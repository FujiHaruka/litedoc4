/- `crates/litedoc4/src/cli.rs`: taking a value off the command line.

There is no `Args` type here to test. The Rust half shares one cursor between
fourteen `match`es; the Lean half is fourteen `List String` recursions, and
"the value is the argument after the flag and it is consumed" is the list
pattern `flag :: v :: more` — so what is left to ask is that a real parser
answers with the value it was handed and reads the *next* flag from `more`.

`every_documented_flag_is_parsed` is not carried and must not be: it is
`tools/flag-tie-gate.sh`, which was built to be its replacement and is stronger
than either — it asks the **binary**, per `(command, flag)` pair rather than over
one union, and it carries a control flag that exists nowhere so that a green run
proves the detector fires (153/153 pairs, 16 controls, measured 2026-08-31). A
`#guard` over the same claim would be a second, weaker place for it to be
answered. -/
import Litedoc4.Main

namespace Litedoc4Test
open Litedoc4

/-- The value is the next argument and it is **consumed**: the second clause
hands `--pages` to `--ir` and finds that nothing else was filled in, which is
the half a parser that peeked instead of taking would fail. -/
def aFlagsValueIsTheArgumentAfterItAndIsNotReadAgainAsAFlag : Bool :=
  (parseRender ["--ir", "site", "--pages", "p"] {}).toOption.map
      (fun a => (a.ir, a.pages)) == some (some "site", some "p")
    && (parseRender ["--ir", "--pages"] {}).toOption.map
      (fun a => (a.ir, a.pages)) == some (some "--pages", none)

#guard aFlagsValueIsTheArgumentAfterItAndIsNotReadAgainAsAFlag

/-- A number flag is the value it took, parsed — not the default it would have
had if the parse were dropped. `--jobs 1` is `build`'s default, so it is the one
number this cannot be stated with. -/
def aNumberFlagIsTheValueItTook : Bool :=
  (parseBuild false ["--jobs", "4"] {}).toOption.map (·.jobs) == some 4
    && (parseExtract ["--jobs", "7"] {}).toOption.map (·.jobs) == some 7
    && ({} : BuildArgs).jobs == 1

#guard aNumberFlagIsTheValueItTook

end Litedoc4Test
