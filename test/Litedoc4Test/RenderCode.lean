/- Where a constant a code fragment tags resolves to: its module and anchor, by
the references, the map, a parent, or a private name's own module.

All closed: nothing here asks md4c anything, so `Md.events` is not on any path. -/
import Litedoc4.Render.Code
import Litedoc4Test.RenderAutolink

namespace Litedoc4Test
open Litedoc4

def noRefs : Std.HashMap String String := Std.HashMap.emptyWithCapacity 0

/-- These declarations, and **a page for every module they name** — which is
what a run has for its own package's modules. -/
def codeIndex (entries : List (String × String)) (pages : List String := [])
    (lidx : String := "") (external : List (String × String) := []) : NameIndex :=
  buildIndex #[] (alModules entries pages) (parseLidx lidx) (mkExternalLinks external.toArray)

/-- The extractor resolved every constant it tagged against the environment,
which is what makes a constant link to the module that *defined* it rather than
to whichever module happened to be read last. -/
def referencesAreConsultedBeforeTheGlobalMap : Bool :=
  let ix := codeIndex [("Nat.succ", "Stale.Module")] ["Init.Prelude"]
  let refs : Std.HashMap String String := ({} : Std.HashMap String String).insert "Nat.succ" "Init.Prelude"
  constTarget ix refs "Nat.succ" == some ("Init.Prelude", some "Nat.succ")

#guard referencesAreConsultedBeforeTheGlobalMap

/-- The last component is what is tested, the whole prefix is what is looked
up, and the two are easy to swap: `Foo.bar` answers for `Foo.bar.x` even though
`bar` is not itself in the map. A prefix with no dot left is never the answer,
even when the map holds it. -/
def linkableParentsSkipNumericAndUnderscoredComponents : Bool :=
  let ix := codeIndex [("Foo.bar", "Pkg.A"), ("Foo", "Pkg.A")]
  let odd := codeIndex [("Foo._aux", "Pkg.A"), ("Foo.1", "Pkg.A")]
  findLinkableParent ix "Foo.bar._eq_1" == some "Foo.bar"
    && findLinkableParent ix "Foo.bar.42" == some "Foo.bar"
    && findLinkableParent ix "Foo.bar.x" == some "Foo.bar"
    && findLinkableParent ix "Foo.gone.x" == none
    && findLinkableParent ix "Foo" == none
    && findLinkableParent ix "Nowhere.x" == none
    && findLinkableParent odd "Foo._aux.x" == none
    && findLinkableParent odd "Foo.1.x" == none

#guard linkableParentsSkipNumericAndUnderscoredComponents

def aConstantCanResolveThroughItsParent : Bool :=
  constTarget (codeIndex [("Nat.rec", "Init.Prelude")]) noRefs "Nat.rec._eq_2"
    == some ("Init.Prelude", some "Nat.rec")

#guard aConstantCanResolveThroughItsParent

/-- A private name is never looked up directly, even when the map has it — but
its user name can still find a parent, and that beats the module link. -/
def aPrivateNameFallsBackToItsModuleAndIsNotLookedUpDirectly : Bool :=
  constTarget (codeIndex [] ["Init.Prelude"]) noRefs "_private.Init.Prelude.0.Foo"
      == some ("Init.Prelude", none)
    && constTarget (codeIndex [("_private.Pkg.A.0.f", "Pkg.Wrong")] ["Pkg.A"]) noRefs
        "_private.Pkg.A.0.f" == some ("Pkg.A", none)
    && constTarget (codeIndex [("_private.Pkg.A.0.f.g.h", "Pkg.Wrong"), ("f.g", "Pkg.Owner")])
        noRefs "_private.Pkg.A.0.f.g.h" == some ("Pkg.Owner", some "f.g")

#guard aPrivateNameFallsBackToItsModuleAndIsNotLookedUpDirectly

/-- Lazy: the *first* `.<digits>.` after the prefix ends the module part, so a
second one does not end it earlier.

The three line-break cases are asserted rather than left unsaid. This split
walks the name's structure, so `A\nB` is a module part and `f\ng` is a user
name, where a regex-shaped reading ends the match at the terminator instead. A
declaration whose name carries a line terminator can only come out of a `«…»`
component and none has ever been seen; what would falsify the choice is such a
name reaching a page. -/
def privateNamesSplitLazilyAtTheFirstNumericComponent : Bool :=
  splitPrivate "_private.A.B.0.f" == some ("A.B", "f")
    && privateToUserName "_private.A.B.0.f" == "f"
    && privateToUserName "_private.A.0.g.1.h" == "g.1.h"
    && splitPrivate "_private.A.B" == none
    && privateToUserName "_private.A.B" == "_private.A.B"
    && splitPrivate "Pkg.A.f" == none
    && privateToUserName "" == ""
    && splitPrivate "_private.A.0.f\ng" == some ("A", "f\ng")
    && privateToUserName "_private.A.0.f\ng" == "f\ng"
    && splitPrivate "_private.A\nB.0.f" == some ("A\nB", "f")

#guard privateNamesSplitLazilyAtTheFirstNumericComponent

/-- A CSS class and not the words above, and the two sit next to each other in
the page. -/
def cssKindsAreADifferentMapping : Bool :=
  cssKind "definition" == "def" && cssKind "class_inductive" == "class"
    && cssKind "constructor" == "ctor" && cssKind "theorem" == "theorem"
    && cssKind "structure" == "structure"

#guard cssKindsAreADifferentMapping

end Litedoc4Test
