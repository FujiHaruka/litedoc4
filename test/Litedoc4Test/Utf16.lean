/- `crates/litedoc4-global/src/artifacts.rs::the_new_files_sort_in_utf16_order_too`.

The invariant, not the Rust test's shape: what that test reaches through
`Artifacts::derive` and two grepped bodies is one fact about the order the name
lists are in. Stated directly it is closed, so the compiler answers it and there
is nothing to run.

`#guard` and not a `theorem`: `by decide` cannot reduce any of this — `cmpUtf16`
is `Id.run do` around a `while`, whose `Loop.forIn` is `partial` and opaque to
the kernel, so reduction gets stuck at the `Decidable` instance (measured
2026-08-31 -> benchmarks/results/lean-test-scaffolding-2026-08-31.txt).
`by native_decide` does close it, by adding an ad-hoc
`ofReduceBool` axiom — the same interpreter `#guard` runs, dressed as a proof.
What would falsify the choice: implementations written structurally rather than
imperatively, which the kernel could then unfold. -/
import Litedoc4.Bytes
import Litedoc4.Ir.Utf16

namespace Litedoc4Test
open Litedoc4

def astral : String := "Pkg.𝒜.a"
def ligature : String := "Pkg.ﬀ.a"

def anAstralNameSortsBelowABmpOneInUtf16 : Bool :=
  sortUtf16 #[ligature, astral] == #[astral, ligature]

#guard anAstralNameSortsBelowABmpOneInUtf16

/-- The control arm. Without it the guard above holds under any order that
happens to put the two the right way round, and every other order in this tree
is `byteLt`. -/
def andByteOrderPutsThoseTwoTheOtherWayRound : Bool :=
  byteLt ligature astral

#guard andByteOrderPutsThoseTwoTheOtherWayRound

end Litedoc4Test
