---
title: Publish on GitHub Pages
description: A workflow that builds the documentation and publishes it to GitHub Pages on every push.
---

Save this file as `.github/workflows/docs.yml` in your package. Then set **Settings → Pages → Source** to **GitHub Actions**.

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
      - uses: FujiHaruka/litedoc4@v2.0.0
        id: docs
        with:
          cache-get: true             # `lake exe cache get` — drop it if you have no Mathlib
      - uses: actions/upload-pages-artifact@v5
        with: { path: "${{ steps.docs.outputs.site }}" }
      - uses: actions/deploy-pages@v5
```

The action installs elan if it is missing. It runs `lake build` and the documentation build in one job, and it caches what the next run needs:

- Mathlib's oleans
- the Lean extractor
- the `litedoc4` build
- the store and the extraction state of the last run, so that the next run extracts only the modules that changed

## Several versions

To publish several versions in one site, add `versions` under `with:` and give `actions/checkout` the full history, because by default it fetches no history and no tags:

```yaml
      - uses: actions/checkout@v7
        with: { fetch-depth: 0 }
      - uses: FujiHaruka/litedoc4@v2.0.0
        id: docs
        with:
          versions: v0.4.0,v0.5.0,main
```

See [Several versions](/litedoc4/guides/versions/) for how the versions are built and kept.

## Archive instead of publish

Replace the last two steps with `actions/upload-artifact`, and remove the `permissions` and `environment` lines.

## Other inputs

`root` if the package is not at the repository root, `lib` for a `lakefile.lean` package, and more: see [The GitHub Action](/litedoc4/reference/action/).
