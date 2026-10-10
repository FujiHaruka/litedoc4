import OleanReader.Read
open Lean

namespace OleanReader

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

def decReducibility (v : UInt64) : DM ReducibilityStatus := do
  unless isScalar v do fail "ReducibilityStatus" v "expected a boxed enum"
  let ver := (← read)[0]!.ver
  match ver.reducibility[unbox v]? with
  | some s => return s.meaning
  | none => fail "ReducibilityStatus" v s!"stored value {unbox v} is unknown to the record for Lean {ver.leanVersion}"

abbrev Keyed := Name × EnvExtensionEntry

def keyed {α} (k : α → Name) (x : α) : Keyed := (k x, decEntry x)

def scopedKey {α} (k : α → Name) : ScopedEnvExtension.Entry α → Name
  | .global a => k a
  | .scoped _ a => k a

unsafe def entryKeyUnsafe {α : Type} (k : α → Name) (e : EnvExtensionEntry) : Name := k (unsafeCast e)

@[implemented_by entryKeyUnsafe]
opaque entryKey {α : Type} (k : α → Name) (e : EnvExtensionEntry) : Name

structure ExtDecoder where
  decode : UInt64 → DM Keyed
  keyOf : EnvExtensionEntry → Name

def ExtDecoder.of {α : Type} (k : α → Name) (dec : UInt64 → DM α) : ExtDecoder :=
  { decode := fun v => keyed k <$> dec v, keyOf := entryKey k }

def pairEntry {β : Type} (what : String) (f : UInt64 → DM β) : ExtDecoder :=
  ExtDecoder.of (fun (p : Name × β) => p.1) (decPair what · decName f)

def tagEntry : ExtDecoder := ExtDecoder.of id decName

def scopedEntry {α : Type} (what : String) (k : α → Name) (f : UInt64 → DM α) : ExtDecoder :=
  ExtDecoder.of (scopedKey k) (decScopedEntry what · f)

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

def axiomsExtName : Name := privName `Lean.Util.CollectAxioms `Lean.exportedAxiomsExt

/-- The extensions whose entries the reader decodes, by registered name, with the entry decoder
and the placement of the old entries. Every other extension's entries are counted and not decoded. -/
def entryDecoders : List (Name × ExtDecoder × Placement) := [
  (Name.mkNum `_private.Lean.Structure 0 ++ `Lean.structureExt,
    ExtDecoder.of (·.structName) decStructureInfo, .byKey),
  (`Lean.declRangeExt, pairEntry "Name × DeclarationRanges" decDeclRanges, .byKey),
  (`Lean.projectionFnInfoExt, pairEntry "Name × ProjectionFunctionInfo" decProjInfo, .byKey),
  (`Lean.Meta.instanceExtension,
    scopedEntry "instance entry" (·.globalName?.getD .anonymous) decInstanceEntry, .state),
  (`Lean.classExtension, ExtDecoder.of (·.name) decClassEntry, .state),
  (`Lean.Meta.coeExt,
    scopedEntry "coe entry" (·.1) (decPair "Name × CoeFnInfo" · decName decCoeFnInfo), .state),
  (`Lean.protectedExt, tagEntry, .byKey),
  (`Lean.aliasExtension, pairEntry "AliasEntry" decName, .state),
  (`reducibilityCore, pairEntry "Name × ReducibilityStatus" decReducibility, .byKey),
  (`reducibilityExtra,
    scopedEntry "reducibilityExtra entry" (·.1) (decPair "Name × ReducibilityStatus" · decName decReducibility), .state),
  (Name.mkNum `_private.Lean.Namespace 0 ++ `Lean.namespacesExt, tagEntry, .state),
  (`Lean.docStringExt, pairEntry "Name × String" decString, .byKey),
  (privName `Lean.DocString.Extension `Lean.inheritDocStringExt, pairEntry "Name × Name" decName, .byKey),
  (privName `Lean.DocString.Extension `Lean.moduleDocExt, ExtDecoder.of (fun _ => .anonymous) decModuleDoc, .perModule),
  (`Lean.Parser.Term.Doc.recommendedSpellingByNameExt,
    pairEntry "Name × Array RecommendedSpelling" (decArray "Array RecommendedSpelling" · decRecommendedSpelling), .allModules),
  (`Lean.Parser.Tactic.Doc.tacticAlternativeExt, pairEntry "Name × Name" decName, .byKey),
  (`Lean.Parser.Tactic.Doc.tacticDocExtExt, pairEntry "Name × Array String" (decArray "Array String" · decString), .allModules),
  (`Lean.Parser.Tactic.Doc.tacticNameExt, pairEntry "Name × String" decString, .byKey),
  (`Lean.Parser.Tactic.Doc.tacticTagExt, pairEntry "Name × Name" decName, .state),
  (`Lean.Parser.Tactic.Doc.knownTacticTagExt,
    pairEntry "Name × String × Option String" (decPair "String × Option String" · decString decOptString), .byKey),
  (`Lean.Meta.Match.Extension.extension, ExtDecoder.of (·.name) decMatcherEntry, .state),
  (`Lean.auxRecExt, tagEntry, .byKey),
  (`Lean.noConfusionExt, pairEntry "Name × NoConfusionInfo" decNoConfusionInfo, .byKey),
  (`recExt, tagEntry, .byKey),
  (`Lean.Meta.matcherLikeExt, tagEntry, .byKey),
  (privName `Lean.AuxRecursor `Lean.sparseCasesOnExt, tagEntry, .byKey),
  (privName `Lean.Meta.Constructions.SparseCasesOn `Lean.Meta.sparseCasesOnInfoExt,
    pairEntry "Name × SparseCasesOnInfo" decSparseCasesOnInfo, .byKey),
  (`Lean.auxParentProjInfoExt, pairEntry "Name × AuxParentProjectionInfo" decAuxParentProjInfo, .byKey),
  (privName `Lean.OriginalConstKind `Lean.privateConstKindsExt, pairEntry "Name × ConstantKind" decConstantKind, .byKey),
  (`Lean.noncomputableExt, tagEntry, .byKey),
  (`Lean.Compiler.inlineAttrs, pairEntry "Name × InlineAttributeKind" decInlineKind, .byKey),
  (`Lean.externAttr, pairEntry "Name × ExternAttrData" decExternAttrData, .byKey),
  (`Lean.Compiler.implementedByAttr, pairEntry "Name × Name" decName, .byKey),
  (`Lean.exportAttr, pairEntry "Name × Name" decName, .byKey),
  (`Lean.Compiler.specializeAttr, pairEntry "Name × Array Nat" decNatArray, .byKey),
  (`Lean.Linter.deprecatedAttr, pairEntry "Name × DeprecationEntry" decDeprecationEntry, .byKey),
  (`Lean.IR.UnboxResult.unboxAttr, tagEntry, .byKey),
  (`Lean.neverExtractAttr, tagEntry, .byKey),
  (`Lean.Elab.Term.elabWithoutExpectedTypeAttr, tagEntry, .byKey),
  (`Lean.matchPatternAttr, tagEntry, .byKey),
  (`Lean.ppNoDotAttr, tagEntry, .byKey),
  (`Lean.ppUsingAnonymousConstructorAttr, tagEntry, .byKey),
  (`Lean.Meta.coeDeclAttr, tagEntry, .byKey),
  (`Lean.Compiler.CSimp.ext,
    scopedEntry "csimp entry" (·.thmName) decCSimpEntry, .state),
  (`Lean.Meta.simpExtension,
    scopedEntry "simp entry" simpEntryKey decSimpEntry, .state),
  (`Lean.Meta.defaultInstanceExtension, ExtDecoder.of (·.instanceName) decDefaultInstance, .state),
  (`Lean.Meta.Ext.extExtension,
    scopedEntry "ext entry" (·.declName) decExtTheorem, .state),
  (`Lean.Meta.unificationHintExtension,
    scopedEntry "unification hint entry" (·.val) decUnifHint, .state),
  (axiomsExtName, pairEntry "Name × Array Name" (decArray "Array Name" · decName), .byKey),
  (`Lean.Meta.eqnOptionsExt,
    pairEntry "Name × Array (Name × DataValue)" (decArray "Array (Name × DataValue)" · (decPair "Name × DataValue" · decName decDataValue)), .byKey),
  (`Lean.Elab.Structural.eqnInfoExt, pairEntry "Name × Structural.EqnInfo" decStructuralEqnInfo, .byKey),
  (`Lean.Elab.WF.eqnInfoExt, pairEntry "Name × WF.EqnInfo" decWFEqnInfo, .byKey),
  (`Lean.Elab.PartialFixpoint.eqnInfoExt, pairEntry "Name × PartialFixpoint.EqnInfo" decPFEqnInfo, .byKey),
  (`eqnsAttribute, pairEntry "Name × Array Name" (decArray "Array Name" · decName), .state),
  (`Lean.Meta.congrKindsExt, pairEntry "Name × Array CongrArgKind" (decArray "Array CongrArgKind" · decCongrArgKind), .byKey),
  (`Lean.Meta.congrExtension,
    scopedEntry "simp congr entry" (·.theoremName) decSimpCongrTheorem, .state),
  (`Lean.versoDocStringExt, ExtDecoder.of (fun (p : Name × Unit) => p.1) fun v => do
      let x ← ctor "Name × VersoDocString" v 0 2 0
      return (← decName (x.field 0), ()), .keysOnly)
]

def decoderFor (extName : Name) : Option (UInt64 → DM Keyed) :=
  (entryDecoders.find? (·.1 == extName)).map (·.2.1.decode)

def entryKeyOf (extName : Name) : Option (EnvExtensionEntry → Name) :=
  (entryDecoders.find? (·.1 == extName)).map (·.2.1.keyOf)

def placementOf (extName : Name) : Option Placement :=
  (entryDecoders.find? (·.1 == extName)).map (·.2.2)

end OleanReader
