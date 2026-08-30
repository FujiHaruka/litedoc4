/- `crates/litedoc4-global/src/site.rs`: an IR tree in, the whole-package
artifacts out. -/
import Litedoc4.Global.Artifacts

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

/-- `indexMarkdown` and `title` are `litedoc4.toml`'s two keys, resolved by
whoever read the file — `--root` names the package this stage is never told
about, and the index path is relative to it. -/
def buildGlobal (ir out : FilePath) (indexMarkdown : Option String := none)
    (title : Option String := none) : IO GlobalSummary := do
  let tree ← openIrTree ir
  let mut facts : Array ModuleFacts := Array.mkEmpty tree.index.modules.size
  for entry in tree.index.modules do
    facts := facts.push (factsOf (← tree.module entry))
  let depMaps ← tree.loadDepMaps
  let artifacts :=
    derive facts depMaps title (indexMarkdown.map introHtml) tree.index.leanVersion
  for (relative, body) in artifactFiles artifacts do
    let path := irPath out relative
    match path.parent with
    | some dir => IO.FS.createDirAll dir
    | none => pure ()
    IO.FS.writeBinFile path body
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
    cacheMisses := facts.size }

end Litedoc4
