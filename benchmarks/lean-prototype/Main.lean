/-
Micro-benchmarks for the pure-Lean replacement study.

What is measured is the floor: what Lean pays to read the IR, parse it, parse
the link index, look names up in it, build the HTML strings and write the pages,
with none of the rendering logic in it. A renderer written in Lean cannot beat
this.

**Every phase returns a number computed inside `IO`.** A `timeIt` over
`pure (f x)` measures the cost of allocating a thunk — 1 microsecond — and not
the work; the first version of this file did exactly that and reported
`lidx.parse 0.000001`.

Where a phase has a faster candidate, the slow original stays next to it and
both run in the same process, so no two numbers come from different runs. Each
candidate is checked against the original inside the program — the link index
map entry by entry, the IR by a digest of every node — and the program fails
loudly when they disagree. A parser that is faster because it parses less is not
a result.

Modes:
  bench <dir>                  every phase and every candidate, one process
  bench <dir> --floor N        the best candidate of each phase and nothing
                               else, so the process wall clock means something
  bench <dir> --par N          read + parse the IR with `Lean.Json`, N workers
  bench <dir> --par2 N         the same with the hand-written parser
  bench <dir> --lookup split|scan
                               lookups in a process holding one map and nothing
                               else, since the phase moves by 40% with the heap
-/
import Lean.Data.Json
import Std.Data.HashMap

open Lean System

/-- The phase's result is forced by being a `Nat` the caller prints. -/
def timeIt (label : String) (act : IO (α × Nat)) : IO α := do
  let t0 ← IO.monoNanosNow
  let (a, n) ← act
  let t1 ← IO.monoNanosNow
  IO.println s!"{label}\t{(Float.ofNat (t1 - t0)) / 1e9}\t{n}"
  return a

def jsonFilesIn (dir : FilePath) : IO (Array FilePath) := do
  let entries ← dir.readDir
  let files := entries.filterMap fun e =>
    if e.fileName.endsWith ".json" then some e.path else none
  return files.qsort (·.toString < ·.toString)

/-! ## Byte access

`String.getUTF8Byte` is `lean_string_get_byte_fast`, so this is a load and not a
UTF-8 decode. Reading through `ByteArray` instead would need `String.toByteArray`,
which copies the whole string. -/

@[inline] def byteAt (s : String) (i : Nat) : UInt8 :=
  if h : (⟨i⟩ : String.Pos.Raw) < s.rawEndPos then s.getUTF8Byte ⟨i⟩ h else 0

/-- One `memcpy` into a fresh string; `lean_string_utf8_extract`. -/
@[inline] def byteSub (s : String) (a b : Nat) : String :=
  String.Pos.Raw.extract s ⟨a⟩ ⟨b⟩

/-! ## Link index -/

structure LidxEntry where
  module : String
  startLine : Nat
  endLine : Nat
  deriving Inhabited

/-- The `.lidx` reader, in the shape `crates/litedoc4-render/src/link_index.rs`
describes: line-oriented, first byte decides, no error path. Written in `IO` so
the timer sees the work rather than a thunk. -/
def parseLidxSplit (text : String) : IO (Std.HashMap String LidxEntry) := do
  let mut map : Std.HashMap String LidxEntry := {}
  let mut group := ""
  for line in text.splitOn "\n" do
    if line.isEmpty then continue
    let c := String.Pos.Raw.get line 0
    if c == '#' then continue
    else if c == '@' then
      let m := (line.drop 1).toString
      map := map.insert m { module := m, startLine := 0, endLine := 0 }
    else if c == '\t' then
      match (line.drop 1).toString.splitOn "\t" with
      | [name] => map := map.insert name { module := group, startLine := 0, endLine := 0 }
      | [name, s, e] =>
        map := map.insert name
          { module := group, startLine := s.toNat!, endLine := e.toNat! }
      | name :: _ => map := map.insert name { module := group, startLine := 0, endLine := 0 }
      | [] => pure ()
    else
      group := line
  return map

@[inline] def digitsAt (s : String) (a b : Nat) : Nat := Id.run do
  let mut acc := 0
  let mut i := a
  while i < b do
    acc := acc * 10 + (byteAt s i).toNat - 48
    i := i + 1
  return acc

/-- Same reader over the bytes of one string. The only allocation per entry is
the key itself. `capacity` is the bucket count handed to the map up front. -/
def parseLidxScan (text : String) (capacity : Nat) : IO (Std.HashMap String LidxEntry) := do
  let n := text.utf8ByteSize
  let mut map : Std.HashMap String LidxEntry := Std.HashMap.emptyWithCapacity capacity
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
        let m := byteSub text (a + 1) j
        map := map.insert m { module := m, startLine := 0, endLine := 0 }
      else if c == 9 then
        let mut t1 := a + 1
        while t1 < j && byteAt text t1 != 9 do
          t1 := t1 + 1
        let name := byteSub text (a + 1) t1
        if t1 >= j then
          map := map.insert name { module := group, startLine := 0, endLine := 0 }
        else
          let mut t2 := t1 + 1
          while t2 < j && byteAt text t2 != 9 do
            t2 := t2 + 1
          if t2 >= j then
            map := map.insert name { module := group, startLine := 0, endLine := 0 }
          else
            let mut t3 := t2 + 1
            while t3 < j && byteAt text t3 != 9 do
              t3 := t3 + 1
            if t3 >= j then
              map := map.insert name
                { module := group
                  startLine := digitsAt text (t1 + 1) t2
                  endLine := digitsAt text (t2 + 1) j }
            else
              map := map.insert name { module := group, startLine := 0, endLine := 0 }
      else
        group := byteSub text a j
    i := j + 1
  return map

/-! The scan decomposed. `raw` walks the lines and tabs and touches nothing
else; `nums` adds the two integers per entry; `keys` adds the key strings.
Subtracting each from the next says where `lidx.parse2.cap` spends its time. -/

def scanLidxRaw (text : String) : IO (Nat × Nat) := do
  let n := text.utf8ByteSize
  let mut entries := 0
  let mut acc := 0
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
        entries := entries + 1
        acc := acc + (j - a - 1)
      else if c == 9 then
        let mut t1 := a + 1
        while t1 < j && byteAt text t1 != 9 do
          t1 := t1 + 1
        entries := entries + 1
        acc := acc + (t1 - a - 1)
        if t1 < j then
          let mut t2 := t1 + 1
          while t2 < j && byteAt text t2 != 9 do
            t2 := t2 + 1
          if t2 < j then
            let mut t3 := t2 + 1
            while t3 < j && byteAt text t3 != 9 do
              t3 := t3 + 1
            acc := acc + t3
      else
        acc := acc + (j - a)
    i := j + 1
  return (entries, acc)

def scanLidxNums (text : String) : IO (Nat × Nat) := do
  let n := text.utf8ByteSize
  let mut entries := 0
  let mut acc := 0
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
        entries := entries + 1
        acc := acc + (j - a - 1)
      else if c == 9 then
        let mut t1 := a + 1
        while t1 < j && byteAt text t1 != 9 do
          t1 := t1 + 1
        entries := entries + 1
        acc := acc + (t1 - a - 1)
        if t1 < j then
          let mut t2 := t1 + 1
          while t2 < j && byteAt text t2 != 9 do
            t2 := t2 + 1
          if t2 < j then
            let mut t3 := t2 + 1
            while t3 < j && byteAt text t3 != 9 do
              t3 := t3 + 1
            if t3 >= j then
              acc := acc + digitsAt text (t1 + 1) t2 + digitsAt text (t2 + 1) j
      else
        acc := acc + (j - a)
    i := j + 1
  return (entries, acc)

def scanLidxKeys (text : String) : IO (Nat × Nat) := do
  let n := text.utf8ByteSize
  let mut entries := 0
  let mut acc := 0
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
        entries := entries + 1
        acc := acc + (byteSub text (a + 1) j).utf8ByteSize
      else if c == 9 then
        let mut t1 := a + 1
        while t1 < j && byteAt text t1 != 9 do
          t1 := t1 + 1
        entries := entries + 1
        acc := acc + (byteSub text (a + 1) t1).utf8ByteSize
        if t1 < j then
          let mut t2 := t1 + 1
          while t2 < j && byteAt text t2 != 9 do
            t2 := t2 + 1
          if t2 < j then
            let mut t3 := t2 + 1
            while t3 < j && byteAt text t3 != 9 do
              t3 := t3 + 1
            if t3 >= j then
              acc := acc + digitsAt text (t1 + 1) t2 + digitsAt text (t2 + 1) j
      else
        group := byteSub text a j
        acc := acc + group.utf8ByteSize
    i := j + 1
  return (entries, acc)

/-- The same scan reading the bytes out of a `ByteArray` instead of the
`String`. The conversion is inside the phase because that is what it costs; the
keys still come from the `String`, since building them from the `ByteArray`
would mean a second copy and a UTF-8 validation each. -/
def parseLidxBA (text : String) (capacity : Nat) : IO (Std.HashMap String LidxEntry) := do
  let ba := text.toByteArray
  let n := ba.size
  let mut map : Std.HashMap String LidxEntry := Std.HashMap.emptyWithCapacity capacity
  let mut group := ""
  let mut i := 0
  while i < n do
    let a := i
    let mut j := a
    while j < n && ba.get! j != 10 do
      j := j + 1
    if a < j then
      let c := ba.get! a
      if c == 35 then
        pure ()
      else if c == 64 then
        let m := byteSub text (a + 1) j
        map := map.insert m { module := m, startLine := 0, endLine := 0 }
      else if c == 9 then
        let mut t1 := a + 1
        while t1 < j && ba.get! t1 != 9 do
          t1 := t1 + 1
        let name := byteSub text (a + 1) t1
        if t1 >= j then
          map := map.insert name { module := group, startLine := 0, endLine := 0 }
        else
          let mut t2 := t1 + 1
          while t2 < j && ba.get! t2 != 9 do
            t2 := t2 + 1
          if t2 >= j then
            map := map.insert name { module := group, startLine := 0, endLine := 0 }
          else
            let mut t3 := t2 + 1
            while t3 < j && ba.get! t3 != 9 do
              t3 := t3 + 1
            if t3 >= j then
              map := map.insert name
                { module := group
                  startLine := digitsAt text (t1 + 1) t2
                  endLine := digitsAt text (t2 + 1) j }
            else
              map := map.insert name { module := group, startLine := 0, endLine := 0 }
      else
        group := byteSub text a j
    i := j + 1
  return map

/-- The map with a tagged `Nat` in place of the `LidxEntry` object: the module
becomes an index into a side array and the two line numbers are bit-packed. -/
def parseLidxPacked (text : String) (capacity : Nat) :
    IO (Std.HashMap String Nat × Array String) := do
  let n := text.utf8ByteSize
  let mut map : Std.HashMap String Nat := Std.HashMap.emptyWithCapacity capacity
  let mut groups : Array String := #[]
  let mut g := 0
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
        let m := byteSub text (a + 1) j
        groups := groups.push m
        map := map.insert m ((groups.size - 1) <<< 40)
      else if c == 9 then
        let mut t1 := a + 1
        while t1 < j && byteAt text t1 != 9 do
          t1 := t1 + 1
        let name := byteSub text (a + 1) t1
        if t1 >= j then
          map := map.insert name (g <<< 40)
        else
          let mut t2 := t1 + 1
          while t2 < j && byteAt text t2 != 9 do
            t2 := t2 + 1
          if t2 >= j then
            map := map.insert name (g <<< 40)
          else
            let mut t3 := t2 + 1
            while t3 < j && byteAt text t3 != 9 do
              t3 := t3 + 1
            if t3 >= j then
              map := map.insert name
                ((g <<< 40) ||| (digitsAt text (t1 + 1) t2 <<< 20) ||| digitsAt text (t2 + 1) j)
            else
              map := map.insert name (g <<< 40)
      else
        groups := groups.push (byteSub text a j)
        g := groups.size - 1
    i := j + 1
  return (map, groups)

/-- Same shape as `parseLidxPacked` with the bit twiddling removed, to say
whether the packing or the `Nat` value is what costs. -/
def parseLidxNatVal (text : String) (capacity : Nat) : IO (Std.HashMap String Nat) := do
  let n := text.utf8ByteSize
  let mut map : Std.HashMap String Nat := Std.HashMap.emptyWithCapacity capacity
  let mut g := 0
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
        map := map.insert (byteSub text (a + 1) j) g
      else if c == 9 then
        let mut t1 := a + 1
        while t1 < j && byteAt text t1 != 9 do
          t1 := t1 + 1
        map := map.insert (byteSub text (a + 1) t1) g
      else
        g := g + 1
    i := j + 1
  return map

def assertSameLidx (what : String) (a b : Std.HashMap String LidxEntry) : IO Unit := do
  if a.size != b.size then
    throw (IO.userError s!"{what}: size {a.size} vs {b.size}")
  for (k, v) in a.toArray do
    match b.get? k with
    | none => throw (IO.userError s!"{what}: key missing: {k}")
    | some w =>
      if v.module != w.module || v.startLine != w.startLine || v.endLine != w.endLine then
        throw (IO.userError
          s!"{what}: {k}: {v.module}/{v.startLine}/{v.endLine} vs {w.module}/{w.startLine}/{w.endLine}")

/-! ## IR

`Lean.Json.parse` builds `Std.TreeMap.Raw String Json` per object and a
`JsonNumber` (`Int` mantissa + `Nat` exponent) per number, and reads strings one
`String.push` at a time. `JVal` below keeps the same information — nothing is
dropped — in an array of pairs, an `Int`, and one `memcpy` per string. -/

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

/-- Returns the position of the closing quote and whether a backslash was seen.
`i` is just past the opening quote. Skipping 2 after a backslash is safe for
every JSON escape: none of the payload bytes of `\uXXXX` is a quote or a
backslash. -/
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

/-- `i` is just past the opening quote. Returns the string and the position just
past the closing quote. -/
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

/-! The same parser with every `skipWs` removed. litedoc4's own extractor emits
compact JSON, so this is the shape a renderer would actually meet; it stops
being a JSON parser the moment anything else produces the file. -/

mutual

partial def qVal (s : String) (n i : Nat) : JVal × Nat :=
  let c := byteAt s i
  if c == 123 then qObj s n (i + 1) (Array.mkEmpty 24)
  else if c == 91 then qArr s n (i + 1) (Array.mkEmpty 8)
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

partial def qArr (s : String) (n i : Nat) (acc : Array JVal) : JVal × Nat :=
  if byteAt s i == 93 then (.arr acc, i + 1)
  else
    let (v, i) := qVal s n i
    let acc := acc.push v
    let c := byteAt s i
    if c == 44 then qArr s n (i + 1) acc
    else if c == 93 then (.arr acc, i + 1)
    else panic! s!"array: unexpected byte {c} at {i}"

partial def qObj (s : String) (n i : Nat) (acc : Array (String × JVal)) : JVal × Nat :=
  if byteAt s i == 125 then (.obj acc, i + 1)
  else
    let (k, i) := readStr s n (i + 1)
    let (v, i) := qVal s n (i + 1)
    let acc := acc.push (k, v)
    let c := byteAt s i
    if c == 44 then qObj s n (i + 1) acc
    else if c == 125 then (.obj acc, i + 1)
    else panic! s!"object: unexpected byte {c} at {i}"

end

/-- The structural floor: walk the bytes, build nothing. -/
partial def skipScalar (s : String) (n i : Nat) : Nat :=
  if i < n && byteAt s i != 44 && byteAt s i != 93 && byteAt s i != 125 then
    skipScalar s n (i + 1)
  else i

mutual

partial def skipVal (s : String) (n i : Nat) : Nat :=
  let c := byteAt s i
  if c == 34 then (scanStrEnd s n (i + 1) false).1 + 1
  else if c == 91 then skipArr s n (i + 1)
  else if c == 123 then skipObj s n (i + 1)
  else skipScalar s n i

partial def skipArr (s : String) (n i : Nat) : Nat :=
  let i := skipWs s n i
  if byteAt s i == 93 then i + 1
  else
    let i := skipWs s n (skipVal s n i)
    let c := byteAt s i
    if c == 44 then skipArr s n (i + 1)
    else if c == 93 then i + 1
    else panic! s!"array: unexpected byte {c} at {i}"

partial def skipObj (s : String) (n i : Nat) : Nat :=
  let i := skipWs s n i
  if byteAt s i == 125 then i + 1
  else
    let ke := (scanStrEnd s n (i + 1) false).1
    let i := skipWs s n (skipVal s n (skipWs s n (ke + 2)))
    let c := byteAt s i
    if c == 44 then skipObj s n (i + 1)
    else if c == 125 then i + 1
    else panic! s!"object: unexpected byte {c} at {i}"

end

/-- `i` is at the first element of a non-empty array. Returns the element count
and the position just past the `]`. -/
partial def countArr (s : String) (n i : Nat) (acc : Nat) : Nat × Nat :=
  let i := skipVal s n i
  let acc := acc + 1
  let i := skipWs s n i
  let c := byteAt s i
  if c == 44 then countArr s n (skipWs s n (i + 1)) acc
  else if c == 93 then (acc, i + 1)
  else panic! s!"declarations: unexpected byte {c} at {i}"

/-- `i` is at a key of the top-level object. -/
partial def topScan (s : String) (n i : Nat) (acc : Nat) : Nat :=
  let i := skipWs s n i
  if byteAt s i == 125 then acc
  else
    let (k, i1) := readStr s n (i + 1)
    let i2 := skipWs s n (i1 + 1)
    let (acc, i3) :=
      if k == "declarations" then
        if byteAt s i2 != 91 then panic! "declarations is not an array"
        else
          let j := skipWs s n (i2 + 1)
          if byteAt s j == 93 then (acc, j + 1) else countArr s n j acc
      else (acc, skipVal s n i2)
    let i4 := skipWs s n i3
    let c := byteAt s i4
    if c == 44 then topScan s n (skipWs s n (i4 + 1)) acc
    else if c == 125 then acc
    else panic! s!"top: unexpected byte {c} at {i4}"

/-- Counts the elements of the top-level `declarations` array without keeping
any of them. -/
partial def countDecls (s : String) : Nat :=
  let n := s.utf8ByteSize
  let i := skipWs s n 0
  if byteAt s i != 123 then panic! "top level is not an object"
  else topScan s n (i + 1) 0

end JScan

/-- Order-independent digest of a parsed document. Two parsers agree only if
every one of these five numbers agrees. -/
structure Digest where
  nodes : Nat := 0
  strBytes : Nat := 0
  numSum : Int := 0
  trues : Nat := 0
  nulls : Nat := 0
  deriving Inhabited, BEq

def Digest.show (d : Digest) : String :=
  s!"nodes={d.nodes} strBytes={d.strBytes} numSum={d.numSum} trues={d.trues} nulls={d.nulls}"

partial def digestJson (j : Json) (acc : Digest) : Digest :=
  match j with
  | .null => { acc with nodes := acc.nodes + 1, nulls := acc.nulls + 1 }
  | .bool b => { acc with nodes := acc.nodes + 1, trues := acc.trues + (if b then 1 else 0) }
  | .num v =>
    if v.exponent != 0 then panic! "IR has a non-integer number"
    else { acc with nodes := acc.nodes + 1, numSum := acc.numSum + v.mantissa }
  | .str v => { acc with nodes := acc.nodes + 1, strBytes := acc.strBytes + v.utf8ByteSize }
  | .arr a => a.foldl (fun acc x => digestJson x acc) { acc with nodes := acc.nodes + 1 }
  | .obj m =>
    m.foldl (fun acc k v =>
      digestJson v { acc with nodes := acc.nodes + 1, strBytes := acc.strBytes + k.utf8ByteSize })
      { acc with nodes := acc.nodes + 1 }

partial def digestJVal (j : JVal) (acc : Digest) : Digest :=
  match j with
  | .null => { acc with nodes := acc.nodes + 1, nulls := acc.nulls + 1 }
  | .bool b => { acc with nodes := acc.nodes + 1, trues := acc.trues + (if b then 1 else 0) }
  | .num v => { acc with nodes := acc.nodes + 1, numSum := acc.numSum + v }
  | .str v => { acc with nodes := acc.nodes + 1, strBytes := acc.strBytes + v.utf8ByteSize }
  | .arr a => a.foldl (fun acc x => digestJVal x acc) { acc with nodes := acc.nodes + 1 }
  | .obj a =>
    a.foldl (fun acc kv =>
      digestJVal kv.2 { acc with nodes := acc.nodes + 1, strBytes := acc.strBytes + kv.1.utf8ByteSize })
      { acc with nodes := acc.nodes + 1 }

def declCountJson (j : Json) : Nat :=
  match j.getObjValAs? (Array Json) "declarations" with
  | .ok ds => ds.size
  | .error _ => 0

def declCountJVal (j : JVal) : Nat :=
  match j with
  | .obj a =>
    match a.find? (fun kv => kv.1 == "declarations") with
    | some (_, .arr ds) => ds.size
    | _ => 0
  | _ => 0

/-! ## Parallel read + parse -/

def chunkArray (xs : Array α) (parts : Nat) : Array (Array α) := Id.run do
  let parts := max 1 parts
  let mut out : Array (Array α) := Array.mkEmpty parts
  let mut i := 0
  for p in [0:parts] do
    let stop := (xs.size * (p + 1)) / parts
    out := out.push (xs.extract i stop)
    i := stop
  return out

def readParseLean (files : Array FilePath) : IO Nat := do
  let mut decls := 0
  for f in files do
    let c ← IO.FS.readFile f
    match Json.parse c with
    | .ok j => decls := decls + declCountJson j
    | .error e => throw (IO.userError s!"parse: {e}")
  return decls

def readParseScan (files : Array FilePath) : IO Nat := do
  let mut decls := 0
  for f in files do
    let c ← IO.FS.readFile f
    let (j, _) := JScan.pVal c c.utf8ByteSize (JScan.skipWs c c.utf8ByteSize 0)
    decls := decls + declCountJVal j
  return decls

def runParallel (files : Array FilePath) (workers : Nat) (body : Array FilePath → IO Nat) :
    IO Nat := do
  let chunks := chunkArray files workers
  let tasks ← chunks.mapM fun ch => IO.asTask (body ch) Task.Priority.dedicated
  let mut total := 0
  for t in tasks do
    match ← IO.wait t with
    | .ok k => total := total + k
    | .error e => throw e
  return total

/-! ## Main -/

def runAll (w : FilePath) : IO UInt32 := do
  let irModules := w / "ir" / "modules"
  let linkIndex := w / "link-index.json"

  let files ← jsonFilesIn irModules
  let contents ← timeIt "ir.read" do
    let mut acc : Array String := #[]
    let mut bytes := 0
    for f in files do
      let c ← IO.FS.readFile f
      bytes := bytes + c.utf8ByteSize
      acc := acc.push c
    return (acc, bytes)

  let parsed ← timeIt "ir.parse" do
    let mut acc : Array Json := #[]
    let mut decls := 0
    for c in contents do
      match Json.parse c with
      | .ok j =>
        -- forced: reaching into the parsed value is what makes the parser run
        decls := decls + declCountJson j
        acc := acc.push j
      | .error e => throw (IO.userError s!"parse: {e}")
    return (acc, decls)

  let scanned ← timeIt "ir.scan" do
    let mut decls := 0
    for c in contents do
      decls := decls + JScan.countDecls c
    return (decls, decls)

  let parsed2 ← timeIt "ir.parse2" do
    let mut acc : Array JVal := #[]
    let mut decls := 0
    for c in contents do
      let n := c.utf8ByteSize
      let (j, e) := JScan.pVal c n (JScan.skipWs c n 0)
      if JScan.skipWs c n e != n then
        throw (IO.userError s!"parse2: stopped at {e} of {n}")
      decls := decls + declCountJVal j
      acc := acc.push j
    return (acc, decls)

  let parsed3 ← timeIt "ir.parse3" do
    let mut acc : Array JVal := #[]
    let mut decls := 0
    for c in contents do
      let n := c.utf8ByteSize
      let (j, e) := JScan.qVal c n 0
      if e != n then
        throw (IO.userError s!"parse3: stopped at {e} of {n}")
      decls := decls + declCountJVal j
      acc := acc.push j
    return (acc, decls)

  let mut digA : Digest := {}
  for j in parsed do
    digA := digestJson j digA
  let mut digB : Digest := {}
  for j in parsed2 do
    digB := digestJVal j digB
  if digA != digB then
    throw (IO.userError s!"ir digest differs:\n  Lean.Json {digA.show}\n  JScan     {digB.show}")
  let mut digC : Digest := {}
  for j in parsed3 do
    digC := digestJVal j digC
  if digA != digC then
    throw (IO.userError s!"ir digest differs:\n  Lean.Json {digA.show}\n  JScan/qVal {digC.show}")
  if scanned != 4584 then
    throw (IO.userError s!"ir.scan counted {scanned} declarations")
  IO.println s!"# ir digest agrees: {digA.show}"

  let liText ← timeIt "lidx.read" do
    let t ← IO.FS.readFile linkIndex
    return (t, t.utf8ByteSize)

  let lidx ← timeIt "lidx.parse" do
    let m ← parseLidxSplit liText
    return (m, m.size)

  let lidx2 ← timeIt "lidx.parse2" do
    let m ← parseLidxScan liText 8
    return (m, m.size)

  let lidx3 ← timeIt "lidx.parse2.cap" do
    let m ← parseLidxScan liText 524288
    return (m, m.size)

  let sRaw ← timeIt "lidx.scan.raw" do
    let (e, b) ← scanLidxRaw liText
    return (e, b)

  let sNums ← timeIt "lidx.scan.nums" do
    let (e, b) ← scanLidxNums liText
    return (e, b)

  let sKeys ← timeIt "lidx.scan.keys" do
    let (e, b) ← scanLidxKeys liText
    return (e, b)

  let lidxBA ← timeIt "lidx.parse2.bytearray" do
    let m ← parseLidxBA liText 524288
    return (m, m.size)

  let lidxP ← timeIt "lidx.parse2.packed" do
    let (m, gs) ← parseLidxPacked liText 524288
    return ((m, gs), m.size)

  let lidxNV ← timeIt "lidx.parse2.natval" do
    let m ← parseLidxNatVal liText 524288
    return (m, m.size)

  if sRaw != sNums || sRaw != sKeys then
    throw (IO.userError s!"lidx scan variants disagree: {sRaw} {sNums} {sKeys}")
  if sRaw < lidx.size then
    throw (IO.userError s!"lidx scan saw fewer entries than the map holds: {sRaw} < {lidx.size}")
  IO.println s!"# lidx lines {sRaw}, distinct keys {lidx.size} ({sRaw - lidx.size} repeated)"
  if lidxNV.size != lidx.size then
    throw (IO.userError s!"lidx.parse2.natval: {lidxNV.size} vs {lidx.size}")
  if lidxP.1.size != lidx.size then
    throw (IO.userError s!"lidx.parse2.packed: {lidxP.1.size} vs {lidx.size}")
  for (k, v) in lidx.toArray do
    match lidxP.1.get? k with
    | none => throw (IO.userError s!"lidx.parse2.packed: key missing: {k}")
    | some p =>
      let m := lidxP.2[p >>> 40]!
      if m != v.module || (p >>> 20) % 1048576 != v.startLine || p % 1048576 != v.endLine then
        throw (IO.userError s!"lidx.parse2.packed: differs at {k}")

  assertSameLidx "lidx.parse2.bytearray" lidx lidxBA
  assertSameLidx "lidx.parse2" lidx lidx2
  assertSameLidx "lidx.parse2.cap" lidx lidx3
  IO.println s!"# lidx agrees: {lidx.size} entries"

  -- `names` are the very string objects the old map stores, so `lean_string_eq`
  -- settles every probe by pointer identity. A renderer looks names up with
  -- strings that came out of the IR, so `namesCopy` is the honest workload and
  -- `names` is kept only because the first version of this file used it.
  let names := lidx.toArray.map (·.1)
  let namesCopy := names.map fun k => String.fromUTF8! k.toByteArray

  let _ ← timeIt "lidx.lookup.ptreq" do
    let mut hits := 0
    for _ in [0:4] do
      for n in names do
        if (lidx.get? n).isSome then hits := hits + 1
    return ((), hits)

  let _ ← timeIt "lidx.lookup" do
    let mut hits := 0
    for _ in [0:4] do
      for n in namesCopy do
        if (lidx.get? n).isSome then hits := hits + 1
    return ((), hits)

  let _ ← timeIt "lidx.lookup2.cap" do
    let mut hits := 0
    for _ in [0:4] do
      for n in namesCopy do
        if (lidx3.get? n).isSome then hits := hits + 1
    return ((), hits)

  let _ ← timeIt "lidx.lookup.again" do
    let mut hits := 0
    for _ in [0:4] do
      for n in namesCopy do
        if (lidx.get? n).isSome then hits := hits + 1
    return ((), hits)

  let built ← timeIt "html.build" do
    let mut pages : Array String := #[]
    let mut bytes := 0
    for _ in [0:422] do
      let mut parts : Array String := #[]
      for i in [0:800] do
        parts := parts.push s!"<div class=\"decl\" id=\"d{i}\"><code>theorem foo{i}</code><p>text</p></div>\n"
      let page := String.join parts.toList
      bytes := bytes + page.utf8ByteSize
      pages := pages.push page
    return (pages, bytes)

  let outDir := w / "lean-bench-pages"
  IO.FS.createDirAll outDir
  let _ ← timeIt "html.write" do
    let mut i := 0
    for p in built do
      IO.FS.writeFile (outDir / s!"p{i}.html") p
      i := i + 1
    return ((), i)
  IO.FS.removeDirAll outDir
  return 0

/-- The floor with the best implementation of every phase and nothing else in
the process, so that the process wall clock is comparable with `litedoc4 render`
and with the first version of this file.

The lookup keys are the keys of a *second* map built by the same parser: equal
in content, not the same objects, so `lean_string_eq` has to compare bytes. A
renderer looks names up with strings that came out of the IR, which is the same
situation. -/
def runFloor (w : FilePath) (workers : Nat) : IO UInt32 := do
  let irModules := w / "ir" / "modules"
  let linkIndex := w / "link-index.json"
  let files ← jsonFilesIn irModules

  if workers > 1 then
    let _ ← timeIt s!"ir.readparse.{workers}" do
      let d ← runParallel files workers readParseScan
      return ((), d)
  else
    let contents ← timeIt "ir.read" do
      let mut acc : Array String := #[]
      let mut bytes := 0
      for f in files do
        let c ← IO.FS.readFile f
        bytes := bytes + c.utf8ByteSize
        acc := acc.push c
      return (acc, bytes)
    let _ ← timeIt "ir.parse" do
      let mut acc : Array JVal := #[]
      let mut decls := 0
      for c in contents do
        let n := c.utf8ByteSize
        let (j, e) := JScan.pVal c n (JScan.skipWs c n 0)
        if JScan.skipWs c n e != n then
          throw (IO.userError s!"parse: stopped at {e} of {n}")
        decls := decls + declCountJVal j
        acc := acc.push j
      return (acc, decls)

  let liText ← timeIt "lidx.read" do
    let t ← IO.FS.readFile linkIndex
    return (t, t.utf8ByteSize)
  let lidx ← timeIt "lidx.parse" do
    let m ← parseLidxScan liText 524288
    return (m, m.size)
  let queries := (← parseLidxScan liText 524288).toArray.map (·.1)
  let _ ← timeIt "lidx.lookup" do
    let mut hits := 0
    for _ in [0:4] do
      for n in queries do
        if (lidx.get? n).isSome then hits := hits + 1
    return ((), hits)

  let built ← timeIt "html.build" do
    let mut pages : Array String := #[]
    let mut bytes := 0
    for _ in [0:422] do
      let mut parts : Array String := #[]
      for i in [0:800] do
        parts := parts.push s!"<div class=\"decl\" id=\"d{i}\"><code>theorem foo{i}</code><p>text</p></div>\n"
      let page := String.join parts.toList
      bytes := bytes + page.utf8ByteSize
      pages := pages.push page
    return (pages, bytes)
  let outDir := w / "lean-bench-pages"
  IO.FS.createDirAll outDir
  let _ ← timeIt "html.write" do
    let mut i := 0
    for p in built do
      IO.FS.writeFile (outDir / s!"p{i}.html") p
      i := i + 1
    return ((), i)
  IO.FS.removeDirAll outDir
  return 0

/-- Lookups measured in a process that has built one map and nothing else.
In `runAll` the same phase moves by 40% depending on how much is already on the
heap, so the numbers there cannot be compared with each other. -/
def runLookup (w : FilePath) (impl : String) : IO UInt32 := do
  let liText ← IO.FS.readFile ((w : FilePath) / "link-index.json")
  let lidx ←
    if impl == "split" then parseLidxSplit liText
    else parseLidxScan liText 524288
  let names := lidx.toArray.map (·.1)
  let namesCopy := names.map fun k => String.fromUTF8! k.toByteArray
  let _ ← timeIt s!"lookup.{impl}.ptreq" do
    let mut hits := 0
    for _ in [0:4] do
      for n in names do
        if (lidx.get? n).isSome then hits := hits + 1
    return ((), hits)
  let _ ← timeIt s!"lookup.{impl}.copy" do
    let mut hits := 0
    for _ in [0:4] do
      for n in namesCopy do
        if (lidx.get? n).isSome then hits := hits + 1
    return ((), hits)
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | [w] => runAll w
  | [w, "--lookup", impl] => runLookup w impl
  | [w, "--floor", k] => runFloor w k.toNat!
  | [w, "--par", k] => do
    let files ← jsonFilesIn ((w : FilePath) / "ir" / "modules")
    let _ ← timeIt s!"par.lean.{k}" do
      let d ← runParallel files k.toNat! readParseLean
      return ((), d)
    return 0
  | [w, "--par2", k] => do
    let files ← jsonFilesIn ((w : FilePath) / "ir" / "modules")
    let _ ← timeIt s!"par.scan.{k}" do
      let d ← runParallel files k.toNat! readParseScan
      return ((), d)
    return 0
  | _ => do
    IO.eprintln "usage: bench <work-dir> [--par N | --par2 N | --floor N | --lookup split|scan]"
    return 2
