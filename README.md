# litedoc4

**Fast HTML documentation for Lean 4 packages — built for the ones standing on Mathlib.**

litedoc4 documents **your** package only. Declarations from your dependencies — Mathlib,
Batteries, Lean core, whatever your `lake-manifest.json` pins — are never regenerated: every
reference to them links to that dependency's **version-pinned source on GitHub**. The output is a
self-contained static site.

Live example: <https://fujiharuka.github.io/information-theory/> — 422 modules, one command,
**24.5 s**. A sample, <https://fujiharuka.github.io/litedoc4/>, is eleven modules rebuilt from this
repository's `main` on every push: the shapes a page can take rather than the scale.

## What you get

- a front page listing every module of your package with a one-line description, and a module tree
- search over your own declarations
- instance lists, "Imported by", and "Used by" within your package
- hyperlinked signatures — every dependency name links to its version-pinned source on GitHub
- `$…$` and `$$…$$` typeset into the page at build time as MathML, with nothing loaded in the
  browser to draw it
- **uses `sorry`** and **depends on `sorry`** markers, kept apart as the different claims they are
- a dark theme
- page paths (`Foo/Bar.html`) and declaration anchors (`#Foo.bar`) in doc-gen4's shape, so links
  into docs you already publish keep working

## Is this for you?

**Yes**, if doc-gen4 is too slow for your CI. Any Lean 4 package works — the payoff just scales
with how large your dependencies are next to your own code, and Mathlib is as large as that gets.

**No**, if:

- **you want to search dependency declarations** — search covers your package only
- **your source is not on GitHub** — source links are GitHub URLs, and another host is refused
  rather than guessed unless you pass `--source-url`
- **you are on a Lean newer than v4.33.1** — v4.31.0, v4.32.2, v4.33.0 and v4.33.1 are the ones CI
  runs end to end, and of those **only v4.31.0 has been run over a Mathlib-sized package**. The
  extractor is compiled against your toolchain, so a version it cannot handle surfaces as a build
  failure, not as bad output
- **you are running it on Windows** — the generator has been run on Linux and macOS only

A `lakefile.lean` package is fine — the live example is one. The CLI will not guess library names
out of Lean code, so pass `--lib` by hand; used as a Lake dependency it is read for you.

## Quickstart

You need `elan`/`lake` and a package that `lake build` passes. Add one line to your
`lakefile.lean` (or the `[[require]]` equivalent in `lakefile.toml`):

```lean
require «litedoc4» from git "https://github.com/FujiHaruka/litedoc4" @ "v1.4.0"
```

```sh
lake run docs -- --out ../mypkg-docs
```

**The site is `../mypkg-docs/site`** — open its `index.html`. Lake builds both executables against
your own toolchain, and the script fills in `--root`, `--extractor-bin` and `--lib` for you,
including for a `lakefile.lean` package where `--lib` otherwise has to be written by hand.

`--out` is required and must be outside the package, and a relative path resolves against the
package directory, so `../mypkg-docs` is the shortest spelling that works. Running the same command
again is incremental, so keep it between runs; `--full` starts over.

Underneath, litedoc4 is two commands, which you reach directly for `watch` and for the flags
`docs` does not pass through:

```
litedoc4 build  --root <repo> --out <dir> --extractor-bin <path>
                [--lib <Name>]... [--jobs <n>] [--source-url <url>] [--full]
litedoc4 watch  --root <repo> --out <dir> --extractor-bin <path>
                [--lib <Name>]... [--jobs <n>] [--port <n>]
```

`litedoc4 --help-all` is every flag. The two you are most likely to need are `--lib <Name>`, when
your libraries cannot be read from `lakefile.toml`, and `--source-url <url>`, when `origin` is not
GitHub. For CI, the action below does all of this in one step.

### What that installs

Nothing is downloaded and there is no version to keep in step: the `require` above is the whole
installation, and the executables Lake builds come from exactly the revision you pinned. No Rust,
no node, and no C compiler of your own — the C that the Markdown parser needs is compiled by the
Lean toolchain's own clang against headers this package carries.

The first `lake run docs` pays for both executables — **18.1 s for `litedoc4` and 25.7 s for the
extractor** (medians of 3, measured 2026-08-31, Apple M1, cold build directory, warm page cache;
log `benchmarks/results/purelean-require-only-2026-08-31.txt`) — and every run after that is Lake
answering that there is nothing to do. It leaves the executable at
`.lake/packages/litedoc4/.lake/build/bin/litedoc4`, with the extractor beside it.

There is deliberately no `lean-toolchain` in this package: one that named a *higher* version would
make your `lake update` rewrite **your** `lean-toolchain`, and a *lower* one would be ignored
without a warning (both measured, `benchmarks/results/lake-package-probe-2026-08-18.txt`). Without
the file, Lake builds both executables with your toolchain and says nothing.

## Speed

Apple M1 / 16 GB, warm page cache, wall clock. One Mathlib-dependent package throughout, at two
of its revisions (432 and 422 modules); each row names the one it ran on:

| | doc-gen4 | litedoc4 |
|---|---:|---:|
| Extract every module, single-threaded (432 modules) | 1,076 s | **14.08 s** |
| Full site from nothing, `--jobs 4` (422) | — | **24.5 s** |
| Rebuild after one added declaration (422) | — | **4.35 s** |
| Rebuild with nothing changed (422) | — | **0.31 s** |

The first row is the only one both tools run: the same 432 modules, extracted the same way, **76×**.

**The dashes are the point.** doc-gen4 is not doing the other three jobs. It documents your entire
import closure — ~8,600 modules here against your 432 — and regenerates every page on every run.
That build has never been finished on this machine (aborted at 42%, memory-bound, after 13,611 s of
CPU time, which extrapolates to ~9 h of CPU for the closure), so there is no wall-clock number to
put next to 24.5 s.

Wall clock here moves with the page cache rather than with the work, so it is not something to gate
on: a second full build in the same session, with the oleans already resident, takes **8.8 s**
against a first run's 26.3 s doing byte for byte the same work, and the rebuild row is the median of
6 runs spread over 3.96–6.22 s (measured 2026-08-29, log
`benchmarks/results/v0.2.0-numbers-2026-08-29.txt`). The 24.5 s is the first-run figure, which is
what a CI job pays.

On a 4-core GitHub runner `litedoc4 build` took **11.5–20.7 s** for 422 modules. A first run also
builds the two executables (the extractor took ~16 s there; both are cached afterwards); the rest
of the job is your usual `lake exe cache get` + `lake build`. Peak resident memory ≈4.0 GB
(3.88–4.03 GB across 50 runs). Raw logs: [`benchmarks/`](benchmarks/).

## Documentation on GitHub Pages

Copy this into your package as `.github/workflows/docs.yml`, and enable Pages in your
repository settings (Settings → Pages → Source: GitHub Actions).

```yaml
name: docs
on: { push: { branches: [main] } }
jobs:
  docs:
    runs-on: ubuntu-latest
    permissions: { contents: read, pages: write, id-token: write }
    environment: { name: github-pages }
    steps:
      - uses: actions/checkout@v7
      - uses: FujiHaruka/litedoc4@v1.4.0
        id: docs
        with:
          cache-get: true             # `lake exe cache get` — drop it if you have no Mathlib
      - uses: actions/upload-pages-artifact@v5
        with: { path: "${{ steps.docs.outputs.site }}" }
      - uses: actions/deploy-pages@v5
```

That is the whole thing: the action installs elan if it is missing, runs `lake build` and the
docs **in one job** (split across jobs the oleans fall out of the page cache and it runs 5–12×
slower), and keeps four caches for you — Mathlib's oleans, the Lean extractor, the litedoc4
build, and last run's state, which is what makes the second run incremental.

Inputs you may need: `root` if your package is not at the repository root, `lib` if you use
`lakefile.lean`, `lake-build: false` if you already built the package **earlier in the same
job** (from another job the page cache is cold), `full: true` to ignore previous state.
Outputs: `site`, `out` and `timings`.

To archive instead of publish, swap the last two steps for `actions/upload-artifact` and drop
the `permissions` / `environment` lines.

## Running it from a checkout

```sh
git clone https://github.com/FujiHaruka/litedoc4 && cd litedoc4

# builds both executables against your package's toolchain, then documents it
tools/ci-build.sh --root /path/to/your-package --out /path/to/docs --jobs 4
```

`lake` cannot run beside this repository's own `lakefile.lean` — there is deliberately no
`lean-toolchain` there — so the script writes a one-line package under `.lake/host` that requires
this checkout, copies your package's `lean-toolchain` into it, and builds from there. It leaves
`litedoc4` in `.lake/build/bin/` and the extractor in `extractor/build/`, and running the script
again reuses both.

## Watching while you work

```sh
.lake/build/bin/litedoc4 watch --root /path/to/your-package --out /path/to/docs \
  --extractor-bin extractor/build/extract --jobs 4
```

`watch` serves the site on `http://127.0.0.1:8484/` (`--port`) and rebuilds it whenever your
package's `.olean` files change. **It does not run `lake build`** — run that in another window;
`watch` notices the oleans it writes. That keeps the division of labour every other command here
has: you build the package, litedoc4 reads it.

It asks the same question `build` asks — which modules the ledger says are stale — once a second
(`--interval`), and rebuilds only when the answer has stopped moving, so a `lake build` still
writing oleans is never read half-finished. Every rebuild prints how many modules were
re-extracted, how many pages were re-rendered and how long it took; a wait says what it is
waiting for.

The pages it serves are the bytes it wrote, with no live-reload script injected — what you look
at is what you will publish — so reload the tab yourself. A port that is already in use is
refused by name rather than moved to the next free one.

One edited module reaches its page in **5.5–6.2 s** (median 5.65 s over 15 cycles; the first
cycle of a session costs 13.7 s). **86–89 % of that is Lean loading its environment**, which a
rebuild has to redo because Lean cannot swap a module out of an imported one — so that figure is
a floor, not something tuning the loop moves. It does not include your own `lake build`, which
runs before any of it. Apple M1, 422 modules, warm page cache; raw logs in
[`benchmarks/`](benchmarks/).

## What the pages show

### The module list

The front page lists every module of your package with a one-line description, and the
description is the heading the module's docstring opens with:

```lean
/-!
# Strong typicality (Cover-Thomas)

Three main theorems for the strongly typical set …
-/
```

`Strong typicality (Cover-Thomas)` becomes that module's row on the front page; the prose under
it stays on the module's own page. Nothing else to write — Mathlib's own modules already open
this way 7,867 times out of 8,169 (measured 2026-08-29, log
`benchmarks/results/module-summary-source-2026-08-29.txt`).

A module whose docstring opens with prose instead is listed by name alone, and a heading that
merely repeats the module's own name — `# Basic` on `Pkg.Basic` — is written to the page as it
stands rather than dropped. The build counts both, which is what tells you where a better heading
is worth writing:

```
global  module descriptions 390 of 422 (0 repeat the module name)
```

(the live example's own front page; measured 2026-08-29, log
`benchmarks/results/module-summary-live-2026-08-29.txt`)

### Math in docstrings

`$…$` and `$$…$$` become MathML **while the site is built**. Nothing is loaded in the browser to
draw them — no MathJax, no KaTeX, no math web font — because every current browser lays MathML
out itself.

A formula the converter cannot read is written back as its own source, exactly as doc-gen4 leaves
every formula, and the build always says how many, zero included:

```
render  math spans kept as LaTeX 3
work    extract 422 / render 422 / math-fallback 3 / …
```

On Mathlib's own docstrings **2,113 of 2,123 formulas convert** (measured 2026-08-22, log
`benchmarks/results/mathml-2026-08-22.txt`); the ten that do not use commands the converter does
not implement — `\colim`, `\dotsc`, `\cr` — or are LaTeX no parser accepts.

### `sorry`

A declaration whose own statement or proof uses `sorry` is marked **uses `sorry`** on its page; one
whose own proof is complete but which depends on such a declaration is marked **depends on
`sorry`**. Those are different claims and the page keeps them apart. The answer comes from the
compiled environment — the declaration's axiom set — so it holds through any depth of dependency,
and a declaration marked neither has no hole under it.

A declaration Lean realized from `@[ext]` is marked **realized by `@[ext]` from …**, naming and
linking the declaration it came from: its own source link points at the attribute, which is where
Lean puts it.

## Configuring the site

`litedoc4.toml` next to your `lakefile`, both keys optional:

```toml
title = "MyPkg"          # the top bar, and the second half of every page's <title>
index = "docs/index.md"  # Markdown to put at the top of the site's index page
```

Without it the title is the name your modules share (`Foo.*` → `Foo`), which is what a reader
types to import your package. It is a file rather than a flag because every stage that writes HTML
reads it, so there is no way to leave the flag off one of them and end up with a site that
disagrees with itself about its own name.

A malformed file, an unknown key, or an `index` naming a file that is not there **stops the
build**. Carrying on with the derived title would be a site that quietly ignored what you asked
for.

## Status

`v1.4.0` — nothing is downloaded; Lake builds litedoc4 from the ref you pinned. Tested on macOS
(Apple Silicon) and `ubuntu-latest` with Lean/Mathlib v4.31.0, and the browser side also on
`windows-latest`.
Pin the action and the `require` to a tag — `v1.3.0` or later, since that is the first one a
machine with only elan on it can use. If your package is not at the top of its repository,
`v1.0.1` is the first release whose source links point at it. `@main` moves.

**Every Lean version litedoc4 claims is run end to end on every change to the extractor or the
sample**, and their output is compared: v4.31.0, v4.32.2, v4.33.0 and v4.33.1 produce byte-identical IR
once one rename is applied — Lean's own reclassification of a reducible instance
(`implicit_reducible` → `instance_reducible`, from v4.33.0). That rename is the only recorded
difference between them, in
[`tools/lean-toolchains.txt`](tools/lean-toolchains.txt) (measured 2026-08-29). A toolchain that
is not in that file fails by name.

### What 1.x keeps

The names your own files can contain do not move inside 1.x: the action's inputs and outputs,
`litedoc4.toml`'s keys, `build`'s and `watch`'s flags, and the site's page paths and declaration
anchors. The list is [`tools/public-surface.txt`](tools/public-surface.txt), and CI fails when one
of them goes missing.

The IR schema, the ledger and `.lidx` are internal, and you never pin them yourself: the action
and the Lake script build both executables out of the ref you pinned, so they always come from
the same tree.

Neither executable is distributed as a binary. A prebuilt one would be a second thing to keep in
step with the ref you pinned, and the build it would replace is under a minute and cached by CI
and by Lake alike.

## License

Apache-2.0 ([`LICENSE`](LICENSE)). litedoc4 is a derivative work of **doc-gen4**
(Apache-2.0, © 2021 Henrik Böving); attribution is in [`NOTICE`](NOTICE).
