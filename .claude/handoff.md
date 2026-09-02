# Handoff — 2026-09-02 (relay leg 2, closed)

## State

**All four follow-ups after the pure-Lean port are done.** `main` is at `3ecaa2e`, clean.
Leg 1 closed C2 and B1+B2; this leg closed **A1** and **C1**, and fixed a version gate that
had been turning `main` red on every commit after a release.

- `d58cbb6` **A1** — the three doc-gen4 comparisons, asked once against the live oracle
- `abd5922` + `ff9bf9c` — the version gate's item 3 asked HEAD a question only a release
  can answer; `main` had been red since `3a62874` for exactly that
- `3ba890f` + `3ecaa2e` **C1** — `tools/md-memory-gate.sh`, merged through PR #4 so that
  its six items were proved on Linux before they reached `main`

Gates after this leg: `DOCS GATE: 211 citations` · `WORKFLOW GATE: 33 gates, 26 from a
workflow, 7 manual` · `VERSION GATE: ok — 1.4.0` · `PROVENANCE GATE: ok` ·
`PUBLIC SURFACE` 10/4/16/13/2 · `MD MEMORY GATE: ok (6 of 6)` on ubuntu-latest, **0 of 6 and
exit 2 on macOS**.

## Relay control
- Mode: DONE
- Goal: the four follow-ups after the pure-Lean port — C2, B1+B2, A1, C1
- Leg: 2 / cap 8
- Predecessor: none (leg 1 was the user's own session)
- Stop-on: completion
- Progress ledger:
  - r1: **C2** (`3dd37e3`) · **B2 + 1.4.0** (`abaf743`, `3cc0d6e`) · **v1.4.0 released** ·
    information-theory pin bumped and its site rebuilt green · two silent-green holes closed
  - r2: **A1** (`d58cbb6`) — 3 doc-gen4 comparisons run once, all three agree, 0 unexplained
    disagreements · **version gate fixed** (`abd5922`, `ff9bf9c`) — `main` was red and is
    green again · **C1** (`3ba890f`, `3ecaa2e`) — the C memory gate, 6 of 6 in CI

## What this leg established, and where it is written down

- **A1** → `benchmarks/results/docgen4-comparison-2026-09-02.txt`,
  `docs/verification-log.md` "A1". 341 shared pages carry doc-gen4's anchors in doc-gen4's
  order; 12 of 21 roots produce the URL doc-gen4 wrote; 235,185 of 251,225 resolvable `.lidx`
  names produce doc-gen4's declaration URL with **0 mismatches**. The comparator is
  `benchmarks/tools/docgen4-compare.py` and `…-falsify.py` is what made each arm fail once.
  **The three keep their place in step E's table** — an answer with a date on it is not a home.
- **C1** → `benchmarks/results/md-memory-gate-2026-09-02.txt`,
  `docs/verification-log.md` "C1". Six items, four of which exist so the other two mean
  something.

## Candidates for a next session, in the order I would take them

1. **The bash 3.2 hole is recorded and not fixed.** Any EXIT trap turns a `set -u` abort into
   exit 0, and `tools/lib/common.sh`'s `on_exit` cannot recover it (the trap sees `$?` already
   0). 13 scripts under `tools/` combine the two. Five are `ci` and covered by CI's bash 5;
   **`base-ir-gate.sh` and `deps-docs-gate.sh` are `manual`, which is where it is open.** The
   defence that works is a flag set on every path that is a real answer, with the cleanup
   refusing a 0 no path claimed — `tools/md-memory-gate.sh`'s `finished`. Doing it in
   `on_exit` itself would change the contract for all 13 at once, which is why it was not done
   blind.
2. **`-O` is the one half of the md-memory gate's compilation that nothing compares.** Lake
   builds that C with elan's clang and no `-O`; the gate uses the machine's `cc` at `-O1`. The
   compiler half is already a compared quantity (`LITEDOC4_SYSTEM_CC=1`,
   `tools/libc-shim-gate.sh`); the optimisation half is not.
3. **The A1 oracle is still alive and still cannot be rebuilt.**
   `/Users/haruka/dev/lean-projects/.lake/build/doc` — `lake update` or a `.lake` wipe there
   destroys it. If a question about doc-gen4's shape ever comes up again, ask it before
   touching the target.

## What a future session must not misread

- **`tools/md-memory-gate.sh` answers 0 of 6 and exits 2 on this machine.** A program built
  with `-fsanitize=address` never reaches its own `main` on this macOS (verified independently
  of the gate, with a three-line program). **That is not a pass and not a broken gate** — the
  question is answered by the CI job on ubuntu-latest.
- **The version gate's item 3 is about the tags, not about HEAD.** Sitting at the released
  version between releases is the normal state; every `tracks` site in
  `tools/version-sites.txt` is a **pin instruction a user follows**, so bumping the literal to
  clear a red gate would tell people to pin a tag that does not exist.
- **`docgen4-compare.py`'s docstring classification is not an exception list.** It asks the
  IR's own `moduleDocs` — today's sources — so a word litedoc4 shows that neither doc-gen4 nor
  the source has is invented, and a word doc-gen4 shows that the source still has and litedoc4
  does not is dropped. Both fail. **What it gives up is order.**
- **Neither comparator is a gate and neither can become one.** doc-gen4 is not in the target's
  manifest.

## Files to read first

1. `docs/verification-log.md` — "A1" and "C1" are the last two sections before 書き方
2. `tools/md-memory-gate.sh`'s header — six items and why four of them exist
3. `tools/version-gate.sh`'s item 3 — the comment says what the old question was and why it
   was the wrong one
