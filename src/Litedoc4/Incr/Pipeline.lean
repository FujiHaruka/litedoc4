/- The rounds `build` runs over an IR tree it already holds: detect, then
extract → ownership → merge until no module is stale.

```text
 1 detect     checkLedger        changed / removed / render-all
 2 extract    the resident extractor, the only external process
 3 ownership  ownership   ┐ who points at a name that moved
 4 merge      merge       ┘ rounds, bounded by `maxRounds`
```

The stages are library calls, not subprocesses: a pipeline made of processes
would have to serialise every intermediate answer through a file. The one
external process is the extractor, because it is Lean.

# The ordering constraints

- **`ownership` before `merge`** — merge overwrites the base IR's idea of who
  owns each name, which is ownership's only input.
- **extract → ownership → merge is a loop**, bounded by `maxRounds`.

**This does not rewrite the ledger**: a stage that answers a question must not
move the state its answer was about, or a caller that stops on the answer has
already lost. It hands the ledger `detect` computed back to its caller, which
writes it after the last step that can fail. -/
import Litedoc4.Config
import Litedoc4.Incr.Merge
import Litedoc4.Incr.Ownership
import Litedoc4.Incr.Resident
import Litedoc4.Packages
import Litedoc4.Store

open System

namespace Litedoc4

/-! ## The source URL -/

def sourceUrlBroken : String :=
  "the acceptance oracle normalises `/blob/[0-9a-f]{40}/` and nothing else, so with a tag or a \
   branch name here every page keeps its revision in the compared bytes and the score drops \
   3.1103 points with no diagnostic (measured)"

def splitOnce (s sep : String) : Option (String × String) :=
  match s.splitOn sep with
  | [] | [_] => none
  | head :: rest => some (head, sep.intercalate rest)

/-- Checked here and nowhere else: this is the path that runs on every commit,
and the only place a real revision enters. -/
def checkSourceUrl (url : String) : Option String :=
  match splitOnce url "/blob/" with
  | none => some s!"--source-url has no `/blob/` segment: {url}\n  {sourceUrlBroken}"
  | some (_, rest) =>
    let rev := (rest.splitOn "/").headD rest
    if isFortyHex rev then none
    else some s!"--source-url must carry a 40-digit lower-case hex revision after `/blob/`, not \
      `{rev}` ({rev.length} character(s))\n  {sourceUrlBroken}"

/-! ## The resident extractor's paths -/

/-- The token the extractor checks the dependency map's `.key` sidecar against
before deciding whether the map on disk can be reused.

The map is a function of four inputs: the extractor that writes it
(`Extract.lean`'s `writeLinkIndex`), the imported module set, those modules'
oleans, and the omit list. The extractor checks the module set itself, out of the
environment it is holding; this covers the rest — the oleans through two of
`extractKey`'s values, the omit list **by its bytes, not its path**, because it
changes when the package gains or loses a module and a path is not an identity,
and the extractor by the identity it prints, in clear after the digest so that a
sidecar says which extractor wrote the map beside it.

`irSchemaVersion` and `irGenerator` are deliberately left out: they describe *the
IR*, which the map is not, and they are read out of `<ir>/index.json`, which a
first-ever build has not written yet — including them made the first incremental
build after a first-ever build rewrite the map for nothing (measured
2026-08-17). -/
def linkIndexKeyOf (package omitList : FilePath) (extractor : Store.ExtractorIdentity) :
    IO String := do
  let key ← extractKey package.toString none
  let mut text := ""
  for name in ["leanToolchain", "manifestSha256"] do
    match keySetGet key name with
    | none => throw (IO.userError s!"extractKey has no `{name}`: the reuse token cannot be built")
    -- `name=value\n`, one per line: neither half can contain a newline (a
    -- toolchain string and a hex digest), so the concatenation is unambiguous
    -- without escaping.
    | some value => text := text ++ name ++ "=" ++ value ++ "\n"
  -- A blank line ends the key half, so that no rearrangement of its characters
  -- can produce the same digest as a different omit list.
  let digest := sha256Hex ((text ++ "\n").toUTF8 ++ (← IO.FS.readBinFile omitList))
  return s!"{digest} {extractor.key}"

structure ServeRequest where
  bin : FilePath
  extractor : Store.ExtractorIdentity
  /-- The package being documented. -/
  target : FilePath
  /-- `--lake`, or `$LAKE`, or the name on PATH. -/
  lake : Option FilePath
  jobs : Nat
  modulesFile : FilePath
  modules : Array String
  work : FilePath
  /-- Where the server writes the dependency map, or `none` to write none. -/
  linkIndex : Option FilePath
  noEquationsUnder : Option (Array String) := none
  writeReuseKeys : Bool := false

def noEquationsUnderFor (given : Option (Array String)) (target : FilePath) : IO (Array String) :=
  match given with
  | some given => pure given
  | none => return (← readConfigKeys target).noEquationsUnder

/-- `lake` defaults to the name on PATH, and it is not an exception to "no
default paths": elan's shim under that name is what picks the toolchain the
target pins, so `~/.elan/bin/lake` would be the more specific and the more
fragile of the two. -/
def serveOptions (r : ServeRequest) : BuildM Serve := do
  let bin := r.bin
  let target ← match ← (IO.FS.realPath r.target).toBaseIO with
    | .error e => throw (3, s!"--target {r.target}: {e}")
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
  -- Computed here, once: a second spelling of a key that has to compare equal
  -- across runs is a second answer.
  let linkIndexKey ← match linkIndex with
    | none => pure none
    | some _ => pure (some (← linkIndexKeyOf target modulesFile r.extractor))
  let noEquationsUnder ← noEquationsUnderFor r.noEquationsUnder target
  return { bin := ← absolutePath bin
           lake := (← envOr r.lake "LAKE").getD ⟨"lake"⟩
           target, jobs := r.jobs, modulesFile, modules := r.modules
           work := ← absolutePath r.work, linkIndex, linkIndexKey, noEquationsUnder
           writeReuseKeys := r.writeReuseKeys }

/-- Whether the round loop runs again.

The second clause is the one that would be silent: **a run whose only work is a
deletion has nothing to re-extract**, and without it the loop never starts, the
merge that drops the module from `index.json` never happens, and the page stays
on the site for ever with every count in the marker reading zero. It is `rounds
== 0` and not "there are deletions" because the deletions are folded into the
first round's merge and passing them again would be a no-op. -/
def anotherRound (roundIn : Array String) (roundsSoFar : Nat) (removed : Array String) : Bool :=
  !roundIn.isEmpty || (roundsSoFar == 0 && !removed.isEmpty)

structure ExtractionInput where
  ir : FilePath
  ledger : FilePath
  work : FilePath
  modules : Array String
  sourceUrl : String
  linkIndex : FilePath
  externalDigest : String
  bibliography : Option String
  maxRounds : Nat

structure Rounds where
  check : CheckSummary
  seen : Array String
  irChanged : Array String
  rounds : Nat
  staleFound : Nat
  extractNanos : Nat
  ownershipNanos : Nat
  mergeNanos : Nat
  started : Nat
  detectDone : Nat
  roundsDone : Nat

def runRounds (o : ExtractionInput) (extractor : Resident) : BuildM Rounds := do
  let started ← IO.monoNanosNow
  IO.FS.createDirAll o.work
  let changedFile := o.work / "changed.txt"
  let removedFile := o.work / "removed.txt"
  let seenFile := o.work / "seen.txt"

  -- `ir` is not optional: without it the ledger cannot see the IR schema or the
  -- generator id, and a schema bump would leave every module stale with the
  -- ledger reporting "0 changed".
  let check ← checkLedger
      { ledger := o.ledger
        -- The ledger's own algorithm: two algorithms produce incomparable
        -- hashes, so overriding here would report every module as changed.
        algorithm := none
        modules := some o.modules, ir := some o.ir, sourceUrl := o.sourceUrl
        linkIndex := some o.linkIndex
        externalLinks := some o.externalDigest
        bibliography := o.bibliography
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
      discard <| extractor.extract roundInFile incIr (o.work / s!"extract-timings-{rounds}.json")
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
  -- whole IR, and holding 3 GB across it buys nothing.
  extractor.stop
  writeLines seenFile seen
  writeLines (o.work / "ir-changed.txt") irChanged
  let roundsDone ← IO.monoNanosNow
  return { check, seen, irChanged, rounds, staleFound, extractNanos, ownershipNanos, mergeNanos
           started, detectDone, roundsDone }

end Litedoc4
