import Micro.Basic

/-!
# The two marks an incomplete proof leaves on a page

Three declarations: one with a hole of its own, one that depends on it, and one
with neither.

A declaration whose own statement or proof uses `sorry` is marked **uses
`sorry`**. One whose own proof is complete but which depends on such a
declaration is marked **depends on `sorry`**. Those are different claims and the
page keeps them apart. The answer comes from the compiled environment — the
declaration's axiom set — so it holds through any depth of dependency, and a
declaration marked neither has no hole anywhere under it.
-/

/-
Do not "fix" these proofs. `sorryHole` is the input and the other two are the
answers that have to differ from it, so `tools/e2e-micro.sh` GATE 7 checks all
three by name and counts how many it compared.

They are here rather than in `Micro/Basic.lean` because `sorry` makes `lake
build` print a warning for the whole module, and GATE 6 appends a probe
declaration to `Basic.lean` — a module whose build is already noisy is a bad
place to read a new warning out of.
-/

namespace Micro.Sorry

/-- A theorem proved by `sorry`: its own proof term is the hole, so the page
marks it **uses `sorry`**. This is the declaration the other two are defined
against. -/
theorem sorryHole (n : Nat) : Micro.double n = n + n := by
  sorry

/-- A theorem with a complete proof of its own that *uses* `sorryHole`. Its term
never mentions the hole, so the page marks it **depends on `sorry`** — the weaker
of the two claims, and the reason there are two. -/
theorem usesHole (n : Nat) : Micro.double n = 2 * n := by
  rw [sorryHole, Nat.two_mul]

/-- A theorem that depends on neither, and is marked neither. -/
theorem noHole (n : Nat) : Micro.double n + 0 = Micro.double n :=
  Nat.add_zero _

end Micro.Sorry
