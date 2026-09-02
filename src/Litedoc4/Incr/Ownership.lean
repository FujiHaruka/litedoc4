/- Which modules point at a name that has moved.

The IR stores every reference as a `(defining module, name)` pair, because the
printed token and the constant it links to often have no textual relation (`ℕ` ->
`Nat`). That pair goes stale when the name moves, even though nothing about the
referring module changed — and no other layer can see it: moving a declaration
from A to X leaves the referring module C's `.olean` **byte identical** (and
Lake's hash unmoved) (measured), so the ledger cannot see it, and widening the
*render* set cannot fix it either, because the stale bytes are in C's IR and C
has to be re-**extracted**. Renaming, by contrast, does change C's olean, because
the new name is embedded in C's terms. -/
import Std.Data.HashMap
import Std.Data.HashSet
import Litedoc4.Duration
import Litedoc4.Fs
import Litedoc4.Ir
import Litedoc4.Ir.Utf16
import Litedoc4.JsonWrite
import Litedoc4.Ledger

open System

namespace Litedoc4

structure Witness where
  module : String
  /-- `ruleLostOwner` or `ruleMovedElsewhere`. -/
  rule : String
  refModule : String
  refName : String
  deriving Inhabited

def ruleLostOwner : String := "lostOwner"

def ruleMovedElsewhere : String := "movedElsewhere"

def witnessesInSummary : Nat := 20

def witnessesInLog : Nat := 10

structure OwnershipInputs where
  /-- The IR as it was before this round. -/
  base : FilePath
  /-- The partial extraction's tree. `none` is a real case, not a misuse: a pure
  deletion re-extracts nothing. -/
  inc : Option FilePath := none
  /-- Modules that no longer exist, one per line. -/
  removed : Option FilePath := none
  /-- Modules already scheduled for re-extraction, one per line. They are fresh
  by definition and are never reported. -/
  exclude : Option FilePath := none
  /-- The stale modules, one per line — the next round's input. -/
  printSet : Option FilePath := none
  json : Option FilePath := none

structure OwnershipSummary where
  incModules : Nat
  removedModules : Nat
  /-- Base modules minus excluded ones, or 0 when nothing was watched.
  **Signed**, because the two counts are not nested: the exclude file may name
  modules the base IR never had, and the negative is reported as it falls out
  rather than clamped away. -/
  scannedBaseModules : Int
  /-- Occurrences, not distinct names: one per (name, module) pair. -/
  lostNames : Nat
  gainedNames : Nat
  lostNamesDistinct : Nat
  gainedNamesDistinct : Nat
  staleByLostOwner : Nat
  staleByMovedElsewhere : Nat
  /-- The union of the two rules, in **UTF-16 order**: the order reaches
  `--print-set`, which the next round re-extracts. -/
  staleModules : Array String
  /-- In scan order, at most one per (module, rule). -/
  witnesses : Array Witness
  diffNanos : Nat
  scanNanos : Nat
  totalNanos : Nat
  deriving Inhabited

def declNameSet (m : Module) : Std.HashSet String := Id.run do
  let mut s : Std.HashSet String := Std.HashSet.emptyWithCapacity (m.decls.size * 2 + 8)
  for d in m.decls do s := s.insert d.name
  return s

private def addOwner (owners : Std.HashMap String (Std.HashSet String)) (name module : String) :
    Std.HashMap String (Std.HashSet String) :=
  owners.insert name ((owners.getD name (Std.HashSet.emptyWithCapacity 2)).insert module)

/-- Diffs the re-extracted modules against the base IR and scans every other
module's references for names that moved. -/
def ownership (i : OwnershipInputs) : IO OwnershipSummary := do
  let started ← IO.monoNanosNow
  let base ← openIrTreeUnvalidated i.base
  let mut baseFileOf : Std.HashMap String IndexEntry :=
    Std.HashMap.emptyWithCapacity (base.index.modules.size * 2)
  for e in base.index.modules do baseFileOf := baseFileOf.insert e.module e
  let inc ← match i.inc with
    | some dir => do let tree ← openIrTreeUnvalidated dir; pure (some tree)
    | none => pure none
  let incEntries := match inc with
    | some tree => tree.index.modules
    | none => #[]
  -- A module the base IR never had cannot have lost anything, so `--removed`
  -- naming one is dropped rather than refused.
  let removedModules ← match i.removed with
    | some path => do pure ((← readModuleList path).filter (baseFileOf.contains ·))
    | none => pure #[]

  let mut lostOwners : Std.HashMap String (Std.HashSet String) :=
    Std.HashMap.emptyWithCapacity 64
  let mut gainedOwners : Std.HashMap String (Std.HashSet String) :=
    Std.HashMap.emptyWithCapacity 64
  let mut lostCount := 0
  let mut gainedCount := 0
  if let some tree := inc then
    for e in incEntries do
      let now := declNameSet (← tree.module e)
      -- A module absent from the base IR is new: nothing can be pointing at it
      -- wrongly yet.
      let was ← match baseFileOf.get? e.module with
        | some entry => do pure (declNameSet (← base.module entry))
        | none => pure (Std.HashSet.emptyWithCapacity 1)
      for name in was.toArray do
        if !now.contains name then
          lostOwners := addOwner lostOwners name e.module
          lostCount := lostCount + 1
      for name in now.toArray do
        if !was.contains name then
          gainedOwners := addOwner gainedOwners name e.module
          gainedCount := gainedCount + 1

  -- A deleted module is one whose whole name set was lost: the same computation
  -- with an empty "gained" side.
  --
  -- Walked as the **array** the file holds, not as a set, so a module that
  -- declared one name twice counts twice in `lostNames`.
  for module in removedModules do
    if let some entry := baseFileOf.get? module then
      for d in (← base.module entry).decls do
        lostOwners := addOwner lostOwners d.name module
        lostCount := lostCount + 1
  let diffDone ← IO.monoNanosNow

  let mut exclude : Std.HashSet String := Std.HashSet.emptyWithCapacity 16
  if let some path := i.exclude then
    for module in ← readModuleList path do exclude := exclude.insert module
  for e in incEntries do exclude := exclude.insert e.module
  -- A removed module must not be reported as needing re-extraction: it is gone.
  for module in removedModules do exclude := exclude.insert module

  let mut staleLost : Array String := #[]
  let mut staleMoved : Array String := #[]
  let mut witnesses : Array Witness := #[]
  -- Nothing moved and nothing was deleted: no module can be pointing anywhere
  -- wrong, so the base IR is not read at all. Dropping this test does not make
  -- the answer wrong, it makes the commonest answer cost a full pass over the
  -- package: 423 module reads against 2 on the measurement target (measured →
  -- `benchmarks/results/purelean-incremental-2026-08-30.txt`).
  let watching := !lostOwners.isEmpty || !gainedOwners.isEmpty
  if watching then
    for e in base.index.modules do
      if exclude.contains e.module then continue
      let m ← base.module e
      let mut hitLost := false
      let mut hitMoved := false
      for d in m.decls do
        for (owner, name) in d.refs do
          if (lostOwners.get? name).any (·.contains owner) then
            if !hitLost then
              hitLost := true
              staleLost := staleLost.push e.module
              witnesses := witnesses.push
                { module := e.module, rule := ruleLostOwner, refModule := owner, refName := name }
          else if (gainedOwners.get? name).any (fun owners => !owners.contains owner) then
            if !hitMoved then
              hitMoved := true
              staleMoved := staleMoved.push e.module
              witnesses := witnesses.push
                { module := e.module, rule := ruleMovedElsewhere, refModule := owner
                  refName := name }
  let scanDone ← IO.monoNanosNow

  let mut union : Array String := staleLost
  for module in staleMoved do
    if !union.contains module then union := union.push module
  let stale := sortUtf16 union

  return { incModules := incEntries.size, removedModules := removedModules.size
           scannedBaseModules :=
             if watching then Int.ofNat base.index.modules.size - Int.ofNat exclude.size else 0
           lostNames := lostCount, gainedNames := gainedCount
           lostNamesDistinct := lostOwners.size, gainedNamesDistinct := gainedOwners.size
           staleByLostOwner := staleLost.size, staleByMovedElsewhere := staleMoved.size
           staleModules := stale, witnesses
           diffNanos := diffDone - started, scanNanos := scanDone - diffDone
           totalNanos := scanDone - started }

/-- `serde_json::to_string_pretty`: two spaces per level, and the field order is
the record's. The three `*Seconds` are diagnostics — wall clock, different every
run, and no comparison may assert on them. -/
def ownershipJson (base inc : String) (s : OwnershipSummary) : String := Id.run do
  let mut o := jsonStr "{\n  \"base\": " base
  o := jsonStr (o ++ ",\n  \"inc\": ") inc
  o := o ++ s!",\n  \"incModules\": {s.incModules}"
  o := o ++ s!",\n  \"removedModules\": {s.removedModules}"
  o := o ++ s!",\n  \"scannedBaseModules\": {s.scannedBaseModules}"
  o := o ++ s!",\n  \"lostNames\": {s.lostNames}"
  o := o ++ s!",\n  \"gainedNames\": {s.gainedNames}"
  o := o ++ s!",\n  \"lostNamesDistinct\": {s.lostNamesDistinct}"
  o := o ++ s!",\n  \"gainedNamesDistinct\": {s.gainedNamesDistinct}"
  o := o ++ s!",\n  \"staleByLostOwner\": {s.staleByLostOwner}"
  o := o ++ s!",\n  \"staleByMovedElsewhere\": {s.staleByMovedElsewhere}"
  o := o ++ s!",\n  \"stale\": {s.staleModules.size}"
  o := o ++ ",\n  \"staleModules\": "
  if s.staleModules.isEmpty then o := o ++ "[]"
  else
    o := o ++ "[\n"
    for k in [0 : s.staleModules.size] do
      o := jsonStr (o ++ "    ") s.staleModules[k]!
      o := o ++ (if k + 1 == s.staleModules.size then "\n" else ",\n")
    o := o ++ "  ]"
  o := o ++ ",\n  \"witnesses\": "
  let shown := s.witnesses.extract 0 witnessesInSummary
  if shown.isEmpty then o := o ++ "[]"
  else
    o := o ++ "[\n"
    for k in [0 : shown.size] do
      let w := shown[k]!
      o := jsonStr (o ++ "    {\n      \"module\": ") w.module
      o := jsonStr (o ++ ",\n      \"rule\": ") w.rule
      o := jsonStr (o ++ ",\n      \"ref\": [\n        ") w.refModule
      o := jsonStr (o ++ ",\n        ") w.refName
      o := o ++ "\n      ]\n    }"
      o := o ++ (if k + 1 == shown.size then "\n" else ",\n")
    o := o ++ "  ]"
  o := o ++ s!",\n  \"diffSeconds\": {seconds s.diffNanos 9}"
  o := o ++ s!",\n  \"scanSeconds\": {seconds s.scanNanos 9}"
  o := o ++ s!",\n  \"totalSeconds\": {seconds s.totalNanos 9}"
  return o ++ "\n}\n"

def runOwnership (i : OwnershipInputs) : IO OwnershipSummary := do
  let summary ← ownership i
  if let some path := i.json then
    -- The empty string, not a null, is what lands in the file when no tree was
    -- given.
    writeFile path (ownershipJson i.base.toString ((i.inc.map (·.toString)).getD "") summary)
  if let some path := i.printSet then writeLines path summary.staleModules
  return summary

end Litedoc4
