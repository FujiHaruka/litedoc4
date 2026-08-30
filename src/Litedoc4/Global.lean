/- `crates/litedoc4-global/src/site.rs`: an IR tree in, the whole-package
artifacts out. -/
import Litedoc4.Global.Artifacts
import Litedoc4.Global.State

open System

namespace Litedoc4

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

/-- `indexMarkdown` and `title` are `litedoc4.toml`'s two keys, resolved by
whoever read the file — `--root` names the package this stage is never told
about, and the index path is relative to it. -/
def buildGlobal (ir out : FilePath) (state : Option FilePath := none)
    (indexMarkdown : Option String := none)
    (title : Option String := none) : IO GlobalSummary := do
  let tree ← openIrTree ir
  let cached ← State.load state tree.index
  let run ← factsFor tree cached
  let facts := run.facts
  let depMaps ← tree.loadDepMaps
  let artifacts :=
    derive facts depMaps title (indexMarkdown.map introHtml) tree.index.leanVersion
  for (relative, body) in artifactFiles artifacts do
    let path := irPath out relative
    match path.parent with
    | some dir => IO.FS.createDirAll dir
    | none => pure ()
    IO.FS.writeBinFile path body
  let stateBytes ← State.save state tree.index facts
  let counts := artifacts.counts
  return {
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
    stateBytes }

end Litedoc4
