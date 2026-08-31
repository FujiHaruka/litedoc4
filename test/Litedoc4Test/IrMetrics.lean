/- `crates/litedoc4-ir/src/metrics.rs::counts_by_kind_and_resets`. -/
import Litedoc4.Metrics
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4

/-- An `Invariant` and not a `#guard`: the counters are an `IO.Ref`, so there is
nothing to evaluate at elaboration time — the question only exists once
something has run.

**One invariant and not four**, for the reason the counters are process-wide:
two that each reset would race the other rather than check anything. -/
def theIrReadCountsAreByKindAndReset : Invariant where
  name := "IR reads are counted per kind, summed, and reset to zero"
  check := do
    resetIrReads
    let before ← irReads
    for _ in [0:4] do recordIrRead .module
    recordIrRead .index
    recordIrRead .depMap
    recordIrRead .depMap
    let counted ← irReads
    resetIrReads
    let after ← irReads
    return first [
      eq (before.index, before.module, before.depMap) (0, 0, 0),
      eq (counted.index, counted.module, counted.depMap) (1, 4, 2),
      eq counted.total 7,
      eq (after.index, after.module, after.depMap) (0, 0, 0)]

end Litedoc4Test
