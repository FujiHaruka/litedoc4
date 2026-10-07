/- A Lean package in, its IR out, in one command — the libraries, the module
list, the source URL, the choice between extracting everything and extracting
what moved, and the layout under `--out` that lets a second run find what the
first one left.

# When the ledger is written — the one ordering that has a silent failure

The ledger's claim is "**the IR was built from these oleans**". Two ways to get
its timing wrong, and they are not symmetric:

* **Write it early** (before the extraction finishes) and a run that dies in
  the middle leaves a ledger saying every module is up to date. The next run
  re-extracts nothing, and the IR is permanently half-old **with no diagnostic
  anywhere**.
* **Write it late but with the hashes read late** and the same silence arrives by
  another road: an olean rebuilt *while* this run was extracting is recorded as
  the one its IR came from, and that module is never re-extracted again.

So the rule is one sentence — **hash before extracting, write after extracting**.
Every failure before the write leaves the previous ledger in place and the next
run redoes the work, which is the safe direction: it is loud and it is finite.

The two keys are the exception, and deliberately so: they are recomputed against
the IR tree that now exists, because they describe *the tree on disk*. Writing
back `detect`'s copy would leave a ledger claiming the IR was written by whatever
wrote the old one, and every later run would re-extract everything for ever. -/
import Litedoc4.Incr.Pipeline
import Litedoc4.Lakefile
import Litedoc4.Modules

open System

namespace Litedoc4

/-! ## The source URL -/

/-- `<owner>/<repo>` when the remote is a github.com one, in any of the spellings
git writes. -/
def githubPath (remote : String) : Option String :=
  let remote := trimWs remote
  let stripped := ["https://github.com/", "http://github.com/", "git@github.com:",
      "ssh://git@github.com/"].findSome? fun p =>
    if remote.startsWith p then some (remote.drop p.length).toString else none
  match stripped with
  | none => none
  | some rest =>
    let rest := trimTrailingSlash rest
    let rest := if rest.endsWith ".git" then (rest.dropEnd 4).toString else rest
    match rest.splitOn "/" with
    | [owner, repo] => if owner.isEmpty || repo.isEmpty then none else some s!"{owner}/{repo}"
    | _ => none

abbrev GitM := ExceptT String IO

def git (root : FilePath) (args : Array String) : GitM String := do
  let spelled := " ".intercalate args.toList
  match ← (IO.Process.output { cmd := "git", args := #["-C", root.toString] ++ args }).toBaseIO with
  | .error e => throw s!"git {spelled}: {e}"
  | .ok out =>
    if out.exitCode != 0 then
      throw s!"git {spelled} in {root} failed: {trimWs out.stderr}. --source-url is a git \
        question — pass it explicitly if the package is not a checkout"
    return trimWs out.stdout

/-- `git`, with a failure folded into `none`: the one caller that asks this way
wants a diagnostic, and a checkout that cannot say whether it is dirty still has
a HEAD. -/
def gitQuiet (root : FilePath) (args : Array String) : IO (Option String) := do
  match ← (git root args).run with
  | .ok text => return some text
  | .error _ => return none

/-- `https://github.com/<owner>/<repo>/blob/<40-hex>/<prefix>`, from the checkout
itself.

**Only `github.com` remotes are read.** The `/blob/<rev>/<path>` shape is
GitHub's; GitLab puts an extra `-` segment before `blob`, Gitea and sr.ht differ
again.
Guessing a host's URL scheme produces links that are *plausible* and 404, on
every declaration of every page.

An uncommitted working tree is reported rather than refused: the pages will link
to the last commit, which is a fact worth one line of output and is not this
command's to fix. -/
def deriveSourceUrl (root : FilePath) : GitM String := do
  let rev ← git root #["rev-parse", "HEAD"]
  let remote ← git root #["config", "--get", "remote.origin.url"]
  let some path := githubPath remote
    | throw s!"cannot derive --source-url from `{remote}`: only github.com remotes have a \
        /blob/<rev>/<path> shape this can be sure of, and a guessed one 404s on every declaration \
        of every page. Pass --source-url https://<host>/<owner>/<repo>/blob/{rev}"
  -- Where the package sits inside the repository. Empty at the root, which is
  -- the shape every number in `benchmarks/` was taken with; a package below it
  -- links at a path the repository does not have without this.
  let subdir ← git root #["rev-parse", "--show-prefix"]
  match ← gitQuiet root #["status", "--porcelain"] with
  | none => pure ()
  | some dirty =>
    let count := (dirty.splitOn "\n").filter (fun line => !(trimWs line).isEmpty) |>.length
    if count > 0 then
      IO.println s!"source  note: {count} uncommitted change(s) in {root} — the pages will link \
        to HEAD"
  -- The renderer appends `/<module path>.lean`, so the base must not end in a
  -- slash; at the repository root `subdir` is empty and this is byte-identical
  -- to what it produced there before.
  return trimTrailingSlash s!"https://github.com/{path}/blob/{rev}/{subdir}"

/-- The dependency link map, resolved in one place so that the store entry and the
ledger's render key cannot read it two ways.

**Problems do not stop the run**: a package missing from disk, a manifest that
will not parse, a `lake` that will not run — each costs the roots it would have
contributed and is printed. Refusing would trade a site with some dead links for
no site at all. `litedoc4.toml` is the opposite and is an error, because there
the package asked for something by name. -/
def resolveExternal (root lake : Option String) : IO ExternalLinks := do
  match root with
  | none => do
    IO.println "external  no package named (--root), so links into a dependency stay relative \
      to pages this site does not write"
    return {}
  | some root => do
    let lake ← match lake with
      | some path => pure path
      | none => pure (((← IO.getEnv "LAKE").filter (!·.isEmpty)).getD "lake")
    let resolved ← externalLinks ⟨root⟩ ⟨lake⟩
    IO.println s!"external  {resolved.links.roots.size} root(s) from \
      {resolved.resolved}/{resolved.declared} package(s) + core"
    -- The roots in that count that carry no URL: they are in the map so that
    -- the pages stop linking into them, which is the opposite of what the line
    -- above reads like on its own.
    if resolved.unpinnedRoots > 0 then
      IO.println s!"external  note: {resolved.unpinnedRoots} of those root(s) have no \
        version-pinned URL, so names in them render without a link rather than linking at a \
        page this site does not write"
    for line in resolved.collisions ++ resolved.problems do
      IO.println s!"external  note: {line}"
    return resolved.links

/-! ## The directory the build owns -/

/-- Bumped when a directory written by an older `build` can no longer be
continued by this one. -/
def layoutVersion : Nat := 2

/-- Not inside `<out>/site`, because the site's file count is a denominator this
project quotes and a stray file in it would change that number. -/
def markerName : String := "litedoc4-build.json"

/-- Round 1 is where deletions are folded in, so the bound is at least 1. -/
def defaultMaxRounds : Nat := 5

structure Layout where
  out : FilePath
  site : FilePath
  ir : FilePath
  work : FilePath
  ledger : FilePath
  marker : FilePath
  linkIndex : FilePath

def layoutOf (out : FilePath) : Layout :=
  { out
    site := out / "site"
    ir := out / "ir"
    work := out / "work"
    ledger := out / "ledger.json"
    marker := out / markerName
    linkIndex := out / "link-index.lidx" }

/-- Whether every file a continuation reads is there. A missing one is answered
by extracting everything rather than by refusing: that path writes all of them
again. -/
def Layout.carriesAPreviousRun (l : Layout) : IO Bool := do
  let ledger ← isRegularFile l.ledger
  let index ← isRegularFile (l.ir / "index.json")
  let map ← isRegularFile l.linkIndex
  return ledger && index && map

/-- Whether the IR tree under `--out` is one this binary reads.

A tree it cannot open at all counts as unreadable too: the question is "can this
run continue from what is there", and an index that will not parse answers it the
same way an old one does. -/
def irIsReadable (ir : FilePath) : IO Bool := do
  match ← (openIrTreeUnvalidated ir).toBaseIO with
  | .error _ => return false
  | .ok tree => return tree.index.schemaVersion ≥ minSchemaVersion

/-- **How much work one run did, as integers that do not depend on the machine.**

This project's product is speed, and a wall clock cannot judge speed here: the
oleans are `mmap`ed, so the same unchanged run's environment load moves by 5×
with the page cache (2.5 s ↔ 13 s (measured)). A threshold over seconds is either
loose enough to pass a regression or tight enough to fail a cold runner, and both
are worse than no gate because they look like one. -/
structure WorkCounts where
  modulesExtracted : Nat
  extractorRequests : Nat
  irReads : IrReads

def WorkCounts.toJson (w : WorkCounts) : String :=
  "{\"modulesExtracted\":" ++ toString w.modulesExtracted
    ++ ",\"extractorRequests\":" ++ toString w.extractorRequests
    -- Split by kind, because only the module files divide into a number of full
    -- passes: `index.json` and the dependency slices are read a fixed number of
    -- times per run whatever the package's size.
    ++ ",\"irReads\":{\"index\":" ++ toString w.irReads.index
    ++ ",\"module\":" ++ toString w.irReads.module
    ++ ",\"depMap\":" ++ toString w.irReads.depMap
    ++ ",\"total\":" ++ toString w.irReads.total ++ "}}"

/-- The same numbers on stdout, so that the log and the marker cannot drift. -/
def WorkCounts.line (w : WorkCounts) : String :=
  s!"work    extract {w.modulesExtracted} / requests {w.extractorRequests} / \
    ir {w.irReads.total} file(s) ({w.irReads.module} module read(s))"

/-- What a build of one working tree put into the store and rendered. -/
structure Stored where
  version : String
  store : String
  extracted : Bool

/-- A fixed set of keys in a fixed order, with **no timestamp**: two runs of this
command over an unchanged package have to be able to produce identical trees.

**`work` absent *is* `complete: false`**, and it writes `"work": null` rather
than a record of zeros. A half-finished run has done some amount of work and this
file does not know how much — and zeros would be **the exact shape a successful
second run has**, so a gate reading a marker left by a crashed first run would
see "re-extracted nothing" and pass. `null` makes that read fail instead. -/
def markerJson (root : String) (libs : Array String) (sourceUrl : String) (modules : Nat)
    (done : Option (WorkCounts × Stored)) : String := Id.run do
  let mut o := "{\"tool\":\"litedoc4 build\",\"layout\":" ++ toString layoutVersion ++ ",\"root\":"
  o := jsonStr o root
  o := o ++ ",\"libs\":["
  let mut first := true
  for lib in libs do
    if !first then o := o.push ','
    first := false
    o := jsonStr o lib
  o := jsonStr (o ++ "],\"sourceUrl\":") sourceUrl
  o := o ++ ",\"modules\":" ++ toString modules
  o := o ++ ",\"complete\":" ++ (if done.isSome then "true" else "false")
  match done with
  | none => o := o ++ ",\"work\":null,\"version\":null,\"store\":null,\"versionsExtracted\":null"
  | some (w, s) =>
    o := o ++ ",\"work\":" ++ w.toJson
    o := jsonStr (o ++ ",\"version\":") s.version
    o := jsonStr (o ++ ",\"store\":") s.store
    o := o ++ s!",\"versionsExtracted\":\{\"count\":{if s.extracted then 1 else 0},\"of\":1,\
      \"names\":["
    if s.extracted then o := jsonStr o s.version
    o := o ++ "]}"
  return o ++ "}\n"

inductive Marker where
  | absent
  | broken (why : String)
  | fields (kv : Array (String × JVal))

/-- A marker that will not parse is **not** treated as absent: it was written by
something, and deleting a site on the strength of a file this cannot read is the
failure the marker exists to prevent. -/
def readMarker (path : FilePath) : IO Marker := do
  match ← (IO.FS.readFile path).toBaseIO with
  | .error _ => return .absent
  | .ok text =>
    match parseJson text with
    | .ok (.obj kv) => return .fields kv
    | .ok _ => return (.broken "the document is not an object")
    | .error why => return (.broken why)

def markerString (kv : Array (String × JVal)) (key : String) : String :=
  match orderedGet? kv key with
  | some (.str s) => s
  | _ => ""

def markerNat (kv : Array (String × JVal)) (key : String) : Option Nat :=
  match orderedGet? kv key with
  | some (.num n) => if n ≥ 0 then some n.toNat else none
  | _ => none

def markerIsTrue (kv : Array (String × JVal)) (key : String) : Bool :=
  match orderedGet? kv key with
  | some (.bool b) => b
  | _ => false

/-- The `libs` array, with anything that is not a string dropped — the same
reading `serde_json`'s `filter_map(as_str)` gives, so a hand-edited marker
compares as the list it can be read as rather than failing. -/
def markerStrings (kv : Array (String × JVal)) (key : String) : Array String := Id.run do
  match orderedGet? kv key with
  | some (.arr items) =>
    let mut out : Array String := #[]
    for item in items do
      if let .str s := item then out := out.push s
    return out
  | _ => return #[]

/-! ## The command -/

structure BuildRequest where
  /-- Canonicalised **before** anything is compared against it: `--out` under a
  symlinked `--root` is still under `--root`. -/
  root : FilePath
  layout : Layout
  libs : Array String
  /-- Resolved **once**, by the caller: its digest is in the ledger's key, and
  resolving it twice is how two runs would come to disagree about it. -/
  external : ExternalLinks
  sourceUrl : Option String
  extractorBin : Option FilePath
  lake : Option FilePath
  jobs : Nat
  timings : Option FilePath
  full : Bool
  noEquationsUnder : Option (Array String) := none

inductive Plan where
  | full (why : String)
  | incremental

def severalVersionsHere (out : FilePath) : String :=
  s!"{out} holds a site of several versions: `build` without --versions replaces <out>/site \
    with one version, so it will not take over a directory `build --versions` wrote. Use a \
    different --out"

/-- Everything or what moved, and the reason, which is printed.

**The refusal in the middle is the important one**: this command removes and
overwrites things under `--out`, so it does that only to a directory whose marker
says it made it — and `--full` is answered **after** those checks, not before
them, because extracting everything *deletes* `<out>/ir`. A `--full` that
short-circuited them would be the one way to make this command remove a
directory whose marker it never looked at. -/
def planOf (r : BuildRequest) (libs : Array String) : BuildM Plan := do
  let layout := r.layout
  if !(← layout.out.pathExists) || (← isEmptyDir layout.out) then
    return .full "nothing there yet"
  match ← readMarker layout.marker with
  | .absent =>
    throw (3, s!"{layout.out} is not empty and has no {markerName}: this command deletes and \
      overwrites inside --out, so it will only do that to a directory it can see it wrote. Name \
      an empty directory, or remove this one yourself")
  | .broken why =>
    throw (3, s!"{layout.marker}: {why}. This file says which directory `litedoc4 build` \
      owns; one that will not parse is not one to overwrite a site on the strength of")
  | .fields kv =>
    if (orderedGet? kv "versions").isSome then throw (3, severalVersionsHere layout.out)
    let was := markerString kv "root"
    if was != r.root.toString then
      throw (3, s!"{layout.out} was built from {was}, not from {r.root}: the ledger under it \
        stores the target whose oleans it hashed, and continuing here would compare one package's \
        build tree with another package's hashes. Use a different --out")
    if r.full then return .full "--full"
    if markerNat kv "layout" != some layoutVersion then
      return .full "the layout under --out is from another version"
    -- Not a refusal: a package that gained a library has more modules, and
    -- extracting everything is the correct answer to "the question changed".
    if markerStrings kv "libs" != libs then return .full "the libraries changed"
    if !markerIsTrue kv "complete" then return .full "the previous run did not finish"
    if !(← layout.carriesAPreviousRun) then
      return .full "the previous run's files are not all there"
    -- **The IR under `--out` has to be one this binary can read.** A CI cache
    -- restores the *previous* binary's state, so a schema bump arrives here as a
    -- tree every reader below refuses (measured 2026-08-23). `detect` is not this
    -- guard and cannot be: it answers "re-extract every module" correctly, and
    -- the round then reads the **base** IR — the tree the re-extraction is about
    -- to replace — to answer ownership, and dies there.
    --
    -- Only the index is read, which is a **lower bound and not a proof**: `merge`
    -- writes the weakest schema under the tree into the index, so a tree *this*
    -- version merged cannot overstate, but a tree an older binary merged can.
    if !(← irIsReadable layout.ir) then
      return .full "the IR under --out is not one this version reads"
    return .incremental

/-- The extractor: a Lean environment this run owns, started at the first request
and released after the last round. It writes the dependency map, which a store
entry holds beside the IR. -/
def openExtractor (r : BuildRequest) (bin : FilePath) (modulesFile : FilePath)
    (modules : Array String) : BuildM Resident := do
  let serve ← serveOptions
    { bin, target := r.root, lake := r.lake, jobs := r.jobs
      modulesFile, modules, work := r.layout.work, noEquationsUnder := r.noEquationsUnder
      linkIndex := some r.layout.linkIndex }
  Resident.new serve

/-- What one path left behind, for the half of the run both paths share. -/
structure Done where
  what : String
  /-- Modules handed to the extractor, summed over the rounds. -/
  extracted : Nat
  rounds : Nat
  extractNanos : Nat
  ledgerModules : Nat
  /-- The ledger this run licensed, with the hashes read **before** the
  extraction. -/
  detected : Ledger
  deriving Inhabited

/-- The first run: hash, extract everything. -/
def fullExtraction (r : BuildRequest) (bibliography : Option String) (modules : Array String)
    (modulesFile : FilePath) (sourceUrl : String) (extractor : Resident) : BuildM Done := do
  let layout := r.layout
  -- The hashes, **before** the extraction they license. Written into `work` as a
  -- diagnostic; the file that counts is written at the end of the run.
  let detected ← match ← buildLedger
      { modules, target := r.root.toString, ir := none, sourceUrl
        linkIndex := some layout.linkIndex, externalLinks := some r.external.digest
        bibliography } with
    | .error message => throw (3, message)
    | .ok (ledger, _) => pure ledger
  writeFile (layout.work / "ledger-detect.json") detected.toJson
  IO.println s!"detect  {detected.modules.size} module(s) hashed"

  -- Removed rather than written over: a partial tree from an interrupted run
  -- would be merged with rather than replaced by this extraction.
  if ← layout.ir.pathExists then IO.FS.removeDirAll layout.ir

  let extractStarted ← IO.monoNanosNow
  discard <| extractor.extract modulesFile layout.ir (layout.work / "extract-timings-1.json")
  let elapsed := (← IO.monoNanosNow) - extractStarted
  extractor.stop
  IO.println s!"extract {modules.size} module(s) in {seconds elapsed 4} s"
  return { what := "full", extracted := modules.size, rounds := 1, extractNanos := elapsed
           ledgerModules := detected.modules.size, detected }

/-- Every later run: the rounds, over the tree the last one left. -/
def incrementalExtraction (r : BuildRequest) (bibliography : Option String)
    (modules : Array String) (sourceUrl : String) (extractor : Resident) : BuildM Done := do
  let layout := r.layout
  let run ← runRounds
    { ir := layout.ir, ledger := layout.ledger, work := layout.work, modules, sourceUrl
      linkIndex := layout.linkIndex, externalDigest := r.external.digest, bibliography
      maxRounds := defaultMaxRounds } extractor
  return { what := "incremental"
           extracted := run.check.reExtract.size + run.staleFound
           rounds := run.rounds, extractNanos := run.extractNanos
           ledgerModules := run.check.fresh.modules.size, detected := run.check.fresh }

/-- What one extraction did, for the caller that stores and renders it. -/
structure Extracted where
  what : String
  libs : Array String
  modules : Array String
  sourceUrl : String
  rounds : Nat
  ledgerModules : Nat
  ledgerBytes : Nat
  work : WorkCounts
  extractNanos : Nat
  started : Nat

/-- The IR of `r.root` under `<out>/ir` and its dependency map beside it, brought
up to date: everything on a first run, the modules whose oleans moved after
that. It writes the ledger and an unfinished marker; the caller finishes the
marker once what it does with the IR has worked.

`bin` is asked for after the ownership check, because an extractor this command
builds itself is written under `--out`. -/
def runExtraction (r : BuildRequest) (bin : BuildM FilePath) : BuildM Extracted := do
  let started ← IO.monoNanosNow
  -- The counters are the *process's*, and `watch` makes one call per pass.
  resetIrReads
  let layout := r.layout
  let libs ← if r.libs.isEmpty then
      match ← readLibraries r.root with
      | .error message => throw (3, message)
      | .ok declared => do
        IO.println s!"lib     {", ".intercalate declared.names.toList} (from {declared.file})"
        pure declared.names
    else do
      IO.println s!"lib     {", ".intercalate r.libs.toList} (--lib)"
      pure r.libs

  let modules ← match ← moduleNames r.root libs with
    | .error message => throw (3, message)
    | .ok names => pure names
  if modules.isEmpty then
    throw (3, s!"no modules under {r.root} for {", ".intercalate libs.toList}: an empty list \
      would build an empty site and report success")
  IO.println s!"modules {modules.size}"

  let sourceUrl ← match r.sourceUrl with
    | some url => pure url
    | none => match ← (deriveSourceUrl r.root).run with
      | .error message => throw (3, message)
      | .ok url => pure url
  if let some message := checkSourceUrl sourceUrl then throw (2, message)
  IO.println s!"source  {sourceUrl}"

  -- **Before anything is written**, and that ordering is load-bearing: the
  -- question is "is `--out` empty, and if not, did this command write it", and
  -- creating the work directory first would make every answer "not empty, and
  -- yes".
  let plan ← planOf r libs
  match plan with
  | .full why => IO.println s!"plan    extract everything ({why})"
  | .incremental => IO.println s!"plan    incremental (continuing {layout.out})"

  writeFile layout.marker (markerJson r.root.toString libs sourceUrl modules.size none)
  IO.FS.createDirAll layout.work
  let modulesFile := layout.work / "modules.txt"
  writeLines modulesFile modules

  let extractor ← openExtractor r (← bin) modulesFile modules
  let bibliography := (← readSiteConfig (some r.root)).bibliography.digest
  -- `finally` and not a `←` on the two paths: the resident environment is
  -- released on the failing path too, and doing it here puts the stop **before**
  -- the error reaches the caller rather than after.
  let done ← try
      match plan with
      | .full _ => fullExtraction r bibliography modules modulesFile sourceUrl extractor
      | .incremental => incrementalExtraction r bibliography modules sourceUrl extractor
    finally
      extractor.stop

  -- The two keys are recomputed against the tree that now exists — they describe
  -- *the tree on disk*, and writing back the pre-run values would leave a ledger
  -- the next run re-extracts everything against, for ever.
  let ledger := { done.detected with
    extractKey := ← extractKey done.detected.target (some layout.ir)
    renderKey := some (renderKey sourceUrl (← linkIndexDigest (some layout.linkIndex))
      (some r.external.digest) bibliography) }
  let body := ledger.toJson
  writeFile layout.ledger body
  IO.println s!"ledger  {done.ledgerModules} module(s) -> {layout.ledger} \
    ({body.utf8ByteSize} B)"

  -- Taken **here**, after the last stage that touches the IR: the ledger's
  -- `extractKey` reads `index.json`, so a snapshot one line earlier would report
  -- a number the next run's would not reproduce.
  let work : WorkCounts :=
    { modulesExtracted := done.extracted
      extractorRequests := ← extractor.requests
      irReads := ← irReads }
  IO.println work.line
  return { what := done.what, libs, modules, sourceUrl, rounds := done.rounds
           ledgerModules := done.ledgerModules, ledgerBytes := body.utf8ByteSize, work
           extractNanos := done.extractNanos, started }

/-- The `build` record, in a key order that is part of the bytes. -/
def buildRecordJson (path : String) (modules extracted rounds : Nat) (work : WorkCounts)
    (ledgerModules ledgerBytes : Nat) (site : String)
    (extractNanos putNanos renderNanos totalNanos : Nat) : String :=
  let o := jsonStr "{\"command\":\"build\",\"path\":" path
  o ++ s!",\"modules\":{modules},\"extracted\":{extracted},\"rounds\":{rounds}"
    ++ ",\"work\":" ++ work.toJson
    ++ s!",\"ledgerModules\":{ledgerModules},\"ledgerBytes\":{ledgerBytes}"
    ++ ",\"site\":" ++ site
    ++ s!",\"extractSeconds\":{seconds extractNanos 9}"
    ++ s!",\"putSeconds\":{seconds putNanos 9}"
    ++ s!",\"renderSeconds\":{seconds renderNanos 9}"
    ++ s!",\"totalSeconds\":{seconds totalNanos 9}" ++ "}"

end Litedoc4
