---
title: litedoc4
description: HTML documentation for Lean 4 packages built on Mathlib, fast, with every version in one site.
template: splash
hero:
  tagline: HTML documentation for Lean 4 packages built on Mathlib. It is fast, and it puts every version in one site.
  image:
    light: ../../../../docs/images/site-light.png
    dark: ../../../../docs/images/site-dark.png
    alt: A module page from the live example, showing the module docstring, a theorem with its full signature, a module tree and a search box.
  actions:
    - text: Quickstart
      link: /litedoc4/getting-started/quickstart/
      icon: right-arrow
    - text: GitHub
      link: https://github.com/FujiHaruka/litedoc4
      icon: external
      variant: minimal
---

litedoc4 documents your package and nothing else. Mathlib, Batteries, Lean core and anything else your `lake-manifest.json` pins are never generated again. Each reference to them links to that dependency's source on GitHub, at the exact revision you build against. The output is a static site.

## See it running

- [information-theory](https://fujiharuka.github.io/information-theory/): a package of about 420 modules on Mathlib
- [mathlib.fuji.land](https://mathlib.fuji.land): Mathlib itself, twelve releases in one site
- [sample](https://fujiharuka.github.io/litedoc4/sample/): a small package that shows every shape a page can take

## Why it is fast

- **Your package, not Mathlib.** doc-gen4 writes pages for everything you import. litedoc4 writes pages for your package and links to the rest.
- **Only what changed.** A rebuild extracts again only the modules whose oleans changed.
- **One Lean environment.** Modules are extracted in parallel threads inside one environment. There is no process per module that loads its imports again.

| | doc-gen4 | litedoc4 |
|---|---:|---:|
| A package of 419 modules on Mathlib | documents all of Mathlib too | **14 s** |
| Batteries | 80 s | **8.5 s** |
| Mathlib | 1 h 53 min | **9.4 min** |

All times (measured) on GitHub `ubuntu-latest` runners on 2026-10-17, with Lean v4.31.0 for the first row and v4.35.0 for the others. doc-gen4's times include the pages it also writes for Lean core and the dependencies. Conditions and logs are on the [Performance](/litedoc4/performance/) page.

## Every version in one site

Give litedoc4 tags, branches or commits, and it builds one site that holds all of them. Each version has its own path, and the version switcher on every page keeps you on the same page. Built versions are kept, so a new release costs only that release: adding Mathlib's twelfth release to mathlib.fuji.land took about 12 minutes (measured). See [Several versions](/litedoc4/guides/versions/).
