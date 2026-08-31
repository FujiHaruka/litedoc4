# Handoff — 2026-09-01 (relay leg 11 → PAUSED)

## THE BLOCKER — read this before running anything

**The disk is full: 159 MiB free on `/System/Volumes/Data`, 100% capacity.** Inodes fell from
21M free to 1.6M during this leg. **This is not the project's doing** — the working tree is
unchanged in size (`.lake` 276 MB, `target` 19 MB, scratchpads a few hundred MB) and every gate
cleaned up after itself. The cause is **~70 GiB held by APFS local snapshots from a staged macOS
update**: `tmutil listlocalsnapshots /` lists `com.apple.os.update-MSUPrepareUpdate` and two
`com.apple.os.update-*` siblings, and the container's 228Gi − 156Gi used − 159Mi free is the
purgeable difference.

**Freeing it is the user's call and was left to them** (installing or cancelling the staged
update, or `tmutil deletelocalsnapshots`). Deleting a staged system update is outward-facing and
irreversible, so no leg should do it unasked.

**Do not run gates until this is fixed.** CLAUDE.md's own record is that a full disk here does
not merely fail a measurement — it broke the target repository's oleans and the shell itself, and
took the means of recovery with it. `tools/purelean-*-gate.sh` and anything building a `build` /
`incremental` world need work areas measured in hundreds of MB.

## State

- Branch `main`, **clean, pushed** at `9899f32`. Nothing is uncommitted; the disk emergency cost
  no work.
- **CI is green on `6acb414`** (all four: CI / lake package / sample site / Lean versions).
  **`9899f32` was still `in_progress` when this was written — confirm it first.** It is the one
  that matters most, because it adds a *new CI job* (`v8-gc-table` in `ci.yml`) that has never
  run on a runner.
- Gate baselines, all reproduced by hand this leg:
  `tools/refusal-gate.sh --lean .lake/build/bin/litedoc4 --rust target/release/litedoc4` →
  `lean 208/208, rust 183/208 (25 differ by design …); usage block 253 line(s) each; 30 row(s)
  print before refusing and freeze stderr only`.
  `tools/lean-test-gate.sh` → **222 compile-time, 31 run-time, 0 failed**.
  `tools/purelean-micro-gate.sh` → ok, 16/16 items, 49/49 frozen files.
  `tools/workflow-gate.sh` → 30 gates inventoried, 24 run by a workflow, 6 manual.
  `tools/docs-gate.sh` → 249 citations resolve.
- **`target/release/litedoc4` is the Rust oracle and is irreplaceable** — `cargo build` needs disk
  this machine does not have. Do not delete `target/`. Do not delete `.lake` either; rebuilding
  costs disk too.
- **The second tranche is complete: 73 rows** in `tools/refusals-on-disk.txt`, 208 with tranche 1.
  `tools/refusals.txt` is byte-identical to where it has been for three legs and must stay so.

## Relay control
- Mode: PAUSED
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 11 / cap 40
- Predecessor: purelean-r10 (killed)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Paused because: **the machine has 159 MiB of disk. The remaining work (M10 steps E and F)
  cannot be verified without work areas, and the fix — removing a staged macOS update's local
  snapshots — is the user's decision, not a leg's.**
- Progress ledger:
  - r1–r7: M1–M9, tag `v1.3.0` (see `git log`)
  - r8: bucket I complete 316/316; both expiring oracle windows closed; 135 argv refusals frozen
  - r9: D done and CI-verified · Unicode oracles measured · the second tranche read, 59 rows
  - r10: the second tranche's machinery and 58 of its rows · five Lean defects found by freezing
    and fixed · the stdout policy written down
  - r11: **the tranche is complete at 73 rows** (`6acb414`) · **a sixth Lean defect — the JSON
    parser's own sentence — found while verifying, not by a failing row** · **B2 done**
    (`9899f32`): the Unicode tables are generated into Lean, two gates added, and a
    `workflow-gate.sh` defect fixed

## What leg 11 did

**1. The tranche's last 15 rows** (C12, groups E/G/H/I) — 58 → 73. Nothing was left out.
`incremental-round-bound`, the only exit-5 row, needed no declaration-moving extractor after all:
a *deletion* reaches exit 5, and `--extractor ./never-run` naming a program that is not there is
what proves none was started. `build-source-url-not-github` is the first row whose `<varies>` is
exercised *within one gate run* — each arm rebuilds the fixture and so commits at a different
time, which is the only demonstration that the wildcard matches two different texts rather than
the same one twice.

**2. A sixth Lean defect, and it is the one worth carrying forward.** `Json.pVal` answered every
unreadable value with **`a value was expected at {i}, and byte {c} begins none`** — false for four
of the five non-structural value starts (110 begins `null`, 116 `true`, 102 `false`, 45 a number),
and it gave `nul` (a literal cut off at EOF) and `not json` (a word that is no literal) the
identical message where Rust separates them. **No row failed.** Both arms read the same wrong
sentence from the same parser, and three earlier legs had frozen it without questioning it. Fixed
to three branches over facts `pVal` already computes; the gate then named exactly the four
affected rows and nothing else. Written up as `.claude/purelean-tranche2.md` **§10**.

**3. B2** — `v8ZcTable` (737 ranges / 7817 chars) re-derives **identically** from deno's own
`/[\p{Z}\p{C}]/u`; `pzcTable` (839) and `zcTable` (742) reproduce byte for byte through the
emitter alone. New generator-owned modules `src/Litedoc4/Global/V8GcTable.lean` and
`src/Litedoc4/Md/GcTable.lean`; `tools/v8-gc-table-gate.sh` (`ci`, wired as the new `v8-gc-table`
job, deno pinned to `v2.7.14` because the table *is* that runtime's answer) and
`tools/gc-table-gate.sh` (`manual`, **exit 2 = "could not ask"**, because UnicodeBasic is not in
the target and arm 2 has never been observed green). `lowerTable`/`sigmaTable` are frozen with the
reason at the definition in `Lower.lean`.

## Next step — M10 step E, then F

**The brief for step E is written and complete:**
`/private/tmp/claude-502/-Users-haruka-dev-lean-doc/1d48be68-eb52-445e-802c-e91ccc9528b5/scratchpad/brief-m10-e.md`
(scratchpads are readable across sessions; leg 9's and leg 10's briefs were found the same way).
Dispatch it to an Opus subagent with the tree state in the launch message, then verify and commit
here. **Only once the disk is fixed.**

Step E is the reversible half — provenance rows repointed or retired, the homeless corpus tests
placed as gates, `public-surface-gate.sh` repointed at `src/`, `corpus-gate.sh`'s fate decided.
**Step F is the irreversible one**: delete `crates/`, tag `rust-frozen`, delete
`.claude/purelean-plan.md` and `.claude/purelean-tranche2.md`. **Push the tag before pushing the
deletion**, so nothing is ever unrecoverable.

## Files to read first

1. `.claude/purelean-plan.md` §M10 (from line ~512) — what actually leaves, and the **two
   degradations** (`public-surface-gate.sh` falling from "accepted" to "spelled";
   `tools/gates.txt`'s `needs` column lying for the three `purelean-*` rows the moment `crates/`
   goes, which `workflow-gate.sh` cannot catch because it reads only the ci/manual column)
2. `.claude/purelean-tranche2.md` **§9 and §10** — this leg's measured corrections. **§2 is the
   oldest part and has been falsified in a dozen places; later sections win**
3. `tools/corpus-tests.txt` — 21 `#[ignore]`d tests, all of which leave with `crates/`. Leg 10
   said **two** are homeless (`base_ir::reads_every_module_of_the_target_package`,
   `base_ir::astral_binders_slice_correctly`). **Verify that number rather than assuming it**

## Load-bearing context

- **A frozen row proves the two halves *agree*, not that either is *right*.** Where a message
  comes from one shared idea — one parser feeding every caller — it agrees with itself by
  construction. Rust is an oracle for *divergence*, never for a sentence both halves get wrong,
  and after `crates/` goes there is no second reader at all. This is what found defect six, and
  it is the last leg in which sentences of that shape can be re-read against anything.
- **`benchmarks/results/unicode-table-regenerators-2026-08-31.txt` §2 has the direction of the
  hand edit backwards** (the log is not rewritten — `benchmarks/results/**` never is). It says the
  committed `.rs` prose was improved by hand after generation; the truth is the *generator* holds
  the older, longer prose and commit `1934448` (2026-08-24, the comment-reduction pass) shortened
  the `.rs`. Following §2 literally would have undone that pass.
- **`gc-table-gate.sh` exits 2, not 0 and not 1, when UnicodeBasic is absent** — "could not ask"
  reported as success is green-by-skipping.
- **`workflow-gate.sh` matched gate names by substring** until this leg, so `gc-table-gate.sh`
  (a substring of `v8-gc-table-gate.sh`) was reported as CI-reached the moment the CI one was
  wired in. Now word-anchored. It is a `ci` gate everything else depends on.
- **`docs/provenance.md` §7 has no row for the Lean V8 table**, a gap that predates this work;
  the same argument §7 makes about `Lower.lean` applies to it word for word. Worth an inventory
  pass over §7 against `src/` **before** M10 removes the Rust rows standing in for it.
- Traps re-confirmed: the Lean executable is rebuilt with
  `tools/build-lean-exe.sh --toolchain-from e2e/micro` (plain `lake build` cannot run beside the
  root `lakefile.lean`); `timeout` does not exist here; `/usr/bin/diff`, not `diff`; a pipe hides
  the exit code and this shell has no `PIPESTATUS`.
