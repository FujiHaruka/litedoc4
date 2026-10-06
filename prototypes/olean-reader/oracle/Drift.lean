import Lean
open Lean Meta

structure StrictE where
  e : Expr

instance : BEq StrictE := ⟨fun a b => a.e.equal b.e⟩
instance : Hashable StrictE := ⟨fun a => a.e.hash⟩

structure SState where
  nodes : Array Json := #[]
  levels : Array Json := #[]
  emap : Std.HashMap StrictE Nat := {}
  lmap : Std.HashMap Level Nat := {}
  mdata : Nat := 0
  mvars : Nat := 0
  fvars : Nat := 0
  lmvars : Nat := 0

def nameToJson (n : Name) : Json :=
  let rec go : Name → Array Json → Array Json
    | .anonymous, acc => acc
    | .str p s, acc => go p (acc.push (Json.str s))
    | .num p k, acc => go p (acc.push (toJson k))
  Json.arr (go n #[]).reverse

def jsonToName (j : Json) : Except String Name := do
  let cs ← j.getArr?
  cs.foldlM (init := Name.anonymous) fun acc c =>
    match c with
    | .str s => pure (Name.mkStr acc s)
    | .num _ => do pure (Name.mkNum acc (← c.getNat?))
    | _ => throw "bad name component"

def biCode : BinderInfo → String
  | .default => "d" | .implicit => "i" | .strictImplicit => "s" | .instImplicit => "c"

def codeBi : String → BinderInfo
  | "i" => .implicit | "s" => .strictImplicit | "c" => .instImplicit | _ => .default

partial def serL (l : Level) : StateM SState Nat := do
  if let some i := (← get).lmap[l]? then return i
  let j ← match l with
    | .zero => pure (Json.arr #["z"])
    | .succ a => do let i ← serL a; pure (Json.arr #["s", toJson i])
    | .max a b => do let i ← serL a; let k ← serL b; pure (Json.arr #["m", toJson i, toJson k])
    | .imax a b => do let i ← serL a; let k ← serL b; pure (Json.arr #["i", toJson i, toJson k])
    | .param n => pure (Json.arr #["p", nameToJson n])
    | .mvar m => do
      modify fun s => { s with lmvars := s.lmvars + 1 }
      pure (Json.arr #["v", nameToJson m.name])
  let s ← get
  let idx := s.levels.size
  set { s with levels := s.levels.push j, lmap := s.lmap.insert l idx }
  return idx

partial def serE (e : Expr) : StateM SState Nat := do
  if let .mdata _ b := e then
    modify fun s => { s with mdata := s.mdata + 1 }
    return (← serE b)
  if let some i := (← get).emap[StrictE.mk e]? then return i
  let j ← match e with
    | .bvar i => pure (Json.arr #["b", toJson i])
    | .fvar id => do
      modify fun s => { s with fvars := s.fvars + 1 }
      pure (Json.arr #["F", nameToJson id.name])
    | .mvar id => do
      modify fun s => { s with mvars := s.mvars + 1 }
      pure (Json.arr #["M", nameToJson id.name])
    | .sort l => do pure (Json.arr #["S", toJson (← serL l)])
    | .const n ls => do
      let is ← ls.mapM serL
      pure (Json.arr #["C", nameToJson n, Json.arr (is.toArray.map toJson)])
    | .app f a => do let i ← serE f; let k ← serE a; pure (Json.arr #["A", toJson i, toJson k])
    | .lam n t b bi => do
      let i ← serE t; let k ← serE b
      pure (Json.arr #["L", nameToJson n, Json.str (biCode bi), toJson i, toJson k])
    | .forallE n t b bi => do
      let i ← serE t; let k ← serE b
      pure (Json.arr #["P", nameToJson n, Json.str (biCode bi), toJson i, toJson k])
    | .letE n t v b nd => do
      let i ← serE t; let k ← serE v; let m ← serE b
      pure (Json.arr #["E", nameToJson n, toJson i, toJson k, toJson m, toJson nd])
    | .lit (.natVal n) => pure (Json.arr #["N", Json.str (toString n)])
    | .lit (.strVal s) => pure (Json.arr #["T", Json.str s])
    | .proj s i b => do let k ← serE b; pure (Json.arr #["J", nameToJson s, toJson i, toJson k])
    | .mdata _ _ => unreachable!
  let s ← get
  let idx := s.nodes.size
  set { s with nodes := s.nodes.push j, emap := s.emap.insert (StrictE.mk e) idx }
  return idx

def serialize (e : Expr) : Json × SState :=
  let (root, s) := (serE e).run {}
  (Json.mkObj [("levels", Json.arr s.levels), ("nodes", Json.arr s.nodes), ("root", toJson root)], s)

def rebuild (j : Json) : Except String Expr := do
  let lv ← (← j.getObjVal? "levels").getArr?
  let nd ← (← j.getObjVal? "nodes").getArr?
  let root ← (← j.getObjVal? "root").getNat?
  let mut ls : Array Level := #[]
  for x in lv do
    let a ← x.getArr?
    let tag ← a[0]!.getStr?
    let l ← match tag with
      | "z" => pure Level.zero
      | "s" => do pure (Level.succ ls[← a[1]!.getNat?]!)
      | "m" => do pure (Level.max ls[← a[1]!.getNat?]! ls[← a[2]!.getNat?]!)
      | "i" => do pure (Level.imax ls[← a[1]!.getNat?]! ls[← a[2]!.getNat?]!)
      | "p" => do pure (Level.param (← jsonToName a[1]!))
      | "v" => do pure (Level.mvar ⟨← jsonToName a[1]!⟩)
      | t => throw s!"bad level tag {t}"
    ls := ls.push l
  let mut es : Array Expr := #[]
  for x in nd do
    let a ← x.getArr?
    let tag ← a[0]!.getStr?
    let ex ← match tag with
      | "b" => do pure (Expr.bvar (← a[1]!.getNat?))
      | "F" => do pure (Expr.fvar ⟨← jsonToName a[1]!⟩)
      | "M" => do pure (Expr.mvar ⟨← jsonToName a[1]!⟩)
      | "S" => do pure (Expr.sort ls[← a[1]!.getNat?]!)
      | "C" => do
        let is ← (← a[2]!.getArr?).mapM (·.getNat?)
        pure (Expr.const (← jsonToName a[1]!) (is.toList.map (ls[·]!)))
      | "A" => do pure (Expr.app es[← a[1]!.getNat?]! es[← a[2]!.getNat?]!)
      | "L" => do
        pure (Expr.lam (← jsonToName a[1]!) es[← a[3]!.getNat?]! es[← a[4]!.getNat?]!
          (codeBi (← a[2]!.getStr?)))
      | "P" => do
        pure (Expr.forallE (← jsonToName a[1]!) es[← a[3]!.getNat?]! es[← a[4]!.getNat?]!
          (codeBi (← a[2]!.getStr?)))
      | "E" => do
        pure (Expr.letE (← jsonToName a[1]!) es[← a[2]!.getNat?]! es[← a[3]!.getNat?]!
          es[← a[4]!.getNat?]! (← a[5]!.getBool?))
      | "N" => do pure (Expr.lit (.natVal (← a[1]!.getStr?).toNat!))
      | "T" => do pure (Expr.lit (.strVal (← a[1]!.getStr?)))
      | "J" => do pure (Expr.proj (← jsonToName a[1]!) (← a[2]!.getNat?) es[← a[3]!.getNat?]!)
      | t => throw s!"bad node tag {t}"
    es := es.push ex
  return es[root]!

/-! doc-gen4's `isBlackListed`, as transcribed in the litedoc4 extractor:
    Copyright (c) 2021 Henrik Böving. All rights reserved.
    Released under Apache 2.0 license as described in the file LICENSE.
    Authors: Henrik Böving -/
def isProjFn (declName : Name) : MetaM Bool := do
  let env ← getEnv
  match declName with
  | .str parent name =>
    let some si := getStructureInfo? env parent | return false
    return getProjFnForField? env parent (Name.mkSimple name) == declName
      || (si.parentInfo.any fun pi => pi.projFn == declName)
  | _ => return false

def isBlackListed (declName : Name) : MetaM Bool := do
  if ← isProjFn declName then
    return false
  match ← findDeclarationRanges? declName with
  | some _ =>
    let env ← getEnv
    pure declName.isInternal
    <||> (pure <| isAuxRecursor env declName)
    <||> (pure <| isNoConfusion env declName)
    <||> (pure declName.isInternalDetail)
    <||> isRec declName
    <||> isMatcher declName
  | none => return true

def isInstanceDecl (declName : Name) : MetaM Bool := do
  return (instanceExtension.getState (← getEnv)).instanceNames.contains declName

def kindOf (name : Name) (ci : ConstantInfo) : MetaM String := do
  match ci with
  | .axiomInfo _ => return "axiom"
  | .thmInfo _ =>
    let isInst ← if ← isProjFn name then pure false else isInstanceDecl name
    return if isInst then "instance" else "theorem"
  | .opaqueInfo _ => return "opaque"
  | .defnInfo _ =>
    let isInst ← if ← isProjFn name then pure false else isInstanceDecl name
    return if isInst then "instance" else "definition"
  | .inductInfo _ =>
    let env ← getEnv
    let isStruct := isStructure env name
    let isCls := isClass env name
    return if isStruct then (if isCls then "class" else "structure")
      else (if isCls then "class_inductive" else "inductive")
  | .ctorInfo _ => return "constructor"
  | .quotInfo _ => return "opaque"
  | .recInfo _ => return "recursor"

def enumerate : MetaM (Array (Name × Name)) := do
  let env ← getEnv
  let mods := env.header.moduleNames
  let mut seen : Std.HashSet Name := {}
  let mut out : Array (Name × Name) := #[]
  for i in [0:mods.size] do
    let m := mods[i]!
    unless (`Mathlib).isPrefixOf m && m != `Mathlib do continue
    for n in env.header.moduleData[i]!.constNames do
      if seen.contains n then continue
      seen := seen.insert n
      match env.find? n with
      | none | some (.recInfo _) => continue
      | some _ => pure ()
      if ← isBlackListed n then continue
      out := out.push (n, m)
  return out

def splitmix (s : UInt64) : UInt64 × UInt64 :=
  let s := s + 0x9E3779B97F4A7C15
  let z := (s ^^^ (s >>> 30)) * 0xBF58476D1CE4E5B9
  let z := (z ^^^ (z >>> 27)) * 0x94D049BB133111EB
  (z ^^^ (z >>> 31), s)

def ppWidth : Nat := 1000000

def ppSafe (e : Expr) : MetaM (Except String String) :=
  tryCatchRuntimeEx
    (do let f ← ppExpr e; return .ok (f.pretty ppWidth))
    (fun ex => do return .error (← ex.toMessageData.toString))

def coreCtx : Core.Context := {
  fileName := "<drift>"
  fileMap := default
  options := Options.empty.insert `format.width (DataValue.ofNat ppWidth)
  maxHeartbeats := 5000000
}

def runMeta (env : Environment) (act : MetaM α) : IO α := do
  let (a, _, _) ← act.toIO coreCtx { env := env } {} {}
  return a

def loadMathlib : IO Environment := do
  initSearchPath (← findSysroot)
  unsafe Lean.enableInitializersExecution
  importModules #[{ module := `Mathlib }] Options.empty (leakEnv := true) (loadExts := true)

def ppIO (env : Environment) (e : Expr) : IO (Except String String) := do
  try runMeta env (ppSafe e)
  catch ex => return .error s!"io: {ex}"

def oldSide (out : String) (seed : UInt64) (k : Nat) : IO UInt32 := do
  let t0 ← IO.monoMsNow
  let env ← loadMathlib
  let t1 ← IO.monoMsNow
  let mut cands ← runMeta env enumerate
  let t2 ← IO.monoMsNow
  IO.eprintln s!"import {t1 - t0} ms, enumerate {t2 - t1} ms, N = {cands.size}"
  let n := cands.size
  let k := min k n
  let mut st := seed
  for i in [0:k] do
    let (r, st') := splitmix st
    st := st'
    let j := i + (r.toNat % (n - i))
    let a := cands[i]!
    cands := (cands.set! i cands[j]!).set! j a
  let h ← IO.FS.Handle.mk out .write
  let mut ppMs := 0
  for i in [0:k] do
    let (name, m) := cands[i]!
    let some ci := env.find? name | throw (IO.userError s!"vanished {name}")
    let kind ← runMeta env (kindOf name ci)
    let (ser, s) := serialize ci.type
    let p0 ← IO.monoMsNow
    let pp ← ppIO env ci.type
    let p1 ← IO.monoMsNow
    ppMs := ppMs + (p1 - p0)
    let rec_ := Json.mkObj [
      ("i", toJson i), ("name", nameToJson name), ("nameStr", Json.str name.toString),
      ("module", Json.str m.toString), ("kind", Json.str kind),
      ("levelParams", Json.arr (ci.levelParams.toArray.map nameToJson)),
      ("type", ser), ("mdataDropped", toJson s.mdata), ("mvars", toJson s.mvars),
      ("fvars", toJson s.fvars), ("levelMvars", toJson s.lmvars),
      ("pp", match pp with | .ok x => Json.str x | .error _ => Json.null),
      ("ppErr", match pp with | .ok _ => Json.null | .error x => Json.str x),
      ("ppMs", toJson (p1 - p0))]
    h.putStrLn rec_.compress
  IO.eprintln s!"N = {n}, sampled = {k}, seed = {seed}, pp total {ppMs} ms"
  return 0

def newSide (inp out : String) (limit : Nat) : IO UInt32 := do
  let t0 ← IO.monoMsNow
  let env ← loadMathlib
  let t1 ← IO.monoMsNow
  IO.eprintln s!"import {t1 - t0} ms"
  let lines := (← IO.FS.lines inp).filter (!·.isEmpty)
  let h ← IO.FS.Handle.mk out .write
  let mut ppMs := 0
  let mut done := 0
  for line in lines do
    if done ≥ limit then break
    done := done + 1
    let j ← IO.ofExcept (Json.parse line)
    let name ← IO.ofExcept (jsonToName (← IO.ofExcept (j.getObjVal? "name")))
    let lps ← IO.ofExcept ((← IO.ofExcept (j.getObjVal? "levelParams")).getArr? >>= (·.mapM jsonToName)) <&> (·.toList)
    let tyJ ← IO.ofExcept (j.getObjVal? "type")
    let ty ← IO.ofExcept (rebuild tyJ)
    let rt := (serialize ty).1
    let roundTrip := rt.compress == tyJ.compress
    let consts := ty.getUsedConstants
    let mut dangling : Array Json := #[]
    let mut arity : Array Json := #[]
    for c in consts do
      match env.find? c with
      | none => dangling := dangling.push (Json.str c.toString)
      | some _ => pure ()
    let mut seenArity : Std.HashSet Name := {}
    for x in (← IO.ofExcept ((← IO.ofExcept (tyJ.getObjVal? "nodes")).getArr?)) do
      let a ← IO.ofExcept x.getArr?
      if (← IO.ofExcept a[0]!.getStr?) == "C" then
        let c ← IO.ofExcept (jsonToName a[1]!)
        let nl := (← IO.ofExcept a[2]!.getArr?).size
        if let some ci := env.find? c then
          if ci.levelParams.length != nl && !seenArity.contains c then
            seenArity := seenArity.insert c
            arity := arity.push (Json.str s!"{c} {nl}->{ci.levelParams.length}")
    let p0 ← IO.monoMsNow
    let pp ← ppIO env ty
    let p1 ← IO.monoMsNow
    ppMs := ppMs + (p1 - p0)
    let (status, newPp) ← match env.find? name with
      | none => pure ("absent", Json.null)
      | some ci =>
        let newSer := (serialize ci.type).1
        let st :=
          if newSer.compress == tyJ.compress then "same"
          else
            let newClean := match rebuild newSer with | .ok e => e | .error _ => ci.type
            if ty == newClean then "same_alpha"
            else if lps.length == ci.levelParams.length then
              let renamed := ty.instantiateLevelParams lps (ci.levelParams.map Level.param)
              if (serialize renamed).1.compress == newSer.compress then "same_levelrename"
              else if renamed == newClean then "same_levelrename_alpha"
              else "different"
            else "different"
        let np ← if st == "same" then pure Json.null else do
          match ← ppIO env ci.type with
          | .ok x => pure (Json.str x)
          | .error x => pure (Json.str s!"<error: {x}>")
        pure (st, np)
    let rec_ := Json.mkObj [
      ("i", ← IO.ofExcept (j.getObjVal? "i")), ("nameStr", ← IO.ofExcept (j.getObjVal? "nameStr")),
      ("module", ← IO.ofExcept (j.getObjVal? "module")), ("kind", ← IO.ofExcept (j.getObjVal? "kind")),
      ("oldPp", ← IO.ofExcept (j.getObjVal? "pp")), ("oldPpErr", ← IO.ofExcept (j.getObjVal? "ppErr")),
      ("mdataDropped", ← IO.ofExcept (j.getObjVal? "mdataDropped")),
      ("mvars", ← IO.ofExcept (j.getObjVal? "mvars")), ("fvars", ← IO.ofExcept (j.getObjVal? "fvars")),
      ("levelMvars", ← IO.ofExcept (j.getObjVal? "levelMvars")),
      ("roundTrip", toJson roundTrip),
      ("newPp", match pp with | .ok x => Json.str x | .error _ => Json.null),
      ("newPpErr", match pp with | .ok _ => Json.null | .error x => Json.str x),
      ("dangling", Json.arr dangling), ("arity", Json.arr arity),
      ("nameStatus", Json.str status), ("newDeclPp", newPp),
      ("ppMs", toJson (p1 - p0))]
    h.putStrLn rec_.compress
  IO.eprintln s!"records = {done}, pp total {ppMs} ms"
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["old", out, seed, k] => oldSide out seed.toNat!.toUInt64 k.toNat!
  | ["new", inp, out, limit] => newSide inp out limit.toNat!
  | _ =>
    IO.eprintln "usage: old <out.jsonl> <seed> <k> | new <in.jsonl> <out.jsonl> <limit>"
    return 2
