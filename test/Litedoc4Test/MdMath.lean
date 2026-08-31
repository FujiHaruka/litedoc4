/- `crates/litedoc4-md/src/math.rs`: what a `$…$` span becomes, and what it
becomes when the LaTeX cannot be read.

Stated through `mdMath` rather than through `MathML4Lean.toMathML`, which is
where the conversion lives: the fallback counter is litedoc4's, and it is the
only place a build can learn that a docstring's mathematics did not come out as
mathematics. Asking the converter directly would answer a question its own suite
already answers, and would not say what this half does with the answer.

The other four assertions of that file are `tools/e2e-micro.sh` GATE 10, which
counts the `<math>` elements on a real page and scans it for markup outside a
tag. -/
import Litedoc4.Md.Html

namespace Litedoc4Test
open Litedoc4

def mathOf (latex : String) (display : Bool) : String × Nat :=
  (mdMath "" latex display).run 0

def holds (s sub : String) : Bool := (s.splitOn sub).length > 1

/-- A sum has to become elements. The dollars are the tell: a converter that
gave up would have written the source back with them, and this is the same
question GATE 10 asks of a page except that no gate asserts `<munderover>`. -/
def aSumBecomesElementsAndNotText : Bool :=
  let (out, fallbacks) := mathOf "\\sum_{i=0}^{n} x_i" true
  holds out "<munderover>" && !out.any (· == '$') && fallbacks == 0

#guard aSumBecomesElementsAndNotText

/-- An empty span is not a failure, and the difference is visible: a converter
that refused it would put `$$` on the page and move `mathFallbacks`, so a
docstring ending in a stray pair of dollars would report the same thing as one
whose mathematics could not be read. -/
def anEmptyMathSpanIsNotAFallback : Bool :=
  (mathOf "" false).2 == 0 && (mathOf "   " false).2 == 0

#guard anEmptyMathSpanIsNotAFallback

end Litedoc4Test
