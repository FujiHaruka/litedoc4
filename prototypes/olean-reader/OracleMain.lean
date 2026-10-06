import OleanReader
open Lean OleanReader

/-! The reader held against a Lean's own answer: the drift log's serialization (`Drift.lean`,
verbatim from `structure StrictE` to `serialize`), applied to the types the reader decodes, compared
byte for byte with what that Lean serialized for the same seeded sample. -/

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


def readSearchPath (f : System.FilePath) : IO (Array System.FilePath) := do
  return (← IO.FS.lines f).filter (!·.isEmpty) |>.map System.FilePath.mk

/-- `oracle <searchpath-file> <limit|all> <oracle.jsonl> <out-types.jsonl|->`: reads every module
of `Mathlib`'s closure once, entries decoded, proofs omitted unless `ORACLE_KEEP_PROOFS=1`, and compares the serialized type of
every oracle record. -/
def oracleMain (spFile limitS oracle outTypes : String) : IO UInt32 := do
  let sp ← readSearchPath spFile
  let t0 ← IO.monoMsNow
  let mods ← closure sp #[`Mathlib]
  let mods := if limitS == "all" then mods else mods.extract 0 limitS.toNat!
  let mut wanted : Std.HashSet Name := {}
  let mut oracleRecs : Array (Name × String) := #[]
  for line in ← IO.FS.lines oracle do
    if line.isEmpty then continue
    let j ← IO.ofExcept (Json.parse line)
    let nameS ← IO.ofExcept (j.getObjValAs? String "nameStr")
    let ty ← IO.ofExcept (j.getObjVal? "type")
    let nj ← IO.ofExcept (j.getObjVal? "name")
    let n := (← IO.ofExcept nj.getArr?).foldl (init := Name.anonymous) fun acc c =>
      match c with
      | .str s => Name.mkStr acc s
      | .num k => Name.mkNum acc k.mantissa.toNat
      | _ => acc
    unless n.toString == nameS do throw <| IO.userError s!"name decode mismatch {n} vs {nameS}"
    wanted := wanted.insert n
    oracleRecs := oracleRecs.push (n, ty.compress)
  let omitProofs := (← IO.getEnv "ORACLE_KEEP_PROOFS") != some "1"
  let stats ← IO.mkRef ({} : ReadStats)
  let mut found : Std.HashMap Name String := {}
  let mut bytes := 0
  let mut objects := 0
  for m in mods do
    let parts ← loadModule sp m
    let ((md, _), st) ← runDM parts (decModuleData omitProofs true parts.back!.root stats)
    bytes := bytes + parts.foldl (· + ·.bytes.size) 0
    objects := objects + st.objects
    for ci in md.constants do
      if wanted.contains ci.name && !found.contains ci.name then
        found := found.insert ci.name (serialize ci.type).1.compress
  let t1 ← IO.monoMsNow
  let s ← stats.get
  let w ← writerOfClosure.get
  IO.eprintln s!"writer of every part read: Lean {w}"
  IO.eprintln s!"modules {mods.size}, bytes {bytes}, objects visited {objects}, constants {s.constants}, entries decoded {s.entriesDecoded}, entries not decoded {s.entriesSkipped} in {s.skippedExts.size} extensions; {t1 - t0} ms"
  IO.eprintln s!"checked against the stored computed field: Name hashes {s.names}, Level data {s.levels}, Expr data {s.exprs}"
  for (e, k) in s.decodedExts.toArray.qsort (fun a b => a.1.toString < b.1.toString) do
    IO.eprintln s!"  decoded ext {e} {k}"
  for (e, k) in s.skippedExts.toArray.qsort (fun a b => a.2 > b.2) do
    IO.eprintln s!"  not decoded ext {e} {k}"
  let mut same := 0
  let mut missing := 0
  let mut diff := #[]
  for (n, ty) in oracleRecs do
    match found[n]? with
    | none => missing := missing + 1
    | some t => if t == ty then same := same + 1 else diff := diff.push n
  IO.println s!"oracle: identical {same} of {oracleRecs.size}; not found {missing}; different {diff.size}"
  for n in diff.extract 0 10 do IO.println s!"  different: {n}"
  if outTypes != "-" then
    let h ← IO.FS.Handle.mk outTypes .write
    for (n, _) in oracleRecs do
      if let some t := found[n]? then h.putStrLn t
  return if same == oracleRecs.size then 0 else 1

def main (args : List String) : IO UInt32 := do
  match args with
  | [sp, limit, oracle, out] => oracleMain sp limit oracle out
  | _ => IO.eprintln "usage: oracle <searchpath-file> <limit|all> <oracle.jsonl> <out-types.jsonl|->"; return 2
