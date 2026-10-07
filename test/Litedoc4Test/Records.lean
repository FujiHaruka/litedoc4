/- The three records a run leaves on disk for something outside this tree to
read: `litedoc4-build.json`, `build --timings` and `site --timings`.

**Their field names are a wire format, not an output format.**
`tools/onemod-gate.sh` and `tools/watch-gate.sh` read `work.modulesExtracted`,
`tools/e2e-micro.sh` reads the marker rather than grepping the log,
`.github/workflows/ci-action.yml` reads `versionsExtracted`, and
`benchmarks/tools/analyze.ts` aggregates the timings JSONL by key. A renamed key
does not fail anything: it makes an aggregation return zero rows, and the gate
that reads it green having checked nothing.

Each of the four writers is already a pure function of the numbers, so there is
nothing to split — what was missing was anybody asking them. Stated as whole
lines: the failure to catch is a key nobody meant to add or drop, and a per-key
check cannot see one. -/
import Litedoc4.Main
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4

def sampleWork : WorkCounts :=
  { modulesExtracted := 1, extractorRequests := 4
    irReads := { index := 9, module := 10, depMap := 11 } }

/-- `irReads` is split by kind because only the module files divide into a
number of full passes, and `total` is written beside the three rather than left
to the reader. -/
def theWorkCountsAreTheseKeysAndTheIrReadsAreSplitByKind : Bool :=
  sampleWork.toJson
      == "{\"modulesExtracted\":1,\"extractorRequests\":4,\
          \"irReads\":{\"index\":9,\"module\":10,\"depMap\":11,\"total\":30}}"
    && sampleWork.irReads.total == 30

#guard theWorkCountsAreTheseKeysAndTheIrReadsAreSplitByKind

/-- **A run that did not finish records no work**, and says so in every field
that would otherwise describe one: `complete` is `false` and `work`, `version`,
`store` and `versionsExtracted` are `null` rather than a record of zeros. The
`Option` is the record, because a marker whose `complete` and whose `work`
disagreed would let a reader take the zeros for a run that did nothing.

`layout` is the number a later run compares before it will write into a tree it
did not make. A finished run names its version, and `versionsExtracted` counts
it only when a module was extracted. -/
def anUnfinishedRunRecordsNoWorkAndSaysSoInEveryField : Bool :=
  markerJson "/pkg" #["Pkg", "Other"] "https://example.invalid/o/r/blob/deadbeef" 3 none
      == "{\"tool\":\"litedoc4 build\",\"layout\":" ++ toString layoutVersion
        ++ ",\"root\":\"/pkg\",\"libs\":[\"Pkg\",\"Other\"],\
           \"sourceUrl\":\"https://example.invalid/o/r/blob/deadbeef\",\
           \"modules\":3,\"complete\":false,\"work\":null,\"version\":null,\"store\":null,\
           \"versionsExtracted\":null}\n"
    && ((markerJson "/pkg" #[] "u" 3
          (some (sampleWork, { version := "0123456789ab", store := "/s", extracted := true }))).splitOn
      ("\"complete\":true,\"work\":" ++ sampleWork.toJson ++ ",\"version\":\"0123456789ab\",\
        \"store\":\"/s\",\"versionsExtracted\":{\"count\":1,\"of\":1,\
        \"names\":[\"0123456789ab\"]}}")).length == 2
    && ((markerJson "/pkg" #[] "u" 3
          (some (sampleWork, { version := "0123456789ab", store := "/s", extracted := false }))).splitOn
      "\"versionsExtracted\":{\"count\":0,\"of\":1,\"names\":[]}}").length == 2

#guard anUnfinishedRunRecordsNoWorkAndSaysSoInEveryField

/-- `path` is `full` or `incremental`, which is the one field that says *which
extraction ran* — the counts beside it are plausible for either. The four
`*Seconds` are diagnostics and nothing may assert on their values; that they are
there at all is what a report reads. `site` is `store render`'s own record of
what the render wrote, carried as it printed it. -/
def theBuildRecordNamesWhichExtractionRan : Bool :=
  buildRecordJson "full" 3 3 1 sampleWork 3 512 "{\"command\":\"store render\"}" 0 0 0 0
      == "{\"command\":\"build\",\"path\":\"full\",\"modules\":3,\"extracted\":3,\"rounds\":1,\
          \"work\":" ++ sampleWork.toJson
        ++ ",\"ledgerModules\":3,\"ledgerBytes\":512,\"site\":{\"command\":\"store render\"},\
           \"extractSeconds\":0.000000000,\"putSeconds\":0.000000000,\
           \"renderSeconds\":0.000000000,\"totalSeconds\":0.000000000}"
    && ((buildRecordJson "incremental" 3 0 1 sampleWork 3 512 "{}" 0 0 0 0).splitOn
      "\"path\":\"incremental\",\"modules\":3,\"extracted\":0").length == 2

#guard theBuildRecordNamesWhichExtractionRan

def sampleRender : Summary := { pagesWritten := 5, modulesInIr := 5, bytes := 1234 }

def sampleGlobal : GlobalSummary := { cacheHits := 0, cacheMisses := 5 }

/-- `renderSeconds`, `globalSeconds` and `totalSeconds` are the **incremental
round's** names for the same two phases, so a full run's record and an
incremental one's subtract. A record that called them `siteSeconds` would be
readable and would stop being comparable, which is the failure nothing else here
would notice.

`totalSeconds` is the sum of the two rather than a third clock: `site` is
`render` then `global` over one tree and there is no third stage to hide in the
difference. -/
def theSiteRecordUsesTheIncrementalRoundsNamesForBothStages : Bool :=
  siteTimingsJson sampleRender sampleGlobal 100000000 200000000
    == "{\"command\":\"site\",\"pagesWritten\":5,\"modulesInIr\":5,\"pageBytes\":1234,\
        \"cacheHits\":0,\"cacheMisses\":5,\"renderSeconds\":0.100000000,\
        \"globalSeconds\":0.200000000,\"totalSeconds\":0.300000000}\n"

#guard theSiteRecordUsesTheIncrementalRoundsNamesForBothStages

end Litedoc4Test
