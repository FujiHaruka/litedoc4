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

structure Prev where
  consts : Std.HashMap Name (UInt64 × ConstantInfo) := {}
  entries : Std.HashMap (Name × Name × UInt64) Keyed := {}

structure ShareCounts where
  constants : Nat := 0
  constantsShared : Nat := 0
  entries : Nat := 0
  entriesShared : Nat := 0

structure Sharing where
  prev : Prev
  next : Prev := {}
  counts : ShareCounts := {}

def Sharing.module (sh : Sharing) (m : Name) (h : ModuleHashes) (md : ModuleData) (ks : Array (Name × Array Keyed)) :
    Except String (Sharing × ModuleData × Array (Name × Array Keyed)) := do
  unless h.consts.size == md.constants.size && h.entries.size == ks.size &&
      (h.entries.zip ks).all (fun ((e, hs), (e', es)) => e == e' && hs.size == es.size) do
    throw s!"olean reader: the content hashes of {m} do not line up with its decoded constants and entries"
  let mut next := sh.next
  let mut c := sh.counts
  let mut cs := Array.mkEmpty md.constants.size
  for n in md.constNames, ci in md.constants, hc in h.consts do
    let ci ← match sh.prev.consts[n]? with
      | some (hp, cp) =>
        if hp == hc then
          c := { c with constantsShared := c.constantsShared + 1 }
          pure cp
        else pure ci
      | none => pure ci
    cs := cs.push ci
    next := { next with consts := next.consts.insertIfNew n (hc, ci) }
  c := { c with constants := c.constants + cs.size }
  let mut ks' := Array.mkEmpty ks.size
  for (e, es) in ks, (_, hs) in h.entries do
    let mut es' := Array.mkEmpty es.size
    for k in es, he in hs do
      let k ← match sh.prev.entries[(e, k.1, he)]? with
        | some kp =>
          c := { c with entriesShared := c.entriesShared + 1 }
          pure kp
        | none => pure k
      es' := es'.push k
      next := { next with entries := next.entries.insertIfNew (e, k.1, he) k }
    c := { c with entries := c.entries + es'.size }
    ks' := ks'.push (e, es')
  return ({ sh with next, counts := c }, { md with constants := cs, entries := ks'.map fun (e, es) => (e, es.map (·.2)) }, ks')

unsafe def decodeAll (s : Session) (mods : Array Name) (prev? : Option Prev := none) :
    IO (Decoded × Option (Prev × ShareCounts)) := do
  let stats ← IO.mkRef ({} : ReadStats)
  let mut sharing := prev?.map ({ prev := · : Sharing })
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
    let (md, ks) ← match sharing with
      | none => pure (md, ks)
      | some sh => do
        let (h, _) ← runDM parts (hashModule (writerSeed parts[0]!.ver) parts.back!.root)
        let (sh, md, ks) ← IO.ofExcept (sh.module m h md ks |>.mapError IO.userError)
        sharing := some sh
        pure (md, ks)
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
  let d : Decoded := { writer, mods := out, keyed := extOrder.map (fun e => (e, grouped.getD e #[])),
                       mentioned, stats := ← stats.get, old }
  return (d, sharing.map fun sh => (sh.next, sh.counts))

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

unsafe def isModuleSys (im : MImportedModule) : Bool := (im.parts[0]!.1).isModule
unsafe def mainPart (im : MImportedModule) : Nat := if isModuleSys im then 2 else 0

def sortKeyed (ks : Array Keyed) : Array EnvExtensionEntry :=
  (ks.qsort (fun a b => Name.quickLt a.1 b.1)).map (·.2)

def reservedPrefix? (n : Name) : Option Name :=
  match privateToUserName n with
  | .str p sfx => if (reservedSuffix? sfx).isSome then some p else none
  | _ => none

def fieldFnStructure? (n : Name) : Option Name :=
  match n with
  | .str (.str s _) sfx => if structureFieldFnSuffixes.contains sfx then some s else none
  | _ => none

def oldHas (oldConsts : Std.HashMap Name ConstantInfo) (n : Name) : Bool :=
  oldConsts.contains n || oldConsts.contains (privateToUserName n)

def isReservedNewest (oldConsts : Std.HashMap Name ConstantInfo) (n : Name) : Bool :=
  (reservedPrefix? n).any (oldHas oldConsts)

def isFieldFnNewest (oldConsts : Std.HashMap Name ConstantInfo) (n : Name) : Bool :=
  (fieldFnStructure? n).any (oldHas oldConsts)

inductive NewestConst where
  | replacedBy (old : ConstantInfo)
  | realization
  | fieldFn
  | kept

def newestConst (oldConsts : Std.HashMap Name ConstantInfo) (n : Name) : NewestConst :=
  match oldConsts[n]? with
  | some oc => .replacedBy oc
  | none =>
    if isReservedNewest oldConsts n then .realization
    else if isFieldFnNewest oldConsts n then .fieldFn
    else .kept

unsafe def oldConstsOf (d : Decoded) : Std.HashMap Name ConstantInfo × Array Name := Id.run do
  let mut oldConsts : Std.HashMap Name ConstantInfo := {}
  let mut oldOrder : Array Name := #[]
  for (_, md) in d.mods do
    for n in md.constNames, c in md.constants do
      unless oldConsts.contains n do
        oldConsts := oldConsts.insert n c
        oldOrder := oldOrder.push n
  return (oldConsts, oldOrder)

def checkKeys (d : Decoded) : IO Unit := do
  for (e, es) in d.keyed do
    let some keyOf := entryKeyOf e
      | throw <| IO.userError s!"hybrid: decoded extension {e} has no key function"
    for (src, k) in es do
      unless keyOf k.2 == k.1 do
        throw <| IO.userError s!"hybrid: an entry of {e} decoded from {d.old.moduleNames[src]!} \
          has key {k.1}, and the key function reads {keyOf k.2} from it"

unsafe def idxOfState (names : Array Name) (mm : Std.HashMap Name MImportedModule) (xn : Array Name) :
    Std.HashMap Name Nat := Id.run do
  let mut idxOf : Std.HashMap Name Nat := {}
  for i in [0:names.size] do
    let im := mm[names[i]!]!
    if im.parts.isEmpty then continue
    for n in (im.parts[mainPart im]!.1).constNames do
      unless idxOf.contains n do idxOf := idxOf.insert n i
    let irData := if im.irParts.isEmpty || !isModuleSys im then im.parts[mainPart im]!.1 else im.irParts.back!.1
    for n in irData.extraConstNames do
      unless idxOf.contains n do idxOf := idxOf.insert n i
  for n in xn do
    unless idxOf.contains n do idxOf := idxOf.insert n names.size
  return idxOf

structure Placed where
  perMod : Std.HashMap Nat (Std.HashMap Name (Array Keyed)) := {}
  stateOld : Array (Name × Array EnvExtensionEntry) := #[]
  oldKeys : Std.HashMap Name (Std.HashSet Name) := {}
  oldAdded : Tally := {}
  oldUnreachable : Tally := {}

-- Not `perMod.insert i (m.insert e (m.getD e #[] |>.push k))` per entry: each insert copies the module's map and its array.
def placeOld (d : Decoded) (idxOf : Std.HashMap Name Nat) (extraIdx : Nat) : Placed := Id.run do
  let mut acc : Std.HashMap (Nat × Name) (Array Keyed) := {}
  let mut outer : Array Nat := #[]
  let mut seenOuter : Std.HashSet Nat := {}
  let mut inner : Std.HashMap Nat (Array Name) := {}
  let mut p : Placed := {}
  for (e, es) in d.keyed do
    p := { p with oldKeys := p.oldKeys.insert e (es.foldl (fun s (_, k) => s.insert k.1) {}) }
    let mut targets : Array (Nat × Keyed) := #[]
    match placementOf e with
    | some .byKey =>
      for (src, k) in es do
        if d.old.modOf[k.1]? == some d.old.moduleNames[src]! then
          targets := targets.push (idxOf.getD k.1 extraIdx, k)
      p := { p with oldAdded := p.oldAdded.add e targets.size
                    oldUnreachable := p.oldUnreachable.add e (es.size - targets.size) }
    | some .allModules =>
      let mut rank : Std.HashMap Nat Nat := {}
      for (src, k) in es do
        let r := rank.getD src rank.size
        rank := rank.insert src r
        targets := targets.push (r, k)
      p := { p with oldAdded := p.oldAdded.add e es.size }
    | some .state =>
      p := { p with stateOld := p.stateOld.push (e, es.map (·.2.2)), oldAdded := p.oldAdded.add e es.size }
    | _ => pure ()
    for (i, k) in targets do
      unless seenOuter.contains i do
        seenOuter := seenOuter.insert i
        outer := outer.push i
      if acc.contains (i, e) then
        acc := acc.modify (i, e) (·.push k)
      else
        inner := inner.alter i fun
          | none => some #[e]
          | some a => some (a.push e)
        acc := acc.insert (i, e) #[k]
  let mut perMod : Std.HashMap Nat (Std.HashMap Name (Array Keyed)) := {}
  for i in outer do
    let mut m : Std.HashMap Name (Array Keyed) := {}
    for e in inner.getD i #[] do m := m.insert e (acc.getD (i, e) #[])
    perMod := perMod.insert i m
  return { p with perMod }

structure EntryTallies where
  emptied : Tally := {}
  keptNewest : Tally := {}
  newestDropped : Tally := {}
  newestKeptBesideOld : Tally := {}

def mergeEntries (entries : Array (Name × Array EnvExtensionEntry)) (olds : Std.HashMap Name (Array Keyed))
    (oldConsts : Std.HashMap Name ConstantInfo) (oldKeys : Std.HashMap Name (Std.HashSet Name)) (t : EntryTallies) :
    Array (Name × Array EnvExtensionEntry) × EntryTallies := Id.run do
  let mut t := t
  let mut merged : Array (Name × Array EnvExtensionEntry) := #[]
  let mut seenExt : NameSet := {}
  for (e, es) in entries do
    match placementOf e, entryKeyOf e with
    | some pl, some keyOf =>
      if pl == .perModule || pl == .keysOnly then
        t := { t with emptied := t.emptied.add e es.size }
        continue
      let ok := oldKeys.getD e {}
      let kept := es.filterMap fun x =>
        let k := keyOf x
        if oldConsts.contains k || ok.contains k then none else some (k, x)
      t := { t with newestKeptBesideOld := t.newestKeptBesideOld.add e kept.size
                    newestDropped := t.newestDropped.add e (es.size - kept.size) }
      let entries := if pl == .byKey then sortKeyed (kept ++ olds.getD e #[]) else kept.map (·.2)
      merged := merged.push (e, entries)
      seenExt := seenExt.insert e
    | _, _ =>
      if keepNewest e then
        t := { t with keptNewest := t.keptNewest.add e es.size }
        merged := merged.push (e, es)
      else
        t := { t with emptied := t.emptied.add e es.size }
  for (e, ks) in olds.toArray do
    unless seenExt.contains e do merged := merged.push (e, sortKeyed ks)
  return (merged, t)

unsafe def oldOnlyImported (xn : Array Name) (oldConsts : Std.HashMap Name ConstantInfo) (p : Placed)
    (extraIdx : Nat) : MImportedModule := Id.run do
  let mut extraEntries := ((p.perMod.getD extraIdx {}).toArray.map fun (e, ks) => (e, sortKeyed ks))
  for (e, es) in p.stateOld do
    match extraEntries.findIdx? (·.1 == e) with
    | some j => extraEntries := extraEntries.modify j fun (e, xs) => (e, xs ++ es)
    | none => extraEntries := extraEntries.push (e, es)
  let extra : ModuleData := {
    isModule := false, imports := #[], constNames := xn, constants := xn.map (oldConsts[·]!),
    extraConstNames := #[], entries := extraEntries }
  return decodedModule oldOnlyModule extra

unsafe def rewriteMerge (ms : MImportState) (d : Decoded) (ask : Std.HashSet Name) : IO Merged := do
  checkKeys d
  let (oldConsts, oldOrder) := oldConstsOf d
  let mut c : Counts := { newestModules := ms.moduleNames.size, oldConstants := oldConsts.size }
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
      match newestConst oldConsts n with
      | .replacedBy oc =>
        if replaced.contains n then
          c := { c with dupDropped := c.dupDropped + 1 }
        else
          replaced := replaced.insert n
          if ask.contains n then sameValue := sameValue.insert n (ci.value? == oc.value?)
          c := { c with replaced := c.replaced + 1 }
          cn := cn.push n; cs := cs.push oc
      | .realization => c := { c with realizationsDropped := c.realizationsDropped + 1 }
      | .fieldFn => c := { c with fieldFnsDropped := c.fieldFnsDropped + 1 }
      | .kept => cn := cn.push n; cs := cs.push ci
    let im' := { im with parts := im.parts.set! pi ({ md with constNames := cn, constants := cs }, region) }
    out := { out with moduleNameMap := out.moduleNameMap.insert name im' }
  let xn := oldOrder.filter (!replaced.contains ·)
  c := { c with oldOnly := xn.size }
  let extraIdx := ms.moduleNames.size
  let idxOf := idxOfState ms.moduleNames out.moduleNameMap xn
  let placed := placeOld d idxOf extraIdx
  c := { c with oldAdded := placed.oldAdded, oldUnreachable := placed.oldUnreachable }
  let mut t : EntryTallies := {}
  for i in [0:ms.moduleNames.size] do
    let name := ms.moduleNames[i]!
    let im := out.moduleNameMap[name]!
    if im.parts.isEmpty then continue
    let pi := mainPart im
    let (md, region) := im.parts[pi]!
    let (merged, t') := mergeEntries md.entries (placed.perMod.getD i {}) oldConsts placed.oldKeys t
    t := t'
    let im' := { im with parts := im.parts.set! pi ({ md with entries := merged }, region) }
    out := { out with moduleNameMap := out.moduleNameMap.insert name im' }
  c := { c with emptied := t.emptied, keptNewest := t.keptNewest, newestDropped := t.newestDropped
                newestKeptBesideOld := t.newestKeptBesideOld }
  out := {
    moduleNameMap := out.moduleNameMap.insert oldOnlyModule (oldOnlyImported xn oldConsts placed extraIdx)
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
