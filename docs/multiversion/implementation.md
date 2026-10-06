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

## Measurement loop

A full Mathlib run costs tens of minutes per version on the runner, so it cannot be the loop that
tells whether a change helped. Three sizes of experiment, the small ones run on every change and
the full one at checkpoints:

| Size | Input | Time per run | What it can say |
|---|---|---|---|
| S | this repository's own history: `src/` at a series of `main` commits since the pure-Lean port, as versions (D6: a site without releases uses commits) | seconds to a minute, local | store, data format, renderer, browser, the command, staleness — exactly, by counters; nothing about Mathlib's time |
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

Building S and M is the first item of step 1, together with an open check: whether Mathlib's cache
can be fetched for a slice rather than whole (if not, M costs the full download per version).

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
- **The open design item is the unit of shared storage** (D5). The browser needs a module's
  content in few fetches; per-declaration files make the file count explode; one file per module
  per version stores a module again whenever one declaration in it changes, and only 30.71% of
  modules have every constant equal across a minor release (measured →
  `benchmarks/results/mathlib-consecutive-release-reuse-2026-10-05.txt`). Candidates: (a) one
  content file per module per version, deduplicated only when identical; (b) per-module
  segments, each version appending only its new or changed declarations, a page fetching the
  segments its manifest names; (c) per-declaration blobs packed in large shared files read by
  byte range. Chosen by hosted bytes, file count and fetches per page view on the three versions,
  extrapolated to 11 and 51 against "v2 targets".

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
