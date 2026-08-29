import «Dep-Aux».Basic

/-!
# Dep

A module that reaches into a dependency, and the one place on this site where a
reference goes somewhere litedoc4 will not write a page for.

litedoc4 documents this package only. A reference to a dependency becomes a link
into that dependency's **version-pinned source**, taken from the revision your
`lake-manifest.json` records. `«Dep-Aux»` is required by *path*, so its manifest
entry has no repository and no revision: there is no revision to link into, and
a link to the wrong page is worse than no link. The names below stay as text.
-/

/--
Names `DepAux.marker`, a declaration in a dependency module.

The module is spelled three ways on purpose, because a module name is written
with guillemets in some places and without them in others:

* `«Dep-Aux».Basic` — the way Lean spells it
* `Dep-Aux.Basic` — the same name without the guillemets
* `Dep-Aux/Basic.lean` — the path to the file it lives in

All three name one module, and litedoc4 gives all three the same answer. Here
that answer is "no link", because the dependency cannot be pinned; where it can,
all three become the same URL into its source.
-/
def Micro.usesDep : Nat := DepAux.marker + 1
