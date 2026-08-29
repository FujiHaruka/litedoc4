/-!
# Basic

The kinds a declaration comes in, each with a docstring of its own: `def`,
`theorem`, `structure`, `instance`, `abbrev` and `inductive`. Every page on this
site is laid out the same way, so this is the one to read first.

This module imports nothing of its own, so the only entry in its import list is
the `Init` every Lean module gets.
-/

namespace Micro

/-- Twice `n`. A plain definition with a docstring — the smallest thing a page
has to show. -/
def double (n : Nat) : Nat := n + n

/-- A theorem about `double`. Its statement names another declaration of this
package, and the signature on the page links to it. -/
theorem double_eq (n : Nat) : double n = 2 * n := by
  simp [double, Nat.two_mul]

/-- A structure. Its fields carry docstrings of their own and are listed on the
page, each with an anchor to link to. -/
structure Point where
  /-- The first coordinate. -/
  x : Nat
  /-- The second coordinate. -/
  y : Nat

/-- An instance for `Point`, which the site gathers under **Instances For**
rather than leaving it to be found by name. -/
instance : Inhabited Point := ⟨{ x := 0, y := 0 }⟩

/-- An `abbrev`. The page prints the kind, so an `abbrev` and a `def` are told
apart without reading the source. -/
abbrev Nat2 := Nat

/-- An inductive. Its constructors are rendered as members, each with an anchor
of its own. -/
inductive Colour where
  /-- The first constructor. -/
  | red
  /-- The second constructor. -/
  | green

/-- A definition that matches on `Colour`, so Lean generates equations for it and
the page prints them. -/
def Colour.name : Colour → String
  | .red => "red"
  | .green => "green"

end Micro
