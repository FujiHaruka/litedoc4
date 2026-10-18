---
title: Configuring the site
description: The litedoc4.toml file and its four keys.
---

Put `litedoc4.toml` next to your lakefile. Every key is optional.

```toml
title = "MyPkg"                 # top bar and page titles; default: your modules' shared prefix
index = "docs/index.md"         # Markdown at the top of the front page
footer = "docs/footer.md"       # Markdown at the bottom of every page
no_equations_under = ["MyPkg.Tactic"]   # namespaces whose definitions get no equations
```

## `title`

Shown in the top bar and in the second half of every page's `<title>`. Without it, the title is the name that your modules share (`Foo.*` gives `Foo`), which is what a reader types to import your package.

## `index` and `footer`

Markdown files, relative to the directory that holds `litedoc4.toml`. They are rendered the way docstrings are, so a name in backticks links to its declaration.

- `index` is put at the top of the site's front page.
- `footer` is put at the bottom of every page: module pages, the front page, search, references and the not-found page. Use it for a license line or a notice about who publishes the site.

## `no_equations_under`

For implementation code such as tactics, elaborators and metaprograms, whose equations would print the code's own body back as a lemma. A definition whose name is inside one of these namespaces gets no equations: they are not generated. `MyPkg.Tactic.ring_nf` is inside `MyPkg.Tactic`. `MyPkg.TacticX.foo` and `MyPkg.Tactic` itself are not.

The signature, docstring and source link stay. Changing the list extracts every module again on the next build.

## Errors stop the build

A malformed file, an unknown key, or an `index` or `footer` that names a missing file stops the build.

## A package you do not control

Keep the file somewhere else and pass it with `--config` (to `build` or `watch`). It is read instead of the package's own `litedoc4.toml`, for every version of a `--versions` build. Its `index` and `footer` are relative to its own directory. `docs/references.bib` is still read from the package.

The title, front page and footer are applied when the site is rendered, so changing them renders every version again and extracts none. Changing `no_equations_under` extracts every version again. A `--config` that names a missing file stops the build.
