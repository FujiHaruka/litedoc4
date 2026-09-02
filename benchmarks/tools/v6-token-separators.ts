#!/usr/bin/env -S deno run --allow-read --allow-write
// V6: the two `autolinkTokens` separator sets.
//
// `autolinkTokens` splits the inside of a code span on a separator set. The
// prototype used **V8's** `/[\p{Z}\p{C}]/u`; the Rust port uses
// **UnicodeBasic's** `Z | C`, because that is the table the renderer's
// `autoLinkInline` splits on. The tokens are the filter in front of the
// whole-package map delta, so a code point that is a separator for one table and
// not the other is a place where the two implementations disagree about which
// modules are stale.
//
// This script measures the disagreement rather than believing it: the symmetric
// difference of the two sets, per direction, over the whole code point space
// (0..=0x10FFFF), and how many of those code points actually occur **inside a
// code span** in the target package's declaration docstrings.
//
// V8's answer is taken from this runtime. UnicodeBasic's is read out of
// `src/Litedoc4/Md/GcTable.lean`, which `tools/oracle/gen-gc-table.ts` generates
// from the build doc-gen4 links — not a second copy of the UCD.
//
// npm/node are broken in this environment; this must run under deno.
//
// usage:
//   deno run --allow-read --allow-write benchmarks/tools/v6-token-separators.ts
//   ... --ir <dir>       the IR tree to scan   (default: the w7h base IR)
//   ... --out <file>     where to write the log (default: the path below)

const REPO = new URL("../..", import.meta.url).pathname;
const DEFAULT_IR = "/private/tmp/lean-doc-relay/w7h/base-ir";
const DEFAULT_OUT = `${REPO}benchmarks/results/m2b-v6-token-separators.json`;
const GC_TABLE = `${REPO}src/Litedoc4/Md/GcTable.lean`;

const args = Deno.args;
const flag = (name: string, fallback: string) => {
  const at = args.indexOf(name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
};
const irRoot = flag("--ir", DEFAULT_IR);
const outPath = flag("--out", DEFAULT_OUT);

// The generated table is `lo-hi` hex pairs in one comma-separated string, and
// the count is in the docstring above it. Both are read, and the second is what
// makes a partial parse fail loudly rather than quietly answering about fewer
// ranges than the file holds.
function readUnicodeBasicZC(source: string): (cp: number) => boolean {
  const at = source.indexOf("def zcTable : String :=");
  if (at < 0) throw new Error("GcTable.lean has no zcTable");
  const open = source.indexOf('"', at);
  const close = source.indexOf('"', open + 1);
  if (open < 0 || close < 0) throw new Error("zcTable is not a string literal");
  const ranges: [number, number][] = [];
  for (const pair of source.slice(open + 1, close).split(",")) {
    const [lo, hi] = pair.split("-");
    ranges.push([parseInt(lo, 16), parseInt(hi, 16)]);
  }
  // The **last** count before `def zcTable`, not the first: `pzcTable`'s
  // docstring is worded identically and comes earlier in the file, so a
  // non-global match would reconcile 742 ranges against 839 and fail on a file
  // that is right.
  const counts = [...source.slice(0, at).matchAll(/(\d+) inclusive `lo-hi` hex pairs/g)];
  const declared = counts.at(-1);
  if (!declared || Number(declared[1]) !== ranges.length) {
    throw new Error(
      `GcTable.lean declares ${declared?.[1]} zcTable ranges, parsed ${ranges.length}`,
    );
  }
  const member = new Uint8Array(0x110000);
  for (const [lo, hi] of ranges) for (let cp = lo; cp <= hi; cp++) member[cp] = 1;
  return (cp: number) => member[cp] === 1;
}

const gcSource = await Deno.readTextFile(GC_TABLE);
const isUnicodeBasicZC = readUnicodeBasicZC(gcSource);

const V8_ZC = /[\p{Z}\p{C}]/u;
const isV8ZC = (cp: number) => V8_ZC.test(String.fromCodePoint(cp));

const v8Only: number[] = [];
const unicodeBasicOnly: number[] = [];
let v8Total = 0;
let unicodeBasicTotal = 0;
let surrogateDisagreements = 0;
for (let cp = 0; cp <= 0x10ffff; cp++) {
  const a = isV8ZC(cp);
  const b = isUnicodeBasicZC(cp);
  if (a) v8Total++;
  if (b) unicodeBasicTotal++;
  if (a === b) continue;
  if (cp >= 0xd800 && cp <= 0xdfff) surrogateDisagreements++;
  (a ? v8Only : unicodeBasicOnly).push(cp);
}

function toRanges(points: number[]): [number, number][] {
  const out: [number, number][] = [];
  for (const cp of points) {
    const last = out[out.length - 1];
    if (last && last[1] + 1 === cp) last[1] = cp;
    else out.push([cp, cp]);
  }
  return out;
}

const disagreeing = new Set([...v8Only, ...unicodeBasicOnly]);

const CODE_SPAN = /`([^`\n]+)`/g;

interface Occurrence {
  module: string;
  decl: string;
  codePoint: number;
  direction: "v8Only" | "unicodeBasicOnly";
}

const index = JSON.parse(await Deno.readTextFile(`${irRoot}/index.json`));
const occurrences: Occurrence[] = [];
let modulesScanned = 0;
let declsScanned = 0;
let docstringsScanned = 0;
let codeSpansScanned = 0;
let codeSpanCodePoints = 0;
for (const entry of index.modules) {
  modulesScanned++;
  const module = JSON.parse(await Deno.readTextFile(`${irRoot}/${entry.file}`));
  for (const decl of module.declarations ?? []) {
    declsScanned++;
    if (!decl.doc) continue;
    docstringsScanned++;
    for (const m of decl.doc.matchAll(CODE_SPAN)) {
      codeSpansScanned++;
      for (const ch of m[1]) {
        codeSpanCodePoints++;
        const cp = ch.codePointAt(0)!;
        if (!disagreeing.has(cp)) continue;
        occurrences.push({
          module: entry.module,
          decl: decl.name,
          codePoint: cp,
          direction: v8Only.includes(cp) ? "v8Only" : "unicodeBasicOnly",
        });
      }
    }
  }
}

const hex = (cp: number) => `U+${cp.toString(16).toUpperCase().padStart(4, "0")}`;
const record = {
  measurement: "V6: the two autolinkTokens separator sets",
  date: new Date().toISOString().slice(0, 10),
  label: "実測",
  runtime: { deno: Deno.version.deno, v8: Deno.version.v8 },
  unicodeBasicFrom: "src/Litedoc4/Md/GcTable.lean (generated from the build doc-gen4 links)",
  sets: {
    v8Members: v8Total,
    unicodeBasicMembers: unicodeBasicTotal,
    agree: 0x110000 - disagreeing.size,
    disagree: disagreeing.size,
    // The direction that costs correctness: V8 splits here and UnicodeBasic
    // does not, so the Rust port keeps a longer token and never offers the
    // pieces the prototype would have offered.
    v8OnlySeparator: v8Only.length,
    unicodeBasicOnlySeparator: unicodeBasicOnly.length,
    surrogateDisagreements,
  },
  v8OnlyRanges: toRanges(v8Only).map(([lo, hi]) => [hex(lo), hex(hi)]),
  unicodeBasicOnlyRanges: toRanges(unicodeBasicOnly).map(([lo, hi]) => [hex(lo), hex(hi)]),
  corpus: {
    ir: irRoot,
    modulesScanned,
    declsScanned,
    docstringsScanned,
    codeSpansScanned,
    codeSpanCodePoints,
    occurrences: occurrences.length,
    where: occurrences.slice(0, 50),
  },
};

await Deno.writeTextFile(outPath, `${JSON.stringify(record, null, 2)}\n`);
console.error(
  [
    `V8 |Z∪C| = ${v8Total}, UnicodeBasic |Z∪C| = ${unicodeBasicTotal}`,
    `disagree on ${disagreeing.size} code points`,
    `  V8 only (Rust under-splits): ${v8Only.length}`,
    `  UnicodeBasic only:           ${unicodeBasicOnly.length}`,
    `corpus: ${modulesScanned} modules, ${declsScanned} declarations, ` +
      `${docstringsScanned} docstrings, ${codeSpansScanned} code spans, ` +
      `${codeSpanCodePoints} code points inside them`,
    `  occurrences of a disagreeing code point: ${occurrences.length}`,
    `-> ${outPath}`,
  ].join("\n"),
);
