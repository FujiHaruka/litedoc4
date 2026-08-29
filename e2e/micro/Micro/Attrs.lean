/-!
# Attrs

One declaration per kind of attribute, so that a page can be read next to the
source to see how each of them is printed.

An attribute reaches the page as a **name** and a **value**, kept apart: the
value is whatever Lean elaborated the argument to, and it is not always a word.

| kind | here |
|---|---|
| custom, no value | `@[simp]`, `@[reducible]` |
| tag, no value | `@[match_pattern]` |
| enum, the name *is* the value | `@[inline]` |
| parametric, empty value | `@[specialize]` — prints `#[]` |
| parametric, value with spaces | `@[deprecated … (since := …)]` |
| instance priority | `instance (priority := 100)` |

The two parametric ones are why the halves stay apart. A `deprecated` value
carries spaces, parentheses and quotes; a `specialize` value carries brackets.
Run together into one string, neither can be taken apart again by a reader who
does not already know where the name ends.

This module imports nothing.
-/

/-
Two obligations, one for each of two gates in `tools/e2e-micro.sh`:

- No imports on purpose. GATE 6 appends its probe to `Micro/Basic.lean`, and
  every module importing it is re-rendered by that edit; importing it here would
  spend that gate's `pagesRendered < modules` margin to buy nothing.
- Do not tidy the attributes away, and do not add one casually. Each line below
  is the only occurrence of its kind in this repository, and GATE 8 counts the
  assertions it made per attribute name — adding a structure adds `reducible`
  through its projections, and the gate names the number to update.

Nothing uses `scaleOld`, and nothing should: a use makes `lake build` print a
deprecation warning, and this package's warnings are read.
-/

namespace Micro.Attrs

/-- An enum-valued attribute: its printed form is the enum's own name, with no
argument after it. -/
@[inline] def scale (n : Nat) : Nat := n * 2

/-- A custom attribute with no value: the plainest shape there is, a name and
nothing after it. -/
@[simp] theorem scale_zero : scale 0 = 0 := rfl

/-- An attribute that comes from the declaration's reducibility status rather
than from a list written in the source. -/
@[reducible] def Weight : Type := Nat

/-- A tag attribute: it marks the declaration and carries nothing else. -/
@[match_pattern] def zero : Nat := 0

/-- A parametric attribute whose value is empty in *this* use but is still a
value: `specialize` takes an `Array Nat`, so with no argument the printed form is
`#[]`. Brackets in a value are what a page has to carry through unharmed. -/
@[specialize] def applyTwice (f : Nat → Nat) (n : Nat) : Nat := f (f n)

/-- A parametric attribute whose value **contains spaces, parentheses and
quotes**. It names the declaration that replaces this one, and that name is
printed as part of the value. -/
@[deprecated scale (since := "2026-08-21")]
def scaleOld (n : Nat) : Nat := n * 2

/-- A class of its own rather than one of Lean's, so that the two instances
below are the only ones in scope and their priorities compete with nothing. -/
class Tiny (α : Type) where
  /-- The small element. -/
  tiny : α

/-- An instance with a priority. A default priority is not printed; this one is
not the default, so the page shows it. -/
instance (priority := 100) tinyNat : Tiny Nat := ⟨0⟩

/-- A default instance, which carries its priority even though the source names
no number: the two lines together show the value is read off the environment
rather than off the text. -/
@[default_instance] instance tinyBool : Tiny Bool := ⟨false⟩

end Micro.Attrs
