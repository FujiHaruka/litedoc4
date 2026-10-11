import Lean
open Lean

/-!
The one text both sides of the reader oracle write: the Lean that wrote a core library, loading
it itself, and the reader, decoding the same files. This file is compiled by every writer
toolchain unchanged, so it names nothing that one of them lacks.
-/

namespace OleanReader.Serialize

structure StrictE where
  e : Expr

instance : BEq StrictE := ⟨fun a b => a.e.equal b.e⟩
instance : Hashable StrictE := ⟨fun a => a.e.hash⟩

structure SState where
  nodes : Array Json := #[]
  levels : Array Json := #[]
  emap : Std.HashMap StrictE Nat := {}
  lmap : Std.HashMap Level Nat := {}

def nameToJson (n : Name) : Json :=
  let rec go : Name → Array Json → Array Json
    | .anonymous, acc => acc
    | .str p s, acc => go p (acc.push (Json.str s))
    | .num p k, acc => go p (acc.push (toJson k))
  Json.arr (go n #[]).reverse

def biCode : BinderInfo → String
  | .default => "d" | .implicit => "i" | .strictImplicit => "s" | .instImplicit => "c"

/-- A syntax value is named, not printed: the printer is not part of what is being compared. -/
def dataValueJson : DataValue → Json
  | .ofString s => Json.arr #["s", Json.str s]
  | .ofBool b => Json.arr #["b", toJson b]
  | .ofName n => Json.arr #["n", nameToJson n]
  | .ofNat n => Json.arr #["N", Json.str (toString n)]
  | .ofInt i => Json.arr #["I", Json.str (toString i)]
  | .ofSyntax _ => Json.arr #["x"]

partial def serL (l : Level) : StateM SState Nat := do
  if let some i := (← get).lmap[l]? then return i
  let j ← match l with
    | .zero => pure (Json.arr #["z"])
    | .succ a => do let i ← serL a; pure (Json.arr #["s", toJson i])
    | .max a b => do let i ← serL a; let k ← serL b; pure (Json.arr #["m", toJson i, toJson k])
    | .imax a b => do let i ← serL a; let k ← serL b; pure (Json.arr #["i", toJson i, toJson k])
    | .param n => pure (Json.arr #["p", nameToJson n])
    | .mvar m => pure (Json.arr #["v", nameToJson m.name])
  let s ← get
  let idx := s.levels.size
  set { s with levels := s.levels.push j, lmap := s.lmap.insert l idx }
  return idx

partial def serE (e : Expr) : StateM SState Nat := do
  if let some i := (← get).emap[StrictE.mk e]? then return i
  let j ← match e with
    | .bvar i => pure (Json.arr #["b", toJson i])
    | .fvar id => pure (Json.arr #["F", nameToJson id.name])
    | .mvar id => pure (Json.arr #["M", nameToJson id.name])
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
    | .mdata d b => do
      let k ← serE b
      pure (Json.arr #["D", Json.arr (d.entries.toArray.map fun (n, v) => Json.arr #[nameToJson n, dataValueJson v]), toJson k])
    | .proj s i b => do let k ← serE b; pure (Json.arr #["J", nameToJson s, toJson i, toJson k])
  let s ← get
  let idx := s.nodes.size
  set { s with nodes := s.nodes.push j, emap := s.emap.insert (StrictE.mk e) idx }
  return idx

def exprJson (e : Expr) : Json :=
  let (root, s) := (serE e).run {}
  Json.mkObj [("levels", Json.arr s.levels), ("nodes", Json.arr s.nodes), ("root", toJson root)]

def kindCode : ConstantInfo → String
  | .axiomInfo _ => "axiom" | .defnInfo _ => "def" | .thmInfo _ => "theorem"
  | .opaqueInfo _ => "opaque" | .quotInfo _ => "quot" | .inductInfo _ => "inductive"
  | .ctorInfo _ => "ctor" | .recInfo _ => "recursor"

def positionJson (p : Position) : Json := Json.arr #[toJson p.line, toJson p.column]

def rangeJson (r : DeclarationRange) : Json :=
  Json.arr #[positionJson r.pos, toJson r.charUtf16, positionJson r.endPos, toJson r.endCharUtf16]

def rangesJson (r : DeclarationRanges) : Json :=
  Json.mkObj [("range", rangeJson r.range), ("selectionRange", rangeJson r.selectionRange)]

def scopeCode {α} : ScopedEnvExtension.Entry α → String × α
  | .global a => ("global", a)
  | .scoped ns a => (s!"scoped:{ns}", a)

def lastComponent (s : String) : String := (s.splitOn ".").getLast!

/-- `.implicit` would separate `implicitReducible` from `semireducible`, but the writers before
v4.33.0 have no such mode. -/
def unfoldMask (s : ReducibilityStatus) : IO String := do
  let dummy : Name := `_olean_reader_oracle.dummy
  let info : ConstantInfo := .axiomInfo { name := dummy, levelParams := [], type := .sort 0, isUnsafe := false }
  let ctx : Core.Context := { fileName := "<olean-reader-oracle>", fileMap := default }
  let act : MetaM String := do
    setReducibilityStatus dummy s
    let modes : List Meta.TransparencyMode := [.reducible, .instances, .default]
    let bits ← modes.mapM fun m => do
      pure (if ← Meta.withTransparency m (Meta.canUnfold info) then "1" else "0")
    return String.join bits
  let (r, _) ← (act.run' {} {}).toIO ctx { env := ← mkEmptyEnvironment }
  return r

def extLine (n : String) (present : Bool) : String :=
  s!"ext {n} {if present then "present" else "absent"}"

def moduleLine (m : Name) (constants : Nat) : String := s!"module {m} {constants}"

def constLine (ci : ConstantInfo) : String := s!"const {ci.name} {kindCode ci}"

def reducibilityLine (m n : Name) (stored : Nat) : String := s!"red {m} {n} {stored}"

def reducibilityExtraLine (m : Name) (scope : String) (n : Name) (stored : Nat) : String :=
  s!"redx {m} {scope} {n} {stored}"

def statusLine (stored : Nat) (writerName mask : String) : String :=
  s!"status {stored} {writerName} {mask}"

def instanceLine (m : Name) (scope : String) (e : Meta.InstanceEntry) (attrKind : Nat) : String :=
  let j := Json.mkObj [
    ("globalName", match e.globalName? with | some n => nameToJson n | none => Json.null),
    ("priority", toJson e.priority), ("synthOrder", toJson e.synthOrder),
    ("attrKind", toJson attrKind), ("keys", toJson e.keys.size), ("val", exprJson e.val)]
  s!"inst {m} {scope} {j.compress}"

def layoutLine (ctor : Name) (objs scalarBytes : Nat) : String := s!"layout {ctor} {objs} {scalarBytes}"

def namespaceLine (m n : Name) : String := s!"ns {m} {n}"

def originJson : Meta.Origin → Json
  | .decl n post inv => Json.arr #["decl", nameToJson n, toJson post, toJson inv]
  | .fvar id => Json.arr #["fvar", nameToJson id.name]
  | .stx id _ => Json.arr #["stx", nameToJson id]
  | .other n => Json.arr #["other", nameToJson n]

def simpEntryJson : Meta.SimpEntry → Json
  | .thm t => Json.mkObj [
      ("origin", originJson t.origin), ("priority", toJson t.priority), ("post", toJson t.post),
      ("perm", toJson t.perm), ("rfl", toJson t.rfl), ("keys", toJson t.keys.size),
      ("levelParams", Json.arr (t.levelParams.map nameToJson)), ("proof", exprJson t.proof)]
  | .toUnfold n => Json.arr #["toUnfold", nameToJson n]
  | .toUnfoldThms n thms => Json.arr #["toUnfoldThms", nameToJson n, Json.arr (thms.map nameToJson)]

def simpLine (m : Name) (scope : String) (e : Meta.SimpEntry) : String :=
  s!"simp {m} {scope} {(simpEntryJson e).compress}"

def structureLine (si : StructureInfo) : String :=
  let fields := si.fieldInfo.map fun f => Json.mkObj [
    ("fieldName", nameToJson f.fieldName), ("projFn", nameToJson f.projFn),
    ("subobject", match f.subobject? with | some n => nameToJson n | none => Json.null),
    ("binderInfo", Json.str (biCode f.binderInfo)),
    ("autoParam", match f.autoParam? with | some e => exprJson e | none => Json.null)]
  let parents := si.parentInfo.map fun p => Json.mkObj [
    ("structName", nameToJson p.structName), ("subobject", toJson p.subobject), ("projFn", nameToJson p.projFn)]
  let j := Json.mkObj [("fieldNames", Json.arr (si.fieldNames.map nameToJson)),
    ("fields", Json.arr fields), ("parents", Json.arr parents)]
  s!"struct {si.structName} {j.compress}"

def moduleDocLine (m : Name) (d : ModuleDoc) : String :=
  s!"mdoc {m} {(Json.mkObj [("doc", Json.str d.doc), ("range", rangeJson d.declarationRange)]).compress}"

def versoKeyLine (m n : Name) : String := s!"verso {m} {n}"

def declLine (m : Name) (kind : String) (cv : ConstantVal) (ranges? : Option DeclarationRanges)
    (doc? : Option String) : String :=
  let j := Json.mkObj [
    ("name", nameToJson cv.name), ("module", Json.str m.toString), ("kind", Json.str kind),
    ("levelParams", Json.arr (cv.levelParams.toArray.map nameToJson)),
    ("type", exprJson cv.type),
    ("ranges", match ranges? with | some r => rangesJson r | none => Json.null),
    ("doc", match doc? with | some d => Json.str d | none => Json.null)]
  s!"decl {j.compress}"

def splitmix (s : UInt64) : UInt64 × UInt64 :=
  let s := s + 0x9E3779B97F4A7C15
  let z := (s ^^^ (s >>> 30)) * 0xBF58476D1CE4E5B9
  let z := (z ^^^ (z >>> 27)) * 0x94D049BB133111EB
  (z ^^^ (z >>> 31), s)

def sample (seed : UInt64) (n k : Nat) : Array Nat := Id.run do
  if k ≥ n then return Array.range n
  let mut perm := Array.range n
  let mut st := seed
  for i in [0:k] do
    let (r, st') := splitmix st
    st := st'
    let j := i + (r.toNat % (n - i))
    let a := perm[i]!
    perm := (perm.set! i perm[j]!).set! j a
  return (perm.extract 0 k).qsort (· < ·)

end OleanReader.Serialize
