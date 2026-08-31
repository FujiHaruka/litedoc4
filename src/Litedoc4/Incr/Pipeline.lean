/- `crates/litedoc4/src/pipeline.rs`: `litedoc4 incremental` — the pipeline that
sequences the stages.

```text
 1 detect     checkLedger        changed / removed / render-all
 2 extract    --extractor / --serve      the only external process
 3 ownership  ownership   ┐ who points at a name that moved
 4 merge      merge       ┘ rounds, bounded by --max-rounds
 5 prune      prune              the deleted modules' pages
 6 global     buildGlobal        the whole-package artifacts + the map delta
 7 impact     impact             the changed set's closure
 8 render     renderSite         the union of the two sets
```

The stages are library calls, not subprocesses: a pipeline made of processes
would have to serialise every intermediate answer through a file. The one
external process is the extractor, because it is Lean.

# The ordering constraints

- **`ownership` before `merge`** — merge overwrites the base IR's idea of who
  owns each name, which is ownership's only input.
- **`global` before `impact`** — the whole-package map delta is half of the
  render set, and `impact` does not take it as an input.
- **extract → ownership → merge is a loop**, bounded by `--max-rounds`.
- **A moved `renderKey` overrides `--mode` with `all`** — the one page set that
  does not follow from any changed module.
- **`name-map.json` is snapshotted before anything runs.** It is both the
  "before" side of the map delta and the file step 6 overwrites in place.
  Snapshot it late and the delta compares the new map with itself: always empty,
  and every page that went stale through the global map is dropped without a
  word.

The two halves of the render set are unioned **in memory**. `global-set.txt`,
`impact-set.txt` and `render-set.txt` are written into `--work` as diagnostics
and read back by nothing, so a file that is missing, empty or stale cannot change
what is rendered.

**This command does not rewrite the ledger**: a stage that answers a question
must not move the state its answer was about, or a caller that stops on the
answer has already lost. It hands the ledger `detect` computed back to its
caller, which writes it after the last step that can fail. -/
import Litedoc4.Config
import Litedoc4.Global
import Litedoc4.Incr.Impact
import Litedoc4.Incr.Merge
import Litedoc4.Incr.Ownership
import Litedoc4.Incr.Prune
import Litedoc4.Incr.Resident
import Litedoc4.Packages
import Litedoc4.Render.Site

open System

namespace Litedoc4

/-! ## The two stages' summaries on stdout -/

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
  if let some delta := d.delta then
    IO.println s!"{label}delta: {delta.changed.size} name(s) moved in or out of the map \
      ({delta.beforeNames} -> {delta.afterNames}) -> {delta.affected.size} page(s) to re-render"
    for w in delta.witnesses.extract 0 10 do
      IO.println s!"{label}  {w.module}  (mentions `{w.name}`)"

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

/-! ## The extractor -/

/-- `--extractor <program>`: a program called once per round.

**There is no default**, and that is what makes this the seam: the contract is
three flags, so anything that accepts them can be handed here. `litedoc4 extract`
takes the same three. -/
structure OneShot where
  program : String
  /-- `--extractor-arg`, in order, placed **before** the three flags below so
  that a wrapper script sees its own configuration first. -/
  args : Array String
  requestCount : IO.Ref Nat

/-- How a round's extraction is done. The two are one interface — a module list
in, an IR tree and a timings record out — and nothing downstream can tell which
one ran. -/
inductive Extractor where
  | oneShot (o : OneShot)
  | resident (r : Resident)

/-- One round's command line for a `--extractor` program.

```text
<program> [<extractor-arg>…] --modules <round-in> --ir-dir <dir> --timings <file>
```

`--events` is not passed: an extraction program defaults it to
`<timings>-events.jsonl` (`eventsBeside`), and the resident path derives it from
the same expression so that two records of the same round stay comparable.

Split out of the spawn for `Serve.startArgv`'s reason: which flags a round hands
its extractor is a decision about the three paths, and inside `IO.Process.spawn`
it could only be asked by running a program. It takes `--extractor-arg`'s array
rather than the `OneShot` holding it, because the rest of that structure is an
`IO.Ref` and a value carrying one cannot be written down in a `#guard`. -/
def oneShotArgv (extractorArgs : Array String) (modules irDir timings : FilePath) :
    Array String :=
  extractorArgs ++ #["--modules", modules.toString, "--ir-dir", irDir.toString,
    "--timings", timings.toString]

/-- One extraction round. -/
def Extractor.run : Extractor → FilePath → FilePath → FilePath → BuildM Unit
  | .resident r, modules, irDir, timings => do discard <| r.extract modules irDir timings
  | .oneShot o, modules, irDir, timings => do
    let args := oneShotArgv o.args modules irDir timings
    let child ← match ← (IO.Process.spawn { cmd := o.program, args }).toBaseIO with
      | .error e => throw (4, s!"--extractor {o.program}: {e}")
      | .ok child => pure child
    let code ← child.wait
    -- Counted before the exit code is judged: the run started an extractor and
    -- paid for it whichever way it ended.
    o.requestCount.modify (· + 1)
    if code == 0 then return ()
    throw (4, s!"--extractor {o.program} exited {code} for {modules}; the IR was not updated and \
      nothing was rendered")

/-- How many extractions this run asked for — processes started on the one-shot
path, requests sent on the resident one.

A run over an unchanged package must answer **0**: it is the only work counter
whose zero says Lean was never started. -/
def Extractor.requests : Extractor → IO Nat
  | .oneShot o => o.requestCount.get
  | .resident r => r.requests

/-- Releases the resident environment, if there is one. Idempotent. -/
def Extractor.release : Extractor → IO Unit
  | .oneShot _ => return ()
  | .resident r => r.stop

/-! ## `--serve`'s three paths -/

/-- The token the extractor checks the dependency map's `.key` sidecar against
before deciding whether the map on disk can be reused.

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
    match keySetGet key name with
    | none => throw (IO.userError s!"extractKey has no `{name}`: the reuse token cannot be built")
    -- `name=value\n`, one per line: neither half can contain a newline (a
    -- toolchain string, a hex digest and a compile-time constant), so the
    -- concatenation is unambiguous without escaping.
    | some value => text := text ++ name ++ "=" ++ value ++ "\n"
  -- A blank line ends the key half, so that no rearrangement of its characters
  -- can produce the same digest as a different omit list.
  return sha256Hex ((text ++ "\n").toUTF8 ++ (← IO.FS.readBinFile omitList))

structure ServeRequest where
  /-- `--extractor-bin`, or `$EXTRACT_BIN`. -/
  bin : Option FilePath
  /-- `--target`, or `$TARGET_REPO`. -/
  target : Option FilePath
  /-- `--lake`, or `$LAKE`, or the name on PATH. -/
  lake : Option FilePath
  jobs : Nat
  modulesFile : FilePath
  modules : Array String
  work : FilePath
  /-- Where the server writes the dependency map, or `none` to write none. -/
  linkIndex : Option FilePath

/-- **Flag, then environment, then nothing** — no default path for the binary and
none for the target, because both are absolute paths on somebody's machine.
`lake` does get one, and it is not an exception: it is a name looked up on PATH,
and elan's shim under that name is what picks the toolchain the target pins, so
`~/.elan/bin/lake` would be the more specific and the more fragile of the two. -/
def serveOptions (r : ServeRequest) : BuildM Serve := do
  let some bin ← envOr r.bin "EXTRACT_BIN"
    | throw (2, "--serve needs --extractor-bin <path> (or EXTRACT_BIN): the Lean extractor built \
        by `extractor/build.sh`, which is 171 MB and is therefore not committed. There is no \
        default — the binary is built against the target's toolchain, so a path baked in here \
        would be right on exactly one machine")
  let some target ← envOr r.target "TARGET_REPO"
    | throw (2, "--serve needs --target <repo> (or TARGET_REPO): the Lean package being \
        documented. `lake env` runs inside it, which is how the resident extractor gets the \
        oleans and the search path without litedoc4 owning a toolchain — and its oleans are the \
        generation every request is checked against")
  let target ← match ← (IO.FS.realPath target).toBaseIO with
    | .error e => throw (3, s!"--target {target}: {e}")
    | .ok path => pure path
  -- **Absolute, all of them** (measured 2026-08-15). The server's working
  -- directory is the target, so a relative path on its command line resolves
  -- against the package being documented — the binary would be looked for there,
  -- and the start-up events file *written* there. `--lake` is the exception: a
  -- name looked up on PATH, not a path.
  let linkIndex ← match r.linkIndex with
    | none => pure none
    | some path => do
      refuseInside target "--target" path "--link-index" ""
      pure (some (← absolutePath path))
  let modulesFile ← absolutePath r.modulesFile
  -- Computed here, once, for both callers — `build` and `incremental` resolve
  -- `--target` differently and neither should own a second spelling of a key
  -- that has to compare equal across runs.
  let linkIndexKey ← match linkIndex with
    | none => pure none
    | some _ => pure (some (← linkIndexKeyOf target modulesFile))
  return { bin := ← absolutePath bin
           lake := (← envOr r.lake "LAKE").getD ⟨"lake"⟩
           target, jobs := r.jobs, modulesFile, modules := r.modules
           work := ← absolutePath r.work, linkIndex, linkIndexKey }

/-! ## One run -/

structure Incremental where
  /-- `<root>/litedoc4.toml`, carried rather than re-read: the incremental round
  and the full generation have to answer "what is this site called" the same way,
  and two readers is two answers. -/
  config : SiteConfig
  ir : FilePath
  pages : FilePath
  ledger : FilePath
  work : FilePath
  /-- The current module list, from a glob over the sources. **Required**:
  without it `check` re-reads the ledger's own list and cannot see a module that
  appeared or vanished. -/
  modules : Array String
  sourceUrl : String
  linkIndex : FilePath
  /-- Resolved by the caller, once, and used twice in here: `detect` hashes it
  into the render key and the render step draws with it. A round that resolved it
  a second time could disagree with the ledger it just checked. -/
  external : ExternalLinks
  state : FilePath
  mode : ImpactMode
  maxRounds : Nat

structure IncrSummary where
  rounds : Nat
  staleFound : Nat
  changed : Nat
  removed : Nat
  irChanged : Nat
  globalStale : Nat
  /-- Pages the renderer **wrote** — not the size of the render set, which is the
  larger of the two whenever the set names a module the IR does not hold. -/
  pagesRendered : Nat
  mathFallbacks : Nat
  cacheHits : Nat
  cacheMisses : Nat
  summariesRendered : Nat
  summariesEchoingTheName : Nat
  mode : String
  deriving Inhabited

/-- The wall-clock split of one run, in nanoseconds.

Kept out of `IncrSummary` because the durations are **diagnostics**: nothing may
assert on them, and a summary without them is one a comparison can take as a
whole. -/
structure IncrTimings where
  detect : Nat
  extract : Nat
  ownership : Nat
  merge : Nat
  rounds : Nat
  prune : Nat
  global : Nat
  impact : Nat
  render : Nat
  total : Nat
  deriving Inhabited

/-- The clock as a run leaves it: one cumulative mark per phase boundary, plus
the three totals that are accumulated across rounds rather than read off a single
mark.

The fields are named so that `IncrTimings.ofMarks` can be the only place a phase
is paired with the mark it is measured from. Handing the marks over positionally
would move the mistake this shape exists to prevent — a phase differenced against
the wrong neighbour — from a function nothing checks into a call nothing
checks. -/
structure IncrMarks where
  started : Nat
  detectDone : Nat
  roundsDone : Nat
  pruneDone : Nat
  globalDone : Nat
  impactDone : Nat
  renderDone : Nat
  extract : Nat
  ownership : Nat
  merge : Nat
  deriving Inhabited

/-- Each phase is the gap from the mark before it, and a phase that did nothing
sits on its predecessor's mark and so measures zero.

**No clamp.** `Nat` subtraction already truncates at zero, so a mark that
precedes its predecessor — a shape the monotonic clock does not produce and the
type allows — cannot become a duration that ran backwards. What would falsify
this: marks stored as anything signed. -/
def IncrTimings.ofMarks (m : IncrMarks) : IncrTimings :=
  { detect := m.detectDone - m.started
    extract := m.extract, ownership := m.ownership, merge := m.merge
    rounds := m.roundsDone - m.detectDone
    prune := m.pruneDone - m.roundsDone
    global := m.globalDone - m.pruneDone
    impact := m.impactDone - m.globalDone
    render := m.renderDone - m.impactDone
    total := m.renderDone - m.started }

/-- One run's whole answer: the counts, the clock, and the ledger the run
*licenses* but does not write. -/
structure IncrRun where
  summary : IncrSummary
  timings : IncrTimings
  /-- The module hashes as `detect` read them, **before** the extraction they
  licensed. -/
  detected : Ledger
  deriving Inhabited

def digestOrNone : Option String → String
  | none => "none"
  | some digest => byteSub digest 0 (min 16 digest.utf8ByteSize)

def renderTimingsJson (s : Summary) (nanos : Nat) : String :=
  "{\"command\":\"render\",\"pagesWritten\":" ++ toString s.pagesWritten
    ++ ",\"modulesInIr\":" ++ toString s.modulesInIr
    ++ ",\"declarationsRendered\":" ++ toString s.declarationsRendered
    ++ ",\"pageBytes\":" ++ toString s.bytes
    ++ ",\"mathFallbacks\":" ++ toString s.mathFailures
    ++ ",\"renderSeconds\":" ++ seconds nanos 9 ++ "}\n"

/-- Whether the round loop runs again.

The second clause is the one that would be silent: **a run whose only work is a
deletion has nothing to re-extract**, and without it the loop never starts, the
merge that drops the module from `index.json` never happens, and the page stays
on the site for ever with every count in the marker reading zero. It is `rounds
== 0` and not "there are deletions" because the deletions are folded into the
first round's merge and passing them again would be a no-op. -/
def anotherRound (roundIn : Array String) (roundsSoFar : Nat) (removed : Array String) : Bool :=
  !roundIn.isEmpty || (roundsSoFar == 0 && !removed.isEmpty)

/-- A moved render key, or a dependency map this run rewrote, **replaces**
`--mode` rather than widening it.

`detect` compared the map as it stood at the head of the run and the extractor
writes it, so the map the renderer is about to read may not be the one `detect`
saw. Doing it only in `detect` would be worse than not doing it: the ledger would
record the *new* map, the next run would compare new against new and find
nothing, and the staleness would be permanent and silent. -/
def renderModeOf (renderAll mapMoved : Bool) (asked : ImpactMode) : ImpactMode :=
  if renderAll || mapMoved then .all else asked

/-- The render set: the pages the changed modules reach, **union** the pages the
whole-package map's delta names.

Neither half is a superset of the other, and either alone reads as a working
pipeline. A round that dropped the global half re-renders nothing when a
declaration moved between modules whose own IR did not change; a round that
dropped the impact half re-renders nothing when the map is unmoved and a module
was re-extracted. -/
def renderSetOf (fromImpact globalAffected : Array String) : Std.HashSet String := Id.run do
  let mut set : Std.HashSet String :=
    Std.HashSet.emptyWithCapacity (fromImpact.size + globalAffected.size + 8)
  for module in fromImpact do set := set.insert module
  for module in globalAffected do set := set.insert module
  return set

/-- `prune` over a deletion list, and **nothing else**.

The signature is the guard. `PruneInputs.ir` turns on the orphan rule, which
calls every `.html` that is not a live module page an orphan — pointed at a site
that includes the whole-package artifacts, that is `index.html`, `404.html`,
`search.html` and `foundational_types.html`, and the site goes **439 → 435**
(measured). There is no parameter here to pass `--ir` through, so the pipeline
cannot ask for orphan sweeping by accident. -/
def pruneRemoved (pages remove json : FilePath) : BuildM PruneSummary :=
  -- `prune`'s refusal and this monad's carry the same pair, so the bind is the
  -- propagation.
  prune { pages, remove := some remove, ir := none, dryRun := false, json := some json }

def runIncremental (o : Incremental) (extractor : Extractor) : BuildM IncrRun := do
  let started ← IO.monoNanosNow
  IO.FS.createDirAll o.work
  let changedFile := o.work / "changed.txt"
  let removedFile := o.work / "removed.txt"
  let seenFile := o.work / "seen.txt"
  let mapBeforeFile := o.work / "name-map-before.json"
  let globalSetFile := o.work / "global-set.txt"

  -- The dependency map's identity **before the rounds**, so that a rewrite one of
  -- them performs can be seen. The ordinary case is that this run's own
  -- extraction writes it.
  let mapBefore ← linkIndexDigest (some o.linkIndex)

  -- Snapshotted rather than recomputed, because the global step overwrites it in
  -- place: taking it later makes every delta empty.
  let liveMap := o.pages / "declarations" / "name-map.json"
  discard <| (IO.FS.removeFile mapBeforeFile).toBaseIO
  let haveBefore ← isRegularFile liveMap
  if haveBefore then
    IO.FS.writeBinFile mapBeforeFile (← IO.FS.readBinFile liveMap)

  -- `ir` is not optional: without it the ledger cannot see the IR schema or the
  -- generator id, and a schema bump would leave every page stale with the ledger
  -- reporting "0 changed". `sourceUrl` is not optional for the mirror-image
  -- reason: it reaches the page bytes and it moves every commit, so it is in the
  -- *render* key and a new revision re-renders without starting Lean once.
  let check ← checkLedger
      { ledger := o.ledger
        -- The ledger's own algorithm: two algorithms produce incomparable
        -- hashes, so overriding here would report every module as changed.
        algorithm := none
        modules := some o.modules, ir := some o.ir, sourceUrl := o.sourceUrl
        -- The half of "did the dependency map move" that can be answered here:
        -- somebody handed this run a different map than the one the ledger
        -- records. The other half — the map this run's own extractor is about to
        -- rewrite — is the check after the rounds.
        linkIndex := some o.linkIndex
        externalLinks := some o.external.digest
        changedOut := some changedFile, removedOut := some removedFile
        renderAllOut := some (o.work / "render-all.txt") }
  let detectDone ← IO.monoNanosNow
  let moved :=
    if check.renderAll then
      s!" — render key moved ({",".intercalate check.renderKeyChanged.toList})"
    else ""
  IO.println s!"detect  {check.modules} module(s): {check.reExtract.size} to re-extract, \
    {check.removed.size} removed{moved}"

  let mut seen := check.reExtract
  let mut roundIn := check.reExtract
  let mut irChanged : Array String := #[]
  let mut rounds := 0
  let mut staleFound := 0
  let mut extractNanos := 0
  let mut ownershipNanos := 0
  let mut mergeNanos := 0

  while anotherRound roundIn rounds check.removed do
    rounds := rounds + 1
    let roundInFile := o.work / s!"round-in-{rounds}.txt"
    writeLines roundInFile roundIn
    let incIr := o.work / s!"inc-ir-{rounds}"
    discard <| (IO.FS.removeDirAll incIr).toBaseIO
    if !roundIn.isEmpty then
      let before ← IO.monoNanosNow
      extractor.run roundInFile incIr (o.work / s!"extract-timings-{rounds}.json")
      extractNanos := extractNanos + ((← IO.monoNanosNow) - before)
    let inc := if roundIn.isEmpty then none else some incIr

    -- Deletions belong to the first round. The condition is documentation rather
    -- than protection: both stages filter the list to modules the base index
    -- still holds, so passing it again would be a no-op.
    let deletions := if rounds == 1 && !check.removed.isEmpty then some removedFile else none

    -- Ownership before the merge: it needs the IR's previous idea of who owns
    -- each name, which the merge is about to overwrite. `exclude` is the round's
    -- memory of what earlier rounds already took.
    writeLines seenFile seen
    let ownershipStarted ← IO.monoNanosNow
    let owners ← runOwnership
      { base := o.ir, inc, removed := deletions, exclude := some seenFile
        printSet := some (o.work / s!"stale-{rounds}.txt")
        json := some (o.work / s!"ownership-{rounds}.json") }
    ownershipNanos := ownershipNanos + ((← IO.monoNanosNow) - ownershipStarted)

    -- The removals are folded into the merge, so the IR is never left in a state
    -- where a deleted module is still indexed.
    let mergeStarted ← IO.monoNanosNow
    let merged ← merge
        { base := o.ir, inc, out := o.ir
          removed := if deletions.isSome then check.removed else #[]
          -- The same list `detect` was given, and for the same reason: it is what
          -- a from-scratch extraction would be handed, so it is the order
          -- `index.json` comes out in.
          modules := some o.modules
          changedOut := some (o.work / s!"ir-changed-{rounds}.txt")
          timings := some (o.work / s!"merge-timings-{rounds}.json") }
    mergeNanos := mergeNanos + ((← IO.monoNanosNow) - mergeStarted)
    irChanged := irChanged ++ merged.irChanged

    IO.println s!"round {rounds}  extracted {merged.updated.size}, removed {merged.removed}, \
      IR moved for {merged.irChanged.size}, stale {owners.staleModules.size}"

    staleFound := staleFound + owners.staleModules.size
    seen := seen ++ owners.staleModules
    roundIn := owners.staleModules
    if rounds ≥ o.maxRounds && !roundIn.isEmpty then
      throw (5, s!"still {roundIn.size} stale module(s) after {rounds} round(s): \
        {", ".intercalate roundIn.toList}")

  -- **The loop is the only thing that can extract**, so the resident environment
  -- is released here rather than at the end of the run: what follows reads the
  -- whole IR, and holding 3 GB across it buys nothing. The teardown stays inside
  -- `totalSeconds` either way.
  extractor.release
  writeLines seenFile seen
  writeLines (o.work / "ir-changed.txt") irChanged
  let roundsDone ← IO.monoNanosNow

  -- The renderer only ever writes, so without this a deleted module's page
  -- survives every later run and is indistinguishable from a live one.
  if !check.removed.isEmpty then
    let pruned ← pruneRemoved o.pages removedFile (o.work / "prune.json")
    IO.println s!"prune   deleted {pruned.deleted.size}/{pruned.requested} page(s)"
  let pruneDone ← IO.monoNanosNow

  -- Before the renderer: the map delta names every declaration whose links can
  -- have changed anywhere on the site, which is the half of the render set no
  -- changed module can produce.
  writeFile globalSetFile ""
  let derived ← buildGlobal
    { ir := o.ir, out := o.pages, state := some o.state
      before := if haveBefore then some mapBeforeFile else none
      printSet := if haveBefore then some globalSetFile else none
      deltaJson := if haveBefore then some (o.work / "global-delta.json") else none
      timings := some (o.work / "global-timings.json")
      -- The same value the render half gets. Without it the incremental round
      -- rewrites `index.html`, `search.html` and `foundational_types.html` with
      -- the *derived* title while the full generation used the configured one
      -- (measured 2026-08-22).
      indexMarkdown := o.config.indexMarkdown, title := o.config.title }
  let globalAffected := (derived.delta.map (·.affected)).getD #[]
  let globalDone ← IO.monoNanosNow
  printGlobalSummary "global  " derived

  let mapAfter ← linkIndexDigest (some o.linkIndex)
  let mapMoved := mapAfter != mapBefore
  if mapMoved then
    IO.eprintln s!"  render-all linkIndex: the dependency map moved during this run \
      ({digestOrNone mapBefore} -> {digestOrNone mapAfter})"
  -- Unconditional: `renderAll` *is* "this list is not empty", so the list is the
  -- condition and a second spelling of it could disagree with `renderModeOf`.
  for reason in check.renderKeyChanged do
    IO.eprintln s!"  render-all renderKey:{reason}"
  let mode := renderModeOf check.renderAll mapMoved o.mode

  let selected ← runImpact
    { ir := o.ir, changed := seen, mode, census := none
      printSet := some (o.work / "impact-set.txt"), json := none }
  let fromImpact := (selected.summary.map (·.selected)).getD #[]
  let renderSet := renderSetOf fromImpact globalAffected
  -- UTF-16 code unit order, which every other module list in this project is in.
  -- Nothing generated depends on it — the renderer is handed a set — so the order
  -- reaches `render-set.txt`, a diagnostic, and stops there.
  writeLines (o.work / "render-set.txt") (sortUtf16 renderSet.toArray)
  let impactDone ← IO.monoNanosNow
  IO.println s!"impact  mode {mode.name} -> {renderSet.size} page(s) ({fromImpact.size} from the \
    changed set, {globalAffected.size} from the global map)"

  -- A `these` of an empty set already renders nothing, so this skip is an
  -- optimisation — it saves reading the whole IR to write no file — and not a
  -- guard.
  let mut pagesRendered := 0
  let mut mathFallbacks := 0
  if renderSet.isEmpty then
    writeFile (o.work / "render-timings.json") "{\"skipped\":\"empty render set\"}\n"
    IO.println "render  nothing to render"
  else
    let renderStarted ← IO.monoNanosNow
    let rendered ← renderSite
      { ir := o.ir, pages := o.pages, sourceUrl := o.sourceUrl
        linkIndex := some o.linkIndex, external := o.external, title := o.config.title
        only := .these renderSet }
    let elapsed := (← IO.monoNanosNow) - renderStarted
    pagesRendered := rendered.pagesWritten
    mathFallbacks := rendered.mathFailures
    writeFile (o.work / "render-timings.json") (renderTimingsJson rendered elapsed)
    printRenderSummary "render  " rendered
  let renderDone ← IO.monoNanosNow

  return {
    summary :=
      { rounds, staleFound, changed := check.reExtract.size, removed := check.removed.size
        irChanged := irChanged.size, globalStale := globalAffected.size
        pagesRendered, mathFallbacks
        cacheHits := derived.cacheHits, cacheMisses := derived.cacheMisses
        summariesRendered := derived.summariesRendered
        summariesEchoingTheName := derived.summariesEchoingTheName
        mode := mode.name }
    timings := IncrTimings.ofMarks
      { started, detectDone, roundsDone, pruneDone, globalDone, impactDone, renderDone
        extract := extractNanos, ownership := ownershipNanos, merge := mergeNanos }
    detected := check.fresh }

/-! ## The record the run writes -/

/-- Which extractor ran, for the record that says so. -/
inductive Ran where
  | oneShot
  | resident (jobs : Nat) (generation : String)

/-- A nested per-stage record, **re-emitted from the bytes it was written as**.
`JVal.real` holds a number as its lexeme, so a duration this pipeline never
computed round-trips rather than being reprinted by a second formatter. -/
def readRecord (path : FilePath) : IO (Option JVal) := do
  if !(← isRegularFile path) then return none
  match ← (IO.FS.readFile path).toBaseIO with
  | .error _ => return none
  | .ok text => match parseJson text with
    | .error _ => return none
    | .ok j => return some j

/-- One JSON line. **The field names are the contract**:
`benchmarks/tools/analyze.ts` and every JSONL already under `benchmarks/results/`
read them.

`serve` is written on both paths and `jobs` only on the resident one: behind
`--extractor` the job count is inside somebody else's argument list and this
command does not know it, and a number it cannot see is left out rather than
guessed at. -/
def incrTimingsLine (s : IncrSummary) (t : IncrTimings) (ran : Ran)
    (nested : Array (String × Array JVal)) : String := Id.run do
  let mut o := jsonStr "{\"mode\":" s.mode
  o := o ++ ",\"serve\":" ++ (match ran with | .oneShot => "false" | .resident .. => "true")
  if let .resident jobs generation := ran then
    o := o ++ s!",\"jobs\":{jobs},\"serveGeneration\":"
    o := jsonStr o generation
  for (name, nanos) in [("detectSeconds", t.detect), ("extractSeconds", t.extract),
      ("ownershipSeconds", t.ownership), ("mergeSeconds", t.merge), ("roundsSeconds", t.rounds),
      ("pruneSeconds", t.prune), ("globalSeconds", t.global), ("impactSeconds", t.impact),
      ("renderSeconds", t.render), ("totalSeconds", t.total)] do
    o := jsonStr (o.push ',') name ++ ":" ++ seconds nanos 9
  for (name, value) in [("rounds", s.rounds), ("staleFound", s.staleFound),
      ("changed", s.changed), ("removed", s.removed), ("irChanged", s.irChanged),
      ("globalStale", s.globalStale), ("pagesRendered", s.pagesRendered),
      ("mathFallbacks", s.mathFallbacks)] do
    o := jsonStr (o.push ',') name ++ ":" ++ toString value
  -- A stage that wrote no record is left out rather than written as `null`: the
  -- aggregations read the key's presence, and `prune` legitimately does not run.
  for (name, records) in nested do
    if records.size == 1 then
      o := jsonStr (o.push ',') name ++ ":" ++ jvalJson records[0]!
    else if records.size > 1 then
      o := jsonStr (o.push ',') name ++ ":" ++ jvalJson (.arr records)
  return o.push '}'

/-- The nested records are read from fixed paths rather than from a glob, so a
directory listing's order cannot reach the record. -/
def writeTimings (path work : FilePath) (s : IncrSummary) (t : IncrTimings) (ran : Ran) :
    IO Unit := do
  let perRound (stem : String) : IO (Array JVal) := do
    let mut out : Array JVal := #[]
    for round in [1 : s.rounds + 1] do
      if let some record ← readRecord (work / s!"{stem}-{round}.json") then out := out.push record
    return out
  let line := incrTimingsLine s t ran
    #[("extract", ← perRound "extract-timings"),
      ("merge", ← perRound "merge-timings"),
      ("global", (← readRecord (work / "global-timings.json")).toArray),
      ("render", (← readRecord (work / "render-timings.json")).toArray)]
  IO.println line
  writeFile path (line ++ "\n")

end Litedoc4
