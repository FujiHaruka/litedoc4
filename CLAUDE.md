# litedoc4 project rules

A fast documentation generation platform for Lean packages that depend on Mathlib.
**All verification stages are complete** (`approach.md` §7, 1–8, plus the CI axis). **The migration
is complete too** — moving from the throwaway prototype (TS + shell) to the Rust product tree
`crates/` finished in M1–M8, and the prototype was **removed from HEAD on 2026-08-16**
(→ "The removed prototype" below).
**v0.1 was closed on 2026-08-17** — tag **`v0.1.0`**. The basis for closing it was only the
settlement of gates A / B, and **unverified items came down 18 → 13 → 3**.
**The substance is how they went down, not the count**:
18 → 15 was **classification and freshness**, 15 → 13 was **2 items actually killed**, and
**neither was unverified — both were broken** (the dead link to a dependency that cannot be
version-pinned, and a real run on `batteries` →
`benchmarks/results/batteries-2026-08-17.txt`). **13 → 3 was the full inventory on 2026-08-18** —
**5 items were settled by measurement** (U1–U5), **4 were "not actually unverified" and were moved
to decisions and spec judgements**, and **2 were closed**. **The list is not restored**
(decided, user's call) — the numbered references rotted before the list did.
The old lists are `git show e744f79^:README.md` (the 13-item version) /
`git show 117e928:README.md` (the 18-item version).
**And separately from the count going down, 1 item was added and closed the same day** — U5
measured that **the extractor does not build on Lean v4.33.0**, and **it was fixed to build on
3 versions (v4.31.0/v4.32.2/v4.33.0)** (→ `benchmarks/results/lean-433-fix-2026-08-18.txt`).
**The fix is not branching on version** — enumeration was delegated to Lean's own `toAttrString`.
**Do not read the remaining 3 as "probably fine" either.**
**Do not write "v0.1" to mean "finished".**
The SoT for the approach is the 3 files `docs/approach*.md`; the SoT for the numbers is
`docs/verification-log.md`.
**The SoT for the implementation is the code** (decided 2026-08-24, user's call) — the 19
implementation plans, implementation logs, and completed planning documents were deleted the same
day. The definition of the gates is `tools/*-gate.sh` and `.github/workflows/`, the behaviour is
held by the code itself, and what comments hold is **only the non-obvious why not** (→ "Code
comments" below). To read the history, read git. **Do not restore docs.**

**On 2026-08-18 it was renamed from `lean-doc` to `litedoc4`** (decided, user's call) — the GitHub
repository, the crate, the CLI, and the Lake package name, all of them. `litedoc` was not chosen
because of **a measured collision** (a Python documentation generator in the same category occupies
PyPI and the CLI name `litedoc`, the Rust `litedoc-core` / `litedoc-cli` actually exist on
crates.io, and a 153★ PDF→Markdown converter is the top search hit). `litedoc4` was free on
crates.io / npm / PyPI / GitHub search alike.
**There are 6 categories where the prototype-era name is deliberately kept. Do not read them as
"forgot to delete" and fix them**:

1. **`benchmarks/results/**`** — raw logs. Do not rewrite past measurements
2. **`crates/*/tests/data/**` (14 files)** — frozen fixtures. The paths at generation time are
   baked in, and **there is no way to regenerate them in HEAD**. The
   `git show experiments-frozen:crates/lean-doc-*/…` in `PROVENANCE.md` is **a real path inside the tag**, and renaming makes it stop resolving
3. **The string `lean-doc-relay`** — the gates' work area `/private/tmp/lean-doc-relay/<stage>`.
   It is in the frozen fixtures as the path at generation time, and **the default path of
   `litedoc4_testutil::corpus` has to match it**
4. **`lean-doc/experiments/stage4b` / `stage4c` (6 files)** — **real identifiers** that the
   prototype wrote into the IR's `generator`. The `assert_ne!` in `ledger.rs` checks that "the
   current ID differs from these", and rewriting it makes it **a meaningless check against a
   string that does not exist**.
   `extractor/Extract.lean` still writes this value. **It was once replaced by mistake and restored**
5. **The asset names `lean-doc-*.tar.gz` in tags `v0.1.0`–`v0.1.3`** — names that really exist on the existing Releases
6. **The `phase` keys `stage4b.*` / `stage1.*` / `stage2.*` / `stage3.*` in the timing JSONL**
   (confirmed 2026-08-24) — **live wire-format identifiers**. `extractor/Extract.lean` writes
   `sink.emit "stage4b.<phase>"` in **16 places**, `benchmarks/tools/analyze.ts` aggregates using
   `stage1.`–`stage3.` as prefixes, and `benchmarks/tools/measure-link-index.sh` strips
   `"stage4b."`. **If you read them as "prototype-derived, therefore dead" and delete them, the
   aggregation returns 0 rows rather than an error** — the silently-broken shape

A bulk replace does not distinguish "identifiers going forward" from "proper nouns pointing at
things that really exist outside".

## v1.0.0 — what is promised, and what that costs to keep

**`v1.0.0` was tagged on 2026-08-29.** The basis was not a feature list: it was
**"someone other than the author can keep using it without the author"**, which turned into four
promises, each with a gate. **Do not read v1 as "finished" any more than v0.1 meant it.**

- **The 1.x surface is `tools/public-surface.txt`** — the action's inputs and outputs,
  `litedoc4.toml`'s keys, `build`'s and `watch`'s flags, and the site's page paths and anchors.
  **The rule that decides membership is "can it appear in a file someone else maintains".**
  `tools/public-surface-gate.sh` (run by `ci.yml`) fails when a promised name goes missing.
  **The IR schema, the ledger and `.lidx` are internal** — a consumer pins one ref and the action
  and the Lake script resolve the binary by the version in *that* ref, so the two halves always
  come from the same tree. Checks are **one-directional on purpose** (adding breaks nobody;
  removing and renaming do); `action.yml` is checked both ways because it is plain data.
- **The Lean versions are `tools/lean-toolchains.txt`**, and that file is also the matrix
  `ci-lean-versions.yml` runs — **read from the file, so two lists cannot drift**. Column 2 is the
  one thing that legitimately moves between toolchains (Lean's rename of a reducible instance's
  reducibility status). **A toolchain with no row fails by name**; a row marked `UNMEASURED`
  fails *carrying the value to write down*. **Do not branch on the version** — the extractor
  delegates enumeration to Lean's own `toAttrString`, and this file records the consequence.
- **Releases carry three triples**, and four places decide whether a machine has an asset:
  `release.yml`'s matrix, `lakefile.lean`'s `releaseTargets`, `action.yml`'s
  `RUNNER_OS-$(uname -m)` case, and `tools/lake-download-gate.sh`'s. Adding one means all four.
  `ci.yml` also builds and tests on **aarch64 Linux** — not for the binary but because `c_char` is
  unsigned there and signed everywhere else the tree had been compiled, and because that is the
  architecture nothing had ever run. **Both defects it found the first time were waiting**
  (measured 2026-08-29 → `benchmarks/results/arm64-linux-runner-2026-08-29.txt`).
- **The release notes are `.github/release-notes.md`**, published by `release.yml` with `@VERSION@`
  substituted. **Do not edit the notes on the Releases page** — the next release republishes the
  file, and a hand edit is a change nobody reviewed. `tools/release-notes-gate.sh` reconciles the
  archives they list against the ones the publish job asserts and their Lean versions against
  `tools/lean-toolchains.txt`, in both directions.
- **Two example sites, and one of them is a maintenance obligation.**
  `https://fujiharuka.github.io/litedoc4/` is `e2e/micro` rebuilt from `main` on every push
  (`pages.yml`, downstream of `tools/e2e-micro.sh`, so a site that failed its gates is never
  served). `https://fujiharuka.github.io/information-theory/` is the real-scale one, and it is
  built by **whatever litedoc4 the target repository pins**. **Bump that pin on every release** —
  it was left at `v0.1.4` for eleven days while the README described features the deployed site
  did not have (measured 2026-08-29: `Used by` 0 occurrences before, 21 after).

**This repository is public** (changed from private on 2026-08-16 (decided, user's call) — the
reason is to run GitHub Actions on the free tier). The measurement target `lean-projects` is public
too.
**Treat everything you write as published** — including docs, commit messages, and handoffs.
**The history and the tags are public too** (→ "The removed prototype" below).

## Repository layout

| | |
|---|---|
| `docs/approach.md` | Approach plan §1–4 / §7–10. **The SoT for the approach is the union of this and the 2 below**. Do not write implementation-level detail here |
| `docs/approach-pillars.md` | Same, **§5 Design pillars** (5.1–5.6). Split out on 2026-08-18. **Section numbers stay as they were before the split** |
| `docs/approach-performance.md` | Same, **§6 Performance** (6.1–6.6). Ditto. There is a mapping table at the end of `approach.md` |
| `docs/verification-log.md` | **Results of the verification stages (approach.md §7, 1–8)**. **If they disagree with the prediction, this is the SoT** |
| `docs/provenance.md` | Provenance determination for doc-gen4 / third-party code and the resulting licensing obligations. **The SoT for provenance determination** |
| `benchmarks/` | Measurement reports, instrumentation patch, tools, raw logs. **Where the numbers come from** |
| `crates/` | **Product code (Rust). The SoT for the implementation.** Comments are only the non-obvious why not |
| `e2e/micro/` | **e2e fixtures** — a Lean package that does not depend on Mathlib. It holds, by construction, **the declaration shapes the target does not have** (→ `e2e/README.md`) |
| `tools/*-gate.sh` | **Gates** = judgements that require hardware, the target, or a toolchain. `cargo test` holds only what depends on zero hardware |
| `.claude/handoff.md` | Handoff between sessions (tracked, committed) |

Lean-side builds borrow the environment of the measurement target repository via `lake env` —
**no toolchain and no Mathlib live on the litedoc4 side**.

**The Rust side builds with `cargo build` + node** (Rust 1.97.1 / rustup; node is pinned to
24.19.0 by `mise.toml`). **Until 2026-08-19 it was "complete with `cargo build` alone"**
(decided 2026-08-19, user's call) — because the site's JS became
TypeScript and `crates/litedoc4-render/build.rs` came to run vite and bake `app.js` into
`OUT_DIR`. **The artefact is not in the repository.**
**Users do not pay for node** — the workspace is `publish = false`, and distribution is the musl
binaries that `release.yml` bakes. The ones who pay are those who build from source, i.e.
developers and CI (which is why every workflow that runs cargo, and the cargo path in
`action.yml`, has `setup-node` — **`tools/workflow-gate.sh` checks that rule rather than a count**;
the count was written down as 8, corrected to 7 and made 9 by two new workflows on the same day).
**There is no fallback.** If node is absent, `build.rs` fails — "build it if it is there, use the
committed one if not" makes 2 paths, so it is not taken.

**`lakefile.lean` is kept** (2026-08-18) — so that users can use it with
`require «litedoc4»`. **`lean-toolchain` is not kept, and this got stronger**:
if the dependency side has a `lean-toolchain` with a higher version than the root,
**`lake update` rewrites the user's `lean-toolchain`**; if lower, **it is silently ignored with not
even a warning** (measured →
`benchmarks/results/lake-package-probe-2026-08-18.txt` §1). **If it is not there, Lake says nothing
and uses the root's toolchain.** The price is that "`lake` does not run in litedoc4's own
directory", so `lake-manifest.json` is hand-written and builds always come from the user's
workspace side.

### The removed prototype — tag `experiments-frozen`

The throwaway prototype for verification stages 1–8 (`experiments/`, 27 directories / 164 files)
was **deleted from HEAD on 2026-08-16** (decided, user's call). **It remains in the history** —
the last commit where `experiments/` was complete (`a15addc`) is tagged **`experiments-frozen`**,
and it can be read from there:

```
git show experiments-frozen:experiments/stage7d/render.ts
git log experiments-frozen -- experiments/
```

- **Every place where docs point at `experiments/...` as the source of a number carries this tag.**
  Do not write `experiments/` without the tag (it would point at a path that is not in HEAD)
- **What disappeared is the scorer, not the numbers.** The committed fixtures
  (`crates/*/tests/data/*-expected.json`) remain as frozen values, and `cargo test` is untouched.
  But **there is no way to regenerate them in HEAD** — to rebuild them, restore the generator from the tag
- **The history is not rewritten.** Since the repository became public (2026-08-16),
  **the 164 files of `experiments/` really can be read via the tag**. This is a knowing decision:
  the reason for the removal is policy, not legal — no additional licensing obligation arises
  (`docs/provenance.md` §8). Operate on the fact that **"not showing it" is not satisfied**

**The extractor is Lean; everything outside it (IR consumption, rendering, incremental, search
index) is Rust** (decided 2026-08-11 → plan §5.6). **The reason for the choice is not speed** —
the speed difference on the outside is decided not by the language but by **the number of full IR
reads** (verification log). **Do not write "it is fast because it is Rust".** The multipliers in
§6.4 come from "stopping work that did not need doing", and tying language and speed together
causally is overstatement.

## Benchmarks

**The measurement target is always `/Users/haruka/dev/lean-projects`** (the Lean 4 + Mathlib
`InformationTheory` project, 432 modules, depending on all of Mathlib).

The target is fixed because **a comparison is only meaningful on the same workload**.
Every number in this repository was taken on this target, and the baseline already exists.
If you want to measure a different target, **add** it rather than replacing, and keep the existing numbers.

- The only thing touched for measurement is the target repository's `.lake/packages/doc-gen4`
  (gitignored). **Do not commit to the target repository.**
- Instrumentation is `benchmarks/doc-gen4-instrumentation.patch`. `.lake` is wiped by
  `lake update`, so if it is gone, re-apply it with `benchmarks/tools/apply-instrumentation.sh`.
  Checking whether it is applied is `--check` on the same script.
- Raw logs (JSONL) are committed to `benchmarks/results/`. Aggregation is `tools/analyze.ts`.
- **Record the measurement conditions every time** — hardware / versions of Lean, Mathlib and
  doc-gen4 / whether the oleans are warm / page cache / parallelism. This workload in particular is
  **memory-bound, not CPU-bound**, so without the amount of RAM and the parallelism the numbers
  cannot be read.
- **Do not trust a number measured only once.** Oleans are read via mmap, so environment loading
  moves by 5× depending on the state of the page cache (measured 2.5s ↔ 13s). **Run the same
  measurement 5 or more times in a row, watch it converge, and record both the cold side and the
  warm side.** If wall clock ≒ CPU time (user+sys), it is warm.
  Put `/usr/bin/time -l` in front and keep CPU time, peak RSS, and page faults.
- **Do not mix cold and warm in a comparison.** When comparing approaches, re-measure in the same
  session in the same warm state. Putting an old number next to a new one is allowed only when the
  conditions have been confirmed to match.
- Run long measurements in the background (do not use a foreground `sleep`).
- **Delete the work directory when a measurement finishes. Decide who does the cleaning up.**
  Gates use `/private/tmp/lean-doc-relay/<stage>` as their work area (**this path keeps the old name even after the rename** —
  it is baked into the frozen fixtures as the path at generation time, and the default path of
  `litedoc4_testutil::corpus` has to match it → "the 6 categories where the old name is kept"
  above). All of them are written on the assumption that they "can be regenerated", but
  **nobody deletes them, so they pile up**. On 2026-08-17, 5 generations' worth piled up to
  **24 GB**, the disk filled, and **an interrupted `lake build` left one of the target's oleans
  missing** (measured). **When the disk runs out, the damage is not limited to a failed
  measurement** — the target repository's state breaks, shell commands themselves stop working,
  and the means of recovery is lost too.
  One site is about 60 MB; the package from `make-target2.sh` is several GB.

## Measurement honesty

The deliverable of this project is numbers, so **managing where the numbers come from is quality
itself**. Every number written in docs carries one of the following 4 labels:

| Label | Meaning | Obligation |
|---|---|---|
| **(measured)** | there is a log | the path to the log must be followable (**`tools/docs-gate.sh`** checks every cited `benchmarks/results/<file>`) |
| **(extrapolated)** | extended from part of a measurement | write what fraction was measured |
| **(assumed)** | no basis | state it as an assumption and turn it into a verification item |
| **(theoretical)** | a composition of the above | list the premises and write "unverified" |

- **Do not write a number with the label dropped.** Deleting only the label while compressing or summarising is the worst decay.
- **Do not write a measurement that did not run to completion as if it did** (the full build is cut off at 42%).
- **State the denominator of a multiplier.** "43× for the same amount of work" and "1,251× for
  building a site from zero" are different claims, and most of the latter is the difference in
  scope of work, not the skill of the implementation. Mixing them makes it overstatement.
- **Doubt a number most when it comes out in your own favour.** Mistaking a unit, an aggregation,
  or the measurement target gets overlooked when it comes out in the convenient direction.
- When you update a number, fix the docs that quote it in the same commit.
- **Do not read "unverified" as "probably fine".** 4 unverified items in the README were killed and
  **3 of them actually turned up defects** (measured 2026-08-17). What has not been measured is
  just as likely not to work, and **the unverified items are not a list of "work remaining" but a
  list of "defects not yet known"**.
  **5 were measured on 2026-08-18 and another one turned up** — the extractor does not build on Lean v4.33.0.
- **Doubt items that say "we do not have the hardware".** Of the 5 killed on 2026-08-18, **2 were
  not a lack of hardware but a failure to use the hardware we have** (measured) — the Windows
  monospace font (`windows-latest` has both Consolas and Chrome) and LeakSanitizer (which runs on
  `ubuntu-latest`). Q8 recorded the same failure on Linux on 2026-08-17. **The CI runners of a
  public repository are hardware for 3 OSes**, and "not here" is only "not on this machine".
- **The "not yet" in docs rots.** On the same day, `cargo-deny` was green in CI while still marked
  "not yet" (measured). Before killing an item, **first check the current state** — the work may already be done.

## Quality gates

**doc-gen4 compatibility (byte reproduction) is not pursued** — it ended at M8 and is not
redefined. What was put in its place is **3 kinds that need no external oracle**:
**self-consistency** (whether the output closes over itself) /
**invariants** (whether a different path gives the same answer) / **Lean itself**.
**These 3 are the definition of "green"**, and their substance is
`cargo test --workspace`, `tools/*-gate.sh`, and `.github/workflows/`.

- **Separate "tests" from "gates". Make the boundary coincide with CI's boundary.**
  A test **holds its own input and depends on zero hardware**, and `cargo test --workspace` is the
  definition of green.
  A gate requires hardware, the target, or a toolchain, and lives in `tools/*-gate.sh`.
  **The gates have an inventory of their own** — `tools/gates.txt`, checked in both directions by
  `tools/workflow-gate.sh`, which also verifies that a row marked `ci` is really reached from a
  workflow and one marked `manual` is really not. Without it, `build-gate.sh` sat for months as a
  gate nobody had ever run (measured 2026-08-29)
  **Anything that reads the target repository is not a test** — anything that breaks when the target moves is by definition not a test
- **Never return green by skipping.** A test with no input is made `#[ignore]` and listed in
  `tools/corpus-tests.txt` (CI looks at the difference in both directions with `--verify-list`).
  **`eprintln!("skipping: …") + return` does not show up in the exit code** —
  this actually made **7 of them "green while the fixture was gone"** (measured 2026-08-16)
- **Gates count "how many ran".** The general form of the above, and **3 more variants turned up on the same day** (measured):
  the gate stripped the module path from the test name so `--exact` matched 0 (**cargo exits 0 even at 0 matches**) /
  there was no `--no-fail-fast` so a red one hid the rest with the same name / the same name spanned frozen and runnable.
  **In all of them the output looks "correct".** The only thing that caught them was
  **reconciling the count in the inventory against the count that actually reported a result**
- **A bare program name in a test is `PATH`, not a path.** Three unit tests passed
  `Path::new("lake-that-does-not-exist")` to mean "no Lean core"; the sibling `lean` derived from
  it has no directory in it, so `Command::new` resolved it on `PATH` and the tests read whichever
  toolchain the machine had. Green on every machine where elan has no **default** toolchain, red
  on one that has (measured 2026-08-29). `cargo test --workspace` is the definition of green, so a
  test that reads the environment moves the definition. The helper that gets this right is
  `litedoc4_testutil::toolchain::lake_that_is_not_there`
- **Do not judge input identity by "path".** A design of "check up to the denominator if it is the
  default path, structure only for another file" **silently changes the strength of the claim the
  moment something else is put at the default path** (measured 2026-08-16,
  `link_index_fixture`). If you claim identity, **judge it by content** (digest / generation conditions)
- **Do not gate performance on wall clock.** It moves by 5× with the page cache.
  What gates use is **deterministic integers** (re-extraction count / rendered page count / IR read count / process spawn count)
- **Do not rewrite an oracle in the same language with the same design** (it creates a path where
  both make the same mistake). This is why the site check is still Python
- **Never build a comparator with an exception list.** It silently swallows the second divergence
- **Do not add a gate that cannot say in one line what broke when it fails.** Do not make the count a goal
- **A gate does not check itself.** A new gate is **always made to fail once** before it is allowed to pass
  (on the day they were made, 2 "gates that pass no matter what" were built (measured))
- **Confirm a gate's checked scope with a number.** "Ran it" and "watching it" are different.
  `cargo-fuzz`'s `-Zsanitizer=address` goes through `RUSTFLAGS`, so **it only reaches Rust and the
  C that `build.rs` bakes goes straight through** — passing `CFLAGS` moved cov **1023 → 2487** under identical conditions
  (measured 2026-08-17). **Whether the number moves with and without instrumentation** is the only means of confirmation
- **Do not use a subset of the gates as the judgement for a commit.** (measured 2026-08-24, turned main red twice)
  When the "fast 5 stages" (without `cargo test`) were used as the judgement during comment
  reduction, nobody saw that the reduction had stepped into **string literals the product prints**.
  Dropping `(coverage.ts:512)` from a rejection message made **2 asserts in another crate's `tests/`** fail.
  Verification instructions given to subagents are also **`cargo test -p <crate>`** — **`--lib` does not look at `tests/`**.
  General form: **first confirm that the gate used for the judgement covers the whole range the change can reach.**
- **Before "measured", confirm "is it in a state where it can be measured".** The same failure
  turned up in 2 more shapes (measured 2026-08-18): (1) the incremental gate **looked for
  `pagesRendered` under a guessed name**, the file it was looking at did not have that key, and it
  was **green having checked nothing** → make it emit the real output once, then write the key.
  (2) the toolchain-mismatch check returned green saying "it was rejected", but **extract had not
  even started — it was failing in lake's package resolution** → before reading a non-zero exit as
  the answer, **confirm in a separate step that the environment can even be built**
- **A diff that fails in both directions at once is the comparator's fault, not the target's.**
  If index → page and page → index disagree on the same name at once, that is not "the site is
  inconsistent" but "**the character sets being compared differ**".
  It was actually just not unescaping the `id` attribute (measured 2026-08-17)

## Rust lints

**The SoT for lint configuration is `[workspace.lints]` in the root `Cargo.toml`.** CI's
`cargo clippy -- -D warnings` **only promotes** — which lints are enabled is decided by
Cargo.toml. This is deliberate, so that **the local `cargo check` and CI
say the same thing**. Do not add `-W` to CI's command line
(it becomes a gate invisible from local).

- **Do not take a whole group.** `clippy::pedantic` + `nursery` produce
  **about 1,800 hits** in this tree (measured 2026-08-17), but most of them are doc lints for
  crates that are not published (`missing_errors_doc`, `must_use_candidate`) and matters of taste
  (`option_if_let_else`, `too_many_lines`). **35 were adopted** (6 of them deny).
  Taking the group and allowing 400 is the same failure as "a comparator with an exception list"
- **The criterion is "if it fires, can you say in one line what broke".** If you cannot, do not take it.
  In fact `missing_debug_implementations` / `trivially_copy_pass_by_ref` /
  `unreadable_literal` / `assigning_clones` / `unused_self` /
  `iter_on_single_items` were **taken and then dropped again** —
  every hit was an FFI type, `&self`, Unicode's `0x10FFFF`, or a `to_owned()` in a test,
  and "broken" could not be said. **The reasons for dropping them are kept in Cargo.toml**
  (so the same investigation is not redone at every reconsideration)
- **Do not write `#[allow]`. Write `#[expect(..., reason = "...")]`.**
  `allow_attributes` / `allow_attributes_without_reason` enforce it mechanically
  (both warn → error in CI. **Confirmed that a single `#[allow]` without a reason makes it fail**).
  The point of `#[expect]` is that **it warns when the lint stops firing** —
  this is exactly how `#![allow(non_camel_case_types)]` in `litedoc4-md/src/ffi.rs` turned out to be
  **no longer needed** and was deleted (measured 2026-08-17). `#[allow]` rots silently
- **Re-wrapping a doc comment makes `clippy::doc_lazy_continuation` fail** (measured 2026-08-24) —
  a continuation line whose head becomes `+` / `-` is read as a list item. **It does not show up in
  `cargo check`**, so when you touch comments, run `cargo clippy --workspace --all-targets`.
- **Do not trust the result of `cargo clippy --fix` without reading it.** The auto-fix
  dropped a `needless_collect` and **broke the diagnostics on failure** (a path present in
  both maps is listed twice) (measured 2026-08-17). The tests pass —
  **that branch only runs when a test fails**

What CI holds besides lints: **rustdoc links**
(`cargo doc` + `RUSTDOCFLAGS=-D warnings`. **15** were broken the first time, and
2 pointed at renamed types (measured)) and **unused dependencies** (`cargo machete`.
`litedoc4` was declaring `litedoc4-md` without using it (measured)).

## Fixing defects

- **Ask every time whether the fix was raised to its general form.** The hole in the inference
  "root is not in the map ⇒ own package ⇒ relative link" was **stepped on twice on the same day**
  (measured 2026-08-17) —
  when the first one (a dependency that cannot be version-pinned) was fixed, **the fact that the
  same inference also exists on the own-package side** was not noticed, and it stayed invisible
  until a real package pointed it out.
  Once fixed, ask **"is this judgement made anywhere else?" and "does the same premise break on a different input?"**.
- **Collect the judgement in one place.** If there are 2 paths answering the same question, only one of them gets fixed.
- **A passing unit test does not mean that branch is correct.**
  "Reject an invalid rev" was checked, but **nothing looked at what gets rendered after it is rejected**.
  Check **not just the judgement at the entrance but all the way to where its consequence appears in the output**.

## Documentation hygiene

- **User-facing documentation (README, the descriptions in `action.yml`, release notes, site copy)
  writes only the final state** (decided 2026-08-19, user's call). **Do not write diffs, process, or history** —
  renames ("renamed from `lean-doc`"), version history ("before vX it was like this"),
  how something was discovered ("this was noticed when …"), abandoned options. **The criterion is
  "is there value in it for a reader with no context at all"**, and if there is not, delete it.
  The reasons are that these **assume a past the reader does not have**, and that
  **the past keeps growing, so left alone the body gets eroded by history**.
  - **The only exception is "a fact that changes what today's reader does"** — fold it into the
    form of **what to do now**, like "pin to `v0.1.4` or later". Do not write "because before the rename it was …".
  - **The provenance and conditions of a measurement are not process. Do not drop them** —
    hardware / versions / warmth / denominator /
    the (measured) / (extrapolated) / (assumed) / (theoretical) labels and the path to the log are
    part of the final state (→ "Measurement honesty" above).
  - **The reason behind a design decision is not process either** — for something like "we do not
    keep a `lean-toolchain`", which **the user meets in the behaviour today**, keep it together with its reason.
  - **The history is held by git.** Deleting it from the user-facing side is not throwing the record away.
- **Between docs too, do not point at a document expected to be completed and disappear as a SoT.**
  A reference to a deleted document is allowed only when the line says it was deleted;
  **`tools/docs-gate.sh`** enforces that. Pointers rot —
  docs disappear, section numbers move, and plans get folded away when completed.
- A planning document over 600 lines goes to `/compact-plan`. **Summarising and splitting are
  different means, and the default is not splitting** —
  but **`approach.md` chose splitting** (decided 2026-08-18, user's call). The reason is that
  §5 and §6 are **alive whole, section by section**, and summarising drops the
  (measured) / (extrapolated) / (assumed) labels and the premises first. **When splitting, do not
  renumber the sections** — the numbers are cited from
  docs and from the frozen logs in `benchmarks/results/`, and renumbering rots all of them at once.
  Leave a mapping table in the original file instead.
- **If the prediction and the result disagree, the result is the SoT.** Fix the plan side (do not do the reverse).
- The history of a settled choice may be deleted (git holds it). **Keep the hypothesis and the condition that would falsify it**
  — when that disappears, a plan degenerates into a mere to-do list.

## Code comments

- **The default is to write no comment** (decided 2026-08-24, user's call). What / how is said by the
  code. A comment that traces the code **silently becomes a lie when the code changes**.
- **When you feel a comment is needed, first read that as a design smell.** Try first to say the
  same thing with a name, a split, a type, or a data structure, and write it
  **only after confirming it does not fall out into a different design**.
  "It needs explaining" usually means "it has a structure that needs explaining".
- **The only thing allowed to be written is the non-obvious why not** — "why was the seemingly straightforward alternative not taken".
  Put it only where a reader would think "you could just write it like this", and write
  **the condition that falsifies it** (if this premise breaks, the straightforward one is fine) as well.

## Orchestration

- Dispatch investigation, implementation, and long measurements to subagents; run planning, verification, integration, and commits yourself.
- **At most 1 subagent running at a time.** Even when told "N in parallel", drop it to sequential
  (concurrent execution hits the usage limit and stops the whole session).
- Creative tasks (coming up with design options, breaking a deadlock) go to Fable;
  everything else (implementation, investigation, aggregation, auditing) goes to Opus. When in doubt, Opus.
- **Tell subagents explicitly "do not commit".** We verify here, then commit.

## Traps on this machine

**All of these were actually stepped on.** Do not copy them into the handoff every time — permanent facts live here.

- **ssh (port 22) does not get through from this machine.** Push is HTTPS + `gh`:
  ```
  GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
  GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='!gh auth git-credential' \
  git push https://github.com/FujiHaruka/litedoc4.git main:main
  ```
- **`diff` is aliased to `colordiff`, which does not exist. Use `/usr/bin/diff`.**
- **`rg`'s `-r` is `--replace`. Do not bundle it as `-rn`** (the following flag gets eaten as the replacement string).
- **Python 3.9's f-string cannot contain a backslash or a nested quote of the same kind.**
- **Do not use `git checkout <file>` for a disable experiment.** It has a track record of blowing away a subagent's implementation.
  Use a scratch copy or `git stash`.
- **After the browser gate, puppeteer sometimes stays holding port 8899** —
  if `AddrInUse` comes up, `pkill -f check-site-browser.ts`.
- **`litedoc4 watch` is long-lived, so it survives the session dying** (measured 2026-08-21).
  A `watch` from an interrupted session kept writing to the same `--out`, and
  `tools/watch-gate.sh` run afterwards **read a half-written IR and failed**
  (`EOF while parsing a value at line 1 column 0`) — then cleanup's `rm` failed with
  "Directory not empty" (because the other side keeps recreating what is being deleted).
  **The symptom looks like "the gate broke", but what is broken is the environment.**
  Before running a gate that starts a long-lived process, look at `pgrep -f 'litedoc4 watch'`.
  General form: **a long-lived process sharing a work area makes its failures look like the work area's fault.**
- **To take a measured CI value without turning main red: push a branch + `gh workflow run <wf> --ref <branch>`**
  — **a branch push starts nothing**: every `push:` trigger in the tree is limited to `main`, and
  `release.yml`'s to `v*` tags (measured 2026-08-29). **`pull_request:` does not filter**, so opening a PR does start `ci.yml`,
  `ci-action.yml`, `ci-lake.yml` and `ci-lean-versions.yml` (each behind its own `paths:`); the
  other nine are `workflow_dispatch` only. **`workflow_dispatch` needs the workflow to exist on the
  default branch** — a new one on a branch cannot be dispatched by name at all, and the way to run
  it is a `push:` trigger naming that branch.
- **The moment you put a pipe in, the exit code you are looking at is the last command's.**
  `litedoc4 build … | tail -25` **looks like 0 even when litedoc4 rejects and exits 3**
  (measured 2026-08-18, stepped on twice that day). Adding `| tail` to read the log is routine, so
  **when the exit code is used as a judgement, remove the pipe and redirect to a file**.
  `${PIPESTATUS[0]}` works in `tools/*.sh` (bash), but **this session's shell is zsh and has no
  `PIPESTATUS`** (in zsh it is `$pipestatus[1]`, 1-based) (measured 2026-08-19).
  Getting the spelling wrong makes **an empty string behave like `0`**, so removing the pipe is the sure thing. This is the version of "a shape where the output and the exit code disagree makes a gate a lie" above
  where the observing side is the one that gets it wrong.
- **The exit code of the last command in `trap … EXIT` becomes the script's exit code.**
  `cleanup() { [ -f "$F" ] && cp …; }` **returns 1** when `$F` is absent.
  `tools/e2e-micro.sh` actually **printed "E2E MICRO: ok" and exited 1**
  (measured 2026-08-18) (it never fired because CI always calls it with `--out … --keep`).
  Write it with `if`, not `&&`. **A shape where "the output and the exit code disagree" makes a gate a lie.**
- **When building C++, the Command Line Tools' `usr/include/c++/v1` has no headers** —
  `CXXFLAGS="-isystem $(xcrun --show-sdk-path)/usr/include/c++/v1"` is required.
- **`node` / `npm` on PATH are dead.** `/usr/local/bin/node` is a 2023 pkg build whose
  signature is invalid, so it **dies instantly with SIGKILL (exit 137)** (measured 2026-08-19). And
  `command -v node` succeeds while `node -v` fails **printing nothing**, so through a pipe it looks
  like "empty output". `cargo build` calls npm from build.rs, so **it hits this**.
  For the same reason **`tools/assets-gate.sh` is called through `mise exec --`** (measured 2026-08-21) —
  it hits `npx biome` directly inside, so calling it bare gives **exit 137 (SIGKILL)** and
  the output says nothing about assets. CI is green because the job has `setup-node`.
  Use the mise side: **`mise exec -- cargo build`** / `mise exec -- npm …`
  (`mise.toml` pins node). `mise` is a shell function and does not rewrite
  PATH in a non-interactive shell — which is why `mise exec` is stated explicitly.
- **Editing a shell script while it is running breaks that run** (measured 2026-08-24) —
  bash reads the script forward by byte offset, so editing the file while it is executing makes it
  **read a different position from partway through**. Fixing a verification script while it was running produced
  `line 24: eps: command not found`. Finish editing a file before running a long verification with it.
- **Writing a comment in `biome.json` makes biome silently discard the whole config and run with defaults**
  (measured 2026-08-19). No error, no warning, and **the exit code is 0**. The symptom is
  "every file is formatted with tabs even though `indentStyle: "space"` is written".
  If you want to write comments, use **`biome.jsonc`** (it is decided by the extension).
  This too is a shape where "the output and the exit code disagree".

## Commits

- Commit and push autonomously. Do not report it to the user.
- Messages are one line, short.

## Language

- Everything is English: docs, commit messages, and code surface (identifiers, comments,
  docstrings, script usage).
- The four honesty labels are written `(measured)` / `(extrapolated)` / `(assumed)` /
  `(theoretical)`, in **round parentheses**. Square brackets are not used: in a Rust doc comment
  rustdoc parses `[measured]` as an intra-doc link, fails to resolve it, and CI runs
  `RUSTDOCFLAGS=-D warnings cargo doc`, so it would turn CI red. Decisions attributed to the user
  are written `(decided <date>, user's call)`.
- These are still Japanese and were deliberately left that way: `docs/`, `benchmarks/README.md`,
  `benchmarks/doc-gen4-report.md` and `.html`, `benchmarks/tools/`, `e2e/README.md`,
  `extractor/README.md`, and `.claude/`. **Do not translate them opportunistically**; new text
  written into them is English.
- `benchmarks/results/**` is never rewritten at all — see the `Measurement honesty` section.
