# Handoff — 2026-10-08 (multi-version: step 5, the reader, relay leg 3)

## Relay control
- Mode: ON
- Goal: implementation.md step 5 (the rebuild from nothing through the reader) to its "Done when", following the "Step 5 plan (2026-10-08)" order 1-7 and, for item 6, the "Item 6 plan" order 1-9
- Leg: 3 / cap 8
- Predecessor: mvstep5-r2
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: step 5 plan (caf56ed); item 1 reader + oracle gate 10/10 (9e33548); item 2 World seam (b52d254); item 3 hybrid on S (0bbc24d); item 4 invariants (4006603); item 5 build --versions fills through the reader, tools/mv-reader-gate.sh 12/12 (2d2f02f)
  - r2: M checkpoint run + classifier + .ilean imported-parent rule (c2ed2d4); two defects fixed, M 0 defects, hybrid gate 22/22 (956aab6); item 6 plan (85ea428); item 6 step 1 reuse seam (2723324, CI green both); item 6 step 2 reader session + manual root rewritten per round, hybrid gate 24/24, mv-reader 12/12 (fb5698a)

## State

- Branch `multi-version`, pushed, clean. Not `main`; no PR open.
- CI on 2723324 (dispatched): `ci.yml` and `ci-lean-versions.yml` both green. fb5698a touches
  only the reader (manual gates) and docs; no CI dispatched for it.

## Where we are

`docs/multiversion/implementation.md`: "Step 5 plan" items 1-5 done (item 5 has the M note);
"Item 6 plan" (subsection right after item 7) steps 1-2 done, each with a "Done" note. Next:
1. **Item 6 step 3, the patch** (`prototypes/olean-reader/Patch.lean`): version k+1's merged state
   built from version k's inside `reader session`, with `--check-patch` comparing against the
   tree's own `rewriteMerge` (which has today's fixes the prototype lacks: the newest-only
   structure field-function drop, autoParam classification). Fails once two ways (see plan).
2. Steps 4-9 of the Item 6 plan (reuse under a recomputed key N1X+own; carried key with
   `--check-keys`; `build --versions` over the session; M with `--session`; reader gates once on
   Linux; L on the runner via `mv-l.yml`), then the M1 per-extra-version measurement (5 runs,
   prediction ≈146-160 s vs tracked 1.2 min — a predicted miss; Done-when says "measured
   against", so record it, don't stop on it).
3. Item 7 (records v4.29.0/v4.29.1/v4.30.0/v4.32.1/v4.34.0, each after its oracle; then delete
   `prototypes/olean-reader/` — the Item 6 plan cites its `differential-design.md`, rewrite those
   pointers to a commit when deleting).

## Files to read first

- `docs/multiversion/implementation.md` — "Step 5 plan" and "Item 6 plan"
- `extractor/reader/OleanReader/{Hybrid,Assemble}.lean`, `tools/reader-hybrid-gate.sh`,
  `prototypes/olean-reader/{Patch,PatchMain,PrintKey}.lean`

## Load-bearing context

- Reader builds on v4.34.1 only (`litedoc4 reader build --out <dir>`; litedoc4 embeds the reader
  sources — rebuild litedoc4 with `tools/build-lean-exe.sh --toolchain-from e2e/micro` after any
  reader or `Extract.lean` edit, before gates). Both reader gates and `mv-reader-gate` are `manual`.
- M run: `benchmarks/tools/mv-m-run.sh --through-reader --need-gb 3 --work /private/tmp/lean-doc-relay/mv-m-reader`
  (≈11 min; work dir currently holds only logs — move/delete before rerun). Comparator:
  `tools/lib/reader-compare.py --classify`. Logs: `benchmarks/results/mv-m-reader{,-fixed}-2026-10-08.txt`.
- Keep under `/private/tmp/lean-doc-relay`: `mv-v4341` (Mathlib v4.34.1, newest), `mv-v4320`
  (v4.32.0), `mv-m/store` (old native M), `mv-l-r3` (L store copy, artifact expires 2026-10-21),
  `u13-host`. Disk ≈ 7.5 GiB free.
- Subagents sometimes stop without a final report after their background gate finishes — if a
  notification says "waiting for X" and nothing follows, check the gate logs in the scratchpad
  and take over.
- `mv-l.yml` still has the glibc-tuned arm (e) and a `push:` trigger on this branch (make
  dispatch-only before merging).
- Open items: `docs/provenance.md` has no row for Lean-core-derived code in
  `extractor/reader/` (the `rewriteManualLinksCore` copy in `Hybrid.lean`, mirrored private
  structures); a reader-filled version has no tactic list (63 modules per M version); kept
  versions' bibliography warning not printed; partial render reports ledger `dataAdded`; step 6
  needs the deployed site at `<out>/site`; dead links not reported; version rule not built;
  README pins v1.4.0; hash-mode not covered by browser items.
- Communicate with the user in Japanese, brief-me style.
