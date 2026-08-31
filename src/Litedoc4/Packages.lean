/- `crates/litedoc4/src/packages.rs`: which GitHub blob prefix each dependency's
module root belongs to, offline, from three inputs and no socket — a
dependency's `url` and 40-hex `rev` out of the target's `lake-manifest.json`,
which module roots it provides out of a scan of its directory, and **Lean core's
revision out of `lean --githash`**, because core is not in the manifest.

**Everything degrades; nothing throws.** A missing manifest, a package with no
directory, a `lake` that will not run — each costs the roots it would have
contributed and adds a line to `Packages.problems`. Refusing would trade a site
with some dead links for no site at all.

**A dropped entry still contributes its roots, with an empty base.** Dropping
them would turn a missing link into a dead one: a root the map does not hold is
read by the renderer as *this package's own module*, so every link into that
dependency becomes a relative link to a page this site never writes. -/
import Litedoc4.External
import Litedoc4.Ir.Utf16
import Litedoc4.Json

open System

namespace Litedoc4

/-- Core has no manifest entry — it is the toolchain — so this is the one URL in
the product that is written down rather than read. -/
def coreUrl : String := "https://github.com/leanprover/lean4"

/-- **`Lake` is not under `src/` with the other three**, and sharing one base
would 404 every Lake link. -/
def coreRoots : Array (String × String) :=
  #[("Init", "src"), ("Lean", "src"), ("Std", "src"), ("Lake", "src/lake")]

def defaultPackagesDir : String := ".lake/packages"

/-- 40 lower-case hex digits. `A`-`F` is rejected: the same string reaches
`renderKey.externalLinks`, and two spellings of one revision are two keys. -/
def isFortyHex (s : String) : Bool := Id.run do
  if s.utf8ByteSize != 40 then return false
  let mut i := 0
  while i < 40 do
    let c := byteAt s i
    if !((c ≥ 48 && c ≤ 57) || (c ≥ 97 && c ≤ 102)) then return false
    i := i + 1
  return true

structure PackageEntry where
  /-- Unquoted, so it is also the directory name under `packagesDir`. -/
  name : String := ""
  /-- `<url>/blob/<rev>`, or **empty** when the entry carries no version-pinned
  URL. The empty string reaches `ExternalLinks` as-is. -/
  blobBase : String := ""
  /-- Where the sources are, relative to the target root, for the entries that
  say so themselves. `none` is `<packagesDir>/<name>`. -/
  dir : Option String := none
  deriving Inhabited

structure Manifest where
  packagesDir : String := defaultPackagesDir
  listed : Nat := 0
  packages : Array PackageEntry := #[]
  problems : Array String := #[]
  deriving Inhabited

structure Packages where
  links : ExternalLinks := {}
  /-- Manifest entries that contributed at least one root **with a URL**. -/
  resolved : Nat := 0
  /-- Roots carried with an empty base: known to belong to a dependency, with no
  version-pinned URL to link them at. Counted apart from `resolved` because it is
  the opposite answer — these are the roots whose links the pages *lose*. -/
  unpinnedRoots : Nat := 0
  declared : Nat := 0
  problems : Array String := #[]
  /-- Kept apart from `problems` because nothing failed to resolve: the map holds
  the root, it just holds one of the two candidates. -/
  collisions : Array String := #[]
  deriving Inhabited

def jField (v : JVal) (key : String) : Option JVal := Id.run do
  for (k, x) in asObj v do
    if k == key then return some x
  return none

def jStrField (v : JVal) (key : String) : Option String :=
  match jField v key with
  | some (.str s) => some s
  | _ => none

def stripDotGit (url : String) : String :=
  let url := trimTrailingSlash url
  if url.endsWith ".git" then byteSub url 0 (url.utf8ByteSize - 4) else url

/-- `Err` is only for the file: unreadable, not JSON, no `packages` array. **A
bad *entry* costs that entry and nothing else** — one dependency pinned to a
branch must not take the others' links with it. -/
def parseManifest (path : FilePath) (text : String) : Except String Manifest := Id.run do
  let value ← match parseJson text with
    | .error why => return .error s!"{path}: {why}"
    | .ok (.obj kv) => pure (JVal.obj kv)
    | .ok _ => return .error s!"{path}: not a JSON object"
  let packagesDir := (jStrField value "packagesDir").getD defaultPackagesDir
  let some (.arr listed) := jField value "packages"
    | return .error s!"{path}: no `packages` array"
  let mut packages : Array PackageEntry := Array.mkEmpty listed.size
  let mut problems : Array String := #[]
  for i in [0:listed.size] do
    let entry := listed[i]!
    match jStrField entry "name" with
    | none =>
      -- The index, not just the name: an entry with no `name` has nothing else
      -- to be called in a message.
      problems := problems.push s!"{path}: packages[{i}] has no `name`"
    | some raw =>
      let name := unescapeComponent raw
      let kind := (jStrField entry "type").getD ""
      if kind != "git" then
        problems := problems.push s!"{path}: package `{name}` is type `{kind}`, not `git` — \
          only a git package has a /blob/<rev> to link into"
        if kind == "path" then
          -- Lake did not fetch this one, so `<packagesDir>/<name>` is not where
          -- it is. Without a `dir` there is nothing to scan, and the entry
          -- really is dropped.
          match jStrField entry "dir" with
          | some dir => packages := packages.push { name, dir := some dir }
          | none => pure ()
        else
          packages := packages.push { name }
      else
        match jStrField entry "url", jStrField entry "rev" with
        | some url, some rev =>
          if isFortyHex rev then
            packages := packages.push { name, blobBase := s!"{stripDotGit url}/blob/{rev}" }
          else
            problems := problems.push s!"{path}: package `{name}` is pinned at `{rev}`, which \
              is not 40 hex digits — a tag or a branch is not a version-pinned link"
            packages := packages.push { name }
        | _, _ =>
          problems := problems.push s!"{path}: package `{name}` has no `url` or no `rev`"
          packages := packages.push { name }
  return .ok { packagesDir, listed := listed.size, packages, problems }

def readManifest (path : FilePath) : IO (Except String Manifest) := do
  let read ← try
      Except.ok <$> IO.FS.readFile path
    catch e =>
      pure (.error s!"{path}: {e}. Without it no dependency's revision is known and the pages \
        carry no external links")
  match read with
  | .error problem => return .error problem
  | .ok text => return parseManifest path text

/-- The stem of every top-level `*.lean` file, sorted so that two machines
resolve the same map. `lakefile` is dropped by name: it is Lake's configuration,
never a module anything imports, and enough packages have one that keeping it
would report root collisions that mean nothing. -/
def moduleRoots (dir : FilePath) : IO (Except String (Array String)) := do
  let read ← try
      Except.ok <$> dir.readDir
    catch e =>
      pure (.error s!"{dir}: {e}. The package is in the manifest but not on disk, so which \
        module roots it provides cannot be known")
  match read with
  | .error problem => return .error problem
  | .ok entries =>
    let mut roots : Array String := #[]
    for entry in entries do
      let path := entry.path
      if path.extension != some "lean" then continue
      -- A broken symlink is neither a file nor a directory, and a root that
      -- cannot be read is not a root.
      if !(← path.pathExists) then continue
      if ← path.isDir then continue
      let some stem := path.fileStem | continue
      if stem == "lakefile" then continue
      roots := roots.push stem
    return .ok (roots.qsort byteLt)

/-- The `lean` that answers for a given `lake`: its sibling, whether `lake`
arrived as a path or as a bare word to be found on `PATH`. **Sibling and not
`PATH`**: with elan both are shims in one directory, but a caller who names a
toolchain-local `lake` means that toolchain's `lean`, and the first `lean` on
`PATH` could be another one entirely. -/
def leanBeside (lake : FilePath) : FilePath :=
  match lake.parent with
  | some dir => if dir.toString.isEmpty then "lean" else dir / "lean"
  | none => "lean"

/-- **Not `lake env lean --githash`**, which costs 0.763 s of a 5.33 s one-module
incremental (measured 2026-08-17 →
`benchmarks/results/g3-attribution-2026-08-17.txt`). Nearly all of it is Lake's
own start-up, and `--githash` needs none of what Lake sets. The two were measured
to agree on both targets, byte for byte.

**Only stdout is read.** Warnings go to stderr — the measurement target prints
one about a dependency with local changes — and folding those into the answer
would produce a revision that is not one. -/
def coreGithash (root lake : FilePath) : IO (Except String String) := do
  let lean := leanBeside lake
  let run ← try
      Except.ok <$> IO.Process.output { cmd := lean.toString, args := #["--githash"], cwd := root }
    catch e =>
      pure (.error s!"{lean} --githash in {root}: {e}. Lean core's revision is unknown, so \
        Init/Lean/Std/Lake carry no external links")
  match run with
  | .error problem => return .error problem
  | .ok output =>
    if output.exitCode != 0 then
      return .error s!"{lean} --githash in {root} failed: {trimWs output.stderr}"
    let hash := trimWs output.stdout
    if !isFortyHex hash then
      return .error s!"{lean} --githash printed `{hash}`, which is not 40 hex digits — a \
        toolchain built without a git revision cannot be linked to"
    return .ok hash

def claimedBase (entries : Array (String × String)) (name : String) : Option String := Id.run do
  for (seen, base) in entries do
    if seen == name then return some base
  return none

def collisionLine (name owner base : String) : String :=
  let claimant := if base.isEmpty then "a package with no version-pinned URL" else base
  s!"module root `{name}` is claimed by package `{owner}` and by {claimant} — keeping the first"

/-- One manifest entry, the directory its sources were looked for in, and what
the scan of that directory said. -/
structure ScannedPackage where
  entry : PackageEntry
  dir : FilePath
  roots : Except String (Array String)
  deriving Inhabited

/-- The whole of the map's shape, as a function of the three answers the world
gives: core's revision, the manifest, and one directory scan per manifest entry.

Split from `externalLinks` rather than left inside it because **every branch here
is a judgement about text** — which entry contributes roots, which contributes a
problem line, which of two claimants keeps a root — and none of them reads
anything. Inside the `IO` shell the same branches need a package tree on disk to
reach. What would falsify the split: a rule that has to look at a file to decide,
which would put the read back in the middle. -/
def assembleLinks (core : Except String String) (manifest : Except String Manifest)
    (scanned : Array ScannedPackage) : Packages := Id.run do
  let mut problems : Array String := #[]
  let mut collisions : Array String := #[]
  -- Core first: its four roots are the toolchain's and are not a package's to
  -- redefine, and `mkExternalLinks` keeps the first of a repeated root.
  let mut entries : Array (String × String) := #[]
  match core with
  | .ok hash =>
    for (name, dir) in coreRoots do
      entries := entries.push (name, s!"{coreUrl}/blob/{hash}/{dir}")
  | .error problem => problems := problems.push problem
  let mut declared := 0
  let mut resolved := 0
  let mut unpinnedRoots := 0
  match manifest with
  | .error problem => problems := problems.push problem
  | .ok manifest =>
    declared := manifest.listed
    problems := problems ++ manifest.problems
    for package in scanned do
      let unpinnable := package.entry.blobBase.isEmpty
      let names := match package.roots with
        | .ok found => found
        | .error _ => #[]
      if names.isEmpty then
        -- An unpinnable package is already reported by `parseManifest` with the
        -- reason it cannot be linked, and a second line saying its directory
        -- could not be read would be the same failure counted twice.
        if !unpinnable then
          match package.roots with
          | .error problem => problems := problems.push problem
          | .ok _ =>
            problems := problems.push s!"{package.dir}: no top-level .lean file, so no module \
              root could be resolved for package `{package.entry.name}`"
        continue
      if !unpinnable then resolved := resolved + 1
      for name in names do
        match claimedBase entries name with
        -- Reported rather than resolved silently: a real collision would be
        -- links pointing into the wrong repository.
        | some base => collisions := collisions.push (collisionLine name package.entry.name base)
        | none =>
          if unpinnable then unpinnedRoots := unpinnedRoots + 1
          entries := entries.push (name, package.entry.blobBase)
  return {
    links := mkExternalLinks entries
    resolved, unpinnedRoots, declared, problems, collisions }

/-- Where a manifest entry's sources are: its own `dir` when it carries one,
`<packagesDir>/<name>` otherwise. -/
def packageDir (root : FilePath) (packagesDir : String) (entry : PackageEntry) : FilePath :=
  match entry.dir with
  | some relative => root / relative
  | none => root / packagesDir / entry.name

def externalLinks (root lake : FilePath) : IO Packages := do
  let core ← coreGithash root lake
  let manifest ← readManifest (root / "lake-manifest.json")
  let mut scanned : Array ScannedPackage := #[]
  if let .ok m := manifest then
    for entry in m.packages do
      let dir := packageDir root m.packagesDir entry
      scanned := scanned.push { entry, dir, roots := ← moduleRoots dir }
  return assembleLinks core manifest scanned

end Litedoc4
