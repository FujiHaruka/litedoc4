---
title: The GitHub Action
description: Inputs and outputs of the litedoc4 GitHub Action.
---

The action builds your package and its documentation in one job. It does not publish: hand its `site` output to `actions/upload-pages-artifact` or `actions/upload-artifact`. A complete workflow is on [Publish on GitHub Pages](/litedoc4/getting-started/github-pages/).

Keep the package build and the documentation build in one job. In another job the page cache is cold and extraction is much slower.

## Inputs

| Input | Default | What it does |
|---|---|---|
| `root` | `.` | The Lean package, relative to the workspace (or absolute) |
| `out` | a directory under `RUNNER_TEMP` | The documentation state. `<out>/site` is the site. Must be outside `root` |
| `cache-get` | `false` | Run `lake exe cache get` first. Use it for a package that depends on Mathlib |
| `lake-build` | `true` | Run `lake build` in the same job. Set it to `false` only if the package was built earlier in the same job |
| `jobs` | `4` | Threads for hashing the oleans and for the extractor |
| `lib` | | The library name, when it cannot be read from `lakefile.toml` (needed for `lakefile.lean`) |
| `source-url` | | Base URL for source links, when `origin` is not GitHub |
| `full` | `false` | Extract every module again |
| `versions` | | Tags, branches or commits of the repository, separated by commas, the newest last. Empty: the checked-out working tree is the one version |
| `store` | `<out>/store` | With `versions`, where the built versions are kept. Setting it without `versions` fails the step |
| `hash-urls` | `false` | Serve every page from the root `index.html`, with the route in the URL fragment |
| `install-elan` | `true` | Install elan if `lake` is not on `PATH` |
| `cache` | `true` | Use `actions/cache` for the extractor, the `litedoc4` build, Mathlib's oleans, and the store and extraction state |

## Outputs

| Output | What it is |
|---|---|
| `site` | The generated site |
| `out` | The state directory: site, store and extraction state. Keep it between runs |
| `timings` | The path to the phase timings JSON |
| `binary-source` | How the `litedoc4` executable was produced. Always `lake` |

Every input is also described in [`action.yml`](https://github.com/FujiHaruka/litedoc4/blob/main/action.yml).
