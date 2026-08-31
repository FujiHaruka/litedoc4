/-
Derived from doc-gen4 (Apache-2.0, Copyright (c) 2021 Henrik Böving) by way of
`crates/litedoc4-render/src/code.rs`, and changed; see this repository's NOTICE
and `docs/provenance.md`.
-/
import Litedoc4.Md.Escape
import Litedoc4.Render.Autolink
import Litedoc4.Render.Whitespace

namespace Litedoc4

/-- Splits `_private.<Module>.<n>.<rest>` into `(<Module>, <rest>)`; the module
part is lazy, so `_private.A.B.0.f` gives `A.B` and not `A`. -/
def splitPrivate (name : String) : Option (String × String) := Id.run do
  if !name.startsWith privatePrefix then return none
  let n := name.utf8ByteSize
  let mut i := privatePrefix.utf8ByteSize
  while i < n do
    if byteAt name i == 46 then
      let mut j := i + 1
      while j < n && byteAt name j >= 48 && byteAt name j <= 57 do
        j := j + 1
      if j > i + 1 && j < n && byteAt name j == 46 then
        return some (byteSub name privatePrefix.utf8ByteSize i, byteSub name (j + 1) n)
    i := i + 1
  return none

def privateToUserName (name : String) : String :=
  match splitPrivate name with
  | some (_, rest) => rest
  | none => name

/-- `findLinkableParent`: strip trailing components that are numeric or start
with `_`, and return the first prefix the IR's own map knows. -/
def findLinkableParent (ix : NameIndex) (name : String) : Option String := Id.run do
  let mut cur := name
  while true do
    let n := cur.utf8ByteSize
    let mut dot := n
    let mut i := 0
    while i < n do
      if byteAt cur i == 46 then dot := i
      i := i + 1
    if dot == n then return none
    let lastLen := n - dot - 1
    let mut isNum : Bool := lastLen > 0
    let mut k := dot + 1
    while k < n do
      if byteAt cur k < 48 || byteAt cur k > 57 then isNum := false
      k := k + 1
    let underscore := lastLen > 0 && byteAt cur (dot + 1) == 95
    if !isNum && !underscore && ix.known.contains cur then return some cur
    cur := byteSub cur 0 dot
    if cur.isEmpty then return none
  return none

/-- `renderedCodeToHtmlAux`'s `.const` resolution. -/
def constLink (ix : NameIndex) (refs : Std.HashMap String String) (root name : String) :
    Option String :=
  let isPriv := name.startsWith privatePrefix
  let direct := if isPriv then none else (refs.get? name).orElse fun _ => ix.known.get? name
  match direct with
  | some module => linkTo ix root module (some name)
  | none =>
    let search := if isPriv then privateToUserName name else name
    match findLinkableParent ix search with
    | some parent =>
      match ix.known.get? parent with
      | some module => linkTo ix root module (some parent)
      | none => none
    | none =>
      if isPriv then
        match splitPrivate name with
        | some (module, _) => linkTo ix root module none
        | none => none
      else none

/-! ## One code fragment

`renderedCodeToHtmlAux` over a text/span pair. Three things it has to get right:
offsets are **UTF-16 code units**, an anchor inside an anchor is suppressed and
the suppression propagates *up*, and the whitespace immediately outside a tagged
sub-expression is rewritten as plain spaces.

The Rust version inserts each wrapper in front of the subtree it has already
written, because which wrapper it is depends on whether the subtree produced an
anchor. A Lean `String` has no `insert_str` that is not a copy, so the walk is
split in two: one pass **backwards over the span array** — pre-order guarantees
a parent comes before its children, so backwards is children-first — decides
every wrapper, and one pass forwards appends. -/

structure FNode where
  start : Nat := 0
  stop : Nat := 0
  op : String := ""
  cl : String := ""
  kids : Array Nat := #[]
  anchor : Bool := false
  deriving Inhabited

@[inline] def anchorOpen (href : String) : String :=
  escapeInto "<a href=\"" href ++ "\">"

def spanFnOpen : String := "<span class=\"fn\">"

mutual

partial def emitNode (out : String) (f : Frag) (nodes : Array FNode) (c : Nat) : String :=
  let nd := nodes[c]!
  let out := out ++ nd.op
  let out := emitRange out f nodes nd.start nd.stop nd.kids
  out ++ nd.cl

partial def emitRange (out : String) (f : Frag) (nodes : Array FNode) (lo hi : Nat)
    (kids : Array Nat) : String := Id.run do
  let mut acc := out
  let mut pos := lo
  for c in kids do
    let nd := nodes[c]!
    if nd.start > pos then acc := escapeSub acc f.text (f.bpos pos) (f.bpos nd.start)
    acc := emitNode acc f nodes c
    pos := nd.stop
  if hi > pos then acc := escapeSub acc f.text (f.bpos pos) (f.bpos hi)
  return acc

end

/-- The html and whether it contains an `<a>` this walk produced. -/
def fragment (ix : NameIndex) (refs : Std.HashMap String String) (root : String)
    (text : String) (spans : Array Span) : String × Bool := Id.run do
  let f := mkFrag text spans
  let units := f.units
  if spans.isEmpty then
    return (escapeSub "" f.text 0 f.text.utf8ByteSize, false)
  -- the tree: pop while the new span starts at or after the top of the stack
  -- ends (`>=`, not `>`: two spans that merely touch are siblings)
  let mut nodes : Array FNode := Array.mkEmpty spans.size
  for s in spans do
    nodes := nodes.push { start := s.start, stop := s.stop }
  let mut roots : Array Nat := #[]
  let mut stack : Array Nat := #[]
  for me in [0:spans.size] do
    let st := spans[me]!.start
    while !stack.isEmpty && st >= spans[stack.back!]!.stop do
      stack := stack.pop
    if stack.isEmpty then roots := roots.push me
    else
      let p := stack.back!
      nodes := nodes.modify p (fun nd => { nd with kids := nd.kids.push me })
    stack := stack.push me
  -- backwards: children are decided before their parent
  for k in [0:nodes.size] do
    let me := nodes.size - 1 - k
    let nd := nodes[me]!
    let mut childAnchor := false
    for c in nd.kids do
      if nodes[c]!.anchor then childAnchor := true
    let s := spans[me]!
    if s.kind == 0 then
      nodes := nodes.set! me { nd with op := spanFnOpen, cl := "</span>", anchor := childAnchor }
    else if s.kind == 2 then
      if childAnchor then
        nodes := nodes.set! me { nd with anchor := true }
      else
        nodes := nodes.set! me
          { nd with op := anchorOpen (root ++ "foundational_types.html")
                  , cl := "</a>", anchor := true }
    else
      match constLink ix refs root s.name with
      | none =>
        nodes := nodes.set! me { nd with op := spanFnOpen, cl := "</span>", anchor := childAnchor }
      | some l =>
        if childAnchor then
          nodes := nodes.set! me { nd with anchor := true }
        else
          nodes := nodes.set! me { nd with op := anchorOpen l, cl := "</a>", anchor := true }
  let mut has := false
  for r in roots do
    if nodes[r]!.anchor then has := true
  return (emitRange "" f nodes 0 units roots, has)

/-- `breakWithin`: each dot-separated component in its own `span.name`. -/
def breakWithin (out : String) (name : String) : String := Id.run do
  let n := name.utf8ByteSize
  let mut acc := out
  let mut a := 0
  let mut i := 0
  let mut first := true
  while i <= n do
    if i == n || byteAt name i == 46 then
      if !first then acc := acc.push '.'
      acc := escapeSub (acc ++ "<span class=\"name\">") name a i ++ "</span>"
      first := false
      a := i + 1
    i := i + 1
  return acc

/-- `getKindDescription`: the words a reader sees, which is **not** the mapping
`cssKind` uses. -/
def kindDescription (kind : String) (modifiers : Array String) : String :=
  let has := fun (m : String) => modifiers.any (· == m)
  if kind == "definition" || kind == "instance" then
    let a := if has "unsafe" then "unsafe " else ""
    let b := if has "noncomputable" then "noncomputable " else ""
    let c := if kind == "instance" then "instance" else if has "abbrev" then "abbrev" else "def"
    a ++ b ++ c
  else if kind == "axiom" && has "unsafe" then "unsafe axiom"
  else if kind == "opaque" && has "partial" then "partial def"
  else if kind == "opaque" && has "unsafe" then "unsafe opaque"
  else if kind == "inductive" && has "unsafe" then "unsafe inductive"
  else if kind == "class_inductive" then "class inductive"
  else kind

def cssKind (kind : String) : String :=
  if kind == "definition" then "def"
  else if kind == "class_inductive" then "class"
  else if kind == "constructor" then "ctor"
  else kind

def declRefs (d : Decl) : Std.HashMap String String := Id.run do
  let mut m : Std.HashMap String String := Std.HashMap.emptyWithCapacity (d.refs.size * 2 + 4)
  for (module, name) in d.refs do
    m := m.insert name module
  return m

end Litedoc4
