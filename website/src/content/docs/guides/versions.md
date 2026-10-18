---
title: Several versions
description: Build one site that holds several tags, branches or commits of your package.
---

```sh
litedoc4 build --root <repo> --out <dir> --versions v0.4.0,v0.5.0,main [--lib <Name>]...
```

`--versions` takes tags, branches or commits of the git repository at `--root`, separated by commas. Put the newest last. litedoc4 builds one site that holds all of them.

## How the site is laid out

- Each version's pages are under the version's name, for example `v0.5.0/Foo/Bar.html`.
- Every page has a version switcher. It opens the same page in the other version. If the module is not in that version, it opens that version's front page and says so.
- A link in doc-gen4's shape without a version, `Foo/Bar.html#Foo.bar`, goes to that page in the newest version. This needs a host that answers a missing path with the site's `404.html`, as GitHub Pages does.

## How each version is built

Each version is checked out under `--out`. elan installs its toolchain, `lake build` builds its libraries, and an extractor built for its own Lean extracts its modules. So `lake` must come from elan (`--lake` names it). A version whose toolchain is not in [`tools/lean-toolchains.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/tools/lean-toolchains.txt) is refused before anything runs.

When the store holds none of the older versions and the newest version uses the newest Lean that litedoc4 supports, the older versions are read with the newest version's Lean instead of their own. A declaration read this way can print differently from how its own Lean prints it, where the printing depends on notation or binders declared elsewhere.

## Keep the store

`<out>/store` keeps every version that was built. `--store` moves it. **Keep it between runs:**

- a version that the store already holds at the same commit is not extracted again
- a version that the site already holds is not rendered again

So adding a release to the list costs only that release.

## In the GitHub Action

Use the `versions` input, and `store` if the store should live somewhere other than `<out>/store`. The action caches the store with the rest of its state. Give `actions/checkout` `fetch-depth: 0`, because by default it fetches no history and no tags. The workflow is on [Publish on GitHub Pages](/litedoc4/getting-started/github-pages/#several-versions).

## Hosting under a subpath

GitHub Pages answers every missing path in a Pages site with the `404.html` at that site's root. When a litedoc4 site is one directory of a larger Pages site, its own `404.html` is not the one that answers. Versionless links then work only if the host's root `404.html` hands each miss under the litedoc4 directory to litedoc4's redirect.

This documentation does this for its [sample](https://fujiharuka.github.io/litedoc4/sample/): for a missing path under `/litedoc4/sample/`, its 404 page loads the sample's own `404.html`, which sends the reader to the newest version.

## One page for every path

With `--hash-urls` (the action's `hash-urls` input), the site has no file per page. The root `index.html` draws every page from the URL fragment, `#/<version>/<module path>`. Use it for a host that cannot answer every path with one page.

## Example

[mathlib.fuji.land](https://mathlib.fuji.land) is Mathlib built this way: every release on Mathlib's Releases page that is not a prerelease, in one site. What it takes to host it is in [`hosting/mathlib/`](https://github.com/FujiHaruka/litedoc4/tree/main/hosting/mathlib).
