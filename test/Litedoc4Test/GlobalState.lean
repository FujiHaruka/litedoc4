/- `crates/litedoc4-global/src/state.rs`: the `contentHash` cache.

What decides whether a file is this run's cache is entirely in the file's text,
and what goes into it is entirely in the index and the facts, so `stateOf` and
`stateJson` are where the rules live and the two `IO` wrappers are a read and a
write. Only the seam between them needs a running process. -/
import Litedoc4.Global.State
import Litedoc4Test.GlobalArtifacts

namespace Litedoc4Test
open Litedoc4 System

def sampleFacts : ModuleFacts :=
  { module := "Pkg.A"
    contentHash := "1111111111111111"
    imports := #["Pkg"]
    tactics := 2
    decls := #[("Pkg.A.one", "def"), ("Pkg.A.two", "theorem")]
    instances := #[("Cls", "Pkg.A.inst")]
    tokens := #["Pkg", "Pkg.A"]
    instancesFor := #[("Pkg.T", "Pkg.A.inst")]
    refs := refsOf [("Pkg.a", [0, 1]), ("Pkg.b", [1])]
    summary := some "A \"quoted\" heading" }

def indexEntryFor (module : String) : IndexEntry :=
  { module, file := s!"modules/{module}.json", bytes := 1, contentHash := "1111111111111111" }

def sampleIndex : Index :=
  { schemaVersion := 5, generator := "litedoc4-test", leanVersion := "4.31.0"
    modules := #[indexEntryFor "Pkg.A"] }

def goodState : String := stateJson sampleIndex #[sampleFacts]

/-- The writer's keys and the reader's required keys are two hand-written lists
in one file, and they decide opposite things. A field added to `jsonFacts` and
not to `factKeys` does not fail: a file written before the field existed then
loads as a **hit** whose new fact is the type's default, and an artifact is
derived from a fact that is silently absent. -/
def theStateFilesKeysAreTheOnesTheReaderRequires : Bool :=
  match parseJson (jsonFacts "" sampleFacts) with
  | .error _ => false
  | .ok v => (asObj v).map (·.1) == factKeys

#guard theStateFilesKeysAreTheOnesTheReaderRequires

def sameFacts (a b : ModuleFacts) : Bool :=
  a.module == b.module && a.contentHash == b.contentHash && a.imports == b.imports
    && a.tactics == b.tactics && a.decls == b.decls && a.instances == b.instances
    && a.tokens == b.tokens && a.instancesFor == b.instancesFor && a.summary == b.summary
    && a.refs.size == b.refs.size
    && a.refs.toList.all fun (name, users) => b.refs.getD name #[] == users

/-- Both directions of the same key list: an entry this writer wrote comes back
whole, and an entry missing any one of the ten does not come back at all. The
second is stated over `factKeys` rather than over a chosen key, because a
required-key check that is right for nine of them and wrong for the tenth reads
the same from the outside. -/
def aStateEntryRoundTripsAndOneMissingKeyIsAMiss : Bool :=
  match parseJson (jsonFacts "" sampleFacts) with
  | .error _ => false
  | .ok v =>
    (match toModuleFacts v with
      | none => false
      | some back => sameFacts back sampleFacts)
    && factKeys.all fun key => (toModuleFacts (.obj ((asObj v).filter (·.1 != key)))).isNone

#guard aStateEntryRoundTripsAndOneMissingKeyIsAMiss

/-- The whole-package invariants below cannot make this non-vacuous: they only
ever hand `stateJson` facts that came from the index it is passed, so dropping
the filter would pass every one of them. Written out of index order, with one
module the index does not list. -/
def onlyTheIndexSurvivesIntoTheFile : Bool :=
  let index := { sampleIndex with
    modules := #[indexEntryFor "Pkg.A", indexEntryFor "Pkg.B"] }
  let body := stateJson index
    #[{ sampleFacts with module := "Pkg.B" },
      { sampleFacts with module := "Pkg.Gone" },
      { sampleFacts with module := "Pkg.A" }]
  (asObj (fieldOf (parsedObj body) "modules")).map (·.1) == #["Pkg.A", "Pkg.B"]

#guard onlyTheIndexSurvivesIntoTheFile

/-- Everything that can go wrong loads as "empty", and each of the six is a
different way for a file to belong to another run. A cold cache is the normal
first run and rebuilding is the only correct response; trusting a foreign entry
costs a wrong artifact that nobody reports. -/
def aStateFromAnotherRunLoadsAsEmpty : Bool :=
  (stateOf goodState sampleIndex).modules.size == 1
    && [goodState.replace "\"stateVersion\":1" "\"stateVersion\":2",
        goodState.replace stateDerivation "some older rule",
        goodState.replace "\"schemaVersion\":5" "\"schemaVersion\":4",
        goodState.replace "litedoc4-test" "doc-gen4",
        goodState.replace "\"module\":\"Pkg.A\"," "",
        "not json at all"].all fun text => (stateOf text sampleIndex).modules.isEmpty

#guard aStateFromAnotherRunLoadsAsEmpty

/-- The seam the two guards above cannot reach: that the file on disk is the
string `stateJson` returned, that the byte count `State.save` reports is that
file's, and that with no `--state` neither half touches the disk at all. -/
def theStateFileOnDiskIsTheBytesItSaysItIs : Invariant where
  name := "State.save writes stateJson's bytes, and without a directory writes nothing"
  check := do
    let base : FilePath := ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩
    let dir := base / "litedoc4-lean-test-state"
    if ← dir.pathExists then IO.FS.removeDirAll dir
    let bytes ← State.save (some dir) sampleIndex #[sampleFacts]
    let body ← IO.FS.readFile (dir / stateFile)
    let loaded ← State.load (some dir) sampleIndex
    let nothing ← State.save none sampleIndex #[sampleFacts]
    let empty ← State.load none sampleIndex
    if ← dir.pathExists then IO.FS.removeDirAll dir
    return first [
      eq body goodState,
      eq bytes body.utf8ByteSize,
      eq loaded.modules.size 1,
      eq nothing 0,
      eq empty.modules.isEmpty true]

end Litedoc4Test
