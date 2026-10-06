/- A declaration's content: what every version declaring the same thing shares,
in canonical bytes, and the address those bytes are found by. -/
import Litedoc4.Ir
import Litedoc4.JsonWrite
import Litedoc4.Render.Decl
import Litedoc4.Render.Whitespace
import Litedoc4.Sha256

namespace Litedoc4
namespace Data

inductive Target where
  | sort
  | name (full : String)
  deriving BEq, Repr, Inhabited

structure Ref where
  start : Nat
  stop : Nat
  target : Target
  deriving BEq, Repr, Inhabited

/-- Nested references are kept rather than flattened: which of two nested ones
links depends on which names resolve, and that is per version. -/
structure Text where
  text : String
  refs : Array Ref
  deriving BEq, Repr, Inhabited

def textOf (text : String) (spans : Array Span) : Text :=
  { text := (mkFrag text spans).text
    refs := spans.filterMap fun s =>
      if s.kind == 0 then none
      else if s.kind == 2 then some { start := s.start, stop := s.stop, target := .sort }
      else if s.name.isEmpty then none
      else some { start := s.start, stop := s.stop, target := .name s.name } }

/-- A docstring as content: `Hrefs.deferred`'s HTML, rendered with no
bibliography, and the strings that HTML leaves the browser to look up. -/
structure Doc where
  html : String
  words : Array String
  deriving BEq, Repr, Inhabited

/-- An empty docstring is not rendered, so a declaration without one never
reaches md4c. -/
def docOf (text : String) : Doc :=
  if text.isEmpty then { html := "", words := #[] }
  else
    let (html, s) := (docstring "" { hrefs := .deferred, bib := {} } text).run {}
    { html, words := s.words }

structure Binder where
  implicit : Bool
  text : Text
  deriving BEq, Repr, Inhabited

def bindersOf (texts : Array String) (codes : Array (Array Span)) (implicits : Array Bool) :
    Array Binder :=
  (List.range texts.size).toArray.map fun i =>
    { implicit := implicits.getD i false, text := textOf texts[i]! (codes.getD i #[]) }

structure Field where
  name : String
  binders : Array Binder
  type : Text
  doc : Doc
  inherited : Bool
  anchored : Bool
  deriving BEq, Repr, Inhabited

structure Ctor where
  name : String
  binders : Array Binder
  type : Text
  doc : Doc
  deriving BEq, Repr, Inhabited

inductive Sorry where
  | direct
  | transitive
  deriving BEq, Repr, Inhabited

structure Decl where
  name : String
  kind : String
  modifiers : Array String
  attrs : Array String
  «sorry» : Option Sorry
  generated : Option (String × String)
  binders : Array Binder
  parents : Array (String × Text)
  type : Text
  doc : Doc
  equations : Array Text
  equationsOmitted : Bool
  fields : Array Field
  ctor : Option String
  ctors : Array Ctor
  deriving BEq, Repr, Inhabited

def isStructureKind (kind : String) : Bool := kind == "structure" || kind == "class"

def declOf (m : Module) (d : Litedoc4.Decl) : Decl := Id.run do
  let structural := isStructureKind d.kind
  let shown := d.kind == "definition" || d.kind == "instance"
  let mut equations : Array Text := #[]
  let mut equationsOmitted := false
  if shown then
    for i in [0:d.equations.size] do
      if d.equations[i]!.length < equationLimit then
        equations := equations.push (textOf d.equations[i]! (d.equationCode.getD i #[]))
      else equationsOmitted := true
  let contained := if structural && d.members.any (·.inherited) then containedNames m d else {}
  let fields := if !structural then #[] else
    (d.members.filter (·.label == "field")).map fun f =>
      { name := f.name, binders := bindersOf f.binders f.binderCode f.implicits
        type := textOf f.text f.code, doc := docOf (if f.inherited then "" else f.doc)
        inherited := f.inherited
        anchored := f.inherited && contained.contains (d.name ++ "." ++ lastComponent f.name) }
  let ctors := if d.kind == "inductive" || d.kind == "class_inductive" then
      (d.members.filter (·.label == "ctor")).map fun c =>
        { name := c.name, binders := bindersOf c.binders c.binderCode c.implicits
          type := textOf c.text c.code, doc := docOf c.doc : Ctor }
    else #[]
  return {
    name := d.name, kind := d.kind, modifiers := d.modifiers, attrs := d.attrs.map attrText
    «sorry» := match m.sorryOf d with
      | .direct => some .direct
      | .transitive => some .transitive
      | .unknown | .clean => none
    generated := match m.generatedBy d with
      | .realizedBy origin source => some (origin, source)
      | .unknown | .unclaimed => none
    binders := bindersOf d.binders d.binderCode d.implicits
    parents := if !structural then #[] else
      (d.members.filter (·.label == "parent")).map fun p => (p.name, textOf p.text p.code)
    type := textOf d.ty d.typeCode
    doc := docOf d.doc, equations, equationsOmitted, fields
    ctor := if !structural then none else
      some ((d.members.find? (·.label == "ctor")).map (·.name) |>.getD (d.name ++ ".mk"))
    ctors }

/-! ## The names a declaration links to -/

def Text.names (t : Text) : Array String :=
  t.refs.filterMap fun r => match r.target with
    | .name full => some full
    | .sort => none

def bindersNames (bs : Array Binder) : Array String := bs.flatMap (·.text.names)

def Decl.spanNames (d : Decl) : Array String :=
  bindersNames d.binders ++ d.parents.flatMap (·.2.names) ++ d.type.names
    ++ d.equations.flatMap (·.names) ++ (d.generated.map (#[·.2])).getD #[]
    ++ d.fields.flatMap (fun f => bindersNames f.binders ++ f.type.names)
    ++ d.ctors.flatMap (fun c => bindersNames c.binders ++ c.type.names)

/-- Apart from `spanNames` because they resolve by `declNameToLink`'s rule. -/
def Decl.memberNames (d : Decl) : Array String :=
  (d.fields.filter (·.inherited)).map (·.name)

def Decl.docWords (d : Decl) : Array String :=
  d.doc.words ++ d.fields.flatMap (·.doc.words) ++ d.ctors.flatMap (·.doc.words)

/-! ## The bytes -/

def pushStrings (out : String) (xs : Array String) : String := Id.run do
  let mut o := out.push '['
  for i in [0:xs.size] do
    if i > 0 then o := o.push ','
    o := jsonStr o xs[i]!
  return o.push ']'

def pushText (out : String) (t : Text) : String := Id.run do
  if t.refs.isEmpty then return jsonStr out t.text
  let mut o := jsonStr (out.push '[') t.text ++ ",["
  for i in [0:t.refs.size] do
    let r := t.refs[i]!
    if i > 0 then o := o.push ','
    o := o ++ s!"[{r.start},{r.stop}"
    if let .name full := r.target then o := jsonStr (o.push ',') full
    o := o.push ']'
  return o ++ "]]"

def pushBinders (out : String) (bs : Array Binder) : String := Id.run do
  let mut o := out.push '['
  for i in [0:bs.size] do
    if i > 0 then o := o.push ','
    o := pushText (o ++ (if bs[i]!.implicit then "[1," else "[0,")) bs[i]!.text |>.push ']'
  return o.push ']'

def pushDoc (out : String) (doc : Doc) : String :=
  if doc.html.isEmpty then out else jsonStr (out ++ ",\"doc\":") doc.html

def pushField (out : String) (f : Field) : String := Id.run do
  let mut o := jsonStr (out ++ "{\"n\":") f.name
  if !f.binders.isEmpty then o := pushBinders (o ++ ",\"b\":") f.binders
  o := pushDoc (pushText (o ++ ",\"t\":") f.type) f.doc
  if f.inherited then o := o ++ ",\"inh\":1"
  if f.anchored then o := o ++ ",\"id\":1"
  return o.push '}'

def pushCtor (out : String) (c : Ctor) : String := Id.run do
  let mut o := jsonStr (out ++ "{\"n\":") c.name
  if !c.binders.isEmpty then o := pushBinders (o ++ ",\"b\":") c.binders
  return (pushDoc (pushText (o ++ ",\"t\":") c.type) c.doc).push '}'

def pushEach (out : String) (xs : Array α) (push : String → α → String) : String := Id.run do
  let mut o := out.push '['
  let mut first := true
  for x in xs do
    if !first then o := o.push ','
    first := false
    o := push o x
  return o.push ']'

def Decl.json (d : Decl) : String := Id.run do
  let mut o := jsonStr (jsonStr "{\"n\":" d.name ++ ",\"k\":") d.kind
  if !d.modifiers.isEmpty then o := pushStrings (o ++ ",\"mods\":") d.modifiers
  if !d.attrs.isEmpty then o := pushStrings (o ++ ",\"attrs\":") d.attrs
  match d.«sorry» with
  | some .direct => o := o ++ ",\"sorry\":\"direct\""
  | some .transitive => o := o ++ ",\"sorry\":\"transitive\""
  | none => pure ()
  if let some (origin, source) := d.generated then
    o := jsonStr (jsonStr (o ++ ",\"gen\":[") origin ++ ",") source |>.push ']'
  if !d.binders.isEmpty then o := pushBinders (o ++ ",\"b\":") d.binders
  if !d.parents.isEmpty then
    o := pushEach (o ++ ",\"p\":") d.parents fun out (name, t) =>
      pushText (jsonStr (out.push '[') name |>.push ',') t |>.push ']'
  o := pushDoc (pushText (o ++ ",\"t\":") d.type) d.doc
  if !d.equations.isEmpty then o := pushEach (o ++ ",\"eq\":") d.equations pushText
  if d.equationsOmitted then o := o ++ ",\"eqOmitted\":1"
  if let some ctor := d.ctor then o := jsonStr (o ++ ",\"ctor\":") ctor
  if !d.fields.isEmpty then o := pushEach (o ++ ",\"f\":") d.fields pushField
  if !d.ctors.isEmpty then o := pushEach (o ++ ",\"c\":") d.ctors pushCtor
  return o.push '}'

/-! ## Content and its address -/

structure Content where
  private mk ::
  bytes : ByteArray

def Decl.content (d : Decl) : Content := ⟨d.json.toUTF8⟩

def declContent (m : Module) (d : Litedoc4.Decl) : Content := (declOf m d).content

def moduleDocContent (doc : Doc) : Content := ⟨(jsonStr "{\"moddoc\":" doc.html |>.push '}').toUTF8⟩

/-- Not all 64 digits: a 64-bit address collides at 51 Mathlib versions with
probability ≈ 2e-7, a collision refuses the build (`contentTable`), and every
page file pays the digits once per content file it names. -/
def addressHexDigits : Nat := 16

def hexAddressOf (bytes : ByteArray) : String := byteSub (sha256Hex bytes) 0 addressHexDigits

structure ContentAddress where
  private mk ::
  hex : String
  deriving BEq, Hashable, Repr, Inhabited

def Content.address (c : Content) : ContentAddress := ⟨hexAddressOf c.bytes⟩

end Data
end Litedoc4
