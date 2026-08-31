/- `crates/litedoc4-render/src/site.rs`: the whole of `litedoc4 render`.

Only one invariant is left to state, and half of it is already a type: `ModuleSet`
is an inductive, so "the caller computed a set and it came out empty" cannot be
spelled the same way as "the caller did not ask for a subset". What a check still
has to say is what the *text* of a render set means. -/
import Litedoc4.Render.Site
import Litedoc4Test.RenderFrame

namespace Litedoc4Test
open Litedoc4

/-- Blank lines are dropped, **an empty file is an empty set**, and an empty set
writes nothing. Split on `\n` rather than through a `lines` helper that also
drops a `\r` before it: the trim removes that `\r` and the empty last element of
a text ending in a newline, so the two spellings cannot differ. -/
def anEmptyModuleSetIsNotTheAbsenceOfOne : Bool :=
  let listed := ModuleSet.fromLines "Pkg.One\n"
  !(ModuleSet.these (moduleSetLines "")).contains "Pkg.One"
    && ModuleSet.all.contains "Pkg.One"
    && (moduleSetLines "").isEmpty
    && (moduleSetLines "\n  \n").isEmpty
    && (moduleSetLines "Pkg.One\r\nPkg.Two\n").toArray.qsort byteLt == #["Pkg.One", "Pkg.Two"]
    && listed.contains "Pkg.One" && !listed.contains "Pkg.Two"

#guard anEmptyModuleSetIsNotTheAbsenceOfOne

end Litedoc4Test
