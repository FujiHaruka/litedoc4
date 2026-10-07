/- Which citation anchors a module page carries, and that the page and the
references are answered by the same list.

What does not parse Markdown is a `#guard`; the rest reads a docstring through
md4c and runs. -/
import Litedoc4.Global.Artifacts
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

/-- The member docstrings a declaration's citations are read from: a
structure's direct fields, an inductive's constructors, and never an inherited
field's, whose own page holds it. -/
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

/-- The anchors are numbered in the order the page shows them — the module
docstring, the declaration, the structure, then its field — and the projection
the structure suppresses is not among them. The references page's back-links,
built from the facts the whole-package step keeps rather than from the page, are
the same four in the same order. -/
def citationAnchorsAreNumberedInPageOrderAndListedOnReferences : Invariant where
  name := "citation anchors are numbered in page order and the references list the same ones"
  check := do
    let want := #[cited "Doe12" "", cited "Roe13" "Pkg.Cite.f", cited "Doe12" "Pkg.Cite.S",
      cited "Roe13" "Pkg.Cite.S.x"]
    let got := (pageCitations twoKeys citingPage (suppressedOf #[citingPage])).map (·.citation)
    let backrefs := backrefsOf #[factsOf citingPage "0" twoKeys]
    return first [
      eq got want,
      eq (backrefs.map (·.index)) #[0, 1, 2, 3],
      eq (backrefs.map (·.citation)) want]

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
    return eq citations #[cited "Roe13" "Pkg.Cite.f"]

end Litedoc4Test
