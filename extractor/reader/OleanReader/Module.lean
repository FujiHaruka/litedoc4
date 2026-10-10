import OleanReader.Entries
open Lean

namespace OleanReader

structure ReadStats where
  constants : Nat := 0
  entriesDecoded : Nat := 0
  entriesSkipped : Nat := 0
  skippedExts : Std.HashMap Name Nat := {}
  decodedExts : Std.HashMap Name Nat := {}
  names : Nat := 0
  levels : Nat := 0
  exprs : Nat := 0
  theorems : Nat := 0
  proofsDecoded : Nat := 0
  proofsWithoutAxiomList : Nat := 0
  proofsWithSorryAx : Nat := 0
  proofsOmitted : Nat := 0

inductive Proofs where
  | every
  | none
  | whereRead

def decStoredAxiomLists (entries : UInt64) : DM (Std.HashMap Name Bool) := do
  let arr ← obj "Array (Name × Array EnvExtensionEntry)" entries
  unless arr.tag == 246 do fail "ModuleData.entries" entries "expected an Array"
  for i in [0:(u64 arr.b (arr.o + 8)).toNat] do
    let p ← ctor "Name × Array EnvExtensionEntry" (u64 arr.b (arr.o + 24 + 8*i)) 0 2 0
    if (← decName (p.field 0)) == axiomsExtName then
      let lists ← decArray "Array EnvExtensionEntry" (p.field 1)
        (decPair "Name × Array Name" · decName (decArray "Array Name" · decName))
      return lists.foldl (fun m (c, axs) => m.insert c (axs.contains ``sorryAx)) {}
  return {}

def Proofs.keep : Proofs → Std.HashMap Name Bool → Name → Bool
  | .every, _, _ => true
  | .none, _, _ => false
  | .whereRead, hasSorryAx, n => hasSorryAx.getD n true

def countProofs (hasSorryAx : Std.HashMap Name Bool) (constants : Array ConstantInfo) (s : ReadStats) : ReadStats :=
  constants.foldl (init := s) fun s ci =>
    match ci with
    | .thmInfo v =>
      let s := if v.value == omittedProof then { s with proofsOmitted := s.proofsOmitted + 1 }
        else { s with proofsDecoded := s.proofsDecoded + 1 }
      let s := { s with theorems := s.theorems + 1 }
      match hasSorryAx[v.name]? with
      | none => { s with proofsWithoutAxiomList := s.proofsWithoutAxiomList + 1 }
      | some true => { s with proofsWithSorryAx := s.proofsWithSorryAx + 1 }
      | some false => s
    | _ => s

def decModuleData (proofs : Proofs) (decodeEntries : Bool) (v : UInt64) (stats : IO.Ref ReadStats) :
    DM (ModuleData × Array (Name × Array Keyed) × Array Name) := do
  let x ← ctor "ModuleData" v 0 5 1
  let isModule ← decBool "ModuleData.isModule" v (x.sc8 0)
  let imports ← decArray "Array Import" (x.field 0) decImport
  let constNames ← decArray "Array Name" (x.field 1) decName
  let hasSorryAx ← match proofs with
    | .whereRead => decStoredAxiomLists (x.field 4)
    | _ => pure {}
  let constants ← decArray "Array ConstantInfo" (x.field 2) (decConstantInfo (proofs.keep hasSorryAx))
  if let .whereRead := proofs then stats.modify (countProofs hasSorryAx constants)
  let mentioned := (← get).mentioned
  let extraConstNames ← decArray "Array Name" (x.field 3) decName
  let entriesObj ← obj "Array (Name × Array EnvExtensionEntry)" (x.field 4)
  unless entriesObj.tag == 246 do fail "ModuleData.entries" (x.field 4) "expected an Array"
  let n := (u64 entriesObj.b (entriesObj.o + 8)).toNat
  let mut keyedEntries := #[]
  for i in [0:n] do
    let pv := u64 entriesObj.b (entriesObj.o + 24 + 8*i)
    let p ← ctor "Name × Array EnvExtensionEntry" pv 0 2 0
    let extName ← decName (p.field 0)
    let ver := (← read)[0]!.ver
    if ver.absentExts.contains extName.toString then
      fail "ModuleData.entries" pv s!"entries under extension {extName}, which the record for Lean {ver.leanVersion} lists as absent from that writer"
    let arr ← obj "Array EnvExtensionEntry" (p.field 1)
    unless arr.tag == 246 do fail "entries" (p.field 1) "expected an Array"
    let k := (u64 arr.b (arr.o + 8)).toNat
    match decodeEntries, decoderFor extName with
    | true, some f =>
      let es ← decArray "Array EnvExtensionEntry" (p.field 1) f
      keyedEntries := keyedEntries.push (extName, es)
      stats.modify fun s => { s with
        entriesDecoded := s.entriesDecoded + k
        decodedExts := s.decodedExts.insert extName (s.decodedExts.getD extName 0 + k) }
    | _, _ =>
      stats.modify fun s => { s with
        entriesSkipped := s.entriesSkipped + k
        skippedExts := s.skippedExts.insert extName (s.skippedExts.getD extName 0 + k) }
  let entries := keyedEntries.map fun (e, es) => (e, es.map (·.2))
  unless constNames.size == constants.size do fail "ModuleData" v "constNames and constants differ in size"
  for n in constNames, c in constants do
    unless n == c.name do fail "ModuleData" v s!"constNames[i] = {n} but constants[i].name = {c.name}"
  let st ← get
  stats.modify fun s => { s with
    constants := s.constants + constants.size
    names := s.names + st.names.size
    levels := s.levels + st.levels.size
    exprs := s.exprs + st.exprs.size }
  return ({ isModule, imports, constNames, constants, extraConstNames, entries }, keyedEntries, mentioned)

def findOlean (s : Session) (m : Name) : IO System.FilePath := do
  let rel := System.mkFilePath (m.components.map (·.toString (escape := false)))
  for d in s.searchPath do
    let p := (d / rel).addExtension "olean"
    if ← p.pathExists then return p
  throw <| IO.userError s!"olean reader: no .olean for module {m} on the search path"

def loadModule (s : Session) (m : Name) : IO (Array Part) := do
  let f ← findOlean s m
  let main ← loadPart s f
  let server := f.addExtension "server"
  let priv := f.addExtension "private"
  if (← server.pathExists) && (← priv.pathExists) then
    return #[main, ← loadPart s server, ← loadPart s priv]
  else if (← server.pathExists) || (← priv.pathExists) then
    throw <| IO.userError s!"olean reader: {m} has only one of .olean.server / .olean.private"
  else
    return #[main]

def runDM (parts : Array Part) (x : DM α) : IO (α × DState) :=
  (x.run parts).run {}

/-- What `finalizeImport` adds to `const2ModIdx` after a `module`'s constants: its `.ir` part's
`extraConstNames`. -/
def readIRExtraConstNames (s : Session) (m : Name) : IO (Array Name) := do
  let irf := (← findOlean s m).withExtension "ir"
  unless ← irf.pathExists do throw <| IO.userError s!"olean reader: {m} is a module but has no .ir"
  let sig := irf.addExtension "sig"
  let sigParts ← if ← sig.pathExists then pure #[← loadPart s sig] else pure #[]
  let p ← loadPart s irf
  let (ns, _) ← runDM (sigParts.push p) do
    let x ← ctor "ModuleData" p.root 0 5 1
    decArray "Array Name" (x.field 3) decName
  return ns

def readImports (s : Session) (m : Name) : IO (Array Import) := do
  let main ← loadPart s (← findOlean s m)
  let (is, _) ← runDM #[main] do
    let x ← ctor "ModuleData" main.root 0 5 1
    decArray "Array Import" (x.field 0) decImport
  return is

/-- The import closure in the order `importModulesCore` visits it (imports before importers). -/
partial def closure (s : Session) (roots : Array Name) : IO (Array Name) := do
  let seen ← IO.mkRef ({} : NameSet)
  let out ← IO.mkRef (#[] : Array Name)
  let rec go (m : Name) : IO Unit := do
    if (← seen.get).contains m then return
    seen.modify (·.insert m)
    for i in ← readImports s m do go i.module
    out.modify (·.push m)
  for r in roots do go r
  out.get

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

def reducibilityCode : ReducibilityStatus → UInt64
  | .reducible => 1 | .semireducible => 2 | .irreducible => 3 | .implicitReducible => 4
  | .instanceReducible => 5

def writerSeed (w : WriterVersion) : UInt64 :=
  w.reducibility.foldl (fun h r => mixHash h (reducibilityCode r.meaning)) 17

structure ModuleHashes where
  consts : Array UInt64
  entries : Array (Name × Array UInt64)

def hashModule (seed root : UInt64) : DM ModuleHashes := do
  let memo ← IO.mkRef ({} : Std.HashMap UInt64 UInt64)
  let x ← ctor "ModuleData" root 0 5 1
  let cs ← obj "Array ConstantInfo" (x.field 2)
  let n := (u64 cs.b (cs.o + 8)).toNat
  let mut consts := Array.mkEmpty n
  for i in [0:n] do
    consts := consts.push (mixHash seed (← rawHash memo (u64 cs.b (cs.o + 24 + 8*i))))
  let es ← obj "entries" (x.field 4)
  let mut entries := #[]
  for i in [0:(u64 es.b (es.o + 8)).toNat] do
    let p ← ctor "Name × Array EnvExtensionEntry" (u64 es.b (es.o + 24 + 8*i)) 0 2 0
    let e ← decName (p.field 0)
    if (decoderFor e).isNone then continue
    let arr ← obj "Array EnvExtensionEntry" (p.field 1)
    let k := (u64 arr.b (arr.o + 8)).toNat
    let mut hs := Array.mkEmpty k
    for j in [0:k] do
      hs := hs.push (mixHash seed (← rawHash memo (u64 arr.b (arr.o + 24 + 8*j))))
    entries := entries.push (e, hs)
  return { consts, entries }

end OleanReader
