/- Which declarations of a module sit inside another's range. -/
import Litedoc4.Data.Content

namespace Litedoc4Test
open Litedoc4

/-- A schema-5 module holding exactly these declarations, at `Pkg.M`. -/
def declModule (decls : Array Decl) : Module :=
  { name := "Pkg.M", schemaVersion := 5, decls }

/-- The population is every declaration the IR carries for the module, including
the ones that get no page entry, and both comparisons are non-strict on the inner
coordinate — a field declared at exactly the structure's own start counts. -/
def containedNamesUsesClosedRanges : Bool :=
  let at_ (name : String) (l c el ec : Nat) : Decl :=
    { name, kind := "definition", line := l, col := c, endLine := el, endCol := ec }
  let parent := at_ "S" 10 2 20 8
  let m := declModule #[parent, at_ "exact" 10 2 20 8, at_ "inside" 11 0 19 99,
    at_ "startsBefore" 10 1 20 8, at_ "endsAfter" 10 2 20 9,
    at_ "linesBefore" 9 99 20 8, at_ "linesAfter" 10 2 21 0]
  (containedNames m parent).toArray.qsort byteLt == #["exact", "inside"]

#guard containedNamesUsesClosedRanges

end Litedoc4Test
