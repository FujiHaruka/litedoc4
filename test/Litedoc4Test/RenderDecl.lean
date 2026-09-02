/- One `<section class="decl">`.

Split by whether a docstring is in it. A declaration with none reaches no
Markdown parser, so head, signature, flags, equations, fields, constructors and
the extra blocks are all `#guard`s; the two invariants whose subject *is* a
rendered docstring run, because `Md.events` is `@[extern]` C the interpreter
cannot call.

`decl_signature`'s split from `signature_with` has no counterpart: it exists in
Rust to avoid building a second `Refs` per declaration, and here the caller
passes the one it has. -/
import Litedoc4.Render.Decl
import Litedoc4Test.Basis
import Litedoc4Test.RenderCode
import Litedoc4Test.RenderFrame

namespace Litedoc4Test
open Litedoc4

/-- A schema-5 module holding exactly these declarations, at `Pkg.M`. -/
def declModule (decls : Array Decl) : Module :=
  { name := "Pkg.M", schemaVersion := 5, decls }

/-- These declarations, and **a page for every module they name** — which is what
a run has for its own package — plus the module being rendered. -/
def declIndex (entries : List (String × String)) (m : Module) : NameIndex :=
  buildIndex #[] (alModules entries (entries.map (·.2)) |>.push m) emptyLidx (mkExternalLinks #[])

/-- A declaration slice of a *dependency*: in `known` and with no page, which is
what `NameIndex.builder().declaration(…)` without `module_name(…)` gives. -/
def depIndex (slice : List (String × String)) (pages : List String) (lidx : String)
    (external : List (String × String)) : NameIndex :=
  buildIndex #[slice.toArray] (alModules [] pages) (parseLidx lidx)
    (mkExternalLinks external.toArray)

def declRoot : String := pageRoot "Pkg.M"

def declOut (ix : NameIndex) (m : Module) (d : Decl) : Except String String :=
  let dr : DeclRenderer := { ix, root := pageRoot m.name, md := pageRenderer (mkPageCtx ix
    (pageRoot m.name) m) }
  ((declHtml "" dr m d "https://x/M.lean").run 0).map (·.1)

/-- The markup, or the empty string when the page was refused — which fails every
assertion below, and is the honest reading: a refused page has no bytes. -/
def declBytes (ix : NameIndex) (m : Module) (d : Decl) : String :=
  (declOut ix m d).toOption.getD ""

/-- The markup of the module's `at`-th declaration, against an index built from
`entries` and that module. -/
def declAt (entries : List (String × String)) (m : Module) (at_ : Nat) : String :=
  declBytes (declIndex entries m) m m.decls[at_]!

def linkOf (ix : NameIndex) (root name : String) : Except String (Option String) :=
  ((declNameToLink ix (Std.HashMap.emptyWithCapacity 0) root name).run 0).map (·.1)

def linkIs (ix : NameIndex) (root name : String) (expected : Option String) : Bool :=
  match linkOf ix root name with
  | .ok got => got == expected
  | .error _ => false

/-- A refusal, and one that names the declaration it could not place: the error
exists only to be read, and one that names nothing spends the debugging round it
was meant to save. -/
def linkRefuses (ix : NameIndex) (root name : String) : Bool :=
  match linkOf ix root name with
  | .ok _ => false
  | .error message => emits message name && emits message "declNameToLink"

def repeatStr (s : String) (n : Nat) : String := String.join (List.replicate n s)

/-- `Module.sorryOf` and `Module.generatedBy` read fields private to
`Litedoc4.Ir`, so a declaration that carries one is built from the bytes. -/
def declWireJson (name kind extra : String) : String :=
  "{\"name\":\"" ++ name ++ "\",\"kind\":\"" ++ kind
    ++ "\",\"line\":1,\"col\":0,\"endLine\":1,\"endCol\":1,\"index\":0" ++ extra ++ "}"

def moduleFromWire (schema : Nat) (decls : List String) : Module :=
  match parseModule ("{\"schemaVersion\":" ++ toString schema
      ++ ",\"module\":\"Pkg.M\",\"imports\":[],\"moduleDocs\":[],\"tactics\":[]"
      ++ ",\"declarations\":[" ++ ",".intercalate decls ++ "]}") with
  | .ok m => m
  | .error _ => {}

/-! ## The head and the signature -/

def headDecl : Decl :=
  { name := "Pkg.M.f", kind := "definition", modifiers := #["abbrev"]
    binders := #["(n : Nat)", "{m : Nat}"], implicits := #[false, true]
    binderCode := #[#[codeConst 5 8 "Nat"], #[]]
    ty := "Nat", typeCode := #[codeConst 0 3 "Nat"]
    line := 1, endLine := 1, endCol := 1 }

/-- `<h2>` because it *is* the heading of the section below it: the sidebar's
table of contents is a list of these, and a page whose declarations are `<div>`s
has no outline for a screen reader to walk. The two `href`s are different kinds
of thing — the page's own anchor and the source range. -/
def aHeadIsKindNameAndSource : Bool :=
  declHeadHtml "" headDecl declRoot "Pkg.M" "https://x/Pkg/M.lean"
    == "<header class=\"decl-head\"><span class=\"kind\">abbrev</span>\
        <h2 class=\"decl-name\"><a class=\"break_within\" href=\".././Pkg/M.html#Pkg.M.f\">\
        <span class=\"name\">Pkg</span>.<span class=\"name\">M</span>.\
        <span class=\"name\">f</span></a></h2>\
        <a class=\"src\" href=\"https://x/Pkg/M.lean#L1-L1\">source</a></header>"

#guard aHeadIsKindNameAndSource

/-- The trailing newline after each binder is layout: a binder is an
`inline-block`, so the whitespace between two of them is what lets a line break
there. `implicits` may be shorter than `binders` and a missing entry is
explicit. -/
def aSignatureIsBindersAndType : Bool :=
  signatureHtml "" (codeIndex [("Nat", "Init.Prelude")]) noRefs declRoot headDecl
    == "<div class=\"sig\">\
        <span class=\"binder\"><span class=\"fn\">\
        (n : <a href=\".././Init/Prelude.html#Nat\">Nat</a>)</span></span>\n\
        <span class=\"binder implicit\"><span class=\"fn\">{m : Nat}</span></span>\n\
        <span class=\"colon\"> :</span>\
        <div class=\"sig-type\"><a href=\".././Init/Prelude.html#Nat\">Nat</a></div></div>"

#guard aSignatureIsBindersAndType

/-- A `class_inductive` has no parents section even when it carries parent
members, so the same members are asked of three kinds. -/
def extendsIsRenderedForStructuresAndClassesOnly : Bool :=
  let parents : Array Member :=
    #[{ label := "parent", name := "P.to<A", text := "A" },
      { label := "parent", name := "P.toB", text := "B" }]
  let sig (kind : String) : String :=
    signatureHtml "" (codeIndex []) noRefs declRoot { name := "P", kind, members := parents }
  ["structure", "class"].all (fun kind => emits (sig kind)
      "<span class=\"extends\">extends</span> \
       <span id=\"P.to&lt;A\">A</span>, <span id=\"P.toB\">B</span><span class=\"colon\"> :</span>")
    && !emits (sig "class_inductive") "class=\"extends\""

#guard extendsIsRenderedForStructuresAndClassesOnly

/-! ## The blocks under the signature -/

/-- 199 code points is 597 bytes and 398 UTF-16 units, so a byte- or unit-based
limit drops the one that is kept. An equation list empty because every equation
was dropped still renders, with the notice and no items; no equations at all
renders nothing, not an empty `<details>`. -/
def theEquationLimitIsInCodePoints : Bool :=
  let eqs (n : Nat) : Decl :=
    { name := "f", kind := "definition", equations := #[repeatStr "𝒜" n], equationCode := #[#[]] }
  let kept := equationsHtml "" (codeIndex []) noRefs "./" (eqs 199)
  emits kept (repeatStr "𝒜" 199) && !emits kept "did not get rendered"
    && equationsHtml "" (codeIndex []) noRefs "./" (eqs 200)
      == "<details class=\"extra\"><summary>Equations</summary><ul class=\"equations\">\
          <li>One or more equations did not get rendered \
          due to their size.</li></ul></details>"
    && equationsHtml "" (codeIndex []) noRefs "./" { name := "f", kind := "definition" } == ""

#guard theEquationLimitIsInCodePoints

/-- Both carry the name in `data-name`, escaped — an attribute rather than an
element `id`, so the name does not have to survive a round trip through an HTML
identifier. The two differ only in which map `app.js` fills them from. -/
def theTwoInstanceStubsDifferOnlyInTheMapThatFillsThem : Bool :=
  fillBlock "" "A<B" "instances-for" "Instances For"
      == "<details class=\"extra\" data-fill=\"instances-for\" data-name=\"A&lt;B\">\
          <summary>Instances For</summary><ul></ul></details>"
    && fillBlock "" "A<B" "instances" "Instances"
      == "<details class=\"extra\" data-fill=\"instances\" data-name=\"A&lt;B\">\
          <summary>Instances</summary><ul></ul></details>"

#guard theTwoInstanceStubsDifferOnlyInTheMapThatFillsThem

/-! ## Placing a name -/

/-- An inherited field of a class the documented package does **not** declare —
as `batteries`' `class LawfulLTCmp … extends Std.OrientedCmp` has — is a name the
IR's own map has never heard of, and the build stopped on it (measured
2026-08-17). The `.lidx` covers the environment rather than the package, so the
fall-through is a *correct* answer; a name in **neither** map is still a refusal
rather than a guessed href. -/
def aFieldInheritedFromOutsideThePackageIsFoundInTheLidx : Bool :=
  let ix := depIndex [("Micro.Preferred.reason", "Micro.Shapes")] []
    "Init.Prelude\n\tInhabited.default\t1227\t1249\n"
    [("Init", "https://host/leanprover/lean4/blob/abc/src")]
  linkIs ix ".././" "Inhabited.default"
      (some "https://host/leanprover/lean4/blob/abc/src/Init/Prelude.lean#L1227-L1249")
    && linkRefuses ix ".././" "Nobody.knows"

#guard aFieldInheritedFromOutsideThePackageIsFoundInTheLidx

/-- **The two failures are different and the return type says so.** All three
answers on one index: a pinned dependency, this package's own module, and
`ok none` for a dependency with no version-pinned URL — which is neither an error
nor a page link. Collapsing the last into the first refuses a page over a missing
link; collapsing it into a link is a dead one. -/
def anInheritedFieldOfADependencysStructureLinksAtItsSource : Bool :=
  let ix := depIndex [("Mathlib.P.y", "Mathlib.Order.Basic"), ("Pkg.M.z", "Pkg.M"),
      ("Dep.P.w", "Dep.Aux")] ["Pkg.M"]
    "Mathlib.Order.Basic\n\tMathlib.P.y\t67\t67\n"
    [("Mathlib", "https://host/o/mathlib4/blob/abc"), ("Dep", "")]
  linkIs ix ".././" "Mathlib.P.y"
      (some "https://host/o/mathlib4/blob/abc/Mathlib/Order/Basic.lean#L67-L67")
    && linkIs ix ".././" "Pkg.M.z" (some ".././Pkg/M.html#Pkg.M.z")
    && linkIs ix ".././" "Dep.P.w" none
    && linkRefuses ix "./" "nowhere"

#guard anInheritedFieldOfADependencysStructureLinksAtItsSource

/-- The population is every declaration the IR carries for the module, including
the ones that get no page entry, and both comparisons are non-strict on the inner
coordinate — a field declared at exactly the structure's own start counts. -/
def containedNamesUsesClosedRanges : Bool :=
  let at_ (name : String) (l c el ec : Nat) : Decl :=
    { name, kind := "definition", line := l, col := c, endLine := el, endCol := ec }
  let parent := at_ "S" 10 2 20 8
  let m := declModule #[parent, at_ "exact" 10 2 20 8, at_ "inside" 11 0 19 99,
    at_ "startsBefore" 10 1 20 8, at_ "endsAfter" 10 2 20 9,
    at_ "linesBefore" 9 99 20 8, at_ "linesAfter" 10 2 21 0]
  (containedNames m parent).toArray.qsort byteLt == #["exact", "inside"]

#guard containedNamesUsesClosedRanges

/-! ## The whole section -/

/-- The renderer says nothing rather than "no `sorry`": a schema-4 file had no
key to omit, so its silence is the extractor's version rather than a fact about
the package. -/
def aFileThatWasNeverAskedAboutSorryGetsNoFlag : Bool :=
  let older := moduleFromWire 4 [declWireJson "Pkg.M.f" "theorem" ",\"sorry\":\"direct\""]
  let newer := moduleFromWire 5 [declWireJson "Pkg.M.f" "theorem" ",\"sorry\":\"direct\""]
  older.decls.size == 1 && newer.decls.size == 1
    && !emits (declAt [] older 0) "flag"
    && emits (declAt [] newer 0) "data-flag=\"sorry-direct\""

#guard aFileThatWasNeverAskedAboutSorryGetsNoFlag

/-- Nothing, not an empty `<div class="doc">` — doc-gen4's test is JavaScript
truthiness, where `""` is falsy. The signature's two closing `</div>`s run
straight into the `Used by` block every declaration ends in. -/
def anEmptyDocstringRendersNothing : Bool :=
  let m := declModule #[{ name := "f", kind := "theorem" }]
  let html := declAt [] m 0
  emits html "</div></div><details class=\"extra\" data-fill=\"used-by\"" && !emits html "<p>"

#guard anEmptyDocstringRendersNothing

/-- Every kind ends in a `Used by` block, so "no extra" means *that one and
nothing else* rather than no `<details>` at all. -/
def eachKindGetsItsOwnExtra : Bool :=
  [("definition", "def", "data-fill=\"instances-for\""),
    ("inductive", "inductive", "data-fill=\"instances-for\""),
    ("class_inductive", "class", "data-fill=\"instances\""),
    ("instance", "instance", ""), ("theorem", "theorem", ""),
    ("constructor", "ctor", "")].all fun (kind, css, extra) =>
      let m := declModule #[{ name := "X", kind }]
      let html := declAt [] m 0
      emits html ("<section class=\"decl\" id=\"X\" data-kind=\"" ++ css ++ "\">")
        && emits html "data-fill=\"used-by\""
        && (if extra.isEmpty then emitCount html "<details" == 1
            else emits html extra && emits html "data-name=\"X\"")

#guard eachKindGetsItsOwnExtra

/-- What is asserted is the *distinction* — a `mk` constructor says nothing, any
other name is printed — and that a missing `ctor` member takes the anonymous
shape. The constructor's name lands on the field list as its `id` either way,
because that is what an inherited field's anchor resolves against. -/
def theConstructorNameDecidesTheStructureShape : Bool :=
  let field : Member := { label := "field", name := "S.x", text := "Nat" }
  let shape (members : Array Member) : String :=
    declAt [] (declModule #[{ name := "S", kind := "structure", members }]) 0
  let anonymous := shape #[field]
  let explicitMk := shape #[field, { label := "ctor", name := "S.mk" }]
  let named := shape #[field, { label := "ctor", name := "S.make" }]
  emits anonymous "<ul class=\"fields\" id=\"S.mk\">\
      <li id=\"S.x\" class=\"field\"><div class=\"field-sig\">\
      <span class=\"field-name\">x</span>\
      <span class=\"colon\"> : </span>Nat</div></li></ul>"
    && !emits anonymous "ctor-note"
    && emits explicitMk "<ul class=\"fields\" id=\"S.mk\">" && !emits explicitMk "ctor-note"
    && emits named "<p class=\"ctor-note\">constructor <code>make</code></p>\
        <ul class=\"fields\" id=\"S.make\">"

#guard theConstructorNameDecidesTheStructureShape

/-- The `id` comes from `containedNames`, so a declaration `S.y` inside `S`'s
range turns it on: an anchor for a field the structure merely inherits would take
over a fragment that belongs to the parent's page. -/
def anInheritedFieldGetsAnIdWhenTheProjectionIsContained : Bool :=
  let s : Decl :=
    { name := "S", kind := "structure", line := 1, endLine := 5, endCol := 0,
      members := #[{ label := "field", name := "P.y", inherited := true }] }
  let proj : Decl := { name := "S.y", kind := "definition", line := 2, endLine := 2 }
  emits (declAt [("P.y", "Pkg.Parent")] (declModule #[s, proj]) 0)
    "<li id=\"S.y\" class=\"field inherited\"><div class=\"field-sig\">"

#guard anInheritedFieldGetsAnIdWhenTheProjectionIsContained

/-! ## The two whose subject is a rendered docstring -/

/-- The order is the assertion: the kind and the name lead, the attributes sit
between the head and the signature, and the docstring follows the signature — one
that drifted above the type would read as belonging to the declaration before it.
An `Invariant` because the docstring is Markdown. -/
def aDeclarationIsHeadAttributesSignatureDocAndExtra : Invariant where
  name := "a declaration is head, attributes, signature, docstring and extra, in that order"
  check := do
    let d : Decl :=
      { name := "Pkg.M.f", kind := "definition", line := 7, endLine := 9,
        attrs := #[("simp", ""), ("reducible", "")], doc := "hello" }
    let html := declAt [] (declModule #[d]) 0
    return first [
      if emits html "<section class=\"decl\" id=\"Pkg.M.f\" data-kind=\"def\">\
          <header class=\"decl-head\"><span class=\"kind\">def</span>" then none
        else some s!"the head does not open the section: {html}",
      if emits html "<a class=\"src\" href=\"https://x/M.lean#L7-L9\">source</a></header>\
          <div class=\"attrs\">@[simp, reducible]</div><div class=\"sig\">" then none
        else some s!"the attributes are not between the head and the signature: {html}",
      if emits html "</div></div><div class=\"doc\"><p>hello</p></div>\
          <details class=\"extra\" data-fill=\"instances-for\" data-name=\"Pkg.M.f\">" then none
        else some s!"the docstring does not follow the signature: {html}"]

/-- Three members and three answers. The direct one keeps its docstring; the
inherited one loses its `id` **and its docstring** and keeps only a link to where
it is declared; and a member with no `isDirect` key at all is direct, because the
test doc-gen4 makes is `isDirect === false` rather than `!isDirect`. No
comparison against the measurement package can catch the other reading: all 156
of its field members carry the key (measured). -/
def anInheritedFieldIsALinkAndAnAbsentKeyIsNotInherited : Invariant where
  name := "an inherited field is a link with no id and no docstring, and an absent key is direct"
  check := do
    let s : Decl :=
      { name := "S", kind := "structure", line := 1, endLine := 5, endCol := 0,
        members := #[
          { label := "field", name := "S.x", text := "Nat", doc := "a field" },
          { label := "field", name := "P.y", text := "Nat", doc := "ignored", inherited := true },
          { label := "field", name := "S.z", text := "Nat" }] }
    let html := declAt [("P.y", "Pkg.Parent")] (declModule #[s]) 0
    return first [
      if emits html "<li id=\"S.x\" class=\"field\"><div class=\"field-sig\">\
          <span class=\"field-name\">x</span>\
          <span class=\"colon\"> : </span>Nat</div>\
          <div class=\"field-doc\"><p>a field</p></div></li>" then none
        else some s!"the direct field lost its docstring: {html}",
      if emits html "<li class=\"field inherited\"><div class=\"field-sig\">\
          <a class=\"field-name\" href=\".././Pkg/Parent.html#P.y\">y</a>\
          <span class=\"colon\"> : </span>Nat</div></li>" then none
        else some s!"the inherited field kept an id or a docstring: {html}",
      if emits html "<li id=\"S.z\" class=\"field\">" then none
        else some s!"a member without `isDirect` was read as inherited: {html}"]

end Litedoc4Test
