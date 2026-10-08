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

def decModuleData (omitProofs decodeEntries : Bool) (v : UInt64) (stats : IO.Ref ReadStats) :
    DM (ModuleData × Array (Name × Array Keyed)) := do
  let x ← ctor "ModuleData" v 0 5 1
  let isModule ← decBool "ModuleData.isModule" v (x.sc8 0)
  let imports ← decArray "Array Import" (x.field 0) decImport
  let constNames ← decArray "Array Name" (x.field 1) decName
  let constants ← decArray "Array ConstantInfo" (x.field 2) (decConstantInfo omitProofs)
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
  return ({ isModule, imports, constNames, constants, extraConstNames, entries }, keyedEntries)

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

end OleanReader
