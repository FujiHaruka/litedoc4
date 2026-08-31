# Handoff — 2026-08-31 (relay leg 6 → leg 7)

## State

- Branch: `main` @ `daa0d78`, clean, pushed. `c7790ef`'s CI is green; **`daa0d78`'s was
  still in flight** — check it first (`gh run list`). Its Lean-side gates were all run
  locally green, so a red there is news.
- **M1–M8 are complete.** M9 is next and is **the first irreversible milestone**.
- Measurement env: target `/Users/haruka/dev/lean-projects` @ `16ff7a40`, read only,
  verified untouched after M8 (705 oleans, its one untracked path). Oleans warm.
- **Disk 4.3 GiB free.** Swap is at its ceiling: 30 × 1 GiB swapfiles plus a 1 GiB
  `kernelcore` dated December 2021. A reboot would return ~30 GiB; that is the user's call
  and nothing below needs it.
- Scratch kept: `/private/tmp/lean-doc-relay/{purelean,m5-impact,m5-ledger}` — inputs other
  recordings take. The M8 clone and gate trees were deleted (recipe in the log below).

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 7 / cap 40
- Predecessor: purelean-r6
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1–r4: M1–M4 (see `git log`)
  - r5: M5–M7 complete, M8 all but `build-gate.sh`. `1e5f0b5`..`9b34b48`
  - r6: **M5's evidence retaken** with the corrected artefact list — **3,201/3,201**
    (was 3,145 over a denominator 8 artefacts too small), all 16 within-run sitecheck
    oracles identical (`c7790ef`). **M8 complete** — `build-gate.sh all` green driving
    both halves, which found **a real Lean defect** and two environment defects
    (`daa0d78`).

## Next step

**M9.** Read `.claude/purelean-plan.md` §M9 first. Two items in it are not plain
repository work; **look at each before deciding it needs the user**:

1. **`public-surface.txt`'s `binary-source`** — the plan writes its「去就」as undecided.
   It is a promised 1.x name, and `tools/public-surface-gate.sh` fails when one goes
   missing. Read what it actually promises before treating removal as a user decision.
2. **`https://fujiharuka.github.io/information-theory/`** — built by whatever litedoc4
   *that* repository pins. Bumping it edits **another repository** and changes a live
   public site. That one is outward-facing; confirm before doing it.

The rest of §M9 (`action.yml`'s binary resolution, `lakefile.lean`'s `resolveLitedoc4`,
`release.yml`, the two release gates, built JS into the tree) is git-reversible.

## Files to read first

1. `.claude/purelean-plan.md` §M9 / §M10 — the SoT for this relay
2. `benchmarks/results/purelean-build-gate-2026-08-31.txt` — M8's verdict, the real cost
   of a clone, and the defect class in "3."
3. `tools/public-surface.txt` + `tools/public-surface-gate.sh` — item 1 above
4. `benchmarks/results/purelean-incremental-retake-2026-08-31.txt` — M5's denominator

## Load-bearing context

- **"Do not start build-gate under 20 GiB free" is dead** (measured). A clone plus
  `rebuild-own.sh` costs **1.92 GiB and 666 s**, of which 1 GiB was one new swapfile.
  **Lake 5.0.0 has no job-count option at all** — a `--jobs` knob was written, proven
  against a stub, and reverted when lake rejected `-j`. **The stub proved the call site,
  not the contract**; that is the lesson, not the knob.
- **A clone is only `baseline` because `setup-clone.sh` now runs `git clean -fd`.** Both
  gates read `git status --porcelain`, which counts untracked paths, and the target
  carries `docs/doc-gen-bench/`. Before the fix every clone was `unknown` and every phase
  refused — which is why `build-gate.sh` had never reached a verdict.
- **The defect class M8 found is "the request's resolved path vs the layout's derived
  one".** `carriesAPreviousRun` asked `Layout.linkIndex` where Rust asks the request's, so
  every second `build` with `--link-index` took the full path for ever — and **a full
  generation of the same sources writes the same site**, so no byte comparison could see
  it. The same mistake sat in `Watch.lean`. **When M9/M10 touch either half, check this
  shape again**: `Layout` fields that are defaults are not the resolved values.
- **`*-reference.sh` recordings take ~5 minutes each, not the 45 the last handoff said.**
- **`pgrep -f '<pattern>'` matches the polling shell itself.** A `while pgrep -f 'foo.sh'`
  loop never exits because its own command line contains `foo.sh`. Write the pattern with
  a bracket class — `'foo[.]sh'` — which matches the target and not the poller.
- **`/usr/bin/env bash` here is bash 3.2**, where an empty `"${arr[@]}"` under `set -u`
  is an unbound-variable error, not zero words. `${arr[@]+"${arr[@]}"}` is the form.
