import OleanReader.PrintKey
import OleanReader.Patch
open Lean Litedoc4 Litedoc4.ReuseKey

namespace OleanReader.Carry
open PrintKey

abbrev AliasState := Std.HashMap Name (List (Name × Bool))

def aliasState (env : Environment) : AliasState :=
  (getAliasState env).fold (fun m a ts => m.insert a (ts.map fun t => (t, isProtected env t))) {}

def aliasDelta (prev cur : AliasState) : Std.HashSet Name × Std.HashSet Name := Id.run do
  let mut keys : Std.HashSet Name := {}
  let mut targets : Std.HashSet Name := {}
  for (a, ts) in cur do
    if prev[a]? != some ts then
      keys := keys.insert a
      for (t, _) in ts ++ prev.getD a [] do targets := targets.insert t
  for (a, ts) in prev do
    unless cur.contains a do
      keys := keys.insert a
      for (t, _) in ts do targets := targets.insert t
  return (keys, targets)

def revAliasMap (s : AliasState) : Std.HashMap Name (List Name) :=
  s.fold (fun m a ts => ts.foldl (fun m (t, _) => m.insert t (a :: m.getD t [])) m) {}

structure Delta where
  consts : Std.HashSet Name
  entries : Std.HashSet (Name × Name)
  named : Std.HashSet Name
  aliasKeys : Std.HashSet Name
  aliasTargets : Std.HashSet Name

def Delta.of (pd : Patch.Delta) (aliasKeys aliasTargets : Std.HashSet Name) : Delta :=
  let named := pd.entries.fold (fun s (e, k) => if keyExts.contains e then s.insert k else s) pd.consts
  { consts := pd.consts, entries := pd.entries, named, aliasKeys, aliasTargets }

inductive Atom where
  | const (n : Name)
  | entry (e n : Name)

def Delta.hit? (d : Delta) (r : Reads) : Option Atom :=
  match r.consts.find? d.consts.contains with
  | some n => some (.const n)
  | none => (r.entries.find? d.entries.contains).map fun (e, n) => .entry e n

inductive ResolutionHit where
  | presence (probe name : Name)
  | alias (name : Name)

def resolutionHit? (env : Environment) (revs : Std.HashMap Name (List Name)) (d : Delta) (presence : Bool)
    (ns c : Name) : Option ResolutionHit := Id.run do
  if d.aliasTargets.contains c then return some (.alias c)
  for p in resolutionProbes env (revs.getD c []) ns c do
    if d.aliasKeys.contains p then return some (.alias p)
    if presence then
      let mut q := p
      while !q.isAnonymous do
        if d.named.contains q then return some (.presence p q)
        q := q.getPrefix
  return none

structure State where
  memo : Memo
  decls : Std.HashMap Name KeyOut
  aliases : AliasState

structure Changed where
  recs : Std.HashSet Name := {}
  res : Std.HashSet (Name × Name) := {}
  facts : Std.HashSet Name := {}
  scx : Std.HashSet Name := {}

structure MemoCount where
  entries : Nat := 0
  stale : Nat := 0
  changed : Nat := 0

def MemoCount.text (c : MemoCount) : String := s!"{c.entries}/{c.stale}/{c.changed}"

structure Stats where
  candidates : Nat := 0
  carried : Nat := 0
  stale : Nat := 0
  new : Nat := 0
  recs : MemoCount := {}
  res : MemoCount := {}
  facts : MemoCount := {}
  scx : MemoCount := {}
  deltaConsts : Nat := 0
  deltaEntries : Nat := 0
  aliasKeys : Nat := 0
  ms : Nat := 0
  fromPrevious : Bool := false

def Stats.recomputed (s : Stats) : Nat := s.stale + s.new

def declStale (d : Delta) (ch : Changed) (n : Name) (o : KeyOut) : Bool :=
  d.consts.contains n || (d.hit? o.members).isSome || (d.hit? o.eqns).isSome || ch.recs.contains n ||
    o.shown.any (fun c => ch.facts.contains c || ch.recs.contains c) ||
    (!ch.res.isEmpty && o.spaces.any fun ns => o.shown.any fun c => ch.res.contains (ns, c)) ||
    o.ctorInducts.any fun s => d.entries.contains (extStructure, s) || ch.scx.contains s

unsafe def validate (env : Environment) (d : Delta) (presence : Bool) (m : Memo) : CoreM (Memo × Changed × Stats) := do
  let mut ch : Changed := {}
  let mut st : Stats := {}
  let mut facts := m.facts
  for (c, v) in m.facts do
    unless d.consts.contains c do continue
    st := { st with facts.stale := st.facts.stale + 1 }
    let v' := factsOf env c
    if v' != v then
      ch := { ch with facts := ch.facts.insert c }
      facts := facts.insert c v'
  let mut recs := m.recs
  for (c, (r, rd)) in m.recs do
    if (d.hit? rd).isNone then continue
    st := { st with recs.stale := st.recs.stale + 1 }
    let (r', rd') ← record env c
    recs := recs.insert c (r', rd')
    if r' != r then ch := { ch with recs := ch.recs.insert c }
  let mut scx := m.scx
  for (s, (x, rd)) in m.scx do
    if (d.hit? rd).isNone then continue
    st := { st with scx.stale := st.scx.stale + 1 }
    let (x', rd') := ctorExtra env s
    scx := scx.insert s (x', rd')
    if x' != x then ch := { ch with scx := ch.scx.insert s }
  let revs := revAliasMap (aliasState env)
  let mut res := m.res
  for ((ns, c), x) in m.res do
    if (resolutionHit? env revs d presence ns c).isNone then continue
    st := { st with res.stale := st.res.stale + 1 }
    let x' := resolution env ns c
    if x' != x then
      ch := { ch with res := ch.res.insert (ns, c) }
      res := res.insert (ns, c) x'
  st := { st with
    facts.entries := m.facts.size, facts.changed := ch.facts.size, recs.entries := m.recs.size,
    recs.changed := ch.recs.size, scx.entries := m.scx.size, scx.changed := ch.scx.size,
    res.entries := m.res.size, res.changed := ch.res.size }
  return ({ recs, res, facts, scx }, ch, st)

unsafe def carriedM (env : Environment) (cands : Array Name) (scx : Bool) (prev? : Option (State × Delta))
    (presence : Bool) : CoreM (Std.HashMap Name KeyOut × State × Stats) := do
  let registered ← registeredEqns env
  let (memo, ch, st) ← match prev? with
    | some (s, d) => validate env d presence s.memo
    | none => pure ({}, {}, {})
  let memoRef ← IO.mkRef memo
  let mut st := { st with candidates := cands.size, fromPrevious := prev?.isSome }
  let mut out : Std.HashMap Name KeyOut := Std.HashMap.emptyWithCapacity cands.size
  for c in cands do
    let some ci := env.find? c | continue
    match prev? with
    | some (s, d) =>
      match s.decls[c]? with
      | some o =>
        if declStale d ch c o then
          st := { st with stale := st.stale + 1 }
          out := out.insert c (← keyOf env registered memoRef scx c ci)
        else
          st := { st with carried := st.carried + 1 }
          out := out.insert c o
      | none =>
        st := { st with new := st.new + 1 }
        out := out.insert c (← keyOf env registered memoRef scx c ci)
    | none =>
      st := { st with new := st.new + 1 }
      out := out.insert c (← keyOf env registered memoRef scx c ci)
  return (out, { memo := ← memoRef.get, decls := out, aliases := aliasState env }, st)

unsafe def run (env : Environment) (world : World) (targets : Array Name) (scx : Bool)
    (prev? : Option (State × Patch.Delta)) (presence : Bool) :
    IO (Std.HashMap Name KeyOut × State × Stats × Option Delta) := do
  let t0 ← IO.monoNanosNow
  let cands ← candidates world targets
  let start := prev?.map fun (s, pd) =>
    let (keys, targets) := aliasDelta s.aliases (aliasState env)
    (s, Delta.of pd keys targets)
  let ((out, state, st), _) ← (carriedM env cands scx start presence).toIO coreCtx { env := env }
  let st := match start with
    | some (_, d) => { st with deltaConsts := d.consts.size, deltaEntries := d.entries.size, aliasKeys := d.aliasKeys.size }
    | none => st
  return (out, state, { st with ms := ((← IO.monoNanosNow) - t0) / 1000000 }, start.map (·.2))

def atomText : Atom → String
  | .const n => s!"constant {n}"
  | .entry e n => s!"{e} entry of {n}"

def recordCause (c : Name) : Option Atom → String
  | some (.const n) => if n == c then s!"record-pointer {c}" else s!"ancestor-layout {n} (record of {c})"
  | some (.entry e n) =>
    if n == c then s!"keyed-entry {e} {c}" else s!"ancestor-layout {e} entry of {n} (record of {c})"
  | none => s!"unrecorded (record of {c})"

def scxCause (s : Name) : Option Atom → String
  | some (.const n) => s!"scx-default {n} (structure {s})"
  | some (.entry e n) =>
    if e == extPPAnon then s!"scx-attribute {n}" else s!"scx-ancestors {atomText (.entry e n)} (structure {s})"
  | none => s!"unrecorded (structure-instance defaults of {s})"

unsafe def causes (env : Environment) (d : Delta) (m : Memo) (n : Name) (o : KeyOut) : CoreM (Array String) := do
  let revs := revAliasMap (aliasState env)
  let mut out := #[]
  for ns in o.spaces do
    for c in o.shown do
      let some x := m.res[(ns, c)]? | continue
      if x == resolution env ns c then continue
      out := out.push <| match resolutionHit? env revs d true ns c with
        | some (.presence p q) =>
          if p == q then s!"presence-flip {p} (resolution of {c} in {ns})"
          else s!"presence-flip {q}, a prefix of probe {p} (resolution of {c} in {ns})"
        | some (.alias a) => s!"alias {a} (resolution of {c} in {ns})"
        | none => s!"unrecorded (resolution of {c} in {ns})"
  for c in o.shown.push n do
    let some (r, rd) := m.recs[c]? | continue
    let (r', _) ← record env c
    if r != r' then out := out.push (recordCause c (d.hit? rd))
  for c in o.shown do
    let some v := m.facts[c]? | continue
    if v != factsOf env c then
      out := out.push (if d.consts.contains c then s!"binder-infos {c}" else s!"unrecorded (binder infos of {c})")
  for s in o.ctorInducts do
    let some (x, rd) := m.scx[s]? | continue
    if x != (ctorExtra env s).1 then out := out.push (scxCause s (d.hit? rd))
  if !out.isEmpty then return out
  if d.consts.contains n then out := out.push s!"own-constant {n}"
  if let some a := d.hit? o.members then out := out.push s!"members {atomText a}"
  if let some a := d.hit? o.eqns then out := out.push s!"equations {atomText a}"
  for s in o.ctorInducts do
    if d.entries.contains (extStructure, s) then out := out.push s!"structure-data {s}"
  return if out.isEmpty then #["unrecorded"] else out

structure Difference where
  decl : Name
  parts : Array String
  causes : Array String

def Difference.line (x : Difference) : String :=
  s!"{x.decl}: {"; ".intercalate x.causes.toList}; parts differ: {", ".intercalate x.parts.toList}"

unsafe def compare (env : Environment) (scx : Bool) (d? : Option Delta) (s : State) (carried fresh : Std.HashMap Name KeyOut) :
    IO (Array Difference) := do
  let names := partNames scx
  let mut out := #[]
  for (n, f) in fresh do
    match carried[n]? with
    | none => out := out.push { decl := n, parts := #["the whole key"], causes := #["not in the carried pass"] }
    | some c =>
      if c.key == f.key then continue
      let parts := if c.parts.size != f.parts.size then #["the whole key"] else
        ((c.parts.zip f.parts).zipIdx.filter (fun ((a, b), _) => a != b)).map fun (_, i) => names.getD i s!"part {i}"
      let cs ← match d? with
        | some d => do
          let (cs, _) ← (causes env d s.memo n c).toIO coreCtx { env := env }
          pure cs
        | none => pure #["unrecorded (nothing was carried: the round computed every key)"]
      out := out.push { decl := n, parts, causes := cs }
  for (n, _) in carried do
    unless fresh.contains n do out := out.push { decl := n, parts := #["the whole key"], causes := #["not in the fresh pass"] }
  return out.qsort fun a b => Name.quickLt a.decl b.decl

end OleanReader.Carry
