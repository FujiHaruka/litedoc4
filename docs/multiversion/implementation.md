# Multi-version documentation — implementation plan (v2.0.0)

Started 2026-10-06. Branch `multi-version`. The goal, the targets and the decisions are in
`docs/multiversion/plan.md` ("v2 targets", D2–D10); this file is the order in which they become
product code, and is deleted when v2.0.0 ships (the code is then the SoT, as for every earlier
implementation plan).

## Context

What exists on 2026-10-06:

- **Single-version product**, unchanged by the milestone so far: `litedoc4 build` extracts one
  package with an extractor built against that package's Lean, writes JSON IR (schema 5, `ir/`),
  renders complete static HTML per module, and writes global files (name map, search index,
  instances, Used by, module list). One `--root`, one toolchain, one source commit; the ledger and
  the incremental path assume all three.
- **Prototypes outside the tree** (Lean v4.34.1, ≈ 7,000 lines): an `.olean` reader with a writer
  table and refusal by version + githash; the hybrid environment (newest Mathlib, old constants
  and decoded extensions); the environment patch that carries one process across versions; the
  print-reuse key; a fork of the extractor with a `World` seam and a reuse seam; an oracle against
  a Lean's own answer. All measured (plan U9) and none product-shaped: environment-variable
  switches, a hard-coded prefix list, literal index arrays, copies between mains. The writer
  record for v4.29.0 survives only inside the committed log
  `benchmarks/results/mathlib-oldest-release-drift-2026-10-05.txt`.
- **What the decisions change for every site** (D4, D9): pages are drawn in the browser from
  data; signatures are carried as text plus link references, with no subterm wrappers; content
  is stored compressed; every URL carries a version.

## Approach

**Build the everyday path first, end to end, on three versions; add the rebuild from nothing
second.**

The everyday path is: a store holds every version already built; a new release is extracted by
its own Lean with today's extractor (no reader, no approximation); the whole site is rendered from
the store. Everything on that path except the extractor has never been built — the store, the
multi-version renderer, the data format, the page drawn in the browser, the version switcher.
That is where the unmeasured risk is, so it goes first. v4.32.2 / v4.33.0 / v4.33.1 are all on
toolchains the extractor already builds on (`tools/lean-toolchains.txt`), so the path can be run
for real without the reader.

The rebuild from nothing (the reader, the hybrid, the patch, print reuse) is prototyped and
measured exact. It enters the product second, as a second way of filling the store, and writes
the same IR as the native path — so nothing downstream of the store knows which way a version
was filled.

The single-version site is the one-version case of the same output (D9). There is no second
format to keep.

**The hypothesis this order rests on**: the store and the IR are a sufficient boundary — the
renderer needs nothing from a version beyond its IR plus a small record (commit, Lean version,
source URL prefix, dependency revisions). **It is falsified** if the renderer has to reach back
into a version's workspace (oleans, `.ilean`, git) at render time; then the store has to keep more
than the IR, and its size estimate below is wrong.

**Read on S (2026-10-07): it held only after widening "the IR" to the extractor's whole output.**
Today's renderer also reads the link index (the dependency closure's name → module and line
ranges), which the extractor writes beside the IR. A store entry therefore keeps both, and a site
rendered from an unpacked entry is byte-identical to one rendered from the build directory (S, v4,
21 files). On S the link index is 93.3% of an entry's raw bytes and 95.7% of its compressed bytes
(Lean core's 1.18 MB against an 84 KB IR; measured →
`benchmarks/results/mv-s-store-2026-10-07.txt`), so the per-version cost is the link index's, not the
IR's. The data format (below) carries only the dependency names a version references; whether the
store can keep that subset instead of the whole index is measured on M.

## Measurement loop

A full Mathlib run costs tens of minutes per version on the runner, so it cannot be the loop that
tells whether a change helped. Three sizes of experiment, the small ones run on every change and
the full one at checkpoints:

| Size | Input | Time per run | What it can say |
|---|---|---|---|
| S | the sample package as a four-commit repository with designed churn (`tools/mv-s/`: `generate.sh`, one patch per version, `expected.txt`), as versions (D6: a site without releases uses commits) | seconds to a minute, local | store, data format, renderer, browser, the command, staleness — exactly, by counters; nothing about Mathlib's time, nothing about dependency revisions (the sample depends on Lean core and a path package only; M covers it) |
| M | a slice of Mathlib at the real release commits: the import closure of a few roots, 5–10% of Mathlib's modules, chosen to include the notation behind the largest drift (`Finset.sum`, set-builder) | minutes, local or runner | everything S says, plus the reader across Lean versions, the patch path and print reuse on Mathlib's real churn; Mathlib's time by the scaling below |
| L | all of Mathlib, the real releases, on the runner | ≈ 11 min first version, minutes per further one | the targets themselves |

- **The release tags of this repository cannot be the S input**: of its 13 tags only `v1.4.0`
  carries the Lean tree (`v1.0.0`–`v1.3.0` are the Rust half). Commits can, and using them
  exercises the commit-as-version path a non-Mathlib site will use.
- **Every run reports per phase** (decode, patch, finalize, key pass, extraction, render, write)
  **its time, its CPU time and the counts that phase scales with** (modules, declarations,
  reprinted declarations, bytes, files). Deterministic counts — reprinted, reused, bytes, files,
  fetches per page — are compared exactly between runs, never predicted.
- **From M to Mathlib, by phase** (theoretical, unverified until the first L run): each phase's
  cost per unit on M, times Mathlib's count of that unit, plus that phase's fixed cost.
  Calibrated once against the full-Mathlib phase times already logged (U9), and checked at every
  L run: a phase predicted more than 25% off is recalibrated, and the miss is written down.
  **It is falsified** if a phase's cost does not scale with any count M can report — the import
  of the newest library is the expected suspect, since it is fixed per run and differs in size
  between M and L.
- **Improvement is read from CPU time and counts first, wall clock second**, 5 runs per arm
  (CLAUDE.md). Local timing runs need no other heavy application running; the runner has no such
  noise but is 1.8× slower.
- **L runs are checkpoints, not the loop**: at the end of step 4 (three versions, the everyday
  path), of step 5 (the rebuild from nothing), and in step 6.

Building S and M is the first item of step 1. Read on 2026-10-06 (from the sources, nothing run):

- **Mathlib's cache fetches a slice**: `lake exe cache get <modules>` downloads only their import
  closure, other packages included (the cache tool's help text and its root filtering, same in
  v4.32.0 and v4.34.1). M costs the slice's download per version, not the whole.
- **M candidates** (closures counted over the `import` lines of v4.34.1 / v4.32.0; Mathlib v4.34.1
  has 8,529 modules; every root exists in both releases):

  | Roots | Closure v4.34.1 / v4.32.0 |
  |---|---|
  | `Algebra.BigOperators.Group.Finset.Basic` + `Order.Filter.Basic` | 447 (5.2%) / 433 |
  | `Algebra.BigOperators.Ring.Finset` + `Data.Set.Lattice` + `Order.Filter.Basic` | 545 (6.4%) / 529 |
  | `Data.Real.Basic` + `Algebra.BigOperators.Intervals` | 722 (8.5%) / 709 |

  All three contain the `∑ x ∈ s, f x` notation (`Algebra.BigOperators.Group.Finset.Defs`) and
  set-builder (`Data.Set.Defs`, whose target changed from `setOf` to `Set.ofPred` between these
  releases), and each loses and gains modules across the pair (11–15 / 25–28) — the churn M exists
  to exercise.
- **S is the sample package with designed churn, not this repository's commits** (decided
  2026-10-06). S has to answer by counters, which needs the right count known before the run;
  designed edits give it (`tools/mv-s/expected.txt`, derived by reading the patches and checked
  against the IR of all three pairs, 0 disagreements), and a commit of `src/` would need a second
  oracle to say what the count should be. `src/` was also thin: 8 commits change it after
  `rust-frozen`, its requires changed twice, and no settled way runs the extractor over it. The
  generated repository still exercises the commit-as-version path (a GitHub-shaped `origin`, one
  commit per version). Its cost: v1 is `e2e/micro` as it is, so an edit to the sample can stop a
  patch applying or change the counts; `expected.txt` names the v1 it was derived against.
- **Two facts from S's IR the format has to respect**: a module's declarations sit in the IR in the olean's order,
  not the source's, so a reorder is visible only through positions; and a `def`'s own name appears
  in its equations, so a renamed definition never shares content with its old name.
- **The compressed IR size** was read at M, not on a full extraction: 15.3% of the packed entry,
  ≈ 66–84 MB per Mathlib version (extrapolated → `benchmarks/results/mv-m-2026-10-07.txt`). The
  full-Mathlib number is read at the first L checkpoint (step 4).

## Steps

Each step ends with something measured or gated. Wall-clock results are recorded in
`benchmarks/results/`, never gated (CLAUDE.md).

### 0. Preserve the prototypes

Copy the prototype sources into the tree as a frozen reference under `prototypes/olean-reader/`
(Lean sources, lakefile, manifest, toolchain, the oracle sources, the design memo; no build logs,
no rounds files). The v4.29.0 writer record stays in its log, pointed at from the directory's
README. Not built by any gate and not part of the package; step 5 ports from it and then deletes
it. **Done 2026-10-06.**

Done when: the directory is committed and `git grep` finds no absolute path under
`/Users` in it.

### 1. The store and the data format

- **The store**: a directory, `--store <dir>`, one entry per version: the IR (compressed), and a
  record of commit, Lean version, how it was filled (own Lean / reader), the source URL prefix,
  the dependency revisions, and **the extractor output identity** — a digest of what produced the
  IR (IR schema version + a digest of the extractor's source, embedded when the extractor is
  built, plus every configuration value the extractor reads). An entry whose identity differs from
  the current extractor's is stale and is re-extracted (D7: judged by content, never by path or
  date).
- **The meta-code equation rule (D8) is applied by the extractor**, from configuration
  (`litedoc4.toml`, a list of namespace prefixes; Mathlib's are `Mathlib.Tactic` and
  `Mathlib.Meta`) instead of the prototype's hard-coded list. Not at render time: the measured
  saving is equations not generated (extraction 111 → 67 s, measured →
  `benchmarks/results/mathlib-structure-rule-and-meta-equations-2026-10-06.txt`), and the list
  is part of the extractor output identity above, so changing it re-extracts.
- **The data format** the browser reads, decided here by measurement on the three versions:
  - per declaration: the content that U3 found shareable (signature text with link references,
    docstring, equations, attributes, fields), **without** the dependency revision, the dependency
    line range and the declaration's own position;
  - per version and module: the declaration list in order, each with its content reference and
    its own position;
  - per version: the dependency link table (name → revision + path + line range), the source URL
    prefix, the module list, the search index, Used by (one file per module), instances.
- **The unit of shared storage** (D5): one content file per module per version, shared only when
  identical — candidate (a) of three measured (below; the choice and its falsifier are in plan.md
  D5). The other two were (b) per-module segments, each version appending only its new or changed
  declarations, and (c) per-declaration blobs packed in large shared files read by byte range.

The store (`litedoc4 store`, internal), the extractor identity and `no_equations_under`, and the
format with all three candidates (`litedoc4 store measure`) exist and agree with
`tools/mv-s/expected.txt` on every S pair (measured → `benchmarks/results/mv-s-store-2026-10-07.txt`,
`benchmarks/results/mv-s-format-2026-10-07.txt`). A content item is a declaration or a module
docstring as today's page shows it, encoded as JSON with links as `[start, stop, name]`, addressed
by the first 64 bits of its SHA-256; **the name is part of the content**, so a rename is a removal
plus an addition (leaving it out would put a name into every manifest entry).
`tools/mv-s-gate.sh` runs the S loop from nothing (40 items, `ci`); `benchmarks/tools/mv-m-run.sh`
runs M.

What M says (438 modules, 5.1% of Mathlib; two runs, byte-identical in every store entry and
every measured file; measured → `benchmarks/results/mv-m-2026-10-07.txt`, which also carries the
extrapolations):

- **Page items = IR declarations + module docstrings − declarations shown inside their parent**,
  exactly. Items are 0.990 of declarations; Mathlib is extrapolated by declarations.
- **A store entry is ≈ 4.6 MB compressed** at M (26.7 MB IR + 3.2 MB link index raw); ≈ 66–84 MB
  per Mathlib version, 3.4–4.3 GB for 51 (extrapolated). The CI store goes to an R2 prefix the
  site does not serve (step 6's default holds).
- **Hosted bytes at 51 versions: a 854 MB, b 711 MB, c 776 MB** (extrapolated), all under 1.5 GB.
  A page under a always makes one content fetch; under b one per release in which its module
  changed (theoretical: ≈ 7 at Mathlib's average churn, up to 26).
- **The per-version files, not the candidate, are the marginal cost of a release**: 73–94% of
  every candidate's 51-version total. A patch release adds 880 of them (≈ 0.84 MB at M) for one
  new content file, and 878 are byte-identical to a file of the previous version; a minor release
  keeps 418 identical, but only 16% of the bytes.
- **The whole per-version link table plus the module list are 90% of the bytes a page view
  fetches**; content is 7.7%.
- **`store measure` takes 8.5 s for three versions** (5 runs, warm), SHA-256 included: ≤ 41 s per
  Mathlib version (extrapolated).
- **Version-pinned URLs make content new on every release** (the smoke on 87 modules →
  `benchmarks/results/mv-m-smoke-2026-10-07.txt`): the one new item of v4.33.1 is a docstring
  whose only change is a Lean reference-manual link carrying the Lean version.

Carried to step 2, because they change what the renderer writes and not the choice above (each
adds the same bytes to every candidate):

- **Share the per-version files by content** — the lever larger than the candidates' difference
  (above). A manifest carries absolute positions, which move with any line above them (U10: 31%
  per minor release absolute, 4.2% relative).
- **Split the link table** per page (in or beside the manifest); its module numbers shift when a
  module is added, so whatever is shared by content cannot carry them.
- **Dependency source links**: the store record keeps each dependency's revision but not its
  repository URL or module roots. A record field, filled by a re-put — the IR does not change, so
  nothing is re-extracted.
- **Docstring autolinks** are not in the link table yet (today's per-page rule).

**Done 2026-10-07.**
Done when: the three versions are in a store; the compressed IR size per version is measured (it
decides where the CI store lives, step 6); the format is chosen with its numbers in a log.

### 2. The multi-version renderer

`litedoc4` renders a site from a store: a thin page shell, the per-version data of step 1, the
shared content, the version list. Today's render path is replaced, not kept beside it (D9). Links
are decided as today (`linkTo`: docs site → pinned source → own page), but a dependency link
becomes a reference into the version's link table.

Done when: rendering the same store twice gives byte-identical output; rendering one version
alone and the three together give the same bytes for that version's data and its shared content;
hosted bytes and file count measured for the three versions.

What exists (2026-10-07):

- **`litedoc4 store render --store --versions --out`** (internal, beside `measure`). It reads one
  entry at a time and keeps nothing of a version once its files are written. Output: `d/<address>`
  holds every data file, gzip-compressed and addressed by its raw bytes (content files, page files,
  module lists, search indexes, instances, one Used-by file per module, the references data, the
  front page, one version file per version, which also carries the title), so anything unchanged
  between two versions is one file; `<v>/<module path>.html`, `<v>/index.html` and
  `<v>/references.html` are page shells whose only version-specific bytes are data attributes
  (version, module, the addresses of the version file, page file, Used-by file or references
  data, the path to the site root); `versions.json` and the root `index.html` are the only files
  that depend on the version set. Locators inside files are addresses, not paths.
- **The page file** holds a page's own link data: line ranges aligned with its items, the roots it
  names, `names` (signature names, by today's declaration rule) and `words` (docstring words, by
  today's autolink resolver, word then tail). Targets name modules, never module numbers; the
  version file carries the pinned source base per root.
- **Shared content carries no layout**: docstrings are HTML in which every word the autolinker
  would try is marked, and destinations stay as the author wrote them; a citation, rendered with the
  version's bibliography, links to that version's `references.html#ref_<key>` and leaves its
  anchor's number to the browser. The browser rule is written once, on the marker's definition.
  Today's single-version HTML is unchanged (51/51 frozen pages).
- **A store entry carries what `build` reads from the checkout besides the IR**: the record
  (schema 4) each root's pinned source URL and the title, the pack the bibliography and the front
  page's Markdown. An entry an older put wrote is "needs re-put" — a re-put, no re-extraction — and
  `measure` / `render` refuse it.
- On S (four versions): 119 files, 53.1 KB stored; v4, a one-line patch, adds 3 data files — the
  module's content file, its page file and the version file — derived from the patch and checked by
  `tools/mv-s-gate.sh` (40 items), which also checks render-twice identity, each version alone
  against its slice of all four, the printed counts against the tree, and that the sample's three
  citations are links its references data lists and its front page is the configured one.

**Deviation from "replaced, not kept beside it" (2026-10-07)**: `build` still writes today's HTML.
Switching it before step 3 exists would publish pages nothing draws and turn every HTML-parsing
gate red; `build` moves onto the store renderer when step 3's page draws from this data, and the
gates listed under "Gates to replace" are replaced then.

What M says (the three releases, schema-4 entries; measured →
`benchmarks/results/mv-m-render-2026-10-07.txt`, which also carries the extrapolations):

- **The identities hold**: five renders of all three versions are byte-identical; each version
  rendered alone gives its shells byte for byte and only data files the three-version run holds
  byte for byte; a separate reader reconciles the renderer's counts with the tree (and was made to
  fail once each way).
- **Hosted: 3,196 files, 4.88 MB** — 1,315 shells (0.58 MB, 441 B each, uncompressed), 1,879 data
  files (4.30 MB gzip), 2 root files.
- **A patch release adds 3 data files (11 KB)** — its one changed content file, that module's page
  file, the version file — where step 1's per-version files added 880. Its 440 shells are now
  what a patch release adds. A minor release adds 683 data files (1.86 MB): 419 of 438 page files
  change, 211 of them only because Lean core's line ranges moved (below).
- **Extrapolated to Mathlib: 169 MB at 11 versions, 693 MB at 51** (shells 40 / 187 MB of that),
  against step 1's 198 / 854 MB for candidate a and the 1.5 GB target. Files per release: 8,314
  shells, plus ≈ 3 data files per patch and ≈ 11k per minor release.
- **A page view at step 1's scope** (version file + page file + content + module list) is 5.26 MB
  over the 438 pages, against step 1's 19.46 MB: the per-version link table is off every view. The
  module list is now 59% of it, if a page fetches it; Used by is a fourth fetch.
- **Render: 9.42 s CPU for three versions, 3.2 s per version, 253 MiB peak** (5 runs, warm);
  ≈ 47 s and ≤ 3.1 GB per Mathlib version (extrapolated). The renderer reports no per-phase time
  yet.

Carried to step 3, because they change what a page fetches, which step 3 decides:

- **Dependency line ranges ride in every page file.** Lean core moves in every Mathlib minor
  release, so 211 of the 228 pages whose content did not change get a new page file for that
  alone; ≈ 5.2 MB of a Mathlib minor release's ≈ 18.9 MB (extrapolated). One per-version table of
  dependency lines would stop it, at the price of a file every page fetches — the shape step 1
  moved away from (its whole link table was 90% of a view).
- **Whether a page fetches the module list** (7 KB at M, every module named; 59% of a view's bytes
  if it does).
- **The docs-site tier is not carried**: store-rendered links go to pinned sources only (D1b).
  A single-version site that links to a dependency's documentation today loses that when `build`
  switches, unless the record carries the tables.
- Module numbers remain inside the search index and the module list, and that is harmless: both
  files list every module, so a release that adds one changes them whatever they number.

**Done 2026-10-07.**

### 3. The page in the browser

`web/src` draws a module page from data: signatures with links, docstrings, equations, fields,
source links built from the version's prefix; the version switcher; search over the selected
version's index; Used by and instances on demand; path URLs and the hash-URL option (D6); a
`#name` anchor that scrolls once the content exists (U7).

D6 leaves four product questions; these defaults are proposed and confirmed before this step
ships:

| Question | Proposed default |
|---|---|
| Old links (`/Mathlib/Foo/Bar.html`) | the page sends the reader to the newest version's page |
| Which URL search engines are told | the newest version's page |
| Switching to a version that has no such module | that version's module list, saying the module does not exist there |
| Switching on an anchor the other version lacks | the module page, top, saying the declaration does not exist there |

Done when: the largest module page settles faster than today's published page (361 ms,
measured the same way as U7); the page-path and anchor check of D9 exists and has failed once.

In progress (2026-10-07):

- **`store render` writes `assets/`** (stylesheet, icon, `site.js`) and the shells link them; a
  module page, a version's index and `references.html` are drawn from the version file, the page
  file and the content (three fetches; the module list only when Imports is opened). On S v1 the
  drawn pages carry exactly the `id`s of the frozen `e2e/micro-expected` pages (13 pages, 0
  missing, 0 extra) and the same 405 body links; a `#name` link from outside sets `:target`.
- **Shells grew from ≈ 381 B to ≈ 749 B on S** (the stylesheet and icon links, the theme script
  inlined, the `<noscript>` line). Step 2's shell figures (441 B on M; 187 of the 693 MB at 51
  versions) predate this and are ≈ 2× low; they are re-derived when M is re-measured in this step.

### 4. One command over the version set

`litedoc4 build` takes the version set — an explicit list, or a rule (for Mathlib: the
non-prerelease releases) — and the store. For each version the store lacks or holds stale: check
out the commit, install its toolchain, fetch dependencies (and Mathlib's cache), build the
extractor against that Lean, extract, add to the store, delete the checkout before the next
(plan Approach: sequential with deletion is a hard constraint). Then render from the store.

What has to change on the way: the ledger keys, `Generation.take`, `deriveSourceUrl` and the
`--out` layout assume one root and one commit; `tools/lean-toolchains.txt` stays the list of
toolchains the native path supports, and a version on a toolchain with no row fails by name.

**This is a cost paid on every release**: adding a release needs the extractor to build on its
Lean and a row for it (with column 2 measured). v4.34.x has none today. There is no fallback —
the reader knows no layout for a Lean newer than its writer table either.

Done when: an empty store plus three versions builds the site; the same command with one version
removed from the store re-extracts exactly that version (counted, not timed); a store entry with a
changed extractor identity is re-extracted. **First L checkpoint**: the three versions on the
runner, from nothing and by adding the third, every phase against the M prediction — the first
time the render pass runs on the runner at all.

### 5. The rebuild from nothing through the reader

Port the prototype into the product as the second way of filling the store:

- the reader with one writer record per supported Lean, refusing any other by version + githash
  (mechanism 1 of D10);
- the oracle against each Lean's own answer, run once per Lean release as a gate (mechanism 2);
- the per-build invariants (mechanism 3), as the plan corrected them: every constant a type
  mentions exists **in the version being read**;
- the hybrid environment, the environment patch across versions in one process, print reuse;
- **the print-reuse key carried forward from the previous version** instead of recomputed (the
  largest phase of a round, ≈ 97 s of ≈ 234 s on the M1, theoretical →
  `benchmarks/results/mathlib-structure-rule-and-meta-equations-2026-10-06.txt`), with a check
  mode that recomputes and compares;
- the open item from U9: the default value read by structure-instance notation, which the key
  does not cover yet.

Writer records are needed for every release in the set: 11 today, of which v4.29.0, v4.31.0,
v4.32.0 exist in the prototype, and v4.30.0's layout is known by source only (D1).

Done when: the three versions filled through the reader give a site that differs from the native
store only where printer drift says it may, counted; the per-extra-version time is measured on the
M1 with no other heavy application running, against the tracked 1.2 min.

### 6. CI, hosting and the full set

- A workflow on `ubuntu-latest` that restores the store, builds, saves the store, and deploys to
  R2. Where the store lives is decided by step 1's size: an R2 prefix the site does not serve is
  the default (Actions caches are evicted after seven days unused).
- The full set of 11 versions, from nothing and by adding the newest, measured against
  "v2 targets".
- The gate of the plan's "Done": `<built> of <declared>`, made to fail once.

## Gates to replace, not extend

These check the single-version output and lose their meaning under D4 / D9. Each is replaced in
the step that breaks it, and the replacement is made to fail once:

- `tools/purelean-micro-gate.sh` and `e2e/micro-expected` (51 frozen pages; the page-path and
  anchor promise in `tools/public-surface.txt`) — must not be re-minted from the new output
  (CLAUDE.md, "The removed trees"); replaced by the D9 path-and-anchor check (step 3).
- `tools/purelean-render-gate.sh` and its expected files — same provenance, same rule.
- The gates that parse static HTML: `site-gate.sh`, `browser-gate.sh`, `usedby-gate.sh`,
  `config-gate.sh`, `e2e-micro.sh`, `watch-gate.sh`, `deps-docs-gate.sh`; and
  `tools/site-artefacts.txt`.
- `tools/lean-versions-gate.sh` compares each toolchain's own IR; under step 5 the question
  becomes the reader against each Lean's own answer.
- `tools/public-surface.txt`: page paths gain the version, and the removed 1.x names are what
  makes this v2.0.0.

## Not in this plan

- Byte compatibility with doc-gen4, every Mathlib commit, prereleases (plan, "Out of scope").
- Instances: kept as today's shape (on demand) until step 1's numbers say otherwise.
