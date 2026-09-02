/- V8's `\p{Z}\p{C}`, the table the frozen prototype tokenised code spans on
and half of what `isTokenSeparator` is.

The sortedness guard is `MdGc.lean`'s helper, reused rather than restated:
`inGcRanges` binary-searches whichever table it is handed, so a third table needs
the same premise and not a second spelling of it. -/
import Litedoc4.Global.V8Gc
import Litedoc4Test.MdGc

namespace Litedoc4Test
open Litedoc4

def theV8TableIsSortedAndDisjoint : Bool := sortedAndDisjoint v8ZcRanges

#guard theV8TableIsSortedAndDisjoint

/-- The spot checks `MdGc.lean` makes of UnicodeBasic's table, made of V8's. The
punctuation row is the one that matters: a tokeniser that split on `.` would
offer every component of every name and call the whole package affected. -/
def theV8CategoryIsTheOneNamed : Bool :=
  [' ', '\t', '\n', '\u0000', '\u00A0', '\u00AD', '\u2028'].all (fun c => isV8ZC c.val)
    && ['.', '_', '\'', '!', '?', '-', ':', 'a', 'α', '→', '𝒩'].all
        fun c => !isV8ZC c.val

#guard theV8CategoryIsTheOneNamed

end Litedoc4Test
