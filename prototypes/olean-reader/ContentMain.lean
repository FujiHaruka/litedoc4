import OleanReader
open Lean OleanReader

/-! Content hashes of every module of `Mathlib`'s closure, from the stored object graph rather than
the file bytes (the header carries the writer's githash): a 64-bit hash per module part, per
constant (its type, its value, the whole `ConstantInfo`) and per extension's entries. Every object
is hashed from its tag, its object fields' hashes and its scalar bytes, so two graphs with the same
content hash the same whatever their addresses. The scalar bytes include a constructor's tail
padding, which Lean's allocator zeroes for this purpose (`lean_alloc_ctor_memory`, lean.h). -/

def readSearchPath (f : System.FilePath) : IO (Array System.FilePath) := do
  return (← IO.FS.lines f).filter (!·.isEmpty) |>.map System.FilePath.mk

def bytesHash (b : ByteArray) (start stop : Nat) (h : UInt64) : UInt64 := Id.run do
  let mut h := h
  let mut i := start
  while i + 8 ≤ stop do
    h := mixHash h (u64 b i); i := i + 8
  while i < stop do
    h := mixHash h (u8 b i).toUInt64; i := i + 1
  return mixHash h (stop - start).toUInt64

partial def rawHash (memo : IO.Ref (Std.HashMap UInt64 UInt64)) (v : UInt64) : DM UInt64 := do
  if isScalar v then return mixHash 1 v
  if let some h := (← memo.get)[v]? then return h
  let x ← obj "object" v
  let h ← if x.tag ≤ 244 then do
      let mut h := mixHash 2 (mixHash x.tag.toUInt64 x.other.toUInt64)
      for i in [0:x.other] do h := mixHash h (← rawHash memo (x.field i))
      pure (bytesHash x.b (x.o + 8 + 8*x.other) (x.o + x.csSz) h)
    else if x.tag == 246 then do
      let n := (u64 x.b (x.o + 8)).toNat
      let mut h := mixHash 3 n.toUInt64
      for i in [0:n] do h := mixHash h (← rawHash memo (u64 x.b (x.o + 24 + 8*i)))
      pure h
    else if x.tag == 248 then
      let n := (u64 x.b (x.o + 8)).toNat
      pure (bytesHash x.b (x.o + 24) (x.o + 24 + n * x.other) (mixHash 4 x.other.toUInt64))
    else if x.tag == 249 then
      let n := (u64 x.b (x.o + 8)).toNat
      pure (bytesHash x.b (x.o + 32) (x.o + 32 + n) 5)
    else if x.tag == 250 then
      let sz := u32 x.b (x.o + 12)
      let limbs := if sz ≥ 0x80000000 then (0 - sz).toNat else sz.toNat
      pure (bytesHash x.b (x.o + 24) (x.o + 24 + 8 * limbs) (mixHash 6 sz.toUInt64))
    else fail "object" v s!"tag {x.tag} is not expected in a compacted module"
  memo.modify (·.insert v h)
  return h

def kindName : Nat → String
  | 0 => "axiom" | 1 => "defn" | 2 => "thm" | 3 => "opaque" | 4 => "quot" | 5 => "induct"
  | 6 => "ctor" | 7 => "rec" | _ => "?"

/-- One module's lines (the file starts with a `D` line per extension the hybrid decodes): `M` module, isModule, parts, hashes of imports / constNames /
extraConstNames, constant count; `C` per constant: name, kind, level params, type, value (`0` if
the kind has none), whole `ConstantInfo`; `E` per extension: name, entry count, entries. -/
def moduleLines (m : Name) (root : UInt64) (nparts : Nat) : DM (Array String) := do
  let memo ← IO.mkRef ({} : Std.HashMap UInt64 UInt64)
  let x ← ctor "ModuleData" root 0 5 1
  let consts ← obj "Array ConstantInfo" (x.field 2)
  let n := (u64 consts.b (consts.o + 8)).toNat
  let mut out := #[s!"M\t{m}\t{x.sc8 0}\t{nparts}\t{← rawHash memo (x.field 0)}\t{← rawHash memo (x.field 1)}\t{← rawHash memo (x.field 3)}\t{n}"]
  for i in [0:n] do
    let cv := u64 consts.b (consts.o + 24 + 8*i)
    let c ← obj "ConstantInfo" cv
    let w ← obj "XVal" (c.field 0)
    let k ← ctor "ConstantVal" (w.field 0) 0 3 0
    let name ← decName (k.field 0)
    let value ← if c.tag == 1 || c.tag == 2 || c.tag == 3 then rawHash memo (w.field 1) else pure 0
    out := out.push s!"C\t{m}\t{name}\t{kindName c.tag}\t{← rawHash memo (k.field 1)}\t{← rawHash memo (k.field 2)}\t{value}\t{← rawHash memo cv}"
  let es ← obj "entries" (x.field 4)
  let ne := (u64 es.b (es.o + 8)).toNat
  for i in [0:ne] do
    let p ← ctor "Name × Array EnvExtensionEntry" (u64 es.b (es.o + 24 + 8*i)) 0 2 0
    let e ← decName (p.field 0)
    let arr ← obj "Array EnvExtensionEntry" (p.field 1)
    out := out.push s!"E\t{m}\t{e}\t{u64 arr.b (arr.o + 8)}\t{← rawHash memo (p.field 1)}"
  return out

def main (args : List String) : IO UInt32 := do
  let [spFile, outPath, limitS] := args
    | IO.eprintln "usage: contenthash <searchpath-file> <out.tsv> <limit|all>"; return 2
  let sp ← readSearchPath spFile
  let t0 ← IO.monoMsNow
  let mods ← closure sp #[`Mathlib]
  let mods := if limitS == "all" then mods else mods.extract 0 limitS.toNat!
  let h ← IO.FS.Handle.mk outPath .write
  for (e, _, _) in entryDecoders do h.putStrLn s!"D\t{e}"
  let mut bytes := 0
  let mut objects := 0
  for m in mods do
    let parts ← loadModule sp m
    let (lines, st) ← runDM parts (moduleLines m parts.back!.root parts.size)
    bytes := bytes + parts.foldl (· + ·.bytes.size) 0
    objects := objects + st.objects
    h.putStr ("\n".intercalate lines.toList ++ "\n")
  h.flush
  let t1 ← IO.monoMsNow
  IO.eprintln s!"writer: Lean {← writerOfClosure.get}; modules {mods.size}, bytes {bytes}, objects visited {objects}; {t1 - t0} ms"
  return 0
