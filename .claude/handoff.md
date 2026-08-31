# Handoff — 2026-08-31 (relay leg 9 → 10)

## State

- Branch `main`, clean, pushed. **CI green on `c5207e4`, the tip**, and on `b611510` —
  the latter including `browser gate on Windows` and `extractor portability`, both
  dispatched by hand because they are `workflow_dispatch` only and this leg changed them.
  (`a307cae` and `914a321` show *cancelled*: concurrency superseded them, not a failure.)
- **Lean side green, measured this leg**: `tools/lean-test-gate.sh` → 222 compile-time
  `#guard`, 30 run-time `Invariant`, 0 failed. Nothing this leg touched `src/`.
- **M10 remaining: C (implement), B2 (implement), E, F.** D is done and verified in CI.
- **Disk 1.9 GiB free (99%).** It hit 1.4 GiB twice this leg. Reclaimed: `target/debug`,
  `fuzz/target`, `fuzz/corpus`, `web/node_modules`, and `target/release/{deps,build}` —
  **`target/release/litedoc4` itself was kept, and that is the Rust oracle C still needs.**
  A second copy is at `<scratchpad>/rust-oracle-litedoc4`. `cargo build` and
  `mise exec -- npm install` restore what was taken; nothing tracked was touched.
  **A full `deps-docs-gate.sh` run costs ~1 GB** — that is what took it to 1.4 GiB the
  second time.

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 10 / cap 40
- Predecessor: purelean-r9
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1–r7: M1–M9, tag `v1.3.0` (see `git log`)
  - r8: bucket I complete 316/316; both expiring oracle windows closed (`e2e/micro-expected`,
    `tools/purelean-render-expected`); 135 argv refusals frozen
  - r9: **D done and CI-verified** (`72747af`, `b611510`) · Unicode oracles measured
    (`3b4d45c`) · **the second tranche read and pinned at 59 rows** (`a307cae`)

## Next step

**1. Implement C** — the 59 rows are already written down, one per *message a user can be
shown*, with the on-disk fixture, the command line, the exit code, the quoted message and
the Lean counterpart for each. Read `.claude/purelean-tranche2.md` first; do not re-derive
it. Four traps it records that will otherwise be stepped on:

- **`impact --mode <nonsense>` is the only exit-2 row that is `Refused`, not `Usage`** — it
  prints **no** `<usage>` block. Reusing tranche 1's `<usage>` substitution mints it wrong.
- **10 of the 59 embed an OS `strerror` or a JSON parser's text** and cannot be frozen byte
  for byte. Freeze by prefix or leave them out — do not pretend.
- **11 of the 59 have no test at all**; they were found by sweeping the 152 `Failure::*`
  construction sites, which is also why the file's row set is not the test set.
- **5 rows genuinely diverge Rust↔Lean** (C9, C10, D2, D5, E4). Settle each direction the
  way leg 8 settled the 17 argv ones, **while the Rust oracle still exists**.

Shape: `tools/refusal-gate.sh` is the model — two arms, Lean-primary against a frozen file,
a Rust arm that skips loudly. Its Python already builds `root/` and `out/` per run; this
tranche needs a per-case fixture recipe in the same place. Mint from `target/release/litedoc4`.

**2. Then B2**, which is decided but not implemented →
`benchmarks/results/unicode-table-regenerators-2026-08-31.txt`:
- `v8ZcTable` **re-derives identically today** (737 ranges, byte-for-byte, deno only) →
  repoint `gen-v8-gc-table.ts` at a generated `src/Litedoc4/Global/V8GcTable.lean` and give
  it a **CI** gate. Carry the *hand-edited* prose into the generator, do not re-emit over it.
- `pzcTable` / `zcTable`: **UnicodeBasic and doc-gen4 are not in the target's manifest**, so
  the acquisition half cannot be run or verified here. Repoint the emitter and verify it by
  reproducing the committed table from the ranges it already encodes — and **do not call the
  result verified end to end.** Manual gate.
- `lowerTable` / `sigmaTable`: **V8 disagrees on 28 code points** (a UCD version gap), so
  there is no live oracle after M10. Freeze them and **say so at the definition** — the file
  currently reads as though a regenerator exists.

**3. E, then F** — retire 14 `tools/provenance-files.txt` rows and their `NOTICE` entries
(the Lean side already carries mirrors; `provenance-gate.sh` is the judge), place the two
homeless target-IR tests, then delete `crates/`, tag `rust-frozen`, and delete both
`.claude/purelean-plan.md` and `.claude/purelean-tranche2.md`.

## Files to read first

1. `.claude/purelean-tranche2.md` — the 59 rows. The expensive part of C is already done
2. `benchmarks/results/unicode-table-regenerators-2026-08-31.txt` — B2, decided by measurement
3. `tools/refusal-gate.sh` header (lines 28-66) — the two-arm design C must copy
4. `.claude/purelean-plan.md` §M10 — counts and the two degradations

## Load-bearing context

- **D was larger than leg 8's sweep said, in three ways, all found by looking.**
  `tools/ledger-compare.sh` read `crates/` and hard-`exit 1`d — missed because it is not a
  `*-gate.sh`. `public-surface-gate.sh` already carries a **parallel Lean arm**, so M10 is a
  *drop of the Rust arm*, not a repoint. And `target2-gate.sh` / `clone-gate.sh` held the
  same binary under `RUST_BIN` with no env override. **Generalise a sweep past the naming
  convention that framed it.**
- **`clone-gate.sh` produces `build-gate.sh`'s reference.** Repointing one without the other
  would have had build-gate compare a Lean candidate against a Rust-produced reference — a
  green-looking cross-implementation diff. They must move together.
- **A `LITEDOC4` default change is a workflow change.** The first push went red exactly
  there: `ci-lake.yml` ran the gate without building the Lean CLI. The fix is not per-job —
  sweep every workflow job against the repointed set (`b611510` did; 4 of 7 were missing it).
  **`ci-browser-windows.yml` and `ci-extractor-portability.yml` are `workflow_dispatch` only,
  so a push does not verify them** — dispatch them by hand or the change stays unmeasured.
- **`gen-v8-gc-table.ts --check` was red before this leg touched anything**, purely from
  hand edits to a file whose header says "do not edit". `tools/gates.txt` has **no row that
  re-derives any Unicode table**, which is why it drifted unseen. Nothing was broken by it;
  the point is that nothing would have said if something had been.
- **The measurement target moved forward** to `60439778`, which is exactly the revision
  `tools/purelean-render-expected` was minted against — so that fixture is current. It has
  an untracked `docs/doc-gen-bench/`; leave it.
- **`deps-docs-gate.sh` passed against the Lean binary at real scale** (426 pages, 91,504
  hrefs, 503 anchors, 0 dead links) — an unplanned but strong confirmation of the repoint.
  It needs the network and about 1 GB; check disk before running it.
- `.claude/purelean-plan.md` is **673 lines, past CLAUDE.md's 600-line threshold**. Not
  compacted deliberately: it is `.claude/`, not `docs/`, and M10 deletes it — compacting it
  would risk dropping `(measured)` labels for nothing.
- Traps re-confirmed here: **`timeout` does not exist on this machine** (cost one wasted
  probe this leg); `/usr/bin/diff`, not `diff`.
