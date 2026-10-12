import OleanReader.Assemble
open Lean

namespace OleanReader.Axioms

structure Table where
  index : Std.HashMap Name Nat := {}
  names : Array Name := #[]
  lists : Std.HashMap Nat (Array Name) := {}

def Table.bit (t : Table) (ax : Name) : Table × Nat :=
  match t.index[ax]? with
  | some i => (t, 1 <<< i)
  | none => ({ t with index := t.index.insert ax t.names.size, names := t.names.push ax }, 1 <<< t.names.size)

def Table.bits (t : Table) (axs : Array Name) : Table × Nat :=
  axs.foldl (init := (t, 0)) fun (t, b) ax => let (t, x) := t.bit ax; (t, b ||| x)

def Table.list (t : Table) (bits : Nat) : Table × Array Name :=
  match t.lists[bits]? with
  | some l => (t, l)
  | none =>
    let l := ((Array.range t.names.size).filter bits.testBit |>.map (t.names[·]!)).qsort Name.lt
    ({ t with lists := t.lists.insert bits l }, l)

def children (ci : ConstantInfo) : Except String (Array Name) :=
  match ci with
  | .axiomInfo v => pure v.type.getUsedConstants
  | .defnInfo v => pure (v.type.getUsedConstants ++ v.value.getUsedConstants)
  | .thmInfo v =>
    if v.value == omittedProof then
      throw s!"the proof of {v.name} was not decoded, and its axiom list is computed from it"
    else pure (v.type.getUsedConstants ++ v.value.getUsedConstants)
  | .opaqueInfo v => pure (v.type.getUsedConstants ++ v.value.getUsedConstants)
  | .quotInfo _ => pure #[]
  | .ctorInfo v => pure v.type.getUsedConstants
  | .recInfo v => pure v.type.getUsedConstants
  | .inductInfo v => pure (v.type.getUsedConstants ++ v.ctors.toArray)

structure Frame where
  name : Name
  children : Array Name
  next : Nat := 0
  saved : Nat := 0
  deriving Inhabited

inductive Step where
  | merge (bits : Nat)
  | enter (f : Frame) (start : Nat)

structure Walk where
  table : Table
  seen : Std.HashMap Name Nat := {}

def Walk.step (w : Walk) (consts : Name → Option ConstantInfo) (listed : Name → Option Nat) (c : Name) :
    Except String (Walk × Step) := do
  if let some b := listed c then return ({ w with seen := w.seen.insert c b }, .merge b)
  if let some b := w.seen[c]? then return (w, .merge b)
  let w := { w with seen := w.seen.insert c 0 }
  match consts c with
  | none => return (w, .enter { name := c, children := #[] } 0)
  | some ci =>
    let cs ← children ci
    if ci matches .axiomInfo _ then
      let (table, b) := w.table.bit c
      return ({ w with table }, .enter { name := c, children := cs } b)
    return (w, .enter { name := c, children := cs } 0)

-- Not a strongly-connected-component closure: Lean's `collect` marks a constant `#[]` before walking it, so a cycle back to it adds nothing and the stored list depends on the walk's order, which this repeats.
def Walk.collect (w : Walk) (consts : Name → Option ConstantInfo) (listed : Name → Option Nat) (root : Name) :
    Except String (Walk × Nat) := do
  let (w, s) ← w.step consts listed root
  let (f, start) ← match s with
    | .merge b => return (w, b)
    | .enter f start => pure (f, start)
  let mut w := w
  let mut stack := #[f]
  let mut acc := start
  while !stack.isEmpty do
    let top := stack.back!
    if top.next < top.children.size then
      stack := stack.pop.push { top with next := top.next + 1 }
      let (w', s) ← w.step consts listed top.children[top.next]!
      w := w'
      match s with
      | .merge b => acc := acc ||| b
      | .enter g start =>
        stack := stack.push { g with saved := acc }
        acc := start
    else
      stack := stack.pop
      w := { w with seen := w.seen.insert top.name acc }
      acc := top.saved ||| acc
  return (w, w.seen[root]!)

def lists (consts : Name → Option ConstantInfo) (listed : Name → Option Nat) (table : Table)
    (scope : Array Name) : Except String (Table × Array (Name × Nat)) := do
  let mut w : Walk := { table }
  let mut out := #[]
  for n in scope do
    let (w', b) ← w.collect consts listed n
    w := w'
    out := out.push (n, b)
  return (w.table, out)

structure Synthesized where
  table : Table
  perModule : Array (Array (Name × Array Name))
  declarations : Nat
  withSorryAx : Nat
  ms : Nat

def synthesize (d : Assemble.Decoded) : IO Synthesized := do
  let t0 ← IO.monoMsNow
  let mut consts : Std.HashMap Name ConstantInfo := {}
  let mut listed : Std.HashMap Name Nat := {}
  let mut table : Table := {}
  let mut perModule := #[]
  let mut declarations := 0
  let mut withSorryAx := 0
  for (m, md) in d.mods, scope in d.axiomScope do
    for ci in md.constants do
      unless consts.contains ci.name do consts := consts.insert ci.name ci
    let (t, bits) ← match lists (consts[·]?) (listed[·]?) table scope with
      | .ok r => pure r
      | .error why => throw <| IO.userError s!"axiom lists: module {m}: {why}"
    table := t
    let mut out := #[]
    for (n, b) in bits do
      listed := listed.insert n b
      let (t, l) := table.list b
      table := t
      if l.contains ``sorryAx then withSorryAx := withSorryAx + 1
      out := out.push (n, l)
    declarations := declarations + out.size
    perModule := perModule.push out
  return { table, perModule, declarations, withSorryAx, ms := (← IO.monoMsNow) - t0 }

def storedGroup? (d : Assemble.Decoded) : Option (Array (Nat × Keyed)) :=
  (d.keyed.find? fun (e, es) => e == axiomsExtName && !es.isEmpty).map (·.2)

unsafe def storedListUnsafe (e : EnvExtensionEntry) : Name × Array Name := unsafeCast e

@[implemented_by storedListUnsafe]
opaque storedList (e : EnvExtensionEntry) : Name × Array Name

structure Supplied where
  modules : Nat
  storing : Nat
  synthesized : Option Synthesized

def Supplied.line (s : Supplied) : String :=
  match s.synthesized with
  | none =>
    s!"axiom lists          stored by {s.storing} of {s.modules} modules; none synthesized"
  | some y =>
    s!"axiom lists          stored by no module of {s.modules}; synthesized as Lean {Lean.versionString}'s \
      collectAxioms stores them: {y.declarations} declarations in \
      {(y.perModule.filter (!·.isEmpty)).size} modules, {y.table.names.size} distinct axioms, \
      {y.table.lists.size} distinct lists, {y.withSorryAx} holding sorryAx ({y.ms} ms)"

def supply (d : Assemble.Decoded) : IO (Assemble.Decoded × Supplied) := do
  if let some es := storedGroup? d then
    let storing := (es.foldl (fun s (src, _) => s.insert src) ({} : Std.HashSet Nat)).size
    return (d, { modules := d.mods.size, storing, synthesized := none })
  let y ← synthesize d
  let mut es : Array (Nat × Keyed) := #[]
  for i in [0:y.perModule.size] do
    for (n, l) in y.perModule[i]! do es := es.push (i, keyed (fun (p : Name × Array Name) => p.1) (n, l))
  let groups := (d.keyed.filter (·.1 != axiomsExtName)).push (axiomsExtName, es)
  return ({ d with keyed := groups }, { modules := d.mods.size, storing := 0, synthesized := some y })

structure Compared where
  modules : Nat := 0
  storing : Nat := 0
  stored : Nat := 0
  equal : Nat := 0
  differ : Array (Name × Name × Array Name × Array Name) := #[]
  notSynthesized : Array (Name × Name) := #[]
  notStored : Array (Name × Name) := #[]

def compare (d : Assemble.Decoded) (y : Synthesized) : Compared := Id.run do
  let mut stored : Std.HashMap Nat (Std.HashMap Name (Array Name)) := {}
  for (src, k) in (storedGroup? d).getD #[] do
    let (n, l) := storedList k.2
    stored := stored.insert src ((stored.getD src {}).insert n l)
  let mut c : Compared := { modules := d.mods.size, storing := stored.size }
  for i in [0:d.mods.size] do
    let m := d.mods[i]!.1
    let theirs := stored.getD i {}
    let ours := y.perModule[i]!
    c := { c with stored := c.stored + theirs.size }
    let mut oursKeys : NameSet := {}
    for (n, l) in ours do
      oursKeys := oursKeys.insert n
      match theirs[n]? with
      | none => c := { c with notStored := c.notStored.push (m, n) }
      | some s =>
        if s == l then c := { c with equal := c.equal + 1 }
        else c := { c with differ := c.differ.push (m, n, s, l) }
    for (n, _) in theirs do
      unless oursKeys.contains n do c := { c with notSynthesized := c.notSynthesized.push (m, n) }
  return c

def Compared.agrees (c : Compared) : Bool :=
  c.stored > 0 && c.equal == c.stored && c.differ.isEmpty && c.notSynthesized.isEmpty && c.notStored.isEmpty

def Compared.lines (c : Compared) (y : Synthesized) : Array String := Id.run do
  let mut out := #[s!"axioms {c.modules} modules, {c.storing} storing lists; {y.declarations} declarations' lists \
    synthesized with every stored list ignored in {y.ms} ms ({y.table.names.size} distinct axioms); \
    {c.equal} of {c.stored} stored lists equal, {c.differ.size} differ, {c.notSynthesized.size} stored and not \
    synthesized, {c.notStored.size} synthesized and not stored"]
  for (m, n, s, l) in c.differ.extract 0 5 do out := out.push s!"differ {m} {n} stored {s} synthesized {l}"
  for (m, n) in c.notSynthesized.extract 0 5 do out := out.push s!"not-synthesized {m} {n}"
  for (m, n) in c.notStored.extract 0 5 do out := out.push s!"not-stored {m} {n}"
  return out

def ax1 : Name := `ax1
def tT : Name := `T

def cycleConsts : Std.HashMap Name ConstantInfo :=
  let ctor (n : Name) (type : Expr) : ConstantInfo :=
    .ctorInfo { name := n, levelParams := [], type, induct := tT, cidx := 0, numParams := 0, numFields := 0,
                isUnsafe := false }
  Std.HashMap.ofList [
    (ax1, .axiomInfo { name := ax1, levelParams := [], type := .sort 0, isUnsafe := false }),
    (tT, .inductInfo { name := tT, levelParams := [], type := .sort 1, numParams := 0, numIndices := 0,
                       all := [tT], ctors := [`T.a, `T.b], numNested := 0, isRec := false, isUnsafe := false,
                       isReflexive := false }),
    (`T.a, ctor `T.a (.forallE `h (.const ax1 []) (.const tT []) .default)),
    (`T.b, ctor `T.b (.const tT []))]

def cycleLists (scope : Array Name) : Option (Array (Name × Array Name)) :=
  match lists (cycleConsts[·]?) (fun _ => none) {} scope with
  | .ok (t, bits) => some (bits.map fun (n, b) => (n, (t.list b).2))
  | .error _ => none

def axiomListsCutACycleWhereLeansCollectDoes : Bool :=
  cycleLists #[`T.a, tT, `T.b] == some #[(`T.a, #[ax1]), (tT, #[]), (`T.b, #[])]
    && cycleLists #[tT, `T.a, `T.b] == some #[(tT, #[ax1]), (`T.a, #[ax1]), (`T.b, #[])]
    && cycleLists #[`T.b, tT, `T.a] == some #[(`T.b, #[ax1]), (tT, #[ax1]), (`T.a, #[ax1])]

#guard axiomListsCutACycleWhereLeansCollectDoes

end OleanReader.Axioms
