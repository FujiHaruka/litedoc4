# Handoff — 2026-10-07 (multi-version: step 1 done, step 2 next)

## State

- Branch `multi-version`, clean, pushed. Not `main`; no PR open. CI (`ci.yml`,
  `ci-lean-versions.yml`) last dispatched green through `9b11d83`; everything since is docs, logs
  and the M runner.
- SoT: `docs/multiversion/plan.md` (goal, v2 targets, D1–D10; D5 now records the unit) and
  `docs/multiversion/implementation.md` (order; step 1 is **Done 2026-10-07**, with what M says and
  what is carried to step 2).
- Step 1's numbers: `benchmarks/results/mv-m-2026-10-07.txt` (two M runs, byte-identical;
  extrapolations to Mathlib at 11 / 51 versions).

## Relay control
- Mode: DONE
- Goal: step 1 of `docs/multiversion/implementation.md` ("The store and the data format") to its
  "Done when".
- Summary: candidate (a), one content file per module per version, chosen on M (854 MB at 51
  versions extrapolated, one content fetch per page); the per-version files, 73–94% of every
  candidate's total, are carried to step 2.
- Leg: 3 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: v2 targets and decisions in plan.md (`e432c58`) · implementation plan with the
    three-size measurement loop (`2bbbcb8`, `16a6b46`, `120c797`) · prototypes preserved
    (`4665c2f`) · step-1 prep findings: slice cache, M candidates, S input (`e93230b`)
  - r2: S input (`9414940`) · gzip via vendored miniz (`fc68911`) · extractor identity +
    `no_equations_under` (`e18ec62`) · store (`256885f`, `b33e428`) · format with candidates a/b/c
    and `store measure` (`bd2b4d3`, `8a34aac`) · `tools/mv-s-gate.sh` (`9b11d83`) · M runner +
    smoke (`8d72a45`) · plan updates (`05772a2`, `261e6b2`)
  - r3: declaration axis settled and M first run logged (`02aa684`) · second run byte-identical,
    `store measure` ×5, extrapolation, candidate (a) chosen, step 1 done (`107391e`, and the
    commit after it)

## Next step (step 2, not started — start it only when the user asks)

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
