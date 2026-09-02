/- The loop's judgement, the question it asks the ledger, and the one line it
prints when something goes wrong.

`decide` is a pure function of three values on purpose — the loop around it needs
a package, a toolchain and an extractor, and none of the four states it chooses
between does. So the judgement is compile time and only the question is not.

`the_port_is_a_number_in_range`, `the_interval_has_a_floor` and
`each_command_refuses_the_others_flags_by_name` are refusals reachable from the
command line and belong to a refusal gate. -/
import Litedoc4.Watch
import Litedoc4Test.IncrFixture
import Litedoc4Test.IncrLedger

namespace Litedoc4Test
open Litedoc4 System

def readingOf (reExtract removed : Nat) (renderAll : Array String) (digest : String) : Reading :=
  { digest, modules := 422, reExtract, removed, renderAll }

/-- Nothing stale is idle **whatever the history**, and that is the clause that
keeps the loop from rebuilding a site nothing has changed: a pass that consulted
the previous digest before asking whether there was any work would rebuild once
on every olean the package's own `lake build` rewrites. -/
def nothingStaleIsIdleWhateverTheHistory : Bool :=
  let quiet := readingOf 0 0 #[] "a"
  decide none none quiet == .idle
    && decide (some "a") (some "a") quiet == .idle
    && decide (some "b") (some "c") quiet == .idle

#guard nothingStaleIsIdleWhateverTheHistory

/-- The three answers when there **is** work, which are three different things
to do and are told apart by two `Option String`s.

`settling` is the answer that costs the most to get wrong: while `lake build` is
writing oleans the reading keeps moving, and extracting into that produces a site
made of two half-worlds. `skip` is the other one — a pass that failed, or a
source file whose olean does not exist yet, is stale to every pass for ever, and
without `skip` the loop would start a 3 GB Lean import every interval. -/
def workIsSettlingUntilTheWorldIsQuietAndIsNeverActedOnTwice : Bool :=
  let stale := readingOf 37 0 #[] "a"
  let one := readingOf 1 0 #[] "a"
  decide none none stale == .settling
    && decide (some "earlier") none stale == .settling
    && decide (some "a") none one == .rebuild
    && decide (some "a") (some "older") one == .rebuild
    && decide (some "a") (some "a") one == .skip

#guard workIsSettlingUntilTheWorldIsQuietAndIsNeverActedOnTwice

/-- A moved render key and a deleted module are work with nothing to
re-extract — the two shapes a loop that only counted stale modules would sit
still through, leaving the site showing pages whose source URL or whose
neighbours have changed. -/
def aMovedRenderKeyOrARemovedModuleIsWorkWithNothingToReExtract : Bool :=
  let keyed := readingOf 0 0 #["sourceUrl"] "a"
  let deleted := readingOf 0 1 #[] "a"
  keyed.work && decide (some "a") none keyed == .rebuild
    && deleted.work && decide (some "a") none deleted == .rebuild
    && !(readingOf 0 0 #[] "a").work

#guard aMovedRenderKeyOrARemovedModuleIsWorkWithNothingToReExtract

/-- The line names what is actually stale, and a pass with nothing to re-extract
must not say `0 module(s) stale` — the reader is waiting to learn whether their
edit was seen. -/
def theWorkIsDescribedByWhatIsActuallyStale : Bool :=
  (readingOf 0 0 #[] "a").what == "nothing stale"
    && (readingOf 1 0 #[] "a").what == "1 module(s) to re-extract"
    && (readingOf 0 2 #[] "a").what == "2 removed"
    && (readingOf 0 0 #["sourceUrl"] "a").what == "the render key moved (sourceUrl)"
    && (readingOf 3 1 #["linkIndex"] "a").what
      == "3 module(s) to re-extract, 1 removed, the render key moved (linkIndex)"

#guard theWorkIsDescribedByWhatIsActuallyStale

/-- One line, and it still says what happened. Exit 1 and 2 are already a
sentence a reader can act on; anything else is a code a caller may be scripting
against, so the code goes in the line.

**There is no message-less failure to carry.** Rust's `Answered(code)` printed
`exit 4` and nothing else; here every exit-4 site throws a message with it, so
the state that used to say only a number cannot be reached. -/
def everyFailureBecomesOneLineThatStillSaysWhatHappened : Bool :=
  describe 2 "--port wants a number" == "--port wants a number"
    && describe 1 "/tmp/x: No such file" == "/tmp/x: No such file"
    && describe 3 "the ledger is older than this layout"
      == "the ledger is older than this layout (exit 3)"
    && describe 4 "the extractor exited 7" == "the extractor exited 7 (exit 4)"

#guard everyFailureBecomesOneLineThatStillSaysWhatHappened

def watchIrIndex : String :=
  "{\"schemaVersion\":5,\"generator\":\"litedoc4/test/Litedoc4Test/Watch.lean\"}"

/-- The sources the glob finds and the oleans the ledger hashes. `writeFakeRepo`
supplies the toolchain and the manifest that `extractKey` is taken over; what it
does not write is the `.lean` files, and `Trigger.ask` re-globs those on every
pass because a source file that appeared or vanished is one of the things the
loop exists to notice. -/
def writeWatchPackage (repo : FilePath) (modules : Array String) : IO Unit := do
  writeFakeRepo repo (modules.map fun name => { name })
  for m in modules do
    writeUnder repo ("/".intercalate (m.splitOn ".") ++ ".lean") "-- a source file\n"

/-- The four answers one pass can get, on a package this owns.

The stable digest is the one that would be silent: two passes over a world that
did not move have to agree, or no pass is ever quiet enough for the next one to
act on, and the loop sits `settling` for ever printing that something is still
building. The moved olean is its mirror — a digest that did not move when the
bytes did leaves the loop sitting on a stale site.

The digest is over the olean hashes **and** the answer, not over the list of
changed modules: two passes during one `lake build` can report the same list
while the bytes underneath are still moving. -/
def theTriggerAnswersNothingYetAStableDigestAMovedOleanAndABrokenLedger : Invariant where
  name := "Trigger.ask: no ledger is `nothing yet`, an unmoved world gives the same digest \
    twice, a moved olean moves it, and a ledger that will not parse names the file"
  check := do
    let work ← incrWorkDir "watch-trigger"
    let repo := work / "repo"
    let ledger := work / "ledger.json"
    let ir := work / "ir"
    let lidx := work / "link-index.lidx"
    writeWatchPackage repo #["Pkg", "Pkg.A"]
    IO.FS.createDirAll ir
    IO.FS.writeFile (ir / "index.json") watchIrIndex
    IO.FS.writeFile lidx "#lidx1\n@Dep.Home\nDep.Home\n\tDep.elsewhere\n"
    let trigger : Trigger :=
      { ledger, ir, linkIndex := lidx, sourceUrl, externalLinks := "external-digest"
        root := repo, libs := #["Pkg"] }

    let nothingYet ← trigger.ask
    let built ← buildLedger
      { modules := #["Pkg", "Pkg.A"], target := repo.toString, ir := some ir, sourceUrl
        linkIndex := some lidx, externalLinks := some "external-digest" }
    let buildRefusal := match built with
      | .error why => some s!"the ledger would not build: {why}"
      | .ok _ => none
    if let .ok (l, _) := built then IO.FS.writeFile ledger l.toJson
    let quiet ← trigger.ask
    let again ← trigger.ask
    writeUnder repo ".lake/build/lib/lean/Pkg/A.olean" "the olean bytes of Pkg.A, moved"
    let moved ← trigger.ask
    IO.FS.writeFile ledger "{ half-written"
    let broken ← trigger.ask
    removeDir work

    let reading (r : Except (UInt32 × String) (Option Reading)) : Option Reading :=
      match r with
      | .ok (some x) => some x
      | _ => none
    return first [
      buildRefusal,
      -- A directory nothing has built reads as `nothing yet`, never as a failure:
      -- the first pass of `watch` is exactly this state.
      eq (match nothingYet with | .ok none => "nothing yet" | _ => "something else")
        "nothing yet",
      eq ((reading quiet).map (fun r => (r.modules, r.work, r.what)))
        (some (2, false, "nothing stale")),
      eq ((reading again).map (·.digest)) ((reading quiet).map (·.digest)),
      eq (((reading moved).map (·.digest)) != ((reading quiet).map (·.digest))) true,
      eq ((reading moved).map (fun r => (r.work, r.reExtract, r.what)))
        (some (true, 1, "1 module(s) to re-extract")),
      eq (match broken with
          | .error (_, why) => (why.splitOn "ledger.json").length ≥ 2
          | .ok _ => false) true]

end Litedoc4Test
