import OleanReader.Writers
open Lean

namespace OleanReader

def headerSize : Nat := 88

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

structure Session where
  searchPath : Array System.FilePath
  firstWriter : IO.Ref (Option (WriterVersion × System.FilePath))

def Session.new (searchPath : Array System.FilePath) : IO Session :=
  return { searchPath, firstWriter := ← IO.mkRef none }

def selectWriter (path : System.FilePath) (lv gh : String) : Except String WriterVersion :=
  match writers.find? (·.leanVersion == lv) with
  | none =>
    .error s!"{path}: written by Lean {lv} ({gh}); this reader has no record for Lean {lv} \
      and reads only {", ".intercalate (writers.map (·.leanVersion))}"
  | some w =>
    if w.githash == gh then .ok w
    else .error s!"{path}: written by Lean {lv} with githash {gh}, but the record for Lean {lv} \
      is for githash {w.githash}; a different build of {lv} is refused"

def loadPart (s : Session) (path : System.FilePath) : IO Part := do
  let bytes ← IO.FS.readBinFile path
  if bytes.size < headerSize + 8 then throw <| IO.userError s!"{path}: shorter than an .olean header"
  unless cstr bytes 0 5 == "olean" do throw <| IO.userError s!"{path}: no olean marker"
  let version := u8 bytes 5
  let flags := u8 bytes 6
  unless version == 2 && flags == 1 do
    throw <| IO.userError s!"{path}: header version {version} flags {flags}, known: 2 / 1"
  let ver ← IO.ofExcept (selectWriter path (cstr bytes 7 33) (cstr bytes 40 40))
  match ← s.firstWriter.get with
  | none => s.firstWriter.set (some (ver, path))
  | some (first, firstPath) =>
    unless first.leanVersion == ver.leanVersion && first.githash == ver.githash do
      throw <| IO.userError s!"{path}: written by Lean {ver.leanVersion} ({ver.githash}), but \
        {firstPath} in the same read was written by Lean {first.leanVersion} ({first.githash}); \
        one read takes one writer"
  return { path, bytes, base := u64 bytes 80, root := u64 bytes headerSize, ver }

structure DState where
  names   : Std.HashMap UInt64 Name := {}
  levels  : Std.HashMap UInt64 Level := {}
  exprs   : Std.HashMap UInt64 Expr := {}
  objects : Nat := 0
  mentioned : Array Name := #[]

abbrev DM := ReaderT (Array Part) (StateRefT DState IO)

def fail (what : String) (addr : UInt64) (msg : String) : DM α := do
  let path := ((← read)[0]?.map (·.path.toString)).getD "<no part>"
  throw <| IO.userError s!"{path}: {what} at 0x{String.ofList (Nat.toDigits 16 addr.toNat)}: {msg}"

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
    | 4, 2 =>
      let n ← decName (x.field 0)
      modify fun s => { s with mentioned := s.mentioned.push n }
      pure (Expr.const n (← decList "List Level" (x.field 1) decLevel))
    | 5, 2 => pure (Expr.app (← decExpr (x.field 0)) (← decExpr (x.field 1)))
    | 6, 3 => pure (Expr.lam (← decName (x.field 0)) (← decExpr (x.field 1)) (← decExpr (x.field 2)) (← decBinderInfo v (x.sc8 8)))
    | 7, 3 => pure (Expr.forallE (← decName (x.field 0)) (← decExpr (x.field 1)) (← decExpr (x.field 2)) (← decBinderInfo v (x.sc8 8)))
    | 8, 4 => pure (Expr.letE (← decName (x.field 0)) (← decExpr (x.field 1)) (← decExpr (x.field 2)) (← decExpr (x.field 3)) (← decBool "Expr.letE.nondep" v (x.sc8 8)))
    | 9, 1 => pure (Expr.lit (← decLiteral (x.field 0)))
    | 10, 2 => pure (Expr.mdata (← decMData (x.field 0)) (← decExpr (x.field 1)))
    | 11, 3 =>
      let n ← decName (x.field 0)
      modify fun s => { s with mentioned := s.mentioned.push n }
      pure (Expr.proj n (← decNat (x.field 1)) (← decExpr (x.field 2)))
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

end OleanReader
