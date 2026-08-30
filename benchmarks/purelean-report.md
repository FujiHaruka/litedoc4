# Replacing the Rust half with Lean — what it costs and what it buys

A measurement study, 2026-08-30. **Nothing here is a decision.** It is the
numbers a decision would need, with the conditions they were taken under.

Every number is labelled `(measured)` / `(extrapolated)` / `(assumed)` /
`(theoretical)`. The raw logs are in `benchmarks/results/` — `purelean-*.txt`,
plus `rust-render-threads-2026-08-30.txt`, `windows-probe-2026-08-30.txt`,
`purelean-md4c-2026-08-30.txt`, `purelean-md4c-shim-2026-08-30.txt` and
`purelean-bare-2026-08-30.txt`, which answered the three questions this study
first had to leave open — and each claim below names the one it came from.

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
| render 422 modules, 4 threads | **0.220 s** | **0.52 s** | 2.4x (extrapolated) |
| CPU for the same work | 0.38 s / 0.42 s | 1.06 s / 1.30 s | 2.8x / 3.1x (measured) |
| what four threads cost in CPU | **1.08x** | **3.3x** | (measured) |
| output | — | **422 of 422 pages byte-identical** | (measured) |
| CI, cache cold, release exists | 2.9 s | 9.25 s | +6.4 s (measured) |
| CI, cache cold, no release asset | 23.6–27.6 s | 9.25 s | −14 to −18 s (measured) |
| CI, cache warm | 0 s | 0 s | 0 |
| incremental core (impact+ownership+merge), sequential | **0.31 s** | **0.60 s** | 1.9x (measured) |
| the same, 4 threads | not threaded | **0.20 s** | 0.65x — Lean is faster (measured) |
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

**It does the same work, and the check is the output.** All 422 pages come out
byte-identical to Rust's — 420 of them as first measured, and the last two once
the math was wired up (→ `results/purelean-md4c-2026-08-30.txt`); those two
contain the target's only three LaTeX spans, 1,464 B, which was exactly the
total byte gap. Every
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

**Threading is the lever, and it has now been pulled on both sides.**
→ `results/rust-render-threads-2026-08-30.txt`

Lean reaches 0.52 s on four workers with byte-identical output. `render_site`
was threaded too — 92 lines of `std::thread::scope`, no new dependency, the
lockfile untouched, and nothing had to be cloned or wrapped to make it compile
— and reaches **0.220 s on four threads, 1.82x, at 1.08x the CPU**, with all
422 pages byte-identical to the sequential arm. Lean's four workers buy 1.26x
at **3.3x** the CPU. The patch is kept as `render-threads.patch`; it is not in
HEAD.

**The two absolutes come from different sessions** — their Rust-sequential
baselines are 0.39 s and 0.400 s, 2.5% apart, on builds whose output differs by
482 B — so the 2.4x above is (extrapolated) from two measured numbers, on the
premise that those baselines are the same workload. The two speedups, 1.82x and
1.26x, are each measured within one session and are the solid figures.

Rust's threading stops at 2.86x for the whole command no matter how many
threads, and the ceiling was measured rather than reasoned: rendering **one**
page still costs 0.140 s, because `ModuleSet` filters pages and not reads, so
all 422 module files and the whole 10.4 MB link index are read every time. That
serial floor is 35% of the run. Above four threads it is the M1's four E-cores:
instructions retired move 1.4% across every arm while IPC falls 3.86 → 3.18.

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

→ `results/purelean-incremental-2026-08-30.txt`

The renderer is half the Rust code. The other half is the incremental path, and
section 6.5 of the approach says "the outside" is 73% of an incremental build.
Its three commands that carry the IR full reads were written in Lean (1,079
lines, no dependencies at all) and measured interleaved against the Rust ones
(measured, n=6, run 1 discarded).

| | Rust | Lean seq | Lean 4 workers |
|---|---:|---:|---:|
| `impact` | 0.07 s | 0.18 s (2.6x) | **0.06 s** (0.86x) |
| `ownership` | 0.06 s | 0.18 s (3.0x) | **0.06 s** (1.00x) |
| `merge` | 0.18 s | 0.24 s (1.3x) | **0.08 s** (0.44x) |
| sum | 0.31 s | 0.60 s (1.9x) | **0.20 s** (0.65x) |

All three produce the **same answer**: `impact`'s 422-line set identical and its
JSON byte-identical, `ownership`'s 34-line set identical, `merge`'s output tree
identical over 426 files.

**At four workers the Lean incremental core beats the single-threaded Rust one
in wall clock**, and this is the part of the system where Lean does best — but
read the 0.65x the way the renderer's 1.33x had to be read before it was
corrected: **Rust's incremental path is a plain loop nobody has threaded**, and
the renderer's threading, once measured, cost 92 lines and no dependency and
bought 1.82x at 1.08x the CPU. Whether the same lever exists in these three
stages is not measured.

Where Lean does best:

- where a stage parses, it is the same 2.6–3.0x — and an ablation that parses
  only four fields, with identical output, buys 9.5%. The gap is the scan over
  15.2 MB, not the typed conversion;
- where a stage does not parse, Lean nearly closes: `merge`'s copy half is
  **1.10x**, through user space, against a kernel-side `fs::copy`;
- **memory goes the other way**: `impact` peaks at 10.4 MB against Rust's
  56.2 MB, because Rust materialises every module into a `Vec` and Lean's
  refcounting frees each one after four fields are read.

The implementation also **counted the IR full reads**, which decomposes section
5.6's measured 4.00 for a one-module edit exactly — and explains the 4.00-vs-3.00
discrepancy recorded there: `ownership` reads 423 modules when a declaration name
enters or leaves the global map and **2 when none does**. Those two modes differ
by 421x and nothing before the extraction can predict which one a build gets.
**The incremental path is bimodal, not a distribution** — an average incremental
build time is an average of two modes.

## What replacing Rust buys

- **`require` and nothing else.** `lakefile.lean`'s `resolveLitedoc4` — 250 of
  its 560 lines — exists to find a binary: `$LITEDOC4_BIN`, a version-pinned
  cache, a GitHub release with a checksum, `PATH`, then `cargo build`. All of it
  goes.
- **Windows and Intel macOS stop being a fallback path.** Today they take the
  `cargo build` branch and need a Rust toolchain, a C compiler and node; pure
  Lean needs **elan and nothing else**. That is not free — md4c is C, and
  Lean's bundled clang ships no libc headers, so it takes eleven hand-written
  declarations (`benchmarks/lean-prototype/csrc/libc`) to compile md4c with the
  toolchain's own compiler. With them, all 422 pages come out byte-identical on
  both the shim build and a system-`cc` control arm (measured 2026-08-30 →
  `results/purelean-md4c-shim-2026-08-30.txt`), and the build completes on
  **Linux, macOS and Windows with every system compiler stubbed to fail on
  contact** — the same eleven declarations on all three, no Windows-specific
  case (measured → `results/purelean-bare-2026-08-30.txt`). Byte identity is
  still measured on arm64 macOS alone: the runners have no target IR to render.

  **This was the larger of the two motives, and it is now smaller than it was.**
  → `results/windows-probe-2026-08-30.txt`. A Windows binary was never
  impossible, only never built: `litedoc4.exe` comes out at 3,051,008 B in
  1 m 48 s on `windows-latest` (measured), and the vendored md4c compiles under
  `cl.exe` with all 47 of `litedoc4-md`'s tests passing. Two defects stood in
  the way — `sha2`'s `asm` feature, which cannot build under MSVC, and
  `build.rs` starting `npm` rather than `npm.cmd` — and both are fixed, so the
  `cargo build` fallback README calls "a normal path, not a failure" is now one.
  What is not done is the asset itself: the archive step and `lakefile.lean`'s
  `fetchRelease` both spell the binary without `.exe`, the smoke job would need
  elan and lake on Windows, three of the four places that decide whether a
  machine has an asset do not name the triple, and `cargo test --workspace` is
  not green on Windows (at least 7 `std::os::unix` sites, all in test code —
  a lower bound, since the build stops at the first error).
- **`release.yml`, 332 lines**, and the three-triple release matrix it feeds,
  along with `tools/lake-download-gate.sh` and the four places that have to
  agree about which platforms have assets.
- **The Rust toolchain in CI**: 11 of 15 workflows mention cargo or rustup.
- Node stays needed for the site's TypeScript (1,550 lines) unless the built
  asset is committed — see below.

## What it costs

- **2.74x wall and 2.8x CPU sequentially** for the same output; 1.33x wall and
  3.4x CPU with four threads. On this target that is 0.68 s per full build.
- **One git dependency** (MathML4Lean), down from the two this study started
  with. MD4Lean was dropped for md4c vendored directly, which is the same C the
  Rust half already vendors, and the swap changes no byte on any of the 422
  pages (measured → `results/purelean-md4c-2026-08-30.txt`). What it costs is
  810 lines of glue to maintain; what it avoids is a dependency with no
  releases, carrying `lean-toolchain: v4.29.0-rc1` — which Lake **rewrites the
  consumer's from above** — plus `experimental.module` and `precompileModules`.
- **LaTeX → MathML now has a Lean equivalent, and it is not math-core.**
  MathML4Lean v0.1.0 converts 2,000 of Mathlib's 2,113 spans byte-identically
  to `math-core`, differs on 107 only where a named rule says so, and refuses
  6. On this target's 3 spans it agrees exactly. **A target that reaches the
  107 will not match the Rust half page for page, by design**: the
  specification decides where it speaks and the oracle only where it is silent
  (decided 2026-08-30, user's call). Adopting it is a decision about output,
  not a gap to be closed.
- **`build.rs` currently bakes the site's JS into the binary.** Without it the
  built asset has to be committed, reversing the current "the artefact is not in
  the repository" rule.
- **31,553 lines of Rust and 24,788 lines of its tests** would be rewritten. The
  prototype suggests Lean is more compact for this work — 1,866 lines produce
  what 10,869 lines of `render` + `md` produce — but the prototype has no error
  handling, no configuration, no external-link or dependency-docs handling, so
  that ratio is not a forecast.

## Not measured

- the search index, `watch` and its HTTP server (Lean 4.31 has `Std.Async.TCP`,
  so it is writable — that is a capability check, not a measurement);
- a real pure-Lean litedoc4 end to end on CI. The CI numbers above are measured
  parts composed by hand, not one A/B run, because no pure-Lean litedoc4 exists.
