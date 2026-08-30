/-
No `import Lean` anywhere below this module, and that is a distribution
constraint rather than a style one: an executable that imports `Lean` measures
226 MB and `Lean.Data.Json` alone 118 MB, against 5.3 MB for `Std`
(measured 2026-08-30 → `benchmarks/results/purelean-ci-probe-2026-08-30.txt`).
The extractor reads oleans and cannot avoid it, so it stays a separate
`lean_exe`. What would falsify this: a distribution model that ships a built
binary instead of a `require`, which is not the one this package has.
-/
import Litedoc4

namespace Litedoc4

def usage : String :=
"usage: litedoc4 [--version] [--help]"

end Litedoc4

def main (args : List String) : IO UInt32 := do
  match args with
  | "--version" :: _ =>
    IO.println s!"litedoc4 {Litedoc4.version}"
    return 0
  | [] | "--help" :: _ | "-h" :: _ =>
    IO.println Litedoc4.usage
    return 0
  | arg :: _ =>
    IO.eprintln s!"litedoc4: unknown argument `{arg}`"
    IO.eprintln Litedoc4.usage
    return 2
