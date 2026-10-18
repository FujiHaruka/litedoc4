---
title: Quickstart
description: Add litedoc4 to a Lean package and build its documentation site.
---

You need `elan` and a package that `lake build` passes.

## Add the dependency

Add one line to your `lakefile.lean`, or the equivalent `[[require]]` entry to `lakefile.toml`:

```lean
require «litedoc4» from git "https://github.com/FujiHaruka/litedoc4" @ "v2.0.0"
```

## Build the site

```sh
lake run docs -- --out ../mypkg-docs
```

The site is written to `../mypkg-docs/site`. Its pages are drawn by a script, and a browser does not run that script for a page opened from disk. So serve the site over HTTP and open the address that the server prints:

```sh
python3 -m http.server -d ../mypkg-docs/site
```

The site shows one version, named by the first 12 hex digits of your commit. To put several versions in one site, see [Several versions](/litedoc4/guides/versions/).

## What happens on the first run

Nothing is downloaded. The `require` line is the whole installation: Lake builds both executables, `litedoc4` and the extractor, from the revision you pinned and with your own toolchain. This takes about a minute (measured on a GitHub runner, see [Performance](/litedoc4/performance/)), once. Later runs reuse them. The C code that the Markdown parser needs is compiled by the Lean toolchain's own `clang`, so you do not need a C compiler, Rust or node.

`lake run docs` fills in `--root`, `--lib` and `--extractor-bin` for you, also for a `lakefile.lean` package.

## Keep `--out`

- `--out` is required and must be outside the package. A relative path is read from the package directory, so `../mypkg-docs` is the shortest path that works.
- Keep `--out` between runs. The next run extracts again only the modules whose oleans changed.
- `--full` extracts every module again.

## Next steps

- [Publish on GitHub Pages](/litedoc4/getting-started/github-pages/) with the GitHub Action.
- [Watch while you work](/litedoc4/guides/watch/) to see your changes as you build.
- [Commands and flags](/litedoc4/reference/commands/) lists what `lake run docs` does not pass for you.
