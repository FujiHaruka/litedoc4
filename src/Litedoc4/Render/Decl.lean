/- `crates/litedoc4-render/src/decl.rs`: one `<section class="decl">`. -/
import Litedoc4.Render.Code

namespace Litedoc4

/-- What a page builder returns: the markup, or the message the run stops with.

Named rather than spelled `Except String` at each signature because a render's
other out-of-band results — how many math spans fell back to their LaTeX source
is the one the summary reports — run along this same chain from the innermost
builder up to `renderSite`, and a layer added here reaches all of them at once.
What would falsify the alias: an out-of-band result that travels only part of the
chain, which would want its own type rather than this one widened. -/
abbrev RenderM := Except String

/-- Per page rather than per run: the root, the source URL and the docstring
renderer (whose resolver scans *this* module's declarations) all change from
page to page. -/
structure DeclRenderer where
  ix : NameIndex
  root : String
  md : Renderer

/-- `declNameToLink`: the declaration's own references first, then the IR's map,
then the dependency closure's `.lidx`.

**The two failures are different and the return type says so.** `.error` is
doc-gen4's `name2ModIdx[name]!` panic: **no module at all** knows the name, so
the IR this run was handed disagrees with itself and the page is not written.
`.ok none` is a module that *is* known and has no page here — a name to render
and nowhere to point it. Collapsing the second into the first refuses a page over
a missing link; collapsing it into a link is a dead one. What would falsify the
split: an index in which every known module also has a page. -/
def declNameToLink (ix : NameIndex) (refs : Std.HashMap String String)
    (root name : String) : RenderM (Option String) :=
  match (refs.get? name).orElse fun _ => moduleOf ix name with
  | some module => .ok (linkTo ix root module (some name))
  | none => .error s!"declNameToLink: no defining module for {name} (doc-gen4 would panic here)"

def lastComponent (name : String) : String := Id.run do
  let n := name.utf8ByteSize
  let mut dot := n
  let mut i := 0
  while i < n do
    if byteAt name i == 46 then dot := i
    i := i + 1
  return if dot == n then name else byteSub name (dot + 1) n

/-- The trailing newline is layout: a binder is an `inline-block`, so the
whitespace between two of them is what lets a line break there. -/
@[inline] def pushArg (out : String) (body : String) (implicit : Bool) : String :=
  out ++ (if implicit then "<span class=\"binder implicit\">" else "<span class=\"binder\">")
      ++ "<span class=\"fn\">" ++ body ++ "</span></span>\n"

def pushArgs (out : String) (ix : NameIndex) (refs : Std.HashMap String String) (root : String)
    (binders : Array String) (binderCode : Array (Array Span)) (implicits : Array Bool) :
    String := Id.run do
  let mut acc := out
  for i in [0:binders.size] do
    let spans := if i < binderCode.size then binderCode[i]! else #[]
    let (body, _) := fragment ix refs root binders[i]! spans
    acc := pushArg acc body (if i < implicits.size then implicits[i]! else false)
  return acc

def signatureHtml (out : String) (ix : NameIndex) (refs : Std.HashMap String String)
    (root : String) (d : Decl) : String := Id.run do
  let mut acc := pushArgs (out ++ "<div class=\"sig\">") ix refs root
    d.binders d.binderCode d.implicits
  if d.kind == "structure" || d.kind == "class" then
    let parents := d.members.filter (·.label == "parent")
    if !parents.isEmpty then
      acc := acc ++ "<span class=\"extends\">extends</span> "
      for i in [0:parents.size] do
        if i > 0 then acc := acc ++ ", "
        let p := parents[i]!
        acc := escapeInto (acc ++ "<span id=\"") p.name ++ "\">"
        let (body, _) := fragment ix refs root p.text p.code
        acc := acc ++ body ++ "</span>"
  acc := acc ++ "<span class=\"colon\"> :</span><div class=\"sig-type\">"
  let (ty, _) := fragment ix refs root d.ty d.typeCode
  return acc ++ ty ++ "</div></div>"

def declHeadHtml (out : String) (d : Decl) (root module sourceUrl : String) : String := Id.run do
  let mut acc := escapeInto (out ++ "<header class=\"decl-head\"><span class=\"kind\">")
    (kindDescription d.kind d.modifiers)
  acc := acc ++ "</span><h2 class=\"decl-name\"><a class=\"break_within\" href=\""
  acc := escapeInto acc (moduleLink root module ++ "#" ++ d.name) ++ "\">"
  acc := breakWithin acc d.name
  acc := acc ++ "</a></h2><a class=\"src\" href=\""
  acc := escapeInto acc s!"{sourceUrl}#L{d.line}-L{d.endLine}"
  return acc ++ "\">source</a></header>"

/-- The two facts a signature cannot print: that the declaration is a hole, and
that an attribute realized it rather than an author writing it.

One guard for both, and it is the module's schema version rather than the key's
absence: below 5 neither key could exist, so "the extractor said nothing" is not
"there is no `sorry`" and not "a human wrote this". -/
def factsSchemaVersion : Nat := 5

@[inline] def pushFlag (out : String) (kind body : String) : String :=
  out ++ "<span class=\"flag\" data-flag=\"" ++ kind ++ "\">" ++ body ++ "</span>"

def flagsHtml (c : DeclRenderer) (m : Module) (d : Decl)
    (refs : Std.HashMap String String) : String := Id.run do
  if m.schemaVersion < factsSchemaVersion then return ""
  let mut pills := ""
  if d.sorryTag == "direct" then
    pills := pushFlag pills "sorry-direct" "uses <code>sorry</code>"
  else if d.sorryTag == "transitive" then
    pills := pushFlag pills "sorry-transitive" "depends on <code>sorry</code>"
  match d.generated with
  | none => pure ()
  | some (origin, source) =>
    let body := escapeInto "realized by <code>@[" origin ++ "]</code> from "
    -- An origin that reaches no page goes in as text rather than being dropped:
    -- the name is the fact and the link is a convenience, unlike `declNameToLink`
    -- where an unplaceable name means the IR disagrees with itself.
    let body := match constLink c.ix refs c.root source with
      | some href =>
        escapeInto (escapeInto (body ++ "<a href=\"") href ++ "\"><code>") source ++ "</code></a>"
      | none => escapeInto (body ++ "<code>") source ++ "</code>"
    pills := pushFlag pills "generated" body
  if pills.isEmpty then return ""
  return "<div class=\"flags\">" ++ pills ++ "</div>"

def fillBlock (out : String) (name fill summary : String) : String :=
  escapeInto (escapeInto (out ++ "<details class=\"extra\" data-fill=\"") fill
    ++ "\" data-name=\"") name ++ "\"><summary>" ++ summary ++ "</summary><ul></ul></details>"

/-- An equation whose printed text reaches 200 **code points** is replaced by a
notice; bytes and UTF-16 units both give a different answer on this package. -/
def equationsHtml (out : String) (ix : NameIndex) (refs : Std.HashMap String String)
    (root : String) (d : Decl) : String := Id.run do
  let mut keep : Array Nat := #[]
  let mut omitted := false
  for i in [0:d.equations.size] do
    if d.equations[i]!.length < 200 then keep := keep.push i else omitted := true
  if keep.isEmpty && !omitted then return out
  let mut acc := out ++
    "<details class=\"extra\"><summary>Equations</summary><ul class=\"equations\">"
  if omitted then
    acc := acc ++ "<li>One or more equations did not get rendered due to their size.</li>"
  for i in keep do
    let spans := if i < d.equationCode.size then d.equationCode[i]! else #[]
    let (body, _) := fragment ix refs root d.equations[i]! spans
    acc := acc ++ "<li>" ++ body ++ "</li>"
  return acc ++ "</ul></details>"

/-- `containedNames`: which declarations of the same module have their range
inside `parent`'s. Both comparisons are non-strict on the inner coordinate. -/
def containedNames (m : Module) (parent : Decl) : Std.HashSet String := Id.run do
  let mut out : Std.HashSet String := Std.HashSet.emptyWithCapacity 16
  for d in m.decls do
    if d.name == parent.name then continue
    let startsInside := d.line > parent.line || (d.line == parent.line && d.col >= parent.col)
    let endsInside := d.endLine < parent.endLine
      || (d.endLine == parent.endLine && d.endCol <= parent.endCol)
    if startsInside && endsInside then out := out.insert d.name
  return out

def memberBody (out : String) (c : DeclRenderer) (short args body : String) (doc : String) :
    String := Id.run do
  let mut acc := escapeInto (out ++ "<div class=\"field-sig\"><span class=\"field-name\">") short
  acc := acc ++ "</span>" ++ args ++ "<span class=\"colon\"> : </span>" ++ body ++ "</div>"
  if !doc.isEmpty then
    acc := docstring (acc ++ "<div class=\"field-doc\">") c.md doc ++ "</div>"
  return acc ++ "</li>"

def structureHtml (out : String) (c : DeclRenderer) (m : Module) (d : Decl)
    (refs : Std.HashMap String String) : RenderM String := do
  let mut lis := ""
  let mut contained : Option (Std.HashSet String) := none
  for f in d.members do
    if f.label != "field" then continue
    let short := lastComponent f.name
    let args := pushArgs "" c.ix refs c.root f.binders f.binderCode f.implicits
    let (body, _) := fragment c.ix refs c.root f.text f.code
    if f.inherited then
      let link ← declNameToLink c.ix refs c.root f.name
      let cs := match contained with
        | some x => x
        | none => containedNames m d
      contained := some cs
      let proj := d.name ++ "." ++ short
      if cs.contains proj then
        lis := escapeInto (lis ++ "<li id=\"") proj ++ "\" class=\"field inherited\">"
      else
        lis := lis ++ "<li class=\"field inherited\">"
      match link with
      | some l =>
        lis := escapeInto (escapeInto (lis ++ "<div class=\"field-sig\"><a class=\"field-name\" href=\"")
          l ++ "\">") short ++ "</a>"
      | none =>
        lis := escapeInto (lis ++ "<div class=\"field-sig\"><span class=\"field-name\">") short
          ++ "</span>"
      lis := lis ++ args ++ "<span class=\"colon\"> : </span>" ++ body ++ "</div></li>"
    else
      lis := escapeInto (lis ++ "<li id=\"") f.name ++ "\" class=\"field\">"
      lis := memberBody lis c short args body f.doc
  let ctorName := match d.members.find? (·.label == "ctor") with
    | some ctor => ctor.name
    | none => d.name ++ ".mk"
  let short := lastComponent ctorName
  let mut acc := out
  if short != "mk" then
    acc := escapeInto (acc ++ "<p class=\"ctor-note\">constructor <code>") short ++ "</code></p>"
  acc := escapeInto (acc ++ "<ul class=\"fields\" id=\"") ctorName ++ "\">"
  return acc ++ lis ++ "</ul>"

def constructorsHtml (out : String) (c : DeclRenderer) (d : Decl)
    (refs : Std.HashMap String String) : String := Id.run do
  let mut lis := ""
  for ctor in d.members do
    if ctor.label != "ctor" then continue
    let short := lastComponent ctor.name
    let args := pushArgs "" c.ix refs c.root ctor.binders ctor.binderCode ctor.implicits
    let (body, _) := fragment c.ix refs c.root ctor.text ctor.code
    lis := escapeInto (lis ++ "<li id=\"") ctor.name ++ "\" class=\"ctor\">"
    lis := memberBody lis c short args body ctor.doc
  if lis.isEmpty then return out
  return out ++ "<ul class=\"ctors\">" ++ lis ++ "</ul>"

def declHtml (out : String) (c : DeclRenderer) (m : Module) (d : Decl) (sourceUrl : String) :
    RenderM String := do
  let refs := declRefs d
  let mut acc := escapeInto (out ++ "<section class=\"decl\" id=\"") d.name ++ "\" data-kind=\""
  acc := escapeInto acc (cssKind d.kind) ++ "\">"
  acc := declHeadHtml acc d c.root m.name sourceUrl
  acc := acc ++ flagsHtml c m d refs
  if !d.attrs.isEmpty then
    let texts := d.attrs.map fun (n, v) => if v.isEmpty then n else n ++ " " ++ v
    let mut joined := "@["
    for i in [0:texts.size] do
      if i > 0 then joined := joined ++ ", "
      joined := joined ++ texts[i]!
    acc := escapeInto (acc ++ "<div class=\"attrs\">") (joined ++ "]") ++ "</div>"
  acc := signatureHtml acc c.ix refs c.root d
  if !d.doc.isEmpty then
    acc := docstring (acc ++ "<div class=\"doc\">") c.md d.doc ++ "</div>"
  let mut extra := ""
  if d.kind == "structure" || d.kind == "class" then
    acc ← structureHtml acc c m d refs
    extra := fillBlock "" d.name
      (if d.kind == "class" then "instances" else "instances-for")
      (if d.kind == "class" then "Instances" else "Instances For")
  else if d.kind == "definition" then
    extra := fillBlock (equationsHtml "" c.ix refs c.root d) d.name "instances-for" "Instances For"
  else if d.kind == "instance" then
    extra := equationsHtml "" c.ix refs c.root d
  else if d.kind == "inductive" then
    acc := constructorsHtml acc c d refs
    extra := fillBlock "" d.name "instances-for" "Instances For"
  else if d.kind == "class_inductive" then
    acc := constructorsHtml acc c d refs
    extra := fillBlock "" d.name "instances" "Instances"
  extra := fillBlock extra d.name "used-by" "Used by"
  return acc ++ extra ++ "</section>"

end Litedoc4
