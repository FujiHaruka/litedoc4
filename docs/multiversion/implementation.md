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
| S | the sample package as a five-commit repository with designed churn (`tools/mv-s/`: `generate.sh`, one patch per version, `expected.txt`; v5 changes only the toolchain and is in no row of `expected.txt`), as versions (D6: a site without releases uses commits) | seconds to a minute, local | store, data format, renderer, browser, the command, staleness — exactly, by counters; nothing about Mathlib's time, nothing about dependency revisions (the sample depends on Lean core and a path package only; M covers it) |
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
`tools/mv-s-gate.sh` runs the S loop from nothing (`ci`; 40 items at the end of this step);
`benchmarks/tools/mv-m-run.sh` runs M.

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
  `tools/mv-s-gate.sh` (40 items at this step), which also checks render-twice identity, each version alone
  against its slice of all four, the printed counts against the tree, and that the sample's three
  citations are links its references data lists and its front page is the configured one.

**Deviation from "replaced, not kept beside it" (2026-10-07)**: `build` still writes today's HTML.
Switching it before step 3 exists would publish pages nothing draws and turn every HTML-parsing
gate red; `build` moves onto the store renderer when step 3's page draws from this data, and the
gates listed under "Gates to replace" are replaced then. **Resolved in step 4**: `build` and
`watch` render only from the store, and the static path left the tree.

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

D6 left four product questions; these defaults are implemented (decided 2026-10-07, user's call):

| Question | Default |
|---|---|
| Old links (`/Mathlib/Foo/Bar.html`) | the page sends the reader to the newest version's page |
| Which URL search engines are told | the newest version's page |
| Switching to a version that has no such module | that version's module list, saying the module does not exist there |
| Switching on an anchor the other version lacks | the module page, top, saying the declaration does not exist there |

Done when: the largest module page settles faster than today's published page (361 ms,
measured the same way as U7); the page-path and anchor check of D9 exists and has failed once.

What exists (2026-10-07):

- **`store render` writes `assets/`** (stylesheet, icon, `site.js`, the redirect script) and every
  page is drawn from data: module pages, each version's index (with module summaries and the
  declaration count, now carried in the per-version module list), `references.html`,
  `search.html` and `foundational_types.html` (both per version, their text in the shell, one
  fetch). Shells per version are its module pages plus 4.
- **What a module page fetches**: the version file, the page file and the content before it draws
  (three, every page of S); `versions.json` after the draw, for the version switcher and the "a
  newer version exists" line, and on an older version the newest version's module list for the
  canonical link. The module list, search index, Used by and instances are fetched only when the
  reader opens what needs them. Nothing a version's shells or data files hold depends on the
  version set; what does (the switcher, canonical) is filled by script.
- **D6's four questions are implemented with the defaults above.** The root sends the reader to
  the newest version by script (`location.replace`, query
  and fragment kept); a root `404.html` sends an unversioned old path to the newest version's page
  and a module a version lacks to that version's index, finding the site root by probing
  `versions.json` up the path (so it works under a path prefix). A host with a 200 rewrite points
  it at `404.html`. Canonical is set by script, which a crawler honours only if it renders the
  page.
- **Hash-URL mode** (`store render --hash-urls`): the root `index.html`, `404.html`, `d/`,
  `assets/` and `versions.json`; routes are `#/<version>/<module path>?id=<declaration>`. It adds
  one routing table per version (module path → page and Used-by addresses), written only in this
  mode and listed in `versions.json` and in the root page, which carries the version list, so
  every other file is identical between the modes. A module page fetches four files before it
  draws, three in a row. The routing table is ≈ 686 KB raw / 246 KB gzip per Mathlib version
  (extrapolated from the target's 8,169 module paths with synthesized addresses, scaled to 8,314).
- **The D9 check exists and has failed once each way** (`tools/mv-pages-gate.sh`, `ci`, 33 items
  at this step, over `tools/mv-s-gate.sh --keep`'s two renders; measured →
  `benchmarks/results/mv-pages-gate-2026-10-07.txt`). The frozen arm is one-directional: every page
  path of `e2e/micro-expected/build/` has a shell under `v1/`, and every frozen `id` is on the
  drawn page (14 pages, 215 ids, 0 missing); the self-consistency arm, all four versions in both
  modes, finds every intra-site href (1,159 path / 1,157 hash), every anchor (568 / 567) and every
  page file name (245) after drawing, and judges `#name` arrival by `:target` / `.targeted`.
- **Shells grew from ≈ 381 B to ≈ 766 B on S** (the stylesheet and icon links, the theme script
  inlined, the `<noscript>` line); `search.html` is 1,122 B and `foundational_types.html` 2,867 B.
  Step 2's shell figures (441 B on M; 187 of the 693 MB at 51 versions) predate this and are ≈ 2×
  low; the module list grew ≈ 2.6× on S with the summaries. Both are re-derived on M below.

**Settle time** (measured → `benchmarks/results/mv-settle-2026-10-07.txt`): on
`CategoryTheory.Comma.StructuredArrow.Basic` at Mathlib v4.33.1 (400 declarations; one-version
store of its 379-module import closure), served from loopback by one server, the drawn page
settles in **217 ms against 322 ms** for `build`'s static page of the same module (medians of 10
warm runs per arm, arms alternating; 217 / 320 ms with gzip on the wire). "Settled" is U7's: two
animation frames after the content exists, which for the drawn page also waits for its own
"drawn" mark — the load event alone fired before drawing finished in 5 of 11 runs. Both arms show
the same 400 ids, text and 8,756 links; the drawn page has 25,693 elements against 45,380 (the
wrapper spans D4 drops and the module tree, built on demand). Its first paint is 32–48 ms later
(it paints nothing until it has drawn), and loopback carries none of its extra round trips: the
shell, `site.js`, then the version file, page file and content (theoretical: on a real network
each adds to the drawn arm only). U7's 361 ms was v4.31.0, 387 declarations, and is not compared.

What M says after step 3 (the three releases; measured →
`benchmarks/results/mv-m-render-step3-2026-10-07.txt`, which carries the extrapolations):

- **Hosted: path mode 3,206 files, 5.48 MB; hash mode 1,888 files, 4.42 MB.** Shells average
  826 B (step 2: 441 B); the module list is 12.1 KB gzip per version (step 2: 7.0 KB, ×1.71).
  Extrapolated to Mathlib: path 205 MB at 11 versions and 858 MB at 51 (shells 348 MB of it),
  hash 132 / 521 MB; the target is 1.5 GB.
- **A patch release adds 3 data files plus its shells in path mode** (365 KB, 97% shells), 4
  files and 23 KB in hash mode, where the routing table is rewritten whole for one changed
  address (≈ 225 KB at Mathlib, extrapolated).
- **Before it draws, a module page fetches 3,094 B of data at the median** (max 30,137 B; v4.33.0),
  plus its 821 B shell in path mode. Used by, the module list, search and instances wait for the
  reader.
- **Render: no measurable change** — 9.3 s CPU for three versions in path mode and 9.25 s in hash
  mode at comparable load (2 runs each; step 2: 9.42 s, 5 runs), 253 MiB peak.
- **`mv-m-render.sh --hash-urls` was made to fail once**, and doing so found that its "each version
  alone" identity compared no byte in hash mode (and missed `404.html` and `assets/` in path mode).
  Fixed: it compares the root files in both modes, and ten injected defects each fail it by name.

Decided by those numbers:

- **The version list rides in the hash-mode root** (done): that page already changes with the
  version set, so it costs ≈ 132 B per version there and takes the fetches in a row before drawing
  from four to three (with 50 ms added per request, drawn at 288–293 ms against 343–354 ms, 5 runs
  each; measured with a scratch script, not a gate). `versions.json` is still written for the 404
  page and path mode, from the same string.
- **Dependency line ranges stay in the page files.** Moving them into one per-version table saves
  ≈ 124 KB per minor release on M (35% of page-file bytes; 1.8–2.0 MB of a ≈ 19 MB Mathlib minor
  release, extrapolated) and costs a 14 KB gzip fetch before every draw — the median view 5.6×
  larger. Hosting is not the bound (858 MB of 1.5 GB at 51 versions). **It is falsified** if a full
  run puts the site near the target.
- **The module list is not fetched before drawing.** One case fetches it after drawing: a path-mode
  page of an older version fetches the newest version's list (12.5 KB on M, ≈ 229 KB gzip at
  Mathlib, extrapolated) to decide whether its canonical link exists. Kept: it is exact on a host
  that answers a missing path with 200 (where a request for the newest page would not be), it does
  not delay the page, and a browser caches it across the version's pages.
- **The theme script stays inlined.** 185 B per shell, 22.5% of a module shell, ≈ 78.5 MB at 51
  versions (extrapolated); an external script would block the first paint of every first view on
  one more round trip to avoid a flash of the wrong theme.
- **The routing table stays one file per version.** It is 64% of a median first hash-mode view
  on M; split, it would add a round trip to every route change. Hash mode is the fallback for
  hosts without rewrites, and path mode carries no routing table.
- **Instances keep reading the search index**, as today's single-version page does: opened on
  demand, ≈ 2.13 MB gzip at Mathlib with the instances file and the module list (extrapolated;
  the earlier "≈ 5 MB" was the raw index alone).

**Done 2026-10-07.**

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
Lean and a row for it (with column 2 measured). v4.34.1 has one since 2026-10-08, with no change
to the extractor; v4.34.0 has none. There is no fallback —
the reader knows no layout for a Lean newer than its writer table either.

Done when: an empty store plus three versions builds the site; the same command with one version
removed from the store re-extracts exactly that version (counted, not timed); a store entry with a
changed extractor identity is re-extracted. **First L checkpoint**: the three versions on the
runner, from nothing and by adding the third, every phase against the M prediction — the first
time the render pass runs on the runner at all.

What exists (2026-10-07):

- **`litedoc4 build --versions <ref>,<ref>...`**, an explicit list of tags, branches or commits of
  `--root`'s repository, the last the newest; no rule over releases yet. Each version the store
  lacks, holds stale or holds at another commit: a `git worktree` at `<out>/checkout`, its
  toolchain installed by elan (one with no row in `tools/lean-toolchains.txt` is refused before
  anything runs), `lake build` of its libraries, an extractor built per toolchain under
  `<out>/extractors`, extract, put, the checkout deleted before the next. Then the site is rendered
  from the store into `<out>/site`, as `store render` writes it. `--store` defaults to
  `<out>/store`. **A checkout that is Mathlib or requires it fetches Mathlib's cache** (`lake exe
  cache get`, into `<out>/scratch`, deleted before the extraction) before `lake build`. Every phase
  prints its wall time (`phase <version> <name> <s>`).
- **Stale is judged by the extractor identity without its `lean` / `leanGithash` fields**: a
  commit pins its Lean, so one extractor on any toolchain answers for every entry. A fresh entry
  is kept and every other is extracted from nothing; `store remove` has one version extracted
  again. `--full`, `--source-url`, `--extractor-bin` and `--timings` are refused with
  `--versions`.
- **The counters**: `versions extracted: <n> of <m> (<names>)` and `versions rendered: <n> of <m>
  (<names>)` on stdout and in `litedoc4-build.json`.
- **Plain `build` / `watch`** is the one-version case: the working tree is a version named by the
  first 12 hex digits of its source commit, its IR brought up to date in place (a module whose
  olean did not move is not extracted), put into `<out>/store`, which this command owns and which
  holds that version alone, and the site rendered from the store. `--store` without `--versions`
  is refused by name. Under `--out`, plain `build` writes `site`, `store`, `ir`,
  `link-index.lidx`, `work`, `ledger.json` and `render-ledger.json` (and `extractors` when no
  `--extractor-bin` is given); `build --versions` owns `site`, `render-ledger.json`, `checkout`,
  `scratch`, `extractors` and the default `store`.
- **The static render path left the tree**, with its subcommands, tests and scripts. Public flags
  removed: `--mode`, `--max-rounds`, `--link-index`, `--extractor`, `--extractor-arg`,
  `--deps-docs-url`, `--deps-docs-index`. The docs-site tier left with the last two: dependency
  links go to pinned sources only (D1b).
- **On S** (five versions; v5 is v4 on Lean v4.32.2, the others on v4.31.0),
  `tools/mv-s-gate.sh` (63 items) drives `build --versions` over all five and checks
  the loop against the hand-driven flow of steps 1–3: entries byte-identical
  (`loop-empty`), the site holding the store render's shells and data files byte for byte
  (`loop-render-same`), a second run extracting `0 of 5` into a byte-identical site
  (`loop-again`), both toolchains judged fresh by one cached extractor with nothing built or
  installed (`loop-toolchain`), a removed entry re-extracted alone and byte-identical
  (`loop-remove-one`), and identity changes re-extracting exactly what they reach
  (`loop-identity`). `tools/mv-pages-gate.sh` (46 items) asks of the drawn site what the retired
  static-output gates asked of the static one; `tools/e2e-micro.sh` builds the sample as one
  version and gained GATE 15 (two builds into one `--out` leave the second version alone in the
  store). Every new item was made to fail once.
- **Two product defects found on the way, both fixed**: the search page showed two result lists
  when a query was typed while the index loaded; print stopped opening `<details>` when `build`
  switched.

Done when, on S:

- an empty store plus the versions builds the site — **met** (`loop-empty`, five versions);
- the same command with one version removed from the store re-extracts exactly that version —
  **met** (`loop-remove-one`);
- a store entry with a changed extractor identity is re-extracted — **met** (`loop-identity`).

**First L checkpoint — run 2026-10-07** (one run on `ubuntu-latest`, measured →
`benchmarks/results/mv-l-step4-2026-10-07.txt`; the prediction, committed before it →
`benchmarks/results/mv-l-prediction-2026-10-07.txt`):

- **Two versions from nothing 25.9 min, the third added 16.6 min, the three again 4.8 min** — all
  three in their predicted ranges. Counted: `2 of 2`, `1 of 3`, `0 of 3`; the third run's site is
  the second's byte for byte.
- **Per version on the runner**: extraction 556–594 s (in range), render 94 s (in range, +1% over
  the top), put 25–28 s (in range), cache 52–58 s, `lake build` 4–9 s, extractor 21–26 s
  including its toolchain. **Four misses over 25%, recalibrated**: extractor −60% (one file
  compiled with `lean` + `leanc`, not a Lake project), cache −40% (no `lake update` before it),
  `lake build` −88% (a replay of cached oleans), and the render's peak RSS **+55%** (4.84 GiB for
  three versions against ≤ 3.1 GB) — whether the render's memory grows with the number of versions
  is not separated, and it is the question to ask before 11.
- **Adding a version rewrites no page of a kept version**: of 59,819 files, the step from two to
  three versions changed `index.html` and `versions.json` and added the new version's; every other
  file came out the same bytes. **The add-one-release target is missed on three versions** (16.6
  min against ≤ 15), and 188 s of it re-rendered those identical pages. At 11 versions the render
  alone would be ≈ 17 min (extrapolated, linear in versions); rendering only the added version puts
  adding a release at ≈ 13 min (theoretical).

**Built: render only the versions the site does not already hold.** `writeVersion` takes one
version's entry and nothing of the others, so a kept version's pages cannot depend on the set;
the run above shows it on Mathlib. The build keeps a render ledger beside the site: per version,
the digest of its entry (`entry.pack.gz` and `record.json`, not the record's fields — a plain
`build` re-puts one commit name over a changed working tree), whether URLs are hashes, and the
renderer's identity, which is **the litedoc4 executable's own bytes** (a version string or a
hand-bumped number can go stale and serve a stale site; a list of renderer sources can miss one).
**One rule**: reuse only when every version the ledger lists is still in the set under an equal
key and every file it wrote is present; anything else deletes the site and renders all, so an
added-to site always equals one rendered from nothing (no orphaned `d/` files). Reported as
`versions rendered: <n> of <m>`. On S (`tools/mv-s-gate.sh`, each item made to fail once): a
version dropped renders `4 of 4`, added back `1 of 5`, `--hash-urls` flipped `5 of 5`, a listed
file deleted `5 of 5`, each ending byte-identical to a render from nothing; a second run and an
entry re-extracted into the same bytes render `0 of 5`.

- **On L** (measured → `benchmarks/results/mv-l-step4-incremental-2026-10-07.txt`, one run):
  adding the third version took **13.5 min** (16.6 before) and rendered `1 of 3`; the site it
  produced equals the from-nothing render of the three, all 59,819 files; a build with nothing to
  do took 3.2 s, the ledger's whole cost. Adding a release at 11 versions ≈ 13.6 min
  (extrapolated). **The render's memory grows ≈ 0.57 GiB per version within one process** (1 / 2
  / 3 versions: 3.67 / 4.23 / 4.82 GiB), though it holds one version's data at a time: ≈ 9.4 GiB
  for a full render of 11 (extrapolated) — the case after every litedoc4 upgrade, since the
  renderer key is the executable. **Explained** (measured →
  `benchmarks/results/mv-l-render-memory-2026-10-08.txt`): the allocator the Lean runtime links
  (mimalloc 2.2.3, in every toolchain `tools/lean-toolchains.txt` lists) never gives back a freed
  block of 66 MiB, and reuses one of 40 MiB; reading an entry allocates two blocks over that line
  (the 63 MiB compressed entry, the 538 MiB inflated pack), ≈ 0.6 GiB per version read in one
  process. Nothing the render keeps across versions is involved — ten lines of C against
  `mi_malloc` reproduce it. A full render of n versions peaks ≈ 3.67 + 0.585 (n − 1) GiB on the
  runner (extrapolated): ≈ 9.5 GiB at 11, past 16 GB at about 20. Under a 4 GiB cgroup cap one
  version renders and three do not. Lean v4.34.1's mimalloc 3.4.4 reuses the block (the same
  probe, flat); v4.34.1 is a row of `tools/lean-toolchains.txt` since 2026-10-08, but the
  renderer is built with the consumer's toolchain, so v4.31.0–v4.33.1 keep the growth. **Not worked around**
  (decided 2026-10-08, user's call): one process per version was the lever, and it is not taken
  because the growth leaves with the toolchain. litedoc4, its tests and the extractor build on
  v4.34.1 (measured → `benchmarks/results/lean-434-build-2026-10-08.txt`), which is now a row. **Falsified** if the set must be fully rendered past ≈ 20 versions on a 16 GB machine
  while the renderer is still built on v4.33 or older.
- **Premise**: the previously deployed site is at `<out>/site` when the build starts. Locally it
  is; on the runner step 6 has to bring it down with the store (≈ 300 MB at three versions,
  ≈ 1 GB at 11, extrapolated from the run above). **Falsified** if bringing it down costs more
  than the render it saves (94 s per version on the runner).
- **Premise**: two builds of litedoc4 from one commit are the same bytes. If not, the key never
  matches across runner jobs and every build renders everything — slower, never wrong. **Holds**:
  two builds on the M1, and two runner jobs building from one commit, gave the same bytes.

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

#### Step 5 plan (2026-10-08)

Read from the sources on 2026-10-08, nothing run: `prototypes/olean-reader/` (7,427 lines of
Lean), `extractor/Extract.lean`, and how `build --versions` builds the extractor today (the source
is embedded in `litedoc4`, written out, compiled per toolchain with `lean` + `leanc -rdynamic`).

**Approach.** The reader is the extractor's second front end, not a second extractor. The
extractor gains one seam — a `World` that answers every "which modules, which names, where does
this name live, which docstring" question — and today's native run builds it from the imported
environment exactly as now. The reader builds the same `World`, and the hybrid environment, from
an old version's decoded `.olean` files instead; everything after the seam, and everything after
the IR, is shared. Correctness first, speed second: the step reaches its exactness checkpoint with
one version per process, and only then adds the patch path and print reuse, each held against the
from-scratch output it replaces.

Three choices this rests on, each the plan's own, with what would undo it:

- **The reader is compiled on one toolchain, the newest row of `tools/lean-toolchains.txt`
  (v4.34.1 today).** It decodes into the running Lean's types (the prototype mirrors private
  structures field for field and casts them), so it cannot be branch-free across rows the way
  `Extract.lean` is; D10 already put printing in one Lean, the newest. The `World` seam goes into
  `Extract.lean` and compiles on every row, watched by `ci-lean-versions.yml` as now. A version
  set whose newest version is not on the reader's toolchain cannot be filled through the reader
  and is refused by name before anything is read. **Undone** if a site's newest release must be
  read on a Lean the reader is not ported to yet — then porting the running side becomes a cost of
  every Lean release, like the extractor's row today (D10 accepted it).
- **A second executable, `reader`, built the way the extractor is**: its sources embedded in
  `litedoc4`, compiled by `build --versions` under `<out>/extractors` with the reader toolchain
  only, `Extract.lean` compiled as a module it imports. Not a Lake `lean_exe`: a consumer's
  single-version build never uses it, and `require «litedoc4»` must not compile 2,800 lines of
  binary layouts it cannot run on its own toolchain. `extractor/build.sh`, `tools/ci-build.sh` and
  `tools/lake-package-gate.sh` item 4 stay single-file. **Undone** if the module split makes the
  extractor's own bytes differ — then the reader includes `Extract.lean` by text instead.
- **The writer table is data with one list.** Each record is selected by the header's Lean
  version and githash together, and says which extensions the running Lean has that the writer
  does not, and what each stored reducibility value means. Plan.md's layout reading (0 changes to
  the object encoding in 10 pairs; patch pairs change nothing) is **the hypothesis each record is
  checked against**, never a licence to copy one: every record exists only after mechanism 2 has
  passed for it.

**Which versions go through the reader** (D7): a rebuild from nothing — a store holding none of the
set's versions below the newest — fills the newest natively and every older one through the
reader; adding a release to a store fills it natively as today. `store` records which way an entry
was filled. An internal flag forces the reader for named versions, because the checkpoint compares
the two ways on versions that have both.

**Where it is checked**, smallest first:

- **S** — the sample has no Mathlib, so printer drift is near zero: an S version read in the newest
  Lean must equal its native entry except where the running Lean spells something its own way
  (reducibility), and each such field is named, not ignored. Needs one more S version on the
  reader's toolchain (v5 is v4.32.2), added in the reader gate's own work area so
  `tools/mv-s-gate.sh`'s five versions and 63 items do not move.
- **M** — the three store versions (v4.32.2 / v4.33.0 / v4.33.1) at the 438-module slice, read in
  the v4.34.1 slice: every difference against the native M store classified (newest-Mathlib
  notation, running-Lean spelling, or a defect), counted. This is where "only where printer drift
  says it may" is answered.
- **L** — the step's checkpoint on the runner, after the patch path.

**The order, each item ending in something counted or gated:**

1. **The reader and the writer table in the tree** (`extractor/reader/`, from `OleanReader.lean`):
   records for v4.31.0, v4.32.0 (both prototype), v4.32.2, v4.33.0, v4.33.1 and v4.34.1 (new),
   v4.29.0 (from its log). **Mechanism 2 as a gate**: per writer toolchain, a small program run by
   that Lean serializes a seeded sample of what it loads (the prototype's `Drift.lean`
   serialization), and the reader's decoding of the same files must equal it byte for byte; the
   input is that toolchain's own core library, so it needs no Mathlib and can run in CI for every
   installed record. **Mechanism 1**: another version, one githash byte changed, mixed writers, a
   wrong "absent" entry — each refused by name, each made to fail once.
   **Done 2026-10-08**: `extractor/reader/` (built on v4.34.1 only) with records for v4.31.0,
   v4.32.0, v4.32.2, v4.33.0, v4.33.1 and v4.34.1; `tools/reader-oracle-gate.sh` (`manual`)
   compares every core constant, its type, ranges and docstring, every stored reducibility entry
   with its unfolding behaviour, instances and structures: 10 of 10, every item made to fail once
   (measured → `benchmarks/results/reader-oracle-2026-10-08.txt`). The v4.33.0 hypothesis held:
   stored reducibility 3 changed meaning. Not covered: `implicitReducible` against `semireducible`
   on v4.33+ (the three unfolding levels cannot tell them apart and v4.31.0 has no finer one),
   scoped reducibility entries (core has none), Verso docstring parts (only their names are
   decoded), and extensions a package registers (the absent lists are core's).
2. **The `World` seam in `extractor/Extract.lean`**, ported as a seam, not by copying the
   prototype's file (which predates `--identity`, `--no-equations-under` and its `#guard`, and
   carries debugging output). Natively it must reproduce today's IR byte for byte on every row:
   `tools/mv-s-gate.sh` and the Lean-versions matrix are the judgement.
3. **The hybrid run** (`Assemble.lean` + `HybridMain.lean`): one old version read into the newest
   environment, IR written as the native extractor writes it; the hard stops (Verso-only docstrings,
   tactic text of `(h : p := by tac)` binders read from the old value) counted, never silent; the
   prototype's environment switches become flags or leave. On S, against the native entries.
4. **Mechanism 3 on every reader run**: every constant a type mentions exists in the version being
   read; the declaration list and ranges agree with the `.ilean` the same Lean wrote. A failure
   stops the version by name.
5. **`build --versions` fills through the reader** (the rule above), with the store record and
   stale judgement: a reader-filled entry is stale when the reader's identity or the extractor's
   changes, and is refilled through the reader. **On M: the exactness checkpoint**.
6. **The patch path and print reuse** (`Patch.lean`, `PrintKey.lean`): several versions in one
   process, each patched from the previous; the key carried forward with a check mode that
   recomputes and compares; the structure-instance default value covered. Each lever held against
   the from-scratch IR of the same version (equal in every file, as U9 measured). Per-extra-version
   time on the M1 and the **L checkpoint** on the runner.
7. **The rest of the set**: records for v4.29.1, v4.30.0, v4.32.1 and v4.34.0, each after its
   oracle; v4.30.0 is the one release whose layout is known by source only (D1). Then
   `prototypes/olean-reader/` is deleted.

### 6. CI, hosting and the full set

- A workflow on `ubuntu-latest` that restores the store, builds, saves the store, and deploys to
  R2. Where the store lives is decided by step 1's size: an R2 prefix the site does not serve is
  the default (Actions caches are evicted after seven days unused).
- The full set of 11 versions, from nothing and by adding the newest, measured against
  "v2 targets".
- The gate of the plan's "Done": `<built> of <declared>`, made to fail once.

## Gates to replace, not extend

These checked the single-version output and lost their meaning under D4 / D9. All were replaced
or retired in step 4, when `build` switched to the store renderer; every replacement item was made
to fail once. Retired scripts are read at `72c5993^`, the commit before the removals began.

- `tools/purelean-micro-gate.sh` (deleted; `git show 72c5993^:tools/purelean-micro-gate.sh`) —
  replaced by `tools/mv-pages-gate.sh`, whose frozen arm reads `e2e/micro-expected` (51 frozen
  pages, kept, never re-minted: CLAUDE.md, "The removed trees") for page paths and element ids,
  never bytes; that is now the page-path and anchor promise of `tools/public-surface.txt`.
- `tools/purelean-render-gate.sh` and `tools/purelean-render-expected/` (deleted;
  `git show 72c5993^:tools/purelean-render-gate.sh`) — retired with no successor: they compared
  the target's rendered bytes against a frozen answer of a renderer that no longer exists.
  `tools/base-ir-gate.sh`, which shared its IR tree, stays.
- The gates that parsed static HTML, `site-gate.sh`, `browser-gate.sh`, `usedby-gate.sh` and
  `config-gate.sh` (deleted; `git show 72c5993^:tools/site-gate.sh` and so on), and
  `tools/site-artefacts.txt` — their questions are asked of the store-rendered S by
  `tools/mv-s-gate.sh` (`render-*`) and `tools/mv-pages-gate.sh` (`path-*`, `search-*`,
  `theme-toggle`, `contrast`, `no-horizontal-scroll`, `mathml`, `mono-glyphs`); step 12 of
  `tools/e2e-micro.sh` names where each of its own moved gates went.
- `tools/deps-docs-gate.sh` (deleted; `git show 72c5993^:tools/deps-docs-gate.sh`) — retired
  with the docs-site tier.
- `tools/build-gate.sh`, `tools/clone-gate.sh` and `tools/target2-gate.sh` (deleted;
  `git show 72c5993^:tools/build-gate.sh` and so on), with the reference and compare scripts
  around them — retired with the static path they measured on the target.
- `tools/e2e-micro.sh` and `tools/watch-gate.sh` — kept, rewritten over the one-version store
  build.
- `tools/lean-versions-gate.sh` — unchanged; under step 5 the question becomes the reader
  against each Lean's own answer.
- `tools/public-surface.txt` — page paths carry the version, and the seven removed flags are what
  makes this v2.0.0.

## Not in this plan

- Byte compatibility with doc-gen4, every Mathlib commit, prereleases (plan, "Out of scope").
- Instances: kept as today's shape (on demand) until step 1's numbers say otherwise.
