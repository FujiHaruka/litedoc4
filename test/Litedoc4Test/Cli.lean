/- Taking a value off the command line, and the front door.

`every_way_of_asking_for_the_usage_prints_the_same_bytes` has no check and needs
none. `src/Main.lean`'s dispatch answers `[]`, `--help` and `-h` in **one** arm
whose body is `IO.println Litedoc4.summary`, so the three spellings cannot print
different bytes; `--help-all` is a second arm over `usage`. What would falsify
it: three arms with three bodies. The same argument covers "the same usage" below
— every subcommand's help path prints the one `usage` constant — so what is left
to ask is that each parser *recognises* the flag.

`an_unknown_subcommand_is_refused_by_name`, `a_run_that_could_not_finish_costs
exit 1` and `every_subcommand_refuses_an_unknown_argument` are refusals
reachable from the command line and belong to `tools/refusal-gate.sh`, which
holds `unknown-subcommand` and a `*-unknown-flag` row per command.

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

/-- Spelled out rather than derived from the dispatch: a list built from the
`match` in `src/Main.lean` would agree with it by construction, and a subcommand
added there and not here is one nobody checked. -/
def subcommands : Array String :=
  #["build", "watch", "incremental", "modules", "links", "extract", "site", "render",
    "global", "ledger", "ownership", "merge", "impact", "prune"]

/-- A subcommand the front door does not name is one nobody finds. Being named at
all, beside the sentence that says where its command line is, is the whole
obligation — `summary` gives two of the fourteen a synopsis on purpose.

The last clause is the way back: without `--help-all` the twelve are hidden with
nothing pointing at them. -/
def theSummaryNamesEverySubcommandAndTheWayToTheirCommandLines : Bool :=
  subcommands.all (fun name => (summary.splitOn name).length ≥ 2)
    && (summary.splitOn "--help-all").length ≥ 2
    && (usage.splitOn "usage: litedoc4 build").length ≥ 2

#guard theSummaryNamesEverySubcommandAndTheWayToTheirCommandLines

/-- Both spellings through every parser, because they are two patterns in each of
the thirteen flag loops: one that lost `-h` passes a check that only asks
`--help`. Thirteen and not fourteen — `parseBuild` serves `build` and `watch`,
and the `Bool` is which.

`--help` is in no synopsis line, so `tools/flag-tie-gate.sh` never hands it to a
command: this is the only place the pair is asked. -/
def everyParserTakesBothSpellingsOfHelp : Bool :=
  ["--help", "-h"].all fun h =>
    (parseBuild false [h] {}).toOption.map (·.help) == some true
      && (parseBuild true [h] {}).toOption.map (·.help) == some true
      && (parseIncremental [h] {}).toOption.map (·.help) == some true
      && (parseModules [h] {}).toOption.map (·.help) == some true
      && (parseLinks [h] {}).toOption.map (·.help) == some true
      && (parseExtract [h] {}).toOption.map (·.help) == some true
      && (parseSite [h] {}).toOption.map (·.help) == some true
      && (parseRender [h] {}).toOption.map (·.help) == some true
      && (parseGlobal [h] {}).toOption.map (·.help) == some true
      && (parseLedger "check" [h] {}).toOption.map (·.help) == some true
      && (parseOwnership [h] {}).toOption.map (·.help) == some true
      && (parseMerge [h] {}).toOption.map (·.help) == some true
      && (parseImpact [h] {}).toOption.map (·.help) == some true
      && (parsePrune [h] {}).toOption.map (·.help) == some true

#guard everyParserTakesBothSpellingsOfHelp

end Litedoc4Test
