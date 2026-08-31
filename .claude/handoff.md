# Handoff — 2026-08-31 (relay leg 5 → leg 6)

## State

- Branch: `main` @ `9b34b48`, clean, pushed. CI green through `c83966d`; `9b34b48` was
  pushed last and its run should be checked first (`gh run list`).
- **M5, M6, M7 are complete. M8 is complete except `build-gate.sh`.** M9 is next and is
  **the first irreversible milestone** — read `.claude/purelean-plan.md` §M9 before touching it.
- Measurement env: target `/Users/haruka/dev/lean-projects` @ `16ff7a40`, read only, untouched.
  Oleans warm. **Disk 4.7 GiB free and swap is holding 29 GB** — `df -h /` before every build.
  `target/debug` was deleted this leg to make room, so **`cargo test --workspace` needs a
  rebuild first**; no Rust file was changed in M5–M8, so nothing is owed to it yet.
- Oracles still on disk: `/private/tmp/lean-doc-relay/{purelean,m5-impact,m5-ledger,m5-merge}`.
  **`m5-incr` was deleted** — the plan's M5 table says how to retake it.

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 6 / cap 40
- Predecessor: none (leg 5 ran in the user's own session)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1–r4: M1–M4 (see `git log`; the earlier ledger entries were compacted away with the plan)
  - r5: **M5 complete** (U1–U13; five judges green, micro gate 14→16 items) /
    **M6 complete** (`watch` + HTTP on `Std.Async.TCP`, gate 12/12) /
    **M7 complete** (whole CLI surface, `public-surface-gate` reads both halves) /
    **M8 all but `build-gate.sh`** (whole-target build 867/871, all 4 under `work/`).
    21 commits, `1e5f0b5`..`9b34b48`. Five new logs under `benchmarks/results/purelean-*`.

## Next step

**Two things, in this order.**

1. **Retake the incremental recordings on both halves.** `tools/incremental-reference.sh`
   carried a fifth copy of the doc-gen4 six-name artefact list, so each scenario's
   `<s>-global/` compared **1 real file and 5 self-agreeing absences**. Fixed this leg (it
   now reads `tools/site-artefacts.txt` and writes `<s>-global.count.txt`: **9 compared,
   3 absent**), but **the recordings M5's evidence rests on were taken with the old
   list, and they are deleted**. Retake Rust then Lean, compare, and only then is M5's evidence what it says.
   Inputs are in the plan's M5 table. ~45 min per recording; `--ref-site` is now required.
2. **`build-gate.sh all` for both halves** — the last of M8. It needs a clone whose own
   oleans are rebuilt at the clone's path, and `tools/rebuild-own.sh` drove swap +2 GiB in
   90 s and took free disk 5.8 → 3.8 GiB after 57 of 422 modules (measured). **Do not start
   it under 20 GiB free.** The `LITEDOC4` variable is already wired and was made to fail.

Then M9. It is irreversible and touches two live sites; `.claude/purelean-plan.md` §M9 lists
what goes.

## Files to read first

1. `.claude/purelean-plan.md` — the SoT for this relay. §M5 "M5's evidence was narrower than
   it said" and §M8 are the two live items; §M9 is what comes next
2. `benchmarks/results/purelean-target-build-2026-08-31.txt` — M8's numbers and the section
   "Why build-gate has no verdict here"
3. `tools/incremental-reference.sh` — the corrected `GLOBAL_ARTIFACTS` and `copy_globals`
4. `benchmarks/results/purelean-async-tcp-2026-08-31.txt` — why M6 was not where the plan broke

## Load-bearing context

- **The doc-gen4 six-name artefact list has now been found in five places** (clone-gate and
  build-gate, collected 2026-08-29; `global-compare.sh` and `site-compare.sh` and
  `incremental-reference.sh`, this leg). Every one reported *absent on both sides* and so
  agreed with itself. **Before adding any comparison over a site, check where that list
  lives** — the inventory is `tools/site-artefacts.txt`.
- **A gate that skips silently is invisible to a comparator that counts files.**
  `incremental-reference.sh` wrapped its own within-run oracle in `if [ -d "$REF_SITE" ]`
  and the default path had rotted, so `base-sitecheck.txt` was never written and
  `incremental-compare.sh` skips that name by design. Made a hard exit this leg.
- **CLAUDE.md's Language rule: new text written into `.claude/` is English.** M5–M7's plan
  sections were added in Japanese this leg by mistake; M8's is English. **Do not translate
  the old text** (that is the opportunistic translation the rule forbids) — write new text
  in English.
- **`"serve": true` in a timings record means "the resident path was selected", not "a
  process exists".** Reading it as the latter is how the lazy start would pass untested.
- **Lean moves a pure computation to where its value is first used**, so a `let` between two
  `IO.monoNanosNow` measures nothing (`Global/Delta.lean` reported 84 ns for a 212-module
  scan). `timedPure` is the fix; any future Lean stage timing a pure phase has the same hole.
- **`ExceptT ε IO α` is definitionally `IO (Except ε α)`** — `let x ← f …` already propagates,
  and `match ← f … with | .error …` fails to elaborate.
- **Do not rebuild the Lean binary while a `*-reference.sh` is recording** — the recording
  dies mid-scenario and leaves a directory that looks complete but for `conditions.txt`.
