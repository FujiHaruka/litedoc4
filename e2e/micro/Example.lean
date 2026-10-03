import Example.Attrs
import Example.Basic
import Example.Dep
import Example.Gen
import Example.Math
import Example.Notation
import Example.Shapes
import Example.Sorry
import Example.Unicode
import Example.Untitled

/-!
# A sample package, one module per thing a page can carry

A small Lean package, published as a sample of what litedoc4 renders. It stands
on Lean core and on one sibling package reached by path, so there is no Mathlib
underneath and the whole site is eleven modules.

Each module shows one thing a page can carry — the kinds a declaration comes in,
attributes, scoped notation, mathematics in a docstring, `sorry` markers,
declarations Lean realized from an attribute, identifiers outside the BMP, and a
reference into a dependency that has no page here. Read a page next to the
source it links to; that is what the sample is for.

This root module imports every other one, so `lake build` over the default
target builds all of them.

A citation such as [deMoura2021], which describes Lean 4 itself, links to the
site's list of references, read from `docs/references.bib`.
-/

/-
`[deMoura2021]` here, `[TPIL4]` in `Example.Basic` and `[Graham1994]` in
`Example.Math` are the citations `tools/config-gate.sh` finds linked on the pages
every command writes. Removing all three leaves it nothing to compare. The first
is the bare-key form, whose link text becomes the entry's tag; the second keeps
its own text.
-/
