import OleanReader.Module
import OleanReader.Serialize
open Lean OleanReader.Serialize

namespace OleanReader

def registeredExts : IO (Array String) := do
  return ((← persistentEnvExtensionsRef.get).map (·.name.toString)).qsort (· < ·)

unsafe def castEntriesUnsafe (α : Type) (es : Array EnvExtensionEntry) : Array α := unsafeCast es

@[implemented_by castEntriesUnsafe]
opaque castEntries (α : Type) (es : Array EnvExtensionEntry) : Array α

structure ReadModule where
  name : Name
  constants : Array ConstantInfo
  entries : Array (Name × Array Keyed)
  deriving Inhabited

def ReadModule.under (rm : ReadModule) (α : Type) (ext : Name) : Array α :=
  castEntries α (((rm.entries.find? (·.1 == ext)).map (·.2.map (·.2))).getD #[])

def ReadModule.keyed (rm : ReadModule) (ext : Name) (n : Name) : Option EnvExtensionEntry :=
  ((rm.entries.find? (·.1 == ext)).bind fun (_, es) => es.find? (·.1 == n)).map (·.2)

def structureExtName : Name := privName `Lean.Structure `Lean.structureExt

def moduleDocExtName : Name := privName `Lean.DocString.Extension `Lean.moduleDocExt

def readClosure (s : Session) (roots : Array Name) (stats : IO.Ref ReadStats) : IO (Array ReadModule) := do
  let mut out := #[]
  for m in ← closure s roots do
    let parts ← loadModule s m
    let ((md, keyed, _), _) ← runDM parts (decModuleData true true parts.back!.root stats)
    out := out.push { name := m, constants := md.constants, entries := keyed }
  return out

def storedIndex (w : WriterVersion) (meaning : ReducibilityStatus) : Nat :=
  (w.reducibility.findIdx? (·.meaning == meaning)).getD w.reducibility.size

unsafe def keyedValueUnsafe (α : Type) [Inhabited α] (e : EnvExtensionEntry) : α := unsafeCast e

@[implemented_by keyedValueUnsafe]
opaque keyedValue (α : Type) [Inhabited α] (e : EnvExtensionEntry) : α

def oracleText (s : Session) (out : IO.FS.Stream) (seed : UInt64) (k? : Option Nat) : IO ReadStats := do
  let stats ← IO.mkRef ({} : ReadStats)
  let mods ← readClosure s #[`Init, `Std, `Lean] stats
  let some (w, _) ← s.firstWriter.get | throw <| IO.userError "olean reader: nothing was read"
  for n in ← registeredExts do out.putStrLn (extLine n (!w.absentExts.contains n))
  let mut all : Array (ReadModule × ConstantInfo) := #[]
  for rm in mods do
    out.putStrLn (moduleLine rm.name rm.constants.size)
    for ci in rm.constants do
      out.putStrLn (constLine ci)
      all := all.push (rm, ci)
  let mut seen : Array Nat := #[]
  for rm in mods do
    for (n, r) in rm.under (Name × ReducibilityStatus) `reducibilityCore do
      let i := storedIndex w r
      out.putStrLn (reducibilityLine rm.name n i)
      unless seen.contains i do seen := seen.push i
    for e in rm.under (ScopedEnvExtension.Entry (Name × ReducibilityStatus)) `reducibilityExtra do
      let (scope, (n, r)) := scopeCode e
      let i := storedIndex w r
      out.putStrLn (reducibilityExtraLine rm.name scope n i)
      unless seen.contains i do seen := seen.push i
  for i in seen.qsort (· < ·) do
    let r := w.reducibility[i]!
    out.putStrLn (statusLine i r.writerName (← unfoldMask r.meaning))
  for rm in mods do
    for e in rm.under (ScopedEnvExtension.Entry Meta.InstanceEntry) `Lean.Meta.instanceExtension do
      let (scope, ie) := scopeCode e
      out.putStrLn (instanceLine rm.name scope ie ie.attrKind.ctorIdx)
  let mut structures : Std.HashMap Name StructureInfo := {}
  for rm in mods do
    for si in rm.under StructureInfo structureExtName do
      structures := structures.insert si.structName si
  for (_, ci) in all do
    if let some si := structures[ci.name]? then out.putStrLn (structureLine si)
  for rm in mods do
    for d in rm.under ModuleDoc moduleDocExtName do out.putStrLn (moduleDocLine rm.name d)
    for (n, _) in ((rm.entries.find? (·.1 == `Lean.versoDocStringExt)).map (·.2)).getD #[] do
      out.putStrLn (versoKeyLine rm.name n)
  for i in sample seed all.size (k?.getD all.size) do
    let (rm, ci) := all[i]!
    let ranges := (rm.keyed `Lean.declRangeExt ci.name).map fun e => (keyedValue (Name × DeclarationRanges) e).2
    let doc := (rm.keyed `Lean.docStringExt ci.name).map fun e => (keyedValue (Name × String) e).2
    out.putStrLn (declLine rm.name (kindCode ci) ci.toConstantVal ranges doc)
  stats.get

end OleanReader
