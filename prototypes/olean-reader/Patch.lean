import OleanReader
import Assemble
open Lean OleanReader Assemble

/-! Patching the hybrid of one old version into the hybrid of the next, in one process: decode the
next version with a content hash per constant and per decoded extension entry, share every object
whose hash equals the previous version's, and rewrite only the newest modules whose inputs changed.
The environment is then finalized again from the patched module data. -/

namespace Patch

def bytesHash (b : ByteArray) (start stop : Nat) (h : UInt64) : UInt64 := Id.run do
  let mut h := h
  let mut i := start
  while i + 8 ≤ stop do
    h := mixHash h (u64 b i); i := i + 8
  while i < stop do
    h := mixHash h (u8 b i).toUInt64; i := i + 1
  return mixHash h (stop - start).toUInt64

/-- The stored object graph's hash: tag, object fields' hashes, scalar bytes. -/
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

def redCode : ReducibilityStatus → UInt64
  | .reducible => 1 | .semireducible => 2 | .irreducible => 3 | .implicitReducible => 4
  | .instanceReducible => 5

/-- What a writer record changes in the decoded value of the same bytes. -/
def writerSeed (w : WriterVersion) : UInt64 :=
  w.reducibility.foldl (fun h r => mixHash h (redCode r)) 17

/-- A constant's content as the reader decodes it: a theorem's proof is not decoded. -/
def constHash (memo : IO.Ref (Std.HashMap UInt64 UInt64)) (v : UInt64) : DM UInt64 := do
  let x ← obj "ConstantInfo" v
  if x.tag == 2 then
    let y ← ctor "TheoremVal" (x.field 0) 0 3 0
    return mixHash (mixHash 201 (← rawHash memo (y.field 0))) (← rawHash memo (y.field 2))
  else
    return mixHash 202 (← rawHash memo v)

/-- Per constant and per entry of a decoded extension, in the order `decModuleData` decodes them. -/
def hashModule (seed : UInt64) (root : UInt64) : DM (Array UInt64 × Array (Name × Array UInt64)) := do
  let memo ← IO.mkRef ({} : Std.HashMap UInt64 UInt64)
  let x ← ctor "ModuleData" root 0 5 1
  let consts ← obj "Array ConstantInfo" (x.field 2)
  let n := (u64 consts.b (consts.o + 8)).toNat
  let mut ch := Array.mkEmpty n
  for i in [0:n] do
    ch := ch.push (mixHash seed (← constHash memo (u64 consts.b (consts.o + 24 + 8*i))))
  let es ← obj "entries" (x.field 4)
  let ne := (u64 es.b (es.o + 8)).toNat
  let mut eh := #[]
  for i in [0:ne] do
    let p ← ctor "Name × Array EnvExtensionEntry" (u64 es.b (es.o + 24 + 8*i)) 0 2 0
    let e ← decName (p.field 0)
    if (decoderFor e).isSome then
      let arr ← obj "Array EnvExtensionEntry" (p.field 1)
      let k := (u64 arr.b (arr.o + 8)).toNat
      let mut hs := Array.mkEmpty k
      for j in [0:k] do
        hs := hs.push (mixHash seed (← rawHash memo (u64 arr.b (arr.o + 24 + 8*j))))
      eh := eh.push (e, hs)
  return (ch, eh)

/-- The previous version's decoded objects by content: what a decoded object of the next version
is replaced by when its hash is the same. Compared only with the counterpart of the same name
(constants) or the same extension and key (entries), so 64 bits are compared pairwise, not across
the whole set. -/
structure Prev where
  consts : Std.HashMap Name (UInt64 × ConstantInfo) := {}
  entries : Std.HashMap (Name × Name × UInt64) Keyed := {}

structure ModOut where
  m : Name
  md : ModuleData
  ks : Array (Name × Array Keyed)
  extra : Array Name
  chash : Array UInt64
  ehash : Array (Array UInt64)
  cShared : Nat
  eShared : Nat
  decNs : Nat
  hashNs : Nat
  subNs : Nat

instance : Inhabited ModOut := ⟨⟨.anonymous, default, #[], #[], #[], #[], 0, 0, 0, 0, 0⟩⟩

unsafe def decodeOne (sp : Array System.FilePath) (seed : UInt64) (prev : Prev) (stats : IO.Ref ReadStats)
    (m : Name) : IO ModOut := do
  let t0 ← IO.monoNanosNow
  let parts ← loadModule sp m
  let ((md, ks), _) ← runDM parts (decModuleData true true parts.back!.root stats)
  let extra ← if md.isModule then readIRExtraConstNames sp m else pure md.extraConstNames
  let t1 ← IO.monoNanosNow
  let ((ch, eh), _) ← runDM parts (hashModule seed parts.back!.root)
  let t2 ← IO.monoNanosNow
  unless ch.size == md.constants.size && eh.size == ks.size do
    throw <| IO.userError s!"patch: hash layout of {m} differs from the decoded one"
  let mut cs := Array.mkEmpty md.constants.size
  let mut cShared := 0
  for n in md.constNames, c in md.constants, h in ch do
    match prev.consts[n]? with
    | some (h', c') =>
      if h' == h then
        cs := cs.push c'
        cShared := cShared + 1
      else
        cs := cs.push c
    | none => cs := cs.push c
  let mut ks' := Array.mkEmpty ks.size
  let mut eShared := 0
  let mut ehs := Array.mkEmpty ks.size
  for idx in [0:ks.size] do
    let (e, es) := ks[idx]!
    let (e', hs) := eh[idx]!
    unless e == e' && es.size == hs.size do
      throw <| IO.userError s!"patch: entry hashes of {m}/{e} differ from the decoded entries"
    let mut es' := Array.mkEmpty es.size
    for k in es, h in hs do
      match prev.entries[(e, k.1, h)]? with
      | some k' =>
        es' := es'.push k'
        eShared := eShared + 1
      | none => es' := es'.push k
    ks' := ks'.push (e, es')
    ehs := ehs.push hs
  let md := { md with constants := cs, entries := ks'.map fun (e, es) => (e, es.map (·.2)) }
  let t3 ← IO.monoNanosNow
  return { m, md, ks := ks', extra, chash := ch, ehash := ehs, cShared, eShared,
           decNs := t1 - t0, hashNs := t2 - t1, subNs := t3 - t2 }

/-- `Assemble.decodeAll`'s fold, on modules already decoded. -/
unsafe def foldDecoded (mods : Array Name) (outs : Array ModOut) (stats : ReadStats) : Decoded := Id.run do
  let mut out := #[]
  let mut chunks : Array (Name × Nat × Array Keyed) := #[]
  let mut modDocs : Std.HashMap Name (Array ModuleDoc) := {}
  let mut modOf : Std.HashMap Name Name := {}
  let mut consts : Std.HashSet Name := {}
  let mut index : Std.HashMap Name Nat := {}
  let mut constNames := #[]
  let mut imports := #[]
  for mo in outs do
    let m := mo.m
    let md := mo.md
    out := out.push (m, md)
    index := index.insert m index.size
    constNames := constNames.push md.constNames
    imports := imports.push (md.imports.map (·.module))
    for (e, es) in mo.ks do
      if placementOf e == some .perModule then
        modDocs := modDocs.insert m (es.map fun k => (unsafeCast k.2 : ModuleDoc))
      else
        chunks := chunks.push (e, index[m]!, es)
    for n in md.constNames do
      consts := consts.insert n
      unless modOf.contains n do modOf := modOf.insert n m
    for n in mo.extra do
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
  return { mods := out, keyed := extOrder.map (fun e => (e, keyed.getD e #[])), stats, old }

structure DecodeTimes where
  wallMs : Nat
  decNs : Nat
  hashNs : Nat
  subNs : Nat
  foldMs : Nat
  prevMs : Nat
  cShared : Nat
  eShared : Nat

/-- Every module of the closure, `jobs` at a time, then the fold; and the content map the next
version is matched against. -/
unsafe def decodeVersion (sp : Array System.FilePath) (mods : Array Name) (jobs : Nat) (prev : Prev) :
    IO (Decoded × Prev × DecodeTimes) := do
  let t0 ← IO.monoMsNow
  let stats ← IO.mkRef ({} : ReadStats)
  let first ← loadPart (← findOlean sp mods[0]!)
  let seed := writerSeed first.ver
  let outs ← if jobs ≤ 1 then mods.mapM (decodeOne sp seed prev stats) else do
    let prio := if (← IO.getEnv "PATCH_POOL") == some "1" then Task.Priority.default else .dedicated
    let tasks ← (Array.range jobs).mapM fun k => IO.asTask (prio := prio) do
      let mut acc : Array (Nat × ModOut) := #[]
      let mut i := k
      while i < mods.size do
        acc := acc.push (i, ← decodeOne sp seed prev stats mods[i]!)
        i := i + jobs
      return acc
    let mut slots : Array ModOut := Array.replicate mods.size default
    for t in tasks do
      for (i, mo) in ← IO.ofExcept t.get do slots := slots.set! i mo
    pure slots
  let t1 ← IO.monoMsNow
  let d := foldDecoded mods outs (← stats.get)
  let t2 ← IO.monoMsNow
  let mut pc : Std.HashMap Name (UInt64 × ConstantInfo) := {}
  let mut pe : Std.HashMap (Name × Name × UInt64) Keyed := {}
  let mut times : DecodeTimes := { wallMs := t1 - t0, decNs := 0, hashNs := 0, subNs := 0, foldMs := t2 - t1, prevMs := 0, cShared := 0, eShared := 0 }
  let mut tPc := 0
  for mo in outs do
    times := { times with decNs := times.decNs + mo.decNs, hashNs := times.hashNs + mo.hashNs, subNs := times.subNs + mo.subNs,
                          cShared := times.cShared + mo.cShared, eShared := times.eShared + mo.eShared }
    let tq0 ← IO.monoNanosNow
    for n in mo.md.constNames, c in mo.md.constants, h in mo.chash do
      pc := pc.insertIfNew n (h, c)
    tPc := tPc + ((← IO.monoNanosNow) - tq0)
    for idx in [0:mo.ks.size] do
      let (e, es) := mo.ks[idx]!
      let hs := mo.ehash[idx]!
      for k in es, h in hs do pe := pe.insertIfNew (e, k.1, h) k
  let t3 ← IO.monoMsNow
  IO.eprintln s!"prev map: constants {tPc / 1000000} ms of {t3 - t2} ms"
  return (d, { consts := pc, entries := pe }, { times with prevMs := t3 - t2 })

/-! ## The merged module data, module by module -/

unsafe def isModuleSys (im : MImportedModule) : Bool := (im.parts[0]!.1).isModule
unsafe def mainPart (im : MImportedModule) : Nat := if isModuleSys im then 2 else 0

def sortKeyed (ks : Array Keyed) : Array EnvExtensionEntry :=
  (ks.qsort (fun a b => Name.quickLt a.1 b.1)).map (·.2)

/-- The newest import and what a patch needs to know about it, computed once. -/
structure NewestIndex where
  ms : MImportState
  names : Array Name
  extraIdx : Nat
  /-- First (module, position) of each constant name over the main parts, in import order. -/
  firstOcc : Std.HashMap Name (Nat × Nat)
  modsOf : Std.HashMap Name (Array Nat)
  /-- A name `p` (and `privateToUserName p`) → the modules holding a realizable `p.<suffix>`. -/
  reservedOf : Std.HashMap Name (Array Nat)
  /-- (decoded extension, key of a newest entry) → the modules holding such an entry. -/
  keyMods : Std.HashMap (Name × Name) (Array Nat)
  keyExts : Array Name

def pushUniq {κ : Type} [BEq κ] [Hashable κ] (m : Std.HashMap κ (Array Nat)) (k : κ) (i : Nat) : Std.HashMap κ (Array Nat) :=
  m.alter k fun
    | none => some #[i]
    | some a => some (if a.back? == some i then a else a.push i)

unsafe def buildNewestIndex (ms : MImportState) : IO NewestIndex := do
  let keyOf := rawKeys
  let mut firstOcc : Std.HashMap Name (Nat × Nat) := {}
  let mut modsOf : Std.HashMap Name (Array Nat) := {}
  let mut reservedOf : Std.HashMap Name (Array Nat) := {}
  let mut keyMods : Std.HashMap (Name × Name) (Array Nat) := {}
  let mut keyExts : Array Name := #[]
  let mut tc := 0
  let mut te := 0
  for i in [0:ms.moduleNames.size] do
    let ta ← IO.monoNanosNow
    let im := ms.moduleNameMap[ms.moduleNames[i]!]!
    if im.parts.isEmpty then continue
    let md := im.parts[mainPart im]!.1
    for j in [0:md.constNames.size] do
      let n := md.constNames[j]!
      firstOcc := firstOcc.insertIfNew n (i, j)
      modsOf := pushUniq modsOf n i
      if let .str p sfx := privateToUserName n then
        if (reservedSuffix? sfx).isSome then
          reservedOf := pushUniq reservedOf p i
          reservedOf := pushUniq reservedOf (privateToUserName p) i
    let tb ← IO.monoNanosNow
    tc := tc + (tb - ta)
    for (e, es) in md.entries do
      match placementOf e with
      | some pl =>
        if pl == .perModule || pl == .keysOnly then continue
        let some kf := keyOf.lookup e
          | throw <| IO.userError s!"patch: no key function for decoded extension {e}"
        unless keyExts.contains e do keyExts := keyExts.push e
        for x in es do keyMods := pushUniq keyMods (e, kf x) i
      | none => pure ()
    te := te + ((← IO.monoNanosNow) - tb)
  IO.eprintln s!"newest index: constants {tc / 1000000} ms, entries {te / 1000000} ms; names {firstOcc.size}, keyed exts {keyExts.size}, keys {keyMods.size}"
  return { ms, names := ms.moduleNames, extraIdx := ms.moduleNames.size, firstOcc, modsOf, reservedOf, keyMods, keyExts }

def isReservedNewest (oldConsts : Std.HashMap Name ConstantInfo) (n : Name) : Bool :=
  match privateToUserName n with
  | .str p sfx =>
    match reservedSuffix? sfx with
    | some _ => oldConsts.contains p || oldConsts.contains (privateToUserName p)
    | none => false
  | _ => false

/-- One newest module's constants as `rewriteMerge` leaves them. -/
unsafe def rewriteConsts (ni : NewestIndex) (i : Nat) (md : ModuleData) (oldConsts : Std.HashMap Name ConstantInfo) :
    Array Name × Array ConstantInfo := Id.run do
  let mut cn := #[]
  let mut cs := #[]
  for j in [0:md.constNames.size] do
    let n := md.constNames[j]!
    match oldConsts[n]? with
    | some oc =>
      if ni.firstOcc[n]? == some (i, j) then
        cn := cn.push n
        cs := cs.push oc
    | none =>
      unless isReservedNewest oldConsts n do
        cn := cn.push n
        cs := cs.push md.constants[j]!
  return (cn, cs)

/-- One newest module's entries as `rewriteMerge` leaves them. -/
unsafe def mergeEntries (md : ModuleData) (olds : Std.HashMap Name (Array Keyed))
    (oldConsts : Std.HashMap Name ConstantInfo) (oldKeys : Std.HashMap Name (Std.HashSet Name)) :
    IO (Array (Name × Array EnvExtensionEntry)) := do
  let keyOf := rawKeys
  let mut merged : Array (Name × Array EnvExtensionEntry) := #[]
  let mut seenExt : NameSet := {}
  for (e, es) in md.entries do
    match placementOf e with
    | some pl =>
      if pl == .perModule || pl == .keysOnly then continue
      let some kf := keyOf.lookup e
        | throw <| IO.userError s!"hybrid: no key function for decoded extension {e}"
      let ok := oldKeys.getD e {}
      let kept := es.filterMap fun x =>
        let k := kf x
        if oldConsts.contains k || ok.contains k then none else some (k, x)
      let entries := if pl == .byKey then sortKeyed (kept ++ olds.getD e #[]) else kept.map (·.2)
      merged := merged.push (e, entries)
      seenExt := seenExt.insert e
    | none =>
      if keepNewest e then merged := merged.push (e, es)
  for (e, ks) in olds.toArray do
    unless seenExt.contains e do merged := merged.push (e, sortKeyed ks)
  return merged

/-- Everything the merged state of one version is computed from, kept for the next patch. -/
structure Built where
  oldConsts : Std.HashMap Name ConstantInfo
  oldOrder : Array Name
  oldKeys : Std.HashMap Name (Std.HashSet Name)
  idxOf : Std.HashMap Name Nat
  perMod : Std.HashMap Nat (Std.HashMap Name (Array Keyed))
  stateOld : Array (Name × Array EnvExtensionEntry)
  out : MImportState

unsafe def oldConstsOf (d : Decoded) : Std.HashMap Name ConstantInfo × Array Name := Id.run do
  let mut oldConsts : Std.HashMap Name ConstantInfo := {}
  let mut oldOrder : Array Name := #[]
  for (_, md) in d.mods do
    for n in md.constNames, c in md.constants do
      unless oldConsts.contains n do
        oldConsts := oldConsts.insert n c
        oldOrder := oldOrder.push n
  return (oldConsts, oldOrder)

unsafe def idxOfState (ni : NewestIndex) (mm : Std.HashMap Name MImportedModule) (xn : Array Name) : Std.HashMap Name Nat := Id.run do
  let mut idxOf : Std.HashMap Name Nat := {}
  for i in [0:ni.names.size] do
    let im := mm[ni.names[i]!]!
    if im.parts.isEmpty then continue
    for n in (im.parts[mainPart im]!.1).constNames do
      unless idxOf.contains n do idxOf := idxOf.insert n i
    let irData := if im.irParts.isEmpty || !isModuleSys im then im.parts[mainPart im]!.1 else im.irParts.back!.1
    for n in irData.extraConstNames do
      unless idxOf.contains n do idxOf := idxOf.insert n i
  for n in xn do
    unless idxOf.contains n do idxOf := idxOf.insert n ni.extraIdx
  return idxOf

/-- Where the old entries go (`rewriteMerge`'s placement), built without copying: the same maps,
keys inserted in the same order. -/
unsafe def placement (ni : NewestIndex) (d : Decoded) (idxOf : Std.HashMap Name Nat) :
    Std.HashMap Nat (Std.HashMap Name (Array Keyed)) × Array (Name × Array EnvExtensionEntry) ×
      Std.HashMap Name (Std.HashSet Name) := Id.run do
  let mut acc : Std.HashMap (Nat × Name) (Array Keyed) := {}
  let mut outer : Array Nat := #[]
  let mut seenOuter : Std.HashSet Nat := {}
  let mut inner : Std.HashMap Nat (Array Name) := {}
  let mut stateOld : Array (Name × Array EnvExtensionEntry) := #[]
  let mut oldKeys : Std.HashMap Name (Std.HashSet Name) := {}
  for (e, es) in d.keyed do
    oldKeys := oldKeys.insert e (es.foldl (fun s (_, k) => s.insert k.1) {})
    let mut targets : Array (Nat × Keyed) := #[]
    match placementOf e with
    | some .byKey =>
      for (src, k) in es do
        if d.old.modOf[k.1]? == some d.old.moduleNames[src]! then
          targets := targets.push (idxOf.getD k.1 ni.extraIdx, k)
    | some .allModules =>
      let mut rank : Std.HashMap Nat Nat := {}
      for (src, k) in es do
        let r ← match rank[src]? with
          | some r => pure r
          | none => do let r := rank.size; rank := rank.insert src r; pure r
        targets := targets.push (r, k)
    | some .state => stateOld := stateOld.push (e, es.map (·.2.2))
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
  return (perMod, stateOld, oldKeys)

unsafe def extraModule (xn : Array Name) (oldConsts : Std.HashMap Name ConstantInfo)
    (perMod : Std.HashMap Nat (Std.HashMap Name (Array Keyed))) (extraIdx : Nat)
    (stateOld : Array (Name × Array EnvExtensionEntry)) : MImportedModule := Id.run do
  let xc := xn.map (oldConsts[·]!)
  let mut extraEntries := ((perMod.getD extraIdx {}).toArray.map fun (e, ks) => (e, sortKeyed ks))
  for (e, es) in stateOld do
    match extraEntries.findIdx? (·.1 == e) with
    | some j => extraEntries := extraEntries.modify j fun (e, xs) => (e, xs ++ es)
    | none => extraEntries := extraEntries.push (e, es)
  let extra : ModuleData := {
    isModule := false, imports := #[], constNames := xn, constants := xc,
    extraConstNames := #[], entries := extraEntries }
  return decodedModule `_olean_reader.OldOnly extra

structure PatchStats where
  constChanged : Nat := 0
  constAdded : Nat := 0
  constRemoved : Nat := 0
  constSame : Nat := 0
  dirtyConst : Nat := 0
  dirtyOlds : Nat := 0
  dirtyFilter : Nat := 0
  dirty : Nat := 0
  modules : Nat := 0
  keyChanges : Nat := 0
  tDelta : Nat := 0
  tConsts : Nat := 0
  tIdx : Nat := 0
  tPlace : Nat := 0
  tDirty : Nat := 0
  tMerge : Nat := 0
  tExtra : Nat := 0
  deriving Repr

@[inline] unsafe def same {α} (a b : α) : Bool := ptrAddrUnsafe a == ptrAddrUnsafe b

unsafe def sameKeyedArr (a b : Array Keyed) : Bool :=
  a.size == b.size && (a.zip b).all fun (x, y) => same x y

unsafe def sameOlds (a b : Std.HashMap Name (Array Keyed)) : Bool :=
  let x := a.toArray
  let y := b.toArray
  x.size == y.size && (Array.range x.size).all fun i => x[i]!.1 == y[i]!.1 && sameKeyedArr x[i]!.2 y[i]!.2

/-- Builds the merged state of `d`: from nothing when `prev?` is `none`, otherwise by rewriting
only the newest modules whose inputs differ from the previous version's. `perturb` leaves one
module that should be rewritten as it was (the falsifier of the oracle comparison). -/
unsafe def build (ni : NewestIndex) (d : Decoded) (prev? : Option Built) (perturb : Bool := false) :
    IO (Built × PatchStats) := do
  let mut ps : PatchStats := { modules := ni.names.size }
  let t0 ← IO.monoMsNow
  let (oldConsts, oldOrder) := oldConstsOf d
  -- constants whose decoded object differs (content or presence)
  let mut changed : Array Name := #[]
  let mut presence : Std.HashSet Name := {}
  if let some pb := prev? then
    for (n, c) in oldConsts do
      match pb.oldConsts[n]? with
      | some c' =>
        if same c c' then
          ps := { ps with constSame := ps.constSame + 1 }
        else
          changed := changed.push n
          ps := { ps with constChanged := ps.constChanged + 1 }
      | none =>
        changed := changed.push n
        presence := presence.insert n
        ps := { ps with constAdded := ps.constAdded + 1 }
    for (n, _) in pb.oldConsts do
      unless oldConsts.contains n do
        changed := changed.push n
        presence := presence.insert n
        ps := { ps with constRemoved := ps.constRemoved + 1 }
  let t1 ← IO.monoMsNow
  -- constants: dirty modules rewritten
  let mut dirtyC : Std.HashSet Nat := {}
  if prev?.isSome then
    for n in changed do
      for i in ni.modsOf.getD n #[] do dirtyC := dirtyC.insert i
    for n in presence do
      for i in ni.reservedOf.getD n #[] do dirtyC := dirtyC.insert i
  if perturb then
    if let some i := dirtyC.toArray.qsort (· < ·) |>.back? then dirtyC := dirtyC.erase i
  let base := match prev? with | some pb => pb.out | none => ni.ms
  let mut rewritten : Std.HashMap Nat (Array Name × Array ConstantInfo) := {}
  for i in [0:ni.names.size] do
    if prev?.isSome && !dirtyC.contains i then continue
    let im := ni.ms.moduleNameMap[ni.names[i]!]!
    if im.parts.isEmpty then continue
    rewritten := rewritten.insert i (rewriteConsts ni i im.parts[mainPart im]!.1 oldConsts)
  let t1a ← IO.monoMsNow
  -- the state with rewritten constants (entries as before) is what `idxOf` reads
  let mut mm := base.moduleNameMap
  for (i, (cn, cs)) in rewritten do
    let name := ni.names[i]!
    let im := mm[name]!
    let pi := mainPart im
    let (md, region) := im.parts[pi]!
    mm := mm.insert name { im with parts := im.parts.set! pi ({ md with constNames := cn, constants := cs }, region) }
  let t1b ← IO.monoMsNow
  let newestNames := ni.firstOcc
  let xn := oldOrder.filter fun n => !newestNames.contains n
  let t2 ← IO.monoMsNow
  IO.eprintln s!"patch consts: rewrite {t1a - t1} ms, module map {t1b - t1a} ms, old-only list {t2 - t1b} ms"
  let idxOf := idxOfState ni mm xn
  let t3 ← IO.monoMsNow
  let (perMod, stateOld, oldKeys) := placement ni d idxOf
  let t4 ← IO.monoMsNow
  -- entries: modules whose placed old entries or whose kept-newest filter changed
  let mut dirtyE : Std.HashSet Nat := {}
  let mut nOlds := 0
  let mut nFilter := 0
  if let some pb := prev? then
    let mut idxs : Std.HashSet Nat := {}
    for (i, _) in perMod do idxs := idxs.insert i
    for (i, _) in pb.perMod do idxs := idxs.insert i
    for i in idxs do
      if i == ni.extraIdx then continue
      if !sameOlds (perMod.getD i {}) (pb.perMod.getD i {}) then
        dirtyE := dirtyE.insert i
        nOlds := nOlds + 1
    for e in ni.keyExts do
      let a := oldKeys.getD e {}
      let b := pb.oldKeys.getD e {}
      let mut flips : Array Name := #[]
      for k in a do unless b.contains k do flips := flips.push k
      for k in b do unless a.contains k do flips := flips.push k
      ps := { ps with keyChanges := ps.keyChanges + flips.size }
      for k in flips ++ presence.toArray do
        for i in ni.keyMods.getD (e, k) #[] do
          unless dirtyE.contains i do
            dirtyE := dirtyE.insert i
            nFilter := nFilter + 1
  let t5 ← IO.monoMsNow
  for i in [0:ni.names.size] do
    if prev?.isSome && !dirtyE.contains i && !dirtyC.contains i then continue
    let name := ni.names[i]!
    let im0 := ni.ms.moduleNameMap[name]!
    if im0.parts.isEmpty then continue
    let im := mm[name]!
    let pi := mainPart im
    let (md, region) := im.parts[pi]!
    let merged ← mergeEntries im0.parts[pi]!.1 (perMod.getD i {}) oldConsts oldKeys
    mm := mm.insert name { im with parts := im.parts.set! pi ({ md with entries := merged }, region) }
  let t6 ← IO.monoMsNow
  let extraName := `_olean_reader.OldOnly
  mm := mm.insert extraName (extraModule xn oldConsts perMod ni.extraIdx stateOld)
  let out : MImportState := { moduleNameMap := mm, moduleNames := ni.names.push extraName }
  checkMirror out
  let t7 ← IO.monoMsNow
  let mut dirtyAll := dirtyE
  for i in dirtyC do dirtyAll := dirtyAll.insert i
  ps := { ps with dirtyConst := dirtyC.size, dirtyOlds := nOlds, dirtyFilter := nFilter, dirty := dirtyAll.size,
                  tDelta := t1 - t0, tConsts := t2 - t1, tIdx := t3 - t2, tPlace := t4 - t3, tDirty := t5 - t4,
                  tMerge := t6 - t5, tExtra := t7 - t6 }
  return ({ oldConsts, oldOrder, oldKeys, idxOf, perMod, stateOld, out }, ps)

/-- Module by module, pointer by pointer: the patched state against `rewriteMerge`'s. -/
unsafe def compareStates (a b : MImportState) : IO (Nat × Array String) := do
  let mut bad := 0
  let mut notes : Array String := #[]
  let note (s : String) (notes : Array String) := if notes.size < 40 then notes.push s else notes
  unless a.moduleNames == b.moduleNames do
    return (1, #["module name lists differ"])
  for name in a.moduleNames do
    let ia := a.moduleNameMap[name]!
    let ib := b.moduleNameMap[name]!
    let mut ok := ia.module == ib.module && ia.importAll == ib.importAll && ia.isExported == ib.isExported &&
      ia.isMeta == ib.isMeta && ia.hasData == ib.hasData && ia.needsIRTrans == ib.needsIRTrans &&
      ia.parts.size == ib.parts.size && ia.irParts.size == ib.irParts.size
    if !ok then
      bad := bad + 1
      notes := note s!"{name}: module record differs" notes
      continue
    for j in [0:ia.irParts.size] do
      unless same ia.irParts[j]!.1 ib.irParts[j]!.1 do ok := false
    for j in [0:ia.parts.size] do
      let (ma, ra) := ia.parts[j]!
      let (mb, rb) := ib.parts[j]!
      unless same ra rb || name == `_olean_reader.OldOnly do
        ok := false
        notes := note s!"{name}: region {j}" notes
      unless ma.isModule == mb.isModule && ma.imports.size == mb.imports.size do ok := false
      unless ma.constNames == mb.constNames do
        ok := false
        notes := note s!"{name}: part {j} constNames" notes
      unless ma.constants.size == mb.constants.size &&
          (ma.constants.zip mb.constants).all (fun (x, y) => same x y) do
        ok := false
        notes := note s!"{name}: part {j} constants" notes
      unless ma.extraConstNames == mb.extraConstNames do
        ok := false
        notes := note s!"{name}: part {j} extraConstNames" notes
      if ma.entries.size != mb.entries.size then
        ok := false
        notes := note s!"{name}: part {j} entries {ma.entries.size} vs {mb.entries.size}" notes
      else
        for k in [0:ma.entries.size] do
          let (ea, xa) := ma.entries[k]!
          let (eb, xb) := mb.entries[k]!
          unless ea == eb && xa.size == xb.size && (xa.zip xb).all (fun (x, y) => same x y) do
            ok := false
            notes := note s!"{name}: part {j} entries of {ea} ({xa.size}) vs {eb} ({xb.size})" notes
    unless ok do bad := bad + 1
  return (bad, notes)

end Patch
