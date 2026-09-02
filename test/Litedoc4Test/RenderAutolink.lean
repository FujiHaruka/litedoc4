/- Which page a name a docstring mentions belongs to, and which of the four
kinds of link that page gets.

All closed. `autoLinkInline` walks a code span's own characters and reaches no
markdown parser, so even the guards that assert bytes elaborate — the barrier is
`Md.events` and nothing here calls it. -/
import Litedoc4.Render.Autolink

namespace Litedoc4Test
open Litedoc4

/-- One module per distinct name-to-module pair, plus modules that have a page
and declare nothing. **The modules are the page set**, which is what a run has
for its own package and only for it. -/
def alModules (entries : List (String × String)) (pages : List String) : Array Module := Id.run do
  let mut out : Array Module := #[]
  for (name, module) in entries do
    match out.findIdx? (·.name == module) with
    | some i => out := out.modify i fun m => { m with decls := m.decls.push { name } }
    | none => out := out.push { name := module, decls := #[{ name }] }
  for module in pages do
    if !out.any (·.name == module) then out := out.push { name := module }
  return out

def alIndex (entries : List (String × String)) (pages : List String)
    (lidx : String := "") (external : List (String × String) := []) : NameIndex :=
  buildIndex #[] (alModules entries pages) (parseLidx lidx) (mkExternalLinks external.toArray)

/-- The module `MODULE_JSON` is, as values: a declaration whose references name
one module of a dependency and one of this package, a private declaration, and
two declarations whose IR order is not their declaration-range order. -/
def pkgTwo : Module :=
  { name := "Pkg.Two"
    decls := #[
      { name := "Pkg.Two.b", kind := "theorem", line := 9, col := 0, index := 1
        refs := #[("Dep.M", "Dep.shared"), ("Pkg.One", "Pkg.One.a")] },
      { name := "_private.Pkg.Two.hidden", kind := "def", line := 3, col := 0, index := 0 },
      { name := "Pkg.Two.a", kind := "def", line := 5, col := 0, index := 2 }] }

def alResolve (ix : NameIndex) (m : Module) (s : String) : Option String :=
  nameToLink (mkPageCtx ix "../" m) s

def nameLiteralsAcceptWhatLeanAccepts : Bool :=
  ["Nat", "Nat.succ", "Nat.succ'", "foo!", "foo?", "_root_.Nat", "Nat.1", "«a b».c",
    "«».x", "α", "ℕ.add", "𝒜.mem", "x₁", "Foo.«bar»"].all isNameLit
    && ["", ".", "a.", ".a", "a..b", "a b", "a-b", "λ", "Π", "Σ", "«a", "a«b»", "1a", "-1",
        "Nat.$x"].all (fun s => !isNameLit s)

#guard nameLiteralsAcceptWhatLeanAccepts

/-- The last of `isLetterLike`'s ranges is **above the BMP**, and a port that
quietly dropped it would still resolve every ASCII name, which is nearly all of
them. Its two ends are what is asserted here; that `𝒜` is an identifier
character and `ﬀ` is not is `Litedoc4Test.IrName`'s, over the same table read
for the other of its two jobs. -/
def letterLikeReachesTheMathematicalAlphanumerics : Bool :=
  isLetterLike (Char.ofNat 0x1d49c) && isLetterLike (Char.ofNat 0x1d59f)
    && !isLetterLike (Char.ofNat 0x1d49b) && !isLetterLike (Char.ofNat 0x1d5a0)
    && isNameLit "𝒜" && isNameLit "Foo.𝒜'"

#guard letterLikeReachesTheMathematicalAlphanumerics

/-- Declaration-range order and not the IR's: passing the IR's own order picks
the wrong one of two candidates in the last branch below. -/
def declNamesAreInDeclarationRangeOrderWithoutThePrivateOnes : Bool :=
  moduleDeclNames pkgTwo == #["Pkg.Two.a", "Pkg.Two.b"]

#guard declNamesAreInDeclarationRangeOrderWithoutThePrivateOnes

/-- Order is behaviour: a declaration overwrites what a dependency slice put
there, a reference only fills a gap, and a private name is in the map — it is
`nameToLink` that refuses to look one up, not the map that lacks it. -/
def aReferenceFillsAGapAndADeclarationOverwrites : Bool :=
  let ix := buildIndex #[#[("Dep.shared", "Dep.Other"), ("Pkg.Two.a", "Dep.Stale")]]
    #[pkgTwo] emptyLidx (mkExternalLinks #[])
  ix.known.get? "Pkg.Two.a" == some "Pkg.Two"
    && ix.known.get? "Dep.shared" == some "Dep.Other"
    && ix.known.get? "Pkg.One.a" == some "Pkg.One"
    && ix.known.get? "_private.Pkg.Two.hidden" == some "Pkg.Two"

#guard aReferenceFillsAGapAndADeclarationOverwrites

/-- Each of the three sources contributes a module the other two do not have, so
dropping any one of them fails here. `Pkg.Empty` is the load-bearing one: a
module that declares nothing is not a value in `known` either, so it is a link
target only because the IR listed it. -/
def knownModulesIsTheUnionOfThreeSources : Bool :=
  let ix := buildIndex #[] #[pkgTwo, { name := "Pkg.Empty" }] (parseLidx "@Lidx.Only\n")
    (mkExternalLinks #[])
  ["Pkg.Empty", "Pkg.One", "Dep.M", "Lidx.Only", "Pkg.Two"].all ix.knownModules.contains
    && !ix.knownModules.contains "Nowhere"

#guard knownModulesIsTheUnionOfThreeSources

/-- Both halves are the point. `Dep-Aux.Basic` is how the `.lidx` writes
`«Dep-Aux».Basic`, and it reaches no other branch because it is not a name
literal. The second half is why this is a map rather than an unescape of the
query: `«Dep-Aux.Basic»` is a *different* module with the same unescaped
spelling, and two answers is no answer. -/
def theUnescapedSpellingOfAModuleResolvesUnlessItIsAmbiguous : Bool :=
  let ix := alIndex [] ["«Dep-Aux».Basic", "Plain.M"]
  let ambiguous := alIndex [] ["«Dep-Aux».Basic", "«Dep-Aux.Basic»"]
  ix.unescapedModules.get? "Dep-Aux.Basic" == some "«Dep-Aux».Basic"
    && alResolve ix {} "Dep-Aux.Basic" == some "../Dep-Aux/Basic.html"
    && ix.unescapedModules.get? "Plain.M" == none
    && ambiguous.unescapedModules.get? "Dep-Aux.Basic" == none
    && alResolve ambiguous {} "Dep-Aux.Basic" == none

#guard theUnescapedSpellingOfAModuleResolvesUnlessItIsAmbiguous

/-- `A.B` is a name literal, so it takes the ordinary branches; letting the
unescaped map answer for it is the one way that map could move a byte. -/
def aRealModuleKeepsItsOwnSpelling : Bool :=
  let ix := alIndex [] ["«A».B", "A.B"]
  ix.unescapedModules.get? "A.B" == none
    && alResolve ix {} "A.B" == some "../A/B.html"

#guard aRealModuleKeepsItsOwnSpelling

/-- One dependency declaration with a source range, and one dependency module
that declares nothing. -/
def alLidx : String := "@Lidx.Only\nDep.M\n\tDep.only_in_lidx\t12\t14\n"

/-- The four branches, in order, on one index. A branch that answers returns its
answer — `none` included — so `_private.Pkg.Two.hidden` gets no link from the
last branch either, and `a b` never reaches a lookup at all. -/
def resolutionTakesTheBranchesInOrder : Bool :=
  let ix := buildIndex #[] #[pkgTwo, { name := "Dep.M" }, { name := "Lidx.Only" }]
    (parseLidx alLidx) (mkExternalLinks #[])
  alResolve ix pkgTwo "Pkg.Two.a" == some "../Pkg/Two.html#Pkg.Two.a"
    && alResolve ix pkgTwo "Dep.only_in_lidx" == some "../Dep/M.html#Dep.only_in_lidx"
    && alResolve ix pkgTwo "Lidx.Only" == some "../Lidx/Only.html"
    && alResolve ix pkgTwo "a" == some "../Pkg/Two.html#Pkg.Two.a"
    && alResolve ix pkgTwo "a b" == none
    && alResolve ix pkgTwo "" == none
    && alResolve ix pkgTwo "_private.Pkg.Two.hidden" == none

#guard resolutionTakesTheBranchesInOrder

/-- `linkTo`'s four answers on **one** index, which is the only way to see that
they are one decision and not four call sites. The map and the page set disagree
on purpose: `Mathlib` is pinned, `Dep` is not, `Pkg.Two` has a page and
`Pkg.One` does not.

The declaration fragment is **replaced** by the line anchor on a pinned source
rather than appended: the two name different kinds of thing, and a blob URL
carrying `#LE.ext` points at nothing. -/
def aLinkTakesOneOfFourBranches : Bool :=
  let mathlib := "https://host/o/mathlib4/blob/fabf563"
  let ix := buildIndex #[] #[pkgTwo] (parseLidx "Mathlib.Order.Basic\n\tLE.ext\t67\t67\n")
    (mkExternalLinks #[("Mathlib", mathlib), ("Dep", "")])
  linkTo ix ".././" "Mathlib.Order.Basic" (some "LE.ext")
      == some (mathlib ++ "/Mathlib/Order/Basic.lean#L67-L67")
    && linkTo ix ".././" "Mathlib.Order.Basic" (some "no.range")
      == some (mathlib ++ "/Mathlib/Order/Basic.lean")
    && linkTo ix "../" "Dep.Aux" (some "Dep.f") == none
    && linkTo ix "../" "Dep" none == none
    && linkTo ix ".././" "Pkg.Two" (some "Pkg.Two.a") == some ".././Pkg/Two.html#Pkg.Two.a"
    && linkTo ix "./" "Pkg.Two" none == some "./Pkg/Two.html"
    && linkTo ix "../" "Pkg.One" (some "Pkg.One.a") == none
    && linkTo ix "../" "Pkg.One" none == none

#guard aLinkTakesOneOfFourBranches

/-- A module of *this* package that this run writes no page for is not a link
target either. `batteries`' `lakefile.toml` declares three `[[lean_lib]]`s, so
`--lib Batteries` extracts one of them while the `.lidx` — the whole
environment — holds all three; `Pkg.Recycling` is that shape.

The bytes are asserted and not only the resolver's answer, because the failure
this replaced is invisible at the resolver: an `<a href>` that renders perfectly
and 404s. -/
def aModuleOfThisPackageWithNoPageIsNotALink : Bool :=
  let ix := buildIndex #[] #[pkgTwo]
    (parseLidx "@Pkg.Recycling\nPkg.Recycling\n\tPkg.Recycling.helper\t3\t4\n")
    (mkExternalLinks #[])
  let page := pageRenderer (mkPageCtx ix "../" pkgTwo)
  ix.knownModules.contains "Pkg.Recycling" && !ix.pages.contains "Pkg.Recycling"
    && ix.pages.contains "Pkg.Two"
    && alResolve ix pkgTwo "Pkg.Recycling.helper" == none
    && alResolve ix pkgTwo "Pkg.Recycling" == none
    && alResolve ix pkgTwo "Pkg.One.a" == none
    && alResolve ix pkgTwo "Pkg.Two.a" == some "../Pkg/Two.html#Pkg.Two.a"
    && linkTo ix "../" "Pkg.Two" none == some "../Pkg/Two.html"
    && linkTo ix "../" "Pkg.Recycling" none == none
    && autoLinkInline "" page "Pkg.Recycling.helper" == "Pkg.Recycling.helper"

#guard aModuleOfThisPackageWithNoPageIsNotALink

/-- `PkgSole.Target` is the load-bearing distractor: it ends with the bytes of
`Sole.Target` and is not a match, because the match has to fall on a component
boundary. A port that compared bytes would find two candidates for
`Sole/Target.lean` and answer `none` — which fails in the *safe* direction,
which is why this is asserted positively. -/
def aSourcePathIsResolvedThroughTheKnownModules : Bool :=
  let ix := alIndex [] ["Mathlib.Order.Basic", "Pkg.Deep.EPI.Stam.ToBridge",
    "Other.EPI.Stam.ToBridge", "Pkg.Sole.Target", "PkgSole.Target",
    "Alpha.«Odd-Name».Inner", "A.B", "X.A.B"]
  moduleForSourcePath ix "Mathlib/Order/Basic" == some "Mathlib.Order.Basic"
    && moduleForSourcePath ix "A/B" == some "A.B"
    && moduleForSourcePath ix "Sole/Target" == some "Pkg.Sole.Target"
    && moduleForSourcePath ix "Odd-Name/Inner" == some "Alpha.«Odd-Name».Inner"
    && moduleForSourcePath ix "EPI/Stam/ToBridge" == none
    && moduleForSourcePath ix "Nope/Missing" == none
    && moduleForSourcePath ix "Sole" == none

#guard aSourcePathIsResolvedThroughTheKnownModules

/-- The bytes of the branch above, through the resolver the page hands the
docstring renderer. Ambiguous and unknown are text and not a guess — and the
second lookup `autoLinkInline` makes on the tail asks about `lean`, which
answers nothing either. -/
def anUnresolvedSourcePathStaysACodeSpan : Bool :=
  let ix := alIndex [] ["Pkg.Deep.Sub.Thing", "Dep.Sub.Thing", "Other.X.Amb", "P.X.Amb"]
    "" [("Dep", "https://host/o/dep/blob/abc")]
  let page := pageRenderer (mkPageCtx ix "../" {})
  autoLinkInline "" page "Deep/Sub/Thing.lean"
      == "<a href=\"../Pkg/Deep/Sub/Thing.html\">Deep/Sub/Thing.lean</a>"
    && autoLinkInline "" page "Dep/Sub/Thing.lean"
      == "<a href=\"https://host/o/dep/blob/abc/Dep/Sub/Thing.lean\">Dep/Sub/Thing.lean</a>"
    && autoLinkInline "" page "X/Amb.lean" == "X/Amb.lean"
    && autoLinkInline "" page "Nope/Missing.lean" == "Nope/Missing.lean"

#guard anUnresolvedSourcePathStaysACodeSpan

/-- The empty piece the splitter leaves between two separators must not resolve;
an anchor there would land in the middle of every double space. It is asked of
an index that holds the empty string as a declaration, as a module and in the
`.lidx`'s `@` section — every source a branch could reach it from. -/
def theEmptyStringNeverResolves : Bool :=
  let ix := buildIndex #[] #[{ name := "Pkg.Two", decls := #[{ name := "" }] }, { name := "" }]
    (parseLidx "@\n") (mkExternalLinks #[])
  alResolve ix { name := "Pkg.Two", decls := #[{ name := "" }] } "" == none

#guard theEmptyStringNeverResolves

end Litedoc4Test
