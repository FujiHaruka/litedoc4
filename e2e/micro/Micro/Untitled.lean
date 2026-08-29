import Micro.Basic

/-!
A module docstring that opens with prose instead of a title.

The front page describes each module by the heading its docstring opens with.
This one opens with a paragraph, so the front page lists it by name and says
nothing more about it — which is what a module that has not introduced itself
should look like, rather than an empty space where a description would go.
-/

/-
`tools/e2e-micro.sh` GATE 13 reads this module's row on the front page. Do not
give this docstring a `# ` heading: it is the negative case, and without one
module that has none, nothing tells a front page that describes every module
apart from one that draws an empty element for the modules it cannot describe.
-/

namespace Micro.Untitled

/-- The two states a coin can be in. Ordinary in every way; the module it lives
in is what this page is about. -/
inductive Coin where
  | heads
  | tails

/-- The other face of `c`. -/
def Coin.flip : Coin → Coin
  | .heads => .tails
  | .tails => .heads

/-- Flipping twice is doing nothing. -/
theorem Coin.flip_flip (c : Coin) : c.flip.flip = c := by
  cases c <;> rfl

end Micro.Untitled
