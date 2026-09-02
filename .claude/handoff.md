# Handoff — 2026-09-02 (both open candidates closed)

## State

**`main` is at `9b7b7df`, clean, and the two candidates the previous handoff left are done.**
Both went through a PR because their evidence is a CI run: the memory gate cannot answer on
this machine at all.

- `6d5b877` (PR #5) — **the bash 3.2 answer guard**. A script under `set -euo pipefail` with an
  EXIT trap reported a `set -u` abort as **exit 0**; ten scripts under `tools/` were in that
  shape and only `md-memory-gate.sh` defended itself
- `9b7b7df` (PR #6) — **the memory gate's optimisation level**. It compiled the C at a
  written-down `-O1` against a product Lake builds with **no `-O` at all**

Gates on `main`: `DOCS GATE: 220 citations` · `WORKFLOW GATE: 33 gates, 26 ci, 7 manual` and
`10 script(s) trap under set -e and every one claims its answer` · `VERSION GATE: ok — 1.4.0` ·
`PROVENANCE`, `PUBLIC SURFACE`, `MD ORACLE`, `libc-shim` ok · `MD MEMORY GATE: ok (6 of 6)` on
ubuntu-latest, **0 of 6 and exit 2 on macOS**.

## Relay control
- Mode: DONE
- Goal: the two candidates left by leg 2 — the bash 3.2 hole, and the memory gate's `-O`
- Leg: 3 / cap 8
- Predecessor: leg 2 (`cada28c`)
- Stop-on: completion
- Progress ledger:
  - r3: **answer guard** (PR #5, `6d5b877`) · **md-memory takes the product's `-O`**
    (PR #6, `9b7b7df`) · both merged, `main` green

## What this leg established

- **`tools/lib/common.sh` has `answer_required` / `answer`.** Opt-in, so the scripts that source
  it and do not ask keep answering exactly what they did. A 0 no path claimed becomes **70**.
  `exit 70` and not `return 70` — under `set -uo pipefail` a trap's return value is discarded
- **The reach was written down too wide.** `set -e` is what makes it a hole: under
  `set -uo pipefail` the same abort exits 1. Of the thirteen scripts combining `set -u` with a
  trap, **ten are exposed and three are not** (`render-compare.sh`, `site-compare.sh`,
  `watch-gate.sh` — C1 had counted the last of those as covered by CI's bash 5)
- **`tools/workflow-gate.sh` question 5** keeps the pairing: `answer_required` present, no bare
  `exit 0` left, and the last executable line is an answer. Made to fail once in each part
- **`md-memory-gate.sh` reads `PRODUCT_OPT` out of `lakefile.lean`'s `ccFlags`**, the way it
  already reads the md4c flag word out of the Lean sources. It refuses (exit 2) if `ccFlags` is
  gone or names two levels; both refusals were made to fail once
- → `benchmarks/results/bash32-answer-guard-2026-09-02.txt`,
  `benchmarks/results/md-memory-opt-2026-09-02.txt`, and the last two sections of
  `docs/verification-log.md` before 書き方

## Candidates for a next session

Nothing is open that a previous session named. If a next one is wanted:

1. **Three of the ten never ran end to end** — `deps-docs-gate.sh`, `extractor-mismatch.sh`,
   `extractor-uniqueness.sh`. Their claim is `bash -n`, the entry paths and question 5, and the
   verification log says so. `deps-docs` was **deliberately not run**: it rebuilds the target's
   site, and `/Users/haruka/dev/lean-projects/.lake/build/doc` there is A1's oracle
2. **The A1 oracle is still alive and still cannot be rebuilt.** `lake update` or a `.lake` wipe
   in the target destroys it. Ask any doc-gen4-shaped question before touching the target
3. **`answer` has a one-call-wide window** — a path that claims and then dies before `exit`
   would still answer 0. Closing it would need the claim to be the exit, which it already
   nearly is

## What a future session must not misread

- **`tools/md-memory-gate.sh` answers 0 of 6 and exits 2 on this machine.** A program built with
  `-fsanitize=address` never reaches its own `main` on this macOS. **That is not a pass and not
  a broken gate** — ubuntu-latest is where the six are answered
- **A gate here that combines `set -e` with an EXIT trap must end by saying its answer.**
  Question 5 fails a new one that does not, and the symptom of forgetting is **exit 70 on a run
  that printed "ok"** — which is how `publish-pages.sh` was caught on the way in
- **The seconds in `md-memory-opt-2026-09-02.txt` are not a comparison.** 3.09 s at the product's
  level, 5.38 s and 6.6 s at `-O1` — three single runs on three runner instances, and the
  5.38 / 6.6 spread is the same code at the same level

## Files to read first

1. `tools/lib/common.sh` — `on_exit`, then the `answer_required` / `answer` block below it
2. `tools/workflow-gate.sh` question 5 (header, and the block near the end)
3. `docs/verification-log.md` — the last two sections before 書き方
