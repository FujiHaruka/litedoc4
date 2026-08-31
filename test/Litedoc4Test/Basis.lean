/- What a runtime invariant is, and the only two things it can say.

Nothing here for the invariants that hold at compile time: those are a `Bool`
with the invariant's name on it and a `#guard`, and a helper would only stand
between the name and the failure message. -/

namespace Litedoc4Test

/-- A named invariant and what it answers: `none` is "held", `some` is the one
line printed when it is not. The line has to name what differed — an invariant
lands here rather than under a `#guard` precisely because `#guard` cannot. -/
structure Invariant where
  name : String
  check : IO (Option String)

/-- `assert_eq!`, and `expect_err` too — a refusal is `eq (parse bad) none`.
Both sides go into the message; a bare "not equal" would make the invariant's
own name the only thing a failure said. -/
def eq [BEq α] [Repr α] (got expected : α) : Option String :=
  if got == expected then none else some s!"got {repr got}, expected {repr expected}"

/-- One invariant stated in several parts answers with its first broken part. -/
def first (parts : List (Option String)) : Option String := parts.findSome? id

/-- Failures on stderr, the count on stdout, and the count is of what ran rather
than of what was written down — a runner that reported the length of its own
argument list could not tell "all held" from "none was reached". -/
def run (invariants : List Invariant) : IO UInt32 := do
  let mut ran := 0
  let mut failed := 0
  for inv in invariants do
    ran := ran + 1
    if let some why ← inv.check then
      IO.eprintln s!"FAIL {inv.name}: {why}"
      failed := failed + 1
  IO.println s!"litedoc4-test: {ran} invariants ran, {failed} failed"
  return if failed == 0 then 0 else 1

end Litedoc4Test
