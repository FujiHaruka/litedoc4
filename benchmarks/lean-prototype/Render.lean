/-
A pure-Lean renderer for the litedoc4 IR.

It answers one question the floor benchmark in `Main.lean` could not: what does
the rendering *logic* cost on top of the floor. It therefore does the same job
as `litedoc4 render` — the document frame, the import list, every declaration in
page order with its anchor, kind, binders, type, attributes, equations, source
range and docstring, and the autolinking of every constant a signature names and
every name a docstring's code spans name — with two things left out on purpose:
**Markdown and math**. A docstring goes in escaped, with its backtick-delimited
code spans found by a byte scan rather than by a parser, because that is where
the autolinks live and the autolinks are the work.

Every phase returns a `Nat` computed inside `IO`, for the reason the header of
`Main.lean` gives: `timeIt (pure (f x))` times the allocation of a thunk.

The JSON parser and the `.lidx` scanner are the fast ones `Main.lean` measured,
copied rather than imported: two executables in one Lake package cannot both
define `main` and be linked, and `Main.lean` must keep building unchanged.

Modes:
  render <work-dir> <out-dir>            sequential, phase by phase
  render <work-dir> <out-dir> --par N    IR read+parse+build and page
                                         render+write on N workers
-/
import Std.Data.HashMap
import Std.Data.HashSet

open System

/-- The phase's body must be an **`IO` action**, not a pure call wrapped in
`return`: `do let x := f y; return (x, n)` puts `f y` *outside* the closure the
`do` block compiles to, so it runs while the argument to this function is being
built — before `t0`, and charged to nothing at all. That is how a first version
of this file reported `index.build 0.000000` for work that takes 60 ms. -/
def timeIt (label : String) (act : IO (α × Nat)) : IO α := do
  let t0 ← IO.monoNanosNow
  let (a, n) ← act
  let t1 ← IO.monoNanosNow
  IO.println s!"{label}\t{(Float.ofNat (t1 - t0)) / 1e9}\t{n}"
  return a

/-! ## Byte access -/

@[inline] def byteAt (s : String) (i : Nat) : UInt8 :=
  if h : (⟨i⟩ : String.Pos.Raw) < s.rawEndPos then s.getUTF8Byte ⟨i⟩ h else 0

@[inline] def byteSub (s : String) (a b : Nat) : String :=
  String.Pos.Raw.extract s ⟨a⟩ ⟨b⟩

/-! ## HTML escaping

`Html.escape` in doc-gen4: `& < > "` and nothing else. The fast path is the one
that matters — most fragments contain none of the four, and then the whole
string is one `memcpy`. -/

def escapeSub (out : String) (s : String) (a b : Nat) : String := Id.run do
  let mut i := a
  let mut seg := a
  let mut acc := out
  while i < b do
    let c := byteAt s i
    if c == 38 || c == 60 || c == 62 || c == 34 then
      acc := acc ++ byteSub s seg i
      acc := acc ++ (if c == 38 then "&amp;" else if c == 60 then "&lt;"
                     else if c == 62 then "&gt;" else "&quot;")
      seg := i + 1
    i := i + 1
  if seg == a then acc ++ byteSub s a b else acc ++ byteSub s seg b

@[inline] def escapeInto (out : String) (s : String) : String :=
  escapeSub out s 0 s.utf8ByteSize

/-! ## JSON -/

inductive JVal where
  | null
  | bool (b : Bool)
  | num (n : Int)
  | str (s : String)
  | arr (a : Array JVal)
  | obj (a : Array (String × JVal))
  deriving Inhabited

namespace JScan

@[inline] def isWs (c : UInt8) : Bool := c == 32 || c == 10 || c == 13 || c == 9

partial def skipWs (s : String) (n i : Nat) : Nat :=
  if i < n && isWs (byteAt s i) then skipWs s n (i + 1) else i

partial def scanStrEnd (s : String) (n i : Nat) (esc : Bool) : Nat × Bool :=
  if i >= n then (i, esc)
  else
    let c := byteAt s i
    if c == 34 then (i, esc)
    else if c == 92 then scanStrEnd s n (i + 2) true
    else scanStrEnd s n (i + 1) esc

def hexVal (c : UInt8) : Nat :=
  if c >= 48 && c <= 57 then c.toNat - 48
  else if c >= 97 && c <= 102 then c.toNat - 87
  else if c >= 65 && c <= 70 then c.toNat - 55
  else 0

partial def unescape (s : String) (endq : Nat) (segStart i : Nat) (acc : String) : String :=
  if i >= endq then acc ++ byteSub s segStart endq
  else if byteAt s i == 92 then
    let acc := acc ++ byteSub s segStart i
    let e := byteAt s (i + 1)
    if e == 117 then
      let v := hexVal (byteAt s (i+2)) * 4096 + hexVal (byteAt s (i+3)) * 256
             + hexVal (byteAt s (i+4)) * 16 + hexVal (byteAt s (i+5))
      if v >= 0xD800 && v < 0xDC00 && i + 11 < endq
         && byteAt s (i+6) == 92 && byteAt s (i+7) == 117 then
        let lo := hexVal (byteAt s (i+8)) * 4096 + hexVal (byteAt s (i+9)) * 256
                + hexVal (byteAt s (i+10)) * 16 + hexVal (byteAt s (i+11))
        let cp := 0x10000 + (v - 0xD800) * 1024 + (lo - 0xDC00)
        unescape s endq (i + 12) (i + 12) (acc.push (Char.ofNat cp))
      else
        unescape s endq (i + 6) (i + 6) (acc.push (Char.ofNat v))
    else
      let ch : Char :=
        if e == 110 then '\n'
        else if e == 116 then '\t'
        else if e == 114 then '\x0d'
        else if e == 98 then '\x08'
        else if e == 102 then '\x0c'
        else if e == 34 then '"'
        else if e == 92 then '\\'
        else if e == 47 then '/'
        else Char.ofNat 0xfffd
      unescape s endq (i + 2) (i + 2) (acc.push ch)
  else unescape s endq segStart (i + 1) acc

@[inline] def readStr (s : String) (n i : Nat) : String × Nat :=
  let (e, esc) := scanStrEnd s n i false
  if esc then (unescape s e i i "", e + 1) else (byteSub s i e, e + 1)

partial def digits (s : String) (n i : Nat) (acc : Nat) : Nat × Nat :=
  if i < n then
    let c := byteAt s i
    if c >= 48 && c <= 57 then digits s n (i + 1) (acc * 10 + (c.toNat - 48)) else (acc, i)
  else (acc, i)

mutual

partial def pVal (s : String) (n i : Nat) : JVal × Nat :=
  let c := byteAt s i
  if c == 123 then pObj s n (i + 1) (Array.mkEmpty 24)
  else if c == 91 then pArr s n (i + 1) (Array.mkEmpty 8)
  else if c == 34 then
    let (v, i) := readStr s n (i + 1)
    (.str v, i)
  else if c == 116 then (.bool true, i + 4)
  else if c == 102 then (.bool false, i + 5)
  else if c == 110 then (.null, i + 4)
  else if c == 45 then
    let (d, i) := digits s n (i + 1) 0
    (.num (-(Int.ofNat d)), i)
  else
    let (d, i) := digits s n i 0
    (.num (Int.ofNat d), i)

partial def pArr (s : String) (n i : Nat) (acc : Array JVal) : JVal × Nat :=
  let i := skipWs s n i
  if byteAt s i == 93 then (.arr acc, i + 1)
  else
    let (v, i) := pVal s n i
    let acc := acc.push v
    let i := skipWs s n i
    let c := byteAt s i
    if c == 44 then pArr s n (i + 1) acc
    else if c == 93 then (.arr acc, i + 1)
    else panic! s!"array: unexpected byte {c} at {i}"

partial def pObj (s : String) (n i : Nat) (acc : Array (String × JVal)) : JVal × Nat :=
  let i := skipWs s n i
  if byteAt s i == 125 then (.obj acc, i + 1)
  else
    let (k, i) := readStr s n (i + 1)
    let i := skipWs s n (i + 1)
    let (v, i) := pVal s n i
    let acc := acc.push (k, v)
    let i := skipWs s n i
    let c := byteAt s i
    if c == 44 then pObj s n (skipWs s n (i + 1)) acc
    else if c == 125 then (.obj acc, i + 1)
    else panic! s!"object: unexpected byte {c} at {i}"

end

end JScan

@[inline] def asStr : JVal → String | .str s => s | _ => ""
@[inline] def asNat : JVal → Nat | .num n => n.toNat | _ => 0
@[inline] def asArr : JVal → Array JVal | .arr a => a | _ => #[]
@[inline] def asObj : JVal → Array (String × JVal) | .obj a => a | _ => #[]
@[inline] def asBool : JVal → Bool | .bool b => b | _ => false
@[inline] def isNull : JVal → Bool | .null => true | _ => false

/-! ## The IR, typed -/

structure Span where
  start : Nat := 0
  stop : Nat := 0
  kind : Nat := 0
  name : String := ""
  front : Nat := 0
  back : Nat := 0
  deriving Inhabited

structure Member where
  label : String := ""
  name : String := ""
  text : String := ""
  code : Array Span := #[]
  binders : Array String := #[]
  binderCode : Array (Array Span) := #[]
  implicits : Array Bool := #[]
  doc : String := ""
  /-- `isDirect === false` is inherited; a *missing* key is direct. -/
  inherited : Bool := false
  deriving Inhabited

structure Decl where
  name : String := ""
  kind : String := ""
  modifiers : Array String := #[]
  binders : Array String := #[]
  implicits : Array Bool := #[]
  binderCode : Array (Array Span) := #[]
  ty : String := ""
  typeCode : Array Span := #[]
  line : Nat := 0
  col : Nat := 0
  endLine : Nat := 0
  endCol : Nat := 0
  index : Nat := 0
  members : Array Member := #[]
  doc : String := ""
  equations : Array String := #[]
  equationCode : Array (Array Span) := #[]
  /-- `[module, name]` on the wire; kept in that order. -/
  refs : Array (String × String) := #[]
  attrs : Array (String × String) := #[]
  deriving Inhabited

structure ModuleDoc where
  line : Nat := 0
  col : Nat := 0
  text : String := ""
  deriving Inhabited

structure Module where
  name : String := ""
  imports : Array String := #[]
  moduleDocs : Array ModuleDoc := #[]
  decls : Array Decl := #[]
  deriving Inhabited

def toSpan (v : JVal) : Span := Id.run do
  let a := asArr v
  let mut s : Span := { start := asNat a[0]!, stop := asNat a[1]!, kind := asNat a[2]! }
  if a.size > 3 then s := { s with name := asStr a[3]! }
  if a.size > 5 then s := { s with front := asNat a[4]!, back := asNat a[5]! }
  return s

@[inline] def toSpans (v : JVal) : Array Span := (asArr v).map toSpan

@[inline] def toSpanLists (v : JVal) : Array (Array Span) := (asArr v).map toSpans

@[inline] def toStrings (v : JVal) : Array String := (asArr v).map asStr

@[inline] def toBools (v : JVal) : Array Bool := (asArr v).map asBool

def toMember (v : JVal) : Member := Id.run do
  let mut m : Member := {}
  for (k, x) in asObj v do
    if k == "label" then m := { m with label := asStr x }
    else if k == "name" then m := { m with name := asStr x }
    else if k == "text" then m := { m with text := asStr x }
    else if k == "code" then m := { m with code := toSpans x }
    else if k == "binders" then m := { m with binders := toStrings x }
    else if k == "binderCode" then m := { m with binderCode := toSpanLists x }
    else if k == "implicits" then m := { m with implicits := toBools x }
    else if k == "doc" then m := { m with doc := asStr x }
    else if k == "isDirect" then
      m := { m with inherited := (match x with | .bool b => !b | _ => false) }
  return m

def toDecl (v : JVal) : Decl := Id.run do
  let mut d : Decl := {}
  for (k, x) in asObj v do
    if k == "name" then d := { d with name := asStr x }
    else if k == "kind" then d := { d with kind := asStr x }
    else if k == "type" then d := { d with ty := asStr x }
    else if k == "typeCode" then d := { d with typeCode := toSpans x }
    else if k == "binders" then d := { d with binders := toStrings x }
    else if k == "binderCode" then d := { d with binderCode := toSpanLists x }
    else if k == "implicits" then d := { d with implicits := toBools x }
    else if k == "line" then d := { d with line := asNat x }
    else if k == "col" then d := { d with col := asNat x }
    else if k == "endLine" then d := { d with endLine := asNat x }
    else if k == "endCol" then d := { d with endCol := asNat x }
    else if k == "index" then d := { d with index := asNat x }
    else if k == "doc" then d := { d with doc := asStr x }
    else if k == "modifiers" then d := { d with modifiers := toStrings x }
    else if k == "members" then d := { d with members := (asArr x).map toMember }
    else if k == "equations" then d := { d with equations := toStrings x }
    else if k == "equationCode" then d := { d with equationCode := toSpanLists x }
    else if k == "refs" then
      d := { d with refs := (asArr x).map fun r =>
        let a := asArr r; (asStr a[0]!, asStr a[1]!) }
    else if k == "attrs" then
      d := { d with attrs := (asArr x).map fun r =>
        let a := asArr r; (asStr a[0]!, asStr a[1]!) }
  return d

def toModule (v : JVal) : Module := Id.run do
  let mut m : Module := {}
  for (k, x) in asObj v do
    if k == "module" then m := { m with name := asStr x }
    else if k == "imports" then m := { m with imports := toStrings x }
    else if k == "declarations" then m := { m with decls := (asArr x).map toDecl }
    else if k == "moduleDocs" then
      m := { m with moduleDocs := (asArr x).map fun md => Id.run do
        let mut r : ModuleDoc := {}
        for (k2, y) in asObj md do
          if k2 == "line" then r := { r with line := asNat y }
          else if k2 == "col" then r := { r with col := asNat y }
          else if k2 == "text" then r := { r with text := asStr y }
        return r }
  return m

/-! ## The link index -/

structure LidxEntry where
  startLine : Nat
  endLine : Nat
  module : String
  deriving Inhabited

structure Lidx where
  names : Std.HashMap String LidxEntry
  modules : Std.HashSet String
  deriving Inhabited

@[inline] def digitsAt (s : String) (a b : Nat) : Nat := Id.run do
  let mut acc := 0
  let mut i := a
  while i < b do
    acc := acc * 10 + (byteAt s i).toNat - 48
    i := i + 1
  return acc

/-- The `.lidx` reader: line-oriented, first byte decides, no error path. The
byte scan `purelean-microbench-optimised-2026-08-30.txt` measured at 0.0877 s,
split so that the `@` module set and the declaration map stay apart the way
`crates/litedoc4-render/src/link_index.rs` keeps them. -/
def parseLidx (text : String) : IO Lidx := do
  let n := text.utf8ByteSize
  let mut names : Std.HashMap String LidxEntry := Std.HashMap.emptyWithCapacity 524288
  let mut modules : Std.HashSet String := Std.HashSet.emptyWithCapacity 8192
  let mut group := ""
  let mut i := 0
  while i < n do
    let a := i
    let mut j := a
    while j < n && byteAt text j != 10 do
      j := j + 1
    if a < j then
      let c := byteAt text a
      if c == 35 then
        pure ()
      else if c == 64 then
        modules := modules.insert (byteSub text (a + 1) j)
      else if c == 9 then
        let mut t1 := a + 1
        while t1 < j && byteAt text t1 != 9 do
          t1 := t1 + 1
        let name := byteSub text (a + 1) t1
        if t1 >= j then
          names := names.insert name { module := group, startLine := 0, endLine := 0 }
        else
          let mut t2 := t1 + 1
          while t2 < j && byteAt text t2 != 9 do
            t2 := t2 + 1
          if t2 >= j then
            names := names.insert name { module := group, startLine := 0, endLine := 0 }
          else
            let mut t3 := t2 + 1
            while t3 < j && byteAt text t3 != 9 do
              t3 := t3 + 1
            if t3 >= j then
              names := names.insert name
                { module := group
                  startLine := digitsAt text (t1 + 1) t2
                  endLine := digitsAt text (t2 + 1) j }
            else
              names := names.insert name { module := group, startLine := 0, endLine := 0 }
      else
        group := byteSub text a j
    i := j + 1
  return { names, modules }

/-! ## The name index

`known` is the IR's own map (dependency slices, then every declaration, then
every reference that fills a gap); `pages` is the set of modules this run writes
a file for; `knownModules` is the union of the `.lidx`'s `@` section with the
modules `known` names. The three answer different questions and
`crates/litedoc4-render/src/autolink.rs` explains why collapsing them is a dead
link. -/

structure NameIndex where
  known : Std.HashMap String String
  lidx : Lidx
  pages : Std.HashSet String
  knownModules : Std.HashSet String
  /-- The same set as an array, because the source-path branch scans it. -/
  knownModuleArray : Array String
  /-- Ablation. Each of the three removes one part of the rendering and nothing
  else, so the difference against the full run is that part's cost — the
  technique the Rust side's `--no-link-index` uses. -/
  noConstLink : Bool := false
  noFragment : Bool := false
  plainDoc : Bool := false
  deriving Inhabited

def buildIndex (deps : Array (Array (String × String))) (mods : Array Module)
    (lidx : Lidx) : IO NameIndex := do
  let mut known : Std.HashMap String String := Std.HashMap.emptyWithCapacity 16384
  for dep in deps do
    for (name, module) in dep do
      known := known.insert name module
  for m in mods do
    for d in m.decls do
      known := known.insert d.name m.name
      for (rmod, rname) in d.refs do
        if !known.contains rname then
          known := known.insert rname rmod
  let mut pages : Std.HashSet String := Std.HashSet.emptyWithCapacity 1024
  for m in mods do
    pages := pages.insert m.name
  let mut knownModules := lidx.modules
  for (_, module) in known.toArray do
    knownModules := knownModules.insert module
  for m in mods do
    knownModules := knownModules.insert m.name
  return { known, lidx, pages, knownModules, knownModuleArray := knownModules.toArray }

/-! ## Lean name syntax

`Lean.isLetterLike` and `Lean.isSubScriptAlnum`, which is what lets `α`, `ℕ` and
`𝒜` start an identifier. The last range is above the BMP; a port that drops it
still resolves every ASCII name, which is nearly all of them. -/

def isLetterLike (c : Char) : Bool :=
  let v := c.val.toNat
  ((0x3b1 ≤ v && v ≤ 0x3c9) && v != 0x3bb)
    || ((0x391 ≤ v && v ≤ 0x3a9) && v != 0x3a0 && v != 0x3a3)
    || (0x3ca ≤ v && v ≤ 0x3fb)
    || (0x1f00 ≤ v && v ≤ 0x1ffe)
    || (0x2100 ≤ v && v ≤ 0x214f)
    || (0x1d49c ≤ v && v ≤ 0x1d59f)
    || ((0xc0 ≤ v && v ≤ 0xff) && v != 0xd7 && v != 0xf7)
    || (0x100 ≤ v && v ≤ 0x17f)

def isSubScriptAlnum (c : Char) : Bool :=
  let v := c.val.toNat
  (0x2080 ≤ v && v ≤ 0x2089) || (0x2090 ≤ v && v ≤ 0x209c)
    || (0x1d62 ≤ v && v ≤ 0x1d6a) || v == 0x2c7c

def isIdFirst (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || c == '_' || isLetterLike c

def isIdRest (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9')
    || c == '_' || c == '\'' || c == '!' || c == '?'
    || isLetterLike c || isSubScriptAlnum c

/-- `Lean.Syntax.decodeNameLit ("`" ++ s)`. The empty string is **not** a name
literal: the autolink splitter hands `""` over routinely, and a resolver that
answered would anchor every double space. -/
def isNameLit (s : String) : Bool := Id.run do
  let n := s.utf8ByteSize
  let mut i := 0
  while true do
    if i >= n then return false
    let c := String.Pos.Raw.get s ⟨i⟩
    let w := c.utf8Size
    let mut after := 0
    if c == '«' then
      let mut j := i + w
      let mut found := false
      while j < n do
        let d := String.Pos.Raw.get s ⟨j⟩
        j := j + d.utf8Size
        if d == '»' then
          after := j
          found := true
          break
      if !found then return false
    else if isIdFirst c then
      let mut j := i + w
      while j < n do
        let d := String.Pos.Raw.get s ⟨j⟩
        if isIdRest d then j := j + d.utf8Size else break
      after := j
    else if '0' ≤ c && c ≤ '9' then
      let mut j := i
      while j < n && byteAt s j >= 48 && byteAt s j <= 57 do
        j := j + 1
      after := j
    else
      return false
    if after >= n then return true
    if byteAt s after == 46 then i := after + 1 else return false
  return false

/-! ## Order

`String.lt` is code-point order, and UTF-8 byte order coincides with it.
`Name.lt` compares the **parents** first, so `Init` and `Mathlib` both precede
`Init.Core`; the import list is sorted with it. -/

def byteLt (a b : String) : Bool := Id.run do
  let na := a.utf8ByteSize
  let nb := b.utf8ByteSize
  let mut i := 0
  while i < na && i < nb do
    let x := byteAt a i
    let y := byteAt b i
    if x != y then return x < y
    i := i + 1
  return na < nb

def components (s : String) : Array String := Id.run do
  let n := s.utf8ByteSize
  let mut out : Array String := #[]
  let mut a := 0
  let mut i := 0
  while i < n do
    if byteAt s i == 46 then
      out := out.push (byteSub s a i)
      a := i + 1
    i := i + 1
  out := out.push (byteSub s a n)
  return out

partial def nameLtC (a b : Array String) : Bool :=
  if a.isEmpty then !b.isEmpty
  else if b.isEmpty then false
  else
    let pa := a.pop
    let pb := b.pop
    if nameLtC pa pb then true
    else if pa == pb then byteLt a.back! b.back!
    else false

def nameLt (a b : String) : Bool := nameLtC (components a) (components b)

/-! ## Links -/

def moduleLink (root : String) (module : String) : String := Id.run do
  let mut out := root
  let mut first := true
  for part in components module do
    if !first then out := out ++ "/"
    out := out ++ part
    first := false
  return out ++ ".html"

def pageRoot (module : String) : String := Id.run do
  let depth := (components module).size - 1
  let mut out := ""
  for _ in [0:depth] do out := out ++ "../"
  return out ++ "./"

/-- `NameIndex::link_to`. The measurement target is rendered with an **empty**
dependency map (`external no package named (--root)` in `render.log`), so the
two external branches are constant `none` here — but the `.lidx` probe for the
source range they consume is not, and it runs on every anchored link, which is
where most of this renderer's link-index traffic comes from. -/
@[inline] def linkTo (ix : NameIndex) (root module : String) (anchor : Option String) :
    Option String :=
  let _range := match anchor with
    | some name => ix.lidx.names.get? name
    | none => none
  if !ix.pages.contains module then none
  else match anchor with
    | some a => some (moduleLink root module ++ "#" ++ a)
    | none => some (moduleLink root module)

def privatePrefix : String := "_private."

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

structure Frag where
  text : String
  ascii : Bool
  /-- UTF-16 index to byte offset; empty when `ascii`. -/
  u2b : Array Nat
  deriving Inhabited

@[inline] def Frag.bpos (f : Frag) (i : Nat) : Nat := if f.ascii then i else f.u2b[i]!

def isAscii (s : String) : Bool := Id.run do
  let n := s.utf8ByteSize
  let mut i := 0
  while i < n do
    if byteAt s i >= 128 then return false
    i := i + 1
  return true

def buildU2B (s : String) : Array Nat := Id.run do
  let n := s.utf8ByteSize
  let mut a : Array Nat := Array.mkEmpty (n + 1)
  let mut i := 0
  while i < n do
    let b := byteAt s i
    let w := if b < 0x80 then 1 else if b < 0xE0 then 2 else if b < 0xF0 then 3 else 4
    a := a.push i
    if w == 4 then a := a.push i
    i := i + w
  return a.push n

def mkFragOf (text : String) : Frag :=
  if isAscii text then { text, ascii := true, u2b := #[] }
  else { text, ascii := false, u2b := buildU2B text }

/-- `splitWhitespaces` replayed from the schema-3 widths: length-preserving in
UTF-16 units, so no offset moves. Skipped entirely when every unit in the runs
is already a space, which is the common case. -/
def mkFrag (text : String) (spans : Array Span) : Frag := Id.run do
  let f0 := mkFragOf text
  let mut ranges : Array (Nat × Nat) := #[]
  for s in spans do
    if s.front > 0 then ranges := ranges.push (s.start - s.front, s.start)
    if s.back > 0 then ranges := ranges.push (s.stop, s.stop + s.back)
  if ranges.isEmpty then return f0
  ranges := ranges.qsort (fun a b => a.1 < b.1)
  let units := if f0.ascii then text.utf8ByteSize else f0.u2b.size - 1
  let mut changed := false
  for (a, b) in ranges do
    if b > units then continue
    let mut i := f0.bpos a
    let e := f0.bpos b
    while i < e do
      if byteAt text i != 32 then changed := true
      i := i + 1
  if !changed then return f0
  let mut out := ""
  let mut pos := 0
  for (a, b) in ranges do
    if b > units then continue
    out := out ++ byteSub text (f0.bpos pos) (f0.bpos a)
    for _ in [a:b] do out := out.push ' '
    pos := b
  out := out ++ byteSub text (f0.bpos pos) text.utf8ByteSize
  return mkFragOf out

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
  if ix.noFragment then return (escapeSub "" text 0 text.utf8ByteSize, false)
  let f := mkFrag text spans
  let units := if f.ascii then text.utf8ByteSize else f.u2b.size - 1
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
      match (if ix.noConstLink then none else constLink ix refs root s.name) with
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

/-! ## Docstrings

**Markdown is not parsed** — that is what `md4c` does on the Rust side and it is
a measurement nobody has taken. What is kept is the part that costs and that a
Markdown parser would only *locate*: `autoLinkInline`, every whitespace-separated
word of a code span that names something documented becoming a link to it. The
code spans are found by a backtick scan rather than by a parser, and everything
outside them goes in escaped. -/

structure PageCtx where
  ix : NameIndex
  root : String
  /-- `nameToLink?`'s last resort walks these, in declaration-range order. -/
  declNames : Array String
  declComps : Array (Array String)
  deriving Inhabited

def moduleOf (ix : NameIndex) (name : String) : Option String :=
  match ix.known.get? name with
  | some m => some m
  | none => (ix.lidx.names.get? name).map (·.module)

/-- Components compared from the end, over as many as the shorter has: `succ`
matches `Nat.succ`, and `Nat.succ` matches `Foo.Nat.succ`. -/
def tailMatch (want have_ : Array String) : Bool := Id.run do
  let k := min want.size have_.size
  for t in [0:k] do
    if want[want.size - 1 - t]! != have_[have_.size - 1 - t]! then return false
  return true

/-- `nameToLink?` from its second branch on. A branch that answers returns its
answer, `none` included: continuing would let the last branch link a name to
whatever declaration of *this* page ends the same way. -/
def nameToLink (c : PageCtx) (s : String) : Option String :=
  if !isNameLit s then none
  else
    let viaMap := if s.startsWith privatePrefix then none else moduleOf c.ix s
    match viaMap with
    | some m => linkTo c.ix c.root m (some s)
    | none =>
      if c.ix.knownModules.contains s then linkTo c.ix c.root s none
      else Id.run do
        let want := components s
        for i in [0:c.declNames.size] do
          if tailMatch want c.declComps[i]! then
            let name := c.declNames[i]!
            match c.ix.known.get? name with
            | some m => return linkTo c.ix c.root m (some name)
            | none => return none
        return none

/-- `nameToLink?`'s first branch: a word that ends in `.lean` and contains a `/`
is a path to a source file. Which module it names is decided against the known
modules — two matches is `none`, because a link to the wrong page is worse than
no link. -/
def sourcePathToLink (c : PageCtx) (path : String) : Option String := Id.run do
  let candidate := path.replace "/" "."
  if c.ix.knownModules.contains candidate then
    return linkTo c.ix c.root candidate none
  let cn := candidate.utf8ByteSize
  let mut found : Option String := none
  for m in c.ix.knownModuleArray do
    let mn := m.utf8ByteSize
    if mn <= cn then continue
    if byteAt m (mn - cn - 1) != 46 then continue
    if byteSub m (mn - cn) mn != candidate then continue
    if found.isSome then return none
    found := some m
  match found with
  | some m => return linkTo c.ix c.root m none
  | none => return none

def resolveLink (c : PageCtx) (s : String) : Option String :=
  if s.endsWith ".lean" && s.any (· == '/') then
    sourcePathToLink c (byteSub s 0 (s.utf8ByteSize - 5))
  else nameToLink c s

@[inline] def pushAnchor (out : String) (href text : String) : String :=
  escapeInto (escapeInto (out ++ "<a href=\"") href ++ "\">") text ++ "</a>"

@[inline] def isSep (c : UInt8) : Bool := c <= 32

/-- `autoLinkInline`. Two lookups per word: the word itself, then whatever
follows its last `.`, so that `Nat.succ` links `succ` when the qualified name is
unknown. -/
def autoLinkInline (out : String) (c : PageCtx) (s : String) : String := Id.run do
  let n := s.utf8ByteSize
  let mut acc := out
  let mut i := 0
  while i < n do
    let a := i
    while i < n && isSep (byteAt s i) do i := i + 1
    if i > a then acc := escapeSub acc s a i
    let b := i
    while i < n && !isSep (byteAt s i) do i := i + 1
    if i > b then
      let piece := byteSub s b i
      match resolveLink c piece with
      | some l => acc := pushAnchor acc l piece
      | none =>
        let pn := piece.utf8ByteSize
        let mut dot := pn
        let mut k := 0
        while k < pn do
          if byteAt piece k == 46 then dot := k
          k := k + 1
        let tail := if dot == pn then piece else byteSub piece (dot + 1) pn
        match resolveLink c tail with
        | some l =>
          if dot != pn then acc := escapeSub acc piece 0 (dot + 1)
          acc := pushAnchor acc l tail
        | none => acc := escapeSub acc piece 0 pn
  return acc

/-- The backtick scan: a run of `k` backticks closes at the next run of exactly
`k`. Three or more is a fenced block. -/
def docstring (out : String) (c : PageCtx) (text : String) : String := Id.run do
  let n := text.utf8ByteSize
  if c.ix.plainDoc then return escapeSub out text 0 n
  let mut acc := out
  let mut seg := 0
  let mut i := 0
  while i < n do
    if byteAt text i != 96 then
      i := i + 1
    else
      let mut k := i
      while k < n && byteAt text k == 96 do k := k + 1
      let run := k - i
      -- the next run of exactly `run` backticks
      let mut j := k
      let mut close := 0
      while j < n do
        if byteAt text j == 96 then
          let mut e := j
          while e < n && byteAt text e == 96 do e := e + 1
          if e - j == run then
            close := j
            break
          j := e
        else j := j + 1
      if close == 0 then
        i := k
      else
        acc := escapeSub acc text seg i
        acc := acc ++ (if run >= 3 then "<pre><code>" else "<code>")
        acc := autoLinkInline acc c (byteSub text k close)
        acc := acc ++ (if run >= 3 then "</code></pre>" else "</code>")
        i := close + run
        seg := i
  return escapeSub acc text seg n

/-! ## The declaration block -/

def lastComponent (name : String) : String := Id.run do
  let n := name.utf8ByteSize
  let mut dot := n
  let mut i := 0
  while i < n do
    if byteAt name i == 46 then dot := i
    i := i + 1
  return if dot == n then name else byteSub name (dot + 1) n

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

/-! ## The page -/

def declRefs (d : Decl) : Std.HashMap String String := Id.run do
  let mut m : Std.HashMap String String := Std.HashMap.emptyWithCapacity (d.refs.size * 2 + 4)
  for (module, name) in d.refs do
    m := m.insert name module
  return m

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

def memberBody (out : String) (c : PageCtx) (short args body : String) (doc : String) :
    String := Id.run do
  let mut acc := escapeInto (out ++ "<div class=\"field-sig\"><span class=\"field-name\">") short
  acc := acc ++ "</span>" ++ args ++ "<span class=\"colon\"> : </span>" ++ body ++ "</div>"
  if !doc.isEmpty then
    acc := docstring (acc ++ "<div class=\"field-doc\">") c doc ++ "</div>"
  return acc ++ "</li>"

def structureHtml (out : String) (c : PageCtx) (m : Module) (d : Decl)
    (refs : Std.HashMap String String) : String := Id.run do
  let mut lis := ""
  let mut contained : Option (Std.HashSet String) := none
  for f in d.members do
    if f.label != "field" then continue
    let short := lastComponent f.name
    let args := pushArgs "" c.ix refs c.root f.binders f.binderCode f.implicits
    let (body, _) := fragment c.ix refs c.root f.text f.code
    if f.inherited then
      -- `declNameToLink`: the declaration's own references first, then the IR's
      -- map, then the dependency closure's `.lidx`
      let module := match refs.get? f.name with
        | some x => some x
        | none => moduleOf c.ix f.name
      let link := match module with
        | some mm => linkTo c.ix c.root mm (some f.name)
        | none => none
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

def constructorsHtml (out : String) (c : PageCtx) (d : Decl)
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

def declHtml (out : String) (c : PageCtx) (m : Module) (d : Decl) (sourceUrl : String) :
    String := Id.run do
  let refs := declRefs d
  let mut acc := escapeInto (out ++ "<section class=\"decl\" id=\"") d.name ++ "\" data-kind=\""
  acc := escapeInto acc (cssKind d.kind) ++ "\">"
  acc := declHeadHtml acc d c.root m.name sourceUrl
  if !d.attrs.isEmpty then
    let texts := d.attrs.map fun (n, v) => if v.isEmpty then n else n ++ " " ++ v
    let mut joined := "@["
    for i in [0:texts.size] do
      if i > 0 then joined := joined ++ ", "
      joined := joined ++ texts[i]!
    acc := escapeInto (acc ++ "<div class=\"attrs\">") (joined ++ "]") ++ "</div>"
  acc := signatureHtml acc c.ix refs c.root d
  if !d.doc.isEmpty then
    acc := docstring (acc ++ "<div class=\"doc\">") c d.doc ++ "</div>"
  let mut extra := ""
  if d.kind == "structure" || d.kind == "class" then
    acc := structureHtml acc c m d refs
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


/-! ## The frame

The theme boot script is inlined in `<head>` on purpose: an external module runs
after first paint, so a reader on the dark theme would see a white flash on
every navigation. It is a build artefact of the Rust tree's `web/` bundle, so it
is a literal here. -/

def themeBoot : String :=
  "(function(){var e=`litedoc4-theme`,t=[`light`,`dark`];try{let n=localStorage.getItem(e);n!==null&&t.includes(n)&&(document.documentElement.dataset.theme=n)}catch{}})();"

def iconMenu : String :=
  "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M3 5h14M3 10h14M3 15h14\"/></svg>"

def iconTheme : String :=
  "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M10 3a7 7 0 1 0 7 7 5.5 5.5 0 0 1-7-7z\"/></svg>"

def headHtml (out : String) (module root title : String) : String := Id.run do
  let mut acc := escapeInto (out ++ "<head><meta charset=\"utf-8\"><meta name=\"viewport\" \
    content=\"width=device-width, initial-scale=1\"><title>") module
  if !title.isEmpty && title != module then
    acc := escapeInto (acc ++ " · ") title
  acc := escapeInto (acc ++ "</title><link rel=\"stylesheet\" href=\"") (root ++ "style.css")
  acc := escapeInto (acc ++ "\"><link rel=\"icon\" href=\"") (root ++ "favicon.svg")
  acc := acc ++ "\"><script>" ++ themeBoot ++ "</script><script type=\"module\" src=\""
  acc := escapeInto acc (root ++ "app.js")
  return acc ++ "\"></script></head>"

def topbarHtml (out : String) (root title : String) : String := Id.run do
  let mut acc := out ++ "<header class=\"topbar\"><button class=\"iconbtn\" id=\"nav-toggle\" \
    aria-label=\"Modules\" aria-expanded=\"false\" aria-controls=\"sidebar\">" ++ iconMenu
    ++ "</button><a class=\"home\" href=\""
  acc := escapeInto acc (root ++ "index.html") ++ "\">"
  acc := escapeInto acc title
  acc := acc ++ "</a><form class=\"search\" role=\"search\" action=\""
  acc := escapeInto acc (root ++ "search.html")
  acc := acc ++ "\"><input type=\"search\" id=\"search-input\" name=\"q\" autocomplete=\"off\" \
    spellcheck=\"false\" placeholder=\"Search declarations\" aria-label=\"Search declarations\">\
    <ul class=\"search-results\" id=\"search-results\" hidden></ul></form>\
    <button class=\"iconbtn\" id=\"theme-toggle\" aria-label=\"Theme\">" ++ iconTheme
  return acc ++ "</button></header>"

/-- The module tree is empty markup `app.js` fills: doc-gen4's equivalent is
57,949 B for this package, and putting it on all 422 pages would add ~25 MB. -/
def sidebarHtml (out : String) (root : String) (memberNames : Array String) : String := Id.run do
  let mut acc := out ++ "<div class=\"scrim\" id=\"scrim\" hidden></div><nav class=\"sidebar\" \
    id=\"sidebar\" aria-label=\"Navigation\">"
  if !memberNames.isEmpty then
    acc := acc ++ "<section class=\"side\"><h2 class=\"side-title\">On this page</h2>\
      <ul class=\"toc\">"
    for name in memberNames do
      acc := escapeInto (acc ++ "<li><a href=\"#") name ++ "\">"
      acc := breakWithin acc name
      acc := acc ++ "</a></li>"
    acc := acc ++ "</ul></section>"
  acc := acc ++ "<section class=\"side\"><h2 class=\"side-title\">Modules</h2>\
    <div class=\"tree\" id=\"module-tree\"><noscript><a href=\""
  acc := escapeInto acc (root ++ "index.html")
  return acc ++ "\">Module index</a></noscript></div></section></nav>"

def moduleHeadHtml (out : String) (module moduleUrl : String) : String := Id.run do
  let mut acc := breakWithin (out ++ "<div class=\"modhead\"><h1>") module
  acc := acc ++ "</h1><p class=\"modactions\"><a class=\"src\" href=\""
  acc := escapeInto acc moduleUrl
  return acc ++ "\">source</a></p></div>"

/-- Duplicates dropped keeping the first occurrence, then a sort by `Name.lt`.
Nearly every import of a package like this one is a dependency's module and this
site has a page for none of them, so most `<li>`s carry no `<a>` at all. -/
def sortedImports (imports : Array String) : Array String := Id.run do
  let mut seen : Std.HashSet String := Std.HashSet.emptyWithCapacity 16
  let mut out : Array String := #[]
  for im in imports do
    if !seen.contains im then
      seen := seen.insert im
      out := out.push im
  return out.qsort nameLt

def moduleMetaHtml (out : String) (ix : NameIndex) (root : String) (imports : Array String) :
    String := Id.run do
  let sorted := sortedImports imports
  let mut acc := out ++ "<div class=\"modmeta\"><details class=\"imports\"><summary>Imports"
  if !sorted.isEmpty then
    acc := acc ++ " <span class=\"count\">" ++ toString sorted.size ++ "</span>"
  acc := acc ++ "</summary><ul>"
  for im in sorted do
    match linkTo ix root im none with
    | some href =>
      acc := escapeInto (acc ++ "<li><a href=\"") href ++ "\">"
      acc := escapeInto acc im ++ "</a></li>"
    | none => acc := escapeInto (acc ++ "<li>") im ++ "</li>"
  return acc ++ "</ul></details><details class=\"imports\" data-fill=\"imported-by\" hidden>\
    <summary>Imported by</summary><ul></ul></details></div>"

/-! ## Page order

A stable sort on `(line, col)` plus a running sequence number: the module
docstrings take `0..k` and a declaration takes `k + index`, which is what keeps
a docstring ahead of a declaration at the same position. -/

structure Item where
  line : Nat
  col : Nat
  seq : Nat
  isDoc : Bool
  idx : Nat
  deriving Inhabited

def itemLt (a b : Item) : Bool :=
  a.line < b.line || (a.line == b.line &&
    (a.col < b.col || (a.col == b.col && a.seq < b.seq)))

def pageItems (m : Module) (sup : Std.HashSet String) : Array Item := Id.run do
  let mut items : Array Item := Array.mkEmpty (m.moduleDocs.size + m.decls.size)
  let mut seq := 0
  for md in m.moduleDocs do
    items := items.push { line := md.line, col := md.col, seq, isDoc := true, idx := seq }
    seq := seq + 1
  for i in [0:m.decls.size] do
    let d := m.decls[i]!
    if sup.contains d.name then continue
    items := items.push
      { line := d.line, col := d.col, seq := seq + d.index, isDoc := false, idx := i }
  return items.qsort itemLt

/-- `res.moduleInfo[current].members`: every `DocInfo` of the module including
the ones that get no page entry, minus the private ones, in declaration-range
order — which is **not** the IR's order. -/
def moduleDeclNames (m : Module) : Array String :=
  let ds := m.decls.filter (fun d => !d.name.startsWith privatePrefix)
  let sorted := ds.qsort fun a b =>
    a.line < b.line || (a.line == b.line &&
      (a.col < b.col || (a.col == b.col && a.index < b.index)))
  sorted.map (·.name)

def pageHtml (ix : NameIndex) (m : Module) (sup : Std.HashSet String)
    (sourceUrl title : String) : String := Id.run do
  let root := pageRoot m.name
  let mut moduleUrl := sourceUrl
  for part in components m.name do
    moduleUrl := moduleUrl ++ "/" ++ part
  moduleUrl := moduleUrl ++ ".lean"
  let declNames := moduleDeclNames m
  let c : PageCtx :=
    { ix, root, declNames, declComps := declNames.map components }
  let mut main := ""
  let mut memberNames : Array String := #[]
  for it in pageItems m sup do
    if it.isDoc then
      main := docstring (main ++ "<div class=\"moddoc\">") c m.moduleDocs[it.idx]!.text ++ "</div>"
    else
      let d := m.decls[it.idx]!
      memberNames := memberNames.push d.name
      main := declHtml main c m d moduleUrl
  let mut out := "<!DOCTYPE html><html lang=\"en\">"
  out := headHtml out m.name root title
  out := escapeInto (out ++ "<body data-root=\"") root
  out := escapeInto (out ++ "\" data-module=\"") m.name
  out := out ++ "\"><a class=\"skip\" href=\"#content\">Skip to content</a>"
  out := topbarHtml out root title
  out := sidebarHtml (out ++ "<div class=\"shell\">") root memberNames
  out := out ++ "<main class=\"content\" id=\"content\">"
  out := moduleHeadHtml out m.name moduleUrl
  out := moduleMetaHtml out ix root m.imports
  return out ++ main ++ "</main></div></body></html>"

def pagePath (outDir : FilePath) (module : String) : FilePath := Id.run do
  let parts := components module
  let mut p := outDir
  for i in [0:parts.size] do
    p := p / (if i + 1 == parts.size then parts[i]! ++ ".html" else parts[i]!)
  return p


/-! ## Driver -/

def jsonFilesIn (dir : FilePath) : IO (Array FilePath) := do
  let entries ← dir.readDir
  let files := entries.filterMap fun e =>
    if e.fileName.endsWith ".json" then some e.path else none
  return files.qsort (·.toString < ·.toString)

def parseModule (text : String) : Module :=
  let n := text.utf8ByteSize
  let (j, _) := JScan.pVal text n (JScan.skipWs text n 0)
  toModule j

def loadDeps (dir : FilePath) : IO (Array (Array (String × String))) := do
  let files ← jsonFilesIn dir
  let mut out : Array (Array (String × String)) := #[]
  for f in files do
    let c ← IO.FS.readFile f
    let n := c.utf8ByteSize
    let (j, _) := JScan.pVal c n (JScan.skipWs c n 0)
    let mut ds : Array (String × String) := #[]
    for (k, v) in asObj j do
      if k == "declarations" then
        for (name, m) in asObj v do
          ds := ds.push (name, asStr m)
    out := out.push ds
  return out

/-- Every name that is some declaration's member, over the **whole site**: a
structure declared in `A` can have its projections attributed to `B`, and a
per-module set leaves those on `B`'s page. -/
def suppressedOf (mods : Array Module) : IO (Std.HashSet String) := do
  let mut s : Std.HashSet String := Std.HashSet.emptyWithCapacity 512
  for m in mods do
    for d in m.decls do
      for mem in d.members do
        s := s.insert mem.name
  return s

def siteTitle (mods : Array Module) : String := Id.run do
  if mods.isEmpty then return "Documentation"
  let head := (components mods[0]!.name)[0]!
  for m in mods do
    if (components m.name)[0]! != head then return "Documentation"
  return head

def writePage (outDir : FilePath) (module html : String) : IO Unit := do
  let p := pagePath outDir module
  match p.parent with
  | some d => IO.FS.createDirAll d
  | none => pure ()
  IO.FS.writeFile p html

def chunkArray (xs : Array α) (parts : Nat) : Array (Array α) := Id.run do
  let parts := max 1 parts
  let mut out : Array (Array α) := Array.mkEmpty parts
  let mut i := 0
  for p in [0:parts] do
    let stop := (xs.size * (p + 1)) / parts
    out := out.push (xs.extract i stop)
    i := stop
  return out

def parMap (chunks : Array (Array α)) (body : Array α → IO β) : IO (Array β) := do
  let tasks ← chunks.mapM fun ch => IO.asTask (body ch) Task.Priority.dedicated
  let mut out : Array β := #[]
  for t in tasks do
    match ← IO.wait t with
    | .ok v => out := out.push v
    | .error e => throw e
  return out

structure Inputs where
  mods : Array Module
  ix : NameIndex
  sup : Std.HashSet String
  sourceUrl : String
  title : String

def renderChunk (inp : Inputs) (outDir : FilePath) (mods : Array Module) : IO Nat := do
  let mut bytes := 0
  for m in mods do
    let html := pageHtml inp.ix m inp.sup inp.sourceUrl inp.title
    bytes := bytes + html.utf8ByteSize
    writePage outDir m.name html
  return bytes

def readParseChunk (files : Array FilePath) : IO (Array Module) := do
  let mut out : Array Module := Array.mkEmpty files.size
  for f in files do
    let c ← IO.FS.readFile f
    out := out.push (parseModule c)
  return out

def run (w outDir : FilePath) (workers : Nat) (ablate : String) : IO UInt32 := do
  let rev ← IO.FS.readFile (w / "rev.txt")
  let sourceUrl := "https://github.com/FujiHaruka/lean-projects/blob/" ++ rev.trimAscii
  let files ← jsonFilesIn (w / "ir" / "modules")

  let mods ←
    if workers > 1 then
      timeIt s!"ir.readparse.{workers}" do
        let parts ← parMap (chunkArray files workers) readParseChunk
        let mut all : Array Module := #[]
        for p in parts do all := all ++ p
        return (all, all.foldl (fun a m => a + m.decls.size) 0)
    else do
      let contents ← timeIt "ir.read" do
        let mut acc : Array String := #[]
        let mut bytes := 0
        for f in files do
          let c ← IO.FS.readFile f
          bytes := bytes + c.utf8ByteSize
          acc := acc.push c
        return (acc, bytes)
      timeIt "ir.parse" do
        let mut acc : Array Module := Array.mkEmpty contents.size
        for c in contents do
          acc := acc.push (parseModule c)
        return (acc, acc.foldl (fun a m => a + m.decls.size) 0)

  let deps ← loadDeps (w / "ir" / "deps")
  let liText ← timeIt "lidx.read" do
    let t ← IO.FS.readFile (w / "link-index.json")
    return (t, t.utf8ByteSize)
  let lidx ← timeIt "lidx.parse" do
    let l ← parseLidx liText
    return (l, l.names.size + l.modules.size)
  let ix ← timeIt "index.build" do
    let ix ← buildIndex deps mods lidx
    let ix := { ix with
      noConstLink := ablate == "links" || ablate == "frag"
      noFragment := ablate == "frag"
      plainDoc := ablate == "doc" || ablate == "frag" }
    return (ix, ix.known.size + ix.knownModules.size)
  let sup ← timeIt "suppressed" do
    let s ← suppressedOf mods
    return (s, s.size)
  let title := siteTitle mods
  let inp : Inputs := { mods, ix, sup, sourceUrl, title }

  IO.FS.createDirAll outDir
  let bytes ←
    if workers > 1 then
      timeIt s!"page.renderwrite.{workers}" do
        let parts ← parMap (chunkArray mods workers) (renderChunk inp outDir)
        let total := parts.foldl (· + ·) 0
        return (total, total)
    else do
      let pages ← timeIt "page.render" do
        let mut acc : Array (String × String) := Array.mkEmpty mods.size
        let mut bytes := 0
        for m in mods do
          let html := pageHtml ix m sup sourceUrl title
          bytes := bytes + html.utf8ByteSize
          acc := acc.push (m.name, html)
        return (acc, bytes)
      timeIt "page.write" do
        let mut bytes := 0
        for (module, html) in pages do
          bytes := bytes + html.utf8ByteSize
          writePage outDir module html
        return (bytes, pages.size)

  let rendered := mods.foldl (fun a m =>
    a + (m.decls.filter (fun d => !sup.contains d.name)).size) 0
  let docs := mods.foldl (fun a m => a + m.moduleDocs.size) 0
  IO.println s!"# modules {mods.size}  declarations {rendered}/{mods.foldl (fun a m => a + m.decls.size) 0} ({sup.size} suppressed)  module docs {docs}  bytes {bytes}"
  IO.println s!"# known {ix.known.size}  link index {ix.lidx.names.size}  known modules {ix.knownModules.size}"
  return 0

/-- The parse split: `Lean.Json`-shaped tree first, typed structures second, so
the conversion has a number of its own. Kept out of `run` because holding both
at once is what it costs, not what a renderer pays. -/
def runSplit (w : FilePath) : IO UInt32 := do
  let files ← jsonFilesIn (w / "ir" / "modules")
  let contents ← timeIt "ir.read" do
    let mut acc : Array String := #[]
    let mut bytes := 0
    for f in files do
      let c ← IO.FS.readFile f
      bytes := bytes + c.utf8ByteSize
      acc := acc.push c
    return (acc, bytes)
  let jvals ← timeIt "ir.parse.jval" do
    let mut acc : Array JVal := Array.mkEmpty contents.size
    let mut n := 0
    for c in contents do
      let sz := c.utf8ByteSize
      let (j, e) := JScan.pVal c sz (JScan.skipWs c sz 0)
      if JScan.skipWs c sz e != sz then
        throw (IO.userError s!"parse: stopped at {e} of {sz}")
      n := n + 1
      acc := acc.push j
    return (acc, n)
  let mods ← timeIt "ir.build.typed" do
    let mut acc : Array Module := Array.mkEmpty jvals.size
    for j in jvals do
      acc := acc.push (toModule j)
    return (acc, acc.foldl (fun a m => a + m.decls.size) 0)
  IO.println s!"# modules {mods.size}"
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | [w, "--split"] => runSplit w
  | [w, out] => run w out 1 "none"
  | [w, out, "--par", k] => run w out k.toNat! "none"
  | [w, out, "--ablate", a] => run w out 1 a
  | [w, out, "--par", k, "--ablate", a] => run w out k.toNat! a
  | _ => do
    IO.eprintln "usage: render <work-dir> <out-dir> [--par N] [--ablate links|doc|frag] \
      | render <work-dir> --split"
    return 2
