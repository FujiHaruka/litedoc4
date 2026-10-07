# Handoff — 2026-10-08 (multi-version: render memory explained and left to the toolchain)

## Relay control
- Mode: ON
- Goal: implementation.md step 5 (the rebuild from nothing through the reader) to its "Done when", following the "Step 5 plan (2026-10-08)" order 1-7
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: step 5 plan written into implementation.md

## State

- Working directory: /Users/haruka/dev/lean-doc
- Branch `multi-version`, pushed, clean. Not `main`; no PR open.
- Working context: the render-memory question is closed. The user decided (2026-10-08) not to
  work around it: Lean v4.34.1's mimalloc 3.4.4 fixes it; v4.34.1 is now a supported row.

## Where we are

The cause is measured and logged (`benchmarks/results/mv-l-render-memory-2026-10-08.txt`,
implementation.md step 4 "On L"): Lean's bundled mimalloc 2.2.3 (every toolchain in
`tools/lean-toolchains.txt`) never reuses or returns a freed block of 66 MiB (40 MiB is reused;
threshold between, not narrowed). `Store.read` allocates two such blocks per version (63 MiB
compressed entry, 538 MiB inflated pack) → +~0.6 GiB per version read in one process. Nothing
litedoc4 retains is involved. Full render peak ≈ 3.67 + 0.585 (n−1) GiB on the runner.

## Next step

Nothing is left of this thread. Pick the next item of `docs/multiversion/implementation.md`
(step 5, the rebuild through the reader, or step 6's CI) with the user; the Open items below are
the known gaps.

## Files to read first

- `docs/multiversion/implementation.md` — step 4 "On L" (the decision) and steps 5-6
- `benchmarks/results/mv-l-render-memory-2026-10-08.txt` — the evidence, if the question returns
- `benchmarks/results/lean-434-build-2026-10-08.txt` — what building on v4.34.1 did and did not cover

## Load-bearing context

- Ruled out with measurements (don't redo): glibc tunables, `MIMALLOC_PURGE_DELAY=0`,
  `MIMALLOC_DISALLOW_ARENA_ALLOC=1` (worse), `MIMALLOC_ARENA_EAGER_COMMIT=0`, `mi_collect(true)`.
  macOS footprint/RSS can't separate retained from freed (compressor) — use Linux `/proc` floors.
- Lean v4.34.1's mimalloc 3.4.4 reuses the block (measured, log section (10)): the growth is
  2.2.3's, i.e. v4.31.0-v4.33.1. v4.34.1 is a supported row since cee62bb (instance_reducible;
  CI run 37697700267 green on all five toolchains, IR agrees). No Mathlib-sized run on v4.34.1
  yet. Process-per-version was rejected (user's call).
- Experiment code is readable at commit 070e030 (`litedoc4_exp_*` in `csrc/gzip.c`, phases in
  `renderStore`, `.github/workflows/mv-l-render.yml`); removed in ab086f9.
- Run 37630692670's artifact `mv-l-store` (3 L entries) expires 2026-10-21; a local copy is at
  `/private/tmp/lean-doc-relay/mv-l-r3/store` (190 MB). Disk ≈ 8.8 GiB free.
- GitHub pushes returned 500 for ~5 min once; a retry loop got through. A workflow whose step
  name contains ": " is invalid YAML and silently creates no named run — validate with
  `python3 -c "import yaml; yaml.safe_load(open(...))"`.
- `mv-l.yml` still has the glibc-tuned arm (e) (proved useless; drop it when next editing) and a
  `push:` trigger on this branch (make dispatch-only before merging).
- Open items from before (unchanged): kept versions' bibliography warning not printed; partial
  render reports ledger `dataAdded`; step 6 needs the deployed site at `<out>/site`; dead links not
  reported; version rule not built; README pins v1.4.0; hash-mode not covered by browser items.
- Communicate with the user in Japanese, brief-me style.
