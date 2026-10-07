import Litedoc4.Build
import Litedoc4.Data.SiteLedger
import Litedoc4.Store
import Litedoc4Sources

open System

namespace Litedoc4
namespace Versions

def toolchainRows (table : String) : Array String :=
  (table.splitOn "\n").toArray.filterMap fun line =>
    match (trimWs line).splitOn " " with
    | first :: _ => if first.isEmpty || first.startsWith "#" then none else some first
    | [] => none

def supportedToolchains : Array String := toolchainRows leanToolchainsTable

def unlistedToolchain (v : Store.VersionName) (commit toolchain : String) (rows : Array String) :
    Option String :=
  if rows.contains toolchain then none
  else some s!"version {v.text} ({commit}) pins `{toolchain}`, which has no row in \
    tools/lean-toolchains.txt — the toolchains this extractor is known to build and run on are \
    {", ".intercalate rows.toList}. A release needs the extractor to build on its Lean and a row \
    for it, and there is no fallback"

def notARepository (root : FilePath) (why : String) : String :=
  s!"--versions reads the versions out of --root's git refs, and {root} is not inside a git \
    repository: {why}"

def unresolvedRef (v : Store.VersionName) (top : FilePath) : String :=
  s!"version {v.text}: `{v.text}` is not a tag, a branch or a commit of {top}"

def noToolchainFile (v : Store.VersionName) (commit path : String) : String :=
  s!"version {v.text} ({commit}) has no {path}: a version is built on the Lean its commit pins, \
    and this one pins none"

def gitAsk (dir : FilePath) (args : Array String) : IO (Except String String) := do
  match ← (IO.Process.output { cmd := "git", args := #["-C", dir.toString] ++ args }).toBaseIO with
  | .error e => return .error s!"git {" ".intercalate args.toList}: {e}"
  | .ok out =>
    if out.exitCode != 0 then return .error (trimWs out.stderr)
    return .ok (trimWs out.stdout)

structure Repository where
  top : FilePath
  packagePrefix : String

def Repository.packageIn (r : Repository) (checkout : FilePath) : FilePath :=
  if r.packagePrefix.isEmpty then checkout else checkout / trimTrailingSlash r.packagePrefix

def repositoryOf (root : FilePath) : IO (Except String Repository) := do
  match ← gitAsk root #["rev-parse", "--show-toplevel"] with
  | .error why => return .error (notARepository root why)
  | .ok top =>
    match ← gitAsk root #["rev-parse", "--show-prefix"] with
    | .error why => return .error (notARepository root why)
    | .ok packagePrefix => return .ok { top := ⟨top⟩, packagePrefix }

structure Planned where
  name : Store.VersionName
  commit : String
  toolchain : String
  deriving BEq, Repr

def plan (repo : Repository) (names : Array Store.VersionName) (rows : Array String) :
    IO (Except String (Array Planned)) := do
  let mut out : Array Planned := #[]
  for v in names do
    let asked ← gitAsk repo.top #["rev-parse", "--verify", "--quiet", s!"{v.text}^\{commit}"]
    let commit ← match asked with
      | .ok commit => if commit.isEmpty then return .error (unresolvedRef v repo.top) else pure commit
      | .error _ => return .error (unresolvedRef v repo.top)
    let path := repo.packagePrefix ++ "lean-toolchain"
    let toolchain ← match ← gitAsk repo.top #["show", s!"{commit}:{path}"] with
      | .ok text => if text.isEmpty then return .error (noToolchainFile v commit path) else pure text
      | .error _ => return .error (noToolchainFile v commit path)
    if let some why := unlistedToolchain v commit toolchain rows then return .error why
    out := out.push { name := v, commit, toolchain }
  return .ok out

inductive Judgement where
  | fresh
  | absent
  | unreadable (why : String)
  | needsReput (why : String)
  | moved (was : String)
  | stale
  deriving BEq, Repr

def Judgement.keeps : Judgement → Bool
  | .fresh => true
  | _ => false

def Judgement.text : Judgement → String
  | .fresh => "fresh"
  | .absent => "not in the store"
  | .unreadable why => s!"unreadable ({why})"
  | .needsReput _ => "needs re-put"
  | .moved was => s!"the store holds it at {was}"
  | .stale => "stale"

def judgeRecord (r : Store.Record) (commit : String) : Option Judgement :=
  match Store.checkoutOf r with
  | .error why => some (.needsReput why)
  | .ok _ => if r.commit != commit then some (.moved r.commit) else none

def judgeIdentity (r : Store.Record) (current : Store.ExtractorIdentity) : Judgement :=
  if Store.stale r current then .stale else .fresh

/-! ## What a versioned build owns under `--out` -/

def checkoutName : String := "checkout"
def scratchName : String := "scratch"
def extractorsName : String := "extractors"
def siteName : String := "site"

def ownedNames : List String :=
  [siteName, renderLedgerName, checkoutName, scratchName, extractorsName]

structure Counted where
  extracted : Array Store.VersionName
  rendered : Array Store.VersionName

def versionsMarkerJson (root store : String) (names : Array Store.VersionName)
    (done : Option Counted) : String := Id.run do
  let strings (o : String) (xs : Array String) : String := Id.run do
    let mut o := o.push '['
    for i in [0:xs.size] do
      if i > 0 then o := o.push ','
      o := jsonStr o xs[i]!
    return o.push ']'
  let mut o := "{\"tool\":\"litedoc4 build\",\"layout\":" ++ toString layoutVersion ++ ",\"root\":"
  o := jsonStr o root
  o := jsonStr (o ++ ",\"store\":") store
  o := strings (o ++ ",\"versions\":") (names.map (·.text))
  let counted (o : String) (vs : Array Store.VersionName) : String :=
    strings (o ++ s!"\{\"count\":{vs.size},\"of\":{names.size},\"names\":") (vs.map (·.text))
      ++ "}"
  o := o ++ ",\"complete\":" ++ (if done.isSome then "true" else "false")
  o := match done with
    | none => o ++ ",\"versionsExtracted\":null,\"versionsRendered\":null"
    | some c =>
      counted (counted (o ++ ",\"versionsExtracted\":") c.extracted ++ ",\"versionsRendered\":")
        c.rendered
  return o ++ "}\n"

def countedLine (what : String) (names done : Array Store.VersionName) : String :=
  s!"versions {what}: {done.size} of {names.size} ({", ".intercalate (done.map (·.text)).toList})"

def extractedLine := countedLine "extracted"

def renderedLine := countedLine "rendered"

-- Not "empty or marked": a restored store or a path dependency's sibling may sit beside these.
def checkOwnership (out root : FilePath) : BuildM Unit := do
  match ← readMarker (out / markerName) with
  | .broken why =>
    throw (3, s!"{out / markerName}: {why}. This file says which directory `litedoc4 build` \
      owns; one that will not parse is not one to replace a site on the strength of")
  | .fields kv =>
    if (orderedGet? kv "versions").isNone then
      throw (3, s!"{out} holds a build of one version: `build --versions` replaces <out>/site with \
        a site of every version, so it will not take over a directory another kind of build \
        wrote. Use a different --out")
    let was := markerString kv "root"
    if was != root.toString then
      throw (3, s!"{out} was built from {was}, not from {root}. Use a different --out")
  | .absent =>
    for name in ownedNames do
      if ← (out / name).pathExists then
        throw (3, s!"{out} has no {markerName} and already holds {out / name}: this command \
          deletes and rewrites {", ".intercalate (ownedNames.map (s!"<out>/{·}"))}, so it does \
          that only where its marker says it wrote them")

/-! ## One version's preparation -/

def toolchainDirName (toolchain : String) : String :=
  toolchain.map fun c => if c.isAlphanum || c == '.' || c == '_' || c == '-' then c else '-'

def sourceDigest (_ : Unit) : String :=
  (sha256Hex extractorSource.toUTF8).take 16 |>.toString

def elanBeside (lake : FilePath) : FilePath :=
  match lake.parent with
  | some dir => if dir.toString.isEmpty then "elan" else dir / "elan"
  | none => "elan"

def spawnInherited (cmd : String) (args : Array String) (cwd : Option FilePath := none)
    (env : Array (String × Option String) := #[]) : BuildM Unit := do
  let spelled := " ".intercalate (cmd :: args.toList)
  let child ← match ← (IO.Process.spawn
      { cmd, args, cwd, env, stdin := .null, stdout := .inherit, stderr := .inherit }).toBaseIO with
    | .error e => throw (1, s!"{spelled}: {e}")
    | .ok child => pure child
  let code ← child.wait
  if code != 0 then
    throw (1, s!"{spelled}{(cwd.map (s!" in {·}")).getD ""} exited {code}")

def installedToolchains (elan : FilePath) : BuildM (Array String) := do
  let out ← match ← (IO.Process.output
      { cmd := elan.toString, args := #["toolchain", "list"] }).toBaseIO with
    | .error e => throw (1, s!"{elan} toolchain list: {e}")
    | .ok out => pure out
  if out.exitCode != 0 then
    throw (1, s!"{elan} toolchain list exited {out.exitCode}: {trimWs out.stderr}")
  return (out.stdout.splitOn "\n").toArray.filterMap fun line =>
    (trimWs line).splitOn " " |>.head?.filter (!·.isEmpty)

def ensureToolchain (elan : FilePath) (toolchain : String) : BuildM Unit := do
  if (← installedToolchains elan).contains toolchain then return
  IO.println s!"toolchain {toolchain}: not installed, installing"
  spawnInherited elan.toString #["toolchain", "install", toolchain]

def extractorDir (cache : FilePath) (toolchain : String) : FilePath :=
  cache / s!"{toolchainDirName toolchain}-{sourceDigest ()}"

def extractorPath (cache : FilePath) (toolchain : String) : FilePath :=
  extractorDir cache toolchain / "extract"

def extractorFor (elan : FilePath) (cache : FilePath) (toolchain : String) : BuildM FilePath := do
  let dir := extractorDir cache toolchain
  let bin := extractorPath cache toolchain
  if ← isRegularFile bin then
    IO.println s!"extractor {toolchain}: {bin} (cached)"
    return bin
  ensureToolchain elan toolchain
  if ← dir.pathExists then IO.FS.removeDirAll dir
  IO.FS.createDirAll dir
  let source := dir / "Extract.lean"
  IO.FS.writeFile source extractorSource
  let started ← IO.monoNanosNow
  spawnInherited elan.toString #["run", toolchain, "lean", s!"--root={dir}",
    "-o", (dir / "Extract.olean").toString, "-c", (dir / "Extract.c").toString, source.toString]
  -- Not without `-rdynamic`: the initializers it runs through the interpreter resolve symbols in it.
  let partial_ := dir / "extract.partial"
  spawnInherited elan.toString #["run", toolchain, "leanc", "-rdynamic", "-o", partial_.toString,
    (dir / "Extract.c").toString]
  IO.FS.rename partial_ bin
  for name in ["Extract.c", "Extract.olean"] do
    if ← (dir / name).pathExists then IO.FS.removeFile (dir / name)
  IO.println s!"extractor {toolchain}: built {bin} in {seconds ((← IO.monoNanosNow) - started) 2} s"
  return bin

def pruneExtractors (cache : FilePath) : IO Unit := do
  if !(← cache.isDir) then return
  let suffix := s!"-{sourceDigest ()}"
  for entry in ← cache.readDir do
    if !entry.fileName.endsWith suffix then IO.FS.removeDirAll entry.path

def removeCheckout (top dir : FilePath) : IO Unit := do
  if ← dir.pathExists then
    discard <| gitAsk top #["worktree", "remove", "--force", dir.toString]
    if ← dir.pathExists then IO.FS.removeDirAll dir
  discard <| gitAsk top #["worktree", "prune"]

def addCheckout (top dir : FilePath) (commit : String) : BuildM Unit := do
  removeCheckout top dir
  match ← gitAsk top #["worktree", "add", "--detach", dir.toString, commit] with
  | .error why => throw (1, s!"git worktree add {dir} {commit} in {top}: {why}")
  | .ok _ => pure ()

def timed (label : String) (act : BuildM α) : BuildM α := do
  let started ← IO.monoNanosNow
  let r ← act
  IO.println s!"phase   {label} {seconds ((← IO.monoNanosNow) - started) 2} s"
  return r

def fetchesMathlibCache (m : Manifest) : Bool :=
  m.name == some "mathlib" || m.packages.any (·.name == "mathlib")

def fetchMathlibCache (lake package cacheDir : FilePath) : BuildM Unit := do
  if ← cacheDir.pathExists then IO.FS.removeDirAll cacheDir
  IO.FS.createDirAll cacheDir
  try
    spawnInherited lake.toString #["exe", "cache", "get"] (some package)
      #[("MATHLIB_CACHE_DIR", some cacheDir.toString)]
  finally
    if ← cacheDir.pathExists then IO.FS.removeDirAll cacheDir

def prepare (repo : Repository) (checkout cacheDir : FilePath) (elan lake : FilePath)
    (libs : Array String) (p : Planned) : BuildM (FilePath × Array String) := do
  let v := p.name.text
  timed s!"{v} checkout" (addCheckout repo.top checkout p.commit)
  timed s!"{v} toolchain" (ensureToolchain elan p.toolchain)
  let package := repo.packageIn checkout
  let libs ← if !libs.isEmpty then pure libs else
    match ← readLibraries package with
    | .error message => throw (3, s!"version {v}: {message}")
    | .ok declared => pure declared.names
  match ← readManifest (package / "lake-manifest.json") with
  | .ok m => if fetchesMathlibCache m then
      timed s!"{v} cache" (fetchMathlibCache lake package cacheDir)
  | .error _ => pure ()
  timed s!"{v} lake" (spawnInherited lake.toString (#["build"] ++ libs) (some package))
  return (package, libs)

/-! ## What a store entry's record reads from a checkout -/

def commitOf (sourceUrl : String) : Option String :=
  match splitOnce sourceUrl "/blob/" with
  | none => none
  | some (_, rest) =>
    let rev := (rest.splitOn "/").headD rest
    if isFortyHex rev then some rev else none

/-- Everything a put records that the IR does not say, read out of the package
at `root`: Lean core's revision, the manifest's dependencies, each dependency
root's version-pinned source, and the site configuration. -/
def originOf (root lake : FilePath) (sources : ExternalLinks) (commit sourceUrl : String) :
    IO (Except String Store.Origin) := do
  let leanGithash ← match ← coreGithash root lake with
    | .error why => return .error why
    | .ok hash => pure hash
  let dependencies ← match ← Store.dependencyRevisions root with
    | .error why => return .error why
    | .ok deps => pure deps
  if let some (core, _) := coreRoots.find? fun (core, _) =>
      !(sources.sourceFor core matches .pinned _) then
    return .error s!"{root}: Lean core's root `{core}` has no version-pinned source URL, so \
      pages rendered from this entry would not link into it"
  let site ← try readSiteSources root catch e => return .error (toString e)
  if let .error why := site.config (bibliographyPath root).toString then return .error why
  return .ok { commit, leanGithash, sourceUrl, dependencies, sources, site }

/-! ## One working tree as one version -/

def unlistedRootToolchain (root : FilePath) (toolchain : String) (rows : Array String) :
    Option String :=
  if rows.contains toolchain then none
  else some s!"{root} pins `{toolchain}`, which has no row in tools/lean-toolchains.txt — the \
    toolchains the extractor this command builds is known to build and run on are \
    {", ".intercalate rows.toList}. Pass --extractor-bin to use an extractor built some other way"

/-- The extractor for the Lean `root` pins, built under `<out>/extractors` the
way `--versions` builds one per toolchain. -/
def extractorForRoot (root out lake : FilePath) : BuildM FilePath := do
  let file := root / "lean-toolchain"
  let toolchain ← match ← (IO.FS.readFile file).toBaseIO with
    | .error _ => throw (3, s!"{root} has no lean-toolchain: the extractor is built on the Lean \
        the package pins, and this one pins none. Pass --extractor-bin")
    | .ok text => pure (trimWs text)
  if let some why := unlistedRootToolchain root toolchain supportedToolchains then throw (3, why)
  let cache := out / extractorsName
  pruneExtractors cache
  extractorFor (elanBeside lake) cache toolchain

structure Built where
  what : String
  version : String
  rendered : Bool
  modulesExtracted : Nat
  extractorRequests : Nat
  nanos : Nat

/-- The working tree at `--root` as one version of a site: its IR brought up to
date in place, put into `<out>/store` under the first 12 hex digits of the commit
its source links name, every other entry removed, and the site rendered from the
store with that version alone.

The put runs on every call, also when nothing was extracted: the site
configuration (title, front page, bibliography) is read into the entry by the
put, and none of it is in the ledger's extraction key. -/
def buildOne (r : BuildRequest) (hashUrls : Bool) : BuildM Built := do
  let store := r.layout.store
  let lake : FilePath := (← envOr r.lake "LAKE").getD ⟨"lake"⟩
  let given ← envOr r.extractorBin "EXTRACT_BIN"
  let bin : BuildM FilePath := match given with
    | some path => pure path
    | none => extractorForRoot r.root r.layout.out lake
  let e ← runExtraction r bin
  let some commit := commitOf e.sourceUrl
    | throw (2, s!"--source-url {e.sourceUrl} names no 40-hex revision after /blob/")
  let version ← match Store.VersionName.parse (commit.take 12).toString with
    | .error why => throw (3, why)
    | .ok v => pure v
  let origin ← match ← originOf r.root lake r.external commit e.sourceUrl with
    | .error why => throw (3, s!"version {version.text}: {why}")
    | .ok origin => pure origin
  IO.FS.createDirAll store
  let putStarted ← IO.monoNanosNow
  let s ← Store.put store version origin r.layout.ir r.layout.linkIndex
  let putNanos := (← IO.monoNanosNow) - putStarted
  IO.println s!"put     {version.text}: {s.record.irFiles} IR file(s) -> {s.record.packBytes} B \
    ({s.record.extractorIdentity.text})"
  for (other, _) in (← Store.list store).entries do
    if other != version then
      Store.remove store other
      IO.println s!"removed {other.text}: a one-version site keeps only {version.text}"
  let extracted := if e.work.modulesExtracted > 0 then #[version] else #[]
  IO.println (extractedLine #[version] extracted)
  let site := r.layout.site
  let renderStarted ← IO.monoNanosNow
  let done ← match ← (Data.SiteLedger.renderSite store site r.layout.renderLedger #[version]
      hashUrls).run with
    | .error why => throw (3, why)
    | .ok done => pure done
  let renderNanos := (← IO.monoNanosNow) - renderStarted
  let counts := done.counts
  IO.println (renderedLine #[version] done.rendered)
  IO.println counts.json
  writeFile r.layout.marker (markerJson r.root.toString e.libs e.sourceUrl e.modules.size
    (some (e.work, { version := version.text, store := store.toString
                     extracted := !extracted.isEmpty })))
  let total := (← IO.monoNanosNow) - e.started
  IO.println s!"build   {e.what} in {seconds total 4} s -> {site}"
  if let some path := r.timings then
    let line := buildRecordJson e.what e.modules.size e.work.modulesExtracted e.rounds e.work
      e.ledgerModules e.ledgerBytes counts.json e.extractNanos putNanos renderNanos total
    writeFile path (line ++ "\n")
    IO.println line
  return { what := e.what, version := version.text, rendered := !done.rendered.isEmpty
           modulesExtracted := e.work.modulesExtracted
           extractorRequests := e.work.extractorRequests, nanos := total }

end Versions
end Litedoc4
