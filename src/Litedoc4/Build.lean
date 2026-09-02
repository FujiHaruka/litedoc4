/- A Lean package in, a documentation site out, in one command — the libraries,
the module list, the source URL, the choice between the full path and the
incremental one, and the layout under `--out` that lets a second run find what
the first one left.

# When the ledger is written — the one ordering that has a silent failure

The ledger's claim is "**the IR was built from these oleans, and the pages were
rendered from that IR**". Two ways to get its timing wrong, and they are not
symmetric:

* **Write it early** (before the pages) and a run that dies in the renderer
  leaves a ledger saying every module is up to date. The next run re-extracts
  nothing, re-renders nothing, and the site is permanently half-old **with no
  diagnostic anywhere**.
* **Write it late but with the hashes read late** and the same silence arrives by
  another road: an olean rebuilt *while* this run was extracting is recorded as
  the one its IR came from, and that module is never re-extracted again.

So the rule is one sentence — **hash before extracting, write after rendering**.
Every failure before the write leaves the previous ledger in place and the next
run redoes the work, which is the safe direction: it is loud and it is finite.

The two keys are the exception, and deliberately so: they are recomputed against
the IR tree that now exists, because they describe *the tree on disk*. Writing
back `detect`'s copy would leave a ledger claiming the IR was written by whatever
wrote the old one, and every later run would re-extract everything for ever. -/
import Litedoc4.Assets
import Litedoc4.DepsDocs
import Litedoc4.Incr.Pipeline
import Litedoc4.Lakefile
import Litedoc4.Modules

open System

namespace Litedoc4

/-- The static files a page needs to look like a page, written from the binary
on **every** build.

Unconditional and idempotent: it overwrites whatever is at each path rather than
asking whether it differs, because a build that skipped an asset because "it was
already there" would leave an edited or truncated file in place and nothing
downstream would notice. It is `build`'s and never `site`'s — `site` is render
plus the whole-package artifacts and nothing else, which is the invariant that
lets the two commands' trees be compared. -/
def writeAssets (site : FilePath) : IO Unit := do
  IO.FS.createDirAll site
  for (name, body) in assets do
    IO.FS.writeFile (site / name) body

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

/-! ## The directory the build owns -/

/-- Bumped when a directory written by an older `build` can no longer be
continued by this one. -/
def layoutVersion : Nat := 1

/-- Not inside `<out>/site`, because the site's file count is a denominator this
project quotes and a stray file in it would change that number. -/
def markerName : String := "litedoc4-build.json"

/-- Round 1 is where deletions are folded in, so the bound is at least 1. -/
def defaultMaxRounds : Nat := 5

/-- What makes `self` enough is that the render set is a **union** with the
whole-package map delta: a change that reaches another module's page without
moving a name is a change ownership already re-extracted the other module for. -/
def defaultMode : ImpactMode := .selfOnly

structure Layout where
  out : FilePath
  site : FilePath
  ir : FilePath
  state : FilePath
  work : FilePath
  ledger : FilePath
  marker : FilePath
  linkIndex : FilePath
  /-- The resolved documentation map, which `litedoc4 site --deps-docs-map` and
  `litedoc4 render --deps-docs-map` read back. Written only when
  `--deps-docs-url` was passed. -/
  depsDocsMap : FilePath

def layoutOf (out : FilePath) : Layout :=
  { out
    site := out / "site"
    ir := out / "ir"
    state := out / "state"
    work := out / "work"
    ledger := out / "ledger.json"
    marker := out / markerName
    linkIndex := out / "link-index.lidx"
    depsDocsMap := out / "work" / "deps-docs-map.json" }

/-- Whether every file a continuation reads is there.

The name map is in the list because the incremental round's map delta compares
against it, and a site tree without one runs with the delta off — a *correct* run
that re-renders too little the first time the map moves. So is the dependency
map: an incremental round renders a *subset*, so a missing map produces pages
whose links are gone, mixed into a tree of pages that still have theirs. A full
generation writes the map again, which is why a missing one is answered by taking
that path rather than by refusing.

`linkIndex` is the request's, not `l.linkIndex`: with `--link-index` the map is
somebody else's file and this run never writes one under `--out`, so asking for
the derived path answers "no previous run" on every second run and the build
silently becomes a full one for ever. The bytes still come out right, which is
why only a gate counting re-extractions catches it. -/
def Layout.carriesAPreviousRun (l : Layout) (linkIndex : FilePath) : IO Bool := do
  let ledger ← isRegularFile l.ledger
  let index ← isRegularFile (l.ir / "index.json")
  let state ← isRegularFile (l.state / "global-state.json")
  let map ← isRegularFile linkIndex
  let names ← isRegularFile (l.site / "declarations" / "name-map.json")
  return ledger && index && state && map && names

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
  pagesRendered : Nat
  mathFallbacks : Nat
  extractorRequests : Nat
  cacheHits : Nat
  cacheMisses : Nat
  moduleSummaries : Nat
  moduleSummariesEchoingTheName : Nat
  irReads : IrReads

def WorkCounts.toJson (w : WorkCounts) : String :=
  "{\"modulesExtracted\":" ++ toString w.modulesExtracted
    ++ ",\"pagesRendered\":" ++ toString w.pagesRendered
    ++ ",\"mathFallbacks\":" ++ toString w.mathFallbacks
    ++ ",\"extractorRequests\":" ++ toString w.extractorRequests
    ++ ",\"globalCacheHits\":" ++ toString w.cacheHits
    ++ ",\"globalCacheMisses\":" ++ toString w.cacheMisses
    ++ ",\"moduleSummaries\":" ++ toString w.moduleSummaries
    ++ ",\"moduleSummariesEchoingTheName\":" ++ toString w.moduleSummariesEchoingTheName
    -- Split by kind, because only the module files divide into a number of full
    -- passes: `index.json` and the dependency slices are read a fixed number of
    -- times per run whatever the package's size.
    ++ ",\"irReads\":{\"index\":" ++ toString w.irReads.index
    ++ ",\"module\":" ++ toString w.irReads.module
    ++ ",\"depMap\":" ++ toString w.irReads.depMap
    ++ ",\"total\":" ++ toString w.irReads.total ++ "}}"

/-- The same numbers on stdout, so that the log and the marker cannot drift.
`irPasses` is printed rather than stored: it is a quotient of two values the
record already holds. -/
def WorkCounts.line (w : WorkCounts) (modules : Nat) : String :=
  s!"work    extract {w.modulesExtracted} / render {w.pagesRendered} / \
    math-fallback {w.mathFallbacks} / requests {w.extractorRequests} / \
    cache {w.cacheHits} hit {w.cacheMisses} miss / \
    summary {w.moduleSummaries} ({w.moduleSummariesEchoingTheName} name-only) / \
    ir {w.irReads.total} file(s) ({w.irReads.module} module read(s) = \
    {fixed w.irReads.module modules 2} full pass(es))"

/-- A fixed set of keys in a fixed order, with **no timestamp**: two runs of this
command over an unchanged package have to be able to produce identical trees.

**`work` absent *is* `complete: false`**, and it writes `"work": null` rather
than a record of zeros. A half-finished run has done some amount of work and this
file does not know how much — and zeros would be **the exact shape a successful
second run has**, so a gate reading a marker left by a crashed first run would
see "re-extracted nothing, rendered nothing" and pass. `null` makes that read
fail instead. -/
def markerJson (root : String) (libs : Array String) (sourceUrl : String) (modules : Nat)
    (work : Option WorkCounts) : String := Id.run do
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
  o := o ++ ",\"complete\":" ++ (if work.isSome then "true" else "false")
  o := o ++ ",\"work\":" ++ (match work with | none => "null" | some w => w.toJson)
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
  /-- Resolved **once**, by the caller, and used by both the renderer and
  `renderKey.externalLinks`. Resolving it twice is how the two would come to
  disagree, and a disagreement there re-renders every page on every run for
  ever. -/
  external : ExternalLinks
  /-- The documentation sites `--deps-docs-url` named, unresolved: the resolution
  needs an IR tree, which does not exist yet on the full path. -/
  depsDocs : Array DocsSite
  sourceUrl : Option String
  extractor : Option String
  extractorArgs : Array String
  extractorBin : Option FilePath
  lake : Option FilePath
  jobs : Nat
  /-- Absolute. Left out on the command line it is `<out>/link-index.lidx`, the
  map this run's own extractor writes; given, it names a file somebody else made
  and this run only reads. -/
  linkIndex : FilePath
  /-- Whether this run *writes* that file or only reads it. -/
  derivedLinkIndex : Bool
  mode : ImpactMode
  maxRounds : Nat
  timings : Option FilePath
  full : Bool

inductive Plan where
  | full (why : String)
  | incremental

/-- Full or incremental, and the reason, which is printed.

**The refusal in the middle is the important one**: this command removes and
overwrites things under `--out`, so it does that only to a directory whose marker
says it made it — and `--full` is answered **after** those checks, not before
them, because a full generation *deletes* `<out>/site` and `<out>/ir`. A `--full`
that short-circuited them would be the one way to make this command remove a
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
    let was := markerString kv "root"
    if was != r.root.toString then
      throw (3, s!"{layout.out} was built from {was}, not from {r.root}: the ledger under it \
        stores the target whose oleans it hashed, and continuing here would compare one package's \
        build tree with another package's hashes. Use a different --out")
    if r.full then return .full "--full"
    if markerNat kv "layout" != some layoutVersion then
      return .full "the layout under --out is from another version"
    -- Not a refusal: a package that gained a library has more modules, and a
    -- full run is the correct answer to "the question changed".
    if markerStrings kv "libs" != libs then return .full "the libraries changed"
    if !markerIsTrue kv "complete" then return .full "the previous run did not finish"
    if !(← layout.carriesAPreviousRun r.linkIndex) then
      return .full "the previous run's files are not all there"
    -- **The IR under `--out` has to be one this binary can read.** A CI cache
    -- restores the *previous* binary's state, so a schema bump arrives here as a
    -- tree every reader below refuses (measured 2026-08-23). `detect` is not this
    -- guard and cannot be: it answers "re-extract every module" correctly, and
    -- the round then reads the **base** IR — the tree the re-extraction is about
    -- to replace — to answer ownership, and dies there with the site left as it
    -- was.
    --
    -- Only the index is read, which is a **lower bound and not a proof**: `merge`
    -- writes the weakest schema under the tree into the index, so a tree *this*
    -- version merged cannot overstate, but a tree an older binary merged can.
    -- What the guard buys is the case that reaches CI: a whole tree from one
    -- older binary, which a cache restores as a unit.
    if !(← irIsReadable layout.ir) then
      return .full "the IR under --out is not one this version reads"
    return .incremental

/-- What one call to `runBuild` did, for a caller that makes many of them
(`watch`). The clock is the one field a gate may not assert on — this workload's
wall clock moves 5× with the page cache. -/
structure BuildRan where
  what : String
  modulesExtracted : Nat
  pagesRendered : Nat
  extractorRequests : Nat
  nanos : Nat

/-- What one path left behind, for the half of the run both paths share. -/
structure Done where
  what : String
  /-- Modules handed to the extractor, summed over the rounds. -/
  extracted : Nat
  rounds : Nat
  extractNanos : Nat
  renderNanos : Nat
  globalNanos : Nat
  pagesRendered : Nat
  mathFallbacks : Nat
  ledgerModules : Nat
  cacheHits : Nat
  cacheMisses : Nat
  summariesRendered : Nat
  summariesEchoingTheName : Nat
  /-- The ledger this run licensed, with the hashes read **before** the
  extraction. -/
  detected : Ledger
  /-- **The map the pages were rendered with.**

  It comes out of the path rather than in on `BuildRequest` because the two paths
  resolve it at different moments, both "as soon as there is an IR tree to read":
  a full generation has none until it has extracted, and an incremental round has
  to know its render key before `detect` compares it with the ledger's. Carrying
  it back here is what makes the ledger record the map the pages actually got. -/
  external : ExternalLinks
  deriving Inhabited

/-- The extractor, in the shape `litedoc4 incremental --serve` uses: a Lean
environment this run owns, started at the first request and released after the
last round. -/
def openExtractor (r : BuildRequest) (modulesFile : FilePath) (modules : Array String) :
    BuildM Extractor := do
  if let some program := r.extractor then
    return .oneShot { program, args := r.extractorArgs, requestCount := ← IO.mkRef 0 }
  let serve ← serveOptions
    { bin := r.extractorBin, target := some r.root, lake := r.lake, jobs := r.jobs
      modulesFile, modules, work := r.layout.work
      -- The resident extractor writes the map when this command owns it. With
      -- `--link-index` it is somebody else's file and is not overwritten.
      linkIndex := if r.derivedLinkIndex then some r.linkIndex else none }
  return .resident (← Resident.new serve)

/-- `--root`'s source map with every configured documentation site verified
against `ir` and attached.

**One function, two call sites, and they are the same rule**: resolve as soon as
there is an IR tree whose render key this run is about to record. Without
`--deps-docs-url` it is the identity — no fetch, no artifact, no line. -/
def resolveDocsFor (r : BuildRequest) (ir : FilePath) : BuildM ExternalLinks := do
  let resolved : Array ResolvedSite ← resolveDocs r.depsDocs ir (some r.layout.depsDocsMap)
  attachDocs r.external resolved

/-- The first run: hash, extract everything, render everything. -/
def fullGeneration (r : BuildRequest) (config : SiteConfig) (modules : Array String)
    (modulesFile : FilePath) (sourceUrl : String) (extractor : Extractor) : BuildM Done := do
  let layout := r.layout
  -- The hashes, **before** the extraction they license. Written into `work` as a
  -- diagnostic; the file that counts is written at the end of the run.
  let detected ← match ← buildLedger
      { modules, target := r.root.toString, ir := none, sourceUrl
        linkIndex := some r.linkIndex, externalLinks := some r.external.digest } with
    | .error message => throw (3, message)
    | .ok (ledger, _) => pure ledger
  writeFile (layout.work / "ledger-detect.json") detected.toJson
  IO.println s!"detect  {detected.modules.size} module(s) hashed"

  -- The page tree is removed rather than written over: the renderer only ever
  -- writes, so a module that vanished since the tree was made would keep its
  -- page and the site would hold a file no from-scratch run produces. Same for
  -- the IR, where a partial tree from an interrupted run would be merged with
  -- rather than replaced by this extraction.
  if ← layout.site.pathExists then IO.FS.removeDirAll layout.site
  if ← layout.ir.pathExists then IO.FS.removeDirAll layout.ir

  let extractStarted ← IO.monoNanosNow
  extractor.run modulesFile layout.ir (layout.work / "extract-timings-1.json")
  let elapsed := (← IO.monoNanosNow) - extractStarted
  -- The 3 GB environment is not held across the render: the loop is the only
  -- thing that extracts, which on this path is one request.
  extractor.release
  IO.println s!"extract {modules.size} module(s) in {seconds elapsed 4} s"

  -- **The documentation map, now that there is an IR to ask about.** Not before
  -- the extraction: on this path the tree does not exist yet, and the set of
  -- dependency names to verify is exactly what it holds.
  let external ← resolveDocsFor r layout.ir

  let siteStarted ← IO.monoNanosNow
  let rendered ← renderSite
    { ir := layout.ir, pages := layout.site, sourceUrl
      linkIndex := some r.linkIndex, external, title := config.title }
  let renderDone ← IO.monoNanosNow
  let derived ← buildGlobal
    { ir := layout.ir, out := layout.site, state := some layout.state
      indexMarkdown := config.indexMarkdown, title := config.title }
  let globalDone ← IO.monoNanosNow
  printRenderSummary "render  " rendered
  printGlobalSummary "global  " derived
  return { what := "full", extracted := modules.size, rounds := 1
           extractNanos := elapsed, renderNanos := renderDone - siteStarted
           globalNanos := globalDone - renderDone
           pagesRendered := rendered.pagesWritten, mathFallbacks := rendered.mathFailures
           ledgerModules := detected.modules.size
           cacheHits := derived.cacheHits, cacheMisses := derived.cacheMisses
           summariesRendered := derived.summariesRendered
           summariesEchoingTheName := derived.summariesEchoingTheName
           detected, external }

/-- Every later run: the pipeline, over the tree the last one left. -/
def incrementalGeneration (r : BuildRequest) (config : SiteConfig) (modules : Array String)
    (sourceUrl : String) (extractor : Extractor) : BuildM Done := do
  let layout := r.layout
  -- **Before the round, from the tree the round starts on.** `detect` is about to
  -- compare this map's digest with the ledger's, and the render uses the same
  -- value, so it has to be resolved once and here.
  let external ← resolveDocsFor r layout.ir
  let run ← runIncremental
    { config, ir := layout.ir, pages := layout.site, ledger := layout.ledger
      work := layout.work, modules, sourceUrl, linkIndex := r.linkIndex
      external, state := layout.state
      mode := r.mode, maxRounds := r.maxRounds } extractor
  return { what := "incremental"
           extracted := run.summary.changed + run.summary.staleFound
           rounds := run.summary.rounds
           extractNanos := run.timings.extract, renderNanos := run.timings.render
           globalNanos := run.timings.global
           pagesRendered := run.summary.pagesRendered
           mathFallbacks := run.summary.mathFallbacks
           ledgerModules := run.detected.modules.size
           cacheHits := run.summary.cacheHits, cacheMisses := run.summary.cacheMisses
           summariesRendered := run.summary.summariesRendered
           summariesEchoingTheName := run.summary.summariesEchoingTheName
           detected := run.detected, external }

/-- Every file under `root`, at every depth. Counted rather than derived from the
stages' own numbers: `pagesInSite` is a denominator this project quotes (432
pages + 9 artifacts + 4 assets on the measurement target), and the point of it is
that it is what the tree holds and not what the run believes it wrote. -/
partial def countFiles (root : FilePath) : IO Nat := do
  let rec go (dir : FilePath) (acc : Nat) : IO Nat := do
    match ← (dir.readDir : IO (Array IO.FS.DirEntry)).toBaseIO with
    | .error _ => return acc
    | .ok listing => do
      let mut acc := acc
      for entry in listing do
        if ← entry.path.isDir then acc ← go entry.path acc else acc := acc + 1
      return acc
  go root 0

/-- The `build` record, in a key order that is part of the bytes. -/
def buildRecordJson (path : String) (modules extracted rounds : Nat) (work : WorkCounts)
    (pagesRendered pagesInSite ledgerModules ledgerBytes : Nat)
    (extractNanos renderNanos globalNanos totalNanos : Nat) : String :=
  let o := jsonStr "{\"command\":\"build\",\"path\":" path
  o ++ s!",\"modules\":{modules},\"extracted\":{extracted},\"rounds\":{rounds}"
    ++ ",\"work\":" ++ work.toJson
    ++ s!",\"pagesRendered\":{pagesRendered},\"pagesInSite\":{pagesInSite}"
    ++ s!",\"ledgerModules\":{ledgerModules},\"ledgerBytes\":{ledgerBytes}"
    ++ s!",\"extractSeconds\":{seconds extractNanos 9}"
    ++ s!",\"renderSeconds\":{seconds renderNanos 9}"
    ++ s!",\"globalSeconds\":{seconds globalNanos 9}"
    ++ s!",\"totalSeconds\":{seconds totalNanos 9}" ++ "}"

def runBuild (r : BuildRequest) : BuildM BuildRan := do
  let started ← IO.monoNanosNow
  -- The counters are the *process's*, and this command is one run per process —
  -- so this changes nothing today and says what `work.irReads` means tomorrow.
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
  | .full why => IO.println s!"plan    full generation ({why})"
  | .incremental => IO.println s!"plan    incremental (continuing {layout.out})"

  writeFile layout.marker (markerJson r.root.toString libs sourceUrl modules.size none)
  IO.FS.createDirAll layout.work
  let modulesFile := layout.work / "modules.txt"
  writeLines modulesFile modules

  let extractor ← openExtractor r modulesFile modules
  let config ← readSiteConfig (some r.root)
  -- `finally` and not a `←` on the two paths: the resident environment is
  -- released on the failing path too, and doing it here puts the stop **before**
  -- the error reaches the caller rather than after.
  let done ← try
      match plan with
      | .full _ => fullGeneration r config modules modulesFile sourceUrl extractor
      | .incremental => incrementalGeneration r config modules sourceUrl extractor
    finally
      extractor.release

  -- On every run, whether or not a page was re-rendered, and before the ledger,
  -- whose claim is about a *finished* tree.
  writeAssets layout.site
  IO.println s!"assets  {assets.size} file(s) -> {layout.site}"
  -- Counted here rather than in the two paths: this is the first point at which
  -- the site holds everything a run puts in it.
  let pagesInSite ← countFiles layout.site

  -- The ledger last: everything that could have failed has now succeeded, so the
  -- claim "the IR was built from these oleans and the pages from that IR" is
  -- true when it is written and not before. The two keys are recomputed against
  -- the tree that now exists — they describe *the tree on disk*, and writing
  -- back the pre-run values would leave a ledger the next run re-extracts
  -- everything against, for ever.
  let ledger := { done.detected with
    extractKey := ← extractKey done.detected.target (some layout.ir)
    renderKey := some (renderKey sourceUrl (← linkIndexDigest (some r.linkIndex))
      (some done.external.digest)) }
  let body := ledger.toJson
  writeFile layout.ledger body
  IO.println s!"ledger  {done.ledgerModules} module(s) -> {layout.ledger} \
    ({body.utf8ByteSize} B)"

  -- Taken **here**, after the last stage that touches the IR: the ledger's
  -- `extractKey` reads `index.json`, so a snapshot one line earlier would report
  -- a number the next run's would not reproduce.
  let work : WorkCounts :=
    { modulesExtracted := done.extracted
      pagesRendered := done.pagesRendered
      mathFallbacks := done.mathFallbacks
      extractorRequests := ← extractor.requests
      cacheHits := done.cacheHits
      cacheMisses := done.cacheMisses
      moduleSummaries := done.summariesRendered
      moduleSummariesEchoingTheName := done.summariesEchoingTheName
      irReads := ← irReads }
  IO.println (work.line modules.size)
  writeFile layout.marker (markerJson r.root.toString libs sourceUrl modules.size (some work))
  let total := (← IO.monoNanosNow) - started
  IO.println s!"build   {done.what} in {seconds total 4} s -> {layout.site}"
  if let some path := r.timings then
    let line := buildRecordJson done.what modules.size done.extracted done.rounds work
      done.pagesRendered pagesInSite done.ledgerModules body.utf8ByteSize
      done.extractNanos done.renderNanos done.globalNanos total
    writeFile path (line ++ "\n")
    IO.println line
  return { what := done.what, modulesExtracted := work.modulesExtracted
           pagesRendered := work.pagesRendered, extractorRequests := work.extractorRequests
           nanos := total }

end Litedoc4
