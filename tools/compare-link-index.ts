#!/usr/bin/env -S deno run --allow-read --allow-write
// compare-link-index.ts -- set-compare two `.lidx` name -> module maps.
//
// The question that matters is not "how many names moved" but "does any name
// both sides have point at a *different* module": that failure mode is a link
// that silently goes somewhere else rather than one that disappears. The rest
// is bucketed coarsely on purpose — a whole module missing on one side is a
// different problem from a name missing inside a module both sides have.
//
// usage: compare-link-index.ts --a <a.lidx> --b <b.lidx> [--out <report.md>]
//                              [--samples <n>] [--dump-dir <dir>]

const argv = Deno.args.slice();
const opt = (name: string, dflt = "") => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : dflt;
};
const A = opt("--a");
const B = opt("--b");
const OUT = opt("--out");
const DUMP = opt("--dump-dir");
const SAMPLES = Number(opt("--samples", "10"));
if (!A || !B) {
  console.error("usage: compare-link-index.ts --a <a.lidx> --b <b.lidx> [--out <p>]");
  Deno.exit(2);
}

type Index = {
  names: Map<string, string>;
  modules: Set<string>; // group headers
  known: Set<string>; // the `@` section
};

/** The parser is the renderer's (`src/Litedoc4/Render/LinkIndex.lean`):
 * first byte decides, no error path, a repeated name takes the later module. */
function parse(text: string): Index {
  const names = new Map<string, string>();
  const modules = new Set<string>();
  const known = new Set<string>();
  let current = "";
  for (const line of text.split("\n")) {
    if (line.length === 0) continue;
    const c = line[0];
    if (c === "\t") names.set(line.slice(1), current);
    else if (c === "@") known.add(line.slice(1));
    else if (c === "#") continue;
    else {
      current = line;
      modules.add(line);
    }
  }
  return { names, modules, known };
}

const a = parse(await Deno.readTextFile(A));
const b = parse(await Deno.readTextFile(B));

const onlyA: string[] = [];
const onlyB: string[] = [];
const moved: [string, string, string][] = [];
let same = 0;
for (const [n, m] of a.names) {
  const other = b.names.get(n);
  if (other === undefined) onlyA.push(n);
  else if (other === m) same++;
  else moved.push([n, m, other]);
}
for (const [n] of b.names) if (!a.names.has(n)) onlyB.push(n);

function classify(names: string[], from: Index, to: Index) {
  const byModule = new Map<string, number>();
  let moduleAbsent = 0;
  let moduleShared = 0;
  const absentModules = new Set<string>();
  for (const n of names) {
    const m = from.names.get(n)!;
    byModule.set(m, (byModule.get(m) ?? 0) + 1);
    if (to.known.has(m)) moduleShared++;
    else {
      moduleAbsent++;
      absentModules.add(m);
    }
  }
  return { byModule, moduleAbsent, moduleShared, absentModules };
}

function shapes(names: string[]) {
  const bucket = new Map<string, number>();
  const put = (k: string) => bucket.set(k, (bucket.get(k) ?? 0) + 1);
  for (const n of names) {
    if (n.startsWith("_private.")) put("_private.*");
    else if (/(^|\.)_/.test(n)) put("component starting with _");
    else if (/\.match_\d+$/.test(n)) put(".match_N");
    else if (/\.eq_\d+$|\.eq_def$/.test(n)) put(".eq_N / .eq_def");
    else if (/\.proof_\d+$/.test(n)) put(".proof_N");
    else if (/\.rec$|\.recOn$|\.brecOn$|\.casesOn$|\.below$|\.ibelow$/.test(n)) put("recursor-ish");
    else if (/\.noConfusion(Type)?$/.test(n)) put("noConfusion");
    else if (/«/.test(n)) put("escaped (notation)");
    else put("plain");
  }
  return bucket;
}

const clsA = classify(onlyA, a, b);
const clsB = classify(onlyB, b, a);

const n = (x: number) => x.toLocaleString("en-US");
const top = (m: Map<string, number>, k: number) =>
  [...m].sort((x, y) => y[1] - x[1]).slice(0, k);

const lines: string[] = [];
const say = (s = "") => lines.push(s);

say(`# link-index cross-check (set comparison)`);
say();
say(`A = ${A}`);
say(`B = ${B}`);
say(`date ${new Date().toISOString()}`);
say();
say(`| | A | B |`);
say(`|---|---:|---:|`);
say(`| declarations (name → module) | ${n(a.names.size)} | ${n(b.names.size)} |`);
say(`| groups (modules that have declarations) | ${n(a.modules.size)} | ${n(b.modules.size)} |`);
say(`| \`@\` section (module names) | ${n(a.known.size)} | ${n(b.known.size)} |`);
say();
say(`## The set of names`);
say();
say(`| | count |`);
say(`|---|---:|`);
say(`| in both, and the module agrees | ${n(same)} |`);
say(`| **in both, but the modules disagree** | **${n(moved.length)}** |`);
say(`| A only | ${n(onlyA.length)} |`);
say(`| B only | ${n(onlyB.length)} |`);
say();
for (const [label, names, cls, from] of [
  ["A only", onlyA, clsA, a],
  ["B only", onlyB, clsB, b],
] as [string, string[], ReturnType<typeof classify>, Index][]) {
  if (names.length === 0) continue;
  say(`### ${label} — breakdown of ${n(names.length)}`);
  say();
  say(`| that module on the other side | count |`);
  say(`|---|---:|`);
  say(`| **absent** (the whole module is missing: ${n(cls.absentModules.size)} modules) | ${n(cls.moduleAbsent)} |`);
  say(`| present (missing inside a module both sides have) | ${n(cls.moduleShared)} |`);
  say();
  say(`Name shapes:`);
  say();
  say(`| shape | count |`);
  say(`|---|---:|`);
  for (const [k, v] of top(shapes(names), 12)) say(`| ${k} | ${n(v)} |`);
  say();
  say(`Top modules:`);
  say();
  say(`| module | count | on the other side |`);
  say(`|---|---:|---|`);
  for (const [m, c] of top(cls.byModule, SAMPLES)) {
    const other = label.startsWith("A") ? b : a;
    say(`| ${m} | ${n(c)} | ${other.known.has(m) ? "yes" : "**no**"} |`);
  }
  say();
  say(`Examples: ${names.slice(0, 5).join(", ")}`);
  say();
}
if (moved.length > 0) {
  say(`### ${n(moved.length)} names whose module disagrees`);
  say();
  say(`| name | A | B |`);
  say(`|---|---|---|`);
  for (const [nm, ma, mb] of moved.slice(0, 40)) say(`| ${nm} | ${ma} | ${mb} |`);
  say();
}
say(`## \`@\` section (module names)`);
say();
const knownOnlyA = [...a.known].filter((m) => !b.known.has(m));
const knownOnlyB = [...b.known].filter((m) => !a.known.has(m));
say(`| | count |`);
say(`|---|---:|`);
say(`| both | ${n(a.known.size - knownOnlyA.length)} |`);
say(`| A only | ${n(knownOnlyA.length)} |`);
say(`| B only | ${n(knownOnlyB.length)} |`);
say();
if (knownOnlyA.length) say(`A only (first 20): ${knownOnlyA.slice(0, 20).join(", ")}`);
if (knownOnlyB.length) say(`B only (first 20): ${knownOnlyB.slice(0, 20).join(", ")}`);
say();

const out = lines.join("\n");
console.log(out);
if (OUT) await Deno.writeTextFile(OUT, out);
if (DUMP) {
  await Deno.mkdir(DUMP, { recursive: true });
  await Deno.writeTextFile(`${DUMP}/only-a.txt`, onlyA.sort().join("\n") + "\n");
  await Deno.writeTextFile(`${DUMP}/only-b.txt`, onlyB.sort().join("\n") + "\n");
  await Deno.writeTextFile(
    `${DUMP}/moved.tsv`,
    moved.map(([nm, ma, mb]) => `${nm}\t${ma}\t${mb}`).sort().join("\n") + "\n",
  );
  await Deno.writeTextFile(
    `${DUMP}/known-only-a.txt`,
    knownOnlyA.sort().join("\n") + "\n",
  );
  await Deno.writeTextFile(
    `${DUMP}/known-only-b.txt`,
    knownOnlyB.sort().join("\n") + "\n",
  );
}
