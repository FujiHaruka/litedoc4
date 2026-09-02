/- The four decisions one round makes, and the record it writes.

The stages themselves are answered where they live (`IncrLedger`, `IncrMerge`,
`IncrImpact`, `IncrPrune`, `GlobalBuild`, `RenderSite`); what only exists here is
the sequencing, and the four things below are the part of it that reads nothing —
`anotherRound`, `renderModeOf`, `renderSetOf` and `incrTimingsLine` were split
out of `runIncremental` for that reason.

What is **not** here, and is a gate rather than a test:
`the_seven_states_match_full_generation` and `a_re_extraction_that_changes_nothing
_rewrites_nothing` are `tools/e2e-micro.sh` GATE 6 / GATE 2 and
`tools/purelean-micro-gate.sh` item 16; `the_name_map_is_snapshotted_before_the
_round_overwrites_it` and `a_moved_declaration_takes_two_rounds` need a real
package whose declarations move, which is `tools/e2e-micro.sh` GATE 6 (it appends
a declaration) and `tools/build-gate.sh` phases 3–4.

`a_mark_that_precedes_its_predecessor_is_zero` has no check here and needs none.
Rust's `gaps` calls `saturating_sub` and the test is what says it does; `Nat`
subtraction truncates at zero, so a mark that ran backwards cannot become a
duration that did. What would falsify that: marks stored as anything signed.

`an_empty_regeneration_set_renders_nothing_twice_over` has none either: the
renderer takes a `ModuleSet`, and `.these` over an empty set is a different value
from `.all`, so "no subset asked for" and "the subset came out empty" cannot be
the same input. What would falsify it: a renderer taking `Array String` with the
empty array meaning everything.

`a_page_tree_with_no_name_map_runs_with_the_delta_off` has none for the same
reason: `GlobalOptions.before` is an `Option`, and `buildGlobal` writes
`--print-set` and `--delta-json` **inside** the `some` branch, so a run with no
map to compare against cannot write half a delta. -/
import Litedoc4.Incr.Pipeline

namespace Litedoc4Test
open Litedoc4

/-- The four cumulative marks of Rust's own fixture, in nanoseconds, with the
third sitting on the second — the shape a skipped phase leaves, since `prune`
does not run when nothing was removed. -/
def marksWithASkippedPhase : IncrMarks :=
  { started := 0, detectDone := 100000000, roundsDone := 250000000
    pruneDone := 250000000, globalDone := 900000000
    impactDone := 1000000000, renderDone := 1200000000
    extract := 7, ownership := 11, merge := 13 }

/-- Each phase is the gap from the mark before it, so **a phase that did nothing
is zero and not the mark's own value** — the difference between "prune took no
time" and "prune took a quarter of a second", printed to a reader trying to find
where a slow run went.

`extract`, `ownership` and `merge` are not differences at all: they are summed
over the rounds, which run interleaved between `detectDone` and `roundsDone`, so
they pass through and are covered by `rounds` rather than partitioning it. That
is also why the totals do not add up to `total`, and why `total` is measured end
to end rather than summed. -/
def eachPhaseIsTheGapFromTheMarkBeforeIt : Bool :=
  let t := IncrTimings.ofMarks marksWithASkippedPhase
  t.detect == 100000000
    && t.rounds == 150000000
    && t.prune == 0
    && t.global == 650000000
    && t.impact == 100000000
    && t.render == 200000000
    && t.total == 1200000000
    && t.extract == 7 && t.ownership == 11 && t.merge == 13

#guard eachPhaseIsTheGapFromTheMarkBeforeIt

/-- The four states of the loop condition. The one that would be silent is the
third: **a run whose only work is a deletion has nothing to re-extract**, so a
loop that only counted the round's input would never start, the merge that drops
the module from `index.json` would never happen, and the page would stay on the
site for ever with every count in the marker reading zero.

The fourth is its bound — the deletion belongs to round 1 and is not offered to
round 2, or a run with one deleted module and nothing stale would never stop. -/
def aDeletionAloneRunsExactlyOneRound : Bool :=
  anotherRound #[] 0 #[] == false
    && anotherRound #["Pkg.A"] 0 #[] == true
    && anotherRound #[] 0 #["Pkg.C"] == true
    && anotherRound #[] 1 #["Pkg.C"] == false
    && anotherRound #["Pkg.A"] 3 #[] == true

#guard aDeletionAloneRunsExactlyOneRound

/-- A moved render key, or a dependency map this run rewrote, **replaces**
`--mode` with `all`. The two are separate inputs because either can move without
the other: the key is compared at the head of the run, and the map is one the
run's own extractor may have rewritten since.

The last clause is the half a reading of the flag would leave out — with neither
moved, the asked-for mode is the answer, so this cannot pass by always saying
`all`. -/
def aMovedRenderKeyOrARewrittenMapReplacesTheAskedForMode : Bool :=
  (renderModeOf true false .selfOnly).name == "all"
    && (renderModeOf false true .selfOnly).name == "all"
    && (renderModeOf true true .importers).name == "all"
    && (renderModeOf false false .selfOnly).name == "self"
    && (renderModeOf false false .importers).name == "importers"

#guard aMovedRenderKeyOrARewrittenMapReplacesTheAskedForMode

/-- The render set is the **union** of the changed set's closure and the pages
the whole-package map's delta names, and neither half is a superset of the other.

A round that dropped the global half renders nothing when a declaration moved
between modules whose own IR did not change — the shape a stale `name-map.json`
produces, where `impact` writes no selection at all. A round that dropped the
impact half renders nothing when the map did not move. Both read as a working
pipeline from the outside. -/
def eitherHalfOfTheRenderSetAloneReachesTheRenderer : Bool :=
  let of (a b : Array String) := sortUtf16 (renderSetOf a b).toArray
  of #[] #["Pkg.C"] == #["Pkg.C"]
    && of #["Pkg.A"] #[] == #["Pkg.A"]
    && of #["Pkg.B", "Pkg.A"] #["Pkg.C"] == #["Pkg.A", "Pkg.B", "Pkg.C"]
    && of #["Pkg.A"] #["Pkg.A"] == #["Pkg.A"]
    && of #[] #[] == #[]

#guard eitherHalfOfTheRenderSetAloneReachesTheRenderer

def roundSummary : IncrSummary :=
  { rounds := 1, staleFound := 0, changed := 1, removed := 0, irChanged := 1
    globalStale := 0, pagesRendered := 1, mathFallbacks := 0
    cacheHits := 2, cacheMisses := 3, summariesRendered := 4, summariesEchoingTheName := 5
    mode := "self" }

/-- The nested per-stage records as `writeTimings` reads them back: `extract`
wrote none this round, `merge` and `render` wrote one each. -/
def roundNested : Array (String × Array JVal) :=
  #[("extract", #[]),
    ("merge", #[.obj #[("command", .str "merge")]]),
    ("render", #[.obj #[("pagesWritten", .num 1)]])]

/-- **The field names are the contract**: `benchmarks/tools/analyze.ts` and every
JSONL already under `benchmarks/results/` read them, and a renamed key makes an
aggregation return zero rows rather than an error.

Three claims a per-key check could not make. `serve` is written on **both**
paths, so a resident run and a one-shot one are told apart in the record, while
`jobs` and `serveGeneration` are the resident path's alone — behind `--extractor`
the job count is inside somebody else's argument list, and a number this command
cannot see is left out rather than guessed at. A stage that wrote no record
leaves **no key**, rather than a `null` an aggregation would read as a
measurement. And the summary's four cache and description counts are deliberately
absent: they belong to `litedoc4-build.json`, and a record carrying them twice is
one whose two copies can disagree.

Stated as the whole line, because the failure to catch is a key nobody meant to
add. -/
def theIncrementalRecordIsTheseFieldsAndNoOthers : Bool :=
  incrTimingsLine roundSummary (IncrTimings.ofMarks marksWithASkippedPhase) .oneShot roundNested
    == "{\"mode\":\"self\",\"serve\":false,\
        \"detectSeconds\":0.100000000,\"extractSeconds\":0.000000007,\
        \"ownershipSeconds\":0.000000011,\"mergeSeconds\":0.000000013,\
        \"roundsSeconds\":0.150000000,\"pruneSeconds\":0.000000000,\
        \"globalSeconds\":0.650000000,\"impactSeconds\":0.100000000,\
        \"renderSeconds\":0.200000000,\"totalSeconds\":1.200000000,\
        \"rounds\":1,\"staleFound\":0,\"changed\":1,\"removed\":0,\"irChanged\":1,\
        \"globalStale\":0,\"pagesRendered\":1,\"mathFallbacks\":0,\
        \"merge\":{\"command\":\"merge\"},\"render\":{\"pagesWritten\":1}}"

#guard theIncrementalRecordIsTheseFieldsAndNoOthers

/-- The resident path's two extra fields, and where they sit: beside `serve`
rather than among the durations, because a reader grepping the JSONL for a run's
configuration reads the head of the line.

A round that ran more than once carries an **array** under the stage's name, not
the last record — the per-round numbers are what a report subtracts. -/
def theResidentPathAddsItsJobCountAndItsGeneration : Bool :=
  let line := incrTimingsLine { roundSummary with rounds := 2 }
    (IncrTimings.ofMarks marksWithASkippedPhase) (.resident 4 "abcd")
    #[("extract", #[.obj #[("targetModules", .num 1)], .obj #[("targetModules", .num 2)]])]
  (line.splitOn "\"mode\":\"self\",\"serve\":true,\"jobs\":4,\"serveGeneration\":\"abcd\",").length
      == 2
    && (line.splitOn "\"extract\":[{\"targetModules\":1},{\"targetModules\":2}]").length == 2
    && (line.splitOn "\"merge\"").length == 1
    && (line.splitOn "\"module\"").length == 1

#guard theResidentPathAddsItsJobCountAndItsGeneration

end Litedoc4Test
