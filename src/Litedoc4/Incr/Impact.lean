/- `crates/litedoc4-incr/src/impact.rs`: a changed module set in, the set of
pages that have to be rewritten out.

Two closures, because they answer different questions.

**IMPORTERS(M)** is the reverse *transitive* import closure of `M`, cut down to
the package's own modules. It is the **sound** bound: a module that does not
transitively import `M` cannot observe anything `M` declares — not a constant,
not notation, not an instance. Nothing in Lean reaches further.

**REFERRERS(M)** is the modules with at least one `refs` entry whose defining
module is `M`. It is a *subset* of IMPORTERS(M) — to name `M`'s constant you must
import `M` — and it is the set whose **printed text** mentions something of
`M`'s.

Neither is "the answer" on its own, which is why `--mode` exists and why nothing
here picks a default for the caller.

The pages whose docstring links went stale because a name moved somewhere else
entirely are the other half of the render set, and **this stage never reads that
half**: the caller unions the two *after* both have been computed, which is the
point of deriving them separately.

**When the changed set is empty and `--mode` is not `all`, this stage writes no
`--print-set` at all**, so the caller has to read a missing file as the empty
set. -/
import Std.Data.HashMap
import Std.Data.HashSet
import Litedoc4.Fs
import Litedoc4.Ir
import Litedoc4.Ir.Utf16
import Litedoc4.JsonWrite

open System

namespace Litedoc4

/-- What a refusal from this stage carries: 2 is a caller that asked for
something that does not exist, 3 is the world and the files disagreeing. -/
abbrev ImpactRefusal := UInt32 × String

/-- `unrecognised` is carried rather than refused at parse time, because the mode
is only ever consulted when there is something to select: `--mode nonsense` with
an empty changed set **exits 0 having done nothing**. -/
inductive ImpactMode where
  | selfOnly
  /-- self + REFERRERS, **direct only**. The transitive count is reported beside
  it but is not what this mode selects. -/
  | referrers
  /-- self + IMPORTERS, transitively: the sound bound. -/
  | importers
  /-- Every module of the package, whatever changed — **and valid with an empty
  changed set**. Not a wider closure over the same graph: it is the answer when
  the *renderer's* input moved rather than any module's, so no module IR is stale
  and every page is. -/
  | all
  | unrecognised (text : String)
  deriving Inhabited, BEq

def ImpactMode.parse : String → ImpactMode
  | "self" => .selfOnly
  | "referrers" => .referrers
  | "importers" => .importers
  | "all" => .all
  | other => .unrecognised other

def ImpactMode.name : ImpactMode → String
  | .selfOnly => "self"
  | .referrers => "referrers"
  | .importers => "importers"
  | .all => "all"
  | .unrecognised text => text

structure ImpactInputs where
  /-- Its `index.json` is what defines the package's modules. -/
  ir : FilePath
  /-- The changed modules, **in the order they were given** — the `--changed`
  flags first, then the lines of `--changed-file`. The order reaches the
  summary's `changed` array, and repeats are kept. -/
  changed : Array String := #[]
  mode : ImpactMode := .importers
  /-- A per-module census (TSV). Written whatever the changed set is, and
  **before** the selection. -/
  census : Option FilePath := none
  /-- The selected modules, one name per line — the render set's first half. -/
  printSet : Option FilePath := none
  json : Option FilePath := none

/-- Every number here is a denominator something else gets quoted against, and
none of them is a clock. -/
structure ImpactSummary where
  /-- The argument as it was given, not a resolved path. -/
  ir : String
  changed : Array String
  mode : String
  ownModules : Nat
  /-- Distinct changed modules. -/
  selfModules : Nat
  referrersDirect : Nat
  referrersTransitive : Nat
  importersTransitive : Nat
  /-- In **UTF-16 order**: this list is what `--print-set` writes and what the
  renderer is then asked for. -/
  selected : Array String
  /-- Summed from the **module files**, not from `index.json`'s `declarations`
  column. -/
  selectedDeclarations : Nat
  /-- Summed from `index.json`'s `bytes` column over the selected entries, so a
  repeated index entry counts twice. -/
  selectedIrBytes : Nat
  deriving Inhabited

structure ImpactRun where
  censusModules : Option Nat
  /-- `none` when the changed set was empty and the mode was not `all`: no
  `--print-set` is written at all. -/
  summary : Option ImpactSummary
  deriving Inhabited

/-- Everything reachable from `seeds` along `edges`.

**The seeds are not in the result unless something leads back to them** — the
stack is seeded, the visited set is not — so `importersTransitive` counts *other*
modules and every caller unions the seeds back in itself. On an acyclic import
graph the two spellings differ by exactly the seeds; on a cyclic reference graph
they do not. -/
def reachable (seeds : Array String) (edges : Std.HashMap String (Array String)) :
    Std.HashSet String := Id.run do
  let mut seen : Std.HashSet String := Std.HashSet.emptyWithCapacity 512
  let mut stack := seeds
  while stack.size > 0 do
    let current := stack.back!
    stack := stack.pop
    for next in edges.getD current #[] do
      if !seen.contains next then
        seen := seen.insert next
        stack := stack.push next
  return seen

def censusHeader : String :=
  "module\tdeclarations\tdirectImports\timportedByDirect\timportersTransitive\treferrersDirect"

/-- Every own-package module gets a list, so a module nobody imports is an empty
list rather than an absent key. -/
private def reverseGraph (own : Array String) (forward : Array (String × Array String)) :
    Std.HashMap String (Array String) := Id.run do
  let mut r : Std.HashMap String (Array String) :=
    Std.HashMap.emptyWithCapacity (own.size * 2 + 8)
  for module in own do r := r.insert module #[]
  for (module, targets) in forward do
    for target in targets do
      r := r.insert target ((r.getD target #[]).push module)
  return r

/-- Computes the two closures and selects a module set. -/
def impact (i : ImpactInputs) : IO (Except ImpactRefusal ImpactRun) := do
  let tree ← openIrTreeUnvalidated i.ir
  let entries := tree.index.modules
  let mut own : Std.HashSet String := Std.HashSet.emptyWithCapacity (entries.size * 2 + 8)
  let mut ownList : Array String := Array.mkEmpty entries.size
  for e in entries do
    if !own.contains e.module then
      own := own.insert e.module
      ownList := ownList.push e.module

  -- One pass over the IR: the import edges, the reference edges and the
  -- declaration counts all come out of the same read.
  let mut directImports : Std.HashMap String (Array String) :=
    Std.HashMap.emptyWithCapacity (entries.size * 2 + 8)
  let mut refModules : Std.HashMap String (Array String) :=
    Std.HashMap.emptyWithCapacity (entries.size * 2 + 8)
  let mut declCount : Std.HashMap String Nat :=
    Std.HashMap.emptyWithCapacity (entries.size * 2 + 8)
  for e in entries do
    let m ← tree.module e
    directImports := directImports.insert m.name (m.imports.filter (own.contains ·))
    declCount := declCount.insert m.name m.decls.size
    -- Each named module once, however many declarations name it.
    let mut named : Array String := #[]
    let mut seen : Std.HashSet String := Std.HashSet.emptyWithCapacity 32
    for d in m.decls do
      for (owner, _) in d.refs do
        if own.contains owner && owner != m.name && !seen.contains owner then
          seen := seen.insert owner
          named := named.push owner
    refModules := refModules.insert m.name named

  let importedBy := reverseGraph ownList directImports.toArray
  let referredBy := reverseGraph ownList refModules.toArray

  let mut censusModules : Option Nat := none
  if let some path := i.census then
    let mut rows := censusHeader
    for e in entries do
      let module := e.module
      rows := rows ++ "\n" ++ module
        ++ "\t" ++ toString (declCount.getD module 0)
        ++ "\t" ++ toString (directImports.getD module #[]).size
        ++ "\t" ++ toString (importedBy.getD module #[]).size
        ++ "\t" ++ toString (reachable #[module] importedBy).size
        ++ "\t" ++ toString (referredBy.getD module #[]).size
    writeFile path (rows ++ "\n")
    censusModules := some entries.size

  -- With nothing changed and a mode that is not `all` there is no question.
  if i.changed.isEmpty && i.mode != .all then
    return .ok { censusModules, summary := none }

  for module in i.changed do
    if !own.contains module then
      return .error (3, s!"not a module of this package: {module}")

  let mut selfSet : Std.HashSet String := Std.HashSet.emptyWithCapacity 8
  for module in i.changed do selfSet := selfSet.insert module
  let importers := reachable i.changed importedBy
  -- Transitive over the reference edges: reported, never selected. `--mode
  -- referrers` takes the direct set below, and the gap between the two counts is
  -- the whole reason both are in the summary.
  let referrersTransitive := reachable i.changed referredBy
  let mut referrersDirect : Std.HashSet String := Std.HashSet.emptyWithCapacity 64
  for module in i.changed do
    for referrer in referredBy.getD module #[] do
      referrersDirect := referrersDirect.insert referrer

  let selected : Std.HashSet String ← match i.mode with
    | .selfOnly => pure selfSet
    | .referrers => pure (referrersDirect.insertMany selfSet.toArray)
    | .importers => pure (importers.insertMany selfSet.toArray)
    | .all => pure own
    | .unrecognised text => return .error (2, s!"unknown --mode {text}")

  -- UTF-16 code unit order; this list decides `--print-set`'s.
  let list := sortUtf16 selected.toArray
  let summary : ImpactSummary :=
    { ir := i.ir.toString, changed := i.changed, mode := i.mode.name
      ownModules := own.size, selfModules := selfSet.size
      referrersDirect := referrersDirect.size
      referrersTransitive := referrersTransitive.size
      importersTransitive := importers.size
      selectedDeclarations := list.foldl (fun a m => a + declCount.getD m 0) 0
      selectedIrBytes :=
        entries.foldl (fun a e => if selected.contains e.module then a + e.bytes else a) 0
      selected := list }
  return .ok { censusModules, summary := some summary }

/-- `serde_json::to_string_pretty`: two spaces per level, and the field order is
the record's. -/
def impactJson (s : ImpactSummary) : String := Id.run do
  let mut o := jsonStr "{\n  \"ir\": " s.ir
  o := o ++ ",\n  \"changed\": "
  if s.changed.isEmpty then o := o ++ "[]"
  else
    o := o ++ "[\n"
    for k in [0 : s.changed.size] do
      o := jsonStr (o ++ "    ") s.changed[k]!
      o := o ++ (if k + 1 == s.changed.size then "\n" else ",\n")
    o := o ++ "  ]"
  o := jsonStr (o ++ ",\n  \"mode\": ") s.mode
  o := o ++ s!",\n  \"ownModules\": {s.ownModules}"
  o := o ++ s!",\n  \"self\": {s.selfModules}"
  o := o ++ s!",\n  \"referrersDirect\": {s.referrersDirect}"
  o := o ++ s!",\n  \"referrersTransitive\": {s.referrersTransitive}"
  o := o ++ s!",\n  \"importersTransitive\": {s.importersTransitive}"
  o := o ++ s!",\n  \"selected\": {s.selected.size}"
  o := o ++ s!",\n  \"selectedDeclarations\": {s.selectedDeclarations}"
  o := o ++ s!",\n  \"selectedIrBytes\": {s.selectedIrBytes}"
  return o ++ "\n}"

def runImpact (i : ImpactInputs) : IO (Except ImpactRefusal ImpactRun) := do
  match ← impact i with
  | .error refusal => return .error refusal
  | .ok run =>
    if let some summary := run.summary then
      let body := impactJson summary
      if let some path := i.json then writeFile path (body ++ "\n")
      if let some path := i.printSet then
        -- **Not** `writeLines`: this writes one blank line where that would
        -- write an empty file. Reaching the difference needs an IR with no
        -- modules at all, and `--only-from` drops blank lines, so the two spell
        -- the same set; the bytes here are what the frozen fixtures compare
        -- against.
        writeFile path ("\n".intercalate summary.selected.toList ++ "\n")
    return .ok run

end Litedoc4
