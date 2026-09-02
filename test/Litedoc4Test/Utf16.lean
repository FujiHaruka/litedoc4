/- The order the whole-package name lists are in. Stated directly it is closed,
so the compiler answers it and there is nothing to run.

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

/-- The half the two guards above do not reach. Throughout the BMP the two orders
**agree** — that is what makes the inversion above it the whole of the
difference, and what stops `cmpUtf16` from being some third order that merely
happens to put an astral name first. -/
def utf16OrderAgreesWithByteOrderThroughoutTheBmp : Bool :=
  [("", "a"), ("a", "b"), ("Nat", "Nat.succ"), ("α", "β"), ("A", "ℕ"), ("∑", "∏")].all
    fun (a, b) => ltUtf16 a b == byteLt a b && ltUtf16 b a == byteLt b a

#guard utf16OrderAgreesWithByteOrderThroughoutTheBmp

end Litedoc4Test
