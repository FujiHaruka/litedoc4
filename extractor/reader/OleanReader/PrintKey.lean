import Extract
import OleanReader.Entries
open Lean Meta Litedoc4

namespace OleanReader.PrintKey

@[inline] def mix (h x : UInt64) : UInt64 := mixHash h x

def mixList (h : UInt64) (xs : List UInt64) : UInt64 := xs.foldl mix h

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

unsafe def hashSkel (env : Environment) (es : Array Expr) : UInt64 × NameSet :=
  let act : StateM SkelState UInt64 := es.foldlM (fun h e => do pure (mix h (← hashSkelM env e))) 71
  let (h, st) := act.run {} |> Id.run
  (h, st.consts)

def kindCode : ConstantInfo → UInt64
  | .axiomInfo _ => 1 | .defnInfo _ => 2 | .thmInfo _ => 3 | .opaqueInfo _ => 4
  | .quotInfo _ => 5 | .inductInfo _ => 6 | .ctorInfo _ => 7 | .recInfo _ => 8

def extStructure : Name := Name.mkNum `_private.Lean.Structure 0 ++ `Lean.structureExt
def extProjFn : Name := `Lean.projectionFnInfoExt
def extClass : Name := `Lean.classExtension
def extCoe : Name := `Lean.Meta.coeExt
def extProtected : Name := `Lean.protectedExt
def extAlias : Name := `Lean.aliasExtension
def extPPNoDot : Name := `Lean.ppNoDotAttr
def extPPAnon : Name := `Lean.ppUsingAnonymousConstructorAttr
def extMatcher : Name := `Lean.Meta.Match.Extension.extension
def extStructuralEqn : Name := `Lean.Elab.Structural.eqnInfoExt
def extWFEqn : Name := `Lean.Elab.WF.eqnInfoExt
def extPFEqn : Name := `Lean.Elab.PartialFixpoint.eqnInfoExt
def extEqns : Name := `eqnsAttribute
def extSparseCasesOn : Name := privName `Lean.Meta.Constructions.SparseCasesOn `Lean.Meta.sparseCasesOnInfoExt

def recordExts : Array Name := #[extMatcher, extProjFn, extCoe, extClass, extStructure, extPPNoDot, extPPAnon, extProtected]

def eqnExts : Array Name := #[extEqns, extStructuralEqn, extWFEqn, extPFEqn]

def keyExts : Array Name := recordExts ++ eqnExts ++ #[extAlias, extSparseCasesOn]

structure Reads where
  consts : Array Name := #[]
  entries : Array (Name × Name) := #[]

instance : Append Reads := ⟨fun a b => { consts := a.consts ++ b.consts, entries := a.entries ++ b.entries }⟩

def Reads.structs (r : Reads) (ss : Array Name) : Reads :=
  { r with entries := ss.foldl (fun es s => es.push (extStructure, s)) r.entries }

def resolution (env : Environment) (ns c : Name) : UInt64 := Id.run do
  if c.hasMacroScopes then return mix 32 (hash c)
  let mut h : UInt64 := 31
  for n in (getRevAliases env c).toArray.push (rootNamespace.appendCore c) do
    h := mix h (hash n)
    if n.hasMacroScopes then continue
    let mut suffix : Name := .anonymous
    for comp in n.componentsRev do
      suffix := comp.appendCore suffix
      let rs := ResolveName.resolveGlobalName env {} ns [] suffix
      h := mixList h ((hash suffix) :: rs.map fun (r, fs) => mix (hash r) (hash fs))
  return h

def probeNames (env : Environment) (ns id : Name) : Array Name := Id.run do
  let mut base := #[]
  let mut id := id
  while true do
    match id with
    | .str p _ =>
      let mut q := ns
      while true do
        match q with
        | .str qp _ => base := base.push (q ++ id); q := qp
        | _ => break
      unless id.isAtomic do base := base.push (id.replacePrefix rootNamespace .anonymous)
      base := base.push id
      id := p
    | _ => break
  let mut out := #[]
  for b in base do
    out := out.push b |>.push (mkPrivateName env b)
    if env.header.isModule then
      for i in env.header.importAllModules do out := out.push (mkPrivateNameCore i.module b)
  return out

def resolutionProbes (env : Environment) (revAliases : List Name) (ns c : Name) : Array Name := Id.run do
  if c.hasMacroScopes then return #[]
  let mut out := #[]
  for n in revAliases.toArray.push (rootNamespace.appendCore c) do
    if n.hasMacroScopes then continue
    let mut suffix : Name := .anonymous
    for comp in n.componentsRev do
      suffix := comp.appendCore suffix
      out := out ++ probeNames env ns suffix
  return out

def structClosure (env : Environment) (s : Name) : Array Name := Id.run do
  let mut out := #[]
  let mut todo := #[s]
  let mut seen : NameSet := {}
  while h : todo.size > 0 do
    let t := todo.back
    todo := todo.pop
    if seen.contains t then continue
    seen := seen.insert t
    out := out.push t
    let some si := getStructureInfo? env t | continue
    for p in si.parentInfo do todo := todo.push p.structName
    for f in si.fieldInfo do
      if let some p := f.subobject? then todo := todo.push p
  return out

def memberConsts (env : Environment) (ci : ConstantInfo) : Array Name × Reads := Id.run do
  let .inductInfo i := ci | return (#[], {})
  if isStructure env i.name then
    let ctor := (getStructureCtor env i.name).name
    let mut out := #[ctor]
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
    return (out, ({ consts := #[ctor] } : Reads).structs (structClosure env i.name))
  else
    return (i.ctors.toArray, ({} : Reads).structs #[i.name])

-- Not the extension by reference: Mathlib declares it, and the reader does not import Mathlib.
unsafe def registeredEqns (env : Environment) : IO (NameMap (Array Name)) := do
  let exts ← persistentEnvExtensionsRef.get
  let some e := exts.find? (·.name == `eqnsAttribute) | return {}
  let ext : SimplePersistentEnvExtension (Name × Array Name) (Thunk (NameMap (Array Name))) := unsafeCast e
  return (ext.getState env).get

unsafe def eqnData (env : Environment) (registered : NameMap (Array Name)) (n : Name) :
    UInt64 × Array Expr × Reads := Id.run do
  let mut h : UInt64 := 41
  let mut es : Array Expr := #[]
  let mut reads : Reads := { entries := eqnExts.map (·, n) }
  for l in (registered.find? n).getD #[] do
    reads := { reads with consts := reads.consts.push l }
    if let some ci := env.find? l then
      h := mixList h [46, hash l, hashExpr ci.type]; es := es.push ci.type
  let mut i := 1
  while true do
    let eqI := n.str s!"eq_{i}"
    reads := { reads with consts := reads.consts.push eqI }
    let some ci := env.find? eqI | break
    h := mix h (hashExpr ci.type); es := es.push ci.type; i := i + 1
  reads := { reads with consts := reads.consts.push (n.str "eq_def") }
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
  return (h, es, reads)

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

structure Rec where
  shape : UInt64
  auxValue : UInt64
  projStruct : UInt64
  proj : UInt64
  cls : UInt64
  struct : UInt64
  coe : UInt64
  pp : UInt64
  matcher : UInt64
  prot : UInt64
  deriving BEq

def Rec.shown (r : Rec) : Array UInt64 :=
  #[r.shape, r.auxValue, r.projStruct, r.proj, r.cls, r.coe, r.pp, r.matcher, r.prot]

def Rec.own (r : Rec) : List UInt64 :=
  [r.shape, r.auxValue, r.projStruct, r.proj, r.cls, r.struct, r.coe, r.pp, r.matcher, r.prot]

def structLayout (env : Environment) (s : Name) : UInt64 := Id.run do
  let mut h : UInt64 := 91
  let mut todo := #[s]
  let mut seen : NameSet := {}
  while h' : todo.size > 0 do
    let t := todo.back
    todo := todo.pop
    if seen.contains t then continue
    seen := seen.insert t
    let some si := getStructureInfo? env t
      | h := mixList h [92, hash t]; continue
    h := mixList h ([hash t] ++ (getStructureFieldsFlattened env t (includeSubobjectFields := true)).toList.map hash)
    for p in si.parentInfo do
      h := mixList h [hash p.projFn, hash p.subobject]
      todo := todo.push p.structName
  return h

-- Not `ctor.getPrefix`: a private constructor is `_private.<module>.0.<S>.<ctor>`, so the inductive is read off the constructor.
def projStructLayout (env : Environment) (ctor : Name) : UInt64 × Reads :=
  match env.find? ctor with
  | some (.ctorInfo cv) => (structLayout env cv.induct, ({ consts := #[ctor] } : Reads).structs (structClosure env cv.induct))
  | _ => (mixList 93 [hash ctor], { consts := #[ctor] })

def structData (env : Environment) (s : Name) : UInt64 :=
  match getStructureInfo? env s with
  | some si => mixList 23 (si.fieldNames.toList.map hash ++
      (getStructureParentInfo env s).toList.map (fun (p : StructureParentInfo) => hash p.structName))
  | none => 0

unsafe def record (env : Environment) (c : Name) : CoreM (Rec × Reads) := do
  let own : Reads := { consts := #[c], entries := recordExts.map (·, c) }
  let some ci := env.find? c
    | let m := mix 99 (hash c); return (⟨m, m, m, m, m, m, m, m, m, m⟩, own)
  let auxValue := match ci with
    | .opaqueInfo o => hashExpr o.value
    | .defnInfo d => if (Match.Extension.getMatcherInfo? env c).isSome then hashExpr d.value else 0
    | _ => 0
  let (projStruct, proj, layout) := match env.getProjectionFnInfo? c with
    | some p =>
      let (ps, r) := projStructLayout env p.ctorName
      (ps, mixList 21 [hash p.ctorName, hash p.numParams, hash p.i, hash p.fromClass], r)
    | none => (0, 0, {})
  let coe := match ← getCoeFnInfo? c with
    | some cf => mix 24 (hash (reprStr cf))
    | none => 0
  let matcher := match Match.Extension.getMatcherInfo? env c with
    | some mi => mix 28 (hash (reprStr mi))
    | none => 0
  return ({ shape := shapeOf ci.type, auxValue, projStruct, proj, cls := hash (isClass env c),
            struct := structData env c, coe,
            pp := mixList 26 [hash (hasPPNoDotAttribute env c), hash (hasPPUsingAnonymousConstructorAttribute env c)],
            matcher, prot := hash (isProtected env c) }, own ++ layout)

def defaultFnCandidates (env : Environment) (s f : Name) : Array Name :=
  let base := (getProjFnForField? env s f).getD (s ++ f)
  #[mkDefaultFnOfProjFn base, mkInheritedDefaultFnOfProjFn base]

unsafe def ctorExtra (env : Environment) (s : Name) : UInt64 × Reads := Id.run do
  let mut h : UInt64 := mixList 97 [hash (hasPPUsingAnonymousConstructorAttribute env s)]
  let mut reads : Reads := ({ entries := #[(extPPAnon, s)] } : Reads).structs (structClosure env s)
  for f in getStructureFieldsFlattened env s (includeSubobjectFields := true) do
    reads := { reads with consts := reads.consts ++ defaultFnCandidates env s f }
    if let some fn := getEffectiveDefaultFnForField? env s f then
      let body := match env.find? fn with
        | some ci => mixList (hashExpr ci.type) [((ci.value? (allowOpaque := true)).map hashExpr).getD 0]
        | none => 98
      h := mixList h [hash f, hash fn, body]
  return (h, reads)

def factsOf (env : Environment) (c : Name) : UInt64 :=
  match env.find? c with
  | none => 1
  | some (.ctorInfo cv) => mixList 2 [hash cv.induct]
  | some _ => mixList 3 ((binderInfos env c).toList.map biCode)

structure Memo where
  recs : Std.HashMap Name (Rec × Reads) := {}
  res : Std.HashMap (Name × Name) UInt64 := {}
  facts : Std.HashMap Name UInt64 := {}
  scx : Std.HashMap Name (UInt64 × Reads) := {}

def partNames (scx : Bool) : Array String :=
  #["own constant", "type skeleton", "value skeleton", "equations", "shown names", "records' shapes",
    "records' auxiliary values", "records' projection structures", "records' projections", "records' classes",
    "records' coercions", "records' pp attributes", "records' matchers", "records' protection", "resolutions",
    "structure data"] ++ (if scx then #["structure-instance defaults (SCX)"] else #[]) ++ #["own record"]

structure KeyOut where
  key : UInt64
  parts : Array UInt64
  members : Reads
  eqns : Reads
  shown : Array Name
  spaces : Array Name
  ctorInducts : Array Name

unsafe def keyOf (env : Environment) (registered : NameMap (Array Name)) (memo : IO.Ref Memo) (scx : Bool)
    (n : Name) (ci : ConstantInfo) : CoreM KeyOut := do
  let recordOf (c : Name) : CoreM Rec := do
    if let some (r, _) := (← memo.get).recs[c]? then return r
    let (r, rd) ← record env c
    memo.modify fun s => { s with recs := s.recs.insert c (r, rd) }
    return r
  let (members, memberReads) := memberConsts env ci
  let (cTS, skelT) := hashSkel env (#[ci.type] ++ members.filterMap fun m => (env.find? m).map (·.type))
  let (cVS, cE, skelV, eqnReads) := match ci with
    | .defnInfo v =>
      let (eh, es, r) := eqnData env registered n
      let (vs, sv) := hashSkel env (#[v.value] ++ es)
      (vs, eh, sv, r)
    | _ => (0, 0, {}, {})
  let memberSet : NameSet := members.foldl (·.insert ·) {}
  let shown := ((skelT.toList ++ skelV.toList).foldl (·.insert ·) memberSet).toArray.qsort Name.quickLt
  let spaces := members.foldl (fun s m => if s.contains m.getPrefix then s else s.push m.getPrefix) #[n.getPrefix]
  let mut names : UInt64 := 71
  let mut agg : Array UInt64 := Array.replicate 9 72
  let mut res : UInt64 := 73
  let mut sstrn : UInt64 := 74
  let mut scxH : UInt64 := 75
  let mut ctorInducts : Array Name := #[]
  for c in shown do
    let r ← recordOf c
    unless (← memo.get).facts.contains c do
      memo.modify fun s => { s with facts := s.facts.insert c (factsOf env c) }
    let mut rs : UInt64 := 0
    for ns in spaces do
      let x ← match (← memo.get).res[(ns, c)]? with
        | some x => pure x
        | none => do
          let x := resolution env ns c
          memo.modify fun s => { s with res := s.res.insert (ns, c) x }
          pure x
      rs := mix rs x
    names := mix names (hash c)
    agg := (agg.zip r.shown).map fun (a, x) => mix a x
    res := mix res rs
    if memberSet.contains c then sstrn := mixList sstrn [hash c, r.struct]
    if let some (.ctorInfo cv) := env.find? c then
      ctorInducts := ctorInducts.push cv.induct
      if isStructure env cv.induct then
        sstrn := mixList sstrn [76, hash cv.induct, structData env cv.induct]
        if scx then
          let x ← match (← memo.get).scx[cv.induct]? with
            | some (x, _) => pure x
            | none => do
              let (x, rd) := ctorExtra env cv.induct
              memo.modify fun s => { s with scx := s.scx.insert cv.induct (x, rd) }
              pure x
          scxH := mixList scxH [hash cv.induct, x]
  let comps := #[mixList 51 [hash n, kindCode ci, hash ci.levelParams], cTS, cVS, cE, names] ++ agg ++
    #[res, sstrn] ++ (if scx then #[scxH] else #[])
  let own := (← recordOf n).own
  return { key := mixList (comps.foldl mix 7) own, parts := comps.push (mixList 77 own),
           members := { memberReads with consts := memberReads.consts ++ members }, eqns := eqnReads,
           shown, spaces, ctorInducts }

def candidates (world : World) (targets : Array Name) : IO (Array Name) := do
  let mut seen : NameSet := {}
  let mut cands : Array Name := #[]
  for m in targets do
    let some idx := world.moduleIndex? m | throw <| IO.userError s!"print key: module not present: {m}"
    for c in world.constNames idx do
      if seen.contains c then continue
      seen := seen.insert c
      cands := cands.push c
  return cands

def coreCtx : Core.Context := { fileName := "<printkey>", fileMap := default, options := {}, maxHeartbeats := 0 }

unsafe def keys (env : Environment) (world : World) (targets : Array Name) (jobs : Nat) (scx : Bool) :
    IO (Std.HashMap Name KeyOut) := do
  let registered ← registeredEqns env
  let cands ← candidates world targets
  let jobs := max jobs 1
  let tasks ← (Array.range jobs).mapM fun k => IO.asTask (prio := .dedicated) do
    let memo ← IO.mkRef ({} : Memo)
    let mut out : Array (Name × KeyOut) := #[]
    let mut i := k
    while i < cands.size do
      let c := cands[i]!
      if let some ci := env.find? c then
        let (h, _) ← (keyOf env registered memo scx c ci).toIO coreCtx { env := env }
        out := out.push (c, h)
      i := i + jobs
    return out
  let mut keys : Std.HashMap Name KeyOut := Std.HashMap.emptyWithCapacity cands.size
  for t in tasks do
    for (c, h) in ← IO.ofExcept t.get do keys := keys.insert c h
  return keys

end OleanReader.PrintKey
