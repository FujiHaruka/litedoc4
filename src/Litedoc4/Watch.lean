/-
`litedoc4 watch` — keep the site current while the package is being edited, and
serve it.

**It does not run `lake build`.** The user (or the GitHub action) builds the
package and litedoc4 reads the oleans; a Lean compile inside the loop would bring
its own errors and its own idea of what to do when it fails into the one command
whose purpose is to be predictable.

**The trigger is the ledger, not a timestamp.** "Which modules are stale" has one
answer in this tree — `checkLedger`, the same call `build` makes. A second answer
derived from mtimes could disagree with the first, and the quiet direction of that
disagreement is a loop that never rebuilds.

**There is no file-system watcher** — no `FSEvents`/`inotify`/`ReadDirectoryChanges`.
Whatever wakes the loop, the answer still comes from the ledger, so an event would
only be a different alarm clock — and the alarm clock is the part that behaves
differently on each operating system. "Events where available, polling otherwise"
is two code paths; polling is not the fallback here, it is the path. `Std` ships no
file-system event source in any case (measured 2026-08-31 →
`benchmarks/results/purelean-async-tcp-2026-08-31.txt` §6). The cost is measured:
an idle pass is one `checkLedger` over the target's 422 modules — 228,439,544 B of
oleans, 2.25 s warm, against 0.063 s for the Rust half on the same tree in the same
session (measured 2026-08-31 →
`benchmarks/results/purelean-watch-2026-08-31.txt`). The price is that an edit is
noticed up to `--interval` late, and that the poll is not free: at the default
1000 ms a pass takes 3.2 s and a core is busy for two thirds of it.

**A pass acts only when the ledger's answer is the same as the previous pass's.**
While `lake build` is writing oleans the answer keeps moving, and extracting into
that produces a site made of two half-worlds — or is stopped by the resident
extractor's generation guard.

**The resident extractor does not survive a pass.** Lean cannot swap a module out
of an imported environment, and a pass only ever extracts when the oleans have
moved — so a server held over from the previous pass is by construction one whose
environment just went stale. Residency is still bought *within* a pass: the
ownership/merge rounds share one import.

**A failed pass waits for the world to move again** before trying the same thing;
retrying immediately would start a 3 GB import every interval for as long as the
failure lasted. The first pass is the exception — it fails the command, because
until it succeeds there is no site to serve and no state to continue from.
-/
import Litedoc4.Build
import Litedoc4.Httpd

open System

namespace Litedoc4

def defaultIntervalMs : Nat := 1000

def minIntervalMs : Nat := 100

def settleReportNanos : Nat := 5000000000

/-- How often an idle loop says it is still there: a silent terminal cannot be
told from a dead one. -/
def heartbeatNanos : Nat := 60000000000

/-- The port, or the refusal that names what was written. -/
def parsePort : Option String → Except String UInt16
  | none => .ok Httpd.defaultPort
  | some raw =>
    match raw.toNat? with
    | none => .error s!"--port wants a number 1-65535, not `{raw}`"
    | some 0 =>
      .error "--port 0 asks the kernel for whatever is free, which is an address nobody can \
        type. Name the port, or leave the flag out for the default"
    | some n =>
      if n > 65535 then .error s!"--port wants a number 1-65535, not `{raw}`"
      else .ok (UInt16.ofNat n)

/-- The floor stays at 100 ms although a pass here costs twenty times that: the
flag is a name `tools/public-surface.txt` promises and moving what it accepts
breaks a file somebody else maintains. What the refusal says instead is what the
pass really costs. -/
def parseInterval : Option String → Except String Nat
  | none => .ok defaultIntervalMs
  | some raw =>
    match raw.toNat? with
    | none => .error s!"--interval wants a whole number of milliseconds, not `{raw}`"
    | some ms =>
      if ms < minIntervalMs then
        .error s!"--interval {ms} is below {minIntervalMs} ms: a pass reads every olean of the \
          package, which on the 422-module measurement target takes 2.25 s (measured, \
          benchmarks/results/purelean-watch-2026-08-31.txt), so a shorter one spends a core \
          asking a question whose last answer is still current"
      else .ok ms

structure Reading where
  /-- Over the olean hashes *and* the answer. Two passes during one `lake build`
  can report the same *list* of changed modules while the bytes underneath are
  still moving, and a digest over the list alone would call that quiet. -/
  digest : String
  modules : Nat
  reExtract : Nat
  removed : Nat
  renderAll : Array String

def Reading.of (c : CheckSummary) : Reading :=
  let lines := c.fresh.modules.map (fun e => s!"{e.module} {e.hash}")
    ++ #[s!"re-extract {",".intercalate c.reExtract.toList}",
         s!"removed {",".intercalate c.removed.toList}",
         s!"renderKey {",".intercalate c.renderKeyChanged.toList}",
         s!"extractKey {",".intercalate c.extractKeyChanged.toList}"]
  { digest := sha256Text ("\n".intercalate lines.toList)
    modules := c.modules, reExtract := c.reExtract.size, removed := c.removed.size
    renderAll := c.renderKeyChanged }

def Reading.work (r : Reading) : Bool :=
  r.reExtract > 0 || r.removed > 0 || !r.renderAll.isEmpty

def Reading.what (r : Reading) : String :=
  let parts := (if r.reExtract > 0 then [s!"{r.reExtract} module(s) to re-extract"] else [])
    ++ (if r.removed > 0 then [s!"{r.removed} removed"] else [])
    ++ (if r.renderAll.isEmpty then []
        else [s!"the render key moved ({",".intercalate r.renderAll.toList})"])
  if parts.isEmpty then "nothing stale" else ", ".intercalate parts

inductive Step where
  | idle
  /-- There is work, but the answer moved since the last pass: something is still
  writing oleans. -/
  | settling
  /-- There is work, the world is quiet, and this is bit for bit the answer the
  last pass already acted on.

  Two states reach here and both need it. A pass that *failed* must not be retried
  until something changes, or a broken extraction becomes a 3 GB Lean import per
  interval. And a source file whose olean does not exist yet is reported stale by
  every pass for as long as that is true — what would fix it is `lake build`, not a
  rebuild — so without this the loop would rebuild once a second for ever. -/
  | skip
  | rebuild
  deriving BEq

/-- The whole of the loop's judgement, as a pure function of three values. -/
def decide (previous acted : Option String) (now : Reading) : Step :=
  if !now.work then .idle
  else if previous != some now.digest then .settling
  else if acted == some now.digest then .skip
  else .rebuild

/-- Everything one pass needs to ask the ledger the question `build` asks.

**Every field is fixed for the session.** The ledger records a render key made of
the source URL, the dependency map and the documentation map; if the loop computed
any of them differently from the run it triggers, the two would take turns telling
each other the key had moved and the loop would re-render the whole site on every
pass, for ever. So they are resolved once, in `watchRun`, and both sides read the
same values.

The module list is the exception: it is re-globbed every pass, because a source
file that appeared or vanished is one of the things this loop exists to notice. -/
structure Trigger where
  ledger : FilePath
  ir : FilePath
  linkIndex : FilePath
  sourceUrl : String
  externalLinks : String
  root : FilePath
  libs : Array String

/-- One reading, or `none` when nothing has ever been built here. -/
def Trigger.ask (t : Trigger) : IO (Except (UInt32 × String) (Option Reading)) := do
  if !(← isRegularFile t.ledger) then return .ok none
  let modules ← match ← moduleNames t.root t.libs with
    | .error message => return .error (3, message)
    | .ok names => pure names
  match ← checkLedger
      { ledger := t.ledger
        -- The ledger's own, never an override: two algorithms produce
        -- incomparable hashes and every module would read as changed.
        algorithm := none
        modules := some modules, ir := some t.ir, sourceUrl := t.sourceUrl
        linkIndex := some t.linkIndex, externalLinks := some t.externalLinks } with
  | .error refusal => return .error refusal
  | .ok check => return .ok (some (Reading.of check))

/-- A failure as one line, for a loop that reports it and carries on. -/
def describe (code : UInt32) (message : String) : String :=
  if code == 2 || code == 1 then message else s!"{message} (exit {code})"

def announce (rebuilds : Nat) (now : Option Reading) : IO Unit := do
  IO.println ""
  match now with
  | none =>
    IO.println s!"watch   #{rebuilds} nothing has been built under --out yet — generating the \
      whole site. This imports the package's Lean environment once and extracts every module, \
      which is the slowest thing this command does; the lines below are that run's own"
  | some reading => IO.println s!"watch   #{rebuilds} the ledger reports {reading.what}"

structure LoopState where
  previous : Option String := none
  acted : Option String := none
  passes : Nat := 0
  rebuilds : Nat := 0
  settling : Option Nat := none
  said : Option Nat := none
  quietSince : Nat

partial def runLoop (r : BuildRequest) (t : Trigger) (interval : Nat) (port : UInt16)
    (s : LoopState) : BuildM Unit := do
  let passes := s.passes + 1
  let askedAt ← IO.monoNanosNow
  let answer ← match ← (t.ask).toBaseIO with
    | .ok answer => pure answer
    | .error e => pure (.error (1, toString e))
  match answer with
  | .error (code, message) =>
    -- Said every time, unlike a failed rebuild: reading the ledger costs nothing
    -- to retry, and the world moving is what fixes it.
    IO.eprintln s!"watch   cannot ask the ledger: {describe code message}"
    IO.sleep (UInt32.ofNat interval)
    runLoop r t interval port { s with passes }
  | .ok now =>
    -- What the poll costs, in the line that says the loop is alive: the one number
    -- a reader can use to choose `--interval`.
    let asked := (← IO.monoNanosNow) - askedAt
    let step := match now with
      | none => Step.rebuild
      | some reading => decide s.previous s.acted reading
    let mut next : LoopState := { s with passes }
    match step with
    | .idle =>
      next := { next with settling := none, said := none }
      if (← IO.monoNanosNow) - s.quietSince ≥ heartbeatNanos then
        let upToDate := now.map (·.modules) |>.getD 0
        IO.println s!"watch   idle — {upToDate} module(s) up to date, {passes} pass(es) so far, \
          {s.rebuilds} rebuild(s), {seconds asked 3} s to ask"
        next := { next with quietSince := ← IO.monoNanosNow }
    | .settling =>
      let stale := (now.map (·.what)).getD ""
      match s.settling with
      -- The first pass of a settling stretch is the ordinary case — a `lake build`
      -- that finished between two passes — so "a build is in flight" here would be
      -- a guess, usually wrong.
      | none =>
        let stamp ← IO.monoNanosNow
        next := { next with settling := some stamp, said := some stamp }
        IO.println s!"watch   {stale} — waiting one quiet interval in case something is still \
          writing oleans"
      | some started =>
        let stamp ← IO.monoNanosNow
        if s.said.all (stamp - · ≥ settleReportNanos) then
          IO.println s!"watch   still not quiet after {seconds (stamp - started) 0} s — {stale}, \
            and the answer keeps moving, so a build is in flight. Waiting; nothing is stuck."
          next := { next with said := some stamp }
    -- Nothing is printed per pass: this state persists until the user builds, so a
    -- line a second about it would bury everything else. Only the heartbeat fires,
    -- because it can last for hours.
    | .skip =>
      next := { next with settling := none, said := none }
      if (← IO.monoNanosNow) - s.quietSince ≥ heartbeatNanos then
        IO.println s!"watch   waiting — {(now.map (·.what)).getD ""}, unchanged since the last \
          pass acted on it, so there is nothing new to do ({seconds asked 3} s to ask)"
        next := { next with quietSince := ← IO.monoNanosNow }
    | .rebuild =>
      let rebuilds := s.rebuilds + 1
      let first := rebuilds == 1 && s.acted.isNone
      announce rebuilds now
      -- Bound with its type written out, and not matched on directly: `BuildM α`
      -- is by definition `IO (Except (UInt32 × String) α)`, so a bare `← (runBuild
      -- r).run` in this monad resolves to the `BuildRan` inside rather than to the
      -- `Except` around it.
      let outcome : Except (UInt32 × String) BuildRan ← (runBuild r).run
      match outcome with
      | .ok ran =>
        IO.println s!"watch   #{rebuilds} {ran.what} — re-extracted {ran.modulesExtracted} \
          module(s), re-rendered {ran.pagesRendered} page(s), started Lean \
          {ran.extractorRequests} time(s) in {seconds ran.nanos 3} s\
          {if ran.pagesRendered == 0 then " — no page on the site changed" else ""}"
        IO.println s!"watch   #{rebuilds} reload http://127.0.0.1:{port}/"
      | .error (code, message) =>
        -- The first one is fatal: with no site to serve and no state to continue
        -- from, looping here would loop over a broken configuration.
        if first then throw (code, message)
        IO.eprintln s!"watch   #{rebuilds} the rebuild stopped: {describe code message}"
        IO.eprintln s!"watch   #{rebuilds} not retrying until the oleans move again — a failing \
          extraction restarted every {interval} ms would import 3 GB every {interval} ms"
      next := { next with rebuilds, settling := none, said := none,
                          acted := now.map (·.digest), quietSince := ← IO.monoNanosNow }
    IO.sleep (UInt32.ofNat interval)
    runLoop r t interval port { next with previous := now.map (·.digest) }

/-- Everything this command prints goes through a stream that flushes on every
write.

Lean's `IO.println` to a **redirected** stdout is fully buffered and core exposes
no way to change the mode, so a process that does not exit — this one — leaves its
log empty for as long as it runs (measured 2026-08-31 →
`benchmarks/results/purelean-async-tcp-2026-08-31.txt` §5). The straightforward
alternative is a helper the loop prints through, but the lines a reader waits for
during a pass are the *build's* own, printed by `runBuild` and everything under it;
replacing the stream is what reaches those without a flush at each of them. What
would falsify it: a buffering-mode setter in core, which would make this one call. -/
private def lineFlushed (s : IO.FS.Stream) : IO.FS.Stream :=
  { s with
    write := fun bytes => do s.write bytes; s.flush
    putStr := fun text => do s.putStr text; s.flush }

def watchRun (r : BuildRequest) (port : UInt16) (interval : Nat) : BuildM Unit := do
  discard <| IO.setStdout (lineFlushed (← IO.getStdout))

  -- Pinned here, once, and never derived again — see `Trigger`.
  let libs ← if r.libs.isEmpty then
      match ← readLibraries r.root with
      | .error message => throw (3, message)
      | .ok declared => do
        IO.println s!"watch   lib    {", ".intercalate declared.names.toList} \
          (from {declared.file})"
        pure declared.names
    else pure r.libs
  let sourceUrl ← match r.sourceUrl with
    | some url => pure url
    | none =>
      match ← (deriveSourceUrl r.root).run with
      | .error message => throw (3, message)
      | .ok derived =>
        if let some message := checkSourceUrl derived then throw (2, message)
        IO.println s!"watch   source {derived} (derived once, now — a commit during this \
          session does not move it)"
        pure derived
  let request := { r with libs, sourceUrl := some sourceUrl }

  -- Before the first build: a port that is taken has to be said while the reader
  -- is still looking, not after a two-minute full generation.
  match ← Httpd.bind port request.layout.site with
  | .error message => throw (3, message)
  | .ok _ => pure ()
  IO.println s!"watch   site   http://127.0.0.1:{port}/  ({request.layout.site})"
  IO.println s!"watch   root   {request.root} — this command does **not** run `lake build`. \
    Run it in another window; watch notices the oleans it writes."
  IO.println s!"watch   asks the ledger every {interval} ms. Ctrl-C stops it."

  let trigger : Trigger :=
    { ledger := request.layout.ledger, ir := request.layout.ir
      linkIndex := request.layout.linkIndex, sourceUrl
      externalLinks := request.external.digest, root := request.root, libs }
  runLoop request trigger interval port { quietSince := ← IO.monoNanosNow }

end Litedoc4
