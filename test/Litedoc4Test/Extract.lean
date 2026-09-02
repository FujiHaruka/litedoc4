/- The part of `litedoc4 extract` that is not the extraction — the command line
it builds, where the events file goes, and the fold from the events JSONL into
one timings record.

The three shapes below are all "values in, a string or an array out", and that is
the port's doing: `extractArgv`, `oneShotArgv` and `foldEvents` were split out of
the three places that spawn or read, so what is left in `IO` is a `spawn` and two
`readFile`s.

`an_ir_dir_inside_the_target_is_refused`, `a_failing_extractor_is_exit_4`,
`the_flags_that_are_not_offered_are_refused_by_name` and
`the_paths_with_no_default_are_required` are refusals reachable from the command
line and belong to `tools/refusal-gate.sh`, which holds the six `extract-*` rows.
`every_path_reaches_the_child_absolute` is not here either: it needs a run
started from a *relative* working directory, which is a process and not a value.
-/
import Litedoc4.Incr.Pipeline
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4 System

/-- Shortened from a real `*-events.jsonl`. Three of its properties are
load-bearing: the `stage4b.` prefix is on every phase, the extra keys are typed
(a number, a boolean and a string in one file), and one line is blank. -/
def sampleEvents : String :=
  "{\"phase\":\"stage4b.initSearchPath\",\"pid\":7,\"us\":34}\n\
   {\"phase\":\"stage4b.importModules\",\"pid\":7,\"us\":2498376,\"directImports\":432,\
   \"resident\":0}\n\n\
   {\"phase\":\"stage4b.writeIR\",\"pid\":7,\"us\":123456,\"taggedCode\":\"true\",\
   \"moduleFiles\":2,\"ok\":true}\n"

/-- The record as the bytes `foldTimings` writes, or the word a refusal starts
with. Compared as the line rather than key by key because the failure to catch is
a key nobody meant to add, which a per-key check cannot see. -/
def foldedJson (label text : String) (counted jobs : Nat) : String :=
  match foldEvents label text counted jobs with
  | .error why => "REFUSED " ++ why
  | .ok record => jvalJson (.obj record)

/-- One record, and **the field names and the value types are the contract**:
`benchmarks/tools/analyze.ts` and every JSONL already under
`benchmarks/results/` read them.

`us` becomes seconds under the phase's own name so that every duration in this
project's records is in one unit; every other key but `pid` becomes
`<phase>:<key>` **with its JSON value carried through untouched**, because
re-typing `"true"` to `true` or `2` to `2.0` would make two records of the same
run disagree about the same measurement. `pid` identifies the process, not the
measurement, and is the one key dropped. -/
def theEventsBecomeOneTimingsObjectAndNothingIsInvented : Bool :=
  foldedJson "events.jsonl" sampleEvents 2 3
    == "{\"initSearchPath\":0.000034,\"importModules\":2.498376,\
        \"importModules:directImports\":432,\"importModules:resident\":0,\
        \"writeIR\":0.123456,\"writeIR:taggedCode\":\"true\",\"writeIR:moduleFiles\":2,\
        \"writeIR:ok\":true,\"targetModules\":2,\"jobsRequested\":3}"

#guard theEventsBecomeOneTimingsObjectAndNothingIsInvented

/-- A phase with no clock is zero seconds, not an absent key: that is a real
event shape, and a phase that vanished from the record would read as one that
never ran. A `us` that is not an integer is refused instead — it is `nanos /
1000` on the only side that writes it, so a fractional one means the wire format
moved, and a phase silently reported as instantaneous is the shape nobody would
look at twice. -/
def anAbsentClockIsZeroAndAClockThatIsNotAnIntegerIsRefused : Bool :=
  foldedJson "e" "{\"phase\":\"stage4b.done\",\"pid\":1}\n" 0 1
      == "{\"done\":0.0,\"targetModules\":0,\"jobsRequested\":1}"
    && (foldedJson "e" "{\"phase\":\"stage4b.done\",\"us\":\"9\"}\n" 0 1).startsWith "REFUSED "
    && (foldedJson "e" "not json\n" 0 1).startsWith "REFUSED "
    && (foldedJson "e" "[1,2]\n" 0 1).startsWith "REFUSED "

#guard anAbsentClockIsZeroAndAClockThatIsNotAnIntegerIsRefused

/-- Blank once trimmed, or *starting* with `#` untrimmed. The asymmetry is
deliberate and is why this is stated rather than left to the reader: the count is
compared across two records of the same run, so both sides have to agree about
what is not a module. -/
def theModuleCountSkipsBlankLinesAndComments : Bool :=
  countModuleLines "A.One\n\n# a comment\nA.Two\n" == 2
    && countModuleLines "  \t \nA.One\n" == 1
    && countModuleLines "  # indented\n" == 1

#guard theModuleCountSkipsBlankLinesAndComments

def extractBin : FilePath := "/bin/extract"

/-- The order the extractor is handed its flags in, and **the same expression
serves both extraction paths**: `Serve.startArgv` is this with `--serve` pushed
onto it, so a flag that moved here would move there too. That is the whole reason
it is one function — two records of the same run stay comparable only if the two
paths configure the extractor identically.

The four fixed flags are what "IR schema 5" means; an IR written without one of
them parses and renders wrongly rather than failing, which is why `extract`
refuses them as flags rather than accepting them as no-ops. -/
def theExtractorIsHandedTheSchema5FlagsInThisOrder : Bool :=
  extractArgv extractBin "/work/modules.txt" "/work/t-events.jsonl" "/out/ir" 4 none none none
      == #["env", "/bin/extract", "/work/modules.txt", "/work/t-events.jsonl",
           "--equations", "--refs", "--write-ir", "--tagged-code",
           "--jobs", "4", "--ir-dir", "/out/ir"]
    && fixedFlags == #["--equations", "--refs", "--write-ir", "--tagged-code"]
    && (Serve.startArgv
        { bin := extractBin, lake := "/bin/lake", target := "/pkg", jobs := 4
          modulesFile := "/work/modules.txt", modules := #[], work := "/work" })
      == (extractArgv extractBin "/work/modules.txt" "/work/serve-events.jsonl"
          "/work/serve-ir-unused" 4 none (some "/work/modules.txt") none).push "--serve"

#guard theExtractorIsHandedTheSchema5FlagsInThisOrder

/-- The map's two companion flags are **inside** `--link-index`, never beside it:
neither names anything when no map is being written, and a flag that does nothing
is the shape where the run looks right and the artefact is not the one that was
asked for. Both commands refuse that combination on the command line; here it
cannot be spelled. -/
def theMapsCompanionFlagsCannotBeWrittenWithoutTheMap : Bool :=
  extractArgv extractBin "/m.txt" "/e.jsonl" "/ir" 1
      (some "/map.lidx") (some "/omit.txt") (some "token")
      == #["env", "/bin/extract", "/m.txt", "/e.jsonl",
           "--equations", "--refs", "--write-ir", "--tagged-code",
           "--jobs", "1", "--ir-dir", "/ir",
           "--link-index", "/map.lidx", "--link-index-omit", "/omit.txt",
           "--link-index-key", "token"]
    && !(extractArgv extractBin "/m.txt" "/e.jsonl" "/ir" 1 none (some "/omit.txt")
          (some "token")).contains "--link-index-omit"
    && !(extractArgv extractBin "/m.txt" "/e.jsonl" "/ir" 1 none none
          (some "token")).contains "--link-index-key"

#guard theMapsCompanionFlagsCannotBeWrittenWithoutTheMap

/-- `--events` is on neither line. Both paths derive it from the timings path
with the **same** expression, so a round's two records name one file; passing it
on one line and defaulting it on the other is how a stale round's events get
folded into this round's timings.

The suffix is dropped only when it is there, because `--timings` is a path the
caller chose and need not end in `.json`. -/
def theEventsFileIsDerivedFromTheTimingsPathAndIsOnNeitherCommandLine : Bool :=
  (eventsBeside "/work/timings.json").toString == "/work/timings-events.jsonl"
    && (eventsBeside "/work/timings").toString == "/work/timings-events.jsonl"
    && (eventsBeside "/work/a.json.json").toString == "/work/a.json-events.jsonl"
    && !(extractArgv extractBin "/m.txt" "/e.jsonl" "/ir" 1 none none none).contains "--events"
    && !(oneShotArgv #[] "/m.txt" "/ir" "/work/timings.json").contains "--events"

#guard theEventsFileIsDerivedFromTheTimingsPathAndIsOnNeitherCommandLine

/-- `--extractor-arg`s come **first**, so a wrapper script sees its own
configuration before the three flags the round adds — a script that took the last
occurrence of a flag it also configures would otherwise silently win over the
round. -/
def aRoundsOwnFlagsComeAfterTheCallersOwn : Bool :=
  oneShotArgv #["--world", "/w"] "/work/round-in-1.txt" "/work/inc-ir-1" "/work/t.json"
    == #["--world", "/w", "--modules", "/work/round-in-1.txt",
         "--ir-dir", "/work/inc-ir-1", "--timings", "/work/t.json"]

#guard aRoundsOwnFlagsComeAfterTheCallersOwn

end Litedoc4Test
