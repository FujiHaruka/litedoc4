import Example.Basic

/-!
# A signature printed with the package's own notation

`scoped notation` declared by the package itself, and a signature that uses it.

A signature is printed the way Lean prints it, with the package's own notation
in scope — so `useNotation` below reads as `⟦n⟧` rather than as the application
underneath it.
-/

/-
This is the one shape doc-gen4 cannot print for a package's own declarations. If
litedoc4 ever loses `Lean.activateScoped`, `useNotation`'s signature stops
printing as `⟦n⟧`, and this module is where that shows.
-/

namespace Example

/-- Doubling, written with brackets. -/
scoped notation "⟦" x "⟧" => Example.double x

/-- A definition whose *signature* uses the scoped notation. -/
def useNotation (n : Nat) : Nat := ⟦n⟧

end Example
