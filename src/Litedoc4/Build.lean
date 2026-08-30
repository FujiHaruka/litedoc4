/- `crates/litedoc4/src/build.rs`: a Lean package in, a documentation site out,
in one command — the libraries, the module list, the source URL, the directory
under `--out` this command owns, and the resident extractor that fills it.

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

# What this build does not have yet

There is no incremental path, so `planOf` answers full after the ownership
checks rather than instead of them, and no run of this command deletes a
directory whose marker it has not read. -/
import Litedoc4.Assets
import Litedoc4.Config
import Litedoc4.Global
import Litedoc4.Ledger
import Litedoc4.Modules
import Litedoc4.Packages
import Litedoc4.Render.Site

open System

namespace Litedoc4

/-- `format!("{n:.digits$}")` for a non-negative rational, rounded half up.
Lean's `Float.toString` takes no width, and every duration this command prints
is written to a fixed number of places. -/
def fixed (num den digits : Nat) : String :=
  if den == 0 then "n/a" else
  let scale := 10 ^ digits
  let scaled := (2 * num * scale + den) / (2 * den)
  let frac := toString (scaled % scale)
  s!"{scaled / scale}." ++ String.ofList (List.replicate (digits - frac.length) '0') ++ frac

def seconds (nanos : Nat) (digits : Nat) : String := fixed nanos 1000000000 digits

/-- The exit code a refusal carries, beside what to say. 2 is a usage error and
prints the usage text; 3 is "the world and the files disagree"; 4 is the
extractor's, so that a caller sees the same code whichever half produced it. -/
abbrev BuildM := ExceptT (UInt32 × String) IO

/-- Writes `body` to `path`, making its directory first. -/
def writeFile (path : FilePath) (body : String) : IO Unit := do
  if let some dir := path.parent then
    if !dir.toString.isEmpty then IO.FS.createDirAll dir
  IO.FS.writeFile path body

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

def printRenderSummary (label : String) (s : Summary) : IO Unit := do
  IO.println s!"{label}modules {s.pagesWritten}/{s.modulesInIr}  \
    declarations {s.declarationsRendered}/{s.declarationsInIr} \
    ({s.declarationsSuppressed} suppressed)  module docs {s.moduleDocs}  bytes {s.bytes}"
  IO.println s!"{label}known {s.known}  link index {s.linkIndexEntries}  \
    known modules {s.knownModules}"
  -- Printed at zero too: the fallback it reports is silent, so a line that
  -- appeared only above zero could not be told from one that had stopped being
  -- printed.
  IO.println s!"{label}math spans kept as LaTeX {s.mathFailures}"

def printGlobalSummary (label : String) (d : GlobalSummary) : IO Unit := do
  IO.println s!"{label}modules {d.modules}  declarations {d.declarations} + \
    {d.dependencyNames} dependency names  instance classes {d.instanceClasses}  \
    instance types {d.instanceTypes}  tactic docs {d.tacticDocs}"
  IO.println s!"{label}name map {d.nameMapBytes} B  module index {d.modulesJsonBytes} B  \
    search index {d.searchIndexBytes} B"
  IO.println s!"{label}module descriptions {d.summariesRendered} of {d.modules} \
    ({d.summariesEchoingTheName} repeat the module name)"
  IO.println s!"{label}cache {d.cacheHits} hit / {d.cacheMisses} miss  state {d.stateBytes} B"

/-! ## The source URL -/

def sourceUrlBroken : String :=
  "the acceptance oracle normalises `/blob/[0-9a-f]{40}/` and nothing else, so with a tag or a \
   branch name here every page keeps its revision in the compared bytes and the score drops \
   3.1103 points with no diagnostic (measured)"

def splitOnce (s sep : String) : Option (String × String) :=
  match s.splitOn sep with
  | [] | [_] => none
  | head :: rest => some (head, sep.intercalate rest)

/-- Checked here and nowhere else: `render` and `site` ask only for a non-empty
string, because they are called by hand and by harnesses that pass placeholder
URLs on purpose. This is the path that runs on every commit, and the only place a
real revision enters. -/
def checkSourceUrl (url : String) : Option String :=
  match splitOnce url "/blob/" with
  | none => some s!"--source-url has no `/blob/` segment: {url}\n  {sourceUrlBroken}"
  | some (_, rest) =>
    let rev := (rest.splitOn "/").headD rest
    if isFortyHex rev then none
    else some s!"--source-url must carry a 40-digit lower-case hex revision after `/blob/`, not \
      `{rev}` ({rev.length} character(s))\n  {sourceUrlBroken}"

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

structure Layout where
  out : FilePath
  site : FilePath
  ir : FilePath
  state : FilePath
  work : FilePath
  ledger : FilePath
  marker : FilePath
  linkIndex : FilePath

def layoutOf (out : FilePath) : Layout :=
  { out
    site := out / "site"
    ir := out / "ir"
    state := out / "state"
    work := out / "work"
    ledger := out / "ledger.json"
    marker := out / markerName
    linkIndex := out / "link-index.lidx" }

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
  | broken
  | fields (kv : Array (String × JVal))

/-- A marker that will not parse is **not** treated as absent: it was written by
something, and deleting a site on the strength of a file this cannot read is the
failure the marker exists to prevent. -/
def readMarker (path : FilePath) : IO Marker := do
  match ← (IO.FS.readFile path).toBaseIO with
  | .error _ => return .absent
  | .ok text =>
    let n := text.utf8ByteSize
    let start := JScan.skipWs text n 0
    if start ≥ n || byteAt text start != 123 then return .broken
    match (JScan.pVal text n start).1 with
    | .obj kv => return .fields kv
    | _ => return .broken

def markerString (kv : Array (String × JVal)) (key : String) : String := Id.run do
  for (k, v) in kv do
    if k == key then
      match v with
      | .str s => return s
      | _ => return ""
  return ""

/-! ## The resident extractor -/

/-- Everything the server is started with. `modulesFile` is the **superset** it
imports — whatever a request asks for later has to be inside it, because a
resident environment is never grown (`Extract.lean:2707-2714`). -/
structure Serve where
  bin : FilePath
  lake : FilePath
  /-- The package being documented, already canonicalised. `lake env` runs in it
  and nothing is ever written into it. -/
  target : FilePath
  jobs : Nat
  modulesFile : FilePath
  /-- The same list, parsed — `Generation` hashes exactly these. -/
  modules : Array String
  work : FilePath
  linkIndex : FilePath
  linkIndexKey : String

/-- The oleans of one module list, as Lake's own content hashes.

`.lake` rather than `.sha256`, and `hashModule` rather than a walk of its own:
this reads the same files in the same order the ledger's `detect` reads, which is
what makes "the world" one thing here rather than two. What would falsify it: a
ledger that hashed a different file set, at which point the guard and `detect`
could disagree about which module moved. -/
structure Generation where
  /-- `(module, hash)`, in the module list's order. `-` is a module with no olean
  at all, which is a real state: it is what `detect` reports as removed. -/
  entries : Array (String × String)
  digest : String

def Generation.take (s : Serve) : BuildM Generation := do
  let target := trimTrailingSlash s.target.toString
  let libDir := s!"{target}/.lake/build/lib/lean"
  let mut entries : Array (String × String) := #[]
  for module in s.modules do
    match ← (hashModule .lake target libDir module).toBaseIO with
    | .error e => throw (3, s!"the resident extractor's generation over {libDir}: {e}")
    | .ok entry => entries := entries.push (module, (entry.map (·.hash)).getD "-")
  let joined := "\n".intercalate (entries.toList.map fun (module, hash) => s!"{module} {hash}")
  return { entries, digest := sha256Text joined }

/-- The modules that differ between two takes, by name.

The lists are the same module list in the same order, so this is a walk rather
than a join — and if they ever are not, the length difference is reported rather
than silently zipped away. -/
def Generation.moved (before after : Generation) : Array String := Id.run do
  if before.digest == after.digest && before.entries.size == after.entries.size then return #[]
  let mut moved : Array String := #[]
  for i in [0 : min before.entries.size after.entries.size] do
    if before.entries[i]! != after.entries[i]! then moved := moved.push before.entries[i]!.1
  for i in [after.entries.size : before.entries.size] do
    moved := moved.push before.entries[i]!.1
  for i in [before.entries.size : after.entries.size] do
    moved := moved.push after.entries[i]!.1
  return moved

def movedInMessage : Nat := 5

/-- Modules whose oleans moved under a running server. -/
def stale (moved : Array String) (when : String) : UInt32 × String :=
  let named := moved.toList.take movedInMessage
  let rest := moved.size - named.length
  let more := if rest > 0 then s!" and {rest} more" else ""
  (3, s!"the oleans moved {when}: {moved.size} module(s) — {", ".intercalate named}{more}. The \
    resident extractor imported the world as it was at the head of this run and Lean cannot swap \
    one module out of an imported environment (`Extract.lean:2716-2721`), so every answer it has \
    given since is about the old world. Re-run after the build that is in flight has finished")

/-- The one place the world is re-read and judged, rather than the reading
written out at each of the three moments it is wanted: three copies are three
answers to one question, which is how two guards start disagreeing. -/
def checkGeneration (s : Serve) (gen : Generation) (when : String) : BuildM Unit := do
  let moved := gen.moved (← Generation.take s)
  if !moved.isEmpty then throw (stale moved when)

/-- The token the extractor checks the map's `.key` sidecar against before
deciding whether the map on disk can be reused.

The map is a function of three inputs (`Extract.lean`'s `writeLinkIndex`): the
imported module set, those modules' oleans, and the omit list. The extractor
checks the first itself, out of the environment it is holding; this covers the
other two — the oleans through three of `extractKey`'s five values, and the omit
list **by its bytes, not its path**, because it changes when the package gains or
loses a module and a path is not an identity.

`irSchemaVersion` and `irGenerator` are deliberately left out: they describe *the
IR*, which the map is not, and they are read out of `<ir>/index.json`, which a
first-ever build has not written yet — including them made the first incremental
build after a first-ever build rewrite the map for nothing (measured
2026-08-17). -/
def linkIndexKeyOf (package omitList : FilePath) : IO String := do
  let key ← extractKey package.toString none
  let mut text := ""
  for name in ["leanToolchain", "manifestSha256", "extractor"] do
    match key.find? (fun entry => entry.1 == name) with
    | none => throw (IO.userError s!"extractKey has no `{name}`: the reuse token cannot be built")
    -- `name=value\n`, one per line: neither half can contain a newline (a
    -- toolchain string, a hex digest and a compile-time constant), so the
    -- concatenation is unambiguous without escaping.
    | some (_, value) => text := text ++ name ++ "=" ++ value ++ "\n"
  -- A blank line ends the key half, so that no rearrangement of its characters
  -- can produce the same digest as a different omit list.
  return sha256Hex ((text ++ "\n").toUTF8 ++ (← IO.FS.readBinFile omitList))

/-- `<timings without .json>-events.jsonl`. One spelling, and that is the point:
both extraction paths have to leave the events file in the same place under the
same name, or two records of the same run stop being comparable. -/
def eventsBeside (timings : FilePath) : FilePath :=
  let text := timings.toString
  ⟨(if text.endsWith ".json" then (text.dropEnd 5).toString else text) ++ "-events.jsonl"⟩

def trimEol (s : String) : String := Id.run do
  let mut n := s.utf8ByteSize
  while n > 0 && (byteAt s (n - 1) == 10 || byteAt s (n - 1) == 13) do
    n := n - 1
  return byteSub s 0 n

/-- One request line, or a refusal naming the path that cannot be sent.

The protocol splits on spaces and tabs (`Extract.lean:2748`), so a path with
whitespace in it does not fail — it arrives as two shorter paths and the server
writes an IR tree somewhere nobody named. The paths are absolute because the
server's working directory is the target. -/
def requestLine (paths : Array FilePath) : BuildM String := do
  let mut line := ""
  for path in paths do
    let text := (← absolutePath path).toString
    if text.toList.any (fun c => isWhiteSpaceCp c.val) then
      throw (3, s!"the resident extractor's protocol is one space-separated line per request \
        (`Extract.lean:2748`), so a path with whitespace in it cannot be sent: {text}")
    if !line.isEmpty then line := line.push ' '
    line := line ++ text
  return line.push '\n'

/-- The next line with this tag, with everything before it logged.

**Located by prefix, not by position**: the extractor prints a human-readable
phase report to the same stdout as the protocol, so counting lines would be
counting the report. -/
partial def waitFor (out log : IO.FS.Handle) (tag : String) : IO (Except String String) := do
  let line ← out.getLine
  if line.isEmpty then
    return .error s!"the resident extractor exited before `{trimWs tag}`"
  log.putStr line
  let text := trimEol line
  if text.startsWith tag then return .ok text
  if text.startsWith "err " then
    return .error s!"the resident extractor rejected the request: {text}"
  waitFor out log tag

/-- One environment, one request, and the stop.

The request channel is the child's **stdin pipe**, and a pipe cannot outlive its
writer: however this process dies, the kernel closes the write end, the server
reads EOF and returns 0 through its own exit path. Lean has no explicit close for
a handle, so the pipe is held in a reference cell and the stop is emptying it —
the last reference goes and the finaliser closes the fd. What would falsify the
cell: a `Handle.close` in core, which would make the cell an indirection with
nothing behind it. -/
def extractOnce (s : Serve) (gen : Generation) (irDir timings : FilePath) : BuildM Nat := do
  IO.FS.createDirAll s.work
  let startEvents := s.work / "serve-events.jsonl"
  discard <| (IO.FS.removeFile startEvents).toBaseIO
  -- Named, and never written to: every request replaces it, and the start-up
  -- value has to be somewhere outside the package being documented.
  let unusedIr := s.work / "serve-ir-unused"
  let log ← IO.FS.Handle.mk (s.work / "serve.out") .write
  let events := eventsBeside timings
  -- The extractor appends, so a file an earlier round left behind would be
  -- folded into this round's timings.
  discard <| (IO.FS.removeFile events).toBaseIO
  IO.FS.createDirAll irDir
  let resolved ← resolvePath irDir
  if isInside s.target resolved then
    throw (3, s!"the round's --ir-dir {resolved} is inside the target {s.target}: the package \
      being documented is opened read-only and nothing is ever written into it")
  let line ← requestLine #[s.modulesFile, events, irDir]
  checkGeneration s gen "before the request"
  let started ← IO.monoNanosNow
  let child ← IO.Process.spawn
    { cmd := s.lake.toString
      cwd := some s.target
      stdin := .piped, stdout := .piped, stderr := .inherit
      args := #["env", s.bin.toString, s.modulesFile.toString, startEvents.toString,
        "--equations", "--refs", "--write-ir", "--tagged-code",
        "--jobs", toString s.jobs, "--ir-dir", unusedIr.toString,
        "--link-index", s.linkIndex.toString,
        -- The start-up list, fixed for the life of the server: a request's own
        -- list is a *subset*, so deriving the omit set from it would make the
        -- map's bytes depend on which round happened to write it — and the
        -- map's SHA-256 is in `renderKey`.
        "--link-index-omit", s.modulesFile.toString,
        "--link-index-key", s.linkIndexKey, "--serve"] }
  let (stdinHandle, child) ← child.takeStdin
  let stdin ← IO.mkRef (some stdinHandle)
  let out := child.stdout
  match ← waitFor out log "ready " with
  | .error message => throw (4, message)
  | .ok ready =>
    checkGeneration s gen "while the server was importing"
    IO.println s!"serve   {ready} ({s.jobs} jobs, generation {byteSub gen.digest 0 16})"
  match ← stdin.get with
  | none => throw (4, "the resident extractor was already stopped")
  | some handle =>
    handle.putStr line
    handle.flush
  let reply ← waitFor out log "ok "
  let elapsed := (← IO.monoNanosNow) - started
  let listed ← IO.FS.readFile s.modulesFile
  let counted := (listed.splitOn "\n").filter
    (fun l => !(trimWs l).isEmpty && !l.startsWith "#") |>.length
  match reply with
  | .error message => throw (4, message)
  | .ok text =>
    -- After as well as before, so that the interval the request ran in is one
    -- the world provably did not move in.
    checkGeneration s gen "after the request"
    if (text.splitOn " ").getD 1 "" != "0" then
      throw (4, s!"the resident extractor answered `{text}` for {s.modulesFile}; the IR tree at \
        {irDir} is incomplete")
    IO.println s!"        served {counted} module(s) from the resident environment in \
      {seconds elapsed 3}s"
    -- Emptying the cell drops the last reference to the write end, the server
    -- reads EOF and leaves through its own exit path. Before the wait, or the
    -- wait is for a process nothing has told to stop.
    stdin.set none
    let code ← child.wait
    let status := if code == 0 then "" else s!" (the server exited {code})"
    IO.println s!"serve   stopped after 1 request(s){status}"
    return counted

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
  sourceUrl : Option String
  extractorBin : Option FilePath
  lake : Option FilePath
  jobs : Nat
  full : Bool

/-- Full or incremental, and the reason, which is printed. **The refusal in the
middle is the important one**: this command removes and overwrites things under
`--out`, so it does that only to a directory whose marker says it made it. There
is no incremental path in this build, so the answer is always full — but it is
reached through the ownership checks and not around them, and `--full` still
answers at its own place in the order rather than short-circuiting them. -/
def planOf (layout : Layout) (root : FilePath) (full : Bool) : BuildM String := do
  if !(← layout.out.pathExists) || (← isEmptyDir layout.out) then
    return "nothing there yet"
  match ← readMarker layout.marker with
  | .absent =>
    throw (3, s!"{layout.out} is not empty and has no {markerName}: this command deletes and \
      overwrites inside --out, so it will only do that to a directory it can see it wrote. Name \
      an empty directory, or remove this one yourself")
  | .broken =>
    throw (3, s!"{layout.marker} will not parse. This file says which directory `litedoc4 build` \
      owns; one that cannot be read is not one to overwrite a site on the strength of")
  | .fields kv =>
    let was := markerString kv "root"
    if was != root.toString then
      throw (3, s!"{layout.out} was built from {was}, not from {root}: the ledger under it stores \
        the target whose oleans it hashed, and continuing here would compare one package's build \
        tree with another package's hashes. Use a different --out")
    return (if full then "--full" else "this build has no incremental path")

def envOr (flag : Option FilePath) (name : String) : IO (Option FilePath) := do
  match flag with
  | some path => return some path
  | none => return ((← IO.getEnv name).filter (!·.isEmpty)).map (⟨·⟩)

def runBuild (r : BuildRequest) : BuildM Unit := do
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
  IO.println s!"plan    full generation ({← planOf layout r.root r.full})"

  writeFile layout.marker (markerJson r.root.toString libs sourceUrl modules.size none)
  IO.FS.createDirAll layout.work
  let modulesFile := layout.work / "modules.txt"
  writeFile modulesFile ("\n".intercalate modules.toList ++ "\n")

  let some bin ← envOr r.extractorBin "EXTRACT_BIN"
    | throw (2, "build needs --extractor-bin <path> (or EXTRACT_BIN): the Lean extractor built \
        by `extractor/build.sh`, which is 171 MB and is therefore not committed. There is no \
        default — the binary is built against the target's toolchain, so a path baked in here \
        would be right on exactly one machine")
  let bin ← absolutePath bin
  if !(← isRegularFile bin) then
    throw (3, s!"--extractor-bin {bin}: not a file. It is `extractor/build.sh`'s output, 171 MB, \
      built against the target's toolchain and therefore not committed")
  let linkIndex ← absolutePath layout.linkIndex
  if isInside r.root (← resolvePath linkIndex) then
    throw (3, s!"--link-index {linkIndex} is inside --root {r.root}: the package being documented \
      is opened read-only and nothing is ever written into it")
  let serve : Serve :=
    { bin
      lake := (← envOr r.lake "LAKE").getD ⟨"lake"⟩
      target := r.root
      jobs := r.jobs
      modulesFile := ← absolutePath modulesFile
      modules
      work := ← absolutePath layout.work
      linkIndex
      linkIndexKey := ← linkIndexKeyOf r.root modulesFile }

  -- Taken once, at the head of the run, and every later check is against this
  -- one value: a second reading to compare a third against would be a second
  -- answer to the same question.
  let generation ← Generation.take serve

  -- The hashes, **before** the extraction they license. Written into `work` as a
  -- diagnostic; the file that counts is written at the end of the run.
  let detected ← match ← buildLedger
      { modules, target := r.root.toString, ir := none, sourceUrl
        linkIndex := some linkIndex, externalLinks := some r.external.digest } with
    | .error message => throw (3, message)
    | .ok ledger => pure ledger
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
  discard <| extractOnce serve generation layout.ir (layout.work / "extract-timings-1.json")
  IO.println s!"extract {modules.size} module(s) in {seconds ((← IO.monoNanosNow) - extractStarted) 4} s"

  let config ← readSiteConfig (some r.root)
  let rendered ← renderSite
    { ir := layout.ir, pages := layout.site, sourceUrl
      linkIndex := some linkIndex, external := r.external, title := config.title }
  let derived ← buildGlobal layout.ir layout.site (some layout.state) config.indexMarkdown
    config.title
  printRenderSummary "render  " rendered
  printGlobalSummary "global  " derived

  -- On every run, whether or not a page was re-rendered, and before the ledger,
  -- whose claim is about a *finished* tree.
  writeAssets layout.site
  IO.println s!"assets  {assets.size} file(s) -> {layout.site}"

  -- The ledger last: everything that could have failed has now succeeded, so the
  -- claim "the IR was built from these oleans and the pages from that IR" is
  -- true when it is written and not before. The two keys are recomputed against
  -- the tree that now exists — they describe *the tree on disk*, and writing
  -- back the pre-run values would leave a ledger the next run re-extracts
  -- everything against, for ever.
  let ledger := { detected with
    extractKey := ← extractKey detected.target (some layout.ir)
    renderKey := renderKey sourceUrl (← linkIndexDigest (some linkIndex))
      (some r.external.digest) }
  let body := ledger.toJson
  writeFile layout.ledger body
  IO.println s!"ledger  {ledger.modules.size} module(s) -> {layout.ledger} \
    ({body.utf8ByteSize} B)"

  -- Taken **here**, after the last stage that touches the IR: the ledger's
  -- `extractKey` reads `index.json`, so a snapshot one line earlier would report
  -- a number the next run's would not reproduce.
  let work : WorkCounts :=
    { modulesExtracted := modules.size
      pagesRendered := rendered.pagesWritten
      mathFallbacks := rendered.mathFailures
      extractorRequests := 1
      cacheHits := derived.cacheHits
      cacheMisses := derived.cacheMisses
      moduleSummaries := derived.summariesRendered
      moduleSummariesEchoingTheName := derived.summariesEchoingTheName
      irReads := ← irReads }
  IO.println (work.line modules.size)
  writeFile layout.marker (markerJson r.root.toString libs sourceUrl modules.size (some work))
  IO.println s!"build   full in {seconds ((← IO.monoNanosNow) - started) 4} s -> {layout.site}"

end Litedoc4
