# Handoff — 2026-10-10 (multi-version: step 5, the reader, relay leg 4 — PAUSED)

## Relay control
- Mode: PAUSED
- Goal: implementation.md step 5 (the rebuild from nothing through the reader) to its "Done when", following the "Step 5 plan (2026-10-08)" order 1-7 and, for item 6, the "Item 6 plan" order 1-9
- Leg: 4 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Paused for: a user decision on the reader's direction. Item 6 steps 7-9 and the M1 measurement are done and recorded; every one says the session (patch + print reuse + carried key) is exact but slower than reading each version alone, and does not fit the runner's memory. The plan's own fallback (read-alone per version) is written down; whether to also invest in the session levers, or to reconsider the reader path itself, is the question.
- Progress ledger:
  - r1: step 5 plan (caf56ed); item 1 reader + oracle gate 10/10 (9e33548); item 2 World seam (b52d254); item 3 hybrid on S (0bbc24d); item 4 invariants (4006603); item 5 build --versions fills through the reader, tools/mv-reader-gate.sh 12/12 (2d2f02f)
  - r2: M checkpoint run + classifier + .ilean imported-parent rule (c2ed2d4); two defects fixed, M 0 defects, hybrid gate 22/22 (956aab6); item 6 plan (85ea428); item 6 step 1 reuse seam (2723324); item 6 step 2 reader session (fb5698a)
  - r3: item 6 steps 3-6 (db0c88c, df25439, 5d5a1ad, 5f0fbf9); reader -O3 (7d2ed9a); native extractor -O3 tried and reverted (62a7d22, f18b7e9); incremental build vs another extractor's IR (0aa5729); real extractor identity (7b3c4f2)
  - r4: step 7 M through the session, mv-m-run.sh --session (de4a7f4); step 8 reader gates on ubuntu-latest 10/31/14 (0b91e09); step 9 prediction (3f6fc10) + mv-l rewrite (faf895c), L session killed twice by memory (120ce6b), L read-alone from nothing (8d84fef); M1 per extra version (e4492ba)

## State

- Branch `multi-version`, pushed, clean at the handoff commit. Not `main`; no PR open. CI green on f18b7e9 (4 workflows); later commits touched only docs, benchmarks/ and mv-l.yml.
- `/private/tmp/lean-doc-relay/mv-v4341` (Mathlib v4.34.1 workspace, full cache) and `mv-v4320` (v4.32.0) exist again; ~15 GiB free on disk.
- `mv-l.yml` now runs arm (c): every older version read alone from nothing (`mv-l-run.sh scratch`); the session/alone/compare subcommands are still in the script. It keeps its `push:` trigger on this branch (make dispatch-only before merging).

## The numbers that decide it (all measured, one run each unless said)

| | session round | read-alone, same version |
|---|---|---|
| M (433-438 modules, M1, --jobs 1) | 58-66 s | 37-42 s |
| M1, all of Mathlib, v4.31.0 -> v4.32.0 | 876.5 s median of 5, footprint 16.2 GB | 529.1 s, footprint 13.2 GB |
| L on ubuntu-latest (16 GB + 3 GB swap) | round 1 1,184 s; round 2 killed the runner (twice) | 642-701 s, 11.1 GiB anon, swap within 7 MiB of full |

Native extraction of one Mathlib version on the same runner type: 556-594 s (step 4, 2026-10-07) and 565 s (v4.34.1, 2026-10-10). Target: 1.2 min per extra version.
Where the session's time goes: the content hash (321-399 s on full Mathlib, 2.3x the decode); the carried key saves nothing (90-103 s against a fresh pass's 78-85 s); decode is single-threaded. Records: `benchmarks/results/mv-m-session-2026-10-10.txt`, `mv-l-session-2026-10-10.txt`, `mv-l-reader-alone-2026-10-10.txt`, `mv-m1-extra-version-2026-10-10.txt`.

## Next, depending on the decision

- Fallback (the plan's, "Undone if memory does not fit the runner … Fallback: read-alone per version"): `build --versions` defaults to read-alone, the session behind a `--help-all` flag; `tools/mv-reader-gate.sh` items `patched-equals-alone` / `check-keys` / `reader-check` pass the session flag explicitly.
- Session levers, if pursued: fuse the hash into the decode (the prototype decoded and hashed all of Mathlib in 48.7-57.2 s on the M1); drop the carry (recompute is faster); share while decoding so a round never holds two whole states.
- Then item 7 (records v4.29.0/v4.29.1/v4.30.0/v4.32.1/v4.34.0, delete `prototypes/olean-reader/`, rewrite the Item 6 plan's pointers to `differential-design.md` to a commit).

## Load-bearing context

- Reader builds on v4.34.1 only, at `-O3 -DNDEBUG`; the native extractor stays -O0. Rebuild litedoc4 with `tools/build-lean-exe.sh --toolchain-from e2e/micro` after any reader or `Extract.lean` edit, before gates. Reader gates (`reader-hybrid` 31, `mv-reader` 14, `reader-oracle` 10) are `manual`; they passed on ubuntu-latest once (the oracle gate also needs v4.32.0 installed).
- The measurement target globs **419 modules** (`--lib InformationTheory`).
- Subagent prompts: gates in the foreground (≤ 10 min), anything longer as one background job waited once. Do not reply to interim "waiting for X" notices.
- `pgrep -f` misreports on this machine; use `ps -axww -o pid,ppid,args | rg …`. zsh does not word-split `$ids` — run CI wait loops under `bash -c`.
- Open items carried from r3: `docs/provenance.md` has no row for Lean-core-derived code in `extractor/reader/`; a reader-filled version has no tactic list; kept versions' bibliography warning not printed; partial render reports ledger `dataAdded`; step 6 of the main plan needs the deployed site at `<out>/site`; dead links not reported; version rule not built; README pins v1.4.0; hash-mode not covered by browser items; watch does not notice an `--extractor-bin` replaced mid-session; `ledger check` cannot report an extractor change. From r4: on M, 2 unshared entries dirtied 123 newest modules (time, not correctness); decode/hash/finalize grew round to round on the same modules.
- Communicate with the user in Japanese, brief-me style.
