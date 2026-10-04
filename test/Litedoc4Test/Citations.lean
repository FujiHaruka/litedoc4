/- Which citation anchors a module page carries, and that the page and
`references.html` are answered by the same list.

What does not parse Markdown is a `#guard`; the rest reads a docstring through
md4c and runs. -/
import Litedoc4.Global.Artifacts
import Litedoc4.Render.Page
import Litedoc4Test.Bib
import Litedoc4Test.GlobalEntry
import Litedoc4Test.RenderPage

namespace Litedoc4Test
open Litedoc4

def citingField : Member :=
  { label := "field", name := "Pkg.Cite.S.x", text := "T", doc := "See [the book][Roe13]." }

/-- A module docstring, a declaration, a structure with a field, and the field's
projection, which the structure suppresses. Each cites one of `twoKeys`. -/
def citingPage : Module :=
  { name := "Pkg.Cite", schemaVersion := 5,
    moduleDocs := #[{ line := 1, col := 0, text := "This module cites [Doe12]." }],
    decls := #[
      { name := "Pkg.Cite.f", kind := "theorem", ty := "T", doc := "By [Roe13].",
        line := 3, col := 0, endLine := 3, endCol := 1, index := 0 },
      { name := "Pkg.Cite.S", kind := "structure", ty := "T", doc := "After [Doe12].",
        line := 5, col := 0, endLine := 6, endCol := 1, index := 1,
        members := #[citingField] },
      { name := "Pkg.Cite.S.x", kind := "theorem", ty := "T", doc := "See [Doe12].",
        line := 6, col := 0, endLine := 6, endCol := 1, index := 2 }] }

def cited (citekey funName : String) : Citation := { citekey, funName }

/-- The member docstrings `declHtml` writes: a structure's direct fields, an
inductive's constructors, and never an inherited field's, whose own page holds
it. -/
def aDeclarationsDocstringsAreItsOwnThenItsMembers : Bool :=
  let field (name : String) (inherited : Bool) : Member :=
    { label := "field", name, doc := name, inherited }
  let s : Decl := { name := "S", kind := "structure", doc := "S",
                    members := #[field "S.a" false, field "S.b" true, { label := "ctor", name := "S.mk" }] }
  let i : Decl := { name := "I", kind := "inductive", doc := "I",
                    members := #[{ label := "ctor", name := "I.c", doc := "c" }] }
  declDocs s == #[("S", "S"), ("S.a", "S.a")]
    && declDocs i == #[("I", "I"), ("I.c", "c")]
    && declDocs { s with kind := "theorem" } == #[("S", "S")]

#guard aDeclarationsDocstringsAreItsOwnThenItsMembers

/-- With no bibliography nothing is parsed, which is also what lets this be a
`#guard`. -/
def noBibliographyIsNoCitations : Bool :=
  (pageCitations {} citingPage {}).isEmpty

#guard noBibliographyIsNoCitations

/-- The part of the suppressed set another module can contribute: members that
are not this module's declarations. -/
def foreignMembersAreTheMembersDeclaredElsewhere : Bool :=
  foreignMembers citingPage == #[] && foreignMembers pkgOnePage == #["Pkg.Two.b"]

#guard foreignMembersAreTheMembersDeclaredElsewhere

def citingIndex : NameIndex := declIndex [] citingPage

def citingHtml (citations : Array Citation) : Except String String :=
  let page := pageHtml citingIndex twoKeys citations citingPage (suppressedOf #[citingPage])
    "https://h/o/r/blob/dead" "Pkg"
  (page.run {}).map (·.1)

def renderedIds (html : String) : Array String :=
  ((html.splitOn "id=\"_backref_").drop 1).toArray.map fun rest => (rest.splitOn "\"").headD ""

/-- The anchors are numbered in the order the page shows them — the module
docstring, the declaration, the structure, then its field — and the projection
the structure suppresses is not among them. `references.html`, built from the
facts the whole-package step keeps rather than from the page, links to the same
four with the module and, outside the module docstring, the declaration. -/
def citationAnchorsAreNumberedInPageOrderAndListedOnReferences : Invariant where
  name := "citation anchors are numbered in page order and references.html lists the same ones"
  check := do
    let want := #[cited "Doe12" "", cited "Roe13" "Pkg.Cite.f", cited "Doe12" "Pkg.Cite.S",
      cited "Roe13" "Pkg.Cite.S.x"]
    let got := (pageCitations twoKeys citingPage (suppressedOf #[citingPage])).map (·.citation)
    let references := (derive #[factsOf citingPage "0" twoKeys] #[] none none twoKeys.items
      "4.31.0").referencesHtml
    let backref (n index : Nat) (location : String) : String :=
      s!" <a href=\"./Pkg/Cite.html#_backref_{index}\" title=\"File: Pkg.Cite{location}\">[{n}]</a>"
    match citingHtml got with
    | .error message => return some s!"the page was refused: {message}"
    | .ok html => return first [
        eq got want,
        eq (renderedIds html) #["0", "1", "2", "3"],
        if has html "title=\"Doe.\" id=\"_backref_2\">[DJ12]</a>" then none
          else some s!"the structure's citation is not anchor 2: {html}",
        if has references ("<small>" ++ backref 1 0 "" ++ backref 2 2 "\nLocation: Pkg.Cite.S"
            ++ "</small>") then none
          else some s!"Doe12's back-references are not the page's anchors 0 and 2: {references}",
        if has references ("<small>" ++ backref 1 1 "\nLocation: Pkg.Cite.f"
            ++ backref 2 3 "\nLocation: Pkg.Cite.S.x" ++ "</small>") then none
          else some s!"Roe13's back-references are not the page's anchors 1 and 3: {references}"]

/-- Handed a list that is not the page's, the renderer refuses the page rather
than write anchors `references.html` does not point at: one missing, one extra,
and two swapped — the last with the same keys in the same order, so only the
declaration tells it apart. -/
def aPageWhoseAnchorsAreNotItsListIsRefused : Invariant where
  name := "a page whose citation anchors are not the list it was handed is refused"
  check := do
    let right := (pageCitations twoKeys citingPage (suppressedOf #[citingPage])).map (·.citation)
    let swapped := #[right[0]!, right[3]!, right[2]!, right[1]!]
    let refused (cs : Array Citation) : Bool := match citingHtml cs with
      | .error _ => true
      | .ok _ => false
    return first [
      eq (refused right) false,
      eq (refused right.pop) true,
      eq (refused (right.push (cited "Doe12" "Pkg.Cite.f"))) true,
      eq (refused (right.set! 1 (cited "Doe12" "Pkg.Cite.f"))) true,
      eq (refused swapped) true]

/-- A declaration filed under one module and suppressed by a structure in
another: its page does not show it, so neither the page nor `references.html`
may count its citation — and the module that declares it cannot know that from
its own facts. -/
def aCitationAnotherModuleSuppressesIsNeitherAnchoredNorListed : Invariant where
  name := "a citation in a declaration another module suppresses is neither anchored nor listed"
  check := do
    let two : Module := { pkgTwoPage with
      decls := pkgTwoPage.decls.modify 0 ({ · with doc := "Cites [Doe12]." }) }
    let site := suppressedOf #[two, pkgOnePage]
    let alone := backrefsOf #[factsOf two "0" twoKeys]
    let together := backrefsOf #[factsOf two "0" twoKeys, factsOf pkgOnePage "0" twoKeys]
    return first [
      eq (pageCitations twoKeys two site).size 0,
      eq alone.size 1,
      eq together.size 0]

/-- doc-gen4 takes a link written straight to an entry as a citation too, and
such a docstring names no key in brackets for the scan to find. -/
def aLinkWrittenStraightToAnEntryIsACitation : Invariant where
  name := "a link written straight to references.html#ref_<key> is a citation"
  check := do
    let page : Module := { citingPage with
      moduleDocs := #[], decls := #[{ citingPage.decls[0]! with
        doc := "See [the book](references.html#ref_Roe13)." }] }
    let citations := (pageCitations twoKeys page {}).map (·.citation)
    let html := pageHtml (declIndex [] page) twoKeys citations page {}
      "https://h/o/r/blob/dead" "Pkg"
    match (html.run {}).map (·.1) with
    | .error message => return some s!"the page was refused: {message}"
    | .ok html => return first [
        eq citations #[cited "Roe13" "Pkg.Cite.f"],
        eq (renderedIds html) #["0"]]

end Litedoc4Test
