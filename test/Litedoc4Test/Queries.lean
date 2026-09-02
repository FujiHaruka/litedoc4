/- The rows `litedoc4 links` prints — one per resolved dependency root, with a
deeper module sampled out of the `.lidx` so that the path building is exercised
on something that has a dot in it.

Both halves are pure here, so the whole of this file is compile time. What is not
carried is the printing: the tab-separated line and the JSON record are the
command's output and belong to whatever reads them, not to this. -/
import Litedoc4.Main

namespace Litedoc4Test
open Litedoc4

def mathlibBase : String := "https://example.invalid/blob/deadbeef"

def fourRoots : Lidx :=
  parseLidx "#lidx2\n@Mathlib\n@Mathlib.Order.Basic\n@Mathlib.Algebra.Group\n@Init.Prelude\n"

/-- Lexicographically first **below** the root, not shortest and not the root
itself: a sample that moved when the index gained a module would make every row
of the report move with it, and a root that sampled itself would fill the deep
column with the URL that is already in the row's own. The last clause is the
separator doing its work — `MathlibTest.Foo` starts with `Mathlib` and is not a
module of it. -/
def theDeepSampleIsTheFirstModuleStrictlyBelowTheRoot : Bool :=
  sampleModule fourRoots "Mathlib" == some "Mathlib.Algebra.Group"
    && sampleModule (parseLidx "#lidx2\n@Init\n") "Init" == none
    && sampleModule (parseLidx "#lidx2\n@MathlibTest.Foo\n") "Mathlib" == none
    && sampleModule fourRoots "Init" == some "Init.Prelude"

#guard theDeepSampleIsTheFirstModuleStrictlyBelowTheRoot

/-- Every URL in a row comes from `ExternalLinks.urlFor`, never from joining the
base to the module name here: a report that built the URL its own way would agree
with a renderer that built it wrongly. Stated as the two columns of one row, so
that the root's own file and the sampled module's are answered by the same
call. -/
def bothColumnsComeFromUrlFor : Bool :=
  let rows := linkRows (mkExternalLinks #[("Mathlib", mathlibBase)]) (some fourRoots)
  rows.size == 1 && rows.all fun row =>
    row.root == "Mathlib"
      && row.base == mathlibBase
      && row.url == some (mathlibBase ++ "/Mathlib.lean")
      && row.deep == some ("Mathlib.Algebra.Group", mathlibBase ++ "/Mathlib/Algebra/Group.lean")

#guard bothColumnsComeFromUrlFor

/-- Without a `.lidx` there is nothing to sample from, so the deep column is
absent rather than a repeat of the row's own URL — the shape a reader would
count as coverage. -/
def withoutAnIndexThereIsNoDeepColumn : Bool :=
  let rows := linkRows (mkExternalLinks #[("Mathlib", mathlibBase)]) none
  rows.size == 1 && rows.all fun row => row.url.isSome && row.deep == none

#guard withoutAnIndexThereIsNoDeepColumn

/-- The unpinnable third state, in a report rather than on a page: the root is in
the map and neither column has a URL. A row that filled them in would print
`/Dep/Inner.lean`, an absolute path on whatever host serves the site. -/
def aRootWithNoBaseGetsNoUrlInEitherColumn : Bool :=
  let rows := linkRows (mkExternalLinks #[("Dep", "")]) (some (parseLidx "#lidx2\n@Dep.Inner\n"))
  rows.size == 1 && rows.all fun row =>
    row.root == "Dep" && row.base == ""
      && row.url == none && row.deep == none && row.deepDocsUrl == none

#guard aRootWithNoBaseGetsNoUrlInEitherColumn

/-- `merge`'s output tree defaults to `<base>.merged` and **never to the base**:
a merge folds a partial extraction into a tree it is reading, so a default of
`--base` would destroy the only copy of it. Rewriting the base has to be asked
for by name, which is what the round loop does and what nobody does by
accident. -/
def aMergeNeverDefaultsToTheTreeItIsReading : Bool :=
  mergeOut none "/work/ir" == "/work/ir.merged"
    && mergeOut (some "/work/out") "/work/ir" == "/work/out"
    && mergeOut (some "/work/ir") "/work/ir" == "/work/ir"

#guard aMergeNeverDefaultsToTheTreeItIsReading

end Litedoc4Test
