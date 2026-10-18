---
title: Compatibility and requirements
description: What 2.x keeps stable, which Lean versions are supported, and where litedoc4 runs.
---

## Requirements

- **Source on GitHub.** Source links are GitHub URLs. For another host, pass `--source-url`. litedoc4 does not guess one.
- **Lean v4.31.0, v4.32.2, v4.33.0, v4.33.1, v4.34.1 or v4.35.0.** Any other version is refused by name before anything runs. The list is [`tools/lean-toolchains.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/tools/lean-toolchains.txt). CI runs every listed version end to end on every change to the extractor or the sample, and compares their output.
- **Linux and macOS.** The generator is tested on macOS (Apple Silicon) and on GitHub's `ubuntu-latest`. The site's browser side is also tested on `windows-latest`. Running the generator on Windows has not been tried.

A `lakefile.lean` package works. The command line does not read library names out of Lean code, so pass `--lib` yourself. `lake run docs` does this for you. In the action, set the `lib` input.

## What 2.x keeps

Within 2.x, nothing that your own files can name is removed or renamed:

- the action's inputs and outputs
- the keys of `litedoc4.toml`
- the flags of `build` and `watch`
- the site's page paths and declaration anchors

The list is [`tools/public-surface.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/tools/public-surface.txt), and CI fails if a name in it goes missing.

The IR schema, the ledger and `.lidx` files are internal. You never pin them yourself: the action and `lake run docs` build both executables from the revision you pinned, so they always come from the same tree.

## Pin a tag

Pin the action and the `require` to a tag. `@main` moves.

## No binaries

Neither executable is distributed as a binary. Lake builds both from the revision you pinned, so there is no second thing to keep in step with that revision. The build takes about a minute (measured, see [Performance](/litedoc4/performance/)) and is cached by CI and by Lake.

There is no `lean-toolchain` in this package on purpose. With one, a higher version would make your `lake update` rewrite your own `lean-toolchain`, and a lower version would be ignored without a warning. Without it, Lake builds both executables with your toolchain.
