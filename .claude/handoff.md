# Handoff — 2026-10-08 (multi-version: step 5, the reader, relay leg 2)

## Relay control
- Mode: ON
- Goal: implementation.md step 5 (the rebuild from nothing through the reader) to its "Done when", following the "Step 5 plan (2026-10-08)" order 1-7
- Leg: 2 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: step 5 plan (caf56ed); item 1 reader + oracle gate 10/10 (9e33548); item 2 World seam (b52d254); item 3 hybrid on S (0bbc24d); item 4 invariants (4006603); item 5 build --versions fills through the reader, tools/mv-reader-gate.sh 12/12 (2d2f02f)

## State

- Branch `multi-version`, pushed, clean. Not `main`; no PR open.
- CI dispatched on 2d2f02f, not yet read: `ci.yml` run 37731622122, `ci-lean-versions.yml` run
  37731615215. Read them first (`gh run view <id> --repo FujiHaruka/litedoc4`); a red one is the
  first job of this leg. The reader has never run on Linux (its gates are `manual`).

## Where we are

`docs/multiversion/implementation.md` "Step 5 plan (2026-10-08)" items 1-5 are done, each with a
"Done" note. Next, in order:
1. **The M exactness checkpoint** (item 5's "On M"): three versions v4.32.2 / v4.33.0 / v4.33.1 at
   the 438-module slice filled through the reader (newest v4.34.1 slice), compared with the native
   M store at `/private/tmp/lean-doc-relay/mv-m/store` (fill "own"; confirm its configuration,
   e.g. `no_equations_under`, matches). A classification run in `benchmarks/tools/` with a log in
   `benchmarks/results/` (conditions recorded), NOT a gate: printed fields (signature text, type
   code, equations, refs positions) that differ → printer drift, counted by cause (U9: `setOf`,
   `↧`, …); any other field differing → defect, zero tolerated. Extend `tools/lib/reader-compare.py`
   rather than writing a second comparator. `benchmarks/tools/mv-m-run.sh` is how M was built
   natively; `build --versions --through-reader` is the product path. Disk ≈ 8 GiB: two Mathlib
   slices at once (newest kept while each older is read). Then the "site differs only where
   printer drift says" half of step 5's Done-when.
2. Item 6 (patch path + print reuse, carried key with check mode, structure-instance default;
   per-extra-version time on the M1; L checkpoint on the runner — record disk, two Mathlib trees).
3. Item 7 (records v4.29.0/v4.29.1/v4.30.0/v4.32.1/v4.34.0 each after its oracle — needs those
   toolchains, ~1.7 GB each; disk; then delete `prototypes/olean-reader/`).

## Files to read first

- `docs/multiversion/implementation.md` — step 5 and its plan subsection
- `extractor/reader/OleanReader/`, `tools/reader-*-gate.sh`, `tools/mv-reader-gate.sh`,
  `tools/lib/reader-compare.py`, `src/Litedoc4/Versions.lean`

## Load-bearing context

- Reader builds on v4.34.1 only (`litedoc4 reader build --out <dir>`, internal; cuts
  `Extract.lean`'s trailing `main`). `build --versions --through-reader <v,...>` is internal. Both reader gates are `manual`. A change to `Extract.lean` needs
  `tools/build-lean-exe.sh --toolchain-from e2e/micro` before `mv-s-gate` (litedoc4 embeds it).
- Native M store (v4.32.2/v4.33.0/v4.33.1, fill "own") at `/private/tmp/lean-doc-relay/mv-m/store`.
  Mathlib workspaces `mv-v4320` (v4.32.0) and `mv-v4341` (v4.34.1) under the same dir — keep.
  L store copy `mv-l-r3/store` (artifact expires 2026-10-21). Disk ≈ 8 GiB free.
- `mv-l.yml` still has the glibc-tuned arm (e) and a `push:` trigger on this branch (paths-filtered;
  make dispatch-only before merging).
- Open items from before: kept versions' bibliography warning not printed; partial render reports
  ledger `dataAdded`; step 6 needs the deployed site at `<out>/site`; dead links not reported;
  version rule not built; README pins v1.4.0; hash-mode not covered by browser items.
- Communicate with the user in Japanese, brief-me style.
