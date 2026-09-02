/- `String.lt` and `Name.lt`, the order a page's import list is sorted in.

All closed and none of it reaches `Md.events`, so the compiler answers them and
there is nothing to run. -/
import Litedoc4.Render.Order

namespace Litedoc4Test
open Litedoc4

/-- `ﬀ` before `𝒜` is where this parts company with the order the whole-package
artifacts use. That the UTF-16 side really answers the other way round is
`Litedoc4Test.Utf16`'s two guards, and stating it in both places would leave one
of them the copy nobody reads when the pair stops being the right one. -/
def stringLtIsCodePointOrder : Bool :=
  byteLt "a" "b" && byteLt "Nat" "Nat.succ" && !byteLt "Nat" "Nat"
    && byteLt "A" "ℕ" && byteLt "ﬀ" "𝒜"

#guard stringLtIsCodePointOrder

def shorterNamesSortFirstWhateverTheStrings : Bool :=
  nameLtC #["Zzz"] #["Aaa", "Bbb"] && !nameLtC #["Aaa", "Bbb"] #["Zzz"]
    && nameLtC #[] #["Aaa"] && !nameLtC #[] #[] && !nameLtC #["Aaa"] #[]

#guard shorterNamesSortFirstWhateverTheStrings

/-- The second pair is the one a comparison of the last components alone would
get backwards. -/
def parentsDecideBeforeTheLastComponent : Bool :=
  nameLtC #["Mathlib", "Algebra"] #["Mathlib", "Order"]
    && nameLtC #["Mathlib", "Zzz"] #["Order", "Aaa"]

#guard parentsDecideBeforeTheLastComponent

/-- `Init` and `Mathlib` both come before `Init.Core`, which no order over the
strings gives. -/
def sortingMatchesThePrototypeComparator : Bool :=
  Array.qsort
      #["Mathlib.Order.Basic", "Init", "Mathlib.Algebra.Group", "Mathlib", "Init.Core"] nameLt
    == #["Init", "Mathlib", "Init.Core", "Mathlib.Algebra.Group", "Mathlib.Order.Basic"]

#guard sortingMatchesThePrototypeComparator

end Litedoc4Test
