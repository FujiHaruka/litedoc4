import OleanReader
open Lean OleanReader

/-! Assembling an `Environment` in the running Lean from decoded `ModuleData`.
`ImportState`, `ImportedModule` and `CompactedRegion` keep their fields private; the structures
below mirror their layouts field for field and are cast with `unsafeCast`. -/

namespace Assemble

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

/-- A region nothing points into; `Environment.freeRegions` is never called on these
environments. -/
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

/-- The old version as the extraction sees it, read from the decoded data alone. -/
structure OldWorld where
  moduleNames : Array Name
  index       : Std.HashMap Name Nat
  constNames  : Array (Array Name)
  imports     : Array (Array Name)
  /-- `const2ModIdx` by v4.31.0's `finalizeImport` rule: modules in import order, each module's
  `constNames`, then the `extraConstNames` of its interpreter data, first module wins. -/
  modOf       : Std.HashMap Name Name
  consts      : Std.HashSet Name
  modDocs     : Std.HashMap Name (Array ModuleDoc)
  docKeys     : Std.HashSet Name
  versoKeys   : Std.HashSet Name
  inherit     : Std.HashMap Name Name
  /-- Names whose axioms the old data stores (the `sorry` pass reads them). -/
  axiomKeys   : Std.HashSet Name

structure Decoded where
  mods    : Array (Name × ModuleData)
  /-- Per decoded extension, its entries over all modules in import order, each with the index
  of the old module it was stored in. -/
  keyed   : Array (Name × Array (Nat × Keyed))
  stats   : ReadStats
  old     : OldWorld

/-- Decodes every module of the closure, one at a time. -/
unsafe def decodeAll (sp : Array System.FilePath) (mods : Array Name) (omitProofs : Bool := true) : IO Decoded := do
  let stats ← IO.mkRef ({} : ReadStats)
  let mut out := #[]
  let mut chunks : Array (Name × Nat × Array Keyed) := #[]
  let mut modDocs : Std.HashMap Name (Array ModuleDoc) := {}
  let mut modOf : Std.HashMap Name Name := {}
  let mut consts : Std.HashSet Name := {}
  let mut index : Std.HashMap Name Nat := {}
  let mut constNames := #[]
  let mut imports := #[]
  for m in mods do
    let parts ← loadModule sp m
    let ((md, ks), _) ← runDM parts (decModuleData omitProofs true parts.back!.root stats)
    out := out.push (m, md)
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
    let extra ← if md.isModule then readIRExtraConstNames sp m else pure md.extraConstNames
    for n in extra do
      unless modOf.contains n do modOf := modOf.insert n m
  let mut extOrder : Array Name := #[]
  let mut grouped : Std.HashMap Name (Array (Nat × Keyed)) := {}
  for (e, i, es) in chunks do
    unless grouped.contains e do extOrder := extOrder.push e
    let mut acc := grouped.getD e #[]
    grouped := grouped.erase e
    for k in es do acc := acc.push (i, k)
    grouped := grouped.insert e acc
  let keyed := grouped
  -- an entry the old version can reach: stored in the module that owns its key
  let reachable (e : Name) : Array (Nat × Keyed) :=
    (keyed.getD e #[]).filter fun (i, k) => modOf[k.1]? == some mods[i]!
  let keysOf (es : Array (Nat × Keyed)) : Std.HashSet Name :=
    es.foldl (fun s (_, k) => s.insert k.1) {}
  let mut inherit : Std.HashMap Name Name := {}
  for (_, k) in reachable (privName `Lean.DocString.Extension `Lean.inheritDocStringExt) do
    inherit := inherit.insert k.1 (unsafeCast k.2 : Name × Name).2
  let old : OldWorld := {
    moduleNames := mods, index, constNames, imports, modOf, consts, modDocs
    docKeys := keysOf (reachable `Lean.docStringExt), versoKeys := keysOf (reachable `Lean.versoDocStringExt), inherit
    axiomKeys := keysOf (reachable (privName `Lean.Util.CollectAxioms `Lean.exportedAxiomsExt)) }
  return { mods := out, keyed := extOrder.map (fun e => (e, keyed.getD e #[])), stats := ← stats.get, old }

def checkMirror (s : MImportState) : IO Unit := do
  unless s.moduleNameMap.size == s.moduleNames.size do
    throw <| IO.userError s!"import state mirror: {s.moduleNameMap.size} map entries, {s.moduleNames.size} names"
  for n in s.moduleNames do
    unless s.moduleNameMap.contains n do throw <| IO.userError s!"import state mirror: {n} not in the map"

unsafe def kName (e : EnvExtensionEntry) : Name := unsafeCast e
unsafe def kFst (e : EnvExtensionEntry) : Name := (unsafeCast e : Name × NonScalar).1
unsafe def kAs {α : Type} (k : α → Name) (e : EnvExtensionEntry) : Name := k (unsafeCast e)
unsafe def kScoped {α : Type} (k : α → Name) (e : EnvExtensionEntry) : Name :=
  scopedKey k (unsafeCast e : ScopedEnvExtension.Entry α)

/-- The key of an entry of a decoded extension, read at that extension's entry type. The same
function reads the newest entries, whose type is layout-identical. -/
unsafe def rawKeys : List (Name × (EnvExtensionEntry → Name)) := [
  (Name.mkNum `_private.Lean.Structure 0 ++ `Lean.structureExt, kAs StructureInfo.structName),
  (`Lean.declRangeExt, kFst), (`Lean.projectionFnInfoExt, kFst),
  (`Lean.Meta.instanceExtension, kScoped (fun (i : Meta.InstanceEntry) => i.globalName?.getD .anonymous)),
  (`Lean.classExtension, kAs ClassEntry.name),
  (`Lean.Meta.coeExt, kScoped (fun (p : Name × NonScalar) => p.1)),
  (`Lean.protectedExt, kName), (`Lean.aliasExtension, kFst), (`reducibilityCore, kFst),
  (`reducibilityExtra, kScoped (fun (p : Name × NonScalar) => p.1)),
  (Name.mkNum `_private.Lean.Namespace 0 ++ `Lean.namespacesExt, kName),
  (`Lean.docStringExt, kFst), (privName `Lean.DocString.Extension `Lean.inheritDocStringExt, kFst),
  (`Lean.Parser.Term.Doc.recommendedSpellingByNameExt, kFst),
  (`Lean.Parser.Tactic.Doc.tacticAlternativeExt, kFst), (`Lean.Parser.Tactic.Doc.tacticDocExtExt, kFst),
  (`Lean.Parser.Tactic.Doc.tacticNameExt, kFst), (`Lean.Parser.Tactic.Doc.tacticTagExt, kFst),
  (`Lean.Parser.Tactic.Doc.knownTacticTagExt, kFst),
  (`Lean.Meta.Match.Extension.extension, kAs Meta.Match.Extension.Entry.name),
  (`Lean.auxRecExt, kName), (`Lean.noConfusionExt, kFst), (`recExt, kName), (`Lean.Meta.matcherLikeExt, kName),
  (privName `Lean.AuxRecursor `Lean.sparseCasesOnExt, kName),
  (privName `Lean.Meta.Constructions.SparseCasesOn `Lean.Meta.sparseCasesOnInfoExt, kFst),
  (`Lean.auxParentProjInfoExt, kFst), (privName `Lean.OriginalConstKind `Lean.privateConstKindsExt, kFst),
  (`Lean.noncomputableExt, kName),
  (`Lean.Compiler.inlineAttrs, kFst), (`Lean.externAttr, kFst), (`Lean.Compiler.implementedByAttr, kFst),
  (`Lean.exportAttr, kFst), (`Lean.Compiler.specializeAttr, kFst), (`Lean.Linter.deprecatedAttr, kFst),
  (`Lean.IR.UnboxResult.unboxAttr, kName), (`Lean.neverExtractAttr, kName),
  (`Lean.Elab.Term.elabWithoutExpectedTypeAttr, kName), (`Lean.matchPatternAttr, kName),
  (`Lean.ppNoDotAttr, kName), (`Lean.ppUsingAnonymousConstructorAttr, kName), (`Lean.Meta.coeDeclAttr, kName),
  (`Lean.Compiler.CSimp.ext, kScoped Compiler.CSimp.Entry.thmName),
  (`Lean.Meta.simpExtension, kScoped simpEntryKey),
  (`Lean.Meta.defaultInstanceExtension, kAs Meta.DefaultInstanceEntry.instanceName),
  (`Lean.Meta.Ext.extExtension, kScoped Meta.Ext.ExtTheorem.declName),
  (`Lean.Meta.unificationHintExtension, kScoped Meta.UnificationHintEntry.val),
  (privName `Lean.Util.CollectAxioms `Lean.exportedAxiomsExt, kFst),
  (`Lean.Meta.eqnOptionsExt, kFst), (`Lean.Elab.Structural.eqnInfoExt, kFst), (`Lean.Elab.WF.eqnInfoExt, kFst),
  (`Lean.Elab.PartialFixpoint.eqnInfoExt, kFst), (`eqnsAttribute, kFst),
  (`Lean.Meta.congrKindsExt, kFst), (`Lean.Meta.congrExtension, kScoped Meta.SimpCongrTheorem.theoremName)
]

/-- Extensions whose newest entries stay as they are: the newest code's own vocabulary
(parsers, elaborators, delaborators, formatters, the attribute registry) and everything the
interpreter needs to run that code (IR, compiler data, initializers, `meta` marks, packages). -/
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

structure Counts where
  replaced : Nat := 0
  dupDropped : Nat := 0
  reservedDropped : Std.HashMap String Nat := {}
  keptNewest : Std.HashMap Name Nat := {}
  unreachableOld : Std.HashMap Name Nat := {}
  droppedNewest : Std.HashMap Name Nat := {}
  emptied : Std.HashMap Name Nat := {}
  kept : Std.HashMap Name Nat := {}
  oldAdded : Std.HashMap Name Nat := {}

def bump (m : Std.HashMap Name Nat) (k : Name) (n : Nat) : Std.HashMap Name Nat :=
  if n == 0 then m else m.insert k (m.getD k 0 + n)

/-- The suffix class of a realizable name — an equation, unfolding, splitter, congruence,
injectivity or induction theorem Lean derives on demand from another declaration — or `none`. -/
def reservedSuffix? (s : String) : Option String :=
  let isNatAfter (p : String) := s.startsWith p && (s.drop p.length).toString.isNat
  if isNatAfter "eq_" then some "eq_<n>"
  else if s == "eq_def" || s == "eq_unfold" || s == "splitter" || s == "congr_simp" || s == "hinj" then some s
  else if isNatAfter "congr_eq_" then some "congr_eq_<n>"
  else if isNatAfter "hcongr_" then some "hcongr_<n>"
  else if s.endsWith "induct" then some "*induct"
  else none

def newestImports : Array Import := #[{ module := `Mathlib }]

/-- The newest Mathlib's module data, read once; every hybrid is built over it. -/
unsafe def importNewest : IO MImportState := do
  initSearchPath (← findSysroot)
  enableInitializersExecution
  let (_, s) ← withImporting (importModulesCore newestImports |>.run)
  let ms : MImportState := unsafeCast s
  checkMirror ms
  return ms

structure Merged where
  out : MImportState
  idxOf : Std.HashMap Name Nat
  msg : String

/-- The rewrite and merge of `assembleHybrid` on an already imported newest state. -/
unsafe def rewriteMerge (ms : MImportState) (d : Decoded) : IO Merged := do
  let mut oldConsts : Std.HashMap Name ConstantInfo := {}
  let mut oldOrder : Array Name := #[]
  for (_, md) in d.mods do
    for n in md.constNames, c in md.constants do
      unless oldConsts.contains n do
        oldConsts := oldConsts.insert n c
        oldOrder := oldOrder.push n
  let isModuleSys (im : MImportedModule) : Bool := (im.parts[0]!.1).isModule
  let mainPart (im : MImportedModule) : Nat := if isModuleSys im then 2 else 0
  let mut c : Counts := {}
  let isReservedNewest (n : Name) : Option String :=
    match privateToUserName n with
    | .str p sfx =>
      match reservedSuffix? sfx with
      | some cls => if oldConsts.contains p || oldConsts.contains (privateToUserName p) then some cls else none
      | none => none
    | _ => none
  -- constants first: the rewritten constant lists decide `const2ModIdx`
  let mut replaced : NameSet := {}
  let mut out := ms
  for i in [0:ms.moduleNames.size] do
    let name := ms.moduleNames[i]!
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
          c := { c with replaced := c.replaced + 1 }
          cn := cn.push n; cs := cs.push oc
      | none =>
        match isReservedNewest n with
        | some cls => c := { c with reservedDropped := c.reservedDropped.insert cls (c.reservedDropped.getD cls 0 + 1) }
        | none => cn := cn.push n; cs := cs.push ci
    out := { out with moduleNameMap := out.moduleNameMap.insert name { im with parts := im.parts.set! pi ({ md with constNames := cn, constants := cs }, region) } }
  let mut xn := #[]
  let mut xc := #[]
  for n in oldOrder do
    unless replaced.contains n do
      xn := xn.push n; xc := xc.push oldConsts[n]!
  -- `const2ModIdx` exactly as v4.34.1's `finalizeImport` will build it
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
  -- old entries: by key into the module the key belongs to, or in order into the extra module
  let keyOf := rawKeys
  let mut perMod : Std.HashMap Nat (Std.HashMap Name (Array Keyed)) := {}
  let mut stateOld : Array (Name × Array EnvExtensionEntry) := #[]
  let mut oldKeys : Std.HashMap Name NameSet := {}
  for (e, es) in d.keyed do
    oldKeys := oldKeys.insert e (es.foldl (fun s (_, k) => s.insert k.1) {})
    match placementOf e with
    | some .byKey =>
      let mut added := 0
      for (src, k) in es do
        -- what the old version answers for a key is the entry in the module owning the key
        if d.old.modOf[k.1]? == some d.old.moduleNames[src]! then
          let i := idxOf.getD k.1 extraIdx
          let m := perMod.getD i {}
          perMod := perMod.insert i (m.insert e (m.getD e #[] |>.push k))
          added := added + 1
      c := { c with oldAdded := bump c.oldAdded e added, unreachableOld := bump c.unreachableOld e (es.size - added) }
    | some .allModules =>
      let mut rank : Std.HashMap Nat Nat := {}
      for (src, k) in es do
        let r ← match rank[src]? with
          | some r => pure r
          | none => do let r := rank.size; rank := rank.insert src r; pure r
        let m := perMod.getD r {}
        perMod := perMod.insert r (m.insert e (m.getD e #[] |>.push k))
      c := { c with oldAdded := bump c.oldAdded e es.size }
    | some .state =>
      stateOld := stateOld.push (e, es.map (·.2.2))
      c := { c with oldAdded := bump c.oldAdded e es.size }
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
      match placementOf e with
      | some pl =>
        if pl == .perModule || pl == .keysOnly then
          c := { c with emptied := bump c.emptied e es.size }
          continue
        let some kf := keyOf.lookup e
          | throw <| IO.userError s!"hybrid: no key function for decoded extension {e}"
        let ok := oldKeys.getD e {}
        let kept := es.filterMap fun x =>
          let k := kf x
          if oldConsts.contains k || ok.contains k then none else some (k, x)
        c := { c with keptNewest := bump c.keptNewest e kept.size, droppedNewest := bump c.droppedNewest e (es.size - kept.size) }
        let entries := if pl == .byKey then sortKeyed (kept ++ olds.getD e #[]) else kept.map (·.2)
        merged := merged.push (e, entries)
        seenExt := seenExt.insert e
      | none =>
        if keepNewest e then
          c := { c with kept := bump c.kept e es.size }
          merged := merged.push (e, es)
        else
          c := { c with emptied := bump c.emptied e es.size }
    for (e, ks) in olds.toArray do
      unless seenExt.contains e do merged := merged.push (e, sortKeyed ks)
    out := { out with moduleNameMap := out.moduleNameMap.insert name { im with parts := im.parts.set! pi ({ md with entries := merged }, region) } }
  let extraName := `_olean_reader.OldOnly
  let mut extraEntries := ((perMod.getD extraIdx {}).toArray.map fun (e, ks) => (e, sortKeyed ks))
  for (e, es) in stateOld do
    match extraEntries.findIdx? (·.1 == e) with
    | some j => extraEntries := extraEntries.modify j fun (e, xs) => (e, xs ++ es)
    | none => extraEntries := extraEntries.push (e, es)
  let extra : ModuleData := {
    isModule := false, imports := #[], constNames := xn, constants := xc,
    extraConstNames := #[], entries := extraEntries }
  out := {
    moduleNameMap := out.moduleNameMap.insert extraName (decodedModule extraName extra)
    moduleNames := out.moduleNames.push extraName }
  checkMirror out
  let fmt (m : Std.HashMap Name Nat) : String :=
    String.intercalate "\n" <| (m.toArray.qsort (fun a b => a.1.toString < b.1.toString)).toList.map fun (e, k) => s!"    {e} {k}"
  let fmtS (m : Std.HashMap String Nat) : String :=
    String.intercalate ", " <| (m.toArray.qsort (fun a b => a.1 < b.1)).toList.map fun (e, k) => s!"{e} {k}"
  let msg := s!"hybrid: newest modules {ms.moduleNames.size}, old constants {oldConsts.size}, replaced in place {c.replaced}, later duplicates dropped {c.dupDropped}, old-only {xn.size} (extra module), names checked against const2ModIdx {idxOf.size}
  newest-only realizations of old declarations dropped: {fmtS c.reservedDropped}
  decoded extensions, old entries added:\n{fmt c.oldAdded}
  decoded extensions, old entries the old version cannot reach (stored outside the module owning the key), not added:\n{fmt c.unreachableOld}
  decoded extensions, newest entries dropped (key is an old name or has an old entry):\n{fmt c.droppedNewest}
  decoded extensions, newest entries kept (key unknown to the old version):\n{fmt c.keptNewest}
  kept newest (code vocabulary), entries:\n{fmt c.kept}
  emptied (entries dropped, nothing added):\n{fmt c.emptied}"
  return { out, idxOf, msg }

/-- `finalizeImport` on a merged state, and the check that every name was placed by the module
index the environment gives it. -/
unsafe def finalizeHybrid (out : MImportState) (idxOf : Std.HashMap Name Nat) (leak : Bool) : IO Environment := do
  enableInitializersExecution
  let env ← withImporting do
    finalizeImport (unsafeCast out) newestImports {} (leakEnv := leak) (loadExts := true)
  let mut idxMismatch := 0
  for (n, i) in idxOf.toList do
    if (env.getModuleIdxFor? n).map (·.toNat) != some i then idxMismatch := idxMismatch + 1
  if idxMismatch != 0 then
    throw <| IO.userError s!"hybrid: {idxMismatch} names placed by a module index the environment does not give them"
  return env

/-- The newest import, with every constant that the old version also has replaced by the old
`ConstantInfo` in place (same module index, so the newest IR and code stay addressable), old-only
constants in one extra module at the end, newest-only realizations of old declarations dropped,
and every extension in one of three classes: decoded (old entries, newest kept only for keys the
old version does not have), kept newest (`keepNewest`), or emptied. -/
unsafe def assembleHybrid (d : Decoded) (leak : Bool := true) : IO (Environment × String) := do
  let tA0 ← IO.monoMsNow
  let ms ← importNewest
  let tA1 ← IO.monoMsNow
  let m ← rewriteMerge ms d
  let tA2 ← IO.monoMsNow
  let env ← finalizeHybrid m.out m.idxOf leak
  let tA3 ← IO.monoMsNow
  IO.eprintln s!"assembly phases: newest importModulesCore {tA1 - tA0} ms, rewrite and merge {tA2 - tA1} ms, finalizeImport {tA3 - tA2} ms"
  return (env, m.msg)

end Assemble
