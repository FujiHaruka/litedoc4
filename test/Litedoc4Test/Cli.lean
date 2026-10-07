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
fourteen `match`es; the Lean half is six `List String` recursions, and
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
hands `--ir-dir` to `--modules` and finds that nothing else was filled in, which
is the half a parser that peeked instead of taking would fail. -/
def aFlagsValueIsTheArgumentAfterItAndIsNotReadAgainAsAFlag : Bool :=
  (parseExtract ["--modules", "m", "--ir-dir", "p"] {}).toOption.map
      (fun a => (a.modules, a.irDir)) == some (some "m", some "p")
    && (parseExtract ["--modules", "--ir-dir"] {}).toOption.map
      (fun a => (a.modules, a.irDir)) == some (some "--ir-dir", none)

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
  #["build", "watch", "modules", "links", "extract", "ledger", "store"]

/-- A subcommand the front door does not name is one nobody finds. Being named at
all, beside the sentence that says where its command line is, is the whole
obligation — `summary` gives two of the seven a synopsis on purpose.

The last clause is the way back: without `--help-all` the five are hidden with
nothing pointing at them. -/
def theSummaryNamesEverySubcommandAndTheWayToTheirCommandLines : Bool :=
  subcommands.all (fun name => (summary.splitOn name).length ≥ 2)
    && (summary.splitOn "--help-all").length ≥ 2
    && (usage.splitOn "usage: litedoc4 build").length ≥ 2

#guard theSummaryNamesEverySubcommandAndTheWayToTheirCommandLines

/-- Both spellings through every parser, because they are two patterns in each of
the six flag loops: one that lost `-h` passes a check that only asks `--help`.
Six and not seven — `parseBuild` serves `build` and `watch`, and the `Bool` is
which.

`--help` is in no synopsis line, so `tools/flag-tie-gate.sh` never hands it to a
command: this is the only place the pair is asked. -/
def everyParserTakesBothSpellingsOfHelp : Bool :=
  ["--help", "-h"].all fun h =>
    (parseBuild false [h] {}).toOption.map (·.help) == some true
      && (parseBuild true [h] {}).toOption.map (·.help) == some true
      && (parseModules [h] {}).toOption.map (·.help) == some true
      && (parseLinks [h] {}).toOption.map (·.help) == some true
      && (parseExtract [h] {}).toOption.map (·.help) == some true
      && (parseLedger "check" [h] {}).toOption.map (·.help) == some true
      && (parseStore "put" [h] {}).toOption.map (·.help) == some true

#guard everyParserTakesBothSpellingsOfHelp

def versionedRefusal (args : List String) : Option String :=
  match parseBuild false args {} with
  | .ok a => versionedChecks a
  | .error _ => none

def namesFlag (message : Option String) (flag : String) : Bool :=
  match message with
  | some m => m.startsWith s!"{flag} is not a flag of `build --versions`"
  | none => false

/-- `--store` and `--hash-urls` are the one-version build's too, since it is the
same output, and `watch` is that build asked over and over; only `--versions`
is a site of several checkouts, which `watch` refuses by name. -/
def theStoreFlagsAreEveryBuildsAndWatchRefusesOnlyVersions : Bool :=
  ((parseBuild false ["--versions", "v1,v2", "--store", "s", "--hash-urls"] {}).toOption.map
      fun a => (a.versions, a.store, a.hashUrls)) == some (some "v1,v2", some "s", true)
    && ((parseBuild true ["--store", "s", "--hash-urls"] {}).toOption.map
      fun a => (a.store, a.hashUrls)) == some (some "s", true)
    && (match parseBuild true ["--versions", "v1"] {} with
      | .error m => m.startsWith "--versions is not a `watch` flag"
      | .ok _ => false)

#guard theStoreFlagsAreEveryBuildsAndWatchRefusesOnlyVersions

def everyFlagAVersionedBuildDecidesPerVersionIsRefusedByNameAndTheRestAreTaken : Bool :=
  let v := ["--versions", "v1"]
  [(["--source-url", "u"], "--source-url"), (["--extractor-bin", "b"], "--extractor-bin"),
   (["--full"], "--full"), (["--timings", "t"], "--timings")].all
      (fun (args, flag) => namesFlag (versionedRefusal (v ++ args)) flag)
    && versionedRefusal (v ++ ["--store", "s", "--hash-urls", "--lib", "L", "--lake", "k",
        "--jobs", "2"]) == none
    && versionedRefusal ["--store", "s", "--hash-urls", "--source-url", "u", "--full",
        "--extractor-bin", "b", "--timings", "t"] == none

#guard everyFlagAVersionedBuildDecidesPerVersionIsRefusedByNameAndTheRestAreTaken

/-- The flags of the static single-version site are gone from both commands, and
a caller who still passes one is told it is an unknown argument: each named a
decision (the dependency map's file, a one-shot extraction program, the render
set's mode and bound, a dependency's documentation site) that the site rendered
from the store does not take. -/
def theStaticSitesFlagsAreUnknownToBuildAndWatch : Bool :=
  ["--link-index", "--extractor", "--extractor-arg", "--mode", "--max-rounds",
   "--deps-docs-url", "--deps-docs-index", "--deps-docs-map"].all fun flag =>
    [false, true].all fun watching =>
      match parseBuild watching [flag, "x"] {} with
      | .error m => m == s!"unknown argument `{flag}`"
      | .ok _ => false

#guard theStaticSitesFlagsAreUnknownToBuildAndWatch

end Litedoc4Test
