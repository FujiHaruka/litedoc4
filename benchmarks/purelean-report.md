# Replacing the Rust half with Lean — what it costs and what it buys

A measurement study, 2026-08-30. **Nothing here is a decision.** It is the
numbers a decision would need, with the conditions they were taken under.

Every number is labelled `(measured)` / `(extrapolated)` / `(assumed)` /
`(theoretical)`. The raw logs are in `benchmarks/results/purelean-*.txt` and
each claim below names the one it came from.

## The question

litedoc4 is a Lean extractor plus a Rust half that consumes the IR: rendering,
the incremental path, the search index, the CLI. The Rust half is 31,553 lines
of product code and 24,788 of tests.

Two things were asked of it:

1. **What does it cost in speed to replace that half with Lean?**
2. **What does it do to CI time on the real target?**

The reason to ask is not speed. It is that a consumer today needs a binary as
well as a `require` line — and on Windows and Intel macOS, where no release
asset exists, that means Rust, a C compiler and node.

## The answer

| | Rust today | pure Lean | |
|---|---:|---:|---|
| render 422 modules, sequential | **0.39 s** | **1.07 s** | 2.74x (measured) |
| render 422 modules, 4 threads | not threaded | **0.52 s** | 1.33x of Rust's 1 thread (measured) |
| CPU for the same work | 0.38 s | 1.06 s / 1.30 s | 2.8x / 3.4x (measured) |
| output | — | **420 of 422 pages byte-identical** | (measured) |
| CI, cache cold, release exists | 2.9 s | 9.25 s | +6.4 s (measured) |
| CI, cache cold, no release asset | 23.6–27.6 s | 9.25 s | −14 to −18 s (measured) |
| CI, cache warm | 0 s | 0 s | 0 |
| binary a consumer would fetch | 3.4 MB | 5.3 MB | (measured) |

The whole `docs.yml` job on the real target is 146–182 s (measured), so the CI
column is **±4% either way**. CI time is not what decides this.

## Speed, in detail

→ `results/purelean-renderer-2026-08-30.txt`,
`results/purelean-markdown-2026-08-30.txt`

A Lean renderer was written (1,866 lines, `benchmarks/lean-prototype/Render.lean`)
and measured against `litedoc4 render` on the same IR — 422 modules, 15,233,730 B
of IR, a 10,448,225 B link index, 24.5 MB of HTML out. Both were run interleaved
in one session, n=7, run 1 discarded (measured).

**It does the same work, and the check is the output.** 420 of 422 pages come
out byte-identical to Rust's. The two that differ contain the target's only
three LaTeX spans, 1,464 B, which is exactly the total byte gap. Every
structural count matches exactly: 41,786 anchors, 388,868 code spans, 5,790
paragraphs, 4,394 declaration anchors of 4,584 (the same 190 suppressed), the
heading hover-links, the lists, the block quotes.

**The gap is not in any one component.** Rendering costs 0.63 s of the 1.07 s,
and splits 47% frame/escaping/assembly, 21% code-fragment walk, 20% docstrings,
12% link resolution. Three separate attempts to find a dominant cost failed:

- the link index was suspected and is 12% of rendering;
- Markdown was suspected and, put in for real through MD4Lean (the same md4c the
  Rust half vendors), costs **+0.036 s marginal, 3.4%**;
- the JSON parse was rewritten by hand for 1.57x and the link-index parse for
  2.66x, and the floor still sits at 0.506 s sequential.

What is left is **~10 cycles per byte where Rust pays ~1**, spread over parsing
15.2 MB, escaping and assembling 24 MB, and walking 385,880 spans through a
UTF-16 offset map. A structural walk that builds nothing already costs 0.046 s.
No restructuring moves this, and the measurements that tried are recorded with
their numbers so nobody retries them.

**Threading is the lever, and it is unpulled on both sides.** Lean reaches
0.52 s on four workers with byte-identical output. Rust's `render_site` is a
plain `for` loop and the workspace has no rayon, so **a threaded Rust has never
been measured** — the 1.33x is Lean-with-cores against Rust-without.

## CI, in detail

→ `results/purelean-ci-runs-2026-08-30.txt`,
`results/purelean-ci-probe-2026-08-30.txt`

Measured on the real target (FujiHaruka/information-theory, `docs.yml`,
ubuntu-latest) and on a probe branch in this repository.

The Rust half's CI cost is **one download**: 2.9 s for a musl binary plus a
SHA-256 check. It is 0 s when the cache is warm. Where no release asset exists —
Windows, Intel macOS — it is `cargo build`, 23.6–27.6 s (measured), and needs
Rust, a C compiler and node.

A pure-Lean renderer replaces that with compilation **inside the extractor build
that already runs**: 9.25 s for 1,612 lines on the same runner (measured, n=3;
the extractor's 3,174 lines take 11.65–16.82 s, a 44% spread across four runs on
identical input). Adding MD4Lean takes a fresh-checkout build to 8.95 s of which
1.50 s is `lake update`'s clone and ~0.5 s is md4c's C (measured).

**A finding that changes the distribution question:** a Lean binary is not
necessarily huge. `render`, which imports only `Std.Data.HashMap`, is **5.3 MB**.
`bench`, which imports `Lean.Data.Json`, is 118 MB. The extractor, which
`import Lean` because it reads oleans, is 226 MB. The half that would be shipped
is the small half, and it is the same order as the Rust binary's 3.4 MB.

## The incremental path

→ measured separately; see `results/purelean-incremental-2026-08-30.txt`

*(pending)*

## What replacing Rust buys

- **`require` and nothing else.** `lakefile.lean`'s `resolveLitedoc4` — 250 of
  its 560 lines — exists to find a binary: `$LITEDOC4_BIN`, a version-pinned
  cache, a GitHub release with a checksum, `PATH`, then `cargo build`. All of it
  goes.
- **Windows and Intel macOS stop being a fallback path.** Today they take the
  `cargo build` branch and need a Rust toolchain, a C compiler and node.
- **`release.yml`, 332 lines**, and the three-triple release matrix it feeds,
  along with `tools/lake-download-gate.sh` and the four places that have to
  agree about which platforms have assets.
- **The Rust toolchain in CI**: 11 of 15 workflows mention cargo or rustup.
- Node stays needed for the site's TypeScript (1,550 lines) unless the built
  asset is committed — see below.

## What it costs

- **2.74x wall and 2.8x CPU sequentially** for the same output; 1.33x wall and
  3.4x CPU with four threads. On this target that is 0.68 s per full build.
- **A second git dependency** (MD4Lean) and, for heading ids, a third
  (`UnicodeBasic`, which doc-gen4 also requires). Neither is in the build
  numbers above beyond MD4Lean's 4.4 s.
- **LaTeX → MathML has no Lean equivalent.** `math-core` is 18 crates. On this
  target it is 3 spans; on a Mathlib-shaped target 2,123 (measured 2026-08-22).
  The options are a client-side renderer or writing one.
- **`build.rs` currently bakes the site's JS into the binary.** Without it the
  built asset has to be committed, reversing the current "the artefact is not in
  the repository" rule.
- **31,553 lines of Rust and 24,788 lines of its tests** would be rewritten. The
  prototype suggests Lean is more compact for this work — 1,866 lines produce
  what 10,869 lines of `render` + `md` produce — but the prototype has no error
  handling, no configuration, no external-link or dependency-docs handling, so
  that ratio is not a forecast.

## Not measured

- a threaded Rust renderer;
- `math-core`'s replacement, at all;
- the search index, `watch` and its HTTP server (Lean 4.31 has `Std.Async.TCP`,
  so it is writable — that is a capability check, not a measurement);
- a real pure-Lean litedoc4 end to end on CI. The CI numbers above are measured
  parts composed by hand, not one A/B run, because no pure-Lean litedoc4 exists.
