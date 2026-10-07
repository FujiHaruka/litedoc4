import Litedoc4.Build
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

def ownedNames : List String := [siteName, checkoutName, scratchName, extractorsName]

def versionsMarkerJson (root store : String) (names : Array Store.VersionName)
    (extracted : Option (Array Store.VersionName)) : String := Id.run do
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
  o := o ++ ",\"complete\":" ++ (if extracted.isSome then "true" else "false")
  o := o ++ ",\"versionsExtracted\":"
  o := match extracted with
    | none => o ++ "null"
    | some done =>
      strings (o ++ s!"\{\"count\":{done.size},\"of\":{names.size},\"names\":") (done.map (·.text))
        ++ "}"
  return o ++ "}\n"

def extractedLine (names extracted : Array Store.VersionName) : String :=
  s!"versions extracted: {extracted.size} of {names.size} \
    ({", ".intercalate (extracted.map (·.text)).toList})"

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

def spawnInherited (cmd : String) (args : Array String) (cwd : Option FilePath := none) :
    BuildM Unit := do
  let spelled := " ".intercalate (cmd :: args.toList)
  let child ← match ← (IO.Process.spawn
      { cmd, args, cwd, stdin := .null, stdout := .inherit, stderr := .inherit }).toBaseIO with
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

def prepare (repo : Repository) (checkout : FilePath) (elan lake : FilePath) (libs : Array String)
    (p : Planned) : BuildM (FilePath × Array String) := do
  addCheckout repo.top checkout p.commit
  ensureToolchain elan p.toolchain
  let package := repo.packageIn checkout
  let libs ← if !libs.isEmpty then pure libs else
    match ← readLibraries package with
    | .error message => throw (3, s!"version {p.name.text}: {message}")
    | .ok declared => pure declared.names
  spawnInherited lake.toString (#["build"] ++ libs) (some package)
  return (package, libs)

end Versions
end Litedoc4
