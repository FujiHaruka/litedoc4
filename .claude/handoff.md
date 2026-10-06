# Handoff — 2026-10-06 (multi-version: step 1 begins)

## State

- Branch `multi-version`, clean, pushed (`e93230b`). Not `main`; no PR open.
- The milestone moved from investigation to implementation today. The SoT is
  `docs/multiversion/plan.md` (goal, "v2 targets", decisions D1–D10) and
  `docs/multiversion/implementation.md` (the order: steps 0–6 and the S/M/L measurement loop).
- Step 0 is done: the prototypes are frozen under `prototypes/olean-reader/` (not built by anything).

## Relay control
- Mode: ON
- Goal: step 1 of `docs/multiversion/implementation.md` ("The store and the data format") to its
  "Done when". Leg plan from the user: **r2 = implement and test** (the store, the S and M
  experiment inputs and runner scripts, the data-format candidates as code with tests); **r3+ =
  measure and optimise** (S/M runs, choose the shared-storage unit by numbers, log to
  `benchmarks/results/`, record the choice in the plans)
- Leg: 2 / cap 8
- Predecessor: none (leg 1 ran in a Herdr pane and closes itself after the baton lands)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: v2 targets and decisions in plan.md (`e432c58`) · implementation plan with the
    three-size measurement loop (`2bbbcb8`, `16a6b46`, `120c797`) · prototypes preserved
    (`4665c2f`) · step-1 prep findings: slice cache, M candidates, S input (`e93230b`)

## Next step

Read `docs/multiversion/implementation.md` whole, then settle step 1's first open item — **S's
input** (litedoc4's own `src/` commits vs a small synthetic package with versions; the plan's
"Measurement loop" lists why the commits are thin: 8 commits after `rust-frozen`, requires
changed twice, and no settled way to run the extractor over `src/`). Pick by what S must say
(store, format, renderer, command, staleness — exactly, by counters), then implement.

## Files to read first

- `docs/multiversion/implementation.md` — the order, step 1, the measurement loop and its findings
- `docs/multiversion/plan.md` "v2 targets", D4, D5, D7, D8, D9 — what the store and format must satisfy
- `src/Litedoc4/Build.lean`, `src/Litedoc4/Ir.lean` — today's single-version pipeline and IR reader
- `/private/tmp/lean-doc-relay/step1-prep/` — import graphs of Mathlib v4.32.0 / v4.34.1
  (`graph-*.json`), closure script, the 51 `src/` commits (`src-commits.txt`); regenerable

## Load-bearing context

- **User's decisions today** (all in plan.md): release condition = adding one release over kept
  versions ≤ 15 min + the set as it exists; 51-version rebuild from nothing is tracked, not a
  condition. Host R2. Thin HTML + data for every version. Used by kept (per module, on demand),
  search per version. One command over a store of kept versions. Meta-code equations dropped,
  applied by the extractor from configuration.
- **The everyday path needs no reader**: the three phase-5 versions (v4.32.2 / v4.33.0 / v4.33.1)
  extract natively with today's extractor. The reader path is step 5. Do not start it early.
- **Existing Mathlib workspaces** `/private/tmp/lean-doc-relay/mv-v4320` (v4.32.0) and
  `mv-v4341` (v4.34.1), 7.7 + 7.6 GB, full caches — an M slice on these needs no download, but
  they are not the step's three versions. Disk free ≈ 13 GiB: delete a workspace before making one.
- **Timing noise on this machine**: another macOS user's Chrome held 13–15 GB compressed memory
  during every recent run. Use CPU time and counters first; flag wall clock as noisy.
- Communicate with the user in Japanese, brief-me style, no code names in briefs.
