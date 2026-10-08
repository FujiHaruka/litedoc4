# Handoff — 2026-10-08 (multi-version: step 5, the reader, relay leg 1)

## Relay control
- Mode: ON
- Goal: implementation.md step 5 (the rebuild from nothing through the reader) to its "Done when", following the "Step 5 plan (2026-10-08)" order 1-7
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: step 5 plan (caf56ed); item 1 reader + oracle gate 10/10 (9e33548); item 2 World seam (b52d254); item 3 hybrid on S (0bbc24d); item 4 invariants (see git log)

## State

- Branch `multi-version`, pushed. Not `main`; no PR open. Relay leg 1 working on step 5.

## Where we are

`docs/multiversion/implementation.md` "Step 5 plan (2026-10-08)" items 1-4 are done, each with a
"Done" note: the reader + writer table (6 Leans) + `tools/reader-oracle-gate.sh`; the `World` seam
in `extractor/Extract.lean`; `reader extract` (hybrid) + `tools/reader-hybrid-gate.sh` on the
sample; per-run invariants (closure, `.ilean`). Item 5 (`build --versions` fills through the
reader, S with a v6 on v4.34.1, staleness by fill, one builder in litedoc4) is next / in progress;
then the M exactness checkpoint (a benchmarks/tools classification run, not a gate), item 6
(patch + print reuse, L checkpoint), item 7 (remaining writer records, delete prototypes/).

## Files to read first

- `docs/multiversion/implementation.md` — step 5 and its plan subsection
- `extractor/reader/OleanReader/` and `tools/reader-*-gate.sh`

## Load-bearing context

- Reader builds on v4.34.1 only (`build_reader` in `tools/lib/common.sh`, cuts `Extract.lean`'s
  trailing `main`). Both reader gates are `manual`. A change to `Extract.lean` needs
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
