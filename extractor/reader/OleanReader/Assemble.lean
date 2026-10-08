import OleanReader.Module
open Lean

-- Not Lean's `ImportState` / `ImportedModule` / `CompactedRegion`: their fields are private, so these mirror the layouts and are cast.

namespace OleanReader.Assemble

structure MRegion where
  filePath       : System.FilePath
  size           : USize
  isMemoryMapped : Bool
  baseAddr       : USize
  bufferOffset   : USize
  root           : NonScalar

structure MImportedModule extends EffectiveImport where
  parts        : Array (ModuleData × CompactedRegion)
  irParts      : Array (ModuleData × CompactedRegion)
  needsIRTrans : Bool

structure MImportState where
  moduleNameMap : Std.HashMap Name MImportedModule := {}
  moduleNames   : Array Name := #[]

unsafe def fakeRegion : CompactedRegion :=
  unsafeCast ({
    filePath := "<olean-reader>", size := 0, isMemoryMapped := false, baseAddr := 0
    bufferOffset := 0, root := unsafeCast (#[] : Array Nat) } : MRegion)

unsafe instance : Inhabited CompactedRegion := ⟨fakeRegion⟩

unsafe def decodedModule (m : Name) (md : ModuleData) : MImportedModule :=
  { module := m, importAll := true, isExported := false, isMeta := false, irPhases := .all
    hasData := true, parts := #[({ md with isModule := false }, fakeRegion)], irParts := #[]
    needsIRTrans := false }

unsafe instance : Inhabited MImportedModule := ⟨decodedModule .anonymous default⟩

structure OldWorld where
  moduleNames : Array Name
  index       : Std.HashMap Name Nat
  constNames  : Array (Array Name)
  imports     : Array (Array Name)
  modOf       : Std.HashMap Name Name
  consts      : Std.HashSet Name
  modDocs     : Std.HashMap Name (Array ModuleDoc)
  docKeys     : Std.HashSet Name
  versoKeys   : Std.HashSet Name
  inherit     : Std.HashMap Name Name

structure Decoded where
  writer  : WriterVersion
  mods    : Array (Name × ModuleData)
  keyed   : Array (Name × Array (Nat × Keyed))
  mentioned : Array (Array Name)
  stats   : ReadStats
  old     : OldWorld

unsafe def decodeAll (s : Session) (mods : Array Name) : IO Decoded := do
  let stats ← IO.mkRef ({} : ReadStats)
  let mut out := #[]
  let mut chunks : Array (Name × Nat × Array Keyed) := #[]
  let mut modDocs : Std.HashMap Name (Array ModuleDoc) := {}
  let mut modOf : Std.HashMap Name Name := {}
  let mut consts : Std.HashSet Name := {}
  let mut index : Std.HashMap Name Nat := {}
  let mut constNames := #[]
  let mut imports := #[]
  let mut mentioned := #[]
  for m in mods do
    let parts ← loadModule s m
    let ((md, ks, ms), _) ← runDM parts (decModuleData false true parts.back!.root stats)
    out := out.push (m, md)
    mentioned := mentioned.push ms
    index := index.insert m index.size
    constNames := constNames.push md.constNames
    imports := imports.push (md.imports.map (·.module))
    for (e, es) in ks do
      if placementOf e == some .perModule then
        modDocs := modDocs.insert m (es.map fun k => (unsafeCast k.2 : ModuleDoc))
      else
        chunks := chunks.push (e, index[m]!, es)
    for n in md.constNames do
      consts := consts.insert n
      unless modOf.contains n do modOf := modOf.insert n m
    let extra ← if md.isModule then readIRExtraConstNames s m else pure md.extraConstNames
    for n in extra do
      unless modOf.contains n do modOf := modOf.insert n m
  let some (writer, _) ← s.firstWriter.get | throw <| IO.userError "olean reader: nothing was read"
  let mut extOrder : Array Name := #[]
  let mut grouped : Std.HashMap Name (Array (Nat × Keyed)) := {}
  for (e, i, es) in chunks do
    unless grouped.contains e do extOrder := extOrder.push e
    let mut acc := grouped.getD e #[]
    grouped := grouped.erase e
    for k in es do acc := acc.push (i, k)
    grouped := grouped.insert e acc
  let reachable (e : Name) : Array (Nat × Keyed) :=
    (grouped.getD e #[]).filter fun (i, k) => modOf[k.1]? == some mods[i]!
  let keysOf (es : Array (Nat × Keyed)) : Std.HashSet Name :=
    es.foldl (fun s (_, k) => s.insert k.1) {}
  let mut inherit : Std.HashMap Name Name := {}
  for (_, k) in reachable (privName `Lean.DocString.Extension `Lean.inheritDocStringExt) do
    inherit := inherit.insert k.1 (unsafeCast k.2 : Name × Name).2
  let old : OldWorld := {
    moduleNames := mods, index, constNames, imports, modOf, consts, modDocs, inherit
    docKeys := keysOf (reachable `Lean.docStringExt)
    versoKeys := keysOf (reachable `Lean.versoDocStringExt) }
  return { writer, mods := out, keyed := extOrder.map (fun e => (e, grouped.getD e #[])),
           mentioned, stats := ← stats.get, old }

def checkMirror (s : MImportState) : IO Unit := do
  unless s.moduleNameMap.size == s.moduleNames.size do
    throw <| IO.userError s!"import state mirror: {s.moduleNameMap.size} map entries, {s.moduleNames.size} names"
  for n in s.moduleNames do
    unless s.moduleNameMap.contains n do throw <| IO.userError s!"import state mirror: {n} not in the map"

def keepNewest (e : Name) : Bool :=
  let s := e.toString
  let pre (p : String) := s.startsWith p
  pre "Lean.Parser.parserExtension" || pre "Lean.PrettyPrinter." || pre "Lean.Elab.macroAttribute" ||
  pre "Lean.Elab.Term.termElabAttribute" || pre "Lean.Elab.Command.commandElabAttribute" ||
  pre "Lean.Elab.Tactic.tacticElabAttribute" || pre "Lean.Elab.Term.Quotation.precheckAttribute" ||
  pre "Lean.Elab.Do." || pre "Lean.Elab.Command.inductiveElabAttr" || pre "Lean.Elab.incrementalAttr" ||
  pre "Lean.Elab.Tactic.Try.tryTacticElabAttribute" || pre "Lean.Elab.Tactic.Grind.symSimprocElabAttribute" ||
  pre "Lean.Elab.Tactic.Grind.symDSimprocElabAttribute" || pre "Lean.Elab.Tactic.Grind.symDischargerElabAttribute" ||
  pre "Lean.Elab.Tactic.Grind.grindTacElabAttribute" || pre "Lean.Elab.Tactic.noFallbackAttr" ||
  pre "Lean.Doc.doc" || pre "Lean.Doc.DeferredCheck.handlerExt" || pre "Lean.Doc.code" ||
  pre "Lean.IR." || pre "Lean.Compiler.LCNF." || pre "_private.Lean.Compiler." ||
  pre "Lean.Compiler.nospecializeAttr" || pre "Lean.Compiler.weakSpecializeAttr" ||
  s == "specMap" || s == "internalSpecMap" || pre "Lean.builtinInitAttr" || pre "Lean.regularInitAttr" ||
  pre "Lean.attributeExtension"

structure Tally where
  extensions : Std.HashSet Name := {}
  entries : Nat := 0

def Tally.add (t : Tally) (e : Name) (n : Nat) : Tally :=
  if n == 0 then t else { extensions := t.extensions.insert e, entries := t.entries + n }

def Tally.text (t : Tally) : String := s!"{t.extensions.size} extensions, {t.entries} entries"

structure Counts where
  newestModules : Nat := 0
  oldConstants : Nat := 0
  replaced : Nat := 0
  dupDropped : Nat := 0
  oldOnly : Nat := 0
  realizationsDropped : Nat := 0
  fieldFnsDropped : Nat := 0
  oldAdded : Tally := {}
  oldUnreachable : Tally := {}
  newestDropped : Tally := {}
  newestKeptBesideOld : Tally := {}
  keptNewest : Tally := {}
  emptied : Tally := {}

def Counts.lines (c : Counts) : List String := [
  s!"newest import       {c.newestModules} modules; old constants {c.oldConstants}: replaced in place \
    {c.replaced}, old-only {c.oldOnly} (one extra module), later duplicates dropped {c.dupDropped}, \
    newest-only realizations of old declarations dropped {c.realizationsDropped}, newest-only \
    default and autoParam functions of old structures' fields dropped {c.fieldFnsDropped}",
  s!"decoded             old entries added: {c.oldAdded.text}; not reachable in the old version, \
    not added: {c.oldUnreachable.text}",
  s!"                    newest entries dropped for an old key: {c.newestDropped.text}; kept for a \
    key the old version does not have: {c.newestKeptBesideOld.text}",
  s!"kept newest         {c.keptNewest.text} (the newest code's vocabulary)",
  s!"emptied             {c.emptied.text}"]

def reservedSuffix? (s : String) : Option String :=
  let isNatAfter (p : String) := s.startsWith p && (s.drop p.length).toString.isNat
  if isNatAfter "eq_" then some "eq_<n>"
  else if s == "eq_def" || s == "eq_unfold" || s == "splitter" || s == "congr_simp" || s == "hinj" then some s
  else if isNatAfter "congr_eq_" then some "congr_eq_<n>"
  else if isNatAfter "hcongr_" then some "hcongr_<n>"
  else if s.endsWith "induct" then some "*induct"
  else none

def structureFieldFnSuffixes : List String :=
  [mkDefaultFnOfProjFn, mkInheritedDefaultFnOfProjFn, mkAutoParamFnOfProjFn].filterMap fun mk =>
    match mk .anonymous with
    | .str .anonymous sfx => some sfx
    | _ => none

unsafe def importNewest (searchPath : Array System.FilePath) (imports : Array Import) : IO MImportState := do
  searchPathRef.set searchPath.toList
  enableInitializersExecution
  let (_, s) ← withImporting (importModulesCore imports |>.run)
  let ms : MImportState := unsafeCast s
  checkMirror ms
  return ms

structure Merged where
  out : MImportState
  idxOf : Std.HashMap Name Nat
  counts : Counts
  sameValue : Std.HashMap Name Bool

def oldOnlyModule : Name := `_olean_reader.OldOnly

unsafe def rewriteMerge (ms : MImportState) (d : Decoded) (ask : Std.HashSet Name) : IO Merged := do
  let mut oldConsts : Std.HashMap Name ConstantInfo := {}
  let mut oldOrder : Array Name := #[]
  for (_, md) in d.mods do
    for n in md.constNames, c in md.constants do
      unless oldConsts.contains n do
        oldConsts := oldConsts.insert n c
        oldOrder := oldOrder.push n
  let isModuleSys (im : MImportedModule) : Bool := (im.parts[0]!.1).isModule
  let mainPart (im : MImportedModule) : Nat := if isModuleSys im then 2 else 0
  let mut c : Counts := { newestModules := ms.moduleNames.size, oldConstants := oldConsts.size }
  let isReservedNewest (n : Name) : Bool :=
    match privateToUserName n with
    | .str p sfx =>
      (reservedSuffix? sfx).isSome && (oldConsts.contains p || oldConsts.contains (privateToUserName p))
    | _ => false
  let isFieldFnNewest (n : Name) : Bool :=
    match n with
    | .str (.str s _) sfx =>
      structureFieldFnSuffixes.contains sfx && (oldConsts.contains s || oldConsts.contains (privateToUserName s))
    | _ => false
  let mut replaced : NameSet := {}
  let mut sameValue : Std.HashMap Name Bool := {}
  let mut out := ms
  for name in ms.moduleNames do
    let im := ms.moduleNameMap[name]!
    if im.parts.isEmpty then continue
    let pi := mainPart im
    let (md, region) := im.parts[pi]!
    let mut cn := #[]
    let mut cs := #[]
    for n in md.constNames, ci in md.constants do
      match oldConsts[n]? with
      | some oc =>
        if replaced.contains n then
          c := { c with dupDropped := c.dupDropped + 1 }
        else
          replaced := replaced.insert n
          if ask.contains n then sameValue := sameValue.insert n (ci.value? == oc.value?)
          c := { c with replaced := c.replaced + 1 }
          cn := cn.push n; cs := cs.push oc
      | none =>
        if isReservedNewest n then
          c := { c with realizationsDropped := c.realizationsDropped + 1 }
        else if isFieldFnNewest n then
          c := { c with fieldFnsDropped := c.fieldFnsDropped + 1 }
        else
          cn := cn.push n; cs := cs.push ci
    let im' := { im with parts := im.parts.set! pi ({ md with constNames := cn, constants := cs }, region) }
    out := { out with moduleNameMap := out.moduleNameMap.insert name im' }
  let mut xn := #[]
  let mut xc := #[]
  for n in oldOrder do
    unless replaced.contains n do
      xn := xn.push n; xc := xc.push oldConsts[n]!
  c := { c with oldOnly := xn.size }
  let extraIdx := ms.moduleNames.size
  let mut idxOf : Std.HashMap Name Nat := {}
  for i in [0:ms.moduleNames.size] do
    let im := out.moduleNameMap[ms.moduleNames[i]!]!
    if im.parts.isEmpty then continue
    for n in (im.parts[mainPart im]!.1).constNames do
      unless idxOf.contains n do idxOf := idxOf.insert n i
    let irData := if im.irParts.isEmpty || !isModuleSys im then im.parts[mainPart im]!.1 else im.irParts.back!.1
    for n in irData.extraConstNames do
      unless idxOf.contains n do idxOf := idxOf.insert n i
  for n in xn do
    unless idxOf.contains n do idxOf := idxOf.insert n extraIdx
  let mut perMod : Std.HashMap Nat (Std.HashMap Name (Array Keyed)) := {}
  let mut stateOld : Array (Name × Array EnvExtensionEntry) := #[]
  let mut oldKeys : Std.HashMap Name NameSet := {}
  for (e, es) in d.keyed do
    let some keyOf := entryKeyOf e
      | throw <| IO.userError s!"hybrid: decoded extension {e} has no key function"
    for (src, k) in es do
      unless keyOf k.2 == k.1 do
        throw <| IO.userError s!"hybrid: an entry of {e} decoded from {d.old.moduleNames[src]!} \
          has key {k.1}, and the key function reads {keyOf k.2} from it"
    oldKeys := oldKeys.insert e (es.foldl (fun s (_, k) => s.insert k.1) {})
    match placementOf e with
    | some .byKey =>
      let mut added := 0
      for (src, k) in es do
        if d.old.modOf[k.1]? == some d.old.moduleNames[src]! then
          let i := idxOf.getD k.1 extraIdx
          let m := perMod.getD i {}
          perMod := perMod.insert i (m.insert e (m.getD e #[] |>.push k))
          added := added + 1
      c := { c with oldAdded := c.oldAdded.add e added
                    oldUnreachable := c.oldUnreachable.add e (es.size - added) }
    | some .allModules =>
      let mut rank : Std.HashMap Nat Nat := {}
      for (src, k) in es do
        let r ← match rank[src]? with
          | some r => pure r
          | none => do let r := rank.size; rank := rank.insert src r; pure r
        let m := perMod.getD r {}
        perMod := perMod.insert r (m.insert e (m.getD e #[] |>.push k))
      c := { c with oldAdded := c.oldAdded.add e es.size }
    | some .state =>
      stateOld := stateOld.push (e, es.map (·.2.2))
      c := { c with oldAdded := c.oldAdded.add e es.size }
    | _ => pure ()
  let sortKeyed (ks : Array Keyed) : Array EnvExtensionEntry :=
    (ks.qsort (fun a b => Name.quickLt a.1 b.1)).map (·.2)
  for i in [0:ms.moduleNames.size] do
    let name := ms.moduleNames[i]!
    let im := out.moduleNameMap[name]!
    if im.parts.isEmpty then continue
    let pi := mainPart im
    let (md, region) := im.parts[pi]!
    let olds := perMod.getD i {}
    let mut merged : Array (Name × Array EnvExtensionEntry) := #[]
    let mut seenExt : NameSet := {}
    for (e, es) in md.entries do
      match placementOf e, entryKeyOf e with
      | some pl, some keyOf =>
        if pl == .perModule || pl == .keysOnly then
          c := { c with emptied := c.emptied.add e es.size }
          continue
        let ok := oldKeys.getD e {}
        let kept := es.filterMap fun x =>
          let k := keyOf x
          if oldConsts.contains k || ok.contains k then none else some (k, x)
        c := { c with newestKeptBesideOld := c.newestKeptBesideOld.add e kept.size
                      newestDropped := c.newestDropped.add e (es.size - kept.size) }
        let entries := if pl == .byKey then sortKeyed (kept ++ olds.getD e #[]) else kept.map (·.2)
        merged := merged.push (e, entries)
        seenExt := seenExt.insert e
      | _, _ =>
        if keepNewest e then
          c := { c with keptNewest := c.keptNewest.add e es.size }
          merged := merged.push (e, es)
        else
          c := { c with emptied := c.emptied.add e es.size }
    for (e, ks) in olds.toArray do
      unless seenExt.contains e do merged := merged.push (e, sortKeyed ks)
    let im' := { im with parts := im.parts.set! pi ({ md with entries := merged }, region) }
    out := { out with moduleNameMap := out.moduleNameMap.insert name im' }
  let mut extraEntries := ((perMod.getD extraIdx {}).toArray.map fun (e, ks) => (e, sortKeyed ks))
  for (e, es) in stateOld do
    match extraEntries.findIdx? (·.1 == e) with
    | some j => extraEntries := extraEntries.modify j fun (e, xs) => (e, xs ++ es)
    | none => extraEntries := extraEntries.push (e, es)
  let extra : ModuleData := {
    isModule := false, imports := #[], constNames := xn, constants := xc,
    extraConstNames := #[], entries := extraEntries }
  out := {
    moduleNameMap := out.moduleNameMap.insert oldOnlyModule (decodedModule oldOnlyModule extra)
    moduleNames := out.moduleNames.push oldOnlyModule }
  checkMirror out
  return { out, idxOf, counts := c, sameValue }

unsafe def finalizeHybrid (out : MImportState) (imports : Array Import) (idxOf : Std.HashMap Name Nat)
    (leak : Bool) : IO Environment := do
  enableInitializersExecution
  let env ← withImporting do
    finalizeImport (unsafeCast out) imports {} (leakEnv := leak) (loadExts := true)
  let mut idxMismatch := 0
  for (n, i) in idxOf.toList do
    if (env.getModuleIdxFor? n).map (·.toNat) != some i then idxMismatch := idxMismatch + 1
  if idxMismatch != 0 then
    throw <| IO.userError s!"hybrid: {idxMismatch} names placed by a module index the environment does not give them"
  return env

unsafe def assembleHybrid (ms : MImportState) (imports : Array Import) (d : Decoded)
    (ask : Std.HashSet Name) (leak : Bool) : IO (Environment × Merged) := do
  let m ← rewriteMerge ms d ask
  let env ← finalizeHybrid m.out imports m.idxOf leak
  return (env, m)

structure MRealizationContext where
  env : NonScalar
  opts : NonScalar
  realizeMapRef : IO.Ref (NameMap NonScalar)

structure MEnvironment where
  base : NonScalar
  serverBaseExts : NonScalar
  checked : NonScalar
  asyncConstsMap : NonScalar
  asyncCtx? : NonScalar
  importRealizationCtx? : Option MRealizationContext
  localRealizationCtxMap : NonScalar
  allRealizations : NonScalar
  isExporting : Bool

-- Not left to the environment's release: the context holds the environment and its realizations hold the context, a cycle reference counting never frees.
unsafe def clearRealizations (env : Environment) : IO Nat := do
  let me : MEnvironment := unsafeCast env
  let some c := me.importRealizationCtx?
    | throw <| IO.userError "environment mirror: the hybrid environment has no realization context"
  unless ptrAddrUnsafe (unsafeCast c.env : MEnvironment).base == ptrAddrUnsafe me.base do
    throw <| IO.userError "environment mirror: the realization context does not hold the environment it belongs to"
  let m ← c.realizeMapRef.get
  let mut n := 0
  for (_, v) in m.toList do n := n + (unsafeCast v : PersistentHashMap Name NonScalar).foldl (fun k _ _ => k + 1) 0
  c.realizeMapRef.set {}
  return n

end OleanReader.Assemble
