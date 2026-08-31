/- `crates/litedoc4-render/src/code.rs`: one printed code fragment — a
declaration's result type, a binder, an equation, a member's text — turned into
HTML from its flat pre-order span list.

All closed. The fragment walk reads printed Lean and its tag positions and never
asks md4c anything, so `Md.events` is not on any path here.

`SpanTree::build` has no counterpart to name: the tree is built inside
`fragment`, so the shape it produces is asserted through the bytes, which is
also where getting it wrong shows up. -/
import Litedoc4.Render.Code
import Litedoc4Test.RenderAutolink

namespace Litedoc4Test
open Litedoc4

/-- `[start, stop, 1, name]`. -/
def codeConst (start stop : Nat) (name : String) : Span :=
  { start, stop, kind := 1, name }

def codeFn (start stop : Nat) : Span := { start, stop, kind := 0 }

def codeSort (start stop : Nat) : Span := { start, stop, kind := 2 }

def noRefs : Std.HashMap String String := Std.HashMap.emptyWithCapacity 0

/-- These declarations, and **a page for every module they name** — which is
what a run has for its own package's modules. -/
def codeIndex (entries : List (String × String)) (pages : List String := [])
    (lidx : String := "") (external : List (String × String) := []) : NameIndex :=
  buildIndex #[] (alModules entries pages) (parseLidx lidx) (mkExternalLinks external.toArray)

def codeHtml (ix : NameIndex) (root text : String) (spans : Array Span) : String :=
  (fragment ix noRefs root text spans).1

def codeAnchored (ix : NameIndex) (root text : String) (spans : Array Span) : Bool :=
  (fragment ix noRefs root text spans).2

/-- `>=` and not `>` when the stack is popped: two spans that merely touch are
siblings, and `6..9` becoming a child of `0..6` makes the walk slice text
outside its parent's range. -/
def buildTreeNestsOnContainmentNotOnTouching : Bool :=
  codeHtml (codeIndex []) "./" "abcdefghi"
      #[codeFn 0 6, codeFn 0 3, codeFn 3 6, codeFn 6 9]
    == "<span class=\"fn\"><span class=\"fn\">abc</span><span class=\"fn\">def</span></span>\
        <span class=\"fn\">ghi</span>"

#guard buildTreeNestsOnContainmentNotOnTouching

/-- The apostrophe is what a general HTML escaper would rewrite and
`Html.escape` does not, which is one byte of mismatch per `foo'` in the package. -/
def untaggedTextIsEscapedAndTagsWrapAndTheApostropheIsNot : Bool :=
  let ix := codeIndex []
  codeHtml ix "./" "a<b & c" #[codeFn 0 3] == "<span class=\"fn\">a&lt;b</span> &amp; c"
    && !codeAnchored ix "./" "a<b & c" #[codeFn 0 3]
    && codeHtml ix "./" "f'" #[] == "f'"

#guard untaggedTextIsEscapedAndTagsWrapAndTheApostropheIsNot

def aSortLinksToTheFoundationalTypesPage : Bool :=
  let ix := codeIndex []
  codeHtml ix "../.././" "Type" #[codeSort 0 4]
      == "<a href=\"../.././foundational_types.html\">Type</a>"
    && codeAnchored ix "../.././" "Type" #[codeSort 0 4]

#guard aSortLinksToTheFoundationalTypesPage

/-- Both directions: a sort around a linked constant renders no anchor of its
own and the flag still comes back set, and an unlinkable constant around a sort
keeps its `span.fn` outside the sort's anchor. Nested anchors are valid-looking
HTML and wrong bytes. -/
def anAnchorInsideAnAnchorIsSuppressed : Bool :=
  let ix := codeIndex [("Nat", "Init.Prelude")]
  codeHtml ix "./" "Nat" #[codeSort 0 3, codeConst 0 3 "Nat"]
      == "<a href=\"./Init/Prelude.html#Nat\">Nat</a>"
    && codeAnchored ix "./" "Nat" #[codeSort 0 3, codeConst 0 3 "Nat"]
    && codeHtml ix "./" "Type" #[codeConst 0 4 "Nowhere", codeSort 0 4]
      == "<span class=\"fn\"><a href=\"./foundational_types.html\">Type</a></span>"

#guard anAnchorInsideAnAnchorIsSuppressed

/-- The extractor resolved every constant it tagged against the environment,
which is what makes a constant link to the module that *defined* it rather than
to whichever module happened to be read last. -/
def referencesAreConsultedBeforeTheGlobalMap : Bool :=
  let ix := codeIndex [("Nat.succ", "Stale.Module")] ["Init.Prelude"]
  let refs := declRefs { refs := #[("Init.Prelude", "Nat.succ")] }
  (fragment ix refs "./" "Nat.succ" #[codeConst 0 8 "Nat.succ"]).1
    == "<a href=\"./Init/Prelude.html#Nat.succ\">Nat.succ</a>"

#guard referencesAreConsultedBeforeTheGlobalMap

/-- A module name with a `&` in it is not reachable in practice; the escape is
in the byte path all the same. -/
def theLinkTargetIsEscaped : Bool :=
  codeHtml (codeIndex [("f", "A&B")]) "./" "f" #[codeConst 0 1 "f"]
    == "<a href=\"./A&amp;B.html#f\">f</a>"

#guard theLinkTargetIsEscaped

def initSrc : String := "https://github.com/leanprover/lean4/blob/dead/src"

/-- All three of `constLink`'s linking branches against a version-pinned
dependency. Branch 2 links the **parent**, so the anchor has to be the parent's
source range and not the name's own and not none; branch 3 links a file, which
has no range at all. -/
def aConstantFromADependencyLinksAtItsPinnedSource : Bool :=
  let ix := codeIndex [("Nat", "Init.Prelude"), ("Nat.rec", "Init.Prelude"), ("Pkg.f", "Pkg.A")]
    [] "Init.Prelude\n\tNat\t26\t27\n\tNat.rec\t44\t50\n" [("Init", initSrc)]
  codeHtml ix "./" "Nat" #[codeConst 0 3 "Nat"]
      == "<a href=\"" ++ initSrc ++ "/Init/Prelude.lean#L26-L27\">Nat</a>"
    && codeHtml ix "./" "f" #[codeConst 0 1 "Pkg.f"] == "<a href=\"./Pkg/A.html#Pkg.f\">f</a>"
    && codeHtml ix "./" "h" #[codeConst 0 1 "Nat.rec._eq_2"]
      == "<a href=\"" ++ initSrc ++ "/Init/Prelude.lean#L44-L50\">h</a>"
    && codeHtml ix "./" "h" #[codeConst 0 1 "_private.Init.Prelude.0.Foo"]
      == "<a href=\"" ++ initSrc ++ "/Init/Prelude.lean\">h</a>"

#guard aConstantFromADependencyLinksAtItsPinnedSource

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
  codeHtml (codeIndex [("Nat.rec", "Init.Prelude")]) "./" "h" #[codeConst 0 1 "Nat.rec._eq_2"]
    == "<a href=\"./Init/Prelude.html#Nat.rec\">h</a>"

#guard aConstantCanResolveThroughItsParent

/-- A private name is never looked up directly, even when the map has it — but
its user name can still find a parent, and that beats the module link. -/
def aPrivateNameFallsBackToItsModuleAndIsNotLookedUpDirectly : Bool :=
  codeHtml (codeIndex [] ["Init.Prelude"]) ".././" "h" #[codeConst 0 1 "_private.Init.Prelude.0.Foo"]
      == "<a href=\".././Init/Prelude.html\">h</a>"
    && codeHtml (codeIndex [("_private.Pkg.A.0.f", "Pkg.Wrong")] ["Pkg.A"]) "./" "h"
        #[codeConst 0 1 "_private.Pkg.A.0.f"] == "<a href=\"./Pkg/A.html\">h</a>"
    && codeHtml (codeIndex [("_private.Pkg.A.0.f.g.h", "Pkg.Wrong"), ("f.g", "Pkg.Owner")]) "./"
        "h" #[codeConst 0 1 "_private.Pkg.A.0.f.g.h"]
      == "<a href=\"./Pkg/Owner.html#f.g\">h</a>"

#guard aPrivateNameFallsBackToItsModuleAndIsNotLookedUpDirectly

/-- Lazy: the *first* `.<digits>.` after the prefix ends the module part, so a
second one does not end it earlier.

The three line-break cases are where this port and
`crates/litedoc4-render/src/code.rs` answer differently, and they are asserted
rather than left unsaid. Rust reproduces two JavaScript regexes: `.` does not
match a line terminator, and `privateToUserName`'s trailing `$` is end of input,
so a break in the tail makes that match fail while `moduleFromPrivatePrefix`'s
still succeeds. This split walks the name's structure instead, so `A\nB` is a
module part and `f\ng` is a user name. A declaration whose name carries a line
terminator can only come out of a `«…»` component and neither half has ever seen
one; what would falsify the choice is such a name reaching a page, where the two
halves would then disagree about where its link points. -/
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

/-- `𝓧` is two UTF-16 units, so the tag on `y` starts at 3 and a walk over bytes
or over characters would wrap the space instead. -/
def offsetsAreUtf16CodeUnitsInAFragment : Bool :=
  codeHtml (codeIndex [("X", "Pkg.A")]) "./" "𝓧 y" #[codeConst 3 4 "X"]
    == "𝓧 <a href=\"./Pkg/A.html#X\">y</a>"

#guard offsetsAreUtf16CodeUnitsInAFragment

/-- Replayed *before* the walk, and the walk still uses the original offsets —
which is only sound because the rewrite is length-preserving. -/
def theWhitespaceRewriteRunsFirst : Bool :=
  codeHtml (codeIndex [("HAdd.hAdd", "Init.Prelude")]) "./" "a\n+\tb"
      #[{ start := 2, stop := 3, kind := 1, name := "HAdd.hAdd", front := 1, back := 1 }]
    == "a <a href=\"./Init/Prelude.html#HAdd.hAdd\">+</a> b"

#guard theWhitespaceRewriteRunsFirst

/-- The words a reader sees. `partial` beats `unsafe` and renames the kind
entirely; `abbrev` does not reach the instance branch. -/
def kindDescriptionsRecomposeTheModifiers : Bool :=
  kindDescription "definition" #[] == "def"
    && kindDescription "definition" #["abbrev"] == "abbrev"
    && kindDescription "definition" #["noncomputable", "unsafe", "abbrev"]
      == "unsafe noncomputable abbrev"
    && kindDescription "instance" #["noncomputable"] == "noncomputable instance"
    && kindDescription "instance" #["abbrev"] == "instance"
    && kindDescription "axiom" #["unsafe"] == "unsafe axiom"
    && kindDescription "axiom" #["partial"] == "axiom"
    && kindDescription "opaque" #["partial", "unsafe"] == "partial def"
    && kindDescription "opaque" #["unsafe"] == "unsafe opaque"
    && kindDescription "opaque" #[] == "opaque"
    && kindDescription "inductive" #["unsafe"] == "unsafe inductive"
    && kindDescription "class_inductive" #["unsafe"] == "class inductive"
    && kindDescription "theorem" #["unsafe"] == "theorem"

#guard kindDescriptionsRecomposeTheModifiers

/-- A CSS class and not the words above, and the two sit next to each other in
the page. -/
def cssKindsAreADifferentMapping : Bool :=
  cssKind "definition" == "def" && cssKind "class_inductive" == "class"
    && cssKind "constructor" == "ctor" && cssKind "theorem" == "theorem"
    && cssKind "structure" == "structure"

#guard cssKindsAreADifferentMapping

/-- The component is escaped, the separator is not. -/
def breakWithinWrapsEachComponent : Bool :=
  breakWithin "" "Nat.succ"
      == "<span class=\"name\">Nat</span>.<span class=\"name\">succ</span>"
    && breakWithin "" "Nat" == "<span class=\"name\">Nat</span>"
    && breakWithin "" "a<b" == "<span class=\"name\">a&lt;b</span>"

#guard breakWithinWrapsEachComponent

end Litedoc4Test
