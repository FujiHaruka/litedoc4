import OleanReader.Serialize
open Lean OleanReader.Serialize

def roots : Array Import := #[{ module := `Init }, { module := `Std }, { module := `Lean }]

def loadCore : IO Environment := do
  initSearchPath (← findSysroot)
  unsafe Lean.enableInitializersExecution
  importModules roots Options.empty (leakEnv := true) (loadExts := true)

def registeredExts : IO (Array String) := do
  return ((← persistentEnvExtensionsRef.get).map (·.name.toString)).qsort (· < ·)

def emitExts (out : IO.FS.Stream) (asked : Array String) : IO Unit := do
  let own ← registeredExts
  for n in asked do out.putStrLn (extLine n (own.contains n))

def emitLayout (out : IO.FS.Stream) (env : Environment) : IO Unit := do
  let ctx : Core.Context := { fileName := "<olean-reader-oracle>", fileMap := default }
  let (l, _) ← (Compiler.LCNF.getCtorLayout ``Meta.SimpTheorem.mk).toIO ctx { env }
  out.putStrLn (layoutLine ``Meta.SimpTheorem.mk l.ctorInfo.size l.ctorInfo.ssize)

def emitModules (out : IO.FS.Stream) (env : Environment) : IO (Array (Name × ConstantInfo)) := do
  let mut all := #[]
  for m in env.header.moduleNames, md in env.header.moduleData do
    out.putStrLn (moduleLine m md.constNames.size)
    for ci in md.constants do
      out.putStrLn (constLine ci)
      all := all.push (m, ci)
  return all

def emitReducibility (out : IO.FS.Stream) (env : Environment) : IO Unit := do
  let mut seen : Array ReducibilityStatus := #[]
  for m in env.header.moduleNames, i in [0:env.header.moduleNames.size] do
    for (n, s) in reducibilityCoreExt.getModuleEntries env i do
      out.putStrLn (reducibilityLine m n s.ctorIdx)
      unless seen.contains s do seen := seen.push s
    for e in reducibilityExtraExt.ext.getModuleEntries env i do
      let (scope, (n, s)) := scopeCode e
      out.putStrLn (reducibilityExtraLine m scope n s.ctorIdx)
      unless seen.contains s do seen := seen.push s
  for s in seen.qsort (·.ctorIdx < ·.ctorIdx) do
    out.putStrLn (statusLine s.ctorIdx (lastComponent (reprStr s)) (← unfoldMask s))

def emitInstances (out : IO.FS.Stream) (env : Environment) : IO Unit := do
  for m in env.header.moduleNames, i in [0:env.header.moduleNames.size] do
    for e in Meta.instanceExtension.ext.getModuleEntries env i do
      let (scope, ie) := scopeCode e
      out.putStrLn (instanceLine m scope ie ie.attrKind.ctorIdx)

def isNamespacesExt : Name → Bool
  | .str _ "namespacesExt" => true
  | _ => false

unsafe def emitNamespaces (out : IO.FS.Stream) (env : Environment) : IO Unit := do
  let exts := (← persistentEnvExtensionsRef.get).filter (isNamespacesExt ·.name)
  let some ext := exts[0]? | throw <| IO.userError "this Lean registers no namespacesExt"
  unless exts.size == 1 do throw <| IO.userError s!"this Lean registers {exts.size} extensions named namespacesExt"
  for m in env.header.moduleNames, i in [0:env.header.moduleNames.size] do
    for n in (unsafeCast (ext.getModuleEntries env i) : Array Name) do out.putStrLn (namespaceLine m n)

def emitSimp (out : IO.FS.Stream) (env : Environment) : IO Unit := do
  for m in env.header.moduleNames, i in [0:env.header.moduleNames.size] do
    for e in Meta.simpExtension.ext.getModuleEntries env i do
      let (scope, se) := scopeCode e
      out.putStrLn (simpLine m scope se)

def emitStructures (out : IO.FS.Stream) (env : Environment) (all : Array (Name × ConstantInfo)) : IO Unit := do
  for (_, ci) in all do
    if let some si := getStructureInfo? env ci.name then out.putStrLn (structureLine si)

def emitDocs (out : IO.FS.Stream) (env : Environment) : IO Unit := do
  for m in env.header.moduleNames, i in [0:env.header.moduleNames.size] do
    for d in (getModuleDoc? env m).getD #[] do out.putStrLn (moduleDocLine m d)
    for (n, _) in versoDocStringExt.getModuleEntries env i do out.putStrLn (versoKeyLine m n)

def emitSample (out : IO.FS.Stream) (env : Environment) (all : Array (Name × ConstantInfo)) (seed : UInt64) (k : Nat) : IO Unit := do
  for i in sample seed all.size k do
    let (m, ci) := all[i]!
    out.putStrLn (declLine m (kindCode ci) ci.toConstantVal (declRangeExt.find? env ci.name) (docStringExt.find? env ci.name))

unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | ["exts"] =>
    discard loadCore
    for n in ← registeredExts do IO.println n
    return 0
  | ["oracle", askedFile, seed, k] =>
    let env ← loadCore
    let asked := (← IO.FS.lines askedFile).filter (!·.isEmpty)
    let out ← IO.getStdout
    emitExts out asked
    emitLayout out env
    let all ← emitModules out env
    emitReducibility out env
    emitInstances out env
    emitNamespaces out env
    emitSimp out env
    emitStructures out env all
    emitDocs out env
    emitSample out env all seed.toNat!.toUInt64 (if k == "all" then all.size else k.toNat!)
    return 0
  | _ =>
    IO.eprintln "usage: dump exts | dump oracle <extension-names-file> <seed> <count|all>"
    return 2
