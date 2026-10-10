# Handoff — 2026-10-11 (multi-version: the reuse chain is wired)

## State

- Working directory: /Users/haruka/dev/lean-doc
- Branch: multi-version (pushed; no PR). Clean after the handoff commit.
- Working context: making the older versions of `build --versions` about 2x faster via E6 inexact print reuse. The three steps the user ordered on 2026-10-10 are done.

## Where we are

- The runner's 62 divergences were all reproduced and classified (`benchmarks/results/mv-l-reuse-inspect-v4.33.1-2026-10-10.txt`). 60 are accepted kinds, accepted again by the user on 2026-10-10. The 2 key misses were fixed: the key now hashes every shown member's type.
- The chain starts from the native newest. The key moved into Extract.lean, the printing identity no longer carries the reader fields, and the native extractor takes `--write-reuse-keys` (`benchmarks/results/mv-reuse-native-start-2026-10-10.txt`).
- `build --versions` reads through the chain by default: newest first, `--lazy-proofs`, each version reusing from the one above. `--reader-alone` is the exact read and `--reader-session` is the old session. `tools/mv-reader-gate.sh` 18 of 18.

## Next step (none approved yet; ask the user)

1. A full-Mathlib number for the chain end to end. `benchmarks/tools/mv-l-run.sh` has no arm for the default `build --versions` (its `session` arm now passes `--reader-session`). Adding an arm and pushing the script starts a runner run, so ask first. Commit 3143ce9 used `[skip ci]` to push the script fix without starting a run.
2. Open: the store record does not say whether an entry was filled with reuse.
3. Parallel decode: dropped by the user; raise it only now that integration is done, if at all.

## Files to read first

- `docs/multiversion/implementation.md` — "Levers plan", item 5 (its last three paragraphs)
- `tools/mv-reader-gate.sh` — sections 7–8 (the chain items)

## Load-bearing context

- User rules (also in memory): measure as lightly as possible — one run per arm, ±10% fine; full-Mathlib runs only after asking, once; Japanese brief-me, no code names.
- Subagent prompts: every command foreground, ≤ 9 min each; at most 1 subagent; tell it not to commit. `tools/mv-reader-gate.sh` takes ~12.5 min on the M1, so run it yourself in the background.
- Pushing `.github/workflows/mv-l.yml` or `benchmarks/tools/mv-l-run.sh` starts a full-Mathlib runner run. Ask first, or put `[skip ci]` in the commit message when no run is wanted.
- Do not touch /private/tmp/lean-doc-relay/mv-v4341 or mv-v4320. After editing extractor/ or src/, rebuild with `tools/build-lean-exe.sh --toolchain-from e2e/micro`; the reader digest changes only after that rebuild.
