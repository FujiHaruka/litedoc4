---
title: What the pages show
description: The module list, math, sorry markers and citations.
---

## The module list

The front page lists every module of your package, with a one-line description, and a module tree. The description is the heading that the module docstring opens with:

```lean
/-!
# Strong typicality (Cover-Thomas)

Three main theorems for the strongly typical set …
-/
```

`Strong typicality (Cover-Thomas)` becomes that module's row on the front page. The text under the heading stays on the module's own page. A module whose docstring opens with prose is listed by name only.

## Search and links

Search covers the declarations of your package. Each page shows instance lists, "Imported by" and "Used by" within your package. In signatures, every name from a dependency links to its source on GitHub at the revision you pinned.

## Math

`$…$` and `$$…$$` become MathML when the site is built. Nothing is loaded in the browser to draw them: no MathJax, no KaTeX and no math web font, because current browsers lay out MathML themselves. A formula that cannot be converted is shown as its source.

## `sorry`

- **uses `sorry`**: the declaration's own statement or proof has a `sorry`.
- **depends on `sorry`**: its own proof is complete, but a declaration under it uses `sorry`.

The answer comes from the compiled environment (the declaration's axioms), so it holds through any depth of dependencies. A declaration with neither mark has no `sorry` under it.

A declaration that Lean made from `@[ext]` is marked **realized by `@[ext]` from …**, with a link to the declaration it came from.

## Citations

Put a BibTeX file at `docs/references.bib` in your package and cite its entries from any docstring:

```lean
/-- The entropy bound of [CoverThomas2006], proved as in [chapter 2][CoverThomas2006]. -/
```

- `[Key]` becomes a link that shows the entry's tag. `[text][Key]` keeps your text.
- Both link to `references.html`, which lists every entry with the anchor `#ref_Key`. Each entry ends with numbered links back to every place that cites it.
- The tags and the entry text come from BibtexQuery, the library doc-gen4 uses, so they match a doc-gen4 site.
- A bracket that is not a key in the file stays as you wrote it.
- BibtexQuery cannot read `@string`, `@comment` or `@preamble`, or a stray `@` in a note, and stops at the first one. The build prints a warning with the file and line, because that entry and every entry after it are left out.
