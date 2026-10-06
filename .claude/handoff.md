# Handoff — 2026-10-07 (multi-version: step 1, measure on M)

## State

- Branch `multi-version`, clean, pushed (`261e6b2`). Not `main`; no PR open. CI (`ci.yml`,
  `ci-lean-versions.yml`) dispatched on the branch and green through `9b11d83`.
- SoT: `docs/multiversion/plan.md` (goal, v2 targets, D1–D10) and
  `docs/multiversion/implementation.md` (order; step 1 now has a "State on 2026-10-07" block
  with the open items and the M smoke findings — read it whole).
- Step 1's code exists and is tested; what is left of step 1 is **measurement and the choice**.

## Relay control
- Mode: ON
- Goal: step 1 of `docs/multiversion/implementation.md` ("The store and the data format") to its
  "Done when". Leg plan from the user: **r2 = implement and test** (done); **r3+ = measure and
  optimise** (S/M runs, choose the shared-storage unit by numbers, log to `benchmarks/results/`,
  record the choice in the plans)
- Leg: 3 / cap 8
- Predecessor: none (r2 ran in a Herdr pane, not tmux; it goes idle after the baton lands)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: v2 targets and decisions in plan.md (`e432c58`) · implementation plan with the
    three-size measurement loop (`2bbbcb8`, `16a6b46`, `120c797`) · prototypes preserved
    (`4665c2f`) · step-1 prep findings: slice cache, M candidates, S input (`e93230b`)
  - r2: S input = sample package ×4 versions with designed churn (`9414940`) · gzip via vendored
    miniz 3.1.2 (`fc68911`) · extractor output identity + `no_equations_under` (`e18ec62`) ·
    store (`256885f`, link index in entries `b33e428`) · data format with candidates a/b/c and
    `store measure` (`bd2b4d3`, imports fix `8a34aac`) · `tools/mv-s-gate.sh` 29 items, ci
    (`9b11d83`) · M runner `benchmarks/tools/mv-m-run.sh` + smoke log (`8d72a45`) · plan
    updates (`05772a2`, `261e6b2`)

## Next step

1. **Settle the declaration axis** before scaling anything: IR declarations exceed `store
   measure` page items by exactly the module count (2,296 vs 2,209 at 87 modules) — find which
   per-module entry one side counts (read `src/Litedoc4/Data/Version.lean` against the IR).
2. **Run M**: `benchmarks/tools/mv-m-run.sh` with the default roots (plan's first candidate,
   ≈ 450 modules) into a fresh `--work`, ≈ 2 GiB per version (extrapolated from the smoke);
   `--jobs` to match the full-Mathlib baseline in `docs/verification-log.md`. Repeat per
   CLAUDE.md (5 runs for times; byte counts are deterministic — compare them exactly). Log to
   `benchmarks/results/`.
3. **Fix the open items that bias the comparison** (implementation.md "State" block): the whole
   per-version link table every page fetches (split it), dependency source URLs missing from the
   store record (record schema bump), docstring autolinks. The per-version files are the marginal
   cost of a release on the smoke slice (≈ 100 KB, 179 files for one changed item) — that, not
   the candidate, may decide hosted bytes; measure it on M.
4. **Choose a/b/c** by hosted bytes, file count and fetches per page view, extrapolated to 11 and
   51 versions against "v2 targets"; write the choice and numbers into implementation.md (and
   plan.md D5). Measure the compressed IR + link index per version (Done-when: it decides where
   the CI store lives) — at M, and say how it scales to full Mathlib.

## Files to read first

- `docs/multiversion/implementation.md` — step 1 and its State block
- `benchmarks/results/mv-m-smoke-2026-10-07.txt`, `mv-s-format-2026-10-07.txt`,
  `mv-s-store-2026-10-07.txt`
- `benchmarks/tools/mv-m-run.sh` (usage header), `src/Litedoc4/Data/` (format), `src/Litedoc4/Store.lean`

## Load-bearing context

- **The everyday path needs no reader**: the three versions extract natively. Do not start step 5.
- **Disk ≈ 12 GiB free.** `/private/tmp/lean-doc-relay/mv-v4320` and `mv-v4341` (7.7 + 7.6 GB,
  full Mathlib v4.32.0 / v4.34.1 workspaces) are kept on purpose; the M runner fits beside them.
  `/private/tmp/lean-doc-relay/mv-s/` (S repo + store, small) is regenerable.
- **Timing noise**: another macOS user's Chrome holds 13–15 GB compressed memory; read CPU time and
  counters first, wall clock second.
- `tools/md-memory-gate.sh` does not cover `vendor/miniz` / `csrc/gzip.c` yet (needs stand-ins in
  its fake `lean.h`, a harness mode, a canary and blind arm each) — not step 1's, but the C runs
  in the product now.
- `tools/purelean-render-gate.sh` was not run for the `constLink`/`derive` refactors in `bd2b4d3`
  (needs the target IR at `/private/tmp/lean-doc-relay/purelean`); `purelean-micro-gate` was 51/51.
- Communicate with the user in Japanese, brief-me style, no code names in briefs.
