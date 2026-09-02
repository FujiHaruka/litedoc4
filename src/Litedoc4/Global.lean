/- An IR tree in, the whole-package artifacts out. -/
import Litedoc4.Global.Artifacts
import Litedoc4.Global.Delta
import Litedoc4.Global.State

open System

namespace Litedoc4

structure GlobalOptions where
  /-- The IR tree: `index.json`, `modules/`, `deps/`. -/
  ir : FilePath
  /-- The site root, next to the module pages. `declarations/` is created under
  it for the name map. -/
  out : FilePath
  /-- Where the `contentHash` cache lives. `none` reads every module, which is
  the from-scratch build. -/
  state : Option FilePath := none
  /-- A previous `name-map.json`. `some` turns the delta on; nothing else does. -/
  before : Option FilePath := none
  /-- The affected modules, one per line, for the incremental pipeline. Ignored
  without `before`. -/
  printSet : Option FilePath := none
  /-- The delta's diagnostic summary. Ignored without `before`. -/
  deltaJson : Option FilePath := none
  /-- One JSON line of counts and durations. What is read back out of it is
  `cacheHits` and `cacheMisses`; the durations are diagnostics. -/
  timings : Option FilePath := none
  /-- `litedoc4.toml`'s two keys, resolved by whoever read the file — `--root`
  names the package this stage is never told about, and the index path is
  relative to it. -/
  indexMarkdown : Option String := none
  title : Option String := none
  deriving Inhabited

structure GlobalSummary where
  modules : Nat := 0
  declarations : Nat := 0
  dependencyNames : Nat := 0
  instanceClasses : Nat := 0
  instanceTypes : Nat := 0
  usedByTargets : Nat := 0
  usedByEdges : Nat := 0
  summariesRendered : Nat := 0
  summariesEchoingTheName : Nat := 0
  tacticDocs : Nat := 0
  nameMapBytes : Nat := 0
  modulesJsonBytes : Nat := 0
  searchIndexBytes : Nat := 0
  cacheHits : Nat := 0
  cacheMisses : Nat := 0
  stateBytes : Nat := 0
  /-- `some` iff `--before` was given. -/
  delta : Option Delta := none
  deriving Inhabited

/-- One `ModuleFacts` per index entry, in index order, and where each came
from. -/
structure FactsRun where
  facts : Array ModuleFacts := #[]
  cacheHits : Nat := 0
  cacheMisses : Nat := 0

/-- Derives the facts of every module of the IR, reading only the modules the
cache cannot answer for.

**The one place a module's IR becomes `ModuleFacts`**, and index order is not
incidental: `derive` resolves a duplicated declaration name in favour of the
later module. The hit test is `cached.contentHash == entry.contentHash` and
nothing else — the hash is the extractor's `String.hash` of the module JSON, so
equal hash is equal bytes is equal facts. -/
def factsFor (tree : IrTree) (cached : State) : IO FactsRun := do
  let mut run : FactsRun := { facts := Array.mkEmpty tree.index.modules.size }
  for entry in tree.index.modules do
    let hit := match cached.modules.get? entry.module with
      | some f => if f.contentHash == entry.contentHash then some f else none
      | none => none
    match hit with
    | some f => run := { run with facts := run.facts.push f, cacheHits := run.cacheHits + 1 }
    | none =>
      let derived := factsOf (← tree.module entry) entry.contentHash
      run := { run with facts := run.facts.push derived, cacheMisses := run.cacheMisses + 1 }
  return run

/-- Fails loudly, unlike `State.load`: `--before` names a file the caller
believes in, and a delta computed against an unreadable map would report every
name in the package as changed. -/
def readNameMap (path : FilePath) : IO (Std.HashMap String String) := do
  let text ← readTextFile path
  let bad (why : String) : IO (Std.HashMap String String) :=
    throw (IO.userError s!"{path}: {why}")
  match parseJson text with
  | .error why => bad why
  | .ok (.obj pairs) => do
    let mut map : Std.HashMap String String := Std.HashMap.emptyWithCapacity (pairs.size * 2 + 8)
    for (name, value) in pairs do
      match value with
      | .str module => map := map.insert name module
      | _ => return ← bad s!"the name map's `{name}` is not a string"
    return map
  | .ok _ => bad "the name map is not a JSON object"

/-- The `global` timing record. The two used-by counts come **after** `delta`
rather than with the counts they belong with, so that everything before them is
still the prototype's key order and two records can be read against each other
key by key. -/
def globalTimingsJson (s : GlobalSummary) (stateOn : Bool)
    (stateLoadNanos readNanos writeNanos deltaNanos stateSaveNanos totalNanos : Nat)
    (diffNanos scanNanos : Nat) : String :=
  let o := "{\"command\":\"build\",\"state\":" ++ (if stateOn then "\"on\"" else "\"off\"")
  let o := o ++ s!",\"cacheHits\":{s.cacheHits},\"cacheMisses\":{s.cacheMisses}"
    ++ s!",\"stateBytes\":{s.stateBytes},\"modules\":{s.modules}"
    ++ s!",\"declarations\":{s.declarations},\"dependencyNames\":{s.dependencyNames}"
    ++ s!",\"instanceClasses\":{s.instanceClasses},\"instanceTypes\":{s.instanceTypes}"
    ++ s!",\"tacticDocs\":{s.tacticDocs},\"nameMapBytes\":{s.nameMapBytes}"
    ++ s!",\"modulesJsonBytes\":{s.modulesJsonBytes}"
    ++ s!",\"searchIndexBytes\":{s.searchIndexBytes}"
    ++ s!",\"stateLoadSeconds\":{seconds stateLoadNanos 9}"
    ++ s!",\"readSeconds\":{seconds readNanos 9}"
    ++ s!",\"writeSeconds\":{seconds writeNanos 9}"
    ++ s!",\"deltaSeconds\":{seconds deltaNanos 9}"
    ++ s!",\"stateSaveSeconds\":{seconds stateSaveNanos 9}"
    ++ s!",\"totalSeconds\":{seconds totalNanos 9},\"delta\":"
  let o := match s.delta with
    | none => o ++ "null"
    | some d =>
      o ++ s!"\{\"changedNames\":{d.changed.size},\"affected\":{d.affected.size}"
        ++ s!",\"diffSeconds\":{seconds diffNanos 9},\"scanSeconds\":{seconds scanNanos 9}}"
  o ++ s!",\"usedByTargets\":{s.usedByTargets},\"usedByEdges\":{s.usedByEdges}" ++ "}\n"

def buildGlobal (o : GlobalOptions) : IO GlobalSummary := do
  let started ← IO.monoNanosNow
  let tree ← openIrTree o.ir
  let cached ← State.load o.state tree.index
  let stateLoaded ← IO.monoNanosNow
  let run ← factsFor tree cached
  let read ← IO.monoNanosNow
  let facts := run.facts
  let depMaps ← tree.loadDepMaps
  let artifacts :=
    derive facts depMaps o.title (o.indexMarkdown.map introHtml) tree.index.leanVersion
  for (relative, body) in artifactFiles artifacts do
    let path := irPath o.out relative
    match path.parent with
    | some dir => IO.FS.createDirAll dir
    | none => pure ()
    IO.FS.writeBinFile path body
  let written ← IO.monoNanosNow
  let mut diffNanos := 0
  let mut scanNanos := 0
  let delta ← match o.before with
    | none => pure none
    | some path => do
      let before ← readNameMap path
      let (changed, diffed) ← timedPure (deltaChanged before artifacts.nameMap)
      let (delta, scanned) ← timedPure (deltaScan before.size artifacts.nameMap.size changed facts)
      diffNanos := diffed - written
      scanNanos := scanned - diffed
      if let some path := o.printSet then writeFile path (deltaPrintSet delta)
      if let some path := o.deltaJson then
        writeFile path (deltaJson delta (diffed - written) (scanned - diffed) (scanned - written))
      pure (some delta)
  let deltaDone ← IO.monoNanosNow
  let stateBytes ← State.save o.state tree.index facts
  let total ← IO.monoNanosNow
  let counts := artifacts.counts
  let summary : GlobalSummary := {
    modules := facts.size
    declarations := counts.declarations
    dependencyNames := counts.dependencyNames
    instanceClasses := counts.instanceClasses
    instanceTypes := counts.instanceTypes
    usedByTargets := counts.usedByTargets
    usedByEdges := counts.usedByEdges
    summariesRendered := counts.summariesRendered
    summariesEchoingTheName := counts.summariesEchoingTheName
    tacticDocs := facts.foldl (fun acc f => acc + f.tactics) 0
    nameMapBytes := artifacts.nameMapJson.utf8ByteSize
    modulesJsonBytes := artifacts.modulesJson.utf8ByteSize
    searchIndexBytes := artifacts.searchIndexBin.size
    cacheHits := run.cacheHits
    cacheMisses := run.cacheMisses
    stateBytes
    delta }
  if let some path := o.timings then
    -- `readSeconds` covers the state load *and* the modules that missed:
    -- together they are what a from-scratch run spends reading all of them.
    writeFile path (globalTimingsJson summary o.state.isSome (stateLoaded - started)
      (read - started) (written - read) (deltaDone - written) (total - deltaDone)
      (total - started) diffNanos scanNanos)
  return summary

end Litedoc4
