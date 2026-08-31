/- `crates/litedoc4/src/pipeline.rs`'s `gaps`: the wall-clock split one
incremental run reports.

`a_mark_that_precedes_its_predecessor_is_zero` has no check here and needs none.
Rust's `gaps` calls `saturating_sub` and the test is what says it does; `Nat`
subtraction truncates at zero, so a mark that ran backwards cannot become a
duration that did. What would falsify that: marks stored as anything signed. -/
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

end Litedoc4Test
