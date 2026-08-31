# Handoff — 2026-09-01 (relay leg 10 → 11)

## State

- Branch `main`, clean, pushed. **CI green on `f477b61`** (CI / lake package / sample site /
  Lean versions, all four). `2bb315d` and `f7de3af` were pushed after that check; `f7de3af`
  touches only `.claude/`, so `docs-gate` is the only thing that can fail on it and it passed
  locally. **Confirm both before starting anything else.**
- **The second tranche is 58 rows and the gate is green both ways.**
  `tools/refusal-gate.sh --lean .lake/build/bin/litedoc4 --rust target/release/litedoc4` →
  `lean 193/193, rust 170/193 (23 differ by design …); usage block 253 line(s) each;
  18 row(s) print before refusing and freeze stderr only`. `tools/refusals.txt` (tranche 1's
  135) is **byte-identical to HEAD** and must stay that way.
- `tools/lean-test-gate.sh` → **222 compile-time `#guard`, 31 run-time `Invariant`, 0 failed**
  (leg 10 added one Invariant, 30 → 31).
- `tools/purelean-micro-gate.sh` → ok, 16/16 items, 49/49 frozen files.
- **Disk 2.1 GiB free (99%).** Stable all leg. No `cargo build`, no `lake update` was run and
  none should be: `target/release/litedoc4` **is the Rust oracle** and rebuilding is not needed.
- **M10 remaining: the tranche's groups E / G / H / I + C12, then B2, then M10's steps E and F.**

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 11 / cap 40
- Predecessor: purelean-r10
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1–r7: M1–M9, tag `v1.3.0` (see `git log`)
  - r8: bucket I complete 316/316; both expiring oracle windows closed; 135 argv refusals frozen
  - r9: D done and CI-verified · Unicode oracles measured · the second tranche read, 59 rows
  - r10: **the second tranche's machinery and 58 of its rows** (`b0e20a8` `e6d83d8` `f477b61`
    `2bb315d`) · **five Lean defects found by freezing and fixed** · the stdout policy and two
    declined generalisations written down (`d720ca1` `f7de3af` `c1b75d4`)

## Next step

**1. Finish the tranche: groups E, G, H, I and C12.** The brief is written and complete —
`/private/tmp/claude-502/-Users-haruka-dev-lean-doc/87d7981e-8875-4d35-958b-658948949142/scratchpad/brief-stage5-eghi.md`
(readable across sessions; leg 9's oracle copy was found the same way). Dispatch it to an Opus
subagent with the tree state in the launch message, then verify and commit here.

These are the expensive rows — every one needs a `build` / `incremental` / `extract` world and
several need an executable stand-in for the extractor. **The stdout policy they were waiting on
is decided** (`.claude/purelean-tranche2.md`, last section). Watch the disk: these are the
largest fixtures in the tranche.

**2. Then B2** — brief at `…/scratchpad/brief-b2.md`, decided by measurement in
`benchmarks/results/unicode-table-regenerators-2026-08-31.txt`: repoint `gen-v8-gc-table.ts` at
a generated `src/Litedoc4/Global/V8GcTable.lean` with a **CI** gate; repoint `gen-gc-table.ts`'s
emitter only and mark it **manual** (UnicodeBasic is not installed and cannot be); and **freeze
`lowerTable`/`sigmaTable` saying so at the definition** — V8 disagrees on 28 code points, so no
live oracle survives M10 for those two.

**3. Then M10's step E**, then **F** — retire 14 `tools/provenance-files.txt` rows and their
`NOTICE` entries, place the two homeless target-IR tests, then delete `crates/`, tag
`rust-frozen`, and delete `.claude/purelean-plan.md` and `.claude/purelean-tranche2.md`.
`tools/gates.txt`'s `needs` column lies for `purelean-gate` / `purelean-micro-gate` /
`purelean-render-gate` the moment `crates/` goes — fix those rows in the same commit.

## Files to read first

1. `.claude/purelean-tranche2.md` **§6, §7, §8 and the last section** — the measured
   corrections. **§2 is the oldest part and has been falsified in a dozen places; where they
   disagree, the later sections win**
2. `tools/refusals-on-disk.txt` header — the format (`dir`/`file`/`>`/`exec`/`git`,
   `<varies>`, `rust-differs`, `stdout-not-frozen`)
3. `tools/refusal-gate.sh` header — what each of the two arms actually claims
4. `.claude/purelean-plan.md` §M10 (line 512 onward) — steps E and F, and the two degradations

## Load-bearing context

- **Freezing refusals is how five Lean defects were found this leg**, not a transcription
  exercise: a `--deps-docs-map` field order, an off-by-one from `splitOn "\n"` where a port of
  `str::lines` already existed one module too deep, **nine reads that lost the
  `litedoc4: <path>:` framing**, a parse door with no verb where the read door had one, and an
  **index entry accepted with a key missing** — which collapsed to `""` and read as a cache hit
  at `Global.factsFor` and as "not changed" at `Incr.Merge`. Expect more, and **ask each time
  whether Lean's answer is simply wrong before reaching for `rust-differs`**.
- **`rust-differs` is for two independent implementations, not for a defect.** 23 rows carry it;
  18 of them are the same shape — Lean's `IO.Error` renders `  file: <path>` on a second line
  where Rust is one line. **Collapsing that was considered and declined** (reasoning and
  falsifying condition in §7): the one-line row could only be frozen as
  `litedoc4: <path>: <varies>`, which passes even if everything after the colon is replaced.
- **The Rust arm is the one that catches a bad fixture, and it drops out exactly where it is
  needed.** Rust's serde requires ~20 keys per declaration in a module file that Lean defaults,
  so a hand-written module fixture is **accepted by Lean and rejected by Rust**. Check a new
  fixture against Rust first, not last. This trap expires with `crates/`.
- **Two shapes where the halves accept differently and no refusal row can hold it**: a tree
  missing only `declarations`, and unknown keys inside a `dependencyMaps` entry. Recorded in §6
  and §8 rather than papered over.
- **`--mint` drops the blank line before a `@case`**, so a hand-written row is only canonical
  after a mint round-trip — `git diff` moves under a mint that reports `0 changed`.
- Mint **only** from the Rust binary and **only while it exists**. Step F deletes it.
- Traps re-confirmed: `timeout` does not exist here; `/usr/bin/diff`, not `diff`; a pipe hides
  the exit code and this shell has no `PIPESTATUS`.
