/- `crates/litedoc4-render/src/link_index.rs`: the dependency closure's `.lidx`,
which is where a name this run never extracted gets its defining module and its
source line range.

Line-oriented, first byte decides, **no error path** — the file is written by
this same toolchain, so a garbled one has to cost a link its `#L…-L…` anchor and
never the site. That is a claim about every malformed shape, not only the ones a
writer produces, so the malformed shapes are guarded here beside the well-formed
ones.

`Entry`'s twelve bytes, `module_count` and `ranged_len` have no counterpart:
the first is a Rust storage layout, and the other two are read by nothing in
either product. -/
import Litedoc4.Render.LinkIndex

namespace Litedoc4Test
open Litedoc4

def lidxSample : String :=
  "#lidx2\n@Mathlib.Order.Basic\n@Mathlib.Init\nMathlib.Order.Basic\n\
   \tMathlib.Order.le_refl\t67\t67\n\tMathlib.Order.le_trans\t70\t74\n\
   Mathlib.Data.Nat\n\tNat.succ\n"

def moduleIn (l : Lidx) (name : String) : Option String :=
  (l.names.get? name).map (·.module)

def rangedCount (l : Lidx) : Nat :=
  l.names.toArray.foldl (fun n (name, _) => if (l.rangeOf name).isSome then n + 1 else n) 0

/-- The `@` section and the group headers are different sets and answer
different questions: `Mathlib.Data.Nat` heads a group and is not an `@` entry,
so a reader that folded the two would make it a link target it is not. -/
def readsGroupsAndModuleNames : Bool :=
  let l := parseLidx lidxSample
  l.names.size == 3 && l.modules.size == 2
    && moduleIn l "Mathlib.Order.le_refl" == some "Mathlib.Order.Basic"
    && moduleIn l "Nat.succ" == some "Mathlib.Data.Nat"
    && moduleIn l "Nat.pred" == none
    && l.modules.contains "Mathlib.Init"
    && !l.modules.contains "Mathlib.Data.Nat"

#guard readsGroupsAndModuleNames

/-- `none` covers two things — a name the map does not hold, and a name it holds
with no range — and `moduleIn` is what tells them apart. -/
def aDeclarationCarriesItsLineRangeWhenTheWriterHadOne : Bool :=
  let l := parseLidx lidxSample
  l.rangeOf "Mathlib.Order.le_refl" == some (67, 67)
    && l.rangeOf "Mathlib.Order.le_trans" == some (70, 74)
    && l.rangeOf "Nat.succ" == none && moduleIn l "Nat.succ" == some "Mathlib.Data.Nat"
    && l.rangeOf "Nat.pred" == none && moduleIn l "Nat.pred" == none
    && rangedCount l == 2

#guard aDeclarationCarriesItsLineRangeWhenTheWriterHadOne

/-- A file of nothing but a marker is an empty map, and so is no file at all —
the marker is documentation and nothing branches on it, `#lidx1` included. -/
def emptyInputIsAnEmptyMap : Bool :=
  ["", "\n", "#lidx1\n", "#lidx2\n"].all fun text =>
    let l := parseLidx text
    l.names.isEmpty && l.modules.isEmpty

#guard emptyInputIsAnEmptyMap

/-- The scan walks bytes, so a name whose characters are several bytes each is
where a field boundary would be cut in the middle of one. -/
def nonAsciiNamesRoundTrip : Bool :=
  let l := parseLidx "M.𝒜\n\tFoo.𝓧'\n\tℕ.add\n"
  moduleIn l "Foo.𝓧'" == some "M.𝒜" && moduleIn l "ℕ.add" == some "M.𝒜"

#guard nonAsciiNamesRoundTrip

/-- `Map.prototype.set`: the later entry wins, and the group it wins for is the
one it was written under. -/
def repeatsFollowThePrototype : Bool :=
  let l := parseLidx "M\n\tA\nN\n\tA\nM\n\tB\n"
  moduleIn l "A" == some "N" && moduleIn l "B" == some "M"

#guard repeatsFollowThePrototype

/-- The module and the range go over together, the second case included: an
entry that lost its range does not keep the earlier one, which belonged to a
module the name no longer sits in. -/
def aRepeatedNameTakesTheLaterEntrysRange : Bool :=
  let l := parseLidx "M\n\tA\t1\t2\nN\n\tA\t30\t40\n"
  let overwritten := parseLidx "M\n\tA\t1\t2\nN\n\tA\n"
  moduleIn l "A" == some "N" && l.rangeOf "A" == some (30, 40)
    && moduleIn overwritten "A" == some "N" && overwritten.rangeOf "A" == none

#guard aRepeatedNameTakesTheLaterEntrysRange

/-- A blank line is not a group header, and neither is a missing `#lidx…`
marker: nothing here is a state a reader can be put into. -/
def blankLinesAndAMissingMarkerAreTolerated : Bool :=
  let l := parseLidx "M\n\n\tA\n\n@N\n"
  moduleIn l "A" == some "M" && l.modules.contains "N"

#guard blankLinesAndAMissingMarkerAreTolerated

/-- The group starts as the empty string rather than as "no group", so an entry
written before the first header is an entry of the module named `""` and still
resolves — it is a name with no page, which every branch downstream already
answers. -/
def anEntryBeforeTheFirstHeaderHasAnEmptyModule : Bool :=
  moduleIn (parseLidx "#lidx1\n\tA\nM\n\tB\n") "A" == some ""

#guard anEntryBeforeTheFirstHeaderHasAnEmptyModule

/-- A `#lidx1` file — one field per declaration line — still reads; every one of
its entries simply has no range. -/
def aFileFromBeforeTheRangeStillReads : Bool :=
  let l := parseLidx "#lidx1\n@Mathlib.Init\nMathlib.Order.Basic\n\
    \tMathlib.Order.le_refl\n\tMathlib.Order.le_trans\n"
  l.names.size == 2 && rangedCount l == 0
    && moduleIn l "Mathlib.Order.le_refl" == some "Mathlib.Order.Basic"
    && l.rangeOf "Mathlib.Order.le_refl" == none

#guard aFileFromBeforeTheRangeStillReads

/-- Every field shape that is not two numbers keeps its entry and loses its
range — and **loses it rather than inventing one**, which a digit scan that
floors at zero does not: `-3` reads as 3 and ` 67` as 67, and a link anchored at
lines the declaration is not on is worse than one with no anchor.

`A.extra` is the other direction: a field this reader does not know about is
ignored, so the day the writer adds one, the ranges already written do not all
disappear at once.

`A.huge` is the one shape the two halves still answer differently — Rust's `u32`
overflows and gives no range, Lean's `Nat` has no ceiling — and it is asserted
as what this half does rather than left unsaid. -/
def aMalformedRangeCostsTheRangeAndNotTheEntry : Bool :=
  let l := parseLidx "M\n\tA.half\t67\n\tA.words\tsixty\tseven\n\tA.empty\t\t\n\
    \tA.negative\t-3\t7\n\tA.zero\t0\t0\n\tA.spaced\t 67\t67 \n\
    \tA.extra\t67\t70\tsomething-new\n\tA.huge\t99999999999999999999\t7\n"
  l.names.size == 8
    && ["A.half", "A.words", "A.empty", "A.negative", "A.zero", "A.spaced"].all
        fun name => moduleIn l name == some "M" && l.rangeOf name == none
    && l.rangeOf "A.extra" == some (67, 70)
    && l.rangeOf "A.huge" == some (99999999999999999999, 7)

#guard aMalformedRangeCostsTheRangeAndNotTheEntry

end Litedoc4Test
