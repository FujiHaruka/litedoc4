import OleanReader.Assemble
open Lean

namespace OleanReader.Check

structure Dangling where
  module : Name
  constant : Name
  missing : Name

structure ClosureCounts where
  constants : Nat := 0
  references : Nat := 0
  dangling : Array Dangling := #[]
  ms : Nat := 0

def recordNames : ConstantInfo → Array Name
  | .defnInfo v => v.all.toArray
  | .thmInfo v => v.all.toArray
  | .opaqueInfo v => v.all.toArray
  | .inductInfo v => (v.all ++ v.ctors).toArray
  | .ctorInfo v => #[v.induct]
  | .recInfo v => (v.all ++ v.rules.map (·.ctor)).toArray
  | .axiomInfo _ | .quotInfo _ => #[]

def exprRoots : ConstantInfo → Array Expr
  | .defnInfo v => #[v.type, v.value]
  | .thmInfo v => #[v.type, v.value]
  | .opaqueInfo v => #[v.type, v.value]
  | .recInfo v => #[v.type] ++ (v.rules.map (·.rhs)).toArray
  | ci => #[ci.type]

def namesConst (n : Name) : Expr → Bool
  | .const c _ | .proj c _ _ => c == n
  | _ => false

def mentionedBy (n : Name) (ci : ConstantInfo) : Bool :=
  (recordNames ci).contains n || (exprRoots ci).any fun e => (e.find? (namesConst n)).isSome

def closure (d : Assemble.Decoded) : IO ClosureCounts := do
  let t0 ← IO.monoMsNow
  let mut c : ClosureCounts := {}
  for (m, md) in d.mods, mentioned in d.mentioned do
    let mut missing : Array Name := #[]
    for n in mentioned do
      unless d.old.consts.contains n do missing := missing.push n
    for ci in md.constants do
      let records := recordNames ci
      c := { c with references := c.references + records.size }
      for n in records do
        unless d.old.consts.contains n do missing := missing.push n
    for n in missing do
      let constant := (md.constants.find? (mentionedBy n)).map (·.name) |>.getD .anonymous
      c := { c with dangling := c.dangling.push { module := m, constant, missing := n } }
    c := { c with constants := c.constants + md.constants.size, references := c.references + mentioned.size }
  return { c with ms := (← IO.monoMsNow) - t0 }

def ileanFormat : Nat := 5

structure IleanCounts where
  modules : Nat := 0
  bytes : Nat := 0
  compared : Nat := 0
  notListed : Nat := 0
  imported : Nat := 0
  inTheorem : Nat := 0
  problems : Array String := #[]
  ms : Nat := 0

def infoNats (i : Lsp.DeclInfo) : List Nat :=
  [i.rangeStartPosLine, i.rangeStartPosCharacter, i.rangeEndPosLine, i.rangeEndPosCharacter,
   i.selectionRangeStartPosLine, i.selectionRangeStartPosCharacter, i.selectionRangeEndPosLine,
   i.selectionRangeEndPosCharacter]

structure Ilean where
  bytes : Nat
  decls : Array (String × Lsp.DeclInfo)
  parents : Std.HashSet String

def locationParent? (l : Json) : Except String (Option String) := do
  let a ← l.getArr?
  if h : a.size = 5 then return some (← a[4].getStr?) else return none

def parentsOf (refs : Json) : Except String (Std.HashSet String) := do
  (← refs.getObj?).foldlM (init := {}) fun acc _ info => do
    let usages ← (← info.getObjVal? "usages").getArr?
    let locations := match info.getObjValD "definition" with
      | .null => usages
      | defn => usages.push defn
    locations.foldlM (init := acc) fun acc l => do
      return match ← locationParent? l with
        | some p => acc.insert p
        | none => acc

def readIlean (path : System.FilePath) (m : Name) : IO Ilean := do
  unless ← path.pathExists do throw <| IO.userError s!"module {m}: no .ilean beside its .olean ({path})"
  let field {α} (what : String) (r : Except String α) : IO α := IO.ofExcept (r.mapError (s!"{path}: {what}: " ++ ·))
  let text ← IO.FS.readFile path
  let j ← field "JSON" (Json.parse text)
  let fmt ← field "version" (j.getObjValAs? Nat "version")
  unless fmt == ileanFormat do
    throw <| IO.userError s!"{path}: .ilean format {fmt}; every writer this reader has a record for writes {ileanFormat}"
  let mod ← field "module" (j.getObjValAs? String "module")
  unless mod == m.toString do throw <| IO.userError s!"{path}: names module {mod}, read as {m}"
  let decls ← field "decls" (j.getObjValAs? Lsp.Decls "decls")
  let parents ← field "references" (j.getObjVal? "references" >>= parentsOf)
  return { bytes := text.utf8ByteSize
           decls := Id.run do
             let mut out := #[]
             for p in decls do out := out.push p
             return out
           parents }

def atOrBefore (a b : Position) : Bool :=
  a.line < b.line || (a.line == b.line && a.column ≤ b.column)

def rangeContains (outer inner : DeclarationRange) : Bool :=
  atOrBefore outer.pos inner.pos && atOrBefore inner.endPos outer.endPos

def nestedInTheorem (theorems : Std.HashMap Name Name)
    (decoded : Std.HashMap String (Name × DeclarationRanges)) (n : Name) (r : DeclarationRanges) : Bool :=
  match privateToUserName n with
  | .str parent _ =>
    match theorems[parent]? >>= (decoded[·.toString]?) with
    | some (_, pr) => rangeContains pr.range r.range
    | none => false
  | _ => false

unsafe def ilean (s : Session) (d : Assemble.Decoded) : IO IleanCounts := do
  let t0 ← IO.monoMsNow
  let mut byModule : Std.HashMap Nat (Std.HashMap String (Name × DeclarationRanges)) := {}
  let mut anywhere : Std.HashMap String DeclarationRanges := {}
  for (e, es) in d.keyed do
    unless e == `Lean.declRangeExt do continue
    for (src, k) in es do
      let (n, r) : Name × DeclarationRanges := unsafeCast k.2
      byModule := byModule.alter src fun t? => some ((t?.getD {}).insert n.toString (n, r))
      anywhere := anywhere.insert n.toString r
  let mut c : IleanCounts := {}
  for (m, md) in d.mods, i in [0:d.mods.size] do
    let path := (← findOlean s m).withExtension "ilean"
    let file := path.fileName.getD ""
    let il ← readIlean path m
    let decoded := byModule.getD i {}
    let theorems : Std.HashMap Name Name := md.constants.foldl (init := {}) fun t ci =>
      if ci.isTheorem then t.insert (privateToUserName ci.name) ci.name else t
    let mut listed : Std.HashSet String := {}
    for (n, info) in il.decls do
      listed := listed.insert n
      match decoded[n]? with
      | none =>
        match anywhere[n]? with
        | some r =>
          if infoNats (.ofDeclarationRanges r) == infoNats info then
            c := { c with imported := c.imported + 1 }
          else
            let p := s!"module {m}: {n}'s range is {infoNats info} in {file} and \
              {infoNats (.ofDeclarationRanges r)} decoded from the .olean that declares it"
            c := { c with problems := c.problems.push p }
        | none =>
          let p := s!"module {m}: {file} lists {n}, and no .olean of the closure has a declaration range for {n}"
          c := { c with problems := c.problems.push p }
      | some (_, r) =>
        let want := infoNats (.ofDeclarationRanges r)
        if want == infoNats info then
          c := { c with compared := c.compared + 1 }
        else
          let p := s!"module {m}: {n}'s range is {infoNats info} in {file} and {want} decoded from its .olean"
          c := { c with problems := c.problems.push p }
    for (key, n, r) in decoded do
      if listed.contains key then continue
      if il.parents.contains key then
        if nestedInTheorem theorems decoded n r then
          c := { c with inTheorem := c.inTheorem + 1 }
          continue
        let p := s!"module {m}: {file} has references inside {n} and does not list it, but its .olean \
          has a range for it, {infoNats (.ofDeclarationRanges r)}"
        c := { c with problems := c.problems.push p }
      else
        c := { c with notListed := c.notListed + 1 }
    c := { c with modules := c.modules + 1, bytes := c.bytes + il.bytes }
  return { c with ms := (← IO.monoMsNow) - t0 }

end OleanReader.Check
