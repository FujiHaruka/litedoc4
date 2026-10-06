# Handoff — 2026-10-07 (multi-version: step 2, relay leg 1)

## State

- Branch `multi-version`, clean, pushed. Not `main`; no PR open. CI (`ci.yml`,
  `ci-lean-versions.yml`) green on the branch; `ci.yml` last dispatched at `a2bc6e2`.
- SoT: `docs/multiversion/plan.md` (goal, v2 targets, D1–D10; D5 now records the unit) and
  `docs/multiversion/implementation.md` (order; step 1 is **Done 2026-10-07**, with what M says and
  what is carried to step 2).
- Step 1's numbers: `benchmarks/results/mv-m-2026-10-07.txt` (two M runs, byte-identical;
  extrapolations to Mathlib at 11 / 51 versions).

## Relay control
- Mode: ON
- Goal: step 2 of `docs/multiversion/implementation.md` ("The multi-version renderer") to its
  "Done when", including the four items step 1 carried to it. Leg plan from the user:
  **implementation and measurement in separate legs** — r1 = implement and test (no M/L
  measurement in that leg); r2+ = measure on S/M, optimise, log to `benchmarks/results/`, record
  in the plans.
- Leg: 1 / cap 8
- Predecessor: multiversion-r3 (step 1's last leg; idle, kill it once you are running)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger (step 1's chain, closed DONE: r1–r3, last `a2bc6e2`; CI green on the branch at
  `a2bc6e2`, run 37505169853)
  - (step 2 legs start here)

## Next step (step 2, leg r1: implement)

Step 2 of `implementation.md`, "The multi-version renderer", with the four items step 1 carried
to it: share the per-version files by content (the largest lever: 878 of 880 identical across a
patch release); split the link table per page (module numbers shift on add, so shared files
cannot carry them); a store-record field for dependency source URLs (re-put, no re-extraction);
docstring autolinks in the link table.

## Load-bearing context

- **Both M work dirs were deleted.** A store for step 2 is regenerated with
  `benchmarks/tools/mv-m-run.sh` (≈ 5.5 min, network, ≈ 1.3 GiB peak); the S store is still at
  `/private/tmp/lean-doc-relay/mv-s/`.
- **Disk ≈ 12 GiB free.** `/private/tmp/lean-doc-relay/mv-v4320` and `mv-v4341` (7.7 + 7.6 GB, full
  Mathlib v4.32.0 / v4.34.1 workspaces) are kept on purpose.
- **Timing noise**: another macOS user's Chrome holds 13–15 GB compressed memory; read CPU time and
  counters first.
- `tools/md-memory-gate.sh` does not cover `vendor/miniz` / `csrc/gzip.c` yet (needs stand-ins in
  its fake `lean.h`, a harness mode, a canary and blind arm each) — the C runs in the product now.
- `tools/purelean-render-gate.sh` was not run for the `constLink`/`derive` refactors in `bd2b4d3`
  (needs the target IR at `/private/tmp/lean-doc-relay/purelean`); `purelean-micro-gate` was 51/51.
- Communicate with the user in Japanese, brief-me style, no code names in briefs.
