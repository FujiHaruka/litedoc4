/- The three wire forms of a tag span.

Two of that file's assertions are not here because the field types already say
them: `kind` is a `Nat`, so a code the extractor starts writing arrives as
itself and there is no enumeration to fall out of, and `back` is a `Nat`, so a
trailing width cannot overflow the offset type the way it can in `u32`. What a
run past the end of the *fragment* does is in `IrFrag.lean`, where there is a
fragment to run past. -/
import Litedoc4.Ir

namespace Litedoc4Test
open Litedoc4

/-- The span read the way a module file's `typeCode` is read. `none` when the
array did not parse at all, so a guard below cannot hold on a span that was
never built. -/
def spanOf (json : String) : Option Span :=
  match parseJson json with
  | .ok v => some (toSpan v)
  | .error _ => none

def isSpan (start stop kind : Nat) (name : String) (front back : Nat) : Option Span → Bool
  | none => false
  | some s =>
    s.start == start && s.stop == stop && s.kind == kind && s.name == name
      && s.front == front && s.back == back

def theThreeElementFormIsAnUnnamedSpanWithNoWidths : Bool :=
  isSpan 0 7 0 "" 0 0 (spanOf "[0,7,0]")

#guard theThreeElementFormIsAnUnnamedSpanWithNoWidths

def theFourElementFormNamesAConstant : Bool :=
  isSpan 2 5 1 "Nat.succ" 0 0 (spanOf "[2,5,1,\"Nat.succ\"]")

#guard theFourElementFormNamesAConstant

def theSixElementFormCarriesTheWhitespaceWidths : Bool :=
  isSpan 4 6 1 "HAdd.hAdd" 1 3 (spanOf "[4,6,1,\"HAdd.hAdd\",1,3]")

#guard theSixElementFormCarriesTheWhitespaceWidths

end Litedoc4Test
