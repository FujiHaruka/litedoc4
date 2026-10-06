# Handoff — 2026-10-07 (multi-version: step 2, relay leg 2)

## State

- Branch `multi-version`, clean, pushed. Not `main`; no PR open. `ci.yml` green at `3417628`
  (run 37514974836); dispatched at `3adb63a` (run 37518150463) — check it first.
- SoT: `docs/multiversion/plan.md` and `docs/multiversion/implementation.md`. Step 2's
  "What exists" / "Deviation" / "Not done yet" blocks say what r1 built and what is left.
- r1 built (all gated on S, nothing measured on M): `litedoc4 store render --store --versions --out`
  (content-addressed `d/`, page shells, `versions.json`), per-page link tables by module name,
  docstrings as HTML with deferred word links (rule on `markWord`, `src/Litedoc4/Md/Html.lean`),
  store record schema 4 (pinned source per root, title; bibliography and front page in the pack).
  Gates: lean-test 266 + 79, `tools/mv-s-gate.sh` 40/40, refusal 219/219, purelean-micro 51/51.

## Relay control
- Mode: ON
- Goal: step 2 of `docs/multiversion/implementation.md` ("The multi-version renderer") to its
  "Done when", including the four items step 1 carried to it. Leg plan from the user:
  **implementation and measurement in separate legs** — r1 = implement and test (no M/L
  measurement in that leg); r2+ = measure on S/M, optimise, log to `benchmarks/results/`, record
  in the plans.
- Leg: 2 / cap 8
- Predecessor: mvstep2-r1 (idle, kill it once you are running)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger (step 1's chain, closed DONE: r1–r3, last `a2bc6e2`)
  - r1: implemented and gated on S — record schema 3 `53dbc61`; per-page links + docstring words
    `de6bef7`; `store render` `3417628`; site config in the store `3adb63a`

## Next step (step 2, leg r2: measure)

1. Regenerate the M store with `benchmarks/tools/mv-m-run.sh` (≈ 5.5 min, network, ≈ 1.3 GiB
   peak; it puts v4.32.2 / v4.33.0 / v4.33.1). Read the script first: it was written for
   `store measure` and schema 2/3 — entries must now be put at schema 4 (re-put needs the build dir
   and a checkout at that commit). Sample first on anything new.
2. `store render` the three versions: hosted bytes and file count (split shells / data / root,
   data added per version), render time and peak RSS (5 runs, warm; CPU time and counters first).
   Render twice → byte-identical; each version alone → its slice. Log to
   `benchmarks/results/mv-m-render-2026-10-0X.txt` with full conditions; extrapolate to Mathlib
   (labelled) and compare with step 1's per-version-files numbers (patch release: 878 of 880
   per-version files were identical — how many data files does v4.33.1 add now?).
3. Record in `implementation.md` step 2 and plan.md (D5's "Still open" on per-version files,
   U10/D4 sizes where they quote), then mark step 2 Done if the "Done when" holds.

## Load-bearing context

- **Disk ≈ 12 GiB free** at r1 start. `/private/tmp/lean-doc-relay/mv-v4320` and `mv-v4341`
  (7.7 + 7.6 GB, full Mathlib v4.32.0 / v4.34.1 workspaces) are kept on purpose. The S store is at
  `/private/tmp/lean-doc-relay/mv-s/` (the gate regenerates its own work dir).
- **Timing noise**: another macOS user's Chrome holds 13–15 GB compressed memory; read CPU time and
  counters first.
- `store measure` still lays out step 1's files only (no references / front-page files), so its
  numbers stay comparable with `benchmarks/results/mv-m-2026-10-07.txt`; hosted bytes now come
  from `store render`. `linkNames` in measure's JSON now counts per-page names + words entries —
  not comparable with the older logs' column.
- Content bytes changed in r1 (docstrings are HTML now): step 1's content sizes are not this
  format's; say so wherever a new number sits beside an old one.
- Shells' `data-root` is the site root; docstring-relative destinations are relative to the
  version's directory (`data-root + version + "/"`) — step 3 inherits this.
- `tools/md-memory-gate.sh` does not cover `vendor/miniz` / `csrc/gzip.c` yet.
- `tools/purelean-render-gate.sh` needs `/private/tmp/lean-doc-relay/purelean` (absent); not run.
- Communicate with the user in Japanese, brief-me style, no code names in briefs.
