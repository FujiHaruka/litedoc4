# Handoff — 2026-10-07 (multi-version: step 4 implemented on S; r2 = first L checkpoint)

## State

- Branch `multi-version`, pushed, clean. Not `main`; no PR open. All six CI workflows green on the
  step-4 commits (last: `3b5d0cc`, ci / ci-lake / ci-action; the Windows browser workflow green at
  `5517a72`). `a380219` is docs only.
- SoT: `docs/multiversion/plan.md`, `docs/multiversion/implementation.md` (step 4 now has its
  "What exists (2026-10-07)" block; the three S "Done when" items are met by `loop-empty`,
  `loop-remove-one`, `loop-identity`; **the first L checkpoint is not run**).
- One render path: plain `build` / `watch` = the working tree as one version (first 12 hex of its
  source commit), `<out>/store` holds exactly that version; `build --versions <refs>` builds the
  set (worktree, elan install, `lake build`, extractor per toolchain under `<out>/extractors`,
  extract, put, delete; staleness ignores the identity's `lean`/`leanGithash`). The static path,
  its subcommands, tests and gates are gone; `tools/mv-s-gate.sh` (59) and `tools/mv-pages-gate.sh`
  (46) carry their questions.
- User (2026-10-07): the sample site's URL changing every push is fine.

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
- Leg: 2 / cap 8
- Predecessor: mvstep4-r1 (kill it once r2 is running)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger
  - r1: build --versions + masked staleness + S v5 (a012811); static gates' questions rehomed
    (ae166b0); search-page race fixed (6fd53ff); build/watch switched, static path + gates
    retired (72c5993); dead code −11.5k lines, print fix (2a21bc7); Windows gate fixes
    (b579eba, 5517a72); one-version store keeps one entry (3b5d0cc); docs (a380219). CI green.

## Next step (r2: the first L checkpoint)

1. **Mathlib's cache is not fetched yet**: `build --versions` runs `lake build` per checkout and
   never `lake exe cache get`, so a Mathlib version would build Mathlib from source. Add it to the
   one bounded per-version preparation function (when Mathlib is in the checkout's manifest),
   modelled on `benchmarks/tools/mv-m-run.sh:341–472` (cache dir per version, deleted after).
   Gate what S can (it cannot see Mathlib); M can.
2. Run M through the product command (`build --versions` over the three M releases) before L, and
   compare per-phase time and counts with the M prediction (`benchmarks/results/mv-m-*`).
3. L on the runner: three versions (v4.32.2 / v4.33.0 / v4.33.1 per implementation.md) from
   nothing, then by adding the third — a workflow on `ubuntu-latest` (dispatch on the branch; a
   new workflow must exist on `main` to be dispatched by name, else give it a `push:` trigger on
   this branch). Every phase against the M prediction; log to `benchmarks/results/`; record in the
   plans; >25% misses recalibrated and written down.
4. DONE brief must include: page-script size after the static path left — 37 `web/src` files,
   2,750 lines (2,507 non-blank), all reachable from the three bundles; `site.js` 40,146 B, 12,293 B
   gzip (counted 2026-10-07 at 2a21bc7).

## Open (not blocking; mention in the DONE brief or fix if cheap)

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

## Load-bearing context

- **Kept**: `/private/tmp/lean-doc-relay/mv-m/store` (three M entries, schema 4 — re-put if the
  record schema moved); `mv-m-settle`, `mv-m-render-path` / `mv-m-render-hash`, `mv-s-gate`
  (old, may be deleted), `mv-v4320` / `mv-v4341` (7.7 + 7.6 GB). Disk ≈ 12 GiB free — check before
  any Mathlib checkout; reclaiming the kept Mathlib dirs is the user's call.
- The session shell is zsh: `for i in $ids` does not split — use `bash -c` or arrays in CI wait
  loops (two watchers spun for hours on 2026-10-07).
- `ci-lake.yml` (refusal-gate) and `ci-browser-windows.yml` run only when dispatched on the
  branch; dispatch all six after a change that reaches them.
- A stale tmux session `mvstep2-r2` from the step-2 chain is still alive; not this chain's.
- Communicate with the user in Japanese, brief-me style, no code names in briefs.
