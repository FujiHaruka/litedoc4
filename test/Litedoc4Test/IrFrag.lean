/- A fragment's text with the UTF-16 index the IR's spans are stated in. The
ordering half of that file is in `Utf16.lean`. -/
import Litedoc4.Ir.Utf16
import Litedoc4.Render.Whitespace

namespace Litedoc4Test
open Litedoc4

/-- What the emitter does with a pair of unit offsets, and the only way a
fragment is ever read. -/
def sliceUnits (f : Frag) (a b : Nat) : String := byteSub f.text (f.bpos a) (f.bpos b)

def anAsciiFragmentNeedsNoOffsetTable : Bool :=
  let f := mkFragOf "f x = y"
  f.ascii && f.u2b.isEmpty && f.units == 7 && sliceUnits f 2 5 == "x ="

#guard anAsciiFragmentNeedsNoOffsetTable

/-- α and β are two bytes for one unit and → is three, so byte 9 is unit 5. -/
def aBmpFragmentsUnitOffsetsAreNotItsByteOffsets : Bool :=
  let f := mkFragOf "α → β"
  !f.ascii && f.units == 5 && f.text.utf8ByteSize == 9 && f.bpos 5 == 9
    && sliceUnits f 0 1 == "α" && sliceUnits f 2 3 == "→" && sliceUnits f 4 5 == "β"

#guard aBmpFragmentsUnitOffsetsAreNotItsByteOffsets

/-- U+1D4E7 is four bytes and two units, and **both units carry the byte offset
of the whole scalar** — the second is not marked unusable the way the Rust
reader marks it, so slicing from it yields the character rather than nothing.
The extractor never writes an offset there (every span it emits lands on a
scalar boundary), so the two readers differ only outside what either is fed. -/
def anAstralScalarSpansTwoUnitsAndBothPointIntoIt : Bool :=
  let f := mkFragOf "{𝓧 : Type}"
  f.units == 11 && sliceUnits f 1 3 == "𝓧"
    && f.bpos 1 == 1 && f.bpos 2 == 1 && f.bpos 3 == 5

#guard anAstralScalarSpansTwoUnitsAndBothPointIntoIt

def theEmptyFragmentHasNoUnitsAndStillSlices : Bool :=
  let f := mkFragOf ""
  f.ascii && f.units == 0 && sliceUnits f 0 0 == ""

#guard theEmptyFragmentHasNoUnitsAndStillSlices

/-- The whitespace rewrite replaces the units inside a span's `front`/`back`
runs with plain spaces. Length-preserving in **units** and not in bytes: U+2009
is one unit and three bytes, so the result is the same 3 units and 2 bytes
shorter — and it is ASCII where the input was not. That difference is the whole
reason `Frag.units` exists as one spelling: a caller measuring the string it
handed in gets an end offset past the end of what it is slicing. -/
def theWhitespaceRewriteIsLengthPreservingInUnitsAndNotInBytes : Bool :=
  let text := "a\u2009b"
  let f := mkFrag text #[{ start := 2, stop := 3, kind := 1, name := "b", front := 1 }]
  text.utf8ByteSize == 5 && f.text == "a b" && f.units == 3 && f.ascii

#guard theWhitespaceRewriteIsLengthPreservingInUnitsAndNotInBytes

/-- A width whose run ends past the fragment is dropped, and the rest of the
rewrite still happens. A width is a `Nat` and has no end to run off; a fragment
does, so the fragment is where the run has to be refused. -/
def aWhitespaceRunPastTheEndOfTheFragmentIsSkipped : Bool :=
  let text := "a\tb"
  let f := mkFrag text #[{ start := 2, stop := 3, kind := 1, name := "b", front := 1 },
                          { start := 2, stop := 3, kind := 1, name := "b", back := 9 }]
  f.text == "a b" && f.units == 3

#guard aWhitespaceRunPastTheEndOfTheFragmentIsSkipped

end Litedoc4Test
