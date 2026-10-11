// Builds an IR tree from a published site's `modules.json` + `search-index.json`,
// so that `litedoc4 global` can be run at the real package's scale without the
// real package.
//
// To measure what the shipped search-index encoder produces at the deployed
// site's scale, something has to feed it 4,584 declarations — and the only
// inputs it takes are IR trees. The measurement target needs Mathlib and an
// hour; this needs two JSON files that anyone can curl.
//
// **It is a measuring instrument, not a fixture.** The declarations it writes
// carry a name, a kind and a module and nothing else: no signature, no
// docstring, no source position. Pages rendered from it would be empty, and the
// only artifact it says anything true about is the search index, whose contents
// are exactly those three fields.
//
// usage:
//   node benchmarks/tools/synth-ir.ts \
//     <modules.json> <search-index.json> <out dir>

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";

const [modulesPath, indexPath, outDir] = process.argv.slice(2);
if (!modulesPath || !indexPath || !outDir) {
  console.error("usage: synth-ir.ts <modules.json> <search-index.json> <out dir>");
  process.exit(2);
}

type Module = { n: string; p: string; i: number[] };
const modules = JSON.parse(readFileSync(modulesPath, "utf8")).modules as Module[];
const index = JSON.parse(readFileSync(indexPath, "utf8")) as {
  kinds: string[];
  decls: [string, number, number][];
  modules?: { n: string; p: string }[];
};

// `css_kind` maps the IR's vocabulary to the badge the page shows; this is the
// way back, so that a synthesised tree produces the kinds it was made from.
const IR_KIND: Record<string, string> = {
  def: "definition",
  ctor: "constructor",
  class: "class_inductive",
};

// `i` is "who imports me". The IR carries the other direction.
const imports: string[][] = modules.map(() => []);
modules.forEach((module, at) => {
  for (const importer of module.i ?? []) imports[importer].push(module.n);
});

const declsOf: [string, number][][] = modules.map(() => []);
for (const [name, kind, module] of index.decls) {
  if (module < declsOf.length) declsOf[module].push([name, kind]);
}

mkdirSync(`${outDir}/modules`, { recursive: true });
const entries = modules.map((module, at) => {
  const body = JSON.stringify({
    schemaVersion: 4,
    module: module.n,
    imports: imports[at],
    moduleDocs: [],
    tactics: [],
    declarations: declsOf[at].map(([name, kind], i) => ({
      name,
      kind: IR_KIND[index.kinds[kind]] ?? index.kinds[kind],
      modifiers: [],
      binders: [],
      implicits: [],
      binderCode: [],
      type: "Prop",
      typeCode: [],
      line: i + 1,
      col: 0,
      endLine: i + 1,
      endCol: 1,
      index: i,
      members: [],
      doc: null,
      equations: [],
      equationCode: [],
      refs: [],
    })),
  });
  const file = `modules/${module.n}.json`;
  writeFileSync(`${outDir}/${file}`, body);
  return {
    bytes: new TextEncoder().encode(body).length,
    contentHash: "0000000000000000",
    declarations: declsOf[at].length,
    file,
    module: module.n,
  };
});

writeFileSync(
  `${outDir}/index.json`,
  JSON.stringify({
    declarationCount: index.decls.length,
    dependencyMaps: [],
    generator: "benchmarks/tools/synth-ir.ts",
    hashAlgorithm: "lean-string-hash-64/hex16",
    leanVersion: "4.31.0",
    moduleCount: entries.length,
    modules: entries,
    schemaVersion: 4,
  }),
);
console.log(`${entries.length} modules, ${index.decls.length} declarations -> ${outDir}`);
