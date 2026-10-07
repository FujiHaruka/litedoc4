# Handoff — 2026-10-07 (multi-version: step 3 done; step 4 next)

## State

- Branch `multi-version`, pushed. Not `main`; no PR open. `ci.yml` green at `0316a55` (run
  37559545386); later commits are docs only.
- SoT: `docs/multiversion/plan.md` and `docs/multiversion/implementation.md`. Step 3 is Done
  (settle 217 ms drawn against 322 ms static → `benchmarks/results/mv-settle-2026-10-07.txt`;
  M re-derived → `benchmarks/results/mv-m-render-step3-2026-10-07.txt`). D6's four defaults were
  confirmed by the user (2026-10-07).
- Two render paths exist today: `build` writes the static single-version HTML (`assets/app.js`
  enhances it), `store render` writes shells + data drawn by `assets/site.js`. **The user wants one
  render path** (2026-10-07) — that is step 4's switch of `build` onto the store renderer, and the
  retirement of the static path and its gates ("Gates to replace, not extend").
- Preact (asked 2026-10-07): no JS library is used today (vanilla TS, ≈ 2,850 lines shared by both
  bundles, `site.js` ≈ 12 KB gzip). Agreed order: unify in step 4 first, then judge Preact on what
  remains — a Preact draw of the largest page measured against the current one would be the test.
  Not part of step 4's goal.

## Relay control
- Mode: ON
- Goal: step 4 of `docs/multiversion/implementation.md` ("One command over the version set") to
  its "Done when", including `build` switched onto the store renderer (one render path; the
  static single-version path and the gates listed under "Gates to replace, not extend" that it
  breaks retired, each replacement made to fail once). Leg plan from the user: implementation and
  optimisation in separate legs — r1 = implement and gate on S (and M where needed); r2+ =
  measure (the first L checkpoint on the runner, every phase against the M prediction), optimise,
  log to `benchmarks/results/`, record in the plans. The DONE brief also reports how much
  page-script code remains after the static path is gone (the input to the Preact question).
- Leg: 1 / cap 8
- Predecessor: mvstep3-r2 (kill it once r1 is running)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger
  - (none yet)

## Next step (r1: implementation)

1. Read step 4 and "Gates to replace, not extend" in `implementation.md`, plan D7 / D9, and
   `tools/public-surface.txt` (page paths gain the version: removing 1.x names is what makes this
   v2.0.0 — the public-surface gate must be updated deliberately, not silenced).
2. Plan the order: version-set input and the per-version loop (checkout, toolchain, deps, cache,
   extractor, extract, put, delete checkout); staleness by extractor identity; then `build`
   renders from the store; then retire the static path and its gates, replacing each.
3. Done-when counters on S first (empty store + versions builds; one version removed re-extracts
   exactly that one; changed extractor identity re-extracts).

## Load-bearing context

- **Kept**: `/private/tmp/lean-doc-relay/mv-m/store` (the three M entries); `mv-m-settle` (61 MB:
  the settle measurement's input); `mv-m-render-path` / `mv-m-render-hash` (15 + 9.6 MB);
  `mv-s-gate`; `mv-v4320` / `mv-v4341` (7.7 + 7.6 GB). Disk ≈ 11 GiB free (95% full) — check
  before any Mathlib checkout.
- v4.34.x has no row in `tools/lean-toolchains.txt` (step 4's text: no fallback).
- Path mode validates `versions.json` (a malformed list shows no switcher).
- A stale tmux session `mvstep2-r2` from the step-2 chain is still alive; not this chain's.
- `tools/md-memory-gate.sh` does not cover `vendor/miniz` / `csrc/gzip.c` yet.
- Communicate with the user in Japanese, brief-me style, no code names in briefs.
