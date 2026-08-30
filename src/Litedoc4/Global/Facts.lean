/- `crates/litedoc4-global/src/facts.rs`: everything the whole-package
artifacts need from one module. -/
import Std.Data.HashMap
import Std.Data.HashSet
import Litedoc4.Global.V8Gc
import Litedoc4.Ir
import Litedoc4.Ir.Utf16

namespace Litedoc4

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

/-- What `autolinkTokens` breaks a code span into parts on: the union of two
answers to "is this code point whitespace", neither of them wrong — V8's
`/[\p{Z}\p{C}]/u`, which the map delta these tokens feed was computed with, and
UnicodeBasic's `Z | C` (`isZC`), which decides which names a page actually ends
up linking.

**Do not narrow this to one of them.** The two ways to be wrong are not mirror
images: a token too many costs a re-render, a token too few keeps a link pointing
at the module a name used to live in and nothing downstream notices. The tables
disagree on 4,803 code points, every one of them a separator for V8 and not for
UnicodeBasic (measured 2026-08-12 →
`benchmarks/results/m2b-v6-token-separators.json`), so the first disjunct is dead
today and stays: the two tables are pinned to things that move independently (a
`lake-manifest.json` rev and a V8 build). -/
def isTokenSeparator (c : UInt32) : Bool := isZC c || isV8ZC c

/-- JavaScript's `\s`: `WhiteSpace` plus `LineTerminator`.

Not `isWhiteSpaceCp`, which is `White_Space` and excludes U+FEFF while including
U+0085. -/
def isJsSpace (c : UInt32) : Bool :=
  c == 9 || c == 10 || c == 11 || c == 12 || c == 13 || c == 32 || c == 0xa0
    || c == 0x1680 || (c ≥ 0x2000 && c ≤ 0x200a) || c == 0x2028 || c == 0x2029
    || c == 0x202f || c == 0x205f || c == 0x3000 || c == 0xfeff

def lastDot (s : String) : Option Nat := Id.run do
  let mut i := s.utf8ByteSize
  while i > 0 do
    i := i - 1
    if byteAt s i == 46 then return some i
  return none

def pushToken (out : Array String) (part : String) : Array String :=
  if part.isEmpty then out
  else
    let out := out.push part
    -- Deliberately asymmetric with the guard above: the last component is pushed
    -- whether or not it is empty, so a part ending in a dot contributes `""`.
    match lastDot part with
    | some d => out.push (byteSub part (d + 1) part.utf8ByteSize)
    | none => out

/-- The inside of every `` `...` `` in the text, as ``/`([^`\n]+)`/g`` finds
them: non-overlapping, left to right, no newline inside, never empty. -/
def codeSpans (doc : String) : Array String := Id.run do
  let n := doc.utf8ByteSize
  let mut out : Array String := #[]
  let mut from_ := 0
  let mut more := true
  while more && from_ < n do
    let mut tick := from_
    while tick < n && byteAt doc tick != 96 do tick := tick + 1
    if tick ≥ n then more := false
    else
      let start := tick + 1
      let mut cur := start
      while cur < n && byteAt doc cur != 96 && byteAt doc cur != 10 do cur := cur + 1
      -- A run that stopped anywhere but on a closing backtick fails, and the
      -- regex retries one position later — which here is the next backtick,
      -- since the scan above never steps over one.
      if cur < n && byteAt doc cur == 96 && cur > start then
        out := out.push (byteSub doc start cur)
        from_ := cur + 1
      else
        from_ := start
  return out

/-- Every `](target)` in the text, as `/\]\(([^)\s]+)\)/g` finds them. -/
def linkTargets (doc : String) : Array String := Id.run do
  let n := doc.utf8ByteSize
  let mut out : Array String := #[]
  let mut from_ := 0
  let mut more := true
  while more && from_ + 1 < n do
    let mut open_ := from_
    while open_ + 1 < n && !(byteAt doc open_ == 93 && byteAt doc (open_ + 1) == 40) do
      open_ := open_ + 1
    if open_ + 1 ≥ n then more := false
    else
      let start := open_ + 2
      let mut cur := start
      let mut scanning := true
      while scanning && cur < n do
        let (c, w) := cpAt doc cur
        if c == 41 || isJsSpace c then scanning := false else cur := cur + w
      if cur < n && byteAt doc cur == 41 && cur > start then
        out := out.push (byteSub doc start cur)
        from_ := cur + 1
      else
        from_ := open_ + 1
  return out

/-- The names a docstring could autolink, in push order: duplicates kept, empty
strings possible.

The unit is the **whitespace-separated part of a code span**, not the code span:
`` `Nat.succ n` `` offers `Nat.succ`, `succ` and `n`. Every part that contains a
dot also offers its last component, unconditionally. Markdown link targets go
through the same name resolution in the renderer, so `](Target)` is tokenised
too.

Deliberately an over-approximation: this does not parse Markdown, because it is a
filter in front of the delta, where a token too many costs a re-render and a
token too few costs a stale page. -/
def autolinkTokens (doc : String) : Array String := Id.run do
  let mut out : Array String := #[]
  for inner in codeSpans doc do
    let n := inner.utf8ByteSize
    let mut a := 0
    let mut i := 0
    while i < n do
      let (c, w) := cpAt inner i
      if isTokenSeparator c then
        out := pushToken out (byteSub inner a i)
        a := i + w
      i := i + w
    out := pushToken out (byteSub inner a n)
  for target in linkTargets doc do
    out := pushToken out target
  return out

/-- `crates/litedoc4-global/src/facts.rs`'s `ModuleFacts`.

**The field order is the state file's bytes.** -/
structure ModuleFacts where
  module : String := ""
  /-- Lean's `String.hash` of the module JSON, carried from `index.json`. The
  cache key, inside the entry rather than beside it so that a cached entry cannot
  be separated from the hash it was built for. -/
  contentHash : String := ""
  imports : Array String := #[]
  tactics : Nat := 0
  /-- `(name, kind)` per declaration, in the module's own order. -/
  decls : Array (String × String) := #[]
  instances : Array (String × String) := #[]
  /-- The names this module's docstrings could autolink: deduplicated and sorted
  in UTF-16 code unit order. The one field no artifact carries — it exists for
  the whole-package map delta, and lives here because the cache boundary is per
  module. -/
  tokens : Array String := #[]
  instancesFor : Array (String × String) := #[]
  /-- Constant name -> subscripts into `decls`, ascending and deduplicated. -/
  refs : Std.HashMap String (Array Nat) := Std.HashMap.emptyWithCapacity 0
  summary : Option String := none

/-- `contentHash` comes from the index entry, not from the file. -/
def factsOf (m : Module) (contentHash : String) : ModuleFacts := Id.run do
  let mut decls : Array (String × String) := Array.mkEmpty m.decls.size
  let mut instances : Array (String × String) := #[]
  let mut instancesFor : Array (String × String) := #[]
  let mut refs : Std.HashMap String (Array Nat) :=
    Std.HashMap.emptyWithCapacity (m.decls.size * 4 + 4)
  -- Module docstrings contribute no tokens, on purpose: the extractor writes
  -- `line` / `col` / `text` for a module doc and no `doc` field, so there is
  -- nothing to tokenise. Reading `text` instead would be a fix, not a port — it
  -- changes which modules the map delta calls affected.
  let mut tokens : Std.HashSet String := Std.HashSet.emptyWithCapacity (m.decls.size * 4 + 4)
  for d in m.decls do
    let index := decls.size
    decls := decls.push (d.name, d.kind)
    if !d.doc.isEmpty then
      for t in autolinkTokens d.doc do tokens := tokens.insert t
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
  let mut tokenList : Array String := Array.mkEmpty tokens.size
  for t in tokens do tokenList := tokenList.push t
  return {
    module := m.name
    contentHash
    imports := m.imports
    tactics := m.tacticCount
    decls, instances, instancesFor, refs
    tokens := sortUtf16 tokenList
    summary := leadingHeading m.moduleDocs }

end Litedoc4
