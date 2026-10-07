# Handoff — 2026-10-07 (multi-version: step 4 done; next = why the render's memory grows per version)

## State

- Branch `multi-version`, pushed, clean. Not `main`; no PR open.
- CI: all six workflows green at `9ce4ed1`; `ci`, `ci-lake`, `ci-action` green again at `250446c`
  (usage block refrozen); `8ff6afd` is docs only.
- SoT: `docs/multiversion/plan.md`, `docs/multiversion/implementation.md` (step 4: "What exists",
  "First L checkpoint — run 2026-10-07", "Built: render only the versions the site does not
  already hold").
- Step 4 is done: S Done-when met (r1); L checkpoint run twice on `ubuntu-latest`
  (`benchmarks/results/mv-l-prediction-2026-10-07.txt` committed before,
  `mv-l-step4-2026-10-07.txt`, `mv-l-step4-incremental-2026-10-07.txt`); four >25% misses
  recalibrated in the log and the plan; adding a release 16.6 → 13.5 min (one run) with the
  render ledger; the added-to site equals the from-nothing one, 59,819 of 59,819 files.

## Relay control
- Mode: DONE
- Goal: step 4 of `docs/multiversion/implementation.md` to its "Done when", including the first L
  checkpoint, optimisation, logging and recording.
- Leg: 2 / cap 8
- Predecessor: none (mvstep4-r1 killed)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Summary: done. Mathlib cache fetch in `build --versions`, per-phase times, L run twice, render
  ledger (render only what the site lacks) — adding a release 13.5 min on three versions.
- Progress ledger
  - r1: build --versions + masked staleness + S v5 (a012811); static gates' questions rehomed
    (ae166b0); search-page race fixed (6fd53ff); build/watch switched, static path + gates
    retired (72c5993); dead code −11.5k lines, print fix (2a21bc7); Windows gate fixes
    (b579eba, 5517a72); one-version store keeps one entry (3b5d0cc); docs (a380219). CI green.
  - r2: Mathlib cache + phase times (6d16aae); L workflow, driver, prediction (e1ec80e); first L
    (acbebf9); render-ledger plan (1a59ef0) and implementation, S 63 items (bc9d4f3); L run with
    memory-by-version and identity (9ce4ed1); usage refrozen (250446c); second L log (8ff6afd).

## Next step (user, 2026-10-07: do the recommended investigation)

**Why does the render's peak memory grow ≈ 0.57 GiB per version within one process?** Measured on
the runner (`benchmarks/results/mv-l-step4-incremental-2026-10-07.txt` (4)): `store render` of
1 / 2 / 3 Mathlib versions peaks at 3.67 / 4.23 / 4.82 GiB, though the render loop holds one
version's data at a time (it keeps only small per-version counts and `versions.json` rows).
It matters because a full render (every litedoc4 upgrade, since the render key is the executable)
of 11 versions would peak ≈ 9.4 GiB (extrapolated) and 51 would not fit 16 GB.

1. Reproduce at M locally, not L (disk ≈ 12 GiB): the kept M store
   `/private/tmp/lean-doc-relay/mv-m/store` is schema 4 and the product reads schema 5, so re-put
   the three M versions first (or build a store from S's five versions as a second, smaller
   probe). At M the step-2 log had 221 MiB alone vs 253 MiB for three (+16 MiB/version) —
   check whether growth per version is ∝ declarations (≈ 0.57 GiB / 14.49 ≈ 40 MiB expected at M)
   or something else.
2. Measure peak RSS for 1, 2, 3 versions (`/usr/bin/time -l`, 5 runs each, warm) and, for one
   version rendered twice (same version listed twice is refused? then render v, v' identical
   entries) — to tell "per version retained" from "allocator high-water mark".
3. Suspects, in order: something in the render loop or `writeVersion` that outlives its
   iteration (a cache, an interned table, the `d/` dedupe set); Lean's allocator not returning
   freed pages (then RSS grows but live memory does not — distinguish with a run that renders
   the largest version last vs first); the gzip/content-addressing path.
4. If it is retained data: fix it so the peak is one version's, gate it with a count (not RSS —
   CLAUDE.md: no wall-clock/RSS gates; a deterministic proxy, or record only), log to
   `benchmarks/results/`, update implementation.md's "On L" bullet and the handoff Open list.
   If it is the allocator: write that down with the evidence; the lever then is one process per
   version (or per batch) in a full render.

## Open (not blocking)

- **The render's memory grows ≈ 0.57 GiB per version within one process** (3.67 / 4.23 / 4.82 GiB
  for 1 / 2 / 3 Mathlib versions) though it holds one version's data at a time; ≈ 9.4 GiB for a
  full render of 11 (extrapolated). A full render follows every litedoc4 upgrade. Unexplained —
  the question before 11 versions. Cheap experiment: the M store locally (the kept
  `/private/tmp/lean-doc-relay/mv-m/store` is schema 4, the product writes 5 — re-put first).
- A kept (not re-rendered) version's bibliography warning is no longer printed.
- After a partial render, kept versions report their ledger's `dataAdded`, so the counts JSON
  reads as a from-nothing render in that order. Site bytes unaffected.
- `.github/workflows/mv-l.yml` has a `push:` trigger on `multi-version` (dispatch cannot reach a
  workflow not on `main`); make it dispatch-only before merging.
- Step 6 premise: the incremental render needs the deployed site at `<out>/site` when the build
  starts (≈ 300 MB at three versions, ≈ 1 GB at 11).
- The build no longer reports dead links (the list is collected, nothing reads it).
- Nothing checks `Example.Gen.Solo.ext`'s expected "no origin" by name since e2e GATE 9 retired.
- The version **rule** (Mathlib: non-prerelease releases) is not built; only an explicit list.
  Any version sort needs a `#guard` that v4.9.0 < v4.10.0.
- README still pins `v1.4.0` while describing this branch (release-time concern, step 6).
- `e2e/micro/Example.lean:34`, `e2e/micro/litedoc4.toml:3` name the retired `config-gate.sh`;
  editing `e2e/micro` moves S's v1 and breaks `tools/mv-s/expected.txt` — leave unless S is
  re-derived.
- Hash-mode is not covered by the 13 new browser items; the 404 redirect under a sub-path
  (`/litedoc4/`) is not tested.
- Page-script size (for the Preact question): 37 `web/src` files, 2,750 lines (2,507 non-blank);
  `site.js` 40,146 B, 12,293 B gzip — counted at 2a21bc7, nothing under `web`/`assets` changed
  since.

## Load-bearing context

- **Kept**: `/private/tmp/lean-doc-relay/mv-m/store`, `mv-m-settle`, `mv-m-render-path` /
  `mv-m-render-hash`, `mv-v4320` / `mv-v4341` (7.7 + 7.6 GB). Disk ≈ 12 GiB free; reclaiming the
  kept Mathlib dirs is the user's call. L runs only on the runner (`mv-l.yml`).
- The session shell is zsh: use `bash -c` with arrays in CI wait loops.
- `ci-lake.yml` (refusal-gate) and `ci-browser-windows.yml` run only when dispatched on the
  branch. A help-text change needs `tools/refusals.txt`'s `@usage` block refrozen from
  `litedoc4 --help-all` (every line `| `-prefixed, the trailing empty lines kept).
- A stale tmux session `mvstep2-r2` from the step-2 chain is still alive; not this chain's.
- Communicate with the user in Japanese, brief-me style, no code names in briefs.
