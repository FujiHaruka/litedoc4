import Lean
import Extract
open Lean Meta Litedoc4

/-! The print key: hashes of what the printed fields of one declaration are computed from, read
from the environment the extractor prints in, written as components so that a key is a choice
of them. -/

namespace PrintKey

@[inline] def mix (h x : UInt64) : UInt64 := mixHash h x

def mixList (h : UInt64) (xs : List UInt64) : UInt64 := xs.foldl mix h

/-! ## The key-pass probe (E1)

Off unless `keysPar` is given a report ref. Every site is one `Option` test, plus two clock
reads when on. A pure `let` is timed only behind `pinU` / `pinN`: the compiler may sink a pure
`let` to its first use, past the next clock read (`Extract.lean`'s `pin`). -/

@[noinline] def pinU (x : UInt64) : BaseIO Unit := if x == 0 then return () else return ()
@[noinline] def pinN (n : Nat) : BaseIO Unit := if n == 0 then return () else return ()

/-- Counters of one thread. Times in nanoseconds. -/
structure KStats where
  decls : Nat := 0
  tTask : Nat := 0
  tKey : Nat := 0
  tOwnHash : Nat := 0
  tMembers : Nat := 0
  tSkelT : Nat := 0
  tEqn : Nat := 0
  tSkelV : Nat := 0
  tVal : Nat := 0
  tShown : Nat := 0
  tLoop : Nat := 0
  recHit : Nat := 0
  recMiss : Nat := 0
  tRec : Nat := 0
  tRecType : Nat := 0
  tRecValue : Nat := 0
  tRecStruct : Nat := 0
  tRecOther : Nat := 0
  resHit : Nat := 0
  resMiss : Nat := 0
  resRecomputed : Nat := 0
  resResets : Nat := 0
  tRes : Nat := 0
  tRevAlias : Nat := 0
  revAliasFound : Nat := 0
  resolveCalls : Nat := 0
  ownRecMiss : Nat := 0
  tOwnRec : Nat := 0
  shownSum : Nat := 0
  spacesSum : Nat := 0
  deriving Inhabited

def KStats.add (a b : KStats) : KStats :=
  { decls := a.decls + b.decls, tTask := a.tTask + b.tTask, tKey := a.tKey + b.tKey,
    tOwnHash := a.tOwnHash + b.tOwnHash, tMembers := a.tMembers + b.tMembers, tSkelT := a.tSkelT + b.tSkelT,
    tEqn := a.tEqn + b.tEqn, tSkelV := a.tSkelV + b.tSkelV, tVal := a.tVal + b.tVal, tShown := a.tShown + b.tShown,
    tLoop := a.tLoop + b.tLoop, recHit := a.recHit + b.recHit, recMiss := a.recMiss + b.recMiss, tRec := a.tRec + b.tRec,
    tRecType := a.tRecType + b.tRecType, tRecValue := a.tRecValue + b.tRecValue, tRecStruct := a.tRecStruct + b.tRecStruct,
    tRecOther := a.tRecOther + b.tRecOther, resHit := a.resHit + b.resHit, resMiss := a.resMiss + b.resMiss,
    resRecomputed := a.resRecomputed + b.resRecomputed, resResets := a.resResets + b.resResets, tRes := a.tRes + b.tRes,
    tRevAlias := a.tRevAlias + b.tRevAlias, revAliasFound := a.revAliasFound + b.revAliasFound,
    resolveCalls := a.resolveCalls + b.resolveCalls, ownRecMiss := a.ownRecMiss + b.ownRecMiss,
    tOwnRec := a.tOwnRec + b.tOwnRec, shownSum := a.shownSum + b.shownSum, spacesSum := a.spacesSum + b.spacesSum }

/-- What one `keyOf` call leaves for its caller's row. -/
structure KCur where
  shown : Nat := 0
  spaces : Nat := 0
  tOwn : Nat := 0
  tSkel : Nat := 0
  tRecMiss : Nat := 0
  tResMiss : Nat := 0
  nRecMiss : Nat := 0
  nResMiss : Nat := 0
  recChanged : Bool := false
  resChanged : Bool := false
  deriving Inhabited

def biCode : BinderInfo → UInt64
  | .default => 0 | .implicit => 1 | .strictImplicit => 2 | .instImplicit => 3

unsafe def hashExprM (e : Expr) : StateM (Std.HashMap USize UInt64) UInt64 := do
  let p := ptrAddrUnsafe e
  if let some h := (← get)[p]? then return h
  let h ← match e with
    | .bvar i => pure (mix 1 (hash i))
    | .fvar f => pure (mix 2 (hash f.name))
    | .mvar m => pure (mix 3 (hash m.name))
    | .sort l => pure (mix 4 (hash l))
    | .const n ls => pure (mix (mix 5 (hash n)) (hash ls))
    | .app f a => do let x ← hashExprM f; let y ← hashExprM a; pure (mix (mix 6 x) y)
    | .lam n t b bi => do
      let x ← hashExprM t; let y ← hashExprM b
      pure (mixList 7 [hash n, biCode bi, x, y])
    | .forallE n t b bi => do
      let x ← hashExprM t; let y ← hashExprM b
      pure (mixList 8 [hash n, biCode bi, x, y])
    | .letE n t v b nd => do
      let x ← hashExprM t; let y ← hashExprM v; let z ← hashExprM b
      pure (mixList 9 [hash n, hash nd, x, y, z])
    | .lit l => pure (mix 10 (hash l))
    | .mdata d b => do
      let y ← hashExprM b
      pure (mixList 11 (d.entries.map (fun (k, v) => mix (hash k) (hash (toString v))) ++ [y]))
    | .proj s i b => do let y ← hashExprM b; pure (mixList 12 [hash s, hash i, y])
  modify (·.insert p h)
  return h

unsafe def hashExpr (e : Expr) : UInt64 := (hashExprM e |>.run' {}) |> Id.run

/-- Binder infos of a constant's leading `∀`s, read off its type without reduction. -/
def binderInfos (env : Environment) (c : Name) : Array BinderInfo := Id.run do
  let some ci := env.find? c | return #[]
  let mut t := ci.type
  let mut out := #[]
  while true do
    match t with
    | .forallE _ _ b bi => out := out.push bi; t := b
    | _ => break
  return out

structure SkelState where
  memo : Std.HashMap USize UInt64 := {}
  bis : Std.HashMap Name (Array BinderInfo) := {}
  consts : NameSet := {}

/-- The hash of what the printer shows by default: an application of a constant loses its
implicit, strict-implicit and instance arguments (hidden unless `@` is printed); everything else
as `hashExprM`. Also collects the constants that survive. -/
unsafe def hashSkelM (env : Environment) (e : Expr) : StateM SkelState UInt64 := do
  let p := ptrAddrUnsafe e
  if let some h := (← get).memo[p]? then return h
  let h ← match e with
    | .app .. =>
      let fn := e.getAppFn
      let args := e.getAppArgs
      match fn with
      | .const c ls => do
        modify fun st => { st with consts := st.consts.insert c }
        let bis ← match (← get).bis[c]? with
          | some b => pure b
          | none => do
            let b := if (env.find? c).any (·.isCtor) then #[] else binderInfos env c
            modify (fun st => { st with bis := st.bis.insert c b }); pure b
        let mut h := mixList 61 [hash c, hash ls]
        for i in [0:args.size] do
          let shown := match bis[i]? with
            | some .default => true
            | some _ => false
            | none => true
          if shown then h := mix h (← hashSkelM env args[i]!) else h := mix h 62
        pure h
      | _ => do
        let mut h ← hashSkelM env fn
        for a in args do h := mix h (← hashSkelM env a)
        pure (mix 63 h)
    | .const n ls => do modify (fun st => { st with consts := st.consts.insert n }); pure (mix (mix 5 (hash n)) (hash ls))
    | .lam n t b bi => do
      let x ← hashSkelM env t; let y ← hashSkelM env b
      pure (mixList 7 [hash n, biCode bi, x, y])
    | .forallE n t b bi => do
      let x ← hashSkelM env t; let y ← hashSkelM env b
      pure (mixList 8 [hash n, biCode bi, x, y])
    | .letE n t v b nd => do
      let x ← hashSkelM env t; let y ← hashSkelM env v; let z ← hashSkelM env b
      pure (mixList 9 [hash n, hash nd, x, y, z])
    | .mdata d b => do
      let y ← hashSkelM env b
      pure (mixList 11 (d.entries.map (fun (k, v) => mix (hash k) (hash (toString v))) ++ [y]))
    | .proj s i b => do let y ← hashSkelM env b; pure (mixList 12 [hash s, hash i, y])
    | _ => pure ((hashExprM e).run' {} |> Id.run)
  modify fun st => { st with memo := st.memo.insert p h }
  return h

/-- Skeleton hash of several expressions, and the constants that survive in them. -/
unsafe def hashSkel (env : Environment) (es : Array Expr) : UInt64 × NameSet :=
  let act : StateM SkelState UInt64 := es.foldlM (fun h e => do pure (mix h (← hashSkelM env e))) 71
  let (h, st) := act.run {} |> Id.run
  (h, st.consts)

def kindCode : ConstantInfo → UInt64
  | .axiomInfo _ => 1 | .defnInfo _ => 2 | .thmInfo _ => 3 | .opaqueInfo _ => 4
  | .quotInfo _ => 5 | .inductInfo _ => 6 | .ctorInfo _ => 7 | .recInfo _ => 8

def redCode : ReducibilityStatus → UInt64
  | .reducible => 1 | .semireducible => 2 | .irreducible => 3 | .implicitReducible => 4
  | .instanceReducible => 5

/-- How the printer can abbreviate `c` inside namespace `ns`: every reverse alias and every
suffix, resolved as the printer resolves it. -/
def resolutionFrom (env : Environment) (ns c : Name) (revAliases : List Name) : UInt64 × Nat := Id.run do
  let initial := revAliases.toArray.push (rootNamespace.appendCore c)
  let mut h : UInt64 := 31
  let mut calls := 0
  for n in initial do
    h := mix h (hash n)
    if n.hasMacroScopes then continue
    let comps := n.componentsRev
    let mut suffix : Name := .anonymous
    for comp in comps do
      suffix := comp.appendCore suffix
      let rs := ResolveName.resolveGlobalName env {} ns [] suffix
      calls := calls + 1
      h := mixList h ((hash suffix) :: rs.map fun (r, fs) => mix (hash r) (hash fs))
  return (h, calls)

def resolution (env : Environment) (ns c : Name) : UInt64 :=
  if c.hasMacroScopes then mix 32 (hash c) else (resolutionFrom env ns c (getRevAliases env c)).1

/-- The declarations whose printed form makes up the members of a structure or inductive, and
the structures the flattened fields go through. -/
def memberConsts (env : Environment) (ci : ConstantInfo) : Array Name := Id.run do
  let .inductInfo i := ci | return #[]
  if isStructure env i.name then
    let mut out := #[(getStructureCtor env i.name).name]
    let mut todo := #[i.name]
    let mut seen : NameSet := {}
    while h : todo.size > 0 do
      let s := todo.back
      todo := todo.pop
      if seen.contains s then continue
      seen := seen.insert s
      out := out.push s
      for p in getStructureParentInfo env s do
        out := out.push p.projFn
        todo := todo.push p.structName
    for f in getStructureFieldsFlattened env i.name (includeSubobjectFields := false) do
      if let some owner := findField? env i.name f then
        if let some pf := getProjFnForField? env owner f then out := out.push pf
    return out
  else
    return i.ctors.toArray

/-- The lemmas a package registered as a declaration's equations (Mathlib's `eqns` attribute,
which `irreducible_def` uses): the state of the persistent extension named `eqnsAttribute`, read
by name because this code does not import the package that declares it. -/
unsafe def registeredEqns (env : Environment) : IO (Option (NameMap (Array Name))) := do
  let exts ← persistentEnvExtensionsRef.get
  let some e := exts.find? (·.name == `eqnsAttribute) | return none
  let ext : SimplePersistentEnvExtension (Name × Array Name) (Thunk (NameMap (Array Name))) := unsafeCast e
  return some (ext.getState env).get

/-- Stored equation lemmas and the recursion data the equation generator reads. -/
unsafe def eqnData (env : Environment) (registered : NameMap (Array Name)) (n : Name) : UInt64 × Array Expr := Id.run do
  let mut h : UInt64 := 41
  let mut es : Array Expr := #[]
  for l in (registered.find? n).getD #[] do
    if let some ci := env.find? l then
      h := mixList h [46, hash l, hashExpr ci.type]; es := es.push ci.type
  let mut i := 1
  while true do
    let some ci := env.find? (n.str s!"eq_{i}") | break
    h := mix h (hashExpr ci.type); es := es.push ci.type; i := i + 1
  if let some ci := env.find? (n.str "eq_def") then
    h := mixList h [42, hashExpr ci.type]; es := es.push ci.type
  if let some e := Elab.Structural.eqnInfoExt.find? env n then
    h := mixList h [43, hashExpr e.type, hashExpr e.value, hash e.recArgPos, hash e.declNames]
    es := es.push e.value
  if let some e := Elab.WF.eqnInfoExt.find? env n then
    h := mixList h [44, hashExpr e.type, hashExpr e.value, hash e.declNames, hash e.declNameNonRec]
    es := es.push e.value
  if let some e := Elab.PartialFixpoint.eqnInfoExt.find? env n then
    h := mixList h [45, hashExpr e.type, hashExpr e.value, hash e.declNames]
    es := es.push e.value
  return (h, es)

/-- What the app delaborator and field notation read off a referenced constant's type: per
leading binder its kind and the head of its type, and the head of the result. -/
def shapeOf (t : Expr) : UInt64 := Id.run do
  let headCode (e : Expr) : UInt64 :=
    match e.getAppFn with
    | .const n _ => hash n
    | .sort l => mix 81 (hash l.isZero)
    | .bvar _ => 82
    | .forallE .. => 83
    | _ => 84
  let mut h : UInt64 := 80
  let mut t := t
  while true do
    match t with
    | .forallE _ d b bi => h := mixList h [biCode bi, headCode d]; t := b
    | _ => break
  return mix h (headCode t)

/-- The printing data of one referenced constant, in parts. -/
structure Rec where
  type : UInt64
  skel : UInt64
  shape : UInt64
  lps : UInt64
  red : UInt64
  proj : UInt64
  cls : UInt64
  struct : UInt64
  coe : UInt64
  inst : UInt64
  pp : UInt64
  matcher : UInt64
  prot : UInt64
  value : UInt64
  redValue : UInt64
  auxValue : UInt64
  projStruct : UInt64
  deriving BEq

def recFields : List String :=
  ["T", "TS", "SH", "LP", "RED", "PROJ", "CLS", "STR", "COE", "INST", "PP", "MAT", "PROT", "V", "RV", "AUX", "PSTR"]

def Rec.toArray (r : Rec) : Array UInt64 :=
  #[r.type, r.skel, r.shape, r.lps, r.red, r.proj, r.cls, r.struct, r.coe, r.inst, r.pp, r.matcher, r.prot, r.value,
    r.redValue, r.auxValue, r.projStruct]

/-- Every place the key met a name it expected to be a structure and was not, with the reason;
written by the key pass so that this case is counted, never a panic's default. -/
initialize notStructures : IO.Ref (Array String) ← IO.mkRef #[]

/-- The flattened field layout of a structure and of every structure above it. A name that is
not a registered structure is a component value of its own (`92`), never a panic's default. -/
def structLayout (env : Environment) (s : Name) : UInt64 × Array Name := Id.run do
  let mut h : UInt64 := 91
  let mut todo := #[s]
  let mut seen : NameSet := {}
  let mut missing := #[]
  while h' : todo.size > 0 do
    let t := todo.back
    todo := todo.pop
    if seen.contains t then continue
    seen := seen.insert t
    let some si := getStructureInfo? env t
      | h := mixList h [92, hash t]; missing := missing.push t; continue
    h := mixList h ([hash t] ++ (getStructureFieldsFlattened env t (includeSubobjectFields := true)).toList.map hash)
    for p in si.parentInfo do
      h := mixList h [hash p.projFn, hash p.subobject]
      todo := todo.push p.structName
  return (h, missing)

/-- The layout of the structure a projection function belongs to: its constructor's inductive
type, read off the constructor (`ctorName.getPrefix` is not it for a private constructor, whose
name is `_private.<module>.0.<S>.<ctor>`). -/
def projStructLayout (env : Environment) (c ctor : Name) : IO UInt64 := do
  let some (.ctorInfo cv) := env.find? ctor
    | notStructures.modify (·.push s!"{c}\tconstructor {ctor} not found"); return mixList 93 [hash ctor]
  let (h, missing) := structLayout env cv.induct
  for t in missing do
    notStructures.modify (·.push s!"{c}\tconstructor {ctor} of {cv.induct}: {t} is not a registered structure (prefix {ctor.getPrefix} is{if (getStructureInfo? env ctor.getPrefix).isSome then "" else " not"} one)")
  if missing.isEmpty && ctor.getPrefix != cv.induct then
    notStructures.modify (·.push s!"{c}\tconstructor {ctor} of {cv.induct}: prefix {ctor.getPrefix} differs from the inductive (resolved through the inductive)")
  return h

/-- The probe's state for one thread: counters, the resolution pairs met (to tell a recomputation
after a reset from a first computation), optionally every resolution value (uncapped), the rows
of the 1-thread variant, and the previous round's records and resolutions to flag against. -/
structure KProbe where
  stats : KStats := {}
  seen : Std.HashSet UInt64 := {}
  keepAll : Bool := false
  resAll : Std.HashMap UInt64 UInt64 := {}
  prevRecs : Option (Std.HashMap Name Rec) := none
  prevRes : Option (Std.HashMap UInt64 UInt64) := none
  cur : KCur := {}

abbrev KProbeRef := Option (IO.Ref KProbe)

@[inline] def kNow (p : KProbeRef) : BaseIO Nat :=
  match p with
  | none => return 0
  | some _ => IO.monoNanosNow

@[inline] def kBump (p : KProbeRef) (f : KStats → KStats) : BaseIO Unit :=
  match p with
  | none => return ()
  | some r => r.modify fun s => { s with stats := f s.stats }

@[inline] def pairHash (ns c : Name) : UInt64 := mix (hash ns) (hash c)

unsafe def record (env : Environment) (c : Name) (probe : KProbeRef := none) : CoreM Rec := do
  let some ci := env.find? c | let m := mix 99 (hash c); return ⟨m, m, m, m, m, m, m, m, m, m, m, m, m, m, m, m, m⟩
  let t0 ← kNow probe
  let type := mixList (hashExpr ci.type) [kindCode ci]
  let skel := (hashSkel env #[ci.type]).1
  let shape := shapeOf ci.type
  pinU (mix (mix type skel) shape)
  let t1 ← kNow probe
  let red := getReducibilityStatusCore env c
  let (v, rv) := match ci with
    | .defnInfo d => let x := hashExpr d.value; (x, if red == ReducibilityStatus.reducible then x else 0)
    | _ => (0, 0)
  let aux := match ci with
    | .opaqueInfo o => hashExpr o.value
    | .defnInfo d => if (Match.Extension.getMatcherInfo? env c).isSome then hashExpr d.value else 0
    | _ => 0
  pinU (mix (mix v rv) aux)
  let t2 ← kNow probe
  let struct := match getStructureInfo? env c with
    | some si => mixList 23 (si.fieldNames.toList.map hash ++ (getStructureParentInfo env c).toList.map (fun (p : StructureParentInfo) => hash p.structName))
    | none => 0
  pinU struct
  let projStruct ← match env.getProjectionFnInfo? c with
    | some p => projStructLayout env c p.ctorName
    | none => pure 0
  let t3 ← kNow probe
  let proj := match env.getProjectionFnInfo? c with
    | some p => mixList 21 [hash p.ctorName, hash p.numParams, hash p.i, hash p.fromClass]
    | none => 0
  let coe := match ← getCoeFnInfo? c with
    | some cf => mix 24 (hash (reprStr cf))
    | none => 0
  let inst := if isInstanceCore env c then
      mix 25 (hash (((instanceExtension.getState env).instanceNames.find? c).map (·.priority) |>.getD 0))
    else 0
  let pp := mixList 26 [hash (hasPPNoDotAttribute env c), hash (hasPPUsingAnonymousConstructorAttribute env c)]
  let matcher := match Match.Extension.getMatcherInfo? env c with
    | some mi => mix 28 (hash (reprStr mi))
    | none => 0
  let lps := hash ci.levelParams
  let cls := hash (isClass env c)
  let prot := hash (isProtected env c)
  pinU (mixList proj [coe, inst, pp, matcher, lps, cls, prot, redCode red])
  let t4 ← kNow probe
  kBump probe fun s => { s with
    tRecType := s.tRecType + (t1 - t0), tRecValue := s.tRecValue + (t2 - t1),
    tRecStruct := s.tRecStruct + (t3 - t2), tRecOther := s.tRecOther + (t4 - t3) }
  return { type, skel, shape, lps, red := redCode red, proj, cls, struct, coe, inst, pp,
           matcher, prot, value := v, redValue := rv, auxValue := aux, projStruct }

/-- `Rec.struct`'s formula for any name: field names and parent structures. -/
def structData (env : Environment) (s : Name) : UInt64 :=
  match getStructureInfo? env s with
  | some si => mixList 23 (si.fieldNames.toList.map hash ++ (getStructureParentInfo env s).toList.map (fun (p : StructureParentInfo) => hash p.structName))
  | none => 0

/-- What structure-instance notation reads besides field names (`collectStructFields`,
`delabStructureInstance`): the anonymous-constructor attribute of the structure, and the default
value function of every field at every level, with its type and value. -/
unsafe def ctorExtra (env : Environment) (s : Name) : UInt64 := Id.run do
  let mut h : UInt64 := mixList 97 [hash (hasPPUsingAnonymousConstructorAttribute env s)]
  for f in getStructureFieldsFlattened env s (includeSubobjectFields := true) do
    if let some fn := getEffectiveDefaultFnForField? env s f then
      let body := match env.find? fn with
        | some ci => mixList (hashExpr ci.type) [((ci.value? (allowOpaque := true)).map hashExpr).getD 0]
        | none => 98
      h := mixList h [hash f, hash fn, body]
  return h

structure Memo where
  recs : Std.HashMap Name Rec := {}
  res : Std.HashMap (Name × Name) UInt64 := {}

/-- Components of one declaration's key, each a hash; a key is a set of them. Own: N name, kind
and universe names; T type; TS type as shown; V value; VS value as shown; E stored equations and
recursion data. Over the constants that survive in what is shown (the members included): SN their
names, then one aggregate per `recFields` entry (prefix `S`), and SRES name resolution. -/
def componentNames : List String :=
  ["N", "T", "TS", "V", "VS", "E", "SN"] ++ recFields.map ("S" ++ ·) ++ ["SRES", "SSTRN", "SCX"]

unsafe def keyOf (env : Environment) (registered : NameMap (Array Name)) (memo : IO.Ref Memo) (n : Name) (ci : ConstantInfo)
    (resLimit : Nat := 4000000) (probe : KProbeRef := none) : CoreM (Array UInt64 × Nat) := do
  let t0 ← kNow probe
  let cN := mixList 51 [hash n, kindCode ci, hash ci.levelParams]
  let cT := hashExpr ci.type
  pinU (mix cN cT)
  let t1 ← kNow probe
  let members := memberConsts env ci
  let memberTypes := members.filterMap fun m => (env.find? m).map (·.type)
  pinN (members.size + memberTypes.size)
  let t2 ← kNow probe
  let (cTS, skelT) := hashSkel env (#[ci.type] ++ memberTypes)
  pinU cTS
  let t3 ← kNow probe
  let (cV, cVS, cE, skelV, tE, tSV, tV) ← match ci with
    | .defnInfo v => do
      let a ← kNow probe
      let (eh, es) := eqnData env registered n
      pinU eh
      pinN es.size
      let b ← kNow probe
      let (vs, sv) := hashSkel env (#[v.value] ++ es)
      pinU vs
      let c ← kNow probe
      let hv := hashExpr v.value
      pinU hv
      let d ← kNow probe
      pure (hv, vs, eh, sv, b - a, c - b, d - c)
    | _ => pure (0, 0, 0, {}, 0, 0, 0)
  let t4 ← kNow probe
  let memberSet : NameSet := members.foldl (·.insert ·) {}
  let mut shown : NameSet := memberSet
  for c in skelT.toList ++ skelV.toList do shown := shown.insert c
  let spaces := members.foldl (fun s m => if s.contains m.getPrefix then s else s.push m.getPrefix) #[n.getPrefix]
  let sorted := shown.toArray.qsort Name.quickLt
  pinN (sorted.size + spaces.size)
  let t5 ← kNow probe
  let flagging ← match probe with
    | some r => pure (← r.get).prevRecs.isSome
    | none => pure false
  let mut names : UInt64 := 71
  let mut agg : Array UInt64 := Array.replicate recFields.length 72
  let mut res : UInt64 := 73
  let mut sstrn : UInt64 := 74
  let mut scx : UInt64 := 75
  let mut cur : KCur := {}
  let mut seenRecs : Array (Name × Rec) := #[]
  let mut seenRes : Array (UInt64 × UInt64) := #[]
  for c in sorted do
    let st ← memo.get
    let (r, dtR) ← match st.recs[c]? with
      | some r => do
        kBump probe fun s => { s with recHit := s.recHit + 1 }
        pure (r, none)
      | none => do
        let a ← kNow probe
        let r ← record env c probe
        let b ← kNow probe
        memo.modify fun s => { s with recs := s.recs.insert c r }
        kBump probe fun s => { s with recMiss := s.recMiss + 1, tRec := s.tRec + (b - a) }
        pure (r, some (b - a))
    if let some dt := dtR then
      cur := { cur with tRecMiss := cur.tRecMiss + dt, nRecMiss := cur.nRecMiss + 1 }
    if flagging then seenRecs := seenRecs.push (c, r)
    let mut rs : UInt64 := 0
    for ns in spaces do
      let st ← memo.get
      let (x, dtX) ← match st.res[(ns, c)]? with
        | some x => do
          kBump probe fun s => { s with resHit := s.resHit + 1 }
          pure (x, none)
        | none => do
          let (x, dtX) ← match probe with
            | none => pure (resolution env ns c, none)
            | some pr => do
              let a ← IO.monoNanosNow
              let (x, calls, found, tRA) ← if c.hasMacroScopes then pure (mix 32 (hash c), 0, 0, 0) else do
                let ra := getRevAliases env c
                pinN ra.length
                let m ← IO.monoNanosNow
                let (x, calls) := resolutionFrom env ns c ra
                pinU x
                pure (x, calls, ra.length, m - a)
              let b ← IO.monoNanosNow
              let ph := pairHash ns c
              let p ← pr.get
              let again := p.seen.contains ph
              pr.modify fun s => { s with
                seen := if again then s.seen else s.seen.insert ph,
                resAll := if s.keepAll then s.resAll.insert ph x else s.resAll,
                stats := { s.stats with
                  resMiss := s.stats.resMiss + 1, tRes := s.stats.tRes + (b - a),
                  tRevAlias := s.stats.tRevAlias + tRA, revAliasFound := s.stats.revAliasFound + found,
                  resolveCalls := s.stats.resolveCalls + calls,
                  resRecomputed := s.stats.resRecomputed + (if again then 1 else 0) } }
              pure (x, some (b - a))
          if st.res.size > resLimit then
            memo.modify fun s => { s with res := {} }
            kBump probe fun s => { s with resResets := s.resResets + 1 }
          memo.modify fun s => { s with res := s.res.insert (ns, c) x }
          pure (x, dtX)
      if let some dt := dtX then
        cur := { cur with tResMiss := cur.tResMiss + dt, nResMiss := cur.nResMiss + 1 }
      if flagging then seenRes := seenRes.push (pairHash ns c, x)
      rs := mix rs x
    names := mix names (hash c)
    agg := (agg.zip r.toArray).map fun (a, x) => mix a x
    res := mix res rs
    if memberSet.contains c then sstrn := mixList sstrn [hash c, r.struct]
    if let some (.ctorInfo cv) := env.find? c then
      if isStructure env cv.induct then
        sstrn := mixList sstrn [76, hash cv.induct, structData env cv.induct]
        scx := mixList scx [hash cv.induct, ctorExtra env cv.induct]
  pinU (mix names res)
  let t6 ← kNow probe
  if let some pr := probe then
    let p ← pr.get
    let mut recChanged := false
    let mut resChanged := false
    if let some prev := p.prevRecs then
      for (c, r) in seenRecs do
        unless prev[c]? == some r do recChanged := true
    if let some prev := p.prevRes then
      for (ph, x) in seenRes do
        unless prev[ph]? == some x do resChanged := true
    pr.set { p with
      cur := { cur with
        shown := sorted.size, spaces := spaces.size,
        tOwn := (t3 - t0) + tE + tSV + tV, tSkel := (t3 - t2) + tSV, recChanged, resChanged },
      stats := { p.stats with
        decls := p.stats.decls + 1,
        tOwnHash := p.stats.tOwnHash + (t1 - t0), tMembers := p.stats.tMembers + (t2 - t1),
        tSkelT := p.stats.tSkelT + (t3 - t2), tEqn := p.stats.tEqn + tE, tSkelV := p.stats.tSkelV + tSV,
        tVal := p.stats.tVal + tV, tShown := p.stats.tShown + (t5 - t4), tLoop := p.stats.tLoop + (t6 - t5),
        shownSum := p.stats.shownSum + sorted.size, spacesSum := p.stats.spacesSum + spaces.size } }
  return (#[cN, cT, cTS, cV, cVS, cE, names] ++ agg ++ #[res, sstrn, scx], shown.size)

/-- The declaration's own record over the fields G7 reads of a shown constant. -/
def ownMix (h : UInt64) (r : Rec) : UInt64 :=
  mixList h [r.shape, r.auxValue, r.projStruct, r.proj, r.cls, r.struct, r.coe, r.pp, r.matcher, r.prot]

/-- Key components of every candidate the extractor would visit, in its enumeration order (first
module wins): `name`, the components in `componentNames` order, the shown-constant count; one
header line. -/
unsafe def writeKeys (env : Environment) (world : World) (targets : Array Name) (out : System.FilePath) :
    IO (Nat × Nat) := do
  let memo ← IO.mkRef ({} : Memo)
  let registered ← registeredEqns env
  IO.eprintln s!"printkey: eqns attribute {match registered with | some m => s!"found, {m.size} declarations" | none => "not found"}"
  let registered := registered.getD {}
  let h ← IO.FS.Handle.mk out .write
  h.putStr ("name\t" ++ "\t".intercalate componentNames ++ "\tOWN\trefs\n")
  let mut seen : NameSet := {}
  let mut n := 0
  let mut missing := 0
  let coreCtx : Core.Context := { fileName := "<printkey>", fileMap := default, options := {}, maxHeartbeats := 0 }
  for m in targets do
    let some idx := world.moduleIndex? m | throw <| IO.userError s!"printkey: module not present: {m}"
    let mut lines : Array String := #[]
    for c in world.constNames idx do
      if seen.contains c then continue
      seen := seen.insert c
      let some ci := env.find? c | missing := missing + 1; continue
      let ((comps, refs), _) ← (keyOf env registered memo c ci).toIO coreCtx { env := env }
      let r ← match (← memo.get).recs[c]? with
        | some r => pure r
        | none => do
          let (r, _) ← (record env c).toIO coreCtx { env := env }
          pure r
      let own := ownMix 0 r
      lines := lines.push s!"{c}\t{"\t".intercalate (comps.toList.map toString)}\t{own}\t{refs}\n"
      n := n + 1
    h.putStr (String.join lines.toList)
  h.flush
  let ns ← notStructures.get
  IO.eprintln s!"printkey: projections whose structure is not a registered structure or not at the constructor's prefix: {ns.size}"
  for l in ns do IO.eprintln s!"  printkey-structure {l}"
  if let some p ← IO.getEnv "PRINTKEY_RECS" then
    let r ← IO.FS.Handle.mk p .write
    r.putStr ("name\t" ++ "\t".intercalate recFields ++ "\n")
    let st ← memo.get
    for (c, x) in st.recs.toArray.qsort (fun a b => Name.quickLt a.1 b.1) do
      r.putStr s!"{c}\t{"\t".intercalate (x.toArray.toList.map toString)}\n"
    r.flush
    IO.eprintln s!"printkey: {st.recs.size} referenced-constant records written"
  return (n, missing)

/-- Indices of G7's components in `componentNames`: N TS VS E SN SSH SRES SAUX SPSTR SPROJ SCLS
SSTR SCOE SPP SMAT SPROT. -/
def g7Idx : Array Nat := #[0, 2, 4, 5, 6, 9, 24, 22, 23, 12, 13, 14, 15, 17, 18, 19]

/-- G7 with SSTR (index 14) replaced by SSTRN (25), and optionally SCX (26) added. -/
def g7nIdx (extra : Bool) : Array Nat :=
  g7Idx.map (fun j => if j == 14 then 25 else j) ++ (if extra then #[26] else #[])

/-- One declaration's row of the 1-thread probe variant. -/
structure KRow where
  name : Name
  ownH : UInt64
  sn : UInt64
  sres : UInt64
  g7 : UInt64
  own : UInt64
  tKey : Nat
  tOwnRec : Nat
  cur : KCur

/-- What a probed `keysPar` reports: counters per thread, the rows (1 thread only), the records
and every resolution value (1 thread only, for the next round to flag against), distinct pairs. -/
structure KReport where
  threads : Array KStats := #[]
  rows : Array KRow := #[]
  recs : Std.HashMap Name Rec := {}
  resAll : Std.HashMap UInt64 UInt64 := {}
  distinctPairs : Nat := 0
  distinctRecs : Nat := 0

/-- G7, and G7 with the declaration's own record over the same fields (SH AUX PSTR PROJ CLS STR COE
PP MAT PROT), for every candidate the extractor visits; `jobs` threads, each with its own memo.
With `report`, every thread runs the probe; with `jobs = 1` it also keeps rows, records and every
resolution value, and flags each declaration against `prev` (records, resolutions). -/
unsafe def keysPar (env : Environment) (world : World) (targets : Array Name) (jobs : Nat)
    (report : Option (IO.Ref KReport) := none)
    (prev : Option (Std.HashMap Name Rec × Std.HashMap UInt64 UInt64) := none) :
    IO (Std.HashMap Name (UInt64 × UInt64) × Nat) := do
  let registered := (← registeredEqns env).getD {}
  let variant := (← IO.getEnv "PRINTKEY_VARIANT").getD ""
  let secondIdx ← match variant with
    | "" => pure g7Idx
    | "nown" => pure (g7nIdx false)
    | "nownx" => pure (g7nIdx true)
    | v => throw <| IO.userError s!"printkey: unknown PRINTKEY_VARIANT {v}"
  IO.eprintln s!"printkey: second key = {if variant.isEmpty then "G7" else variant} + own record, components {secondIdx}"
  let mut seen : NameSet := {}
  let mut cands : Array Name := #[]
  for m in targets do
    let some idx := world.moduleIndex? m | throw <| IO.userError s!"printkey: module not present: {m}"
    for c in world.constNames idx do
      if seen.contains c then continue
      seen := seen.insert c
      cands := cands.push c
  let coreCtx : Core.Context := { fileName := "<printkey>", fileMap := default, options := {}, maxHeartbeats := 0 }
  let prio := if (← IO.getEnv "PATCH_POOL") == some "1" then Task.Priority.default else .dedicated
  let single : Bool := jobs ≤ 1
  let tasks ← (Array.range jobs).mapM fun k => IO.asTask (prio := prio) do
    let tT0 ← IO.monoNanosNow
    let memo ← IO.mkRef ({} : Memo)
    let probe : KProbeRef ← match report with
      | none => pure none
      | some _ => do
        let r ← IO.mkRef ({
          keepAll := single,
          prevRecs := if single then prev.map (·.1) else none,
          prevRes := if single then prev.map (·.2) else none } : KProbe)
        pure (some r)
    let out ← IO.mkRef (Array.mkEmpty (α := Name × UInt64 × UInt64) (cands.size / jobs + 1))
    let rows ← IO.mkRef (#[] : Array KRow)
    let mut missing := 0
    let mut i := k
    while i < cands.size do
      let c := cands[i]!
      match env.find? c with
      | none => missing := missing + 1
      | some ci =>
        let a ← kNow probe
        let ((comps, _), _) ← (keyOf env registered memo c ci (resLimit := 1000000) (probe := probe)).toIO coreCtx { env := env }
        let g7 := g7Idx.foldl (fun h j => mix h comps[j]!) 7
        let b ← kNow probe
        let r ← match (← memo.get).recs[c]? with
          | some r => pure r
          | none => do
            let (r, _) ← (record env c probe).toIO coreCtx { env := env }
            pure r
        let base := if variant.isEmpty then g7 else secondIdx.foldl (fun h j => mix h comps[j]!) 7
        let own := ownMix base r
        pinU own
        let d ← kNow probe
        if let some pr := probe then
          let wasOwnMiss := !((← memo.get).recs.contains c)
          kBump probe fun s => { s with
            tKey := s.tKey + (b - a), tOwnRec := s.tOwnRec + (d - b),
            ownRecMiss := s.ownRecMiss + (if wasOwnMiss then 1 else 0) }
          if single then
            let cur := (← pr.get).cur
            rows.modify (·.push {
              name := c, ownH := mixList 0 (comps.extract 0 6).toList, sn := comps[6]!,
              sres := comps[24]!, g7, own, tKey := b - a, tOwnRec := d - b, cur })
        out.modify (·.push (c, g7, own))
      i := i + jobs
    let tT1 ← IO.monoNanosNow
    let extra ← match probe with
      | none => pure none
      | some pr => do
        let p ← pr.get
        let st := { p.stats with tTask := tT1 - tT0 }
        pure (some (st, p.seen, ← rows.get, (← memo.get).recs, p.resAll))
    return (← out.get, missing, extra)
  let mut keys : Std.HashMap Name (UInt64 × UInt64) := Std.HashMap.emptyWithCapacity cands.size
  let mut missing := 0
  let mut threads : Array KStats := #[]
  let mut pairs : Std.HashSet UInt64 := {}
  let mut recNames : NameSet := {}
  let mut rep : KReport := {}
  for t in tasks do
    let (out, miss, extra) ← IO.ofExcept t.get
    missing := missing + miss
    for (c, g, o) in out do keys := keys.insert c (g, o)
    if let some (st, sn, rows, recs, resAll) := extra then
      threads := threads.push st
      if single then
        rep := { rep with rows, recs, resAll }
        pairs := sn
      else
        pairs := sn.fold (fun s x => s.insert x) pairs
      recNames := recs.fold (fun s n _ => s.insert n) recNames
  if let some r := report then
    r.set { rep with threads, distinctPairs := pairs.size, distinctRecs := recNames.size }
  return (keys, missing)

end PrintKey
