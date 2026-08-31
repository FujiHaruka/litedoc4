/-
No `import Lean` anywhere below this module, and that is a distribution
constraint rather than a style one: an executable that imports `Lean` measures
226 MB and `Lean.Data.Json` alone 118 MB, against 5.3 MB for `Std`
(measured 2026-08-30 → `benchmarks/results/purelean-ci-probe-2026-08-30.txt`).
The extractor reads oleans and cannot avoid it, so it stays a separate
`lean_exe`. What would falsify this: a distribution model that ships a built
binary instead of a `require`, which is not the one this package has.

The subcommand dispatch is here and everything it dispatches to is in
`Litedoc4.Main`, which is one module more than the executable needs. The reason
is the test executable: `Litedoc4Test.Main` declares a `main` of its own, and a
module that declares `main` cannot import another that does — so a `#guard` over
`usage` or over any of the fourteen parsers would be unelaboratable if they
lived beside this. What would falsify it: an entry point Lean does not require
to be called `main`.
-/
import Litedoc4.Main

def main (args : List String) : IO UInt32 := do
  match args with
  | "--version" :: _ =>
    IO.println s!"litedoc4 {Litedoc4.version}"
    return 0
  | "build" :: rest => Litedoc4.build rest
  | "watch" :: rest => Litedoc4.watch rest
  | "modules" :: rest => Litedoc4.modules rest
  | "render" :: rest => Litedoc4.render rest
  | "ledger" :: rest => Litedoc4.ledger rest
  | "site" :: rest => Litedoc4.site rest
  | "global" :: rest => Litedoc4.globalCmd rest
  | "ownership" :: rest => Litedoc4.ownershipCmd rest
  | "merge" :: rest => Litedoc4.mergeCmd rest
  | "impact" :: rest => Litedoc4.impactCmd rest
  | "prune" :: rest => Litedoc4.pruneCmd rest
  | "links" :: rest => Litedoc4.linksCmd rest
  | "incremental" :: rest => Litedoc4.incremental rest
  | "extract" :: rest => Litedoc4.extract rest
  | [] | "--help" :: _ | "-h" :: _ =>
    IO.println Litedoc4.summary
    return 0
  | "--help-all" :: _ =>
    IO.println Litedoc4.usage
    return 0
  | arg :: _ => Litedoc4.refuse s!"unknown subcommand `{arg}`"
