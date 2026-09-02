/- doc-gen4's `splitWhitespaces` replayed from the schema-3 widths, which is
why a `\n` immediately outside a tagged sub-expression comes out as a space.

The rewrite is **length-preserving in UTF-16 units**, and that is the whole
point: the spans keep addressing the result. Every guard here asserts the unit
count beside the bytes, because bytes that look right over a fragment whose
length moved are exactly what the offsets cannot survive.

`WsRewrite::changed_units` has no counterpart: nothing in either product reads
it, and the borrow it went with is a `Cow` this port has nothing to say about. -/
import Litedoc4.Render.Whitespace

namespace Litedoc4Test
open Litedoc4

/-- The wire form `[start, stop, 1, name, front, back]`. -/
def wsSpan (start stop front back : Nat) : Span :=
  { start, stop, kind := 1, name := "n", front, back }

/-- The wire form `[start, stop, 0]` — no widths at all. -/
def wsPlain (start stop : Nat) : Span := { start, stop, kind := 0 }

/-- Two ways of asking for no work: no widths at all, and widths over units that
are already spaces. Rust tells them from a rewrite by the `Cow` coming back
borrowed; here the only thing a caller can see is that the text did not move, so
the two are one guard. -/
def aRunThatIsAlreadySpacesLeavesTheTextAlone : Bool :=
  (mkFrag "f\n x" #[wsPlain 0 1, wsSpan 3 4 0 0]).text == "f\n x"
    && (mkFrag "a = b" #[wsSpan 2 3 1 1]).text == "a = b"

#guard aRunThatIsAlreadySpacesLeavesTheTextAlone

/-- `a =\n\tb`: the tag on `=` carries a 1-unit run in front and a 2-unit run
behind. -/
def newlineAndTabBecomeSpaces : Bool :=
  let f := mkFrag "a =\n\tb" #[wsSpan 2 3 1 2]
  f.text == "a =  b" && f.units == 6

#guard newlineAndTabBecomeSpaces

/-- `𝓧` is two UTF-16 units, so the tag on `:` starts at 3 and not at 2 — and
after the rewrite the same offsets still cut out the same character. -/
def offsetsAreUtf16CodeUnits : Bool :=
  let text := "𝓧\n:\tType"
  let f := mkFrag text #[wsSpan 3 4 1 1]
  (mkFragOf text).units == 9 && f.units == 9 && f.text == "𝓧 : Type"
    && byteSub f.text (f.bpos 3) (f.bpos 4) == ":"

#guard offsetsAreUtf16CodeUnits

/-- The tag on `c` claims only the run behind it; the one in front is already
the `b` tag's trailing run. Given in the other order, so a walk that trusted the
span order would write the later run's spaces before the earlier run's text. -/
def severalRunsAreSortedBeforeUse : Bool :=
  let f := mkFrag "a\tb\tc\td" #[wsSpan 4 5 0 1, wsSpan 2 3 1 1]
  f.text == "a b c d" && f.units == 7

#guard severalRunsAreSortedBeforeUse

/-- Two widths claiming the same units, and a width reaching past the end. Each
costs its own run the rewrite and nothing else — the unit count is the one
thing that may not move, and a second run over units the first already emitted
is what would move it. -/
def aWidthTheIrCannotMeanCostsItsOwnRunAndNoOffset : Bool :=
  let overlapping := mkFrag "a\tb\tc" #[wsSpan 2 3 1 1, wsSpan 2 3 1 1]
  let pastTheEnd := mkFrag "a\t" #[wsSpan 0 1 0 3]
  overlapping.text == "a b c" && overlapping.units == 5
    && pastTheEnd.text == "a\t" && pastTheEnd.units == 2

#guard aWidthTheIrCannotMeanCostsItsOwnRunAndNoOffset

end Litedoc4Test
