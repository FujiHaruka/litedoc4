# Multi-version Mathlib documentation — milestone plan

Started 2026-10-04. Branch `multi-version`. This file holds the goal, the open questions and the
decisions of the milestone; results land in `docs/verification-log.md` as usual, and the logs in
`benchmarks/results/`.

## Goal

**One build produces one site in which a reader can pick any public Mathlib version and read its
documentation**, and switch versions on the page they are reading.

- **"Public Mathlib version"** = a release on the Mathlib Releases page
  (`github.com/leanprover-community/mathlib4/releases`) that is not marked prerelease
  (decided 2026-10-04, user's call).
- **"Realistic"** is two budgets that this plan has to turn into numbers (→ D2): the wall clock of
  the one build, and the size and file count of what is hosted.
- Anything may be given up to meet the budgets — a feature, a page shape, no-JS reading of old
  versions — as long as what is given up is written down (→ "Features that could be given up").

## Context — what is known on 2026-10-04

### The version set today

11 releases (measured 2026-10-04, GitHub API; Lean read from each tag's `lean-toolchain`):

| Release | Date | Commit | Lean | Extractor builds on this Lean |
|---|---|---|---|---|
| v4.34.1 | 2026-09-24 | `d13f23b723` | v4.34.1 | unmeasured |
| v4.34.0 | 2026-09-15 | `5ed2965256` | v4.34.0 | unmeasured |
| v4.33.1 | 2026-08-21 | `0df444a360` | v4.33.1 | yes |
| v4.33.0 | 2026-08-10 | `db584cd6d4` | v4.33.0 | yes |
| v4.32.2 | 2026-07-28 | `905b95818e` | v4.32.2 | yes |
| v4.32.1 | 2026-07-23 | `520045ab14` | v4.32.1 | unmeasured |
| v4.32.0 | 2026-07-13 | `81a5d257c8` | v4.32.0 | unmeasured |
| v4.31.0 | 2026-06-15 | `fabf563a7c` | v4.31.0 | yes |
| v4.30.0 | 2026-05-26 | `c5ea00351c` | v4.30.0 | unmeasured |
| v4.29.1 | 2026-04-17 | `5e932f97dd` | v4.29.1 | unmeasured |
| v4.29.0 | 2026-03-30 | `8a178386ff` | v4.29.0 | unmeasured |

- **4 of 11 are on a toolchain the extractor is known to build on** (`tools/lean-toolchains.txt`).
  The other 7 are the first wall (→ U1).
- **v4.31.0 is `fabf563a7c` — the commit already documented end to end** on 2026-10-03.
- **The set grows**: 11 releases in the 6 months from 2026-03-30 to 2026-09-24, and 5 of the 11 are
  patch releases (`x.y.1`, `x.y.2`). A new one arrives roughly every two to three weeks, so
  "one build" happens again for each release (→ D7).
- **The Releases page starts at v4.29.0-rc2 (2026-02-25).** Mathlib has 47 stable `v4.x.y` tags
  going back to v4.0.0, but those have no Releases page entry, so they are outside D1's definition.

### One version, as measured

From one `litedoc4 build --lib Mathlib` of `fabf563a7c` on Apple M1 / 16 GB, Lean 4.31.0, 4 jobs,
page cache partly warm, single run (measured → `benchmarks/results/mathlib-render-fixed-2026-10-03.txt`):

| | |
|---|---|
| Wall clock | 449.9 s: extract 296.5, render 61.5, global 30.4, detect and the rest 61.4 |
| Pages | 8,170 module pages, 311,415 declarations |
| Module page HTML | 1,074,382,825 B — the site is 1.1 GB and almost all of it is these pages |
| Global files | name map 24.3 MB, search index 5.1 MB, module index 1.0 MB |
| IR | 550 MB |
| Mathlib checkout with oleans | 6.7 GB, of which `.lake` 6.6 GB |
| Peak memory | extractor 3.73 GB (measured → `benchmarks/results/mathlib-render-2026-10-03.txt`); litedoc4 2.79 GB footprint |

### What simply multiplying gives

11 independent builds and 11 independent sites (extrapolated, × 11 from the single run above):

| | One version | × 11 |
|---|---|---|
| Wall clock | 449.9 s | ≈ 82 min, plus olean download per version |
| Hosted bytes | 1.1 GB | ≈ 12 GB |
| HTML files | ≈ 8,174 | ≈ 90,000 |

### Hosting ceilings

Read from the vendors' documentation on 2026-10-04:

- **GitHub Pages**: published site at most 1 GB; deployment times out after 10 minutes; soft limit
  of 100 GB bandwidth per month and 10 builds per hour.
- **Cloudflare Pages**: at most 20,000 files per site (free) or 100,000 (paid); at most 25 MiB per
  file; no stated total size limit.

**One Mathlib version (1.1 GB) is already over GitHub Pages' documented limit**, and 11 versions as
they are today are ≈ 4.5× Cloudflare Pages' free file limit. So the size question is not "how do
we fit 11 copies" but "how do we fit one, then make the other ten nearly free".

**The documented 1 GB is not what GitHub enforces at this size**: doc-gen4's own Mathlib site is
2,555,490,819 B and its GitHub Pages deploy succeeds (measured 2026-10-04 →
`benchmarks/results/mathlib-site-bytes-2026-10-04.txt`). That is an observation about one
repository on one day, not a promise; the plan does not rely on it.

### What incremental extraction will not buy

A study on 2026-10-03 counted, for 1,050 consecutive Mathlib commits, how many modules a safe
incremental build would re-extract (the changed modules and everything downstream). Batched a week
at a time (≈ 210 commits) the median was 8,167 modules — essentially all of them — and a day at a
time (≈ 30 commits) already 7,761 (measured, 2026-10-03; the log was not committed, so U3
re-measures what this plan relies on). Consecutive releases are 5 to 39 days apart. **Between two releases, incremental extraction
re-extracts everything**, so extraction cost is linear in the number of versions; savings have to
come from the output side.

## Approach

**Extract each version separately and in sequence; render all versions together into one store
where identical content is written once.**

1. **Extraction runs in one Lean, the newest, for every version** (D10). For each release: fetch
   its oleans, read them with an own `.olean` reader, print with the newest Lean and Mathlib, keep
   the IR, delete the checkout before the next one. Sequential with deletion is a hard constraint,
   not an optimisation: one checkout is 6.6 GB, and disk exhaustion has already damaged the target
   once (CLAUDE.md, 2026-08-17). Cost: unknown until U9.
2. **Rendering becomes multi-version.** One pass reads every version's IR and writes:
   - a **version-independent layer**: each declaration's rendered content (signature, docstring,
     equations, attributes) stored once per distinct content, addressed by a hash of the content;
   - a **per-version layer**: what really differs per version — which declarations each module
     has, in which order, and the globally collected parts (Used by, instances, search index,
     source links).
3. **Pages are assembled from the two layers.** Whether assembly happens at build time (static
   HTML per version, deduplicated only in storage) or in the browser (thin HTML plus data) is the
   central representation decision (→ D4), and it decides whether the hosted size scales with the
   number of versions or with the number of distinct declarations.
4. **Every feature is priced** against the budgets. A feature whose output differs per version for
   most declarations (a source link carrying the commit SHA is the obvious one) either moves into
   the per-version layer in a form that does not touch the shared content, or is limited to the
   latest version, or goes.

The order is: **first find out whether the version set and one version are feasible at all**
(U1, U4, U6), then **measure how much content really is shared between releases** (U3), and only
then choose the representation (D4) and the feature cuts (D8). Choosing the representation before
U3 would decide the design on an unmeasured sharing ratio.

**The hypothesis this plan rests on**: between two consecutive releases, most declarations'
rendered content is byte-identical once version-specific parts (source links, Used by, instances)
are moved out of it. **It is falsified** if U3 finds that a large share of declarations that did
not change in source still change in rendered content — for example because signatures link to
modules that moved. (Pretty-printing no longer changes with the Lean version: D10 prints every
version with one printer.) Then the shared layer saves
little, and the remaining levers are cutting features or cutting versions.

## Unknowns to measure

Each item says what is expected and what would show the expectation wrong.

### U1 — Does the extractor build on the 7 unmeasured toolchains?

**Superseded by D10**: the per-version extractor is replaced by one reader in the newest Lean, so
the question became the reader's per-version layout knowledge, answered for v4.29 – v4.34
(measured → `benchmarks/results/lean-olean-layout-history-2026-10-04.txt`). The text below is the
question as it stood.

v4.29.0, v4.29.1, v4.30.0, v4.32.0, v4.32.1, v4.34.0, v4.34.1.

- **Expected**: patch releases inside a series behave like their neighbours (v4.32.0 / v4.32.1
  like v4.32.2); v4.34.x needs at most a small fix, as v4.33.0 did; v4.29 / v4.30 are the
  uncertain ones.
- **Wrong if**: any of them fails to build. v4.34.x then has to be fixed regardless — it is the
  newest and every future release continues from it. v4.29 / v4.30 can be fixed or dropped (→ D1).
- **Constraint**: the extractor does not branch on the Lean version. If a fix cannot be written
  without branching, that is a finding to bring back, not a licence to branch.
- This cost recurs: every new Lean release may break the extractor. The plan has to say who pays
  it and when (→ D7).

### U2 — Are the oleans of the 11 release commits all fetchable?

The 2026-10-03 study checked 5 arbitrary dates, not these 11 commits.

**Not measured, by choice** (decided 2026-10-04, user's call): expected to hold, and a missing
file shows on the first full build.

- **Expected**: all fetchable from `cache.mathlib.org`.
- **Wrong if**: any file is missing. Building one version from source takes hours (assumed), which
  would break the build-time budget for that version.

### U3 — How much rendered content do consecutive releases share?

The experiment proposed on 2026-10-04, retargeted from adjacent commits to adjacent releases.
Two pairs can run today, before U1, because both sides are on supported toolchains:

- a **patch pair**: v4.33.0 → v4.33.1;
- a **minor pair**: v4.32.2 → v4.33.0.

For each pair, classify every declaration as: unchanged / changed in source / changed only in
rendered content / added / removed. Then split "changed only in rendered content" by cause:
signature links to Mathlib modules, signature links to dependencies (their pinned revision moves —
Lean core's on every release, D1b), pretty-printing, docstring link resolution, Used by, instances,
source link, and
the attribute string of reducible instances — Lean renamed it between v4.32.2
(`implicit_reducible`) and v4.33.0 (`instance_reducible`) (`tools/lean-toolchains.txt`, column 2),
so the minor pair carries churn that no Mathlib source change caused. The patch pair, on one Lean
series, is the cleaner measurement of the hypothesis.
Count source links both ways — pinned to the commit SHA, and as a constant prefix.

- **Expected**: excluding source links, Used by and instances, ≥ 90% of declarations are
  byte-identical between a patch pair (assumed); less for a minor pair.
- **Wrong if**: the share of declarations that did not change in source but changed in rendered
  content is large. That falsifies the Approach's hypothesis.
- Also check one pair for **non-determinism**: render the same IR twice and compare. Any difference
  there is a defect, and it would also destroy deduplication.

**Answered 2026-10-04** (measured → `benchmarks/results/mathlib-release-sharing-2026-10-04.txt`;
each version extracted by its own Lean with today's extractor):

- **The hypothesis holds, once links into dependencies are taken out of shared content.** Share of
  declarations byte-identical, patch pair / minor pair: 11.48% / 7.04% as rendered; **99.9994% /
  97.89%** with the dependency revision, the dependency line ranges, the declaration's own source
  position and the reducibility rename taken out.
- **The "expected" above was wrong on what is version-specific.** Not only source links, Used by
  and instances: 77.8% of declarations have a signature link into Lean core, whose revision moves on
  every release, and between minor releases 20.7% of the referenced dependency declarations moved
  lines. **D5 has to keep both the revision and the line range of a dependency link out of shared
  content**; removing the revision alone leaves the minor pair at 43.21%.
- **Falsifier**: in the minor pair, 603 of 93,533 declarations in byte-identical source files
  (0.64%) still changed — 539 of them from one upstream rename (`setOf` → `Set.ofPred`: same text,
  link to a different constant). The patch pair (v4.33.0 → v4.33.1 is a single toolchain-bump
  commit) changed 2 declarations, both from Lean itself.
- **No non-determinism**: two extractions of v4.33.1 gave byte-identical IR, link index and site.
- Printing per version here, not with one printer as D10 decides; printer drift is 0 in the patch
  pair and at most 255 declarations in the minor pair.

### U4 — What is the 1.1 GB of one version made of?

Break one version's site down by part: declaration signatures (and how much of that is link
markup), docstrings, equations, Used by, instances, page chrome repeated on every page, inlined
assets. This decides which representation change pays (→ D4) and which feature cuts matter (→ D8).

- **Expected**: link markup and per-page chrome are a large share, and the deduplicable part is
  most of the rest.
- **Wrong if**: one part that cannot be shared dominates — then sharing does not get one version
  under the hosting limit, and the representation itself has to shrink.

**Answered 2026-10-04** (measured → `benchmarks/results/mathlib-site-bytes-2026-10-04.txt`):

- **The size is the format, not litedoc4.** doc-gen4's Mathlib module pages are 1,069,790,161 B
  against litedoc4's 1,074,699,047 B; on the 5,877 modules with the same content litedoc4 is
  1.051×.
- **Signatures are 63.92% of page bytes, and markup is 89.88%.** Text is 9.99%. Links are 37.92%
  of bytes.
- **Per-page chrome is small**: 1,612 B of fixed boilerplate per page, 1.36% in total. The
  "expected" above was wrong on this half.
- **Levers, as upper bounds that overlap**: the `<span class="fn">` wrappers in signatures
  (≈ 247 MB, the same density in doc-gen4); links to Lean core source on GitHub (835,214 links,
  ≈ 100 MB, only 1,733 distinct URLs — litedoc4 only); same-page links spelled as full paths
  (≈ 47 MB); `../` prefixes (≈ 40 MB); the Used by placeholder (≈ 40 MB, litedoc4 only).
- **The readable text of all 298,656 signatures is 54,717,246 B — 7.97% of their HTML.** The rest
  is 12.0 M spans (≈ 40 per signature) and 3.45 M links (measured →
  `benchmarks/results/mathlib-signature-shape-2026-10-04.txt`).
- **Every module page compressed on its own with gzip totals 54,843,686 B**, 19.6× smaller than
  the pages (measured, same log). Data that the browser decompresses is stored at roughly that
  size; a host compressing on the fly does not change the stored size.
- **What this means for D4**: the bytes are markup around a small amount of text. A signature as
  tokens (text, a reference into a name table per link, a marker per span) is ≈ 89 MB before
  compression (theoretical, same log), and compression on top of any data format is the larger
  lever. Both shrink one version by more than deduplicating versions does.

### U5 — Can the build host carry it?

Per version: 6.6 GB of checkout, 550 MB of IR, up to 3.73 GB of extractor memory, all measured on
an M1. The one build needs all IRs at once at render time (≈ 6 GB for 11, extrapolated) unless the
renderer streams them.

- Measure on the host the build will actually run on (a CI runner or this machine, → D3). Do not
  write a runner's memory or disk size from memory — read it from the runner image's documentation
  and record the date.
- **Wrong if**: memory or disk does not fit; then the render pass has to stream versions rather
  than load them all.

### U6 — Where can it be hosted, with numbers?

GitHub Pages is out for even one version as things stand (1 GB). Candidates: Cloudflare Pages
(file count), object storage behind a CDN (Cloudflare R2, S3), a GitHub Pages site per version
(one repository each), Netlify / Vercel. For each: size limit, file count limit, per-file limit,
cost per month at the expected traffic, and how a CI deploy reaches it.

- **Wrong if**: no option fits a realistic representation within a cost the user accepts. Then
  version count or features are what gives.

**Answered 2026-10-05** (vendor limits read from their documentation that day; sizes extrapolated
from one version → `benchmarks/results/hosting-and-client-render-2026-10-05.txt`):

| D4 row | 11 versions | 51 versions |
|---|---|---|
| Static HTML as served | 13.1 GB, 90k files | 60.6 GB, 417k files |
| Static HTML, stored precompressed | 0.77 GB, 90k files | 3.6 GB, 417k files |
| Thin HTML + shared data | 0.32 GB, ≈122k files | 1.38 GB, ≈544k files |
| Thin + data, one shell page answering every path | ≈33k files | ≈133k files |

- **Fits every row: Cloudflare R2 behind a Cloudflare domain** (≈ $0–1 a month plus a domain) and
  **S3 + CloudFront** ($0, or ≈ $15 a month at an assumed 200 GB and 3 M requests). Only these
  two keep static HTML for all 51 versions — reading without JavaScript included.
- Cloudflare Pages / Workers: thin + data fits 11 versions only on the $5 plan with a rewrite; 51
  need coarser data files. GitHub Pages: 11 versions of thin + data, not 51. Netlify: over its $20
  plan at the assumed traffic. Vercel: does not fit.
- **D6 fixes the file count at one page per module per version in every row**, unless the host
  answers any path with one shell page and status 200 — GitHub Pages cannot (it returns 404).
- **Used by is 10.3 of the 15.3 MB each version carries compressed**, and its one file is 74.5 MiB
  raw, over Cloudflare's 25 MiB per-file limit — today's single-version site does not fit there
  unchanged. Making Used by latest-only (D8) is now a hosting lever.

### U7 — What does a data-driven page cost the reader?

If pages become thin HTML plus data rendered in the browser (one D4 option): time to first content
for the largest Mathlib module page, behaviour with JavaScript off, behaviour of in-page anchors
and of links from outside (search engines, Zulip, papers), memory in the browser.

**Answered 2026-10-05** (measured, same log; the largest Mathlib module page, 387 declarations,
headless Chrome 154 on loopback, medians of 5; network time not measured):

- **Bytes: data saves only 1.9× after compression.** All 8,169 module pages gzip to 54.7 MB as
  HTML and to 28.6 MB as data (23.9 MB with brotli). The ≈ 89 MB "signatures as data" figure in U4
  was before compression; against compressed HTML the gain is far smaller than it suggested.
- **Time: the data-driven page settles in 153 ms against 361 ms for the page as published**, but
  most of that is element count, not format: the static page without CSS/JS and without subterm
  wrappers settles in 189 ms. Layout (≈ 120 ms) tracks element count in every variant.
- **A `#name` link from outside does not scroll on a page drawn by script**; re-assigning the
  location after drawing fixes both the scroll and `:target`.
- Chrome 154 cannot decompress brotli in script, so data stored as brotli works only if the host
  sends it encoded; gzip works either way.
- Google treats an instant meta refresh as a permanent redirect — relevant to the root page that
  resolves to the newest version (D6).

### U8 — Which of the extractor's answers can one reader plus the newest Lean give?

D10 measured printing only. The extractor asks Lean more than that (occurrences in its source,
comments included): `ppSignature` / `ppExprWithInfos` (10), `inferType` (8),
`findDeclarationRanges?` (5), `isInstance` (4), `getEqnsFor?` (4), `toAttrString` (4), `isClass` /
`isStructure` (6), `getStructureInfo?`, `getReducibilityStatus`, `forallTelescope(Reducing)`, the
instance extension. Each falls in one of three kinds:

- **stored data**: the reader decodes it (ranges, reducibility, instance entries, structure info);
- **computed from stored data by Lean code**: run by the newest Lean on the old data
  (`inferType`, telescopes, printing) — approximate, as printing is;
- **generated by running elaboration** — equations: `getEqnsFor?` proves equation lemmas for a
  definition, so an old definition would have to be added to the newest environment first, or
  equations become latest-only (already a candidate in the features table).

- **Expected**: every answer falls in the first two kinds except equations.
- **Wrong if**: something on every page needs elaboration of old declarations in the newest
  environment. Then that feature is latest-only or goes (→ D8).

**Answered 2026-10-04** (desk reading of the extractor against Lean v4.34.1, plus one measurement):

- **The expectation holds**: of the extractor's outputs, 27 are stored data, 3 are computed by Lean
  code (plus printing on 6 of the stored ones), and only equations need elaboration.
- **But "computed from stored data" was mislabelled for every call that takes a name.** In an
  environment holding the newest Mathlib, asking for a declaration *by name* — its type, its
  structure fields, its docstring, its module, its equations — answers about the newest
  declaration of that name, with no error. That is 99.22% of names (the drift log), and 18.66% of
  declarations have a different type there. About 30 such lookups exist; each must read the
  decoded old data instead, or run against an old environment (U9). Only calls that take an
  *expression* — printing, telescopes, the class test — can go to the newest Lean, and they look
  names up inside, which is where the approximation lives.
- **Equations** (measured, all 57,892 eligible definitions of Mathlib v4.34.1, one version →
  `benchmarks/results/mathlib-equation-sources-2026-10-04.txt`): 22.86% have their equation lemmas
  already stored in the oleans; 72.00% have nothing to split, so the one equation `f xs = body` can
  be built from the decoded value (equivalence with Lean's own output inferred, not compared);
  **5.14% need real generation** (matcher, if-then-else, recursion). Adding the old definition to
  the newest environment does not work — the name already exists there for 99.22%.
- **Each version's Lean core library has to be read too** — core names are in every signature, and
  Mathlib's classes extend core's. It ships with that version's toolchain, not Mathlib's cache:
  1,749,779,168 B in 7,556 files for v4.34.1 (measured, same log).
- **A declaration that fails today vanishes from the IR** — the failure is printed, not recorded —
  and a failed equation reads as "no equations". Both are silent on the page; a multi-version
  build hits them more often (a missing constant in the newest version raises inside the printer).
- Smaller items: the Lean version on the index page is the running binary's; the reader must
  apply the global-only filter Lean applies to instance, simp and ext entries; the 282 Mathlib
  tactics are all data (`ParserDescr`), so their names are readable without running parser code;
  reducibility before v4.33.0 is printed as that version wrote it.

### U9 — How fast is the reader, and does printing fit the build budget?

One version is a 6.6 GB checkout, 11 versions are read in sequence, and the budget is 2 h for all
of them (D2). The reader decodes objects in Lean code rather than mapping them into memory as Lean
does; printing ran at ≈ 1 ms per declaration in the drift measurement (5.1 s for 5,000), ≈ 5 min
for 311,415 (extrapolated).

- Prototype: read one old version's `.olean` files (v4.31.0) in Lean v4.34.1 — header, object
  graph, `ModuleData`, constants — and print every declaration's type. Hold the reader against
  Lean's own answer (D10 mechanism 2) on that one version.
- **Expected**: reading is I/O-bound and well under the extraction it replaces.
- **Wrong if**: one version takes more than ≈ 10 min end to end; then 11 versions do not fit 2 h,
  and reading only what a page needs (constants and a few extensions, not every object) becomes
  a requirement.

**Answered 2026-10-04** (measured → `benchmarks/results/olean-reader-prototype-2026-10-04.txt`; a
prototype in a scratch project, Lean v4.34.1 reading Mathlib v4.31.0 with all its packages and
Lean core v4.31.0):

- **The reader reads correctly**: 5,000 of 5,000 sampled types serialize byte-identically to what
  v4.31.0 itself wrote, and every stored hash it decoded recomputes (11.4 M name hashes, 131 M
  expression data words); a corrupted copy stops the run naming the object.
- **Reading is not the cost**: the whole closure (10,583 modules, 7.0 GB, all three files per
  module) in 0.80 min median (0.41 min with proofs skipped), one module held at a time (206 MB
  peak). Cold and warm could not be separated on this machine; a cold start after reboot is not
  measured.
- **The hybrid works, and it is the design**: the decoded old data is assembled into an
  environment of the newest Lean, with the newest Mathlib's code (delaborators, notation) on top.
  - Alone, the old environment answered all 16 name-keyed lookups U8 flagged as v4.31.0 does, on
    all 5,000 declarations — so the ~30 lookups need no re-implementation.
  - Printing in the hybrid: **98.60% identical** to v4.31.0's own print (95% interval
    98.24–98.89), against 97.56% with lookups going to the newest constants. Fully explicit `@`
    applications 28 → 0; "failed to pretty print" 11 → 0. What remains is notation the newest
    Mathlib prints differently for the same term (`setOf` 45, `↧` 16, 9 others).
  - Two rules, both found by failing first: the newest code needs the newest data about its own
    vocabulary (dropping the newest class entries made 7 of 20 types unprintable); "does this name
    exist" and "which module" are answered from the decoded old data (in the hybrid, 136 module
    answers and 6 stored-equation lookups came back as the newest version's). Merging extension
    data must be by name, not by replacing constants alone.
- **Per version end to end ≈ 8.8 min** (theoretical: ≈ 2.1 min to read and assemble, measured;
  ≈ 6.7 min to print 311,415 types at 1.29 ms each, extrapolated). Under the ≈ 10 min line, but
  printing is what fills it — 11 versions ≈ 97 min of the 2 h budget, single-threaded.

### U10 — How small can the per-version part be?

Once declaration content is shared (U3), the per-version part is what grows with versions: the
manifest, own positions, dependency link targets, and the global files (Used by, name map, search
index, instances). The U6 sizing stored each of them whole per version, and Used by alone was 10.3
of the 15.3 MB. A theoretical lower bound (2026-10-05) put 11 versions at ≈ 54 MB and 51 at
≈ 92 MB, assuming each per-version part changes in proportion to the declarations that changed
(≈ 3% per minor release) — unmeasured for Used by and the global files.

- Measure on one minor pair (v4.32.2 → v4.33.0) and one patch pair (v4.33.0 → v4.33.1): the size of
  each per-version part whole and as a delta against the previous version, and the content-addressed
  store's growth, with and without Used by.
- **Wrong if**: Used by or the manifest changes far more than the declarations do — then storing
  them as deltas does not pay, and dropping Used by becomes the lever.

## Decisions to make

### D1 — The version set (decided 2026-10-04, user's call — with one open part)

Non-prerelease releases on the Releases page: 11 today. **Open**: what to do with a release U1
cannot build for — fix the extractor, or drop that version and say so on the site.

### D1b — Dependency documentation: out (decided 2026-10-04, user's call)

Mathlib only, as for every litedoc4 site: Lean core, Batteries, Aesop and the rest are not
documented, and a reference to them links to that dependency's version-pinned source. Every number
above is already `--lib Mathlib` only.

The consequence is a design item, not a further decision: **those links carry the dependency's
revision, and every release moves Lean core's**, so a signature that mentions `Nat` or `Eq` changes
between releases even when nothing in Mathlib did. U3 counts it; D5 has to keep the revision out of
the shared content. Links to a dependency's documentation site instead of its source do not avoid
this — that site is built from one revision only, so for older versions it would answer for the
wrong one.

### D2 — The budgets (decided 2026-10-04, user's call)

- **Build**: all versions from nothing in ≤ 2 h on one machine; adding one new release in ≤ 15 min.
- **Hosting**: whatever U6's chosen host allows, with headroom for 2 years of releases (≈ 40 more
  versions at the current rate (extrapolated)). The budget has to hold for the growth, not only for
  today's 11.

### D3 — Build host and hosting target

Where the one build runs (this machine, a GitHub runner, something else) and where the site is
served. Bound by U5 and U6. **A deploy that cannot finish inside the host's limits (GitHub Pages:
10 minutes) is a failure even if the build succeeds.**

### D4 — Page representation

| Option | Hosted size grows with | Gives up |
|---|---|---|
| Static HTML per version, deduplicated only in the build's storage | versions × pages | nothing for readers; does not fit hosting (≈ 12 GB) |
| Static HTML for the latest version, data + client render for older ones | 1 version + distinct content | no-JS reading of older versions |
| Thin HTML for all versions, content as shared data, client render | distinct content | no-JS reading of everything; first-paint time (U7) |

Bound by U3 (how much is shared), U4 (what the bytes are) and U7 (what the reader pays). Page
paths and anchors are part of the 1.x public surface (`tools/public-surface.txt`), but **this
milestone may be v2.0.0** (decided 2026-10-04, user's call): the design aims at what it should be,
and breaks the 1.x promise where that requires it.

**Reading without JavaScript may be given up, for every version** (decided 2026-10-04, user's
call). That leaves the third row open, and lets a page carry its signatures as data drawn in the
browser (U4). Still open: which of the three rows, after U3 and U7.

**How one version shrinks** (decided 2026-10-04, user's call), both from U4's measurements:

1. **Content is stored compressed and decompressed in the browser.** Pages compressed one by one
   are 19.6× smaller (measured → `benchmarks/results/mathlib-signature-shape-2026-10-04.txt`).
2. **Signatures are carried as data, not as HTML.** Text, one reference into a name table per link,
   one marker per binder kind; the browser builds the links and the markup. A link costs a few
   bytes instead of a full URL: one signature measured at 1,065 B of HTML for 58 B of text spends
   378 B on three links to Lean core source and 360 B on fifteen subterm wrappers
   (measured → `benchmarks/results/mathlib-signature-example-2026-10-04.txt`).
3. **Subterm wrapping is given up: no subterm structure is carried at all** (decided 2026-10-04,
   user's call). The wrappers are layout only — their one CSS rule makes a long signature wrap
   whole subterms with a hanging indent, and nothing else reads them. The browser cannot rebuild
   them from the text (the subterm tree is the pretty printer's). What the reader loses: a long
   signature wraps at any space, like prose, which reads worst on a narrow screen. 5,461,099 of
   the 10,285,239 wrappers (53.1%) wrapped a single token and did nothing anyway (measured →
   `benchmarks/results/mathlib-subterm-wrappers-2026-10-04.txt`). Single-version sites drop them
   too (D9: one rendering path).

### D5 — Unit and address of sharing

Per declaration, per module, or per fragment within a declaration; content-addressed by hash or
by (name, version range). Bound by U3: if most change is in a small part of a declaration (one
link), a finer unit pays; otherwise per declaration.

**Content-addressed** (decided 2026-10-05, user's call): a declaration's content is stored once and
found by a hash of the content itself, never by a chain of deltas between versions. What each
version holds is its manifest — which declarations each module has, in which order, with which
content hash — and its version-specific data (own positions, dependency revisions and line
ranges, Used by and the other global files). Still open: the unit (U3 points at the declaration,
with dependency links outside the hashed content) and how manifests and global files are stored
across versions (U10).

### D6 — URL scheme and the version switcher

**Every page's URL carries its version** — `/<version>/Mathlib/Foo/Bar.html#Foo.bar` — so a link
means the same thing forever, and **"latest" is not a URL at all** (decided 2026-10-04, user's
call). There is no `/latest/` tree. The site root is the one entry that resolves to the newest
version when opened; inside the site, a page of an older version says that a newer one exists and
switches to it.

**A site with no releases or tags uses commits as its versions** (decided 2026-10-04, user's call):
the version in the URL is the commit the site was built from.

**A build option for hash URLs** (decided 2026-10-05, user's call): `/#/<version>/Mathlib/Foo/Bar`,
served by one HTML file, for hosts that cannot answer every path with one page (GitHub Pages
returns 404, U6). It removes the per-page files — the file count that dominates every D4 row.
The cost is search: Google's guidance is "don't use fragments to load different page content"
and "use the History API" for client-side routing, because "Googlebot can't reliably resolve the
URLs" (JavaScript SEO basics, last updated 2026-03-04, read 2026-10-05), so under hash URLs only
the root page is reliably indexed. Path URLs stay the default where the host can rewrite. In hash
mode the fragment is the route, so a declaration anchor lives inside it and the page scrolls to it
itself (U7 already requires that of a script-drawn page).

Open:

- how many commits such a site keeps: a commit URL is fixed only for as long as its content is
  hosted, and a site rebuilt on every push adds a version per push;
- links into today's sites (`/Mathlib/Foo/Bar.html`): sent to the newest version — by the page
  itself, since a static host serves no redirects — or left to break under v2;
- which URL search engines are told is the page (one page exists once per version);
- what switching does on a page that does not exist in the other version (module renamed, split,
  deleted), and on an anchor whose declaration does not exist there.

### D7 — How a new release gets in

The goal says one build. Releases arrive every two to three weeks. Either rebuild everything each
time (simple, cost grows with the version count), or keep each version's IR or its layers and add
one version at a time (needs a store that persists between runs, and a way to know it is not
stale). Also: who fixes the extractor when a new Lean breaks it (U1), and what the site shows until
then.

### D8 — Which features to give up, and for which versions

From the table below, after U3 and U4 have put numbers on each line.

### D9 — Product feature or Mathlib-only pipeline

**A product feature** (decided 2026-10-04, user's call), and **one rendering path**: the reason is
fewer branches, so a single-version site is the one-version case of the same output, not a second
format. Consequences for every litedoc4 site, the single-version ones included:

- pages need JavaScript to read (D4);
- content is stored compressed, signatures are carried as data (D4, "How one version shrinks");
- long signatures wrap like prose — no subterm wrapping.

The surface it adds:

- **The version set can be given both ways** (decided 2026-10-04, user's call): as an explicit
  list, and as a rule (for Mathlib: the releases that are not prereleases).
- **How versions are passed — leaning to one command, not decided.** One `build` given the version
  set checks out each version, prepares its Lean and dependencies, builds the extractor against
  that Lean, extracts, and renders the whole site. The alternative is extraction per version as
  today plus one step that assembles N extractions into a site. One command is what a user wants
  to type; its cost is that the product takes over toolchain installs and dependency fetching per
  version, which for a package without Mathlib's cache means building from source.
- **The check behind the page-path promise has to be replaced, not updated.** Today it is the 51
  frozen pages of `e2e/micro-expected`, compared byte for byte. Data drawn in the browser changes
  every byte, and those answers were minted by an implementation that left the tree, so they must
  not be re-minted from the new output (CLAUDE.md, "The removed trees"). What replaces it checks
  paths and anchors as a reader meets them: the list of page paths, and every anchor reached
  after the browser has drawn the page — including a `#name` link arriving from outside, which
  has to scroll once the content exists.

### D10 — Where Lean runs: printed signatures or signatures as written

An `.olean` is readable only by the Lean that wrote it, but the deeper binding is what a page
shows: a signature is the declaration's elaborated type printed by Lean's pretty printer with
Mathlib's notation, and both are Lean programs that run only inside that Lean. The extractor is
the one place this happens (one file depending on `Lean` alone); everything after the IR is
version-free. The options:

| Option | Lean at documentation time | What is lost |
|---|---|---|
| Extractor per Lean version (today), kept as thin as possible | yes, one per version | nothing; a port when a Lean release breaks it (U1) |
| doc-gen4 as the per-version extractor (its maintainers port it) | yes | speed; a second extraction path |
| Own `.olean` reader in one Lean | no | a per-version branch wherever a decoded type changed (below); old versions print with the newest notation |
| Source as written, plus `.ilean` for links | no | below |

**What "as written" loses on Mathlib** (measured, heuristic →
`benchmarks/results/mathlib-source-vs-printed-2026-10-04.txt`, 311,415 declarations):

- **56,312 (18.1%) have no header text at all** — 42,672 generated by an attribute on another
  declaration (`to_additive` 16,926, `simps`/`simps!` 16,209, `reassoc` 3,852, …), 5,544 aliases,
  5,151 structure machinery. `.ilean` does not list them either.
- **201,737 of the 232,676 own-source declarations (86.7%) print binders their header does not
  write**, from `variable`; 1,081,171 of 1,570,497 printed binders (68.8%).
- **Only 33,570 (10.8%) would show the same binders as Lean prints.**
- `.ilean` would resolve every identifier of an as-written header to its constant — links are not
  the problem; missing declarations and missing binders are.

So "as written" is not a trimmed version of today's pages but a different product — a source
browser with links.

**Direction: an own `.olean` reader in one Lean, printing every version with the newest Lean and
Mathlib** (decided 2026-10-04, user's call). The reader's two jobs differ:

- **Reading** works, at the price of knowing each version's data layout (the object graph is
  stable; which field means what is not, and the module system has already split one `.olean`
  into `.olean` / `.olean.server` / `.olean.private`). The porting moves from API calls to binary
  layouts.
- **Printing faithfully cannot be done in one Lean**: Mathlib's notation is Lean code
  (`@[app_delab Finset.sum]` and 21 more written by hand, plus those `notation` generates),
  compiled against its own Lean's internals. Printing an old version with the newest printer is
  **an approximation, and it is accepted** (same call): right where notation and the constant's
  meaning did not change, off where they did. A declaration whose name exists in both versions
  with different types can only be looked up as the newest one.

**A misread must never be silent** — a layout change read as the old layout gives wrong data with
no error. The mechanisms, none of them written yet:

1. **Refuse an unknown version by name.** The `.olean` header carries the Lean version; a version
   with no known layout fails the build, as `tools/lean-toolchains.txt` already does for the
   extractor.
2. **Hold the reader against Lean's own answer, once per Lean version.** A small program run by
   that version's Lean dumps what it reads (names, kinds, a digest of each type); the reader's
   answer must equal it. This needs the toolchain only once per Lean release, not per build.
3. **Invariants on every build that a misread breaks**: every constant a type mentions exists;
   every type is well-formed in the newest Lean; the declaration list and ranges agree with the
   `.ilean` that the same Lean wrote beside each `.olean`.

**The cost of the reader is small** (measured →
`benchmarks/results/lean-olean-layout-history-2026-10-04.txt`; source diffs on all 10 adjacent
pairs v4.29.0 → v4.34.1, reflection on the 5 installed toolchains, v4.29/v4.30 by source only):

- **0 changes in 10 pairs** to the `.olean` header and object encoding, `ModuleData` and the
  three-file split, and `Name` / `Level` / `Expr` / every `ConstantInfo` (computed fields and
  hashes included).
- **3 of 10 pairs** changed something the reader interprets, **2** of them the shape of a decoded
  object (simp theorems gained a field in v4.31.0; in v4.33.0 the reducibility status gained a
  value and Verso docstring parts were restructured). The rest is extensions added or renamed.
  All 5 patch pairs changed nothing.
- **1 of 10 pairs changed a meaning without changing a shape** — v4.33.0's reducibility status,
  the value `tools/lean-toolchains.txt` already records. This is the silent-misread kind
  mechanism 2 exists for.
- **A Verso docstring's custom blocks need a package's code to become text.** Their values are
  `Dynamic` (a value of a type the package defines), and since v4.33.0 turning one into Markdown
  runs a handler the package registered. The reader can walk the value but not render it alone.
  The way consistent with this direction is the newest version's handler, fed the old value
  rebuilt as the newest Lean's object of the same type (theoretical, unverified) — the old
  `.olean` carries that type's definition, so a changed type is detected rather than misread.
  **On the documented package it does not arise today** (measured →
  `benchmarks/results/mathlib-verso-docstrings-2026-10-04.txt`): Mathlib v4.34.1 has 0 Verso
  docstrings of 90,663 declaration and 12,887 module docstrings, and so does every other package
  it imports except core. Core's custom elements are core's own five types, each with a
  non-empty fallback text (0 empty of 1,766). Older Mathlib versions are not measured.
  **Verso docstrings are supported all the same** (decided 2026-10-04, user's call): Mathlib is
  in a compatibility phase and replacement is likely. The reader decodes the document types
  (core's, versioned like any other), renders a custom element with the newest handler, and
  falls back to its `content` when the newest version has no handler for its type or the type
  changed — counted, never silent. **Today's single-version output already misses Verso module
  docs**: declaration docstrings go through `findDocString?`, which renders Verso, but module docs
  are read with `getModuleDoc?` alone, which returns Markdown ones only (read in the code, not
  reproduced on a package). Fixed in v2, not on 1.x (decided 2026-10-04, user's call).

**The cost of the approximation is small too** (extrapolated: 5,000 of 311,415 Mathlib v4.31.0
declarations, 1.61%, seeded; each type printed by v4.31.0 and, rebuilt verbatim, by v4.34.1 with
plain `ppExpr` and a perfect reader assumed →
`benchmarks/results/mathlib-printer-drift-2026-10-04.txt`):

- **97.56% print the same text** (95% interval 97.09–97.95). 2.22% differ, led by one rename (45
  of 111: `setOf` became an alias of `Set.ofPred`, so `{x | p}` prints as `setOf fun x => p`),
  then fully explicit `@` applications (28) and a notation v4.31.0 did not have (16).
- **0.22% fail to print, and the failure is silent**: `ppExpr` returns the text "failed to pretty
  print expression" as if it were the type. All 11 mention a constant v4.34.1 removed. A
  publisher that does not check for it ships that text as the signature.
- **7.76% mention at least one constant the newest version does not have**, and 91% of those still
  print the same (mostly instances the printer hides). So mechanism 3's "every constant a type
  mentions exists" cannot be checked against the newest environment as written — it must hold
  within the version being read, and a missing constant in the newest one is a printing input,
  not a misread.
- **18.66% of declarations have the same name with a different type in v4.34.1**, and 0.78% have
  no such name. The lookup clause above is not a corner case.
- Only the pair v4.31.0 → v4.34.1 (3 minor releases apart) is measured. Drift for v4.29 / v4.30
  (5 apart) is unmeasured and is not extrapolated from this.

## Features that could be given up

Each line is a candidate, not a decision. The cost column is the reason it is expensive across
versions; U3 and U4 put a number on each.

| Feature | Why it costs across versions | Options |
|---|---|---|
| Source link with line range, pinned to the commit | different in every version for every declaration; line ranges move whenever anything above the declaration moves | per-version prefix stored once and joined in the page; file-level link only; latest only |
| Used by | collected from all of Mathlib; a new use anywhere changes the page of the used declaration; 10.3 of the 15.3 MB each version carries compressed (U6) | latest only; per-version reverse index loaded on demand; **dropped entirely** (a candidate, user's 2026-10-05) |
| Instances / instances for | same shape as Used by | latest only; on demand |
| Search | one index per version (5.1 MB each) | latest only; per-version index loaded when that version is selected |
| Docstring link resolution | depends on the whole name set of the version | resolve against latest; keep per version |
| Equations | large, rarely read (58,426 per version) | latest only; on demand |
| Static HTML that reads without JavaScript | the main reason hosted size scales with the number of versions | latest only (D4) |
| Wrapping a long signature by subterm, with a hanging indent | 10.3 M wrappers on module pages (signatures, equations, fields) — the structure a signature carries beyond its text and links; 53.1% wrap one token and do nothing | **dropped, every version** (decided 2026-10-04, user's call) |
| Bibliography page | per version, small | keep |

## Out of scope

- Every Mathlib commit (the 35,178-commit history). This milestone is the releases only.
- Prereleases (`-rc` releases on the Releases page).
- Stable tags that have no Releases page entry (v4.0.0 – v4.28.x).
- Byte compatibility with doc-gen4.

## Phases

1. **Feasibility of the parts.** U2 (oleans of the 11), U4 (what one version's bytes are), U6
   (hosting numbers), U5 (the build host). All cheap; none needs a new extractor.
2. **Sharing.** U3 on the two supported pairs, with the non-determinism check.
3. **The version set.** U1 on the 7 toolchains. v4.34.x is required; v4.29 / v4.30 decide D1's
   open part.
4. **Decide.** D2 – D9, with the numbers from phases 1 – 3. Record each in this file.
5. **Prototype on 3 versions.** The multi-version render on v4.32.2 / v4.33.0 / v4.33.1; measure
   build time, hosted size and file count against D2.
6. **All versions.** The full set, deployed to the chosen host, with the way a new release gets in
   (D7) running in CI.

**Done** means: one command builds every version in the set within D2's build budget; the result
is hosted within D2's hosting budget; a reader can switch version on any page; and a gate checks
that every version in the set was built and served — reporting `<built> of <declared>` and failing
when they differ, and made to fail once before it is trusted.
