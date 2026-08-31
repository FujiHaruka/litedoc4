/- `crates/litedoc4/src/resident.rs`: **one Lean environment, many extractions**,
and `crates/litedoc4/src/extract.rs`'s `extractArgv` / `foldTimings` / `eventsBeside`
/ the containment guard, which both extraction paths share.

```text
lake env <extract> <modules.txt> <events.jsonl> --equations --refs
         --write-ir --tagged-code --jobs N --ir-dir <unused> --serve

  stdin   <modules.txt> <events.jsonl> <ir-dir>      one request per line
  stdout  ready <ns> <envModules> <targets>          once, at start-up
          ok <exit code> <ns>                        one per request
```

# The request channel is a pipe

The server's loop ends on EOF (`Extract.lean:2747`), and the channel is the
child's **stdin pipe**, held in a reference cell for as long as the server is
wanted. Lean has no explicit close for a handle, so emptying the cell drops the
last reference and the finaliser closes the fd. What that buys:

> **A pipe cannot outlive its writer.** However this process dies, the kernel
> closes the write end, the server reads EOF and returns 0 through its own exit
> path. The 3 GB process cannot be orphaned by a failure of the driver, because
> the thing that keeps it alive *is* the driver.

What would falsify the cell: a `Handle.close` in core, which would make it an
indirection with nothing behind it.

# Started lazily, at the first request

A run that extracts *nothing* — the commonest answer the incremental pipeline
gives — never pays 3 GB and an import for a server it does not speak to. The
generation is taken at the head of the run either way, so the guard covers the
delay.

# There is no `--serve-dir`: a server this process does not own

**Correctness comes from the server's olean generation, never from the round
number** (measured, stage 6a). A server imported *before* an edit answers with
the pre-edit owner of every name that moved, and with such a server no round is
safe, including round 2. `Generation` is what makes that checkable rather than
argued: Lake's own content hash of every olean of every module in the start-up
list, over the same files in the same order the ledger hashes. It is taken once
at the head of the run and compared when the server reports `ready` and before
and after every request.

# Two traps, both measured

1. **`--ir-dir` is required at start-up even though every request overrides it**
   (measured 2026-08-15): the extractor refuses `--write-ir` without one
   (`Extract.lean:2778-2782`), while a request's third field replaces it
   (`Extract.lean:2753`). The value passed here names nothing that is written.
2. **stderr is inherited, exactly as the one-shot path inherits it.** A Lean
   error has to reach the caller, and the two extraction paths have to be
   diagnosable the same way. -/
import Litedoc4.Duration
import Litedoc4.Fs
import Litedoc4.Json
import Litedoc4.JsonWrite
import Litedoc4.Ledger

open System

namespace Litedoc4

/-- The exit code a refusal carries, beside what to say. 1 is "this run did not
finish", 2 is a usage error and prints the usage text, 3 is "the world and the
files disagree", 4 is the extractor's, so that a caller sees the same code
whichever half produced it, and 5 is the round bound. -/
abbrev BuildM := ExceptT (UInt32 × String) IO

/-- Flag, then environment, then nothing. An empty variable counts as unset:
`TARGET_REPO=` in a wrapper script is how a shell spells "I did not set this",
and taking it literally would make the target the filesystem root. -/
def envOr (flag : Option FilePath) (name : String) : IO (Option FilePath) := do
  match flag with
  | some path => return some path
  | none => return ((← IO.getEnv name).filter (!·.isEmpty)).map (⟨·⟩)

/-- Refuses `candidate` if it resolves inside `container`.

**The only copy of this decision** — the round's `--ir-dir`, `--link-index` and
`build`'s `--out` all call it rather than restate it. Resolved with
`resolvePath`, not compared as given: `/tmp/x` and `/private/tmp/x` are one
directory on this platform, and a guard that says otherwise can be walked around
by spelling. -/
def refuseInside (container : FilePath) (containerFlag : String) (candidate : FilePath)
    (what extra : String) : BuildM Unit := do
  let resolved ← resolvePath candidate
  if !isInside container resolved then return ()
  throw (3, s!"{what} {resolved} is inside {containerFlag} {container}: the package being \
    documented is opened read-only and nothing is ever written into it{extra}")

/-! ## The server's configuration -/

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
  /-- Where the server writes the dependency closure's `name -> module` map, or
  `none` to write none.

  **Start-up configuration, not a request field, and that is the extractor's
  shape rather than a choice here**: the serve loop builds every request's `cfg`
  from the start-up one, so a map path given here is written once per request.
  That is acceptable because every round writes the same bytes — the map is
  derived from the *environment*, which a resident server imports once and never
  reloads. -/
  linkIndex : Option FilePath := none
  /-- The token the extractor compares the map's `.key` sidecar against, or
  `none` to make it write unconditionally. It has to be start-up configuration
  too: a token that changed between two requests of one server would describe two
  different maps in one file. -/
  linkIndexKey : Option String := none

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

/-! ## The extraction's shared parts -/

/-- What "IR schema 5" means, minus the two flags the caller chooses. -/
def fixedFlags : Array String := #["--equations", "--refs", "--write-ir", "--tagged-code"]

/-- `<timings without .json>-events.jsonl`. One spelling, and that is the point:
both extraction paths have to leave the events file in the same place under the
same name, or two records of the same run stop being comparable. -/
def eventsBeside (timings : FilePath) : FilePath :=
  let text := timings.toString
  ⟨(if text.endsWith ".json" then (text.dropEnd 5).toString else text) ++ "-events.jsonl"⟩

/-- Removed rather than truncated on open, because the extractor **appends**: a
file an earlier round left behind is folded into this round's timings, and every
number derived from them is then wrong with nothing failing.

One spelling for the same reason `eventsBeside` is one — the three extraction
paths (`Server.start`, `Resident.extract`, `litedoc4 extract`) each had their
own copy, and a judgement in three places is one that gets fixed in one.
Discarded rather than checked: the file not being there is the outcome wanted,
so its absence is not an error. -/
def clearEvents (events : FilePath) : IO Unit :=
  discard <| (IO.FS.removeFile events).toBaseIO

/-- The whole command line an extraction is started with, after `lake env`.

**One spelling for both extraction paths.** `litedoc4 extract` runs it once and
`Serve.startArgv` appends `--serve` to it; written twice, one path's flag order
or one path's `--link-index-omit` could move while the other stood still, and the
two records of the same run would stop being comparable — which is the whole
reason `eventsBeside` is shared too.

`--link-index-omit` and `--link-index-key` are nested inside `--link-index`
because neither names anything without a map to write: the two commands refuse
that combination, and this is where the refusal stops being needed.

Split out of the spawn for the reason `Serve.startArgv` was: which flags an
extraction is given is a decision about its inputs, and inside `IO.Process.spawn`
it could only be asked by running Lean against a real package. What would falsify
the split: a flag whose value has to be read off disk here. -/
def extractArgv (bin modules events irDir : FilePath) (jobs : Nat)
    (linkIndex linkIndexOmit : Option FilePath) (linkIndexKey : Option String) :
    Array String := Id.run do
  let mut args := #["env", bin.toString, modules.toString, events.toString]
  args := args ++ fixedFlags
  args := args ++ #["--jobs", toString jobs, "--ir-dir", irDir.toString]
  if let some map := linkIndex then
    args := args.push "--link-index" |>.push map.toString
    if let some omitList := linkIndexOmit then
      args := args.push "--link-index-omit" |>.push omitList.toString
    if let some key := linkIndexKey then
      args := args.push "--link-index-key" |>.push key
  return args

/-- The modules an extraction was asked for. Blank once trimmed, or *starting*
with `#` untrimmed — the asymmetry is deliberate, because this count is compared
across records of the same run. -/
def countModuleLines (listed : String) : Nat :=
  (listed.splitOn "\n").filter
    (fun line => !(trimWs line).isEmpty && !line.startsWith "#") |>.length

/-- Microseconds as the seconds lexeme to write. Absent is zero, which is the
one event shape that carries no clock.

**Not a `Float`**: Lean has no shortest-round-trip printer, and these numbers are
copied through verbatim by `incremental --timings`, so a value written once and
read back has to come out as the bytes it went in as. Trailing zeros go because
a fixed six places would print `4.542440` where the number is `4.54244`. What
would falsify it: a `Float` printer in core that round-trips. -/
def microSeconds (us : Option Int) : String := Id.run do
  let text := fixed (us.getD 0).toNat 1000000 6
  let mut n := text.utf8ByteSize
  while n > 1 && byteAt text (n - 1) == 48 do n := n - 1
  if byteAt text (n - 1) == 46 then n := n + 1
  return byteSub text 0 n

structure Folded where
  events : FilePath
  modules : FilePath
  jobs : Nat
  out : FilePath

/-- The extractor's events as one timings record.

```text
{"phase":"stage4b.importModules","pid":83359,"us":2498376,"directImports":432}
  -> {"importModules": 2.498376, "importModules:directImports": 432}
```

The `stage4b.` prefix the extractor writes is dropped; `us` becomes seconds under
the phase's own name, so every duration in this project's records is in one unit;
every other key except `pid` becomes `<phase>:<key>` **with its JSON value
carried through untouched**, because the extractor emits a mixture of numbers,
booleans and strings there and re-typing any of them would make two records of
the same run disagree over the same measurement.

Split out of `foldTimings` for `Serve.startArgv`'s reason: this is text in and a
record out, and inside the two `readFile`s it could only be asked of a file on
disk. `label` is the events path, which reaches the refusals and nothing else.
What would falsify the split: a phase whose value has to be looked up somewhere
other than its own line. -/
def foldEvents (label text : String) (counted jobs : Nat) :
    Except String (Array (String × JVal)) := do
  let mut record : Array (String × JVal) := #[]
  for line in text.splitOn "\n" do
    let line := trimWs line
    if line.isEmpty then continue
    let event ← match parseJson line with
      | .error why => .error s!"{label}: {why}"
      | .ok j => .ok j
    let fields ← match event with
      | .obj fields => .ok fields
      | _ => .error s!"{label}: an event that is not a JSON object"
    let phase := match jvalGet? event "phase" with
      | some (.str name) => name.replace "stage4b." ""
      | _ => ""
    -- Refused rather than defaulted to zero: `us` is `nanos / 1000` on the only
    -- side that writes it (`Extract.lean`), so a fractional one means the wire
    -- format moved, and a phase silently reported as instantaneous is the shape
    -- nobody would look at twice. Absent stays zero, which is a real event shape.
    let us ← match jvalGet? event "us" with
      | none => .ok none
      | some (.num n) => .ok (some n)
      | some _ => .error s!"{label}: `us` is not an integer for phase `{phase}`"
    record := orderedInsert record phase (.real (microSeconds us))
    for (key, value) in fields do
      if key != "phase" && key != "pid" && key != "us" then
        record := orderedInsert record s!"{phase}:{key}" value
  record := orderedInsert record "targetModules" (.num (Int.ofNat counted))
  record := orderedInsert record "jobsRequested" (.num (Int.ofNat jobs))
  return record

/-- Writes the fold, and returns the module count it also writes as
`targetModules`. -/
def foldTimings (f : Folded) : IO Nat := do
  let text ← IO.FS.readFile f.events
  let counted := countModuleLines (← IO.FS.readFile f.modules)
  match foldEvents f.events.toString text counted f.jobs with
  | .error why => throw (IO.userError why)
  | .ok record =>
    -- No trailing newline: nothing reads this file as bytes — `analyze.ts` and
    -- `writeTimings` both parse it.
    writeFile f.out (jvalJson (.obj record))
    return counted

/-! ## The server -/

abbrev ServeChild := IO.Process.Child { stdin := .null, stdout := .piped, stderr := .inherit }

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

structure Server where
  child : ServeChild
  /-- The request channel. Emptying the cell is the stop. -/
  stdin : IO.Ref (Option IO.FS.Handle)
  /-- `<work>/serve.out`: every line the server printed, protocol and phase
  report alike, in order. Written and never read back by this process. -/
  log : IO.FS.Handle
  ready : String

/-- The next line with this tag, with everything before it logged.

**Located by prefix, not by position**: the extractor prints a human-readable
phase report to the same stdout as the protocol, so counting lines would be
counting the report. -/
partial def waitFor (child : ServeChild) (log : IO.FS.Handle) (tag : String) : BuildM String := do
  let line ← child.stdout.getLine
  if line.isEmpty then
    -- EOF: the server is gone. Its stderr already reached the caller's, so what
    -- is added here is what was being waited for and what it exited with.
    let code ← child.wait
    throw (4, s!"the resident extractor exited {code} before `{trimWs tag}`")
  log.putStr line
  let text := trimEol line
  if text.startsWith tag then return text
  if text.startsWith "err " then
    throw (4, s!"the resident extractor rejected the request: {text}")
  waitFor child log tag

/-- Where the server appends its events. Every round reads it back under this
name, so it is derived from `work` rather than passed in. -/
def Serve.eventsPath (s : Serve) : FilePath := s.work / "serve-events.jsonl"

/-- Trap 1 in the heading: `--ir-dir` is required at start-up and every request
carries its own, so the value here names a directory nothing ever writes. It is
still a path under `work` rather than a word like `unused`, because the extractor
would create whatever it was handed. -/
def Serve.unusedIrPath (s : Serve) : FilePath := s.work / "serve-ir-unused"

/-- The whole start-up command line: `extractArgv` with `--serve` after it.

The map leaves out the groups of the modules named by the omit list, and
**`modulesFile` is the right list precisely because it is the start-up one, fixed
for the life of the server**. A request's own list is a *subset* — the round loop
extracts what went stale — so deriving the omit set from the request would make
the map's bytes depend on which round happened to write it, and the map's SHA-256
is in `renderKey`.

`--serve` is last because everything before it is configuration; a flag appended
after it would be read as the serve loop's argument. -/
def Serve.startArgv (s : Serve) : Array String :=
  (extractArgv s.bin s.modulesFile s.eventsPath s.unusedIrPath s.jobs
    s.linkIndex (some s.modulesFile) s.linkIndexKey).push "--serve"

def Server.start (s : Serve) : BuildM Server := do
  IO.FS.createDirAll s.work
  clearEvents s.eventsPath
  let log ← IO.FS.Handle.mk (s.work / "serve.out") .write
  let args := s.startArgv
  let child ← match ← (IO.Process.spawn
      { cmd := s.lake.toString
        cwd := some s.target
        stdin := .piped, stdout := .piped, stderr := .inherit
        args }).toBaseIO with
    | .error e => throw (4, s!"{s.lake} env {s.bin} --serve: {e}")
    | .ok child => pure child
  let (handle, child) ← child.takeStdin
  let stdin ← IO.mkRef (some handle)
  let ready ← waitFor child log "ready "
  return { child, stdin, log, ready }

/-- Writes one request and returns its `ok` line. -/
def Server.request (s : Server) (line : String) : BuildM String := do
  match ← s.stdin.get with
  | none => throw (1, "the resident extractor was already stopped")
  | some handle =>
    match ← (do handle.putStr line; handle.flush : IO Unit).toBaseIO with
    | .error e => throw (4, s!"writing to the resident extractor: {e}")
    | .ok () => pure ()
  waitFor s.child s.log "ok "

/-- Closes the pipe and waits. Returns what to say about it.

Emptying the cell drops the last reference to the write end, the server reads
EOF and leaves through its own exit path. Before the wait, or the wait is for a
process nothing has told to stop. -/
def Server.stop (s : Server) : IO String := do
  s.stdin.set none
  let code ← s.child.wait
  return (if code == 0 then "" else s!" (the server exited {code})")

/-! ## The resident extractor -/

/-- A resident extractor and the world it is valid for. -/
structure Resident where
  serve : Serve
  /-- The world as it stood at the head of the run, before `detect` looked at it.
  Every later check is against this one value. -/
  generation : Generation
  running : IO.Ref (Option Server)
  requestCount : IO.Ref Nat

/-- Records the world; starts nothing. -/
def Resident.new (s : Serve) : BuildM Resident := do
  if !(← isRegularFile s.bin) then
    throw (3, s!"--extractor-bin {s.bin}: not a file. It is `extractor/build.sh`'s output, 171 MB, \
      built against the target's toolchain and therefore not committed")
  let generation ← Generation.take s
  return { serve := s, generation, running := ← IO.mkRef none, requestCount := ← IO.mkRef 0 }

/-- The one place the world is re-read and judged, rather than the reading
written out at each of the moments it is wanted: three copies are three answers
to one question, which is how two guards start disagreeing. -/
def Resident.checkGeneration (r : Resident) (when : String) : BuildM Unit := do
  let moved := r.generation.moved (← Generation.take r.serve)
  if !moved.isEmpty then throw (stale moved when)

/-- The running server, started on first use. -/
def Resident.server (r : Resident) : BuildM Server := do
  match ← r.running.get with
  | some server => return server
  | none =>
    -- No check before the spawn: `Resident.extract` has just made one and this is
    -- its next statement.
    let server ← Server.start r.serve
    -- The import window: the server is holding the oleans as they were at some
    -- instant inside it, and this says which. The server is already in hand, so a
    -- refusal here stops it rather than leaking it.
    let moved := r.generation.moved (← Generation.take r.serve)
    if !moved.isEmpty then
      discard <| server.stop
      throw (stale moved "while the server was importing")
    IO.println s!"serve   {server.ready} ({r.serve.jobs} jobs, \
      generation {byteSub r.generation.digest 0 16})"
    r.running.set (some server)
    return server

/-- One extraction round, on the same interface as a `--extractor` program: a
module list in, an IR tree and a timings record out. -/
def Resident.extract (r : Resident) (modules irDir timings : FilePath) : BuildM Nat := do
  let events := eventsBeside timings
  clearEvents events
  IO.FS.createDirAll irDir
  refuseInside r.serve.target "the target" irDir "the round's --ir-dir" ""
  let line ← requestLine #[modules, events, irDir]
  r.checkGeneration "before the request"
  let started ← IO.monoNanosNow
  let reply ← (← r.server).request line
  r.requestCount.modify (· + 1)
  -- After as well as before, so that the interval the request ran in is one the
  -- world provably did not move in.
  r.checkGeneration "after the request"
  if (reply.splitOn " ").getD 1 "" != "0" then
    throw (4, s!"the resident extractor answered `{reply}` for {modules}; the IR tree at {irDir} \
      is incomplete")
  let counted ← foldTimings { events, modules, jobs := r.serve.jobs, out := timings }
  IO.println s!"        served {counted} module(s) from the resident environment in \
    {seconds ((← IO.monoNanosNow) - started) 3}s"
  return counted

/-- How many extraction requests this run has sent. **The same field the stop
line prints** rather than a second tally: two counters of one thing are two
things that can disagree, and this one is a gate's input. -/
def Resident.requests (r : Resident) : IO Nat := r.requestCount.get

/-- Stops the server, if one was ever started. Idempotent. -/
def Resident.stop (r : Resident) : IO Unit := do
  match ← r.running.get with
  | none => return ()
  | some server =>
    r.running.set none
    let requests ← r.requestCount.get
    let status ← server.stop
    IO.println s!"serve   stopped after {requests} request(s){status}"

end Litedoc4
