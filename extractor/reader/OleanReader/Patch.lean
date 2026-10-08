import OleanReader.Assemble
open Lean

namespace OleanReader.Patch
open Assemble

def pushUniq {κ : Type} [BEq κ] [Hashable κ] (m : Std.HashMap κ (Array Nat)) (k : κ) (i : Nat) :
    Std.HashMap κ (Array Nat) :=
  m.alter k fun
    | none => some #[i]
    | some a => some (if a.back? == some i then a else a.push i)

structure NewestIndex where
  ms : MImportState
  names : Array Name
  firstOcc : Std.HashMap Name (Nat × Nat) := {}
  occurrences : Std.HashMap Name Nat := {}
  modsOf : Std.HashMap Name (Array Nat) := {}
  reservedOf : Std.HashMap Name (Array Nat) := {}
  fieldFnOf : Std.HashMap Name (Array Nat) := {}
  realizationNames : Array Name := #[]
  fieldFnNames : Array Name := #[]
  keyMods : Std.HashMap (Name × Name) (Array Nat) := {}
  keyCount : Std.HashMap (Name × Name) Nat := {}
  keyExts : Array Name := #[]
  emptied : Tally := {}
  keptNewest : Tally := {}

def NewestIndex.extraIdx (ni : NewestIndex) : Nat := ni.names.size

unsafe def NewestIndex.mainData (ni : NewestIndex) (i : Nat) : Option ModuleData :=
  let im := ni.ms.moduleNameMap[ni.names[i]!]!
  if im.parts.isEmpty then none else some im.parts[mainPart im]!.1

unsafe def buildNewestIndex (ms : MImportState) (fieldFnIndex : Bool) : NewestIndex := Id.run do
  let mut ni : NewestIndex := { ms, names := ms.moduleNames }
  for i in [0:ms.moduleNames.size] do
    let some md := ni.mainData i | continue
    for j in [0:md.constNames.size] do
      let n := md.constNames[j]!
      ni := { ni with
        firstOcc := ni.firstOcc.insertIfNew n (i, j)
        occurrences := ni.occurrences.insert n (ni.occurrences.getD n 0 + 1)
        modsOf := pushUniq ni.modsOf n i }
      if let some p := reservedPrefix? n then
        ni := { ni with
          realizationNames := ni.realizationNames.push n
          reservedOf := pushUniq (pushUniq ni.reservedOf p i) (privateToUserName p) i }
      if let some s := fieldFnStructure? n then
        ni := { ni with fieldFnNames := ni.fieldFnNames.push n }
        if fieldFnIndex then
          ni := { ni with fieldFnOf := pushUniq (pushUniq ni.fieldFnOf s i) (privateToUserName s) i }
    for (e, es) in md.entries do
      match placementOf e, entryKeyOf e with
      | some pl, some keyOf =>
        if pl == .perModule || pl == .keysOnly then
          ni := { ni with emptied := ni.emptied.add e es.size }
          continue
        unless ni.keyExts.contains e do ni := { ni with keyExts := ni.keyExts.push e }
        for x in es do
          let k := keyOf x
          ni := { ni with
            keyMods := pushUniq ni.keyMods (e, k) i
            keyCount := ni.keyCount.insert (e, k) (ni.keyCount.getD (e, k) 0 + 1) }
      | _, _ =>
        if keepNewest e then ni := { ni with keptNewest := ni.keptNewest.add e es.size }
        else ni := { ni with emptied := ni.emptied.add e es.size }
  return ni

unsafe def rewriteConsts (ni : NewestIndex) (i : Nat) (md : ModuleData) (oldConsts : Std.HashMap Name ConstantInfo) :
    Array Name × Array ConstantInfo := Id.run do
  let mut cn := #[]
  let mut cs := #[]
  for j in [0:md.constNames.size] do
    let n := md.constNames[j]!
    match newestConst oldConsts n with
    | .replacedBy oc =>
      if ni.firstOcc[n]? == some (i, j) then
        cn := cn.push n; cs := cs.push oc
    | .kept => cn := cn.push n; cs := cs.push md.constants[j]!
    | .realization | .fieldFn => pure ()
  return (cn, cs)

def countsByName (ni : NewestIndex) (oldConsts : Std.HashMap Name ConstantInfo) (oldOnly : Nat) (p : Placed) :
    Counts := Id.run do
  let mut c : Counts := {
    newestModules := ni.names.size, oldConstants := oldConsts.size, oldOnly
    oldAdded := p.oldAdded, oldUnreachable := p.oldUnreachable, emptied := ni.emptied, keptNewest := ni.keptNewest }
  for (n, _) in oldConsts do
    let k := ni.occurrences.getD n 0
    if k > 0 then c := { c with replaced := c.replaced + 1, dupDropped := c.dupDropped + (k - 1) }
  for n in ni.realizationNames do
    if newestConst oldConsts n matches .realization then
      c := { c with realizationsDropped := c.realizationsDropped + 1 }
  for n in ni.fieldFnNames do
    if newestConst oldConsts n matches .fieldFn then
      c := { c with fieldFnsDropped := c.fieldFnsDropped + 1 }
  let mut dropped : Std.HashMap Name Nat := {}
  let mut kept : Std.HashMap Name Nat := {}
  for ((e, k), count) in ni.keyCount do
    if oldConsts.contains k || (p.oldKeys.getD e {}).contains k then
      dropped := dropped.insert e (dropped.getD e 0 + count)
    else
      kept := kept.insert e (kept.getD e 0 + count)
  for e in ni.keyExts do
    c := { c with newestDropped := c.newestDropped.add e (dropped.getD e 0)
                  newestKeptBesideOld := c.newestKeptBesideOld.add e (kept.getD e 0) }
  return c

unsafe def sameValueByName (ni : NewestIndex) (oldConsts : Std.HashMap Name ConstantInfo) (ask : Std.HashSet Name) :
    Std.HashMap Name Bool :=
  ask.fold (init := {}) fun m n =>
    match oldConsts[n]?, ni.firstOcc[n]? with
    | some oc, some (i, j) =>
      match ni.mainData i with
      | some md => m.insert n (md.constants[j]!.value? == oc.value?)
      | none => m
    | _, _ => m

structure Built where
  oldConsts : Std.HashMap Name ConstantInfo
  oldKeys : Std.HashMap Name (Std.HashSet Name)
  perMod : Std.HashMap Nat (Std.HashMap Name (Array Keyed))
  out : MImportState

structure Options where
  perturb : Bool := false

structure Stats where
  constSame : Nat := 0
  constChanged : Nat := 0
  constAdded : Nat := 0
  constRemoved : Nat := 0
  byName : Nat := 0
  byRealization : Nat := 0
  byFieldFn : Nat := 0
  dirtyConst : Nat := 0
  byOlds : Nat := 0
  byFilter : Nat := 0
  dirtyEntries : Nat := 0
  dirty : Nat := 0
  perturbed : Option Name := none
  perturbedNothing : Bool := false

@[inline] unsafe def same {α} (a b : α) : Bool := ptrAddrUnsafe a == ptrAddrUnsafe b

unsafe def sameOlds (a b : Std.HashMap Name (Array Keyed)) : Bool :=
  let x := a.toArray
  let y := b.toArray
  x.size == y.size && (x.zip y).all fun ((e, xs), (e', ys)) =>
    e == e' && xs.size == ys.size && (xs.zip ys).all fun (k, k') => same k k'

def union (sets : List (Std.HashSet Nat)) : Std.HashSet Nat :=
  sets.foldl (fun acc s => s.fold (·.insert ·) acc) {}

unsafe def build (ni : NewestIndex) (d : Decoded) (ask : Std.HashSet Name) (prev? : Option Built)
    (o : Options := {}) : IO (Built × Merged × Stats) := do
  checkKeys d
  let (oldConsts, oldOrder) := oldConstsOf d
  let mut st : Stats := {}
  let mut changed : Array Name := #[]
  let mut presence : Array Name := #[]
  if let some pb := prev? then
    for (n, c) in oldConsts do
      match pb.oldConsts[n]? with
      | some c' =>
        if same c c' then st := { st with constSame := st.constSame + 1 }
        else
          changed := changed.push n
          st := { st with constChanged := st.constChanged + 1 }
      | none =>
        changed := changed.push n; presence := presence.push n
        st := { st with constAdded := st.constAdded + 1 }
    for (n, _) in pb.oldConsts do
      unless oldConsts.contains n do
        changed := changed.push n; presence := presence.push n
        st := { st with constRemoved := st.constRemoved + 1 }
  let mut byName : Std.HashSet Nat := {}
  let mut byRealization : Std.HashSet Nat := {}
  let mut byFieldFn : Std.HashSet Nat := {}
  for n in changed do
    for i in ni.modsOf.getD n #[] do byName := byName.insert i
  for n in presence do
    for i in ni.reservedOf.getD n #[] do byRealization := byRealization.insert i
    for i in ni.fieldFnOf.getD n #[] do byFieldFn := byFieldFn.insert i
  let mut dirtyC := union [byName, byRealization, byFieldFn]
  let mut perturbed : Option Nat := none
  if o.perturb && prev?.isSome then
    match (byName.toArray.qsort (· < ·)).back? with
    | some i => dirtyC := dirtyC.erase i; perturbed := some i
    | none => st := { st with perturbedNothing := true }
  let whole := prev?.isNone
  let mut mm := (prev?.map (·.out) |>.getD ni.ms).moduleNameMap
  for i in [0:ni.names.size] do
    if !whole && !dirtyC.contains i then continue
    let some md0 := ni.mainData i | continue
    let name := ni.names[i]!
    let im := mm[name]!
    let pi := mainPart im
    let (md, region) := im.parts[pi]!
    let (cn, cs) := rewriteConsts ni i md0 oldConsts
    mm := mm.insert name { im with parts := im.parts.set! pi ({ md with constNames := cn, constants := cs }, region) }
  let xn := oldOrder.filter (!ni.firstOcc.contains ·)
  let idxOf := idxOfState ni.names mm xn
  let placed := placeOld d idxOf ni.extraIdx
  let mut byOlds : Std.HashSet Nat := {}
  let mut byFilter : Std.HashSet Nat := {}
  if let some pb := prev? then
    let mut idxs : Std.HashSet Nat := {}
    for (i, _) in placed.perMod do idxs := idxs.insert i
    for (i, _) in pb.perMod do idxs := idxs.insert i
    for i in idxs do
      if i != ni.extraIdx && !sameOlds (placed.perMod.getD i {}) (pb.perMod.getD i {}) then
        byOlds := byOlds.insert i
    for e in ni.keyExts do
      let a := placed.oldKeys.getD e {}
      let b := pb.oldKeys.getD e {}
      let flips := a.fold (fun fs k => if b.contains k then fs else fs.push k) #[]
      let flips := b.fold (fun fs k => if a.contains k then fs else fs.push k) flips
      for k in flips ++ presence do
        for i in ni.keyMods.getD (e, k) #[] do byFilter := byFilter.insert i
  let mut dirtyE := union [byOlds, byFilter]
  if let some i := perturbed then dirtyE := dirtyE.erase i
  for i in [0:ni.names.size] do
    if !whole && !dirtyE.contains i && !dirtyC.contains i then continue
    let some md0 := ni.mainData i | continue
    let name := ni.names[i]!
    let im := mm[name]!
    let pi := mainPart im
    let (md, region) := im.parts[pi]!
    let (merged, _) := mergeEntries md0.entries (placed.perMod.getD i {}) oldConsts placed.oldKeys {}
    mm := mm.insert name { im with parts := im.parts.set! pi ({ md with entries := merged }, region) }
  let out : MImportState := {
    moduleNameMap := mm.insert oldOnlyModule (oldOnlyImported xn oldConsts placed ni.extraIdx)
    moduleNames := ni.names.push oldOnlyModule }
  checkMirror out
  st := { st with
    byName := byName.size, byRealization := byRealization.size, byFieldFn := byFieldFn.size
    dirtyConst := dirtyC.size, byOlds := byOlds.size, byFilter := byFilter.size, dirtyEntries := dirtyE.size
    dirty := (union [dirtyC, dirtyE]).size, perturbed := perturbed.map (ni.names[·]!) }
  let merged : Merged := {
    out, idxOf, counts := countsByName ni oldConsts xn.size placed, sameValue := sameValueByName ni oldConsts ask }
  return ({ oldConsts, oldKeys := placed.oldKeys, perMod := placed.perMod, out }, merged, st)

unsafe def moduleDifference? (name : Name) (ia ib : MImportedModule) : Option String := Id.run do
  unless ia.module == ib.module && ia.importAll == ib.importAll && ia.isExported == ib.isExported &&
      ia.isMeta == ib.isMeta && ia.hasData == ib.hasData && ia.needsIRTrans == ib.needsIRTrans &&
      ia.parts.size == ib.parts.size && ia.irParts.size == ib.irParts.size do
    return some "the module record differs"
  for j in [0:ia.irParts.size] do
    unless same ia.irParts[j]!.1 ib.irParts[j]!.1 do return some s!"IR part {j} is another object"
  for j in [0:ia.parts.size] do
    let (ma, ra) := ia.parts[j]!
    let (mb, rb) := ib.parts[j]!
    unless same ra rb || name == oldOnlyModule do return some s!"part {j}: the region is another object"
    unless ma.isModule == mb.isModule && ma.imports.size == mb.imports.size do
      return some s!"part {j}: the module header differs"
    unless ma.constNames == mb.constNames do return some s!"part {j}: constNames differ"
    unless ma.constants.size == mb.constants.size && (ma.constants.zip mb.constants).all (fun (x, y) => same x y) do
      return some s!"part {j}: constants are other objects"
    unless ma.extraConstNames == mb.extraConstNames do return some s!"part {j}: extraConstNames differ"
    unless ma.entries.size == mb.entries.size do
      return some s!"part {j}: {ma.entries.size} extensions' entries against {mb.entries.size}"
    for (ea, xa) in ma.entries, (eb, xb) in mb.entries do
      unless ea == eb && xa.size == xb.size && (xa.zip xb).all (fun (x, y) => same x y) do
        return some s!"part {j}: entries of {ea} ({xa.size}) against {eb} ({xb.size})"
  return none

structure Comparison where
  modules : Array (Name × String) := #[]
  other : Array String := #[]

def Comparison.clean (c : Comparison) : Bool := c.modules.isEmpty && c.other.isEmpty

unsafe def compare (patched oracle : Merged) : Comparison := Id.run do
  let a := patched.out
  let b := oracle.out
  let mut c : Comparison := {}
  unless a.moduleNames == b.moduleNames do
    return { c with other := #[s!"the module lists differ: {a.moduleNames.size} against {b.moduleNames.size}"] }
  for name in a.moduleNames do
    if let some why := moduleDifference? name a.moduleNameMap[name]! b.moduleNameMap[name]! then
      c := { c with modules := c.modules.push (name, why) }
  let idx := patched.idxOf.fold (fun k n i => if oracle.idxOf[n]? == some i then k else k + 1) 0 +
    oracle.idxOf.fold (fun k n _ => if patched.idxOf.contains n then k else k + 1) 0
  if idx != 0 then c := { c with other := c.other.push s!"{idx} names have another module index" }
  for la in patched.counts.lines, lb in oracle.counts.lines do
    if la != lb then c := { c with other := c.other.push s!"counts: `{la}` against `{lb}`" }
  let sv := patched.sameValue.fold (fun k n v => if oracle.sameValue[n]? == some v then k else k + 1) 0 +
    oracle.sameValue.fold (fun k n _ => if patched.sameValue.contains n then k else k + 1) 0
  if sv != 0 then c := { c with other := c.other.push s!"sameValue differs for {sv} names" }
  return c

end OleanReader.Patch
