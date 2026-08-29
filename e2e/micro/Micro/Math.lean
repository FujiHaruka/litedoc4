import Micro.Basic

/-!
# Math

Mathematics written in a docstring, converted to MathML **while the site is
built**. Nothing is loaded in the browser to draw it — no MathJax, no KaTeX, no
math web font — because every current browser lays MathML out itself.

The four declarations below are the four answers, and the last one is the one to
look at: a formula the converter cannot read is written back as its own source,
so a page is never worse than one that never tried. The build says how many were
kept that way, because a page whose formulas silently stayed unconverted is
still a valid page.
-/

/-
`tools/e2e-micro.sh` GATE 10 reads this module's page and the run's marker: three
inline formulas, one displayed, one fallback, and no half-escaped markup inside a
MathML element. The counts are exact, so a formula added or removed here — in a
docstring or in the module doc above — has to be added or removed there.

Do not "fix" `\colim` to a command the converter implements. It is the input:
without a span that fails, nothing distinguishes a run that converted everything
from one that converted nothing.
-/

namespace Micro.Math

/-- An inline span: $x^2 + 1$ sits in the run of text around it. -/
def inlineSpan (n : Nat) : Nat := n * n + 1

/-- A displayed span, which is its own block:

$$\sum_{i = 0}^{n} i = \frac{n(n+1)}{2}$$

and the prose continues after it. -/
def displaySpan (n : Nat) : Nat := n * (n + 1) / 2

/-- Escaping still applies to whatever is *not* converted, and the conversion has
to survive characters HTML cares about: $a < b$ and $c \& d$ are both legal
LaTeX and both come out as mathematics rather than as markup. -/
def escapes (a : Nat) : Nat := a

/-- **The fallback.** `\colim` is not a command the converter implements, so this
span stays $\colim_k F(k)$ — dollars, source and escaping, exactly what the page
held before MathML. -/
theorem fallbackStays (n : Nat) : Micro.double n = n + n := rfl

end Micro.Math
