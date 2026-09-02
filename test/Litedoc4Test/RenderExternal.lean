/- Where a dependency's source lives, and where its already-rendered
documentation lives.

All closed. Nothing here parses Markdown, so even the digest guards elaborate —
`sha256Text` is Lean all the way down.

**`a_dependency_with_no_pinned_base_has_no_url` has no check of its own any
more.** `RootSource.pinned` carries a base that is not empty by construction, so
there is no state in which `moduleSourceUrl` is handed the empty prefix. What is
left of that test is the half a type cannot say: that such a root is still *in*
the map, which is what tells it from a module of the package being documented.

`the_map_collects_from_an_iterator` is not carried: `FromIterator` is Rust's
trait, and `mkExternalLinks` already takes the array. -/
import Litedoc4.External

namespace Litedoc4Test
open Litedoc4

def mathlibSrc : String :=
  "https://github.com/leanprover-community/mathlib4/blob/fabf563a7c95a166b8d7b6efca11c8b4dc9d911f"

def coreSrc : String :=
  "https://github.com/leanprover/lean4/blob/68218e876d2a38b1985b8590fff244a83c321783/src"

def mathlibDocs : String := "https://leanprover-community.github.io/mathlib4_docs"

def digestMarker : String := "litedoc4 external-links v1\n"

def docsDigestMarker : String := "litedoc4 external-links docs v1\n"

def twoRoots : ExternalLinks :=
  mkExternalLinks #[("Mathlib", mathlibSrc), ("Init", coreSrc)]

/-- The two URLs this module's own doc comment quotes off the reference tree,
built from the map rather than read out of a page — and the root module beside
them, which is the file *next to* its directory rather than one inside it. -/
def theTwoUrlsThePlanQuotesComeOutOfTheMap : Bool :=
  twoRoots.urlFor "Mathlib.Order.Basic" (some (67, 67))
      == some (mathlibSrc ++ "/Mathlib/Order/Basic.lean#L67-L67")
    && twoRoots.urlFor "Init.Prelude" none == some (coreSrc ++ "/Init/Prelude.lean")
    && twoRoots.urlFor "Mathlib" none == some (mathlibSrc ++ "/Mathlib.lean")

#guard theTwoUrlsThePlanQuotesComeOutOfTheMap

/-- The package being documented is exactly this case: a map that does not hold
a root cannot resolve it, so leaving this package's own links alone is
structural rather than a rule at the call site. -/
def aRootTheMapDoesNotHoldResolvesToNothing : Bool :=
  twoRoots.urlFor "InformationTheory.Shannon" none == none
    && twoRoots.urlFor "" none == none
    && twoRoots.sourceFor "InformationTheory" == .absent
    && (mkExternalLinks #[]).urlFor "Mathlib.Order" none == none

#guard aRootTheMapDoesNotHoldResolvesToNothing

/-- The path is the *source* path, so a quoted component loses its guillemets —
the same rule `moduleSourceUrl` follows, and the lookup key is the unescaped
first component. -/
def aQuotedComponentIsUnescapedInThePathAndInTheLookup : Bool :=
  (mkExternalLinks #[("Odd-Name", "https://host/o/r/blob/abc")]).urlFor "«Odd-Name».Inner" none
    == some "https://host/o/r/blob/abc/Odd-Name/Inner.lean"

#guard aQuotedComponentIsUnescapedInThePathAndInTheLookup

/-- **The third state** (measured 2026-08-17), reduced to the half a type cannot
say. That such a root yields no URL is `RootSource`'s job; that it is still in
the map is this one's, and it is the only thing that tells the state from the
package being documented. The two roots either side of it are in the same map,
so an answer given too widely fails here rather than downstream. -/
def aDependencyWithNoPinnedBaseIsStillInTheMap : Bool :=
  let mixed := mkExternalLinks #[("Mathlib", mathlibSrc), ("Dep", "")]
  mixed.sourceFor "Dep" == .unpinned
    && mixed.sourceFor "Pkg" == .absent
    && mixed.sourceFor "Mathlib" == .pinned mathlibSrc
    && mixed.roots.size == 2
    && mixed.urlFor "Mathlib.Order" none == some (mathlibSrc ++ "/Mathlib/Order.lean")

#guard aDependencyWithNoPinnedBaseIsStillInTheMap

/-- A trailing slash would produce `…/blob/<rev>//Mathlib/…`, which resolves on
GitHub and is not the byte the reference tree has. -/
def aTrailingSlashOnABaseIsDropped : Bool :=
  (mkExternalLinks #[("Mathlib", mathlibSrc ++ "/")]).sourceFor "Mathlib" == .pinned mathlibSrc

#guard aTrailingSlashOnABaseIsDropped

/-- First-wins, because the caller orders the entries by authority: core's four
roots are not a package's to redefine. -/
def aRepeatedRootKeepsTheFirst : Bool :=
  let two := mkExternalLinks #[("Init", coreSrc), ("Init", mathlibSrc)]
  two.roots.size == 1 && two.sourceFor "Init" == .pinned coreSrc

#guard aRepeatedRootKeepsTheFirst

/-- A function of what the map *resolves*, not of how it was built — otherwise a
resolver that reorders its scan re-renders every page for nothing. -/
def theDigestIgnoresInsertionOrderAndMovesWithARevision : Bool :=
  let backward := mkExternalLinks #[("Init", coreSrc), ("Mathlib", mathlibSrc)]
  let bumped := mkExternalLinks
    #[("Mathlib", "https://github.com/leanprover-community/mathlib4/blob/0000000"), ("Init", coreSrc)]
  twoRoots.digest == backward.digest
    && twoRoots.roots[0]!.name != backward.roots[0]!.name
    && twoRoots.digest != bumped.digest
    && twoRoots.digest != (mkExternalLinks #[]).digest

#guard theDigestIgnoresInsertionOrderAndMovesWithARevision

/-- The two values are **not** this implementation's output copied down — they
are `shasum -a 256` of the canonical bytes, taken outside both halves. Copying
the code's own answer would make the guard hold for any change to the canonical
form, which is the one thing it is here to catch. They also pin `sha256Text`
against an oracle that is neither of these implementations. -/
def theDigestIsTheShasumOfTheCanonicalBytes : Bool :=
  (mkExternalLinks #[]).digest
      == "dea955012a343d7bd694bd443e8f3a627e30ac4111d3ed768e3c51574bc96fa1"
    && twoRoots.digest == "0809d24d45f1a20338c93ef87ca084bb5127d84e60772521c4d43e4d4fecfea6"
    && (mkExternalLinks #[("Mathlib", mathlibSrc), ("Init", coreSrc), ("Dep", "")]).canonical
      == digestMarker ++ "Dep\t\nInit\t" ++ coreSrc ++ "\nMathlib\t" ++ mathlibSrc ++ "\n"

#guard theDigestIsTheShasumOfTheCanonicalBytes

/-- An unpinnable root is a line with an empty second field and not an absent
line, which is what makes it an input to the render key. -/
def theCanonicalFormIsTheMarkerAndOneSortedLinePerRoot : Bool :=
  twoRoots.canonical == digestMarker ++ "Init\t" ++ coreSrc ++ "\nMathlib\t" ++ mathlibSrc ++ "\n"
    && (mkExternalLinks #[]).canonical == digestMarker
    && (mkExternalLinks #[]).digest.length == 64

#guard theCanonicalFormIsTheMarkerAndOneSortedLinePerRoot

/-- mathlib pinned *and* documented, holding one name and one module out of that
site's table. -/
def withMathlibDocs : ExternalLinks :=
  twoRoots.withDocs #[("Mathlib", mkDepDocs mathlibDocs
    #[("Mathlib.Order.le_refl", "./Mathlib/Order/Basic.html#le_refl")]
    #[("Mathlib.Order.Basic", "./Mathlib/Order/Basic.html")])]

/-- The name the table holds resolves on the documentation site; the one it does
not gets nothing from here, which is what sends `linkTo` on to the version-pinned
source — and that source is untouched by any of this. -/
def aNameTheTableHoldsResolvesAndOneItDoesNotDoesNot : Bool :=
  withMathlibDocs.docsUrlFor "Mathlib.Order.Basic" (some "Mathlib.Order.le_refl")
      == some (mathlibDocs ++ "/Mathlib/Order/Basic.html#le_refl")
    && withMathlibDocs.docsUrlFor "Mathlib.Order.Basic" (some "Mathlib.Order.le_rfl") == none
    && withMathlibDocs.urlFor "Mathlib.Order.Basic" (some (67, 67))
      == some (mathlibSrc ++ "/Mathlib/Order/Basic.lean#L67-L67")

#guard aNameTheTableHoldsResolvesAndOneItDoesNotDoesNot

/-- A module is answered out of the table's own `modules` section, and a root
with no documentation site is not this state at all. -/
def aModuleIsVerifiedOutOfTheTablesModuleSection : Bool :=
  withMathlibDocs.docsUrlFor "Mathlib.Order.Basic" none
      == some (mathlibDocs ++ "/Mathlib/Order/Basic.html")
    && withMathlibDocs.docsUrlFor "Mathlib.Order.Defs" none == none
    && withMathlibDocs.docsUrlFor "Init.Prelude" none == none
    && (withMathlibDocs.docsFor "Init").isNone

#guard aModuleIsVerifiedOutOfTheTablesModuleSection

/-- The value that reaches the href is the table's, not one built out of the
module name: the point of consulting a table is that it knows where a name moved
to. `./` and a leading `/` are both stripped, **each as often as it is there** —
joined onto the base, one surviving `/` puts the link at a path of the docs host
that the table never named. -/
def theHrefIsTheTablesOwnDocLink : Bool :=
  let moved := (mkExternalLinks #[]).withDocs #[("Mathlib", mkDepDocs mathlibDocs
    #[("Mathlib.Old.thing", "./Mathlib/New/Home.html#thing")]
    #[("Mathlib.Old", "/Mathlib/New/Home.html"), ("Mathlib.Odd", ".//Odd.html"),
      ("Mathlib.Twice", ".././Twice.html")])]
  moved.docsUrlFor "Mathlib.Old" (some "Mathlib.Old.thing")
      == some (mathlibDocs ++ "/Mathlib/New/Home.html#thing")
    && moved.docsUrlFor "Mathlib.Old" none == some (mathlibDocs ++ "/Mathlib/New/Home.html")
    && moved.docsUrlFor "Mathlib.Odd" none == some (mathlibDocs ++ "/Odd.html")
    && stripDocLink "././Twice.html" == "Twice.html"

#guard theHrefIsTheTablesOwnDocLink

/-- The root arrives **unpinned** — the third state — so a name the table does
not document gets no link rather than a relative one to a page this site never
writes. `litedoc4 render --deps-docs-map <file>` without `--root` is this case:
a resolved documentation map and no manifest to pin sources from. -/
def aDocsRootTheSourceMapDoesNotHoldArrivesUnpinned : Bool :=
  let map := (mkExternalLinks #[]).withDocs #[("Dep", mkDepDocs mathlibDocs
    #[("Dep.thing", "./Dep.html#thing")] #[("Dep", "./Dep.html")])]
  map.sourceFor "Dep" == .unpinned
    && map.urlFor "Dep.Aux" none == none
    && map.docsUrlFor "Dep" (some "Dep.thing") == some (mathlibDocs ++ "/Dep.html#thing")

#guard aDocsRootTheSourceMapDoesNotHoldArrivesUnpinned

def aRepeatedDocsRootKeepsTheFirst : Bool :=
  let one := mkDepDocs mathlibDocs #[("A.b", "./A.html#b")] #[("A", "./A.html")]
  let two := mkDepDocs "https://other.invalid" #[("A.b", "./Z.html#b")] #[]
  let map := (mkExternalLinks #[("A", "")]).withDocs #[("A", one), ("A", two)]
  (map.docsFor "A").map (·.base) == some mathlibDocs
    && (map.roots.filter (·.docs.isSome)).size == 1

#guard aRepeatedDocsRootKeepsTheFirst

def docsOf (declarations modules : Array (String × String)) : ExternalLinks :=
  (mkExternalLinks #[("Mathlib", mathlibSrc)]).withDocs
    #[("Mathlib", mkDepDocs mathlibDocs declarations modules)]

/-- Same entries in another order hash alike; one entry moved to another page
does not — which is what a rebuilt mathlib4_docs looks like from here, and it has
to re-render. So does a name the table stopped documenting, and so does turning
the feature on at all. -/
def theDigestMovesWithTheTablesContentsAndNotWithInsertionOrder : Bool :=
  let forward := docsOf #[("Mathlib.b", "./B.html#b"), ("Mathlib.a", "./A.html#a")]
    #[("Mathlib.B", "./B.html"), ("Mathlib.A", "./A.html")]
  let backward := docsOf #[("Mathlib.a", "./A.html#a"), ("Mathlib.b", "./B.html#b")]
    #[("Mathlib.A", "./A.html"), ("Mathlib.B", "./B.html")]
  let moved := docsOf #[("Mathlib.a", "./A.html#a"), ("Mathlib.b", "./C.html#b")]
    #[("Mathlib.A", "./A.html"), ("Mathlib.B", "./B.html")]
  let dropped := docsOf #[("Mathlib.a", "./A.html#a")]
    #[("Mathlib.A", "./A.html"), ("Mathlib.B", "./B.html")]
  forward.digest == backward.digest
    && forward.digest != moved.digest
    && forward.digest != dropped.digest
    && forward.digest != (mkExternalLinks #[("Mathlib", mathlibSrc)]).digest

#guard theDigestMovesWithTheTablesContentsAndNotWithInsertionOrder

/-- The docs section is written **only** when there is one, which is what keeps a
ledger written by a run that did not use the feature valid. -/
def theDocsSectionIsAbsentUntilARootHasOneAndThenCountsItself : Bool :=
  (twoRoots.canonical.splitOn docsDigestMarker).length == 1
    && withMathlibDocs.canonical == digestMarker ++ "Init\t" ++ coreSrc ++ "\nMathlib\t"
      ++ mathlibSrc ++ "\n" ++ docsDigestMarker ++ "Mathlib\t" ++ mathlibDocs ++ "\t1\t1\n"
      ++ "Mathlib.Order.le_refl\tMathlib/Order/Basic.html#le_refl\n"
      ++ "Mathlib.Order.Basic\tMathlib/Order/Basic.html\n"

#guard theDocsSectionIsAbsentUntilARootHasOneAndThenCountsItself

/-- The claim `sortedPairs`' docstring makes, on an input long enough for the
sort to have a choice: **a table that names one declaration twice resolves to the
last entry on both sides**. `Array.qsort` is not stable, so reading the last of a
run of equal keys off the sorted array answers whichever the partition left
there — with these eight entries it answered the **first** `a` (measured
2026-08-31). -/
def aTableThatNamesADeclarationTwiceKeepsTheLastEntry : Bool :=
  let docs := mkDepDocs mathlibDocs
    #[("m", "./m.html"), ("a", "./1.html"), ("z", "./z.html"), ("a", "./2.html"),
      ("k", "./k.html"), ("a", "./3.html"), ("b", "./b.html"), ("a", "./4.html")] #[]
  docs.declarations.size == 5
    && docs.urlForName "a" == some (mathlibDocs ++ "/4.html")
    && docs.declarations.map (·.1) == #["a", "b", "k", "m", "z"]

#guard aTableThatNamesADeclarationTwiceKeepsTheLastEntry


end Litedoc4Test
