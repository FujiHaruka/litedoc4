# Handoff — 2026-10-10 (multi-version: step 5, the reader, relay leg 4)

## Relay control
- Mode: ON
- Goal: implementation.md step 5 (the rebuild from nothing through the reader) to its "Done when", following the "Step 5 plan (2026-10-08)" order 1-7 and, for item 6, the "Item 6 plan" order 1-9
- Leg: 4 / cap 8
- Predecessor: mvstep5-r3
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: step 5 plan (caf56ed); item 1 reader + oracle gate 10/10 (9e33548); item 2 World seam (b52d254); item 3 hybrid on S (0bbc24d); item 4 invariants (4006603); item 5 build --versions fills through the reader, tools/mv-reader-gate.sh 12/12 (2d2f02f)
  - r2: M checkpoint run + classifier + .ilean imported-parent rule (c2ed2d4); two defects fixed, M 0 defects, hybrid gate 22/22 (956aab6); item 6 plan (85ea428); item 6 step 1 reuse seam (2723324, CI green both); item 6 step 2 reader session + manual root rewritten per round, hybrid gate 24/24, mv-reader 12/12 (fb5698a)
  - r3: item 6 step 3 patch + --check-patch (db0c88c); step 4 reuse under recomputed key N1X+own (df25439); step 5 carried key + --check-keys on S, two-list #guard (5d5a1ad); step 6 build --versions over one session, mv-reader 14/14 (5f0fbf9); reader built at -O3 (was -O0), phases line, session overhead = content hash (7d2ed9a); native extractor -O3 tried (62a7d22) and reverted on Mathlib measurement (f18b7e9); incremental build no longer continues another extractor's IR, e2e-micro GATE 6 (0aa5729); real extractor identity replaces the hand-bumped constant for ledger, dependency map and watch (7b3c4f2). CI green on 7b3c4f2 (6 workflows).

## State

- Branch `multi-version`, pushed, clean at f18b7e9. Not `main`; no PR open.
- CI dispatched on f18b7e9 (`ci.yml`, `ci-action.yml`, `ci-template.yml`, `ci-lake.yml`): **check them first** (`gh run list --branch multi-version -L 4`; full SHA for `--commit`). Everything before was green on 7b3c4f2.

## Where we are

`docs/multiversion/implementation.md` → "Item 6 plan": steps 1–6 done, each with a "Done" note (step 5 is "Done on S"; its M half belongs to step 7). Step 6's note has the "Answered 2026-10-09" paragraph (session overhead = content hash; reader -O0 → -O3; **every reader time recorded before it was -O0**, incl. item 5's 99 s/version on M) and the native-extractor -O0 decision with numbers.

Next, in order:
1. **Step 7 (M)**: `benchmarks/tools/mv-m-run.sh --through-reader --session`, three versions at the `mv-m-reader-fixed` commits; entry equality, `--check-keys`/`--check-patch` 0, per round reused / reprinted / rewritten modules and the `phases` line. **The Mathlib workspaces are gone** (a reboot on 2026-10-08 emptied `/private/tmp`): `mv-v4341` (Mathlib v4.34.1 slice, the newest), `mv-v4320`, `mv-m/store` (old native M store), `u13-host`, `mv-l-r3`. Read `mv-m-run.sh`'s header for how each is made and rebuild what step 7 needs (disk 32 GiB free; each Mathlib checkout ≈ 7.7 GiB). Step 5's "then on M" (check-keys 0 on M) is answered here; the carry's open costs on M are in step 5's note.
2. Step 8: both reader gates once on `ubuntu-latest` (the reader has never run on Linux).
3. Step 9: L via `mv-l.yml`, prediction committed first. The L store copy came from a CI artifact that **expires 2026-10-21**.
4. The M1 per-extra-version measurement (plan's "Measurement" section; its 146–160 s prediction was composed at -O3 but without proofs — the tree decodes and hashes proofs).
5. Item 7 (records v4.29.0/v4.29.1/v4.30.0/v4.32.1/v4.34.0, then delete `prototypes/olean-reader/`, rewriting the Item 6 plan's pointers to `differential-design.md` to a commit).

## Files to read first

- `docs/multiversion/implementation.md` — "Item 6 plan" (steps 1–6 Done notes, steps 7–9, Measurement)
- `benchmarks/tools/mv-m-run.sh`, `extractor/reader/OleanReader/{Hybrid,Patch,PrintKey,Carry}.lean`

## Load-bearing context

- Reader builds on v4.34.1 only, now at `-O3 -DNDEBUG` (`readerCFlags`); the native extractor stays -O0 on purpose (one-line why-not in `extractorFor`). Rebuild litedoc4 with `tools/build-lean-exe.sh --toolchain-from e2e/micro` after any reader or `Extract.lean` edit, before gates. Reader gates (`reader-hybrid` 31, `mv-reader` 14, `reader-oracle` 10) are `manual`.
- The measurement target now globs **419 modules** (`--lib InformationTheory`), not 422: new numbers carry 419.
- **Subagent prompts**: tell them to run gates in the foreground (≤ 10 min) and to batch anything longer into one background job, waiting once — otherwise they stop a dozen times and each stop notifies. Do not reply to interim "waiting for X" notices (user feedback 2026-10-09).
- `pgrep -f` misreports on this machine; use `ps -axww -o pid,ppid,args | rg …` (`com.apple.ifdreader` is an unrelated system process). zsh does not word-split `$ids` — run CI wait loops under `bash -c`.
- GitHub Actions caches are branch-scoped: a CI bisect on a temp branch starts with empty caches and may not reach the path under test (that is how 62a7d22 was wrongly blamed).
- `mv-l.yml` still has the glibc-tuned arm (e) and a `push:` trigger on this branch (make dispatch-only before merging).
- Open items: `docs/provenance.md` has no row for Lean-core-derived code in `extractor/reader/`; a reader-filled version has no tactic list; kept versions' bibliography warning not printed; partial render reports ledger `dataAdded`; step 6 of the main plan needs the deployed site at `<out>/site`; dead links not reported; version rule not built; README pins v1.4.0; hash-mode not covered by browser items; reader: hash could be fused into decode (≈ 4.4 s of an 11.5 s S round), session manual-root ask 1.9–2.1 s vs 1.0–1.6 s alone; watch does not notice an `--extractor-bin` replaced mid-session; `ledger check` cannot report an extractor change; README's "the extractor took ~16 s there" still holds (native stays -O0).
- Communicate with the user in Japanese, brief-me style.
