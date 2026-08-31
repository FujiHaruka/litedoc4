# Handoff — 2026-08-31 (relay leg 8 → user decision)

## State

- Branch `main`, clean, pushed. **CI green on `7800296`** (CI) and on `ab0516d`
  (lake package self-test, Lean versions, sample site).
- **M9 is fully closed.** Its two "waiting on the user" items were not user decisions and
  were settled by looking (→ Next step, item 0).
- **M10 has not started.** What it deletes is now counted rather than guessed, and the
  cheapest half of the loss has already been bought back. **The remaining question is one
  the user has to answer** — it is at the bottom of this file.
- Measurement env: target `/Users/haruka/dev/lean-projects`, now at `88bc6f75` — **this leg
  committed one line to it** (the litedoc4 pin) and nothing else. Sources untouched.
- **Disk 2.9 GiB free (99% full), and it fell ~0.3 GiB over this leg.** CLAUDE.md's warning
  about what happens when this runs out is not hypothetical — it cost a target olean once.
  The reclaimable piece is **`target/debug`, 1.2 GB** (`target/release` is 356 MB and is what
  the gates prefer). It was left alone deliberately: deleting it buys a full `cargo test`
  rebuild for whoever runs next, and nobody asked. **Take it before any large run**, and note
  that M10 removes the whole 1.6 GB anyway.

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 8 / cap 40
- Predecessor: purelean-r7 (killed)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Answered 2026-08-31: **(b)** — build Lean test scaffolding, port selectively, then delete.
  User's rule: **invariants must be expressed as code; types where a type can say it,
  tests only where nothing else can.**
- Progress ledger:
  - r1–r4: M1–M4 (see `git log`)
  - r5: M5–M7 complete, M8 all but `build-gate.sh`. `1e5f0b5`..`9b34b48`
  - r6: M5's evidence retaken (3,201/3,201); M8 complete. `c7790ef` / `daa0d78`
  - r7: M9 complete on the repository side; tag `v1.3.0`. `08efc70`..`ca70fcf`
  - r8 (cont.): the user answered **(b)**. Scaffolding built and green on Linux
    (`12afbd2`), the rule recorded in CLAUDE.md (`c7c97ab`), `litedoc4-ir`'s 32
    invariants in triage.
  - r8: M9 closed out and M10 costed. `fd92965` (the vite → `assets/` link becomes a gate
    stage), `88befc3` (two measurements), `673e551` (M9's leftovers settled),
    `fe8e100` (584 tests classified), `ab0516d` (135 argv refusals frozen + the 17
    divergences they found, closed), `7800296` (`web/` leaves `crates/`),
    `a3e691e` (the Lean half gains the documented-flag/parser tie it never had)

## Next step

**0. Nothing is pending from M9.** Both items leg 7 left for the user were settled here:
   - The `information-theory` pin is at `v1.3.0` (`88bc6f75` in that repository). CLAUDE.md's
     v1.0.0 section instructs this on every release; `docs.yml` fires on a tag push, so the
     pin commit publishes nothing by itself.
   - `v1.3.0` has a GitHub Release. The page's "Latest" had been `v1.2.0` — a falsehood, not
     an open question. Nothing in the tree points at litedoc4's own Releases (every
     `releases/` hit is elan's), so this is discoverability. **Releases cannot be retired by
     deletion**: CLAUDE.md keeps the `v0.1.0`–`v0.1.3` asset names as real external names.

**1. ~~Answer the question at the bottom.~~ Answered: (b).** The scaffolding exists and is
   green on Linux (`tools/lean-test-gate.sh`, 4 items, each shown to fail on its own). The
   rule is in CLAUDE.md under "Lean invariants" — **type first, `#guard` next, test last** —
   and the mechanism constraints behind it are measured in
   `benchmarks/results/lean-test-scaffolding-2026-08-31.txt`. Read that before choosing a
   mechanism; it will save rediscovering that `by decide` is unusable here.

**1a. The triage is the remaining work, and it is per-crate.** `litedoc4-ir` (32) is the
   pilot. Still to do: `litedoc4-render` (110 I, and the most md4c-downstream),
   `litedoc4` (89), `litedoc4-global` (41), `litedoc4-md` (28), `litedoc4-incr` (16).
   `litedoc4-testutil` (37) is skipped — it tests the Rust test helpers.
   **Then** the F bucket, **then** the fixture-requiring refusals, **then** the deletion.

**2. Decision-independent work that is already done** — do not redo it:
   - `web/` is out of `crates/` and every reference moved with it.
   - The `vite → assets/` link is `tools/assets-gate.sh`'s last stage, not a Rust test.
   - `tools/refusal-gate.sh` + `tools/refusals.txt`: 135 argv refusals, frozen from the Rust
     oracle, Lean-primary arm, Rust arm that skips loudly when the binary is gone.
   - `tools/flag-tie-gate.sh`: 153 `(command, flag)` pairs read out of the Lean binary's own
     `--help-all` and handed to both halves; a documented flag that comes back
     `unknown argument` fails. **This closes degradation 1 below.** Its 16 controls are the
     part worth understanding: "not `unknown argument`" is a string match, so each command is
     also handed a flag that must *not* exist — without that, the whole gate passes the
     moment that wording changes.

**3. Decision-dependent, therefore not started**: the second tranche of refusals (the ones
   needing a crafted IR tree, ledger or `litedoc4.toml`). If the answer is "build Lean test
   scaffolding", those should be Lean tests, not gate cases — so the answer changes the shape
   of the work, and doing it now would be building the wrong thing.

## What M10 deletes — counted, not guessed

`cargo test --workspace` is CLAUDE.md's definition of green. Every `#[test]` under `crates/`
was classified by **what it asserts** (the name-based approximation from leg 7, 146/556, was
discarded as unreliable).

| bucket | count | fate |
|---|---|---|
| **G** a surviving gate already sees it | 55 | no loss |
| **R** entrance refusal, reachable from the CLI | 93 | **partly bought back** — see below |
| **F** frozen-fixture byte comparison | 83 | data survives in the planned `rust-frozen` tag; stops running |
| **I** internal invariant, no CLI path | 353 | **stops running** |
| | **584** (21 `#[ignore]`d) | |

- **The denominator is verified; the I/F split is not.** `584` tests and `21` `#[ignore]`d
  were checked against the repository directly (`rg -c '#\[(tokio::)?test\]' crates/`, and the
  per-crate totals match one for one). `G=55` and `R=93` are corroborated by the per-test
  tables row for row. **`I=353` / `F=83` are not**: the detail tables hold only 331 I and 67 F
  rows, so **38 of the 436 non-G non-R tests were counted but never tabulated**. Honest
  bounds: **I is between 331 and 369, F between 67 and 105.** Subtracting
  `litedoc4-testutil`'s 37 helper-tests gives a product figure of **~294–332, not a crisp
  316** — the number quoted before this was checked. The triage below re-reads every one of
  them, so it settles this as a by-product; do not quote a precise figure until it has.
- **No R behaviour is library-only.** `main.rs` dispatches 14 subcommands, so all 93 have an
  executable path — which is what made the refusal gate possible at all.
- **"Reachable from the CLI" is not "expressible as argv".** `tools/refusal-gate.sh`'s own
  scope line says **command lines only** — 132 of its 135 cases are refused before anything on
  disk is opened. The refusals that need a crafted IR tree, `litedoc4.toml`, ledger or
  blocking file (the `reading_a_broken_tree.rs` group, `config.rs`, `decl.rs`'s unplaceable
  name, the `io.rs` filesystem pair) are **the second tranche and are not covered**.
  **The split between the two is not established** — a keyword pass over the R list's
  descriptions said 12-of-93 need disk, which contradicts the list's own grouping (the IR
  group alone is 13 crafted trees), so the approximation is wrong and no figure is quoted
  here. Establish it by reading, the way the 146/556 name approximation had to be.
- **There is no Lean test scaffolding of any kind.** `lakefile.lean` declares four things
  (`lean_exe extract`, `lean_lib Litedoc4`, `lean_exe litedoc4`, `script docs`). `src/`'s 53
  modules contain zero `#guard`, `#eval`, `example :` or `theorem`. Porting a test means
  first inventing the target, the runner and the assertion vocabulary.
- The I bucket is **not trivia**: `a_closing_hash_run_is_dropped_and_a_trailing_hash_is_not`,
  `only_the_names_ascii_folding_is_wrong_for_are_carried`,
  `the_heading_is_the_first_one_by_position_not_by_order`,
  `the_split_is_a_superset_of_both_implementations`. These are edge rules **no corpus
  exercises** — which is precisely why they were written as unit tests.

## What the oracle found before it could be lost

`tools/refusal-gate.sh` compared 135 argv refusals across both halves while the Rust binary
still exists. **Exit codes: 0 differences. Messages: 17 differed, and none was substrate
wording** — every one was litedoc4's own prose
(→ `benchmarks/results/refusal-divergence-2026-08-31.txt`).

This **falsified** the 24-probe conclusion from earlier in the same leg
(`purelean-refusal-diff-2026-08-31.txt`), which had sampled and found only 3 differences, all
substrate. The plan's wording was corrected: **exit codes agree, messages did not.**

All 17 are now closed, in a direction decided per case:
- **12 — Rust moved.** It was naming `crates/litedoc4/src/resident.rs`,
  `stage7g/extract-once.sh`, or "See this file's heading" (a CLI user has no "this file"), or
  writing history ("was … and is gone"). Paths that stop existing at M10; a message naming
  one is a lie the moment it does.
- **1 — Rust gained** the Lean half's measured clause on `watch --interval`.
- **4 — Lean gained** a reason (`--source-url`: doc-gen4 reads it from lake plus git, and it
  is not in the IR) and a measured consequence (`--no-link-index`: 150 of 432 pages). Lean
  had the source-url string inlined **seven times**; it was collected into one `def` rather
  than edited seven times.

**The frozen expectations reproduce byte for byte on Linux** — `lean 135/135, rust 135/135`
in `ci-lake.yml` on `ab0516d`. Nothing platform-specific leaked into them.

## Two Rust tests have no home after M10

`base_ir::reads_every_module_of_the_target_package` and
`base_ir::astral_binders_slice_correctly` read the **measurement target's** IR. By this
repository's own rule that is not a test, and they cannot become `Invariant`s. They are listed
in `tools/corpus-tests.txt`, **an inventory that dies with `crates/`**, so unless someone
places them they vanish without anything failing. `purelean-render-gate.sh` already takes the
target's IR and is the natural host. Found during the `litedoc4-ir` triage; not yet placed.

## Load-bearing context

- **`tools/refusal-gate.sh`'s two arms are not symmetric on purpose.** The Lean arm reads
  only the frozen file and must keep working after `crates/` is gone. The Rust arm asserts
  the frozen file still matches the oracle and **skips with its count printed** when there is
  no Rust binary — never a silent pass. Re-mint with
  `tools/refusal-gate.sh --mint --from target/release/litedoc4`; it reports how many rows moved.
- **`assets/` is a committed build output**, because the Lean half cannot `include_str!` and
  `tools/gen-assets.py` writes its bytes into `src/Litedoc4/Assets.lean`. Its freshness is
  the last stage of `tools/assets-gate.sh` — it was a Rust unit test, which would have taken
  the chain's first link away with `crates/`. `assets-embed-gate.sh` must stay node-free,
  which is why it is not there.
- **vite's output is byte-identical on macOS and Linux** (measured this leg, both in CI and
  locally). That is what makes a committed bundle safe.
- **`docs-gate.sh` scans every tracked `.rs` / `.lean` / `.sh` / `.ts` / `.py` / `.yml` /
  `.toml` / `.md` / `.txt` file**, not just `docs/` — so a `benchmarks/results/…` citation
  inside product code *is* checked for rot. (A subagent reported the opposite; it was wrong.)
- **`crates/litedoc4-render/build.rs`'s header used to say "No bundle is committed"** — false
  since M2. Fixed. Watch for the same staleness elsewhere in that crate.
- **`--help-all` attributes flags to commands twice, and only one of them is checked.** The
  synopsis block (lines 1–64) is what `flag-tie-gate.sh` pairs from; the description block
  below it attributes them again and more finely (`` --deps-docs-map  (`site`, `render`,
  `incremental`, `ledger`, `links`) ``). Nothing reconciles the two, so prose naming a
  command the synopsis does not list passes both gates — and the prose is the copy a reader
  acts on.
- **`impact --mode <nonsense>` is the one flag value not refused at the entrance.**
  `Mode::Unrecognised` is carried to where the mode is consulted, so with an empty changed
  set the run **exits 0 having done nothing**. Deliberate and commented, but a typo there is
  silent. Covering it needs a crafted IR tree — second tranche.
- The traps from leg 7 that still hold: `pgrep -f 'foo[.]sh'`; bash 3.2; no `timeout`;
  `RUSTDOCFLAGS='-D warnings -A rustdoc::private_intra_doc_links'`; `tools/build-lean-exe.sh`
  is the single answer to "how is `lean_exe litedoc4` built".

## Files to read first

1. `.claude/purelean-plan.md` §M10 — rewritten this leg with the counts and the two degradations
2. `benchmarks/results/refusal-divergence-2026-08-31.txt` — what the oracle caught
3. `tools/refusal-gate.sh` header — the two-arm design M10 has to keep
4. `benchmarks/results/purelean-runner-2026-08-31.txt` — M9 at real scale on a runner

## The question for the user

**M10 deletes 316 product invariants and there is nowhere in the Lean half to put them.**

The refusal class (93) is bought back and the gate suite covers 55. What stops running is
**316 internal invariants + 83 frozen-fixture comparisons**, and the two degradations below.
Three ways forward:

- **(a) Delete as planned.** Green becomes the gate suite alone. Cheapest; accepts that edge
  rules no corpus exercises stop being checked, permanently — because with no scaffolding
  there is nowhere to add a check later either.
- **(b) Build minimal Lean test scaffolding first, port a chosen subset, then delete.**
- **(c) Build the scaffolding, port nothing yet, then delete.** The one-time cost is paid,
  future checks have a home, and porting becomes something that can happen when a bug
  motivates it.

**Recommendation: (c), then (b) selectively** for the rules no corpus reaches. The reason is
not the count — it is that **(a) is not "fewer tests", it is "no unit-level checking, ever"**,
and this repository's own doctrine is that what is not measured is not fine.

**Two degradations independent of the count. This leg closed one; the other is still open:**

1. ~~`public-surface-gate.sh` weakens on a 1.x promise.~~ **Closed** (`a3e691e`). The tie was
   one Rust test, `every_documented_flag_is_parsed`; it is now `tools/flag-tie-gate.sh`,
   which asks both binaries rather than reading either one's source, and therefore survives
   M10. 153/153 pairs accepted by both halves — **no flag was found documented but
   unparsed**. `public-surface-gate.sh`'s header no longer claims the hole.
2. **`tools/gates.txt`'s `needs` column becomes false for three rows.** `purelean-gate`,
   `purelean-micro-gate` and `purelean-render-gate` all say "a built Rust litedoc4 as the
   oracle". They become one-armed the moment `crates/` goes, and `workflow-gate.sh` checks
   the `ci`/`manual` column, not `needs` — so **nothing fails**. Of
   `purelean-micro-gate.sh`'s 16 items, a few already need no Rust (item 16 compares an
   incremental build against a full one; items 8 and 11 re-run the closure checker and
   `site-gate.sh` on the Lean-built site). Item 16 is the one whose *question* is unique to
   this gate, and its header says so. **The rest are byte comparisons against the oracle and
   have nothing to compare against once it is gone** — that is the shape to decide about,
   not the row in `gates.txt`.
