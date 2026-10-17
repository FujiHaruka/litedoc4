/- The loop condition of the rounds `build` runs.

The stages themselves are answered where they live (`IncrLedger`, `IncrMerge`,
`IncrOwnership`); what only exists here is the sequencing, and `anotherRound`
is the part of it that reads nothing.

What is **not** here, and is a gate rather than a test: a run that changes
nothing and a one-module edit need a real package, which is `tools/e2e-micro.sh`
GATE 2 and GATE 6. -/
import Litedoc4.Incr.Pipeline

namespace Litedoc4Test
open Litedoc4

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

end Litedoc4Test
