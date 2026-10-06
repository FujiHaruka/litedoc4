import Lean
open Lean

def main (args : List String) : IO UInt32 := do
  initSearchPath (← findSysroot)
  unsafe Lean.enableInitializersExecution
  let env ← importModules #[{ module := `Mathlib }] Options.empty (leakEnv := true) (loadExts := true)
  for line in ← IO.FS.lines args[0]! do
    if line.isEmpty then continue
    let n := line.toName
    match getStructureInfo? env n with
    | none => IO.println s!"{n}\tnot a structure"
    | some si => IO.println s!"{n}\tfields {si.fieldNames.toList}\tparents {(si.parentInfo.map (·.structName)).toList}"
  return 0
