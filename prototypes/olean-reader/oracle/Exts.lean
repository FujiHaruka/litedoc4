import Lean
open Lean

def main (args : List String) : IO UInt32 := do
  initSearchPath (← findSysroot)
  unsafe Lean.enableInitializersExecution
  let root : Name := if args == ["mathlib"] then `Mathlib else `Lean
  let env ← importModules #[{ module := root }] Options.empty (leakEnv := true) (loadExts := true)
  let exts ← persistentEnvExtensionsRef.get
  for e in exts do IO.println e.name
  IO.eprintln s!"{exts.size} persistent extensions registered after import {root}; constants {env.constants.map₁.size}"
  return 0
