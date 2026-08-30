/- `crates/litedoc4-global/src/facts.rs`: everything the whole-package
artifacts need from one module. -/
import Std.Data.HashMap
import Litedoc4.Ir
import Litedoc4.Ir.Utf16

namespace Litedoc4

/-- Unicode `White_Space`, which is what Rust's `char::is_whitespace` is and
what every `trim` below has to agree with. Lean's own `Char.isWhitespace` is the
four ASCII ones, so a heading padded with U+00A0 would keep the pad. -/
def isWhiteSpaceCp (c : UInt32) : Bool :=
  (c ≥ 0x09 && c ≤ 0x0D) || c == 0x20 || c == 0x85 || c == 0xA0 || c == 0x1680
    || (c ≥ 0x2000 && c ≤ 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F
    || c == 0x205F || c == 0x3000

/-- Byte offset of the character before `i`. -/
def prevCpAt (s : String) (i : Nat) : Nat := Id.run do
  let mut j := i - 1
  while j > 0 && (byteAt s j) &&& 0xC0 == 0x80 do
    j := j - 1
  return j

def wsStart (s : String) : Nat := Id.run do
  let n := s.utf8ByteSize
  let mut i := 0
  while i < n do
    let (c, w) := cpAt s i
    if !isWhiteSpaceCp c then return i
    i := i + w
  return n

def wsEnd (s : String) : Nat := Id.run do
  let mut e := s.utf8ByteSize
  while e > 0 do
    let j := prevCpAt s e
    let (c, _) := cpAt s j
    if !isWhiteSpaceCp c then return e
    e := j
  return 0

def trimWs (s : String) : String :=
  let a := wsStart s
  let b := wsEnd s
  if a ≥ b then "" else byteSub s a b

def trimStartWs (s : String) : String := byteSub s (wsStart s) s.utf8ByteSize

def trimEndWs (s : String) : String := byteSub s 0 (wsEnd s)

/-- Rust's `str::lines`: split on `\n`, drop one `\r` before it, and no empty
final line for a text that ends in a newline. -/
def linesOf (s : String) : Array String := Id.run do
  let n := s.utf8ByteSize
  let mut out : Array String := #[]
  let mut a := 0
  let mut i := 0
  while i < n do
    if byteAt s i == 10 then
      let e := if i > a && byteAt s (i - 1) == 13 then i - 1 else i
      out := out.push (byteSub s a e)
      a := i + 1
    i := i + 1
  if a < n then out := out.push (byteSub s a n)
  return out

/-- Rust's `rsplit_once(char::is_whitespace)`. -/
def rsplitOnceWs (s : String) : Option (String × String) := Id.run do
  let n := s.utf8ByteSize
  let mut e := n
  while e > 0 do
    let j := prevCpAt s e
    let (c, w) := cpAt s j
    if isWhiteSpaceCp c then return some (byteSub s 0 j, byteSub s (j + w) n)
    e := j
  return none

def allHashes (s : String) : Bool := Id.run do
  let n := s.utf8ByteSize
  let mut i := 0
  while i < n do
    if byteAt s i != 35 then return false
    i := i + 1
  return true

/-- The heading a module docstring opens with, without its `#`.

ATX only. A setext heading is a heading to every Markdown parser and is not read
here, because neither Mathlib's 8,035 module docstrings nor the target's 414
contain one (measured 2026-08-29 →
`benchmarks/results/module-summary-source-2026-08-29.txt`). What would falsify
this: a corpus that writes them. -/
def leadingHeading (docs : Array ModuleDoc) : Option String := Id.run do
  let mut best : Option ModuleDoc := none
  for d in docs do
    match best with
    | none => best := some d
    | some b => if d.line < b.line || (d.line == b.line && d.col < b.col) then best := some d
  let some first := best | return none
  let some line := (linesOf first.text).find? (fun l => !(trimWs l).isEmpty) | return none
  let head := trimStartWs line
  if byteAt head 0 != 35 then return none
  let rest := byteSub head 1 head.utf8ByteSize
  let lead := byteAt rest 0
  if !(lead == 32 || lead == 9) then return none
  let text := trimWs rest
  -- CommonMark's closing sequence: `# Title #` is titled "Title", but `# C#` is
  -- titled "C#" — the run of hashes only closes when a space precedes it.
  let text := match rsplitOnceWs text with
    | some (h, tail) => if !tail.isEmpty && allHashes tail then trimEndWs h else text
    | none => text
  return if text.isEmpty then none else some text

/-- The name on the tagged constant span that starts earliest. The spans come in
the extractor's pre-order, which is **not** sorted by `start`; ties keep the
earlier element of `typeCode`. -/
def headConst (d : Decl) : Option String := Id.run do
  let mut best : Option (Nat × String) := none
  for s in d.typeCode do
    if s.kind != 1 || s.name.isEmpty then continue
    match best with
    | none => best := some (s.start, s.name)
    | some (start, _) => if s.start < start then best := some (s.start, s.name)
  return best.map (·.2)

/-- `crates/litedoc4-global/src/facts.rs`'s `ModuleFacts`, without `tokens` (the
map delta's, M5) and without `contentHash` (the cache's). -/
structure ModuleFacts where
  module : String := ""
  imports : Array String := #[]
  tactics : Nat := 0
  /-- `(name, kind)` per declaration, in the module's own order. -/
  decls : Array (String × String) := #[]
  instances : Array (String × String) := #[]
  instancesFor : Array (String × String) := #[]
  /-- Constant name -> subscripts into `decls`, ascending and deduplicated. -/
  refs : Std.HashMap String (Array Nat) := Std.HashMap.emptyWithCapacity 0
  summary : Option String := none

def factsOf (m : Module) : ModuleFacts := Id.run do
  let mut decls : Array (String × String) := Array.mkEmpty m.decls.size
  let mut instances : Array (String × String) := #[]
  let mut instancesFor : Array (String × String) := #[]
  let mut refs : Std.HashMap String (Array Nat) :=
    Std.HashMap.emptyWithCapacity (m.decls.size * 4 + 4)
  for d in m.decls do
    let index := decls.size
    decls := decls.push (d.name, d.kind)
    for (_, name) in d.refs do
      let users := refs.getD name #[]
      if users.isEmpty || users[users.size - 1]! != index then
        refs := refs.insert name (users.push index)
    if d.kind == "instance" then
      match headConst d with
      | some cls => instances := instances.push (cls, d.name)
      | none => pure ()
      for ty in d.instTypes do
        if !ty.isEmpty then instancesFor := instancesFor.push (ty, d.name)
  return {
    module := m.name
    imports := m.imports
    tactics := m.tacticCount
    decls, instances, instancesFor, refs
    summary := leadingHeading m.moduleDocs }

end Litedoc4
