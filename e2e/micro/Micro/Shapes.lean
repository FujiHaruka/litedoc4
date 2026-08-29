import Micro.Basic

/-!
# Shapes

The declaration kinds `Micro.Basic` does not have, each printed differently from
the others: a `class`, a `class inductive`, a structure whose constructor has a
name of its own, a structure that inherits a field, a field carrying an implicit
binder, and a class extending one from Lean core.

`Micro.Basic` is the module with no imports; the rest of the unusual shapes live
here.
-/

/-
Nine of the renderer's branches never fire over the measurement target — no
`class`, no `inductive`, no `class_inductive`, no structure whose constructor is
not `mk`, no structure without a `ctor` member, no inherited field declared
inside its structure's range, no implicit binder on a field, no module without
imports. Curated unit tests reach them with hand-written IR; this module is what
reaches them through the real pipeline, so do not thin it out.

`Micro.Preferred` is a regression: a class extending one whose defining module is
outside the package made `litedoc4 build` stop with `no defining module for
Std.OrientedCmp.eq_swap`, having rendered nothing, on the first page it was
pointed at in `batteries` (measured 2026-08-17). The measurement target never
produced the shape.
-/

namespace Micro

/-- A class, whose members are printed with the class rather than as
declarations of their own. -/
class Greet (α : Type) where
  /-- How to greet a value. -/
  greet : α → String

/-- An instance of that class, so that `Greet` has something to list under
**Instances**. -/
instance : Greet Nat where
  greet n := s!"hello {n}"

/-- A `class inductive`: a class whose declaration is an inductive type rather
than a structure. It is the widest kind there is, and the page has to keep the
signature next to it readable. -/
class inductive Decision (p : Prop) where
  /-- The negative case, carrying a refutation. -/
  | no (refutation : p → False)
  /-- The positive case, carrying a proof. -/
  | yes (proof : p)

/-- A structure whose constructor is **not** `mk`. The page prints the name the
source gave it. -/
structure Named where
  /-- The named constructor. -/
  make ::
  /-- The only field. -/
  value : Nat

/-- The base of an `extends`, so that `Derived` below has a field to inherit. -/
structure Base where
  /-- A field that `Derived` inherits. -/
  b : Nat

/-- A structure with an inherited field, which the page lists alongside the
structure's own. -/
structure Derived extends Base where
  /-- A field of its own. -/
  d : Nat

/-- A structure with an **implicit binder** on a field, which the signature keeps
in braces. -/
structure Poly where
  /-- A field whose own signature binds a type implicitly. -/
  apply : {α : Type} → α → α

/-- A class extending one that belongs to **Lean core rather than to this
package**, so the field it inherits was declared outside this site entirely.

`Derived` above inherits from `Base`, which this package declares; here the
inherited `default` comes from `Inhabited`, which it does not. -/
class Preferred (α : Type) extends Inhabited α where
  /-- Why the inherited `default` is the preferred value. -/
  reason : String

/-- An instance, so the class above lists one like `Greet` does. -/
instance : Preferred Nat where
  default := 7
  reason := "seven is small and not zero"

end Micro
