# Handoff — 2026-10-10 (multi-version: reader reuse, E6)

## State

- Working directory: /Users/haruka/dev/lean-doc
- Branch: multi-version (pushed; no PR). Clean after the handoff commit.
- Working context: making read-alone (`reader extract`, old Mathlib read into Lean v4.34.1) about 2x faster via E6 inexact print reuse; the user picked the order below.

## Where we are

E2 (lazy proofs), E5 (fixed costs), E6 (reuse from the adjacent version's IR, cheap key without macro scopes) and the reuse-overhead cut are committed; all are in docs/multiversion/implementation.md "Levers plan: beating read-alone on M (2026-10-10)" items 2/4/5 with Measured notes. M: ~2x at --jobs 1, ~1.5x at --jobs 4. Runner (full Mathlib, v4.33.1 only, 2 runs): 1.46/1.49x, +2 GiB reader memory (later cut estimated to +0.8-1.1 GiB), 62 of 317,784 declarations differ, link index equal. Further runner runs were cancelled by the user.

## Next step (user-approved order)

1. **Inspect the 62 full-scale divergences** (47 are type/typeCode, i.e. the signature itself). List: `benchmarks/results/mv-l-reuse-differing-v4.33.1-2026-10-10.txt` (15 module files; from runner run 38043515525 artifact `mv-l`). Locally: make a Mathlib v4.33.1 workspace under /private/tmp/lean-doc-relay (like mv-v4320 was made; `lake exe cache get`, ~5-6 GB, 15 GiB free), read only those modules with `reader extract --lazy-proofs`: newest from /private/tmp/lean-doc-relay/mv-v4341 with `--write-reuse-keys`, then v4.33.1 (a) alone and (r) `--reuse-from`, and show how each differing declaration renders in both. Verdict wanted: all of the accepted kinds (notation, helper definitions behind equations, other declarations' binders), or a key miss showing a different statement (then the key or the approach needs rethinking). Brief the user in Japanese.
2. **Newest as the chain's start**: reuse from the native extractor's v4.34.1 output is refused because the "printing identity" differs from the reader's (measurement used a second reader read of v4.34.1 as a crutch). Find why; if it cannot match, first older version is built without reuse.
3. Then wire the chain into `build --versions`.

## Files to read first

- `docs/multiversion/implementation.md` — Levers plan section (items 2, 4, 5)
- `benchmarks/results/mv-l-reuse-2026-10-10.txt` — runner numbers and the 62
- `benchmarks/results/mv-m-reuse-key-e5-2026-10-10.txt` — key analysis, accepted divergence kinds
- `benchmarks/tools/mv-l-run.sh` — `reuse` subcommand shows the exact reader flags

## Load-bearing context

- User rules from this session (also in memory): measure as lightly as possible — one run per arm, ±10% fine, validate obvious win + side effects (quality, memory); full-Mathlib runs only after asking, once; Japanese brief-me, no code names.
- Subagent prompts: every command foreground, ≤ 9 min each; never end the turn to wait on a background job (that is what produced interim notices). Do not reply to interim notices. At most 1 subagent; tell it not to commit.
- Pushing `.github/workflows/mv-l.yml` or `benchmarks/tools/mv-l-run.sh` starts a full-Mathlib runner run (push trigger on this branch) — ask first.
- Parallel decode was dropped by the user (no memory gain); it is the only lever left for 2x at --jobs 4 — raise it only after integration.
- Do not touch /private/tmp/lean-doc-relay/mv-v4341 or mv-v4320. Rebuild with `tools/build-lean-exe.sh --toolchain-from e2e/micro` after reader edits.
