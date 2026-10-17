/-
Derived from doc-gen4 (Apache-2.0, Copyright (c) 2021 Henrik Böving) by way of
`git show rust-frozen:crates/litedoc4-render/src/code.rs` — in that tag, not in
this tree — and changed; see this repository's NOTICE and `docs/provenance.md`.
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
def constTarget (ix : NameIndex) (refs : Std.HashMap String String) (name : String) :
    Option (String × Option String) :=
  let isPriv := name.startsWith privatePrefix
  let direct := if isPriv then none else (refs.get? name).orElse fun _ => ix.known.get? name
  match direct with
  | some module => some (module, some name)
  | none =>
    let search := if isPriv then privateToUserName name else name
    match findLinkableParent ix search with
    | some parent => (ix.known.get? parent).map (·, some parent)
    | none =>
      if isPriv then (splitPrivate name).map fun (module, _) => (module, none)
      else none

def cssKind (kind : String) : String :=
  if kind == "definition" then "def"
  else if kind == "class_inductive" then "class"
  else if kind == "constructor" then "ctor"
  else kind

end Litedoc4
