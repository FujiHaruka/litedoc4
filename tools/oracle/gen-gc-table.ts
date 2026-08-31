#!/usr/bin/env -S deno run --allow-read --allow-write --allow-run --allow-env
// gen-gc-table.ts -- write `src/Litedoc4/Md/GcTable.lean` from UnicodeBasic's
// own answers.
//
// doc-gen4 classifies on `UnicodeBasic`, whose character database is pinned by
// the target package's `lake-manifest.json`. Any other copy of the UCD is a
// different answer: V8's `\p{P}\p{Z}\p{C}` and this one disagree on 4,802 code
// points (measured 2026-08-11). So the ranges are dumped by `dump-gc.lean` from
// the build doc-gen4 links, and written here as Lean.
//
// WHICH HALF OF THIS SCRIPT HAS BEEN EXERCISED, AND WHICH HAS NOT
// ----------------------------------------------------------------
// Two halves, and only one of them can be run on the development machine.
//
//   acquisition   `lake env lean --load-dynlib=<UnicodeBasic>` in the target,
//                 plus the rev out of its `lake-manifest.json`.
//                 **Not exercised by the port to Lean, and not runnable here:**
//                 UnicodeBasic is absent from the target and so is doc-gen4,
//                 which is what brings it, and installing either is a `lake
//                 update` on a Mathlib project — 2.0 GiB of free disk is not
//                 room for it (measured 2026-08-31 →
//                 benchmarks/results/unicode-table-regenerators-2026-08-31.txt
//                 §3). This half is exactly as untested as it was when it wrote
//                 Rust; the repoint neither improved nor damaged it.
//   emission      the Lean file below. **Exercised**, by `--self-check`: the
//                 committed tables are decoded back into ranges, re-emitted, and
//                 the result required to equal the committed file byte for byte.
//
// So `--self-check` says the emitter is right and says nothing whatever about
// whether the ranges are still UnicodeBasic's. Only `--check`, against a target
// that has UnicodeBasic, answers that, and `tools/gc-table-gate.sh` is marked
// `manual` for exactly this reason. Do not read a green `--self-check` as the
// table having been re-asked.
//
// The generated module holds the two tables and nothing else, for the same
// reason `gen-v8-gc-table.ts` splits its output: a generated file is rewritten
// wholesale, so hand-written prose in it is lost without a word — which is what
// happened to the Rust file this script used to write (measured 2026-08-31, §2
// of the same log).
//
// npm/node are broken in this environment; this must run under deno.
//
// usage:
//   deno run --allow-read --allow-write --allow-run --allow-env \
//     tools/oracle/gen-gc-table.ts [--target DIR]
//   ... --check        ask UnicodeBasic and fail if the committed .lean is not
//                      what this produces
//   ... --self-check   re-emit from the committed tables; the emitter only,
//                      no oracle, no target
//   ... --reemit       the same, written out. Changes prose and cannot change a
//                      range: the ranges are read out of the file it overwrites.
//                      It is how a wording change reaches the generated file
//                      while the oracle is out of reach, and it is not a
//                      regeneration — nothing is re-asked

const OUT = new URL("../../src/Litedoc4/Md/GcTable.lean", import.meta.url);
const DUMPER = new URL("dump-gc.lean", import.meta.url);
const DEFAULT_TARGET = "/Users/haruka/dev/lean-projects";

type Range = [number, number];

const args = Deno.args;
const flag = (name: string, fallback: string | null = null) => {
  const at = args.indexOf(name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
};
const target = flag("--target", DEFAULT_TARGET)!;
const check = args.includes("--check");
const selfCheck = args.includes("--self-check");
const reemit = args.includes("--reemit");

function sortedAndDisjoint(name: string, ranges: Range[]) {
  // -2 so that a first range starting at 0 satisfies `lo > previous + 1`.
  let previous = -2;
  for (const [lo, hi] of ranges) {
    if (!(lo > previous + 1 && hi >= lo)) {
      const hex = (n: number) => n.toString(16).toUpperCase();
      throw new Error(`${name}: ranges are not sorted and disjoint at ${hex(lo)}-${hex(hi)}`);
    }
    previous = hi;
  }
}

/** The oracle: UnicodeBasic, through the build doc-gen4 links. */
async function acquire(): Promise<{ pzc: Range[]; zc: Range[]; rev: string }> {
  const DYLIB = Deno.build.os === "darwin" ? "dylib" : "so";
  const lib =
    `.lake/packages/UnicodeBasic/.lake/build/lib/libUnicodeBasic_UnicodeBasic.${DYLIB}`;
  const command = new Deno.Command("lake", {
    args: ["env", "lean", `--load-dynlib=${lib}`, "--run", DUMPER.pathname],
    cwd: target,
    stdout: "piped",
    stderr: "inherit",
  });
  const { code, stdout } = await command.output();
  if (code !== 0) throw new Error(`dump-gc.lean exited ${code}`);

  const sets = new Map<string, Range[]>();
  for (const line of new TextDecoder().decode(stdout).split("\n")) {
    if (line === "") continue;
    const at = line.indexOf(" ");
    const name = line.slice(0, at);
    if (!sets.has(name)) sets.set(name, []);
    sets.get(name)!.push(JSON.parse(line.slice(at + 1)));
  }
  for (const [name, ranges] of sets) sortedAndDisjoint(name, ranges);

  // The pin the tables came from, so a stale one can be spotted.
  const manifest = JSON.parse(await Deno.readTextFile(`${target}/lake-manifest.json`));
  const found = (manifest.packages ?? []).find((p: { name: string }) => p.name === "UnicodeBasic");
  return { pzc: sets.get("PZC")!, zc: sets.get("ZC")!, rev: found?.rev ?? "unknown" };
}

const decodeTable = (s: string): Range[] =>
  s.split(",").map((pair) => {
    const [lo, hi] = pair.split("-");
    return [parseInt(lo, 16), parseInt(hi, 16)] as Range;
  });

/** The committed file, read as the emitter's input rather than as its output. */
function fromCommitted(committed: string): { pzc: Range[]; zc: Range[]; rev: string } {
  const tables = [...committed.matchAll(/^ {2}"([0-9A-F,-]+)"$/gm)].map((m) => m[1]);
  if (tables.length !== 2) {
    throw new Error(`${OUT.pathname} holds ${tables.length} table line(s), not 2`);
  }
  const rev = committed.match(/`([0-9a-f]{40})`/)?.[1];
  if (!rev) throw new Error(`${OUT.pathname} records no 40-hex UnicodeBasic rev`);
  const [pzc, zc] = tables.map(decodeTable);
  sortedAndDisjoint("PZC", pzc);
  sortedAndDisjoint("ZC", zc);
  return { pzc, zc, rev };
}

// Not the Rust encoding: `Litedoc4.gcRanges` reads one string literal per set,
// because 839 array elements are elaborated one by one and a string is one token.
const encode = (ranges: Range[]) =>
  ranges
    .map(([lo, hi]) => `${lo.toString(16).toUpperCase()}-${hi.toString(16).toUpperCase()}`)
    .join(",");

function emit({ pzc, zc, rev }: { pzc: Range[]; zc: Range[]; rev: string }): string {
  return `/-
Holds the answers of Lean 4 / Unicode Basic (Apache-2.0, Copyright © 2023-2026
François G. Dorais), whose data derives from Unicode® character databases
(Copyright © 1991-2025 Unicode, Inc., <https://www.unicode.org/copyright.html>).
See this repository's NOTICE and \`docs/provenance.md\`.

**Generated by \`tools/oracle/gen-gc-table.ts\`; do not edit.** The ranges are
\`UnicodeBasic\`'s own answers, from the build doc-gen4 links, pinned by the
target package's \`lake-manifest.json\` at
\`${rev}\`.
Regenerate with the script above; \`--check\` fails if this file is not what it
produces. \`tools/gc-table-gate.sh\` runs that check, and is manual: UnicodeBasic
only exists where doc-gen4 does, so no free runner can ask it.

What reads the tables, and why they are strings rather than arrays, is said in
\`Litedoc4.Md.Gc\`, which imports this module. Prose written here does not
survive the next run.
-/

namespace Litedoc4

/-- \`P | Z | C\` as ${pzc.length} inclusive \`lo-hi\` hex pairs, in order. Not a
general-purpose Unicode table: the set is a merge of several categories, and
surrogates are members (they are \`Cs\`, inside \`C\`). -/
def pzcTable : String :=
  "${encode(pzc)}"

/-- \`Z | C\` as ${zc.length} inclusive \`lo-hi\` hex pairs, in the same encoding. -/
def zcTable : String :=
  "${encode(zc)}"

end Litedoc4
`;
}

/** The one line a reader gets when a check is red: what moved, not that something did.
 *
 * `writer` names where `source` came from, because the two checks mean different
 * things by a difference: under `--check` the tables can move, under
 * `--self-check` they are the file's own and only the emitter can move.
 */
function whatMoved(committed: string, source: string, writer: string): string {
  const tableOf = (text: string) => [...text.matchAll(/^ {2}"([0-9A-F,-]+)"$/gm)].map((m) => m[1]);
  const theirs = tableOf(committed);
  const mine = tableOf(source);
  for (const [i, name] of ["pzcTable", "zcTable"].entries()) {
    if (theirs[i] === mine[i]) continue;
    if (theirs[i] === undefined) return `it holds no table line for ${name}`;
    let at = 0;
    while (at < theirs[i].length && at < mine[i].length && theirs[i][at] === mine[i][at]) at++;
    return (
      `${name} moved — ${writer} says ${mine[i].split(",").length} ranges / ${mine[i].length} ` +
      `chars, the file says ${theirs[i].split(",").length} / ${theirs[i].length}, ` +
      `first difference at character ${at} (${JSON.stringify(theirs[i].slice(at, at + 24))} ` +
      `where ${writer} has ${JSON.stringify(mine[i].slice(at, at + 24))})`
    );
  }
  const ours = source.split("\n");
  const yours = committed.split("\n");
  let line = 0;
  while (line < ours.length && line < yours.length && ours[line] === yours[line]) line++;
  return (
    `both table strings are identical; ${writer}'s output differs first at line ` +
    `${line + 1} (${JSON.stringify(yours[line] ?? "<end of file>")})`
  );
}

const path = OUT.pathname;
const readCommitted = async () => {
  const text = await Deno.readTextFile(OUT).catch(() => null);
  if (text === null) {
    console.error(`${path} is not there; run this script without a check flag to write it`);
    Deno.exit(1);
  }
  return text;
};

// A thrown premise reaches the reader as a stack trace otherwise, and a gate
// whose failure needs reading past `at file:///...` is one that does not say in
// one line what broke.
// Both events, not one: this module has a top-level `await`, so a throw from
// the code below arrives as a rejected module promise rather than as `error`.
const said = (reason: unknown) => {
  console.error(`${path}: ${reason instanceof Error ? reason.message : reason}`);
  Deno.exit(1);
};
addEventListener("error", (event) => {
  event.preventDefault();
  said(event.error);
});
addEventListener("unhandledrejection", (event) => {
  event.preventDefault();
  said(event.reason);
});

if (reemit) {
  const committed = await readCommitted();
  const held = fromCommitted(committed);
  await Deno.writeTextFile(OUT, emit(held));
  console.error(
    `${held.pzc.length} + ${held.zc.length} ranges re-emitted -> ${path} ` +
      `(the ranges came from that file; UnicodeBasic was not asked)`,
  );
} else if (selfCheck) {
  const committed = await readCommitted();
  const source = emit(fromCommitted(committed));
  if (committed !== source) {
    console.error(`${path}: ${whatMoved(committed, source, "the emitter")}`);
    Deno.exit(1);
  }
  const { pzc, zc } = fromCommitted(committed);
  console.error(
    `${path} is what the emitter writes for the ranges it already holds ` +
      `(${pzc.length} + ${zc.length} ranges) — the emitter only; UnicodeBasic was not asked`,
  );
} else if (check) {
  const committed = await readCommitted();
  const source = emit(await acquire());
  if (committed !== source) {
    console.error(`${path}: ${whatMoved(committed, source, "UnicodeBasic")}`);
    Deno.exit(1);
  }
  console.error(`${path} is current (UnicodeBasic asked through ${target})`);
} else {
  const acquired = await acquire();
  await Deno.writeTextFile(OUT, emit(acquired));
  console.error(`${acquired.pzc.length} + ${acquired.zc.length} ranges -> ${path}`);
}
