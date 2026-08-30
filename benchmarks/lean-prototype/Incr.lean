/-
The incremental half of litedoc4, in pure Lean: `impact`, `ownership` and
`merge`.

The renderer prototype in `Render.lean` measured the *other* half. These three
commands are the ones that carry the IR full reads, which
`docs/approach-pillars.md` §5.6 names as the incremental path's rate limiter,
so what they cost decides whether a pure-Lean litedoc4 is possible at all.

The definitions are `crates/litedoc4-incr/src/{impact,ownership,merge}.rs`, and
the answers are meant to be *identical*, not merely similar: `--print-set`
writes the same sorted set and `merge` writes the same tree.

The JSON scanner, the typed IR and the byte helpers are copied from
`Render.lean` rather than imported, for the reason its own header gives: two
executables in one Lake package cannot both define `main` and be linked, and
`Main.lean` and `Render.lean` must keep building unchanged.

Every phase returns a `Nat` computed inside `IO`, because `timeIt` over
`do let x := pureFn y; return (x, n)` charges nothing at all.

Modes:
  incr impact    --ir D --changed M --mode all --print-set F [--json F] [--par N]
  incr ownership --base D --inc D --print-set F [--json F] [--par N]
  incr merge     --base D --inc D --out D [--changed-out F] [--par N]
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

/-! ## Order

`byteLt` is UTF-8 byte order = code point order, which is what Lean's `String`
comparison does and therefore what a `deps/<Root>.json`'s keys are in.
`utf16Lt` is `Array.prototype.sort`'s, which is what every `--print-set` is in;
the two part company above the BMP and the IR really does carry mathematical
alphanumerics. -/

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


def utf16Units (s : String) : Array UInt32 :=
  s.foldl (fun out c =>
    let v := c.val
    if v ≥ 0x10000 then
      let x := v - 0x10000
      (out.push ((0xD800 : UInt32) + (x >>> 10))).push ((0xDC00 : UInt32) + (x % 0x400))
    else out.push v) (Array.mkEmpty s.length)

/-- `Array.prototype.sort`'s order, which is what every `--print-set` is in.
Not `byteLt`: a supplementary scalar starts in `D800..DBFF` and so sorts below
every scalar in `U+E000..U+FFFF`, the other way round from code point order. -/
def utf16Lt (a b : String) : Bool := Id.run do
  let ua := utf16Units a
  let ub := utf16Units b
  let mut i := 0
  while i < ua.size && i < ub.size do
    if ua[i]! != ub[i]! then return ua[i]! < ub[i]!
    i := i + 1
  return ua.size < ub.size

@[inline] def sortUtf16 (xs : Array String) : Array String := xs.qsort utf16Lt

/-! ## JSON out

`serde_json`'s bytes: compact has no spaces at all, a string escapes only `"`,
`\` and the C0 controls, and non-ASCII goes out as UTF-8. -/

def hexDigit (v : Nat) : Char := if v < 10 then Char.ofNat (48 + v) else Char.ofNat (87 + v)

def hex4 (v : Nat) : String :=
  String.ofList [hexDigit ((v / 4096) % 16), hexDigit ((v / 256) % 16),
                 hexDigit ((v / 16) % 16), hexDigit (v % 16)]

def escJson (out : String) (s : String) : String := Id.run do
  let n := s.utf8ByteSize
  let mut acc := out
  let mut seg := 0
  let mut i := 0
  while i < n do
    let c := byteAt s i
    if c == 34 || c == 92 || c < 32 then
      acc := acc ++ byteSub s seg i
      acc := acc ++
        (if c == 34 then "\\\""
         else if c == 92 then "\\\\"
         else if c == 8 then "\\b"
         else if c == 9 then "\\t"
         else if c == 10 then "\\n"
         else if c == 12 then "\\f"
         else if c == 13 then "\\r"
         else "\\u" ++ hex4 c.toNat)
      seg := i + 1
    i := i + 1
  return acc ++ byteSub s seg n

@[inline] def quoted (out : String) (s : String) : String := (escJson (out ++ "\"") s) ++ "\""

partial def writeJson (out : String) (v : JVal) : String :=
  match v with
  | .null => out ++ "null"
  | .bool b => out ++ (if b then "true" else "false")
  | .num n => out ++ toString n
  | .str s => quoted out s
  | .arr a => Id.run do
      let mut acc := out ++ "["
      let mut first := true
      for x in a do
        if !first then acc := acc ++ ","
        first := false
        acc := writeJson acc x
      return acc ++ "]"
  | .obj o => Id.run do
      let mut acc := out ++ "{"
      let mut first := true
      for (k, x) in o do
        if !first then acc := acc ++ ","
        first := false
        acc := (quoted acc k) ++ ":"
        acc := writeJson acc x
      return acc ++ "}"

@[inline] def jget (v : JVal) : String → Option JVal := fun k => Id.run do
  for (kk, x) in asObj v do
    if kk == k then return some x
  return none

/-- Keeps the key's position when it is already there, appends when it is not —
`Ordered::insert`'s rule, which is what makes a merged `index.json`'s key order
the base file's. -/
def jset (v : JVal) (k : String) (x : JVal) : JVal := Id.run do
  let o := asObj v
  for i in [0:o.size] do
    if o[i]!.1 == k then return .obj (o.set! i (k, x))
  return .obj (o.push (k, x))

/-! ## The index -/

structure IdxEntry where
  module : String := ""
  file : String := ""
  bytes : Nat := 0
  declarations : Nat := 0
  contentHash : String := ""
  raw : JVal := .null
  deriving Inhabited

def toIdxEntry (v : JVal) : IdxEntry := Id.run do
  let mut e : IdxEntry := { raw := v }
  for (k, x) in asObj v do
    if k == "module" then e := { e with module := asStr x }
    else if k == "file" then e := { e with file := asStr x }
    else if k == "bytes" then e := { e with bytes := asNat x }
    else if k == "declarations" then e := { e with declarations := asNat x }
    else if k == "contentHash" then e := { e with contentHash := asStr x }
  return e

structure IrIndex where
  raw : JVal := .null
  entries : Array IdxEntry := #[]
  deriving Inhabited

@[inline] def parseJson (text : String) : JVal :=
  let n := text.utf8ByteSize
  (JScan.pVal text n (JScan.skipWs text n 0)).1

def readIndex (dir : FilePath) : IO IrIndex := do
  let text ← IO.FS.readFile (dir / "index.json")
  let j := parseJson text
  let entries := match jget j "modules" with
    | some m => (asArr m).map toIdxEntry
    | none => #[]
  return { raw := j, entries }

@[inline] def readModuleFile (path : FilePath) : IO Module := do
  let text ← IO.FS.readFile path
  return toModule (parseJson text)

/-! ## Workers -/

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

/-- `parts` chunks when there is more than one worker, one chunk otherwise, so
the sequential path runs the *same* body and the difference between the two rows
is threading and nothing else. -/
@[inline] def spread (xs : Array α) (workers : Nat) (body : Array α → IO β) : IO (Array β) :=
  parMap (chunkArray xs (max 1 workers)) body

/-! ## The read counter

Counted the way `litedoc4_ir::metrics` counts: files opened and parsed, split so
that only the module count divides into a number of full passes. `fs::copy` of a
module file is not a read on either side. -/

structure Reads where
  index : Nat := 0
  module : Nat := 0
  depMap : Nat := 0
  deriving Inhabited

@[inline] def Reads.add (a b : Reads) : Reads :=
  { index := a.index + b.index, module := a.module + b.module, depMap := a.depMap + b.depMap }

def Reads.report (r : Reads) (modules : Nat) : String :=
  let passes := if modules == 0 then 0.0 else (Float.ofNat r.module) / (Float.ofNat modules)
  s!"# reads index {r.index}  module {r.module}  depMap {r.depMap}  \
    full passes {passes} over {modules} modules"

/-! ## impact

`crates/litedoc4-incr/src/impact.rs`. IMPORTERS is the reverse *transitive*
import closure cut to the package's own modules — the sound bound. REFERRERS is
the modules with a `refs` entry whose defining module is the changed one. Both
are computed whatever `--mode` selects, so the summary can quote the gap. -/

structure ModInfo where
  name : String := ""
  imports : Array String := #[]
  decls : Nat := 0
  /-- Each named own-package module once, itself excluded. -/
  refs : Array String := #[]
  deriving Inhabited

/-- Everything `impact` looks at and nothing else. `toModule` is the like-for-like
comparison — `serde` deserialises the whole `ModuleFile` — but a pure-Lean
implementation would not be obliged to, and the gap between the two is this
stage's headroom. -/
def toModuleSlim (v : JVal) : Module := Id.run do
  let mut m : Module := {}
  for (k, x) in asObj v do
    if k == "module" then m := { m with name := asStr x }
    else if k == "imports" then m := { m with imports := toStrings x }
    else if k == "declarations" then
      m := { m with decls := (asArr x).map fun dv => Id.run do
        let mut d : Decl := {}
        for (dk, y) in asObj dv do
          if dk == "name" then d := { d with name := asStr y }
          else if dk == "refs" then
            d := { d with refs := (asArr y).map fun r =>
              let a := asArr r; (asStr a[0]!, asStr a[1]!) }
        return d }
  return m

def infoOfModule (own : Std.HashSet String) (m : Module) : ModInfo := Id.run do
  let mut imports : Array String := Array.mkEmpty m.imports.size
  for im in m.imports do
    if own.contains im then imports := imports.push im
  let mut named : Array String := #[]
  let mut seen : Std.HashSet String := Std.HashSet.emptyWithCapacity 32
  for d in m.decls do
    for (owner, _) in d.refs do
      if own.contains owner && owner != m.name && !seen.contains owner then
        seen := seen.insert owner
        named := named.push owner
  return { name := m.name, imports, decls := m.decls.size, refs := named }

/-- Every own-package module gets a list, so a module nobody imports is an empty
list rather than an absent key. -/
def reverseGraph (own : Array String) (infos : Array ModInfo)
    (pick : ModInfo → Array String) : Std.HashMap String (Array String) := Id.run do
  let mut r : Std.HashMap String (Array String) := Std.HashMap.emptyWithCapacity (own.size * 2)
  for m in own do r := r.insert m #[]
  for info in infos do
    for t in pick info do
      r := r.insert t ((r.getD t #[]).push info.name)
  return r

/-- Everything reachable from `seeds`; the seeds are in the result only when
something leads back to them, which is what `importersTransitive` counts. -/
def closure (seeds : Array String) (edges : Std.HashMap String (Array String)) :
    Std.HashSet String := Id.run do
  let mut seen : Std.HashSet String := Std.HashSet.emptyWithCapacity 512
  let mut stack := seeds
  while stack.size > 0 do
    let cur := stack.back!
    stack := stack.pop
    for nxt in edges.getD cur #[] do
      if !seen.contains nxt then
        seen := seen.insert nxt
        stack := stack.push nxt
  return seen

def impactJson (ir : String) (changed : Array String) (mode : String)
    (ownModules selfModules refDirect refTrans impTrans selected selDecls selBytes : Nat) :
    String := Id.run do
  let mut s := "{\n  \"ir\": " ++ (quoted "" ir) ++ ",\n  \"changed\": "
  if changed.isEmpty then s := s ++ "[]"
  else
    s := s ++ "[\n"
    for i in [0:changed.size] do
      s := s ++ "    " ++ (quoted "" changed[i]!) ++ (if i + 1 == changed.size then "\n" else ",\n")
    s := s ++ "  ]"
  s := s ++ ",\n  \"mode\": " ++ (quoted "" mode)
  s := s ++ s!",\n  \"ownModules\": {ownModules}"
  s := s ++ s!",\n  \"self\": {selfModules}"
  s := s ++ s!",\n  \"referrersDirect\": {refDirect}"
  s := s ++ s!",\n  \"referrersTransitive\": {refTrans}"
  s := s ++ s!",\n  \"importersTransitive\": {impTrans}"
  s := s ++ s!",\n  \"selected\": {selected}"
  s := s ++ s!",\n  \"selectedDeclarations\": {selDecls}"
  s := s ++ s!",\n  \"selectedIrBytes\": {selBytes}" ++ "\n}"
  return s

def runImpact (irDir : FilePath) (changed : Array String) (mode : String)
    (printSet jsonOut : Option FilePath) (workers : Nat) (slim : Bool) : IO UInt32 := do
  let idx ← timeIt "index.read" do
    let i ← readIndex irDir
    return (i, i.entries.size)
  let mut reads : Reads := { index := 1 }
  let mut own : Std.HashSet String := Std.HashSet.emptyWithCapacity (idx.entries.size * 2)
  let mut ownList : Array String := #[]
  for e in idx.entries do
    if !own.contains e.module then
      own := own.insert e.module
      ownList := ownList.push e.module
  let ownSet := own
  let files := idx.entries.map (fun e => irDir / e.file)
  let infos ← timeIt s!"ir.readparse.{workers}" do
    let parts ← spread files workers fun chunk => do
      let mut acc : Array ModInfo := Array.mkEmpty chunk.size
      for f in chunk do
        let text ← IO.FS.readFile f
        let m := if slim then toModuleSlim (parseJson text) else toModule (parseJson text)
        acc := acc.push (infoOfModule ownSet m)
      return acc
    let mut all : Array ModInfo := Array.mkEmpty files.size
    for p in parts do all := all ++ p
    return (all, all.foldl (fun a i => a + i.decls) 0)
  reads := { reads with module := reads.module + files.size }

  let sel ← timeIt "closures" do
    let importedBy := reverseGraph ownList infos (·.imports)
    let referredBy := reverseGraph ownList infos (·.refs)
    let mut declCount : Std.HashMap String Nat := Std.HashMap.emptyWithCapacity (infos.size * 2)
    for i in infos do declCount := declCount.insert i.name i.decls
    for m in changed do
      if !ownSet.contains m then
        throw (IO.userError s!"{m} is not a module of this package")
    let selfSet := changed.foldl (fun (s : Std.HashSet String) m => s.insert m)
      (Std.HashSet.emptyWithCapacity 8)
    let importers := closure changed importedBy
    let refTrans := closure changed referredBy
    let mut refDirect : Std.HashSet String := Std.HashSet.emptyWithCapacity 64
    for m in changed do
      for r in referredBy.getD m #[] do refDirect := refDirect.insert r
    let selected : Array String :=
      if mode == "self" then selfSet.toArray
      else if mode == "referrers" then (refDirect.insertMany selfSet.toArray).toArray
      else if mode == "importers" then (importers.insertMany selfSet.toArray).toArray
      else if mode == "all" then ownList
      else panic! s!"unknown mode {mode}"
    let list := sortUtf16 selected
    let inSel := list.foldl (fun (s : Std.HashSet String) m => s.insert m)
      (Std.HashSet.emptyWithCapacity (list.size * 2))
    let selDecls := list.foldl (fun a m => a + declCount.getD m 0) 0
    let selBytes := idx.entries.foldl
      (fun a e => if inSel.contains e.module then a + e.bytes else a) 0
    return ((list, selfSet.size, refDirect.size, refTrans.size, importers.size, selDecls,
      selBytes), list.size)
  let (list, selfN, refDirectN, refTransN, importersN, selDecls, selBytes) := sel

  let body := impactJson irDir.toString changed mode ownSet.size selfN refDirectN refTransN
    importersN list.size selDecls selBytes
  IO.println body
  match jsonOut with
  | some p => IO.FS.writeFile p (body ++ "\n")
  | none => pure ()
  match printSet with
  | some p =>
    -- `impact`'s own writer, not `write_text`: it writes one blank line where
    -- that would write an empty file.
    IO.FS.writeFile p (String.intercalate "\n" list.toList ++ "\n")
  | none => pure ()
  IO.println (reads.report idx.entries.size)
  return 0

/-! ## ownership

`crates/litedoc4-incr/src/ownership.rs`. A `(defining module, name)` pair goes
stale when the name moves, even though nothing about the referring module
changed, so the base tree has to be swept for pairs that no longer hold. **That
sweep is the extra full read** the real one-module edit costs and the `ledger
touch` simulation does not: it runs only when a name actually entered or left
the global map. -/

structure Witness where
  module : String := ""
  rule : String := ""
  refModule : String := ""
  refName : String := ""
  deriving Inhabited

def ruleLostOwner : String := "lostOwner"
def ruleMovedElsewhere : String := "movedElsewhere"

def declNameSet (m : Module) : Std.HashSet String := Id.run do
  let mut s : Std.HashSet String := Std.HashSet.emptyWithCapacity (m.decls.size * 2 + 8)
  for d in m.decls do s := s.insert d.name
  return s

structure Sweep where
  lost : Array String := #[]
  moved : Array String := #[]
  witnesses : Array Witness := #[]
  deriving Inhabited

def sweepChunk (baseDir : FilePath) (lostOwners gainedOwners : Std.HashMap String (Std.HashSet String))
    (chunk : Array IdxEntry) : IO Sweep := do
  let mut s : Sweep := {}
  for e in chunk do
    let m ← readModuleFile (baseDir / e.file)
    let mut hitLost := false
    let mut hitMoved := false
    for d in m.decls do
      for (owner, name) in d.refs do
        if (lostOwners.get? name).any (·.contains owner) then
          if !hitLost then
            let w : Witness :=
              { module := e.module, rule := ruleLostOwner, refModule := owner, refName := name }
            hitLost := true
            s := { s with witnesses := s.witnesses.push w, lost := s.lost.push e.module }
        else if (gainedOwners.get? name).any (fun os => !os.contains owner) then
          if !hitMoved then
            let w : Witness :=
              { module := e.module, rule := ruleMovedElsewhere, refModule := owner,
                refName := name }
            hitMoved := true
            s := { s with witnesses := s.witnesses.push w, moved := s.moved.push e.module }
  return s

def ownershipJson (base inc : String) (incModules removedModules : Nat) (scannedBase : Int)
    (lost gained lostD gainedD byLost byMoved : Nat) (stale : Array String)
    (witnesses : Array Witness) : String := Id.run do
  let arr (name : String) (xs : Array String) : String := Id.run do
    let mut s := "  \"" ++ name ++ "\": "
    if xs.isEmpty then return s ++ "[]"
    s := s ++ "[\n"
    for i in [0:xs.size] do
      s := s ++ "    " ++ (quoted "" xs[i]!) ++ (if i + 1 == xs.size then "\n" else ",\n")
    return s ++ "  ]"
  let mut s := "{\n  \"base\": " ++ (quoted "" base)
  s := s ++ ",\n  \"inc\": " ++ (quoted "" inc)
  s := s ++ s!",\n  \"incModules\": {incModules}"
  s := s ++ s!",\n  \"removedModules\": {removedModules}"
  s := s ++ s!",\n  \"scannedBaseModules\": {scannedBase}"
  s := s ++ s!",\n  \"lostNames\": {lost}"
  s := s ++ s!",\n  \"gainedNames\": {gained}"
  s := s ++ s!",\n  \"lostNamesDistinct\": {lostD}"
  s := s ++ s!",\n  \"gainedNamesDistinct\": {gainedD}"
  s := s ++ s!",\n  \"staleByLostOwner\": {byLost}"
  s := s ++ s!",\n  \"staleByMovedElsewhere\": {byMoved}"
  s := s ++ s!",\n  \"stale\": {stale.size}"
  s := s ++ ",\n" ++ arr "staleModules" stale
  s := s ++ ",\n  \"witnesses\": "
  if witnesses.isEmpty then s := s ++ "[]"
  else
    s := s ++ "[\n"
    for i in [0:witnesses.size] do
      let w := witnesses[i]!
      s := s ++ "    {\n      \"module\": " ++ (quoted "" w.module)
      s := s ++ ",\n      \"rule\": " ++ (quoted "" w.rule)
      s := s ++ ",\n      \"ref\": [\n        " ++ (quoted "" w.refModule)
      s := s ++ ",\n        " ++ (quoted "" w.refName) ++ "\n      ]\n    }"
      s := s ++ (if i + 1 == witnesses.size then "\n" else ",\n")
    s := s ++ "  ]"
  return s ++ "\n}"

def witnessesInSummary : Nat := 20

def runOwnership (baseDir incDir : FilePath) (printSet jsonOut : Option FilePath)
    (workers : Nat) : IO UInt32 := do
  let baseIdx ← timeIt "index.read" do
    let i ← readIndex baseDir
    return (i, i.entries.size)
  let incIdx ← readIndex incDir
  let mut reads : Reads := { index := 2 }
  let mut baseFileOf : Std.HashMap String IdxEntry :=
    Std.HashMap.emptyWithCapacity (baseIdx.entries.size * 2)
  for e in baseIdx.entries do baseFileOf := baseFileOf.insert e.module e

  let diff ← timeIt "diff" do
    let mut lostOwners : Std.HashMap String (Std.HashSet String) :=
      Std.HashMap.emptyWithCapacity 64
    let mut gainedOwners : Std.HashMap String (Std.HashSet String) :=
      Std.HashMap.emptyWithCapacity 64
    let mut lost := 0
    let mut gained := 0
    for e in incIdx.entries do
      let now := declNameSet (← readModuleFile (incDir / e.file))
      let was ← match baseFileOf.get? e.module with
        | some be => do
            let bm ← readModuleFile (baseDir / be.file)
            pure (declNameSet bm)
        | none => pure (Std.HashSet.emptyWithCapacity 1)
      for name in was.toArray do
        if !now.contains name then
          lostOwners := lostOwners.insert name
            ((lostOwners.getD name (Std.HashSet.emptyWithCapacity 2)).insert e.module)
          lost := lost + 1
      for name in now.toArray do
        if !was.contains name then
          gainedOwners := gainedOwners.insert name
            ((gainedOwners.getD name (Std.HashSet.emptyWithCapacity 2)).insert e.module)
          gained := gained + 1
    return ((lostOwners, gainedOwners, lost, gained), lost + gained)
  let (lostOwners, gainedOwners, lostN, gainedN) := diff
  reads := { reads with module := reads.module + incIdx.entries.size
                          + (incIdx.entries.filter (fun e => baseFileOf.contains e.module)).size }

  let mut exclude : Std.HashSet String := Std.HashSet.emptyWithCapacity 16
  for e in incIdx.entries do exclude := exclude.insert e.module
  let excludeSet := exclude
  -- Nothing moved and nothing was deleted: no module can be pointing anywhere
  -- wrong, so the base IR is not read at all.
  let watching := !lostOwners.isEmpty || !gainedOwners.isEmpty
  let scanned := if watching then
      (Int.ofNat baseIdx.entries.size) - (Int.ofNat excludeSet.size) else 0
  let toScan := if watching then
      baseIdx.entries.filter (fun e => !excludeSet.contains e.module) else #[]
  let sweeps ← timeIt s!"scan.{workers}" do
    let parts ← spread toScan workers (sweepChunk baseDir lostOwners gainedOwners)
    return (parts, parts.foldl (fun a p => a + p.witnesses.size) 0)
  reads := { reads with module := reads.module + toScan.size }

  let mut staleLost : Std.HashSet String := Std.HashSet.emptyWithCapacity 64
  let mut staleMoved : Std.HashSet String := Std.HashSet.emptyWithCapacity 64
  let mut witnesses : Array Witness := #[]
  for p in sweeps do
    for m in p.lost do staleLost := staleLost.insert m
    for m in p.moved do staleMoved := staleMoved.insert m
    witnesses := witnesses ++ p.witnesses
  let stale := sortUtf16 (staleMoved.insertMany staleLost.toArray).toArray

  let body := ownershipJson baseDir.toString incDir.toString incIdx.entries.size 0 scanned
    lostN gainedN lostOwners.size gainedOwners.size staleLost.size staleMoved.size stale
    (witnesses.extract 0 witnessesInSummary)
  match jsonOut with
  | some p => IO.FS.writeFile p (body ++ "\n")
  | none => pure ()
  match printSet with
  | some p =>
    -- `write_text`: no line at all when there are no names, because the
    -- pipeline hands this to `--only-from` where empty means "render nothing".
    IO.FS.writeFile p
      (if stale.isEmpty then "" else String.intercalate "\n" stale.toList ++ "\n")
  | none => pure ()
  IO.println s!"ownership: {lostN} name(s) lost, {gainedN} gained across \
    {incIdx.entries.size} re-extracted module(s) -> {stale.size} module(s) need re-extraction"
  IO.println (reads.report baseIdx.entries.size)
  return 0

/-! ## merge

`crates/litedoc4-incr/src/merge.rs`. The extractor writes a *complete* tree for
whatever module list it was given, so a one-module run misfiles the package's
other modules as dependencies: `deps/*.json` cannot be merged, only recomputed
from the merged module files — which is where this stage's full read comes from.

Every order here is the one Lean's from-scratch writer would have produced: each
`deps/<Root>.json` is sorted by `String` comparison (code point order, `byteLt`),
and so is `dependencyMaps`. -/

def moduleRoot (m : String) : String := (components m)[0]!

def copyFile (from_ to : FilePath) : IO Unit := do
  IO.FS.writeBinFile to (← IO.FS.readBinFile from_)

def depChunk (outDir : FilePath) (own : Std.HashSet String) (chunk : Array IdxEntry) :
    IO (Std.HashMap String String × Nat) := do
  let mut dep : Std.HashMap String String := Std.HashMap.emptyWithCapacity 1024
  let mut decls := 0
  for e in chunk do
    let m ← readModuleFile (outDir / e.file)
    decls := decls + m.decls.size
    for d in m.decls do
      for (owner, name) in d.refs do
        if !own.contains owner then dep := dep.insert name owner
  return (dep, decls)

/-- The lower of two `schemaVersion`s, keeping the base's whenever the two
cannot be compared as numbers: a tree without the key is a schema-1 file, and
answering with the incremental tree's number would invent a claim the base never
made. -/
def weakestSchema : Option JVal → Option JVal → Option JVal
  | some b, some i => match b, i with
    | .num nb, .num ni => if ni < nb then some i else some b
    | _, _ => some b
  | b, _ => b

def runMerge (baseDir incDir outDir : FilePath) (changedOut : Option FilePath)
    (workers : Nat) : IO UInt32 := do
  let baseIdx ← timeIt "index.read" do
    let i ← readIndex baseDir
    return (i, i.entries.size)
  let incIdx ← readIndex incDir
  let mut reads : Reads := { index := 2 }
  let incSchema := jget incIdx.raw "schemaVersion"

  let mut entries : Std.HashMap String IdxEntry :=
    Std.HashMap.emptyWithCapacity (baseIdx.entries.size * 2)
  let mut order : Array String := Array.mkEmpty baseIdx.entries.size
  for e in baseIdx.entries do
    order := order.push e.module
    entries := entries.insert e.module e

  IO.FS.createDirAll (outDir / "modules")
  IO.FS.createDirAll (outDir / "deps")
  let inInc := incIdx.entries.foldl (fun (s : Std.HashSet String) e => s.insert e.module)
    (Std.HashSet.emptyWithCapacity 16)
  let inPlace ← (do
    try
      let a ← IO.FS.realPath baseDir
      let b ← IO.FS.realPath outDir
      return a == b
    catch _ => return false)

  let copied ← timeIt s!"modules.copy.{workers}" do
    if inPlace then return (0, 0)
    let carry := baseIdx.entries.filter (fun e => !inInc.contains e.module)
    let parts ← spread carry workers fun chunk => do
      for e in chunk do copyFile (baseDir / e.file) (outDir / e.file)
      return chunk.size
    return (parts.foldl (· + ·) 0, parts.foldl (· + ·) 0)

  let mut updated : Array String := #[]
  let mut irChanged : Array String := #[]
  for e in incIdx.entries do
    copyFile (incDir / e.file) (outDir / e.file)
    match entries.get? e.module with
    | none =>
      order := order.push e.module
      irChanged := irChanged.push e.module
    | some was => if was.contentHash != e.contentHash then irChanged := irChanged.push e.module
    entries := entries.insert e.module e
    updated := updated.push e.module
  let entriesMap := entries
  let orderList := order

  let own := orderList.foldl (fun (s : Std.HashSet String) m => s.insert m)
    (Std.HashSet.emptyWithCapacity (orderList.size * 2))
  let merged := orderList.map (fun m => (entriesMap.get? m).getD {})
  let deps ← timeIt s!"deps.scan.{workers}" do
    let parts ← spread merged workers (depChunk outDir own)
    -- Chunk by chunk in order: each chunk's own last-writer-wins fold, applied
    -- in order, is the sequential fold.
    let mut dep : Std.HashMap String String := Std.HashMap.emptyWithCapacity 2048
    let mut decls := 0
    for (m, n) in parts do
      for (k, v) in m.toArray do dep := dep.insert k v
      decls := decls + n
    return ((dep, decls), dep.size)
  let (dep, declarations) := deps
  reads := { reads with module := reads.module + merged.size }

  let sorted := dep.toArray.qsort (fun a b => byteLt a.1 b.1)
  let mut roots : Array String := #[]
  let mut byRoot : Std.HashMap String (Array (String × String)) := Std.HashMap.emptyWithCapacity 16
  for (name, m) in sorted do
    let r := moduleRoot m
    if !byRoot.contains r then roots := roots.push r
    byRoot := byRoot.insert r ((byRoot.getD r #[]).push (name, m))
  let rootList := roots.qsort byteLt
  let schema := weakestSchema (jget baseIdx.raw "schemaVersion") incSchema

  let mut depMaps : Array JVal := #[]
  let mut kept : Std.HashSet String := Std.HashSet.emptyWithCapacity 16
  for root in rootList do
    let ds := byRoot.getD root #[]
    let mut body := "{\"declarations\":{"
    let mut first := true
    for (name, m) in ds do
      if !first then body := body ++ ","
      first := false
      body := (quoted body name) ++ ":"
      body := quoted body m
    body := body ++ "},\"package\":" ++ (quoted "" root)
    if let some sv := schema then
      body := body ++ ",\"schemaVersion\":" ++ writeJson "" sv
    body := body ++ "}"
    let file := "deps/" ++ root ++ ".json"
    IO.FS.writeFile (outDir / file) body
    kept := kept.insert file
    depMaps := depMaps.push (.obj #[("bytes", .num (Int.ofNat body.utf8ByteSize)),
      ("entries", .num (Int.ofNat ds.size)), ("file", .str file), ("package", .str root)])

  let listing ← (outDir / "deps").readDir
  let mut stale : Array String := #[]
  for f in listing do
    let rel := "deps/" ++ f.fileName
    if !kept.contains rel then stale := stale.push rel
  for rel in stale.qsort byteLt do IO.FS.removeFile (outDir / rel)

  let mut index := baseIdx.raw
  if let some sv := schema then
    index := jset index "schemaVersion" sv
  index := jset index "moduleCount" (.num (Int.ofNat orderList.size))
  index := jset index "declarationCount" (.num (Int.ofNat declarations))
  index := jset index "modules" (.arr (merged.map (·.raw)))
  index := jset index "dependencyMaps" (.arr depMaps)
  IO.FS.writeFile (outDir / "index.json") (writeJson "" index)

  if let some p := changedOut then
    IO.FS.writeFile p
      (if irChanged.isEmpty then "" else String.intercalate "\n" irChanged.toList ++ "\n")
  IO.println s!"merged {updated.size} module(s) into {orderList.size}: carried {copied}, \
    dependency entries {dep.size} over {rootList.size} package(s), declarations {declarations}"
  IO.println (reads.report baseIdx.entries.size)
  return 0

/-! ## Driver -/

structure Flags where
  ir : FilePath := "."
  base : FilePath := "."
  inc : FilePath := "."
  out : FilePath := "."
  changed : Array String := #[]
  mode : String := "importers"
  printSet : Option FilePath := none
  json : Option FilePath := none
  changedOut : Option FilePath := none
  workers : Nat := 1
  slim : Bool := false
  deriving Inhabited

def parseFlags : List String → Flags → Option Flags
  | [], f => some f
  | "--ir" :: v :: t, f => parseFlags t { f with ir := v }
  | "--base" :: v :: t, f => parseFlags t { f with base := v }
  | "--inc" :: v :: t, f => parseFlags t { f with inc := v }
  | "--out" :: v :: t, f => parseFlags t { f with out := v }
  | "--changed" :: v :: t, f => parseFlags t { f with changed := f.changed.push v }
  | "--mode" :: v :: t, f => parseFlags t { f with mode := v }
  | "--print-set" :: v :: t, f => parseFlags t { f with printSet := some v }
  | "--json" :: v :: t, f => parseFlags t { f with json := some v }
  | "--changed-out" :: v :: t, f => parseFlags t { f with changedOut := some v }
  | "--par" :: v :: t, f => parseFlags t { f with workers := v.toNat! }
  | "--slim" :: t, f => parseFlags t { f with slim := true }
  | _, _ => none

def usage : IO UInt32 := do
  IO.eprintln "usage: incr impact    --ir D --changed M --mode all --print-set F [--json F] [--par N]"
  IO.eprintln "       incr ownership --base D --inc D --print-set F [--json F] [--par N]"
  IO.eprintln "       incr merge     --base D --inc D --out D [--changed-out F] [--par N]"
  return 2

def main (args : List String) : IO UInt32 := do
  match args with
  | cmd :: rest =>
    match parseFlags rest {} with
    | none => usage
    | some f =>
      if cmd == "impact" then runImpact f.ir f.changed f.mode f.printSet f.json f.workers f.slim
      else if cmd == "ownership" then runOwnership f.base f.inc f.printSet f.json f.workers
      else if cmd == "merge" then runMerge f.base f.inc f.out f.changedOut f.workers
      else usage
  | _ => usage
