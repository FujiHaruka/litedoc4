import PrintKey
import Snap
open Lean Litedoc4

/-! The print keys of a version extracted natively: the same import as the extractor's, then the
key pass. -/

unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | [modules, out] =>
    let targets := (← IO.FS.lines modules).filter (!·.isEmpty) |>.map String.toName
    let t0 ← IO.monoMsNow
    initSearchPath (← findSysroot)
    enableInitializersExecution
    let env ← importModules (targets.map (Import.mk · false true false)) Options.empty
      (leakEnv := true) (loadExts := true)
    let t1 ← IO.monoMsNow
    IO.eprintln s!"import {targets.size} modules in {t1 - t0} ms"
    snap "imported"
    let (n, missing) ← PrintKey.writeKeys env (World.ofEnv env) targets out
    let t2 ← IO.monoMsNow
    IO.eprintln s!"keys {n} (missing {missing}) in {t2 - t1} ms"
    snap "keyed"
    return 0
  | _ => IO.eprintln "usage: nativekeys <modules.txt> <out.tsv>"; return 2
