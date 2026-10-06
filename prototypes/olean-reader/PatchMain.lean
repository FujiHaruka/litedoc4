import OleanReader
import Assemble
import Patch
import Extract
import PrintKey
import Snap
open Lean OleanReader Litedoc4

/-! Several versions in one process: the newest import once, the first version's hybrid built
whole, every later version's hybrid patched from the previous one, keys recomputed, and only the
declarations whose key changed printed again. -/

def readSearchPath (f : System.FilePath) : IO (Array System.FilePath) := do
  return (← IO.FS.lines f).filter (!·.isEmpty) |>.map System.FilePath.mk

structure HardStops where
  verso : IO.Ref (Array Name)
  builtinDoc : IO.Ref (Array Name)

/-- `HybridMain.hybridWorld`, verbatim. -/
def hybridWorld (env : Environment) (o : Assemble.OldWorld) (hs : HardStops) : World :=
  { moduleNames := o.moduleNames
    moduleIndex? := fun m => o.index[m]?
    constNames := fun i => o.constNames[i]!
    imports := fun i => o.imports[i]!
    moduleOf? := fun n => o.modOf[n]?
    contains := fun n => o.consts.contains n
    moduleDocs := fun m => o.modDocs.getD m #[]
    docString? := fun n => do
      let start := (Parser.Tactic.Doc.alternativeOfTactic env n).getD n
      let mut t := start
      let mut steps := 0
      while steps < 64 do
        match o.inherit[t]? with
        | some u => t := u; steps := steps + 1
        | none => break
      if o.docKeys.contains t then
        findDocString? env n
      else if o.versoKeys.contains t then
        hs.verso.modify (·.push n)
        return some s!"<hard stop: the docstring of {t} is Verso and was not decoded>"
      else
        match ← findDocString? env n with
        | none => return none
        | some _ =>
          hs.builtinDoc.modify (·.push n)
          return some s!"<hard stop: the docstring of {t} came from v{Lean.versionString}'s builtin table>"
    tactics := pure none }

structure MRealCtx where
  env : NonScalar
  opts : NonScalar
  realizeMapRef : IO.Ref (NameMap NonScalar)

/-- `Lean.Environment`'s fields in order; only the realization context is read. -/
structure MEnv where
  base : NonScalar
  serverBaseExts : NonScalar
  checked : NonScalar
  asyncConstsMap : NonScalar
  asyncCtx? : NonScalar
  importRealizationCtx? : Option MRealCtx
  localRealizationCtxMap : NonScalar
  allRealizations : NonScalar
  isExporting : Bool

/-- Empties the map of realizations of imported constants (equation lemmas the extraction
generated), returning how many kinds and entries it held. -/
unsafe def clearRealizations (env : Environment) : IO (Nat × Nat) := do
  let me : MEnv := unsafeCast env
  match me.importRealizationCtx? with
  | none => return (0, 0)
  | some c =>
    let m ← c.realizeMapRef.get
    let mut n := 0
    for (_, v) in m.toList do n := n + (unsafeCast v : PersistentHashMap Name NonScalar).foldl (fun k _ _ => k + 1) 0
    c.realizeMapRef.set {}
    return (m.toList.length, n)

structure RoundSpec where
  label : String
  sp : String
  modules : String
  key : String
  decodeJobs : Nat
  refIr : String
  refLidx : String
  keep : Bool

def parseSpec (line : String) : Except String RoundSpec :=
  match line.splitOn "\t" with
  | [label, sp, modules, key, dj, refIr, refLidx, keep] =>
    match dj.toNat? with
    | some j => .ok { label, sp, modules, key, decodeJobs := j, refIr, refLidx, keep := keep == "1" }
    | none => .error s!"bad decode jobs {dj}"
  | _ => .error s!"bad round line: {line}"

def emit (r : Nat) (phase : String) (ms : Nat) (extra : String := "") : IO Unit :=
  IO.eprintln s!"TIME r{r} {phase} {ms}{if extra.isEmpty then "" else " " ++ extra}"

/-- The differences between two versions' old-data records, piece by piece. -/
unsafe def recordDelta (a b : Assemble.OldWorld) : String := Id.run do
  let setOf (xs : Array Name) : Std.HashSet Name := xs.foldl (·.insert ·) {}
  let ma := setOf a.moduleNames
  let mb := setOf b.moduleNames
  let added := b.moduleNames.filter (!ma.contains ·) |>.size
  let removed := a.moduleNames.filter (!mb.contains ·) |>.size
  let mut cnDiff := 0
  let mut impDiff := 0
  let mut docDiff := 0
  for m in b.moduleNames do
    match a.index[m]?, b.index[m]? with
    | some i, some j =>
      if a.constNames[i]! != b.constNames[j]! then cnDiff := cnDiff + 1
      if a.imports[i]! != b.imports[j]! then impDiff := impDiff + 1
      let da := a.modDocs.getD m #[]
      let db := b.modDocs.getD m #[]
      unless da.size == db.size && (da.zip db).all (fun (x, y) => ptrAddrUnsafe x == ptrAddrUnsafe y) do
        docDiff := docDiff + 1
    | _, _ => pure ()
  let mut modOfDiff := 0
  for (n, m) in b.modOf do
    if a.modOf[n]? != some m then modOfDiff := modOfDiff + 1
  for (n, _) in a.modOf do
    unless b.modOf.contains n do modOfDiff := modOfDiff + 1
  let symm (x y : Std.HashSet Name) : Nat :=
    (x.fold (fun k n => if y.contains n then k else k + 1) 0) + (y.fold (fun k n => if x.contains n then k else k + 1) 0)
  let mut inhDiff := 0
  for (n, t) in b.inherit do
    if a.inherit[n]? != some t then inhDiff := inhDiff + 1
  for (n, _) in a.inherit do
    unless b.inherit.contains n do inhDiff := inhDiff + 1
  return s!"modules +{added} -{removed}; constNames differ in {cnDiff} common modules; imports differ in {impDiff}; module docs differ in {docDiff}; moduleOf differs for {modOfDiff} names; constant set symmetric difference {symm a.consts b.consts}; docstring keys {symm a.docKeys b.docKeys}; Verso keys {symm a.versoKeys b.versoKeys}; inherit_doc {inhDiff}; stored axiom lists {symm a.axiomKeys b.axiomKeys}"

def shell (cmd : String) : IO Unit := do
  let out ← IO.Process.output { cmd := "/bin/sh", args := #["-c", cmd] }
  unless out.exitCode == 0 do
    throw <| IO.userError s!"shell failed ({out.exitCode}): {cmd}\n{out.stderr}"

/-- Lines of a sha256 list, keyed by path with any leading `./` or `ir/` dropped. -/
def shaMap (path : System.FilePath) : IO (Std.HashMap String String) := do
  let mut m : Std.HashMap String String := {}
  for l in ← IO.FS.lines path do
    match l.splitOn "  " with
    | [h, p] =>
      let p := if p.startsWith "./" then (p.drop 2).toString else if p.startsWith "ir/" then (p.drop 3).toString else p
      m := m.insert p h
    | _ => pure ()
  return m

/-! ## The key-pass profile (E1): several `keysPar` variants in one round, checked against the first -/

structure ProfCarry where
  prev : Option (Std.HashMap Name PrintKey.Rec × Std.HashMap UInt64 UInt64) := none
  aliases : Std.HashSet (Name × Name) := {}
  namespaces : Std.HashSet Name := {}
  envAliases : Std.HashSet (Name × Name) := {}
  filled : Bool := false

unsafe def decodedAliasNs (d : Assemble.Decoded) : Std.HashSet (Name × Name) × Std.HashSet Name := Id.run do
  let nsExt := Name.mkNum `_private.Lean.Namespace 0 ++ `Lean.namespacesExt
  let mut al : Std.HashSet (Name × Name) := {}
  let mut ns : Std.HashSet Name := {}
  for (e, es) in d.keyed do
    if e == `Lean.aliasExtension then
      for (_, k) in es do al := al.insert (unsafeCast k.2 : Name × Name)
    else if e == nsExt then
      for (_, k) in es do ns := ns.insert (unsafeCast k.2 : Name)
  return (al, ns)

def setDiff {α : Type} [BEq α] [Hashable α] (a b : Std.HashSet α) : Nat × Nat :=
  (b.fold (fun k x => if a.contains x then k else k + 1) 0, a.fold (fun k x => if b.contains x then k else k + 1) 0)

def statsLine (s : PrintKey.KStats) : String :=
  s!"decls {s.decls} tTask {s.tTask} tKey {s.tKey} tOwnHash {s.tOwnHash} tMembers {s.tMembers} tSkelT {s.tSkelT} tEqn {s.tEqn} tSkelV {s.tSkelV} tVal {s.tVal} tShown {s.tShown} tLoop {s.tLoop} recHit {s.recHit} recMiss {s.recMiss} tRec {s.tRec} tRecType {s.tRecType} tRecValue {s.tRecValue} tRecStruct {s.tRecStruct} tRecOther {s.tRecOther} resHit {s.resHit} resMiss {s.resMiss} resRecomputed {s.resRecomputed} resResets {s.resResets} tRes {s.tRes} tRevAlias {s.tRevAlias} revAliasFound {s.revAliasFound} resolveCalls {s.resolveCalls} ownRecMiss {s.ownRecMiss} tOwnRec {s.tOwnRec} shownSum {s.shownSum} spacesSum {s.spacesSum}"

unsafe def keyProfile (r : Nat) (dir : System.FilePath) (env0 : Environment) (world : World) (targets : Array Name)
    (plan : String) (carry : ProfCarry) (d : Assemble.Decoded) (prevKeys : Std.HashMap Name (UInt64 × UInt64)) :
    IO (Std.HashMap Name (UInt64 × UInt64) × Nat × ProfCarry) := do
  let mut env := env0
  let mut persistent := false
  let mut ref? : Option (Std.HashMap Name (UInt64 × UInt64)) := none
  let mut missing0 := 0
  let mut carry' := carry
  let mut vi := 0
  for v in plan.splitOn "," do
    if v == "persist" then
      let t0 ← IO.monoMsNow
      env ← Runtime.markPersistent env
      persistent := true
      emit r "mark-persistent" ((← IO.monoMsNow) - t0)
      continue
    let some (mode, jobs) := (match v.splitOn ":" with
        | [m, j] => j.toNat?.map (m, ·)
        | _ => none)
      | throw <| IO.userError s!"keyprof: bad variant {v}"
    let prof := mode == "prof"
    let rep ← IO.mkRef ({} : PrintKey.KReport)
    let prevArg := if prof && jobs == 1 then carry.prev else none
    let t0 ← IO.monoMsNow
    let (keys, missing) ← PrintKey.keysPar env world targets jobs (if prof then some rep else none) prevArg
    let t1 ← IO.monoMsNow
    let label := s!"{mode}{jobs}{if persistent then "p" else ""}"
    emit r s!"keys-{vi}-{label}" (t1 - t0) s!"candidates {keys.size} missing {missing}"
    let f := dir / s!"keys-{vi}-{label}.tsv"
    let sorted := keys.toArray.qsort (fun a b => Name.quickLt a.1 b.1)
    let h ← IO.FS.Handle.mk f .write
    let mut buf : Array String := #[]
    for (n, g, o) in sorted do
      buf := buf.push s!"{n}\t{g}\t{o}\n"
      if buf.size ≥ 20000 then
        h.putStr (String.join buf.toList); buf := #[]
    h.putStr (String.join buf.toList)
    h.flush
    let out ← IO.Process.output { cmd := "/usr/bin/shasum", args := #["-a", "256", f.toString] }
    IO.eprintln s!"KEYHASH r{r} v{vi} {label} {(out.stdout.splitOn " ").head!} lines {sorted.size}"
    IO.FS.removeFile f
    match ref? with
    | none =>
      ref? := some keys
      missing0 := missing
    | some ref =>
      let mut diff := 0
      for (n, k) in keys do
        unless ref[n]? == some k do diff := diff + 1
      for (n, _) in ref do
        unless keys.contains n do diff := diff + 1
      IO.eprintln s!"KEYCHECK r{r} v{vi} {label}: {keys.size} keys, reference {ref.size}, differing or missing {diff}"
    if prof then
      let rp ← rep.get
      let tot := rp.threads.foldl PrintKey.KStats.add {}
      IO.eprintln s!"KSTATS r{r} v{vi} {label} total {statsLine tot}"
      for i in [0:rp.threads.size] do
        IO.eprintln s!"KSTATS r{r} v{vi} {label} thread{i} {statsLine rp.threads[i]!}"
      IO.eprintln s!"KDISTINCT r{r} v{vi} {label} pairs {rp.distinctPairs} records {rp.distinctRecs}"
      if jobs == 1 then
        let rf := dir / s!"keyrows-r{r}.tsv"
        let h ← IO.FS.Handle.mk rf .write
        h.putStr "name\tshown\tspaces\townH\tsn\tsres\tg7\town\ttKey\ttOwnRec\ttOwn\ttSkel\ttRecMiss\ttResMiss\tnRecMiss\tnResMiss\trecChanged\tresChanged\n"
        let mut rbuf : Array String := #[]
        for w in rp.rows do
          let c := w.cur
          rbuf := rbuf.push s!"{w.name}\t{c.shown}\t{c.spaces}\t{w.ownH}\t{w.sn}\t{w.sres}\t{w.g7}\t{w.own}\t{w.tKey}\t{w.tOwnRec}\t{c.tOwn}\t{c.tSkel}\t{c.tRecMiss}\t{c.tResMiss}\t{c.nRecMiss}\t{c.nResMiss}\t{if c.recChanged then 1 else 0}\t{if c.resChanged then 1 else 0}\n"
          if rbuf.size ≥ 20000 then
            h.putStr (String.join rbuf.toList); rbuf := #[]
        h.putStr (String.join rbuf.toList)
        h.flush
        IO.eprintln s!"KROWS r{r}: {rp.rows.size} rows -> {rf}"
        if let some (pRecs, pRes) := carry.prev then
          let mut same := 0
          let mut changed := 0
          let mut added := 0
          let mut fields := Array.replicate PrintKey.recFields.length 0
          for (c, x) in rp.recs do
            match pRecs[c]? with
            | none => added := added + 1
            | some y =>
              if x == y then same := same + 1 else
                changed := changed + 1
                let xa := x.toArray
                let ya := y.toArray
                for j in [0:xa.size] do
                  unless xa[j]! == ya[j]! do fields := fields.modify j (· + 1)
          let removed := pRecs.fold (fun k c _ => if rp.recs.contains c then k else k + 1) 0
          IO.eprintln s!"RECDELTA r{r}: records {rp.recs.size}, previous {pRecs.size}; same {same} changed {changed} new {added} removed {removed}; changed by field {String.intercalate " " ((PrintKey.recFields.zip fields.toList).map fun (n, k) => s!"{n}={k}")}"
          let mut rsame := 0
          let mut rchanged := 0
          let mut radded := 0
          for (ph, x) in rp.resAll do
            match pRes[ph]? with
            | none => radded := radded + 1
            | some y => if x == y then rsame := rsame + 1 else rchanged := rchanged + 1
          let rremoved := pRes.fold (fun k ph _ => if rp.resAll.contains ph then k else k + 1) 0
          IO.eprintln s!"RESDELTA r{r}: pairs {rp.resAll.size}, previous {pRes.size}; same {rsame} changed {rchanged} new {radded} removed {rremoved}"
        carry' := { carry' with prev := some (rp.recs, rp.resAll) }
    vi := vi + 1
  let some keys := ref? | throw <| IO.userError "keyprof: empty plan"
  if !prevKeys.isEmpty then
    let mut both := 0
    let mut g7Eq := 0
    let mut ownEq := 0
    for (n, k) in keys do
      if let some k' := prevKeys[n]? then
        both := both + 1
        if k.1 == k'.1 then g7Eq := g7Eq + 1
        if k.2 == k'.2 then ownEq := ownEq + 1
    IO.eprintln s!"KEYCMP r{r}: candidates {keys.size}, previous {prevKeys.size}, in both {both}; G7 equal {g7Eq}; G7+own equal {ownEq}"
  let (al, ns) := decodedAliasNs d
  let envAl : Std.HashSet (Name × Name) :=
    (getAliasState env).fold (fun s a es => es.foldl (fun s e => s.insert (a, e)) s) {}
  let envKeys := (getAliasState env).fold (fun k _ _ => k + 1) 0
  IO.eprintln s!"ALIAS r{r}: decoded alias entries {al.size} (distinct pairs), namespaces {ns.size}; environment alias state {envKeys} names, {envAl.size} pairs"
  if carry.filled then
    let (a1, r1) := setDiff carry.aliases al
    let (a2, r2) := setDiff carry.namespaces ns
    let (a3, r3) := setDiff carry.envAliases envAl
    IO.eprintln s!"ALIASDELTA r{r}: decoded alias pairs +{a1} -{r1}; namespaces +{a2} -{r2}; environment alias pairs +{a3} -{r3}"
  carry' := { carry' with aliases := al, namespaces := ns, envAliases := envAl, filled := true }
  return (keys, missing0, carry')

unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | specFile :: outDir :: rest =>
    let some cfg0 := (parseArgs ("-" :: "-" :: rest)).toOption
      | IO.eprintln "patchrun: bad extractor arguments"; return 2
    let mut specs : Array RoundSpec := #[]
    for l in ← IO.FS.lines specFile do
      if l.isEmpty || l.startsWith "#" then continue
      match parseSpec l with
      | .ok s => specs := specs.push s
      | .error e => IO.eprintln e; return 2
    let perturb := (← IO.getEnv "PATCH_PERTURB") == some "1"
    let stop := (← IO.getEnv "PATCH_STOP").getD ""
    let oracle := (← IO.getEnv "PATCH_ORACLE") == some "1"
    let mut prev : Patch.Prev := {}
    let mut built? : Option Patch.Built := none
    let mut ni? : Option Patch.NewestIndex := none
    let mut prevOld? : Option Assemble.OldWorld := none
    let mut prevResults : Std.HashMap Name DeclOut := {}
    let mut prevKeys : Std.HashMap Name (UInt64 × UInt64) := {}
    let plan := (← IO.getEnv "KEYPROF_PLAN").getD ""
    let mut carry : ProfCarry := {}
    let mut kept := 0
    let mut failed := false
    snap "start"
    for h : r in [0:specs.size] do
      let spec := specs[r]
      let dir : System.FilePath := ⟨outDir⟩ / s!"r{r}-{spec.label}"
      IO.FS.createDirAll dir
      IO.eprintln s!"=== round {r} {spec.label}: {spec.modules} key {spec.key} decode jobs {spec.decodeJobs}"
      writerOfClosure.set ""
      let sp ← readSearchPath spec.sp
      let targets := (← IO.FS.lines spec.modules).filter (!·.isEmpty) |>.map String.toName
      let t0 ← IO.monoMsNow
      let mods ← closure sp targets
      let t1 ← IO.monoMsNow
      emit r "closure" (t1 - t0) s!"modules {mods.size}"
      let (d, prevNext, dt) ← Patch.decodeVersion sp mods spec.decodeJobs prev
      prev := prevNext
      let t2 ← IO.monoMsNow
      emit r "decode" (t2 - t1) s!"wall-of-modules {dt.wallMs} dec-cpu {dt.decNs / 1000000} hash-cpu {dt.hashNs / 1000000} share-cpu {dt.subNs / 1000000} fold {dt.foldMs} prevmap {dt.prevMs} constants {d.stats.constants} entries {d.stats.entriesDecoded} constants-shared {dt.cShared} entries-shared {dt.eShared}"
      snap s!"r{r}-decoded"
      if let some o := prevOld? then
        IO.eprintln s!"RECORD r{r}: {recordDelta o d.old}"
      prevOld? := some d.old
      if ni?.isNone then
        let ms ← Assemble.importNewest
        let t3 ← IO.monoMsNow
        let ni ← Patch.buildNewestIndex ms
        let t4 ← IO.monoMsNow
        emit r "import-newest" (t3 - t2)
        emit r "newest-index" (t4 - t3)
        ni? := some ni
      let some ni := ni? | return 3
      let tP0 ← IO.monoMsNow
      let (b, ps) ← Patch.build ni d built? (perturb && built?.isSome)
      let tP1 ← IO.monoMsNow
      emit r "patch" (tP1 - tP0) s!"delta {ps.tDelta} consts {ps.tConsts} idxOf {ps.tIdx} placement {ps.tPlace} dirty {ps.tDirty} merge {ps.tMerge} extra {ps.tExtra}"
      IO.eprintln s!"PATCH r{r}: constants same {ps.constSame} changed {ps.constChanged} added {ps.constAdded} removed {ps.constRemoved}; newest modules {ps.modules}, rewritten {ps.dirty} (constants {ps.dirtyConst}, placed old entries {ps.dirtyOlds}, kept-newest filter {ps.dirtyFilter}); old-key membership changes {ps.keyChanges}"
      if oracle then
        let tO0 ← IO.monoMsNow
        let m ← Assemble.rewriteMerge ni.ms d
        let (bad, notes) ← Patch.compareStates b.out m.out
        let mut idxBad := 0
        unless m.idxOf.size == b.idxOf.size do idxBad := idxBad + 1
        for (n, i) in m.idxOf do
          unless b.idxOf[n]? == some i do idxBad := idxBad + 1
        let tO1 ← IO.monoMsNow
        emit r "oracle" (tO1 - tO0)
        IO.eprintln s!"ORACLE r{r}: modules differing from rewriteMerge {bad}, idxOf differences {idxBad}"
        for n in notes do IO.eprintln s!"  oracle: {n}"
      built? := some b
      snap s!"r{r}-patched"
      if stop == "patch" then
        snap s!"r{r}-end"
        continue
      let tF0 ← IO.monoMsNow
      let env ← Assemble.finalizeHybrid b.out b.idxOf (leak := false)
      let tF1 ← IO.monoMsNow
      emit r "finalize" (tF1 - tF0)
      if r == 0 then
        let n := (← builtinDeclRanges.get).size
        builtinDeclRanges.set {}
        IO.eprintln s!"builtinDeclRanges of v{Lean.versionString} cleared: {n} entries"
      snap s!"r{r}-finalized"
      if stop == "finalize" then
        snap s!"r{r}-end"
        continue
      let hs : HardStops := { verso := ← IO.mkRef #[], builtinDoc := ← IO.mkRef #[] }
      let world := hybridWorld env d.old hs
      let tK0 ← IO.monoMsNow
      let planR := (← IO.getEnv s!"KEYPROF_PLAN_R{r}").getD plan
      let (keys, missing) ← if planR.isEmpty then PrintKey.keysPar env world targets cfg0.jobs else do
        let (k, m, c) ← keyProfile r dir env world targets planR carry d prevKeys
        carry := c
        pure (k, m)
      let tK1 ← IO.monoMsNow
      emit r "keys" (tK1 - tK0) s!"candidates {keys.size} missing {missing}"
      let pick := fun (k : UInt64 × UInt64) => if spec.key == "own" then k.2 else k.1
      let mut g7Eq := 0
      let mut ownEq := 0
      let mut reusable := 0
      let mut lostByOwn : Array Name := #[]
      for (n, k) in keys do
        match prevResults[n]?, prevKeys[n]? with
        | some _, some k' =>
          if k.1 == k'.1 then g7Eq := g7Eq + 1
          if k.2 == k'.2 then ownEq := ownEq + 1
          if k.1 == k'.1 && k.2 != k'.2 then lostByOwn := lostByOwn.push n
          if pick k == pick k' then reusable := reusable + 1
        | _, _ => pure ()
      let second := match (← IO.getEnv "PRINTKEY_VARIANT").getD "" with
        | "" => "G7+own"
        | v => s!"{v} (variant + own)"
      IO.eprintln s!"KEYS r{r}: previous output {prevResults.size}; G7 equal {g7Eq}; {second} equal {ownEq}; reused under {spec.key} {reusable}; G7-equal but second-different {lostByOwn.size}"
      IO.FS.writeFile (dir / "own-lost.txt") ("\n".intercalate (lostByOwn.toList.map toString) ++ "\n")
      if stop == "keys" then
        prevKeys := keys
        snap s!"r{r}-end"
        continue
      let reuseOf (n : Name) : Option DeclOut :=
        match prevResults[n]?, prevKeys[n]?, keys[n]? with
        | some p, some a, some k => if pick a == pick k then some p else none
        | _, _, _ => none
      let outRef ← IO.mkRef #[]
      let cfg := { cfg0 with
        declProfilePath := cfg0.declProfilePath.map fun _ => dir / "decl-profile.jsonl",
        modulesPath := ⟨spec.modules⟩, outPath := dir / "events.jsonl", irDir := some (dir / "ir"),
        linkIndexPath := some (dir / "link-index.lidx"), linkIndexOmitPath := some ⟨spec.modules⟩ }
      let tE0 ← IO.monoMsNow
      let code ← Litedoc4.run cfg (some (env, world)) (some { prev := reuseOf, out := outRef })
      let tE1 ← IO.monoMsNow
      let results ← outRef.get
      emit r "extract" (tE1 - tE0) s!"exit {code} produced {results.size}"
      if (← IO.getEnv "PATCH_CLEAR") != some "0" then
        let (kinds, entries) ← clearRealizations env
        IO.eprintln s!"REALIZE r{r}: realization map of imported constants held {entries} entries in {kinds} kinds; emptied"
      let v ← hs.verso.get
      let bd ← hs.builtinDoc.get
      IO.eprintln s!"HARD STOPS r{r}: Verso {v.size}, builtin-table docstrings {bd.size}"
      prevResults := results.foldl (fun m x => m.insert x.name x) (Std.HashMap.emptyWithCapacity results.size)
      prevKeys := keys
      snap s!"r{r}-extracted"
      let tH0 ← IO.monoMsNow
      shell s!"cd '{dir}' && find ir -type f | LC_ALL=C sort | xargs shasum -a 256 > ir.sha256 && shasum -a 256 link-index.lidx > lidx.sha256"
      let mut diffs := 0
      if spec.refIr != "-" then
        let a ← shaMap (dir / "ir.sha256")
        let b ← shaMap ⟨spec.refIr⟩
        let mut shown := 0
        for (p, hsh) in a do
          unless b[p]? == some hsh do
            diffs := diffs + 1
            if shown < 30 then
              IO.eprintln s!"  ir differs: {p}"
              shown := shown + 1
        for (p, _) in b do
          unless a.contains p do
            diffs := diffs + 1
            if shown < 30 then
              IO.eprintln s!"  ir missing: {p}"
              shown := shown + 1
        IO.eprintln s!"IR r{r}: {a.size} files, reference {b.size}, differing or missing {diffs}"
      if spec.refLidx != "-" then
        let la := (← IO.FS.readFile (dir / "lidx.sha256")).splitOn " " |>.head!
        let lb := (← IO.FS.readFile ⟨spec.refLidx⟩).splitOn " " |>.head!
        IO.eprintln s!"LIDX r{r}: {if la == lb then "equal" else "DIFFERS"}"
        if la != lb then diffs := diffs + 1
      if spec.keep || (diffs > 0 && kept < 2) then
        kept := kept + 1
        IO.eprintln s!"IR r{r}: kept in {dir}"
      else
        shell s!"rm -rf '{dir}/ir' '{dir}/link-index.lidx'"
      let tH1 ← IO.monoMsNow
      emit r "hash-ir" (tH1 - tH0)
      if diffs > 0 then failed := true
      snap s!"r{r}-end"
    IO.eprintln s!"patchrun: {specs.size} rounds; {if failed then "some round differs from its reference" else "every round equals its reference"}"
    return 0
  | _ =>
    IO.eprintln "usage: patchrun <rounds.tsv> <out-dir> [extractor options]"
    return 2
