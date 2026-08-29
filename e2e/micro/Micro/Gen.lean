/-!
# Declarations Lean realized from an attribute

And, next to them, the ones that only look as if Lean had.

`@[ext]` on a structure makes Lean realize extensionality theorems for it. Such
a declaration is given the position of the **attribute token**, not of the
structure it belongs to, so no rule over source positions recovers the parent.
litedoc4 names the origin instead: a realized declaration is marked **realized
by `@[ext]` from …**, linking the declaration it came from, and its source link
points at the attribute, which is where Lean put it.

The four positions below are what makes that a claim rather than a guess:

| | |
|---|---|
| `Pair` | `@[ext]` written on the structure. Both realized theorems land **inside** the parent's own range |
| `Trip` | `attribute [ext] Trip` on a later line. The realized theorems land **completely outside** the parent's range |
| `Quad` / `Quint` | `attribute [ext] Quad Quint` — **one position, two parents, four realized theorems** |
| `Solo` | a **hand-written** `@[ext] theorem`. It sits in the same table as the realized ones and gets the **opposite** answer |

`PairPlus` adds the parent projection `toPair`, which Lean realizes as well but
not from `@[ext]`: it stays unmarked too.
-/

/-
`tools/e2e-micro.sh` GATE 9 compares the origins over this module whole,
positives *and* negatives, so the shapes here are the gate's input:

- Do not fold `Micro.Gen.Solo.ext` into `@[ext] structure Solo`. A hand-written
  ext theorem is in the environment extension exactly like a realized one, and
  this is the only declaration keeping "is in the extension" from being read as
  "was realized" — Mathlib has 20 of this shape (measured 2026-08-21).
- Do not add or remove a declaration without updating the counts the gate names:
  9 declarations claim an origin, and 33 of the 42 whose `selectionRange` equals
  their `range` claim none.

`@[ext]` is the only such attribute the extractor can name without importing
Mathlib — `extExtension` is Lean core's, while `simps`, `to_additive`, `mk_iff`
and `to_dual` are Mathlib's, and an extractor that imported Mathlib would stop
building against this package.
-/

namespace Micro.Gen

/-- A structure carrying `@[ext]` inline. `Pair.ext` and `Pair.ext_iff` are
realized at the `ext` token on the attribute line, which is inside this
declaration's own range. -/
@[ext]
structure Pair where
  /-- The first component. -/
  fst : Nat
  /-- The second component. -/
  snd : Nat

/-- A structure whose `@[ext]` arrives later, as a separate `attribute` command.
Its realized theorems land outside this range entirely. -/
structure Trip where
  /-- The first component. -/
  a : Nat
  /-- The second component. -/
  b : Nat
  /-- The third component. -/
  c : Nat

attribute [ext] Trip

/-- One of the two structures a single `attribute [ext] Quad Quint` marks. -/
structure Quad where
  /-- The only component. -/
  q : Nat

/-- The other one. Four theorems are realized at that one position, with two
different parents between them, and each still names its own. -/
structure Quint where
  /-- The only component. -/
  r : Nat

attribute [ext] Quad Quint

/-- A structure extending `Pair`, so that the parent projection `toPair` is
realized as well. It does not come from `@[ext]`, and is not marked as if it
did. -/
structure PairPlus extends Pair where
  /-- The extra component. -/
  extra : Nat

/-- A structure with **no** `@[ext]` on it. The extensionality theorem below is
written out by hand instead. -/
structure Solo where
  /-- The only component. -/
  s : Nat

/-- A **hand-written** extensionality theorem carrying `@[ext]`.

Being in the same table as the realized theorems is not the same as having been
realized: this one has a source of its own, so its page claims no origin. The
`Solo.ext_iff` that the attribute realizes *from* it is a different matter, and
does. -/
@[ext]
theorem Solo.ext : ∀ {x y : Solo}, x.s = y.s → x = y
  | ⟨_⟩, ⟨_⟩, rfl => rfl

end Micro.Gen
