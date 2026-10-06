import Lean
open Lean

/-!
An `.olean` reader that walks the bytes of a module written by an older Lean and rebuilds its
`ModuleData` as values of the Lean that runs it. It knows the writer versions in `knownWriters`;
anything else is refused by name. Every object it meets is checked against the layout it expects (tag,
object-field count, byte size) and every computed field it can recompute (Name hash, Level and
Expr data) is compared with the stored one; a mismatch is an error, never a skip.
-/

namespace OleanReader

def headerSize : Nat := 88

def namespacesExtV434 : Name := Name.mkNum `_private.Lean.Namespace 0 ++ `Lean.namespacesExt

/-- Everything the reader knows about one writer, selected by the header's version string and
githash together. -/
structure WriterVersion where
  leanVersion       : String
  githash           : String
  /-- Extensions the running Lean registers that this writer does not have. Seeing one of them
  in this writer's data is an error. -/
  absentExts        : List String
  /-- What each stored `ReducibilityStatus` constructor index means, as the running Lean's value. -/
  reducibility      : Array ReducibilityStatus

instance : Inhabited WriterVersion := ⟨⟨"", "", [], #[]⟩⟩

def v4_31_0 : WriterVersion := {
  leanVersion := "4.31.0", githash := "68218e876d2a38b1985b8590fff244a83c321783"
  absentExts := []
  reducibility := #[.reducible, .semireducible, .irreducible, .instanceReducible] }

def v4_32_0 : WriterVersion := {
  leanVersion := "4.32.0", githash := "8c9756b28d64dab099da31a4c09229a9e6a2ef35"
  absentExts := ["Inclusion.IntervalDyadicReal.intervalDyadicRealFamily.hypothesisExt", "Inclusion.IntervalDyadicReal.intervalDyadicRealFamily.inclusionExt", "Inclusion.coreFamily.hypothesisExt", "Inclusion.coreFamily.inclusionExt", "Inclusion.inclusionParamExt", "Lean.Doc.DeferredCheck.handlerExt", "Lean.Doc.deferredCheckExt", "Lean.Doc.docBlockMdExt", "Lean.Doc.docInlineMdExt", "Lean.Elab.Tactic.Do.Internal.VCGen.frameProcExt", "Lean.Linter.CodeQuality.packageCheckExt", "Lean.Meta.Grind.homoExt", "Lean.Meta.Grind.homoPredExt", "Lean.Meta.Grind.homoSourceTypesExt", "Lean.Meta.Grind.liaExt", "Lean.Meta.Tactic.BVDecide.metaIntToBitVecExt", "Lean.Meta.Tactic.BVDecide.symIntToBitVecExt", "Lean.bool_to_prop", "Mathlib.Tactic.Echelon.bareissExt", "Mathlib.Tactic.higherOrderAttr", "Std.Internal.treeTacExt", "_private.Batteries.Util.ProofWanted.0.wantedArityExt"]
  reducibility := #[.reducible, .semireducible, .irreducible, .instanceReducible] }

def knownWriters : List WriterVersion := [v4_31_0, v4_32_0]

structure Part where
  path  : System.FilePath
  bytes : ByteArray
  base  : UInt64
  root  : UInt64
  ver   : WriterVersion

instance : Inhabited Part := ⟨⟨"", .empty, 0, 0, default⟩⟩

@[inline] def u8 (b : ByteArray) (o : Nat) : UInt8 := b.get! o
@[inline] def u16 (b : ByteArray) (o : Nat) : UInt16 :=
  (b.get! o).toUInt16 ||| ((b.get! (o+1)).toUInt16 <<< 8)
@[inline] def u32 (b : ByteArray) (o : Nat) : UInt32 :=
  (b.get! o).toUInt32 ||| ((b.get! (o+1)).toUInt32 <<< 8) |||
  ((b.get! (o+2)).toUInt32 <<< 16) ||| ((b.get! (o+3)).toUInt32 <<< 24)
@[inline] def u64 (b : ByteArray) (o : Nat) : UInt64 :=
  (u32 b o).toUInt64 ||| ((u32 b (o+4)).toUInt64 <<< 32)

def cstr (b : ByteArray) (o n : Nat) : String := Id.run do
  let mut s := ""
  for i in [0:n] do
    let c := b.get! (o+i)
    if c == 0 then break
    s := s.push (Char.ofNat c.toNat)
  return s

initialize writerOfClosure : IO.Ref String ← IO.mkRef ""

def loadPart (path : System.FilePath) : IO Part := do
  let bytes ← IO.FS.readBinFile path
  if bytes.size < headerSize + 8 then throw <| IO.userError s!"{path}: shorter than an .olean header"
  unless cstr bytes 0 5 == "olean" do throw <| IO.userError s!"{path}: no olean marker"
  let version := u8 bytes 5
  let flags := u8 bytes 6
  let lv := cstr bytes 7 33
  let gh := cstr bytes 40 40
  unless version == 2 && flags == 1 do
    throw <| IO.userError s!"{path}: header version {version} flags {flags}, known: 2 / 1"
  let some ver := knownWriters.find? (fun w => w.leanVersion == lv && w.githash == gh)
    | throw <| IO.userError s!"{path}: written by Lean {lv} ({gh}); this reader knows only {", ".intercalate (knownWriters.map fun w => s!"{w.leanVersion} ({w.githash})")}"
  let first ← writerOfClosure.modifyGet fun w => (w, if w.isEmpty then lv else w)
  unless first.isEmpty || first == lv do
    throw <| IO.userError s!"{path}: written by Lean {lv}, but this closure was read as written by {first}"
  let base := u64 bytes 80
  let root := u64 bytes headerSize
  return { path, bytes, base, root, ver }

structure DState where
  names   : Std.HashMap UInt64 Name := {}
  levels  : Std.HashMap UInt64 Level := {}
  exprs   : Std.HashMap UInt64 Expr := {}
  objects : Nat := 0

abbrev DM := ReaderT (Array Part) (StateRefT DState IO)

def fail (what : String) (addr : UInt64) (msg : String) : DM α :=
  throw <| IO.userError s!"olean reader: {what} at 0x{String.ofList (Nat.toDigits 16 addr.toNat)}: {msg}"

@[inline] def isScalar (v : UInt64) : Bool := v &&& 1 == 1
@[inline] def unbox (v : UInt64) : Nat := (v >>> 1).toNat

structure Obj where
  b     : ByteArray
  o     : Nat
  tag   : Nat
  other : Nat
  csSz  : Nat

@[inline] def obj (what : String) (addr : UInt64) : DM Obj := do
  if isScalar addr then fail what addr "expected an object, found a scalar"
  let ps ← read
  for p in ps do
    if addr ≥ p.base && addr < p.base + p.bytes.size.toUInt64 then
      let o := (addr - p.base).toNat
      modify fun s => { s with objects := s.objects + 1 }
      return { b := p.bytes, o, tag := (u8 p.bytes (o+7)).toNat, other := (u8 p.bytes (o+6)).toNat,
               csSz := (u16 p.bytes (o+4)).toNat }
  fail what addr "address outside every part of this module"

@[inline] def align8 (n : Nat) : Nat := (n + 7) / 8 * 8

/-- A constructor object with the expected tag, object-field count and scalar size. -/
@[inline] def ctor (what : String) (addr : UInt64) (tag objs ssz : Nat) : DM Obj := do
  let x ← obj what addr
  unless x.tag == tag && x.other == objs && x.csSz == align8 (8 + 8*objs + ssz) do
    fail what addr s!"expected ctor tag {tag} objs {objs} size {align8 (8 + 8*objs + ssz)}, found tag {x.tag} objs {x.other} size {x.csSz}"
  return x

@[inline] def Obj.field (x : Obj) (i : Nat) : UInt64 := u64 x.b (x.o + 8 + 8*i)
@[inline] def Obj.sc8 (x : Obj) (off : Nat) : UInt8 := u8 x.b (x.o + 8 + 8*x.other + off)
@[inline] def Obj.sc32 (x : Obj) (off : Nat) : UInt32 := u32 x.b (x.o + 8 + 8*x.other + off)
@[inline] def Obj.sc64 (x : Obj) (off : Nat) : UInt64 := u64 x.b (x.o + 8 + 8*x.other + off)

def decBool (what : String) (addr : UInt64) (v : UInt8) : DM Bool :=
  match v with
  | 0 => pure false
  | 1 => pure true
  | _ => fail what addr s!"Bool byte {v}"

def decBoxedBool (v : UInt64) : DM Bool := do
  unless isScalar v && unbox v ≤ 1 do fail "Bool" v "expected a boxed Bool"
  return unbox v == 1

/-- `Nat`: a boxed scalar or a GMP bignum (header flag bit 0 = 1 was checked). -/
def decNat (v : UInt64) : DM Nat := do
  if isScalar v then return unbox v
  let x ← obj "Nat" v
  unless x.tag == 250 do fail "Nat" v s!"expected an MPZ object (tag 250), found tag {x.tag}"
  let sz := (u32 x.b (x.o + 12)).toNat
  if sz ≥ 2^31 then fail "Nat" v "negative bignum"
  let limbs := u64 x.b (x.o + 16)
  unless limbs == v + 24 do fail "Nat" v "limb pointer does not follow the object"
  let mut n := 0
  for i in [0:sz] do
    n := n + (u64 x.b (x.o + 24 + 8*i)).toNat * 2^(64*i)
  return n

def decInt (v : UInt64) : DM Int := do
  if isScalar v then
    let w := (v >>> 1).toUInt32
    return if w ≥ 0x80000000 then Int.negSucc (0xFFFFFFFF - w).toNat else Int.ofNat w.toNat
  let x ← obj "Int" v
  unless x.tag == 250 do fail "Int" v s!"expected an MPZ object, found tag {x.tag}"
  let szRaw := u32 x.b (x.o + 12)
  let neg := szRaw ≥ 0x80000000
  let sz := if neg then (0 - szRaw).toNat else szRaw.toNat
  let mut n := 0
  for i in [0:sz] do
    n := n + (u64 x.b (x.o + 24 + 8*i)).toNat * 2^(64*i)
  return if neg then -(n : Int) else n

def decString (v : UInt64) : DM String := do
  let x ← obj "String" v
  unless x.tag == 249 do fail "String" v s!"expected a String object (tag 249), found tag {x.tag}"
  let size := (u64 x.b (x.o + 8)).toNat
  if size == 0 then fail "String" v "size 0 (no terminator)"
  let bs := x.b.extract (x.o + 32) (x.o + 32 + size - 1)
  match String.fromUTF8? bs with
  | some s =>
    unless s.length == (u64 x.b (x.o + 24)).toNat do fail "String" v "stored length differs"
    return s
  | none => fail "String" v "invalid UTF-8"

@[specialize] def decArray (what : String) (v : UInt64) (f : UInt64 → DM α) : DM (Array α) := do
  let x ← obj what v
  unless x.tag == 246 do fail what v s!"expected an Array object (tag 246), found tag {x.tag}"
  let n := (u64 x.b (x.o + 8)).toNat
  let mut out := Array.mkEmpty n
  for i in [0:n] do
    out := out.push (← f (u64 x.b (x.o + 24 + 8*i)))
  return out

def decNatArray (v : UInt64) : DM (Array Nat) := decArray "Array Nat" v decNat

@[specialize] def decList (what : String) (v : UInt64) (f : UInt64 → DM α) : DM (List α) := do
  let mut acc : Array α := #[]
  let mut cur := v
  while true do
    if isScalar cur then
      unless unbox cur == 0 do fail what cur s!"List: scalar {unbox cur}"
      break
    let x ← ctor what cur 1 2 0
    acc := acc.push (← f (x.field 0))
    cur := x.field 1
  return acc.toList

@[specialize] def decOption (what : String) (v : UInt64) (f : UInt64 → DM α) : DM (Option α) := do
  if isScalar v then
    unless unbox v == 0 do fail what v s!"Option: scalar {unbox v}"
    return none
  let x ← ctor what v 1 1 0
  return some (← f (x.field 0))

@[specialize] def decPair (what : String) (v : UInt64) (f : UInt64 → DM α) (g : UInt64 → DM β) : DM (α × β) := do
  let x ← ctor what v 0 2 0
  return (← f (x.field 0), ← g (x.field 1))

partial def decName (v : UInt64) : DM Name := do
  if isScalar v then
    unless unbox v == 0 do fail "Name" v s!"scalar {unbox v}"
    return .anonymous
  if let some n := (← get).names[v]? then return n
  let x ← obj "Name" v
  unless x.other == 2 && x.csSz == 32 && (x.tag == 1 || x.tag == 2) do
    fail "Name" v s!"tag {x.tag} objs {x.other} size {x.csSz}"
  let pre ← decName (x.field 0)
  let n ← if x.tag == 1 then pure (Name.str pre (← decString (x.field 1)))
    else pure (Name.num pre (← decNat (x.field 1)))
  unless n.hash == x.sc64 0 do fail "Name" v s!"stored hash differs from the recomputed one for {n}"
  modify fun s => { s with names := s.names.insert v n }
  return n

partial def decLevel (v : UInt64) : DM Level := do
  if isScalar v then
    unless unbox v == 0 do fail "Level" v s!"scalar {unbox v}"
    return .zero
  if let some l := (← get).levels[v]? then return l
  let x ← obj "Level" v
  let l ← match x.tag, x.other with
    | 1, 1 => pure (Level.succ (← decLevel (x.field 0)))
    | 2, 2 => pure (Level.max (← decLevel (x.field 0)) (← decLevel (x.field 1)))
    | 3, 2 => pure (Level.imax (← decLevel (x.field 0)) (← decLevel (x.field 1)))
    | 4, 1 => pure (Level.param (← decName (x.field 0)))
    | 5, 1 => pure (Level.mvar ⟨← decName (x.field 0)⟩)
    | t, k => fail "Level" v s!"unknown ctor tag {t} objs {k}"
  unless x.csSz == align8 (8 + 8*x.other + 8) do fail "Level" v s!"size {x.csSz}"
  unless (l.data : UInt64) == x.sc64 0 do fail "Level" v "stored data differs from the recomputed one"
  modify fun s => { s with levels := s.levels.insert v l }
  return l

def decBinderInfo (addr : UInt64) (b : UInt8) : DM BinderInfo :=
  match b with
  | 0 => pure .default | 1 => pure .implicit | 2 => pure .strictImplicit | 3 => pure .instImplicit
  | _ => fail "BinderInfo" addr s!"value {b}"

def decLiteral (v : UInt64) : DM Literal := do
  let x ← obj "Literal" v
  match x.tag with
  | 0 => let _ ← ctor "Literal.natVal" v 0 1 0; return .natVal (← decNat (x.field 0))
  | 1 => let _ ← ctor "Literal.strVal" v 1 1 0; return .strVal (← decString (x.field 0))
  | t => fail "Literal" v s!"tag {t}"

/-- `String.Pos.Raw` is a single-field structure and is represented as its `Nat`. -/
def decPos (v : UInt64) : DM String.Pos.Raw := return ⟨← decNat v⟩

def decSubstring (v : UInt64) : DM Substring.Raw := do
  let x ← ctor "Substring.Raw" v 0 3 0
  return ⟨← decString (x.field 0), ← decPos (x.field 1), ← decPos (x.field 2)⟩

def decSourceInfo (v : UInt64) : DM SourceInfo := do
  if isScalar v then
    unless unbox v == 2 do fail "SourceInfo" v s!"scalar {unbox v}"
    return .none
  let x ← obj "SourceInfo" v
  match x.tag with
  | 0 =>
    let x ← ctor "SourceInfo.original" v 0 4 0
    return .original (← decSubstring (x.field 0)) (← decPos (x.field 1)) (← decSubstring (x.field 2)) (← decPos (x.field 3))
  | 1 =>
    let x ← ctor "SourceInfo.synthetic" v 1 2 1
    return .synthetic (← decPos (x.field 0)) (← decPos (x.field 1)) (← decBool "SourceInfo.canonical" v (x.sc8 0))
  | t => fail "SourceInfo" v s!"tag {t}"

def decPreresolved (v : UInt64) : DM Syntax.Preresolved := do
  let x ← obj "Syntax.Preresolved" v
  match x.tag with
  | 0 => let x ← ctor "Preresolved.namespace" v 0 1 0; return .namespace (← decName (x.field 0))
  | 1 =>
    let x ← ctor "Preresolved.decl" v 1 2 0
    return .decl (← decName (x.field 0)) (← decList "List String" (x.field 1) decString)
  | t => fail "Syntax.Preresolved" v s!"tag {t}"

partial def decSyntax (v : UInt64) : DM Syntax := do
  if isScalar v then
    unless unbox v == 0 do fail "Syntax" v s!"scalar {unbox v}"
    return .missing
  let x ← obj "Syntax" v
  match x.tag with
  | 1 =>
    let x ← ctor "Syntax.node" v 1 3 0
    return .node (← decSourceInfo (x.field 0)) (← decName (x.field 1)) (← decArray "Array Syntax" (x.field 2) decSyntax)
  | 2 =>
    let x ← ctor "Syntax.atom" v 2 2 0
    return .atom (← decSourceInfo (x.field 0)) (← decString (x.field 1))
  | 3 =>
    let x ← ctor "Syntax.ident" v 3 4 0
    return .ident (← decSourceInfo (x.field 0)) (← decSubstring (x.field 1)) (← decName (x.field 2))
      (← decList "List Preresolved" (x.field 3) decPreresolved)
  | t => fail "Syntax" v s!"tag {t}"

def decDataValue (v : UInt64) : DM DataValue := do
  let x ← obj "DataValue" v
  match x.tag with
  | 0 => let x ← ctor "DataValue.ofString" v 0 1 0; return .ofString (← decString (x.field 0))
  | 1 => let x ← ctor "DataValue.ofBool" v 1 0 1; return .ofBool (← decBool "DataValue.ofBool" v (x.sc8 0))
  | 2 => let x ← ctor "DataValue.ofName" v 2 1 0; return .ofName (← decName (x.field 0))
  | 3 => let x ← ctor "DataValue.ofNat" v 3 1 0; return .ofNat (← decNat (x.field 0))
  | 4 => let x ← ctor "DataValue.ofInt" v 4 1 0; return .ofInt (← decInt (x.field 0))
  | 5 => let x ← ctor "DataValue.ofSyntax" v 5 1 0; return .ofSyntax (← decSyntax (x.field 0))
  | t => fail "DataValue" v s!"tag {t}"

/-- `KVMap` is a single-field structure and is represented as its `List`. -/
def decMData (v : UInt64) : DM MData := do
  return ⟨← decList "KVMap" v (decPair "Name × DataValue" · decName decDataValue)⟩

partial def decExpr (v : UInt64) : DM Expr := do
  if let some e := (← get).exprs[v]? then return e
  let x ← obj "Expr" v
  let e ← match x.tag, x.other with
    | 0, 1 => pure (Expr.bvar (← decNat (x.field 0)))
    | 1, 1 => pure (Expr.fvar ⟨← decName (x.field 0)⟩)
    | 2, 1 => pure (Expr.mvar ⟨← decName (x.field 0)⟩)
    | 3, 1 => pure (Expr.sort (← decLevel (x.field 0)))
    | 4, 2 => pure (Expr.const (← decName (x.field 0)) (← decList "List Level" (x.field 1) decLevel))
    | 5, 2 => pure (Expr.app (← decExpr (x.field 0)) (← decExpr (x.field 1)))
    | 6, 3 => pure (Expr.lam (← decName (x.field 0)) (← decExpr (x.field 1)) (← decExpr (x.field 2)) (← decBinderInfo v (x.sc8 8)))
    | 7, 3 => pure (Expr.forallE (← decName (x.field 0)) (← decExpr (x.field 1)) (← decExpr (x.field 2)) (← decBinderInfo v (x.sc8 8)))
    | 8, 4 => pure (Expr.letE (← decName (x.field 0)) (← decExpr (x.field 1)) (← decExpr (x.field 2)) (← decExpr (x.field 3)) (← decBool "Expr.letE.nondep" v (x.sc8 8)))
    | 9, 1 => pure (Expr.lit (← decLiteral (x.field 0)))
    | 10, 2 => pure (Expr.mdata (← decMData (x.field 0)) (← decExpr (x.field 1)))
    | 11, 3 => pure (Expr.proj (← decName (x.field 0)) (← decNat (x.field 1)) (← decExpr (x.field 2)))
    | t, k => fail "Expr" v s!"unknown ctor tag {t} objs {k}"
  let ssz := if x.tag == 6 || x.tag == 7 || x.tag == 8 then 9 else 8
  unless x.csSz == align8 (8 + 8*x.other + ssz) do fail "Expr" v s!"size {x.csSz} for tag {x.tag}"
  unless (e.data : UInt64) == x.sc64 0 do fail "Expr" v s!"stored data differs from the recomputed one (tag {x.tag})"
  modify fun s => { s with exprs := s.exprs.insert v e }
  return e

def decNameList (v : UInt64) : DM (List Name) := decList "List Name" v decName

def decConstantVal (v : UInt64) : DM ConstantVal := do
  let x ← ctor "ConstantVal" v 0 3 0
  return { name := ← decName (x.field 0), levelParams := ← decNameList (x.field 1), type := ← decExpr (x.field 2) }

def decHints (v : UInt64) : DM ReducibilityHints := do
  if isScalar v then
    match unbox v with
    | 0 => return .opaque
    | 1 => return .abbrev
    | k => fail "ReducibilityHints" v s!"scalar {k}"
  let x ← ctor "ReducibilityHints.regular" v 2 0 4
  return .regular (x.sc32 0)

def decSafety (addr : UInt64) (b : UInt8) : DM DefinitionSafety :=
  match b with
  | 0 => pure .unsafe | 1 => pure .safe | 2 => pure .partial
  | _ => fail "DefinitionSafety" addr s!"value {b}"

def decQuotKind (addr : UInt64) (b : UInt8) : DM QuotKind :=
  match b with
  | 0 => pure .type | 1 => pure .ctor | 2 => pure .lift | 3 => pure .ind
  | _ => fail "QuotKind" addr s!"value {b}"

/-- What the reader keeps of a theorem's proof. `omitProofs` replaces it by a constant that no
environment defines, so a use of it fails by name instead of answering. -/
def omittedProof : Expr := .const `_olean_reader.proofOmitted []

def decRule (v : UInt64) : DM RecursorRule := do
  let x ← ctor "RecursorRule" v 0 3 0
  return { ctor := ← decName (x.field 0), nfields := ← decNat (x.field 1), rhs := ← decExpr (x.field 2) }

def decConstantInfo (omitProofs : Bool) (v : UInt64) : DM ConstantInfo := do
  let x ← obj "ConstantInfo" v
  unless x.other == 1 && x.csSz == 16 do fail "ConstantInfo" v s!"tag {x.tag} objs {x.other} size {x.csSz}"
  let w := x.field 0
  match x.tag with
  | 0 =>
    let y ← ctor "AxiomVal" w 0 1 1
    return .axiomInfo { toConstantVal := ← decConstantVal (y.field 0), isUnsafe := ← decBool "AxiomVal.isUnsafe" w (y.sc8 0) }
  | 1 =>
    let y ← ctor "DefinitionVal" w 0 4 1
    return .defnInfo {
      toConstantVal := ← decConstantVal (y.field 0), value := ← decExpr (y.field 1),
      hints := ← decHints (y.field 2), safety := ← decSafety w (y.sc8 0), all := ← decNameList (y.field 3) }
  | 2 =>
    let y ← ctor "TheoremVal" w 0 3 0
    let cv ← decConstantVal (y.field 0)
    let value ← if omitProofs then pure omittedProof else decExpr (y.field 1)
    return .thmInfo { toConstantVal := cv, value, all := ← decNameList (y.field 2) }
  | 3 =>
    let y ← ctor "OpaqueVal" w 0 3 1
    return .opaqueInfo {
      toConstantVal := ← decConstantVal (y.field 0), value := ← decExpr (y.field 1),
      isUnsafe := ← decBool "OpaqueVal.isUnsafe" w (y.sc8 0), all := ← decNameList (y.field 2) }
  | 4 =>
    let y ← ctor "QuotVal" w 0 1 1
    return .quotInfo { toConstantVal := ← decConstantVal (y.field 0), kind := ← decQuotKind w (y.sc8 0) }
  | 5 =>
    let y ← ctor "InductiveVal" w 0 6 3
    return .inductInfo {
      toConstantVal := ← decConstantVal (y.field 0), numParams := ← decNat (y.field 1),
      numIndices := ← decNat (y.field 2), all := ← decNameList (y.field 3), ctors := ← decNameList (y.field 4),
      numNested := ← decNat (y.field 5), isRec := ← decBool "InductiveVal.isRec" w (y.sc8 0),
      isUnsafe := ← decBool "InductiveVal.isUnsafe" w (y.sc8 1), isReflexive := ← decBool "InductiveVal.isReflexive" w (y.sc8 2) }
  | 6 =>
    let y ← ctor "ConstructorVal" w 0 5 1
    return .ctorInfo {
      toConstantVal := ← decConstantVal (y.field 0), induct := ← decName (y.field 1),
      cidx := ← decNat (y.field 2), numParams := ← decNat (y.field 3), numFields := ← decNat (y.field 4),
      isUnsafe := ← decBool "ConstructorVal.isUnsafe" w (y.sc8 0) }
  | 7 =>
    let y ← ctor "RecursorVal" w 0 7 2
    return .recInfo {
      toConstantVal := ← decConstantVal (y.field 0), all := ← decNameList (y.field 1),
      numParams := ← decNat (y.field 2), numIndices := ← decNat (y.field 3), numMotives := ← decNat (y.field 4),
      numMinors := ← decNat (y.field 5), rules := ← decList "List RecursorRule" (y.field 6) decRule,
      k := ← decBool "RecursorVal.k" w (y.sc8 0), isUnsafe := ← decBool "RecursorVal.isUnsafe" w (y.sc8 1) }
  | t => fail "ConstantInfo" v s!"unknown tag {t}"

def decImport (v : UInt64) : DM Import := do
  let x ← ctor "Import" v 0 1 3
  return { module := ← decName (x.field 0), importAll := ← decBool "Import.importAll" v (x.sc8 0),
           isExported := ← decBool "Import.isExported" v (x.sc8 1), isMeta := ← decBool "Import.isMeta" v (x.sc8 2) }

/-! Extension entries. Each decoder rebuilds the entry as the running Lean's value of the same
type; `unsafeCast` to `EnvExtensionEntry` is how Lean itself stores them. -/

def decEntry {α} (x : α) : EnvExtensionEntry := unsafe unsafeCast x

def decScopedEntry (what : String) (v : UInt64) (f : UInt64 → DM α) : DM (ScopedEnvExtension.Entry α) := do
  let x ← obj what v
  match x.tag with
  | 0 => let x ← ctor what v 0 1 0; return .global (← f (x.field 0))
  | 1 => let x ← ctor what v 1 2 0; return .scoped (← decName (x.field 0)) (← f (x.field 1))
  | t => fail what v s!"ScopedEnvExtension.Entry tag {t}"

def decStructureFieldInfo (v : UInt64) : DM StructureFieldInfo := do
  let x ← ctor "StructureFieldInfo" v 0 4 1
  return { fieldName := ← decName (x.field 0), projFn := ← decName (x.field 1),
           subobject? := ← decOption "Option Name" (x.field 2) decName,
           binderInfo := ← decBinderInfo v (x.sc8 0), autoParam? := ← decOption "Option Expr" (x.field 3) decExpr }

def decStructureParentInfo (v : UInt64) : DM StructureParentInfo := do
  let x ← ctor "StructureParentInfo" v 0 2 1
  return { structName := ← decName (x.field 0), subobject := ← decBool "StructureParentInfo.subobject" v (x.sc8 0),
           projFn := ← decName (x.field 1) }

def decStructureInfo (v : UInt64) : DM StructureInfo := do
  let x ← ctor "StructureInfo" v 0 4 0
  return { structName := ← decName (x.field 0), fieldNames := ← decArray "Array Name" (x.field 1) decName,
           fieldInfo := ← decArray "Array StructureFieldInfo" (x.field 2) decStructureFieldInfo,
           parentInfo := ← decArray "Array StructureParentInfo" (x.field 3) decStructureParentInfo }

def decPosition (v : UInt64) : DM Position := do
  let x ← ctor "Position" v 0 2 0
  return ⟨← decNat (x.field 0), ← decNat (x.field 1)⟩

def decDeclRange (v : UInt64) : DM DeclarationRange := do
  let x ← ctor "DeclarationRange" v 0 4 0
  return { pos := ← decPosition (x.field 0), charUtf16 := ← decNat (x.field 1),
           endPos := ← decPosition (x.field 2), endCharUtf16 := ← decNat (x.field 3) }

def decDeclRanges (v : UInt64) : DM DeclarationRanges := do
  let x ← ctor "DeclarationRanges" v 0 2 0
  return ⟨← decDeclRange (x.field 0), ← decDeclRange (x.field 1)⟩

def decProjInfo (v : UInt64) : DM ProjectionFunctionInfo := do
  let x ← ctor "ProjectionFunctionInfo" v 0 3 1
  return { ctorName := ← decName (x.field 0), numParams := ← decNat (x.field 1), i := ← decNat (x.field 2),
           fromClass := ← decBool "ProjectionFunctionInfo.fromClass" v (x.sc8 0) }

def decKey (v : UInt64) : DM Meta.DiscrTree.Key := do
  if isScalar v then
    match unbox v with
    | 0 => return .star | 1 => return .other | 5 => return .arrow
    | k => fail "DiscrTree.Key" v s!"scalar {k}"
  let x ← obj "DiscrTree.Key" v
  match x.tag with
  | 2 => let x ← ctor "Key.lit" v 2 1 0; return .lit (← decLiteral (x.field 0))
  | 3 => let x ← ctor "Key.fvar" v 3 2 0; return .fvar ⟨← decName (x.field 0)⟩ (← decNat (x.field 1))
  | 4 => let x ← ctor "Key.const" v 4 2 0; return .const (← decName (x.field 0)) (← decNat (x.field 1))
  | 6 => let x ← ctor "Key.proj" v 6 3 0; return .proj (← decName (x.field 0)) (← decNat (x.field 1)) (← decNat (x.field 2))
  | t => fail "DiscrTree.Key" v s!"tag {t}"

def decAttrKind (addr : UInt64) (b : UInt8) : DM AttributeKind :=
  match b with
  | 0 => pure .global | 1 => pure .local | 2 => pure .scoped
  | _ => fail "AttributeKind" addr s!"value {b}"

def decInstanceEntry (v : UInt64) : DM Meta.InstanceEntry := do
  let x ← ctor "InstanceEntry" v 0 5 1
  return { keys := ← decArray "Array Key" (x.field 0) decKey, val := ← decExpr (x.field 1),
           priority := ← decNat (x.field 2), globalName? := ← decOption "Option Name" (x.field 3) decName,
           synthOrder := ← decNatArray (x.field 4), attrKind := ← decAttrKind v (x.sc8 0) }

def decClassEntry (v : UInt64) : DM ClassEntry := do
  let x ← ctor "ClassEntry" v 0 3 0
  return { name := ← decName (x.field 0), outParams := ← decNatArray (x.field 1),
           outLevelParams := ← decNatArray (x.field 2) }

def decCoeFnInfo (v : UInt64) : DM Meta.CoeFnInfo := do
  let x ← ctor "CoeFnInfo" v 0 2 1
  let type ← match x.sc8 0 with
    | 0 => pure .coe | 1 => pure .coeFun | 2 => pure .coeSort
    | b => fail "CoeFnType" v s!"value {b}"
  return { numArgs := ← decNat (x.field 0), coercee := ← decNat (x.field 1), type }

/-- v4.31.0 and v4.32.0 write 0 reducible, 1 semireducible, 2 irreducible, 3 "unfolded at
.instances or above" (what the `instance` command wrote). From v4.33.0 that meaning is
constructor 4, `instanceReducible`, and 3 means something else (layout log, v4.32.2 -> v4.33.0). -/
def decReducibility (v : UInt64) : DM ReducibilityStatus := do
  unless isScalar v do fail "ReducibilityStatus" v "expected a boxed enum"
  let ver := (← read)[0]!.ver
  match ver.reducibility[unbox v]? with
  | some s => return s
  | none => fail "ReducibilityStatus" v s!"value {unbox v} unknown to v{ver.leanVersion}"

/-- An extension entry with the declaration name it is about (used to regroup entries by module). -/
abbrev Keyed := Name × EnvExtensionEntry

def keyed {α} (k : α → Name) (x : α) : Keyed := (k x, decEntry x)

def scopedKey {α} (k : α → Name) : ScopedEnvExtension.Entry α → Name
  | .global a => k a
  | .scoped _ a => k a

/-! Entry decoders added for the extractor (u12). Each type was diffed between the v4.31.0 and
v4.34.1 sources before its decoder was written; all are layout-identical. -/

def decPairEntry (what : String) (f : UInt64 → DM α) (v : UInt64) : DM Keyed :=
  keyed (·.1) <$> decPair what v decName f

def decTagEntry (v : UInt64) : DM Keyed := keyed id <$> decName v

/-- A boxed enum value below `n`. -/
def decEnum (what : String) (n : Nat) (v : UInt64) : DM Nat := do
  unless isScalar v && unbox v < n do fail what v s!"expected a boxed enum value below {n}"
  return unbox v

def decInlineKind (v : UInt64) : DM Compiler.InlineAttributeKind := do
  match ← decEnum "InlineAttributeKind" 5 v with
  | 0 => return .inline | 1 => return .noinline | 2 => return .macroInline
  | 3 => return .inlineIfReduce | _ => return .alwaysInline

def decExternEntry (v : UInt64) : DM ExternEntry := do
  if isScalar v then
    unless unbox v == 3 do fail "ExternEntry" v s!"scalar {unbox v}"
    return .opaque
  let x ← obj "ExternEntry" v
  match x.tag with
  | 0 => let x ← ctor "ExternEntry.adhoc" v 0 1 0; return .adhoc (← decName (x.field 0))
  | 1 => let x ← ctor "ExternEntry.inline" v 1 2 0; return .inline (← decName (x.field 0)) (← decString (x.field 1))
  | 2 => let x ← ctor "ExternEntry.standard" v 2 2 0; return .standard (← decName (x.field 0)) (← decString (x.field 1))
  | t => fail "ExternEntry" v s!"tag {t}"

/-- `ExternAttrData` has one field and is represented as its `List`. -/
def decExternAttrData (v : UInt64) : DM ExternAttrData :=
  return { entries := ← decList "List ExternEntry" v decExternEntry }

def decOptString (v : UInt64) : DM (Option String) := decOption "Option String" v decString
def decOptName (v : UInt64) : DM (Option Name) := decOption "Option Name" v decName

def decDeprecationEntry (v : UInt64) : DM Linter.DeprecationEntry := do
  let x ← ctor "DeprecationEntry" v 0 3 0
  return { newName? := ← decOptName (x.field 0), text? := ← decOptString (x.field 1),
           since? := ← decOptString (x.field 2) }

def decModuleDoc (v : UInt64) : DM ModuleDoc := do
  let x ← ctor "ModuleDoc" v 0 2 0
  return { doc := ← decString (x.field 0), declarationRange := ← decDeclRange (x.field 1) }

def decAltParamInfo (v : UInt64) : DM Meta.Match.AltParamInfo := do
  let x ← ctor "AltParamInfo" v 0 2 1
  return { numFields := ← decNat (x.field 0), numOverlaps := ← decNat (x.field 1),
           hasUnitThunk := ← decBool "AltParamInfo.hasUnitThunk" v (x.sc8 0) }

/-- `Std.TreeSet Nat` is represented as its `DTreeMap.Internal.Impl Nat (fun _ => Unit)`:
`inner size k v l r` (tag 0) or `leaf` (box 1). The keys are collected in order and inserted
into a set of the running Lean. -/
partial def decTreeSetNatKeys (v : UInt64) (acc : Array Nat) : DM (Array Nat) := do
  if isScalar v then
    unless unbox v == 1 do fail "TreeSet.Impl" v s!"scalar {unbox v}"
    return acc
  let x ← ctor "TreeSet.Impl.inner" v 0 5 0
  let _ ← decNat (x.field 0)
  let k ← decNat (x.field 1)
  unless isScalar (x.field 2) && unbox (x.field 2) == 0 do fail "TreeSet.Impl" v "value is not ()"
  let acc ← decTreeSetNatKeys (x.field 3) acc
  decTreeSetNatKeys (x.field 4) (acc.push k)

def decTreeSetNat (v : UInt64) : DM (Std.TreeSet Nat) := do
  let ks ← decTreeSetNatKeys v #[]
  for i in [1:ks.size] do
    unless ks[i-1]! < ks[i]! do fail "TreeSet Nat" v "keys not strictly increasing"
  return ks.foldl (fun s k => s.insert k) {}

/-- `Overlaps` has one field, a `Std.HashMap Nat (Std.TreeSet Nat)`, represented as its
`DHashMap.Raw`: `size` and an array of association lists (`nil` = box 0, `cons k v tail` = tag 1). -/
partial def decOverlaps (v : UInt64) : DM Meta.Match.Overlaps := do
  let x ← ctor "HashMap.Raw" v 0 2 0
  let size ← decNat (x.field 0)
  let mut pairs : Array (Nat × Std.TreeSet Nat) := #[]
  let bo ← obj "HashMap buckets" (x.field 1)
  unless bo.tag == 246 do fail "HashMap buckets" (x.field 1) "expected an Array"
  let nb := (u64 bo.b (bo.o + 8)).toNat
  for i in [0:nb] do
    let mut cur := u64 bo.b (bo.o + 24 + 8*i)
    while true do
      if isScalar cur then
        unless unbox cur == 0 do fail "AssocList" cur s!"scalar {unbox cur}"
        break
      let c ← ctor "AssocList.cons" cur 1 3 0
      pairs := pairs.push (← decNat (c.field 0), ← decTreeSetNat (c.field 1))
      cur := c.field 2
  unless pairs.size == size do fail "HashMap.Raw" v s!"size {size} but {pairs.size} entries"
  return { map := pairs.foldl (fun m (k, s) => m.insert k s) {} }

def decMatcherInfo (v : UInt64) : DM Meta.Match.MatcherInfo := do
  let x ← ctor "MatcherInfo" v 0 6 0
  return { numParams := ← decNat (x.field 0), numDiscrs := ← decNat (x.field 1),
           altInfos := ← decArray "Array AltParamInfo" (x.field 2) decAltParamInfo,
           uElimPos? := ← decOption "Option Nat" (x.field 3) decNat,
           discrInfos := ← decArray "Array DiscrInfo" (x.field 4) (fun w => do return { hName? := ← decOptName w }),
           overlaps := ← decOverlaps (x.field 5) }

def decMatcherEntry (v : UInt64) : DM Meta.Match.Extension.Entry := do
  let x ← ctor "Match.Extension.Entry" v 0 2 0
  return { name := ← decName (x.field 0), info := ← decMatcherInfo (x.field 1) }

def decNoConfusionInfo (v : UInt64) : DM NoConfusionInfo := do
  let x ← obj "NoConfusionInfo" v
  match x.tag with
  | 0 => let x ← ctor "NoConfusionInfo.regular" v 0 3 0; return .regular (← decNat (x.field 0)) (← decNat (x.field 1)) (← decNat (x.field 2))
  | 1 => let x ← ctor "NoConfusionInfo.perCtor" v 1 2 0; return .perCtor (← decNat (x.field 0)) (← decNat (x.field 1))
  | t => fail "NoConfusionInfo" v s!"tag {t}"

def decFixedParamPerms (v : UInt64) : DM Elab.FixedParamPerms := do
  let x ← ctor "FixedParamPerms" v 0 3 0
  return { numFixed := ← decNat (x.field 0),
           perms := ← decArray "Array FixedParamPerm" (x.field 1) (decArray "FixedParamPerm" · (decOption "Option Nat" · decNat)),
           revDeps := ← decArray "revDeps" (x.field 2) (decArray "revDeps[i]" · (decArray "revDeps[i][j]" · decNat)) }

def decStructuralEqnInfo (v : UInt64) : DM Elab.Structural.EqnInfo := do
  let x ← ctor "Structural.EqnInfo" v 0 7 0
  return { declName := ← decName (x.field 0), levelParams := ← decNameList (x.field 1),
           type := ← decExpr (x.field 2), value := ← decExpr (x.field 3), recArgPos := ← decNat (x.field 4),
           declNames := ← decArray "Array Name" (x.field 5) decName, fixedParamPerms := ← decFixedParamPerms (x.field 6) }

def decWFEqnInfo (v : UInt64) : DM Elab.WF.EqnInfo := do
  let x ← ctor "WF.EqnInfo" v 0 8 0
  return { declName := ← decName (x.field 0), levelParams := ← decNameList (x.field 1),
           type := ← decExpr (x.field 2), value := ← decExpr (x.field 3),
           declNames := ← decArray "Array Name" (x.field 4) decName, declNameNonRec := ← decName (x.field 5),
           argsPacker := { varNamess := ← decArray "varNamess" (x.field 6) (decArray "Array Name" · decName) },
           fixedParamPerms := ← decFixedParamPerms (x.field 7) }

def decPartialFixpointType (v : UInt64) : DM Elab.PartialFixpointType := do
  match ← decEnum "PartialFixpointType" 3 v with
  | 0 => return .partialFixpoint | 1 => return .coinductiveFixpoint | _ => return .inductiveFixpoint

def decPFEqnInfo (v : UInt64) : DM Elab.PartialFixpoint.EqnInfo := do
  let x ← ctor "PartialFixpoint.EqnInfo" v 0 8 0
  return { declName := ← decName (x.field 0), levelParams := ← decNameList (x.field 1),
           type := ← decExpr (x.field 2), value := ← decExpr (x.field 3),
           declNames := ← decArray "Array Name" (x.field 4) decName, declNameNonRec := ← decName (x.field 5),
           fixedParamPerms := ← decFixedParamPerms (x.field 6),
           fixpointType := ← decArray "Array PartialFixpointType" (x.field 7) decPartialFixpointType }

def decSparseCasesOnInfo (v : UInt64) : DM Meta.SparseCasesOnInfo := do
  let x ← ctor "SparseCasesOnInfo" v 0 4 0
  return { indName := ← decName (x.field 0), majorPos := ← decNat (x.field 1), arity := ← decNat (x.field 2),
           insterestingCtors := ← decArray "Array Name" (x.field 3) decName }

def decAuxParentProjInfo (v : UInt64) : DM AuxParentProjectionInfo := do
  let x ← ctor "AuxParentProjectionInfo" v 0 1 1
  return { numParams := ← decNat (x.field 0), fromClass := ← decBool "fromClass" v (x.sc8 0) }

def decConstantKind (v : UInt64) : DM ConstantKind := do
  match ← decEnum "ConstantKind" 8 v with
  | 0 => return .defn | 1 => return .thm | 2 => return .axiom | 3 => return .opaque
  | 4 => return .quot | 5 => return .induct | 6 => return .ctor | _ => return .recursor

def decOrigin (v : UInt64) : DM Meta.Origin := do
  let x ← obj "Origin" v
  match x.tag with
  | 0 => let x ← ctor "Origin.decl" v 0 1 2
         return .decl (← decName (x.field 0)) (← decBool "Origin.post" v (x.sc8 0)) (← decBool "Origin.inv" v (x.sc8 1))
  | 1 => let x ← ctor "Origin.fvar" v 1 1 0; return .fvar ⟨← decName (x.field 0)⟩
  | 2 => let x ← ctor "Origin.stx" v 2 2 0; return .stx (← decName (x.field 0)) (← decSyntax (x.field 1))
  | 3 => let x ← ctor "Origin.other" v 3 1 0; return .other (← decName (x.field 0))
  | t => fail "Origin" v s!"tag {t}"

def decSimpTheorem (v : UInt64) : DM Meta.SimpTheorem := do
  let x ← ctor "SimpTheorem" v 0 5 4
  return { keys := ← decArray "Array Key" (x.field 0) decKey, levelParams := ← decArray "Array Name" (x.field 1) decName,
           proof := ← decExpr (x.field 2), priority := ← decNat (x.field 3), origin := ← decOrigin (x.field 4),
           post := ← decBool "SimpTheorem.post" v (x.sc8 0), perm := ← decBool "SimpTheorem.perm" v (x.sc8 1),
           rfl := ← decBool "SimpTheorem.rfl" v (x.sc8 2), backwardRfl := ← decBool "SimpTheorem.backwardRfl" v (x.sc8 3) }

def decSimpEntry (v : UInt64) : DM Meta.SimpEntry := do
  let x ← obj "SimpEntry" v
  match x.tag with
  | 0 => let x ← ctor "SimpEntry.thm" v 0 1 0; return .thm (← decSimpTheorem (x.field 0))
  | 1 => let x ← ctor "SimpEntry.toUnfold" v 1 1 0; return .toUnfold (← decName (x.field 0))
  | 2 => let x ← ctor "SimpEntry.toUnfoldThms" v 2 2 0
         return .toUnfoldThms (← decName (x.field 0)) (← decArray "Array Name" (x.field 1) decName)
  | t => fail "SimpEntry" v s!"tag {t}"

def simpEntryKey : Meta.SimpEntry → Name
  | .thm t => t.origin.key
  | .toUnfold n => n
  | .toUnfoldThms n _ => n

def decCSimpEntry (v : UInt64) : DM Compiler.CSimp.Entry := do
  let x ← ctor "CSimp.Entry" v 0 3 0
  return { fromDeclName := ← decName (x.field 0), toDeclName := ← decName (x.field 1), thmName := ← decName (x.field 2) }

def decExtTheorem (v : UInt64) : DM Meta.Ext.ExtTheorem := do
  let x ← ctor "ExtTheorem" v 0 3 0
  return { declName := ← decName (x.field 0), priority := ← decNat (x.field 1), keys := ← decArray "Array Key" (x.field 2) decKey }

def decUnifHint (v : UInt64) : DM Meta.UnificationHintEntry := do
  let x ← ctor "UnificationHintEntry" v 0 2 0
  return { keys := ← decArray "Array Key" (x.field 0) decKey, val := ← decName (x.field 1) }

def decDefaultInstance (v : UInt64) : DM Meta.DefaultInstanceEntry := do
  let x ← ctor "DefaultInstanceEntry" v 0 3 0
  return { className := ← decName (x.field 0), instanceName := ← decName (x.field 1), priority := ← decNat (x.field 2) }

def decCongrArgKind (v : UInt64) : DM Meta.CongrArgKind := do
  match ← decEnum "CongrArgKind" 6 v with
  | 0 => return .fixed | 1 => return .fixedNoParam | 2 => return .eq | 3 => return .cast
  | 4 => return .heq | _ => return .subsingletonInst

def decSimpCongrTheorem (v : UInt64) : DM Meta.SimpCongrTheorem := do
  let x ← ctor "SimpCongrTheorem" v 0 4 0
  return { theoremName := ← decName (x.field 0), funName := ← decName (x.field 1),
           hypothesesPos := ← decNatArray (x.field 2), priority := ← decNat (x.field 3) }

def decRecommendedSpelling (v : UInt64) : DM Parser.Term.Doc.RecommendedSpelling := do
  let x ← ctor "RecommendedSpelling" v 0 3 0
  return { «notation» := ← decString (x.field 0), recommendedSpelling := ← decString (x.field 1),
           additionalInformation? := ← decOptString (x.field 2) }

/-- Where the old entries of a decoded extension go in the hybrid.
`byKey`: into the module the hybrid's `const2ModIdx` gives the key, sorted by `Name.quickLt` — the
extension answers a name by binary search in that one module's entries.
`state`: all into one module, in the old version's import order — the extension builds its state
from every module's entries and the order can matter (instance priority ties).
`perModule`: keyed by module, not by name; served from the decoded data per old module and
emptied in the hybrid. -/
inductive Placement where
  | byKey | state | perModule
  /-- Only the key is decoded. Nothing of it enters the hybrid; the keys tell the world which
  names the old version answers from this extension, so a lookup that needs it stops visibly. -/
  | keysOnly
  /-- Looked up by binary search in every module's entries, results concatenated in module
  order (`getTacticExtensions`, `getRecommendedSpellingsForName`): each old module's entries go
  to a module of their own, in the old order. -/
  | allModules
  deriving BEq, Repr

def privName (mod : Name) (n : Name) : Name := Name.mkNum (`_private ++ mod) 0 ++ n

/-- The extensions whose entries the reader decodes, by registered name, with the entry decoder
and the placement of the old entries. Every other extension's entries are counted and not decoded. -/
def entryDecoders : List (Name × (UInt64 → DM Keyed) × Placement) := [
  (Name.mkNum `_private.Lean.Structure 0 ++ `Lean.structureExt,
    fun v => keyed (·.structName) <$> decStructureInfo v, .byKey),
  (`Lean.declRangeExt, decPairEntry "Name × DeclarationRanges" decDeclRanges, .byKey),
  (`Lean.projectionFnInfoExt, decPairEntry "Name × ProjectionFunctionInfo" decProjInfo, .byKey),
  (`Lean.Meta.instanceExtension,
    fun v => keyed (scopedKey (·.globalName?.getD .anonymous)) <$> decScopedEntry "instance entry" v decInstanceEntry, .state),
  (`Lean.classExtension, fun v => keyed (·.name) <$> decClassEntry v, .state),
  (`Lean.Meta.coeExt,
    fun v => keyed (scopedKey (·.1)) <$> decScopedEntry "coe entry" v (decPair "Name × CoeFnInfo" · decName decCoeFnInfo), .state),
  (`Lean.protectedExt, decTagEntry, .byKey),
  (`Lean.aliasExtension, decPairEntry "AliasEntry" decName, .state),
  (`reducibilityCore, decPairEntry "Name × ReducibilityStatus" decReducibility, .byKey),
  (`reducibilityExtra,
    fun v => keyed (scopedKey (·.1)) <$> decScopedEntry "reducibilityExtra entry" v (decPair "Name × ReducibilityStatus" · decName decReducibility), .state),
  (Name.mkNum `_private.Lean.Namespace 0 ++ `Lean.namespacesExt, decTagEntry, .state),
  -- docstrings
  (`Lean.docStringExt, decPairEntry "Name × String" decString, .byKey),
  (privName `Lean.DocString.Extension `Lean.inheritDocStringExt, decPairEntry "Name × Name" decName, .byKey),
  (privName `Lean.DocString.Extension `Lean.moduleDocExt, fun v => keyed (fun _ => .anonymous) <$> decModuleDoc v, .perModule),
  (`Lean.Parser.Term.Doc.recommendedSpellingByNameExt,
    decPairEntry "Name × Array RecommendedSpelling" (decArray "Array RecommendedSpelling" · decRecommendedSpelling), .allModules),
  (`Lean.Parser.Tactic.Doc.tacticAlternativeExt, decPairEntry "Name × Name" decName, .byKey),
  (`Lean.Parser.Tactic.Doc.tacticDocExtExt, decPairEntry "Name × Array String" (decArray "Array String" · decString), .allModules),
  (`Lean.Parser.Tactic.Doc.tacticNameExt, decPairEntry "Name × String" decString, .byKey),
  (`Lean.Parser.Tactic.Doc.tacticTagExt, decPairEntry "Name × Name" decName, .state),
  (`Lean.Parser.Tactic.Doc.knownTacticTagExt,
    decPairEntry "Name × String × Option String" (decPair "String × Option String" · decString decOptString), .byKey),
  -- the blacklist and kinds
  (`Lean.Meta.Match.Extension.extension, fun v => keyed (·.name) <$> decMatcherEntry v, .state),
  (`Lean.auxRecExt, decTagEntry, .byKey),
  (`Lean.noConfusionExt, decPairEntry "Name × NoConfusionInfo" decNoConfusionInfo, .byKey),
  (`recExt, decTagEntry, .byKey),
  (`Lean.Meta.matcherLikeExt, decTagEntry, .byKey),
  (privName `Lean.AuxRecursor `Lean.sparseCasesOnExt, decTagEntry, .byKey),
  (privName `Lean.Meta.Constructions.SparseCasesOn `Lean.Meta.sparseCasesOnInfoExt,
    decPairEntry "Name × SparseCasesOnInfo" decSparseCasesOnInfo, .byKey),
  (`Lean.auxParentProjInfoExt, decPairEntry "Name × AuxParentProjectionInfo" decAuxParentProjInfo, .byKey),
  (privName `Lean.OriginalConstKind `Lean.privateConstKindsExt, decPairEntry "Name × ConstantKind" decConstantKind, .byKey),
  (`Lean.noncomputableExt, decTagEntry, .byKey),
  -- attributes the extractor prints
  (`Lean.Compiler.inlineAttrs, decPairEntry "Name × InlineAttributeKind" decInlineKind, .byKey),
  (`Lean.externAttr, decPairEntry "Name × ExternAttrData" decExternAttrData, .byKey),
  (`Lean.Compiler.implementedByAttr, decPairEntry "Name × Name" decName, .byKey),
  (`Lean.exportAttr, decPairEntry "Name × Name" decName, .byKey),
  (`Lean.Compiler.specializeAttr, decPairEntry "Name × Array Nat" decNatArray, .byKey),
  (`Lean.Linter.deprecatedAttr, decPairEntry "Name × DeprecationEntry" decDeprecationEntry, .byKey),
  (`Lean.IR.UnboxResult.unboxAttr, decTagEntry, .byKey),
  (`Lean.neverExtractAttr, decTagEntry, .byKey),
  (`Lean.Elab.Term.elabWithoutExpectedTypeAttr, decTagEntry, .byKey),
  (`Lean.matchPatternAttr, decTagEntry, .byKey),
  (`Lean.ppNoDotAttr, decTagEntry, .byKey),
  (`Lean.ppUsingAnonymousConstructorAttr, decTagEntry, .byKey),
  (`Lean.Meta.coeDeclAttr, decTagEntry, .byKey),
  (`Lean.Compiler.CSimp.ext,
    fun v => keyed (scopedKey (·.thmName)) <$> decScopedEntry "csimp entry" v decCSimpEntry, .state),
  (`Lean.Meta.simpExtension,
    fun v => keyed (scopedKey simpEntryKey) <$> decScopedEntry "simp entry" v decSimpEntry, .state),
  (`Lean.Meta.defaultInstanceExtension, fun v => keyed (·.instanceName) <$> decDefaultInstance v, .state),
  (`Lean.Meta.Ext.extExtension,
    fun v => keyed (scopedKey (·.declName)) <$> decScopedEntry "ext entry" v decExtTheorem, .state),
  (`Lean.Meta.unificationHintExtension,
    fun v => keyed (scopedKey (·.val)) <$> decScopedEntry "unification hint entry" v decUnifHint, .state),
  -- the sorry pass
  (privName `Lean.Util.CollectAxioms `Lean.exportedAxiomsExt, decPairEntry "Name × Array Name" (decArray "Array Name" · decName), .byKey),
  -- equations
  (`Lean.Meta.eqnOptionsExt,
    decPairEntry "Name × Array (Name × DataValue)" (decArray "Array (Name × DataValue)" · (decPair "Name × DataValue" · decName decDataValue)), .byKey),
  (`Lean.Elab.Structural.eqnInfoExt, decPairEntry "Name × Structural.EqnInfo" decStructuralEqnInfo, .byKey),
  (`Lean.Elab.WF.eqnInfoExt, decPairEntry "Name × WF.EqnInfo" decWFEqnInfo, .byKey),
  (`Lean.Elab.PartialFixpoint.eqnInfoExt, decPairEntry "Name × PartialFixpoint.EqnInfo" decPFEqnInfo, .byKey),
  (`eqnsAttribute, decPairEntry "Name × Array Name" (decArray "Array Name" · decName), .state),
  (`Lean.Meta.congrKindsExt, decPairEntry "Name × Array CongrArgKind" (decArray "Array CongrArgKind" · decCongrArgKind), .byKey),
  (`Lean.Meta.congrExtension,
    fun v => keyed (scopedKey (·.theoremName)) <$> decScopedEntry "simp congr entry" v decSimpCongrTheorem, .state),
  (`Lean.versoDocStringExt, fun v => do
      let x ← ctor "Name × VersoDocString" v 0 2 0
      return (← decName (x.field 0), decEntry ()), .keysOnly)
]

def decoderFor (extName : Name) : Option (UInt64 → DM Keyed) :=
  (entryDecoders.find? (·.1 == extName)).map (·.2.1)

def placementOf (extName : Name) : Option Placement :=
  (entryDecoders.find? (·.1 == extName)).map (·.2.2)

structure ReadStats where
  constants : Nat := 0
  entriesDecoded : Nat := 0
  entriesSkipped : Nat := 0
  skippedExts : Std.HashMap Name Nat := {}
  decodedExts : Std.HashMap Name Nat := {}
  names : Nat := 0
  levels : Nat := 0
  exprs : Nat := 0

/-- Decodes a module's `ModuleData` from the root of its last part, and the decoded entries
with their keys. -/
def decModuleData (omitProofs decodeEntries : Bool) (v : UInt64) (stats : IO.Ref ReadStats) :
    DM (ModuleData × Array (Name × Array Keyed)) := do
  let x ← ctor "ModuleData" v 0 5 1
  let isModule ← decBool "ModuleData.isModule" v (x.sc8 0)
  let imports ← decArray "Array Import" (x.field 0) decImport
  let constNames ← decArray "Array Name" (x.field 1) decName
  let constants ← decArray "Array ConstantInfo" (x.field 2) (decConstantInfo omitProofs)
  let extraConstNames ← decArray "Array Name" (x.field 3) decName
  let entriesObj ← obj "Array (Name × Array EnvExtensionEntry)" (x.field 4)
  unless entriesObj.tag == 246 do fail "ModuleData.entries" (x.field 4) "expected an Array"
  let n := (u64 entriesObj.b (entriesObj.o + 8)).toNat
  let mut keyedEntries := #[]
  for i in [0:n] do
    let pv := u64 entriesObj.b (entriesObj.o + 24 + 8*i)
    let p ← ctor "Name × Array EnvExtensionEntry" pv 0 2 0
    let extName ← decName (p.field 0)
    let ver := (← read)[0]!.ver
    if ver.absentExts.contains extName.toString then
      fail "ModuleData.entries" pv s!"extension {extName} does not exist in v{ver.leanVersion}, yet it has entries"
    let arr ← obj "Array EnvExtensionEntry" (p.field 1)
    unless arr.tag == 246 do fail "entries" (p.field 1) "expected an Array"
    let k := (u64 arr.b (arr.o + 8)).toNat
    match decodeEntries, decoderFor extName with
    | true, some f =>
      let es ← decArray "Array EnvExtensionEntry" (p.field 1) f
      keyedEntries := keyedEntries.push (extName, es)
      stats.modify fun s => { s with
        entriesDecoded := s.entriesDecoded + k
        decodedExts := s.decodedExts.insert extName (s.decodedExts.getD extName 0 + k) }
    | _, _ =>
      stats.modify fun s => { s with
        entriesSkipped := s.entriesSkipped + k
        skippedExts := s.skippedExts.insert extName (s.skippedExts.getD extName 0 + k) }
  let entries := keyedEntries.map fun (e, es) => (e, es.map (·.2))
  unless constNames.size == constants.size do fail "ModuleData" v "constNames and constants differ in size"
  for n in constNames, c in constants do
    unless n == c.name do fail "ModuleData" v s!"constNames[i] = {n} but constants[i].name = {c.name}"
  let st ← get
  stats.modify fun s => { s with
    constants := s.constants + constants.size
    names := s.names + st.names.size
    levels := s.levels + st.levels.size
    exprs := s.exprs + st.exprs.size }
  return ({ isModule, imports, constNames, constants, extraConstNames, entries }, keyedEntries)

/-- Where a module's files are: the first search-path directory holding `<dir>/A/B.olean`. -/
def findOlean (sp : Array System.FilePath) (m : Name) : IO System.FilePath := do
  let rel := System.mkFilePath (m.components.map (·.toString (escape := false)))
  for d in sp do
    let p := (d / rel).addExtension "olean"
    if ← p.pathExists then return p
  throw <| IO.userError s!"olean reader: no .olean for module {m} on the search path"

/-- Loads all parts of a module that exist: `.olean`, then `.olean.server` and `.olean.private`. -/
def loadModule (sp : Array System.FilePath) (m : Name) : IO (Array Part) := do
  let f ← findOlean sp m
  let main ← loadPart f
  let s := f.addExtension "server"
  let p := f.addExtension "private"
  if (← s.pathExists) && (← p.pathExists) then
    return #[main, ← loadPart s, ← loadPart p]
  else if (← s.pathExists) || (← p.pathExists) then
    throw <| IO.userError s!"olean reader: {m} has only one of .olean.server / .olean.private"
  else
    return #[main]

def runDM (parts : Array Part) (x : DM α) : IO (α × DState) :=
  (x.run parts).run {}

/-- `extraConstNames` of a module's `.ir` part: what `finalizeImport` adds to `const2ModIdx` after
the module's constants when the module is a `module` (the `.ir` is its interpreter data). -/
def readIRExtraConstNames (sp : Array System.FilePath) (m : Name) : IO (Array Name) := do
  let irf := (← findOlean sp m).withExtension "ir"
  unless ← irf.pathExists do throw <| IO.userError s!"olean reader: {m} is a module but has no .ir"
  let p ← loadPart irf
  let (ns, _) ← runDM #[p] do
    let x ← ctor "ModuleData" p.root 0 5 1
    decArray "Array Name" (x.field 3) decName
  return ns

/-- The imports of a module, read from its `.olean` alone. -/
def readImports (sp : Array System.FilePath) (m : Name) : IO (Array Import) := do
  let main ← loadPart (← findOlean sp m)
  let (is, _) ← runDM #[main] do
    let x ← ctor "ModuleData" main.root 0 5 1
    decArray "Array Import" (x.field 0) decImport
  return is

/-- The import closure in the order `importModulesCore` visits it (imports before importers). -/
partial def closure (sp : Array System.FilePath) (roots : Array Name) : IO (Array Name) := do
  let seen ← IO.mkRef ({} : NameSet)
  let out ← IO.mkRef (#[] : Array Name)
  let rec go (m : Name) : IO Unit := do
    if (← seen.get).contains m then return
    seen.modify (·.insert m)
    for i in ← readImports sp m do go i.module
    out.modify (·.push m)
  for r in roots do go r
  out.get

end OleanReader
