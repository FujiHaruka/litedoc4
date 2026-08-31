/- The three records a run leaves on disk for something outside this tree to
read: `litedoc4-build.json`, `build --timings` and `site --timings`.

**Their field names are a wire format, not an output format.**
`tools/onemod-gate.sh` reads `work.pagesRendered` and `work.modulesExtracted`,
`tools/watch-gate.sh` reads the marker too, `tools/e2e-micro.sh` GATE 5 reads it
rather than grepping the log, and `benchmarks/tools/analyze.ts` aggregates the
timings JSONL by key. A renamed key does not fail anything: it makes an
aggregation return zero rows, and the gate that reads it green having checked
nothing.

Each of the four writers is already a pure function of the numbers, so there is
nothing to split — what was missing was anybody asking them. Stated as whole
lines: the failure to catch is a key nobody meant to add or drop, and a per-key
check cannot see one. -/
import Litedoc4.Main
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4

def sampleWork : WorkCounts :=
  { modulesExtracted := 1, pagesRendered := 2, mathFallbacks := 3, extractorRequests := 4
    cacheHits := 5, cacheMisses := 6, moduleSummaries := 7, moduleSummariesEchoingTheName := 8
    irReads := { index := 9, module := 10, depMap := 11 } }

/-- `globalCacheHits` / `globalCacheMisses` on the wire and `cacheHits` /
`cacheMisses` in the structure: the marker's names say *which* cache, because it
also carries the counts of a second one. Renaming either half to match the other
would be the tidy that breaks a reader outside this tree.

`irReads` is split by kind because only the module files divide into a number of
full passes, and `total` is written beside the three rather than left to the
reader — `tools/purelean-micro-gate.sh` item 13 reports it. -/
def theWorkCountsAreTheseKeysAndTheIrReadsAreSplitByKind : Bool :=
  sampleWork.toJson
      == "{\"modulesExtracted\":1,\"pagesRendered\":2,\"mathFallbacks\":3,\
          \"extractorRequests\":4,\"globalCacheHits\":5,\"globalCacheMisses\":6,\
          \"moduleSummaries\":7,\"moduleSummariesEchoingTheName\":8,\
          \"irReads\":{\"index\":9,\"module\":10,\"depMap\":11,\"total\":30}}"
    && sampleWork.irReads.total == 30

#guard theWorkCountsAreTheseKeysAndTheIrReadsAreSplitByKind

/-- **A run that did not finish records no work**, and says so twice: `complete`
is `false` and `work` is `null` rather than a record of zeros. The two are one
decision — the `Option` is the record — because a marker whose `complete` and
whose `work` disagreed would let a reader take the zeros for a run that did
nothing.

`layout` is the number a later run compares before it will write into a tree it
did not make. -/
def anUnfinishedRunRecordsNoWorkAndSaysSoInBothFields : Bool :=
  markerJson "/pkg" #["Pkg", "Other"] "https://example.invalid/o/r/blob/deadbeef" 3 none
      == "{\"tool\":\"litedoc4 build\",\"layout\":" ++ toString layoutVersion
        ++ ",\"root\":\"/pkg\",\"libs\":[\"Pkg\",\"Other\"],\
           \"sourceUrl\":\"https://example.invalid/o/r/blob/deadbeef\",\
           \"modules\":3,\"complete\":false,\"work\":null}\n"
    && ((markerJson "/pkg" #[] "u" 3 (some sampleWork)).splitOn
      "\"complete\":true,\"work\":{").length == 2

#guard anUnfinishedRunRecordsNoWorkAndSaysSoInBothFields

/-- `path` is `full` or `incremental`, which is the one field that says *which of
the two pipelines ran* — the counts beside it are plausible for either. The four
`*Seconds` are diagnostics and nothing may assert on their values; that they are
there at all is what a report reads.

`pagesInSite` is counted after the assets are written, so it is the tree that
shipped rather than a stage of it, and it is therefore not `pagesRendered` even
on a full run. -/
def theBuildRecordNamesWhichPipelineRan : Bool :=
  buildRecordJson "full" 3 3 1 sampleWork 3 15 3 512 0 0 0 0
      == "{\"command\":\"build\",\"path\":\"full\",\"modules\":3,\"extracted\":3,\"rounds\":1,\
          \"work\":" ++ sampleWork.toJson
        ++ ",\"pagesRendered\":3,\"pagesInSite\":15,\"ledgerModules\":3,\"ledgerBytes\":512,\
           \"extractSeconds\":0.000000000,\"renderSeconds\":0.000000000,\
           \"globalSeconds\":0.000000000,\"totalSeconds\":0.000000000}"
    && ((buildRecordJson "incremental" 3 0 1 sampleWork 0 15 3 512 0 0 0 0).splitOn
      "\"path\":\"incremental\",\"modules\":3,\"extracted\":0").length == 2

#guard theBuildRecordNamesWhichPipelineRan

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
