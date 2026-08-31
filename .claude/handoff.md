# Handoff — 2026-08-31 (relay leg 7 → leg 8)

## State

- Branch: `main` @ `fa1183c`, clean, pushed. **CI green on `004db90`** (all five workflows);
  `fa1183c` is a one-line comment on top of it and its CI was still in flight — check
  `gh run list` first.
- **Tag `v1.3.0` is pushed** (annotated; the tag object is `80e21f3`, the commit `fa1183c`).
  README, `lakefile.lean` and `action.yml`'s example all name it.
- **M9 is done on the repository side, and measured.** M10 is next and its shape changed —
  read "The M10 finding" below before planning it.
- Measurement env: target `/Users/haruka/dev/lean-projects` @ `16ff7a40`, read only, untouched.
  It is `FujiHaruka/information-theory` — the repository behind the second live site.
- **Disk 3.2 GiB free.** No clone was made this leg. Scratch kept:
  `/private/tmp/lean-doc-relay/{purelean,m5-impact,m5-ledger,m5-incr}` and `m9-tag`
  (delete `m9-tag*` — it is a throwaway consumer, ~300 MB).

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 8 / cap 40
- Predecessor: purelean-r7
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1–r4: M1–M4 (see `git log`)
  - r5: M5–M7 complete, M8 all but `build-gate.sh`. `1e5f0b5`..`9b34b48`
  - r6: M5's evidence retaken (3,201/3,201); M8 complete. `c7790ef` / `daa0d78`
  - r7: **M9 complete on the repository side** — `08efc70` (the docs script builds with Lake),
    `11735e9` (the release path and its two gates go), `9a47cca` (the action + v1.3.0),
    `02570c9` (the published sample is built by the Lean half), `004db90` (assets-gate's
    count-of-2 rot), `fa1183c`. **Tag `v1.3.0` pushed.** Evidence:
    `benchmarks/results/purelean-require-only-2026-08-31.txt`.

## Next step

**M10, but not the M10 the plan describes.** Do these in order:

1. **Measure the coverage gap before deleting anything** (→ "The M10 finding"). Write it to
   `benchmarks/results/`, then put the question to the user with numbers.
2. **The decision-independent M10 preparation** can start now, whatever the answer is:
   - **`crates/litedoc4-render/web` has to leave `crates/`** (→ `web/`). It is the site's
     TypeScript and its vitest suite, and it survives the Rust half. Six references:
     `tools/assets-gate.sh:19`, `build.rs:71,82`, `assets.rs:335`,
     `crates/litedoc4-global/tests/web_fixture.rs:2,19`, `docs/provenance.md:130`.
   - **"vite's output is what `assets/` holds" is checked by a Rust unit test today**
     (`the_committed_bundles_match_what_build_rs_bundled`, in
     `crates/litedoc4-render/src/assets.rs`). `tools/assets-embed-gate.sh`'s header already
     says the check leaves with the Rust tree — **so move it into `tools/assets-gate.sh`
     first, or the chain vite → `assets/` → `Assets.lean` loses its first link silently.**
3. **Two things are waiting on the user** (both stated at the end of leg 7; neither blocks 1–2):
   - **The `information-theory` pin** (`docs.yml:49`, `FujiHaruka/litedoc4@v1.2.0`). It is
     another repository *and* it is the measurement target, which CLAUDE.md says not to commit
     to. Bumping it to `v1.3.0` is what makes the second live site run the new path.
   - **Whether GitHub Releases continue in any form.** `release.yml` is gone, so `v1.3.0` is a
     tag and nothing else; the Releases page still shows `v1.2.0` as the latest. Tags are
     enough to pin — this is discoverability, not function.

## The M10 finding — deleting `crates/` deletes the test suite

**`cargo test --workspace` is CLAUDE.md's definition of green, and the Lean half has no tests
at all.**

| | |
|---|---|
| Rust | **582 passing, 22 ignored** (measured 2026-08-31, `cargo test --workspace`) |
| — of which refusal-shaped | **146 of 556** `#[test]` names match `error/refus/reject/fail/broken/missing/invalid/…` — **an approximation by name, not by what they assert.** Confirm before quoting it |
| Lean | **53 modules under `src/`, 0 tests** |

What survives M10 is the gate suite, and it is not nothing: **`tools/e2e-micro.sh` passes
driving the Lean binary, 17/17** (measured this leg, macOS), and `pages.yml` now publishes
through exactly that path on Linux. But the gates are end-to-end. The names above
(`reading_a_broken_tree.rs`, `an_unplaceable_name_is_an_error_and_not_a_guess`,
`a_file_that_is_wrong_is_an_error_and_not_a_default`) are **entrance refusals no end-to-end
gate reaches** — the class this repository has been bitten by twice ("a passing unit test does
not mean that branch is correct" cuts both ways).

**Do not read the plan's M10 judgement — "0 workflows naming cargo" — as sufficient.** It is
satisfiable while 582 tests leave and nothing says so. That is the "green while checking
nothing" shape, at the scale of the whole suite.

## Files to read first

1. `.claude/purelean-plan.md` §M9 (what was done, and the three leftovers) / §M10
2. `benchmarks/results/purelean-require-only-2026-08-31.txt` — M9's evidence and its limits
3. `tools/build-lean-exe.sh` — new, and the one place that knows how to build the Lean half
4. `tools/assets-embed-gate.sh` header — the three-link chain M10 has to keep whole

## Load-bearing context

- **`tools/build-lean-exe.sh` is the single answer to "how is `lean_exe litedoc4` built".**
  Lake cannot run beside the root `lakefile.lean`, so it writes a one-`require` workspace under
  `<repo>/.lake/host` with the **caller's** `lean-toolchain` copied in. `tools/ci-build.sh`
  step 4/5 and `ci-lean-versions.yml` both call it. **Do not grow a second copy** — that is why
  the inline version written first was pulled out.
- **`src/` now has to compile on every toolchain in `tools/lean-toolchains.txt`**, because the
  consumer's Lean compiles it. `ci-lean-versions.yml` runs `build-lean-exe.sh` per toolchain and
  **all four were green on the first run** (v4.31.0 / v4.32.2 / v4.33.0 / v4.33.1, run
  33359548045). This requirement did not exist before M9.
- **`binary-source` was kept, as the constant `lake`.** Not sentiment: **a GitHub Actions output
  that no longer exists comes back as the empty string with no error**, so deleting a promised
  name turns a caller's `test "$SRC" = release` into a silent pass. `ci-action.yml`'s
  `standalone` job asserts the value arrives, which is what catches an output whose `value:`
  names a dead step.
- **`LITEDOC4_BIN` / `LITEDOC4_NO_DOWNLOAD` / `XDG_CACHE_HOME` no longer exist.** Two places
  were still setting `LITEDOC4_BIN` after the lakefile stopped reading it
  (`tools/lake-package-gate.sh`, `ci-lake.yml`) and were **green while grading a different
  binary than the one they named**. Both fixed. If you delete an input, grep for who sets it.
- **`tools/assets-gate.sh` had a count** — "the composite action and action.yml should both read
  mise.toml; N do" — and it went red the moment `action.yml` correctly stopped installing node.
  Now derived: *whatever installs node reads the version from `mise.toml`*. Made to fail once
  before it was allowed to pass.
- **`docs/provenance.md`'s dependency-closure half is retired, not relaxed.** Its subject was
  Object-form distribution; nothing is distributed as an object any more. `NOTICE` and
  `tools/provenance-files.txt` stay — those are the source-form obligations.
- **The `cargo doc` CI command is not the obvious one.** `RUSTDOCFLAGS='-D warnings -A
  rustdoc::private_intra_doc_links' cargo doc --workspace --no-deps --document-private-items`.
  Without both flags it fails on three pre-existing private links and tells you nothing.
- **`pgrep -f '<pattern>'` matches the polling shell itself.** Write `'foo[.]sh'`.
- **`/usr/bin/env bash` here is bash 3.2**; `${arr[@]+"${arr[@]}"}` is the empty-array form.
- **`timeout` does not exist on this machine** (it is `gtimeout`, if at all). A command line
  starting `timeout …` fails with `command not found` **and the rest of the pipeline still
  runs**, so a stale `FETCH_HEAD` looked like a fresh fetch this leg.
