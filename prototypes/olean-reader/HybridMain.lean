import OleanReader
import Assemble
import Extract
import PrintKey
import Snap
open Lean OleanReader Litedoc4

/-! The extractor of `Extract.lean`, unchanged, run in the hybrid: where the native run calls
`importModules`, this builds the hybrid environment and the old version's `World` instead. -/

def readSearchPath (f : System.FilePath) : IO (Array System.FilePath) := do
  return (← IO.FS.lines f).filter (!·.isEmpty) |>.map System.FilePath.mk

structure HardStops where
  verso : IO.Ref (Array Name)
  builtinDoc : IO.Ref (Array Name)

/-- The old version's `World`: every answer from the decoded data. A docstring the old data
holds only as Verso, or does not hold at all while the running Lean's builtin table has one, is
not answered: the text says so, and the run counts it. -/
def hybridWorld (env : Environment) (o : Assemble.OldWorld) (hs : HardStops) : World :=
  { moduleNames := o.moduleNames
    moduleIndex? := fun m => o.index[m]?
    constNames := fun i => o.constNames[i]!
    imports := fun i => o.imports[i]!
    moduleOf? := fun n => o.modOf[n]?
    contains := fun n => o.consts.contains n
    moduleDocs := fun m => o.modDocs.getD m #[]
    docString? := fun n => do
      let start := (Parser.Tactic.Doc.alternativeOfTactic env n).getD n
      let mut t := start
      let mut steps := 0
      while steps < 64 do
        match o.inherit[t]? with
        | some u => t := u; steps := steps + 1
        | none => break
      if o.docKeys.contains t then
        findDocString? env n
      else if o.versoKeys.contains t then
        hs.verso.modify (·.push n)
        return some s!"<hard stop: the docstring of {t} is Verso and was not decoded>"
      else
        match ← findDocString? env n with
        | none => return none
        | some _ =>
          hs.builtinDoc.modify (·.push n)
          return some s!"<hard stop: the docstring of {t} came from v{Lean.versionString}'s builtin table>"
    tactics := pure none }

unsafe def hybridMain (args : List String) : IO UInt32 := do
  match args with
  | spFile :: modules :: events :: rest =>
    let some cfg := (parseArgs (modules :: events :: rest)).toOption
      | IO.eprintln "hybrid: bad extractor arguments"; return 2
    let sp ← readSearchPath spFile
    let targets := (← IO.FS.lines modules).filter (!·.isEmpty) |>.map String.toName
    let keepProofs := (← IO.getEnv "HYBRID_KEEP_PROOFS") == some "1"
    let leak := (← IO.getEnv "HYBRID_LEAK") != some "0"
    let stopAfter := (← IO.getEnv "HYBRID_STOP_AFTER").getD ""
    let rounds := ((← IO.getEnv "HYBRID_ROUNDS").bind String.toNat?).getD 1
    snap "start"
    let t0 ← IO.monoMsNow
    let mods ← closure sp targets
    let t1 ← IO.monoMsNow
    IO.eprintln s!"closure {mods.size} modules from {targets.size} roots in {t1 - t0} ms"
    if stopAfter == "assemble" && rounds > 1 then
      for r in [0:rounds] do
        let ta ← IO.monoMsNow
        let d ← Assemble.decodeAll sp mods (omitProofs := !keepProofs)
        let tb ← IO.monoMsNow
        snap s!"round{r}-decoded"
        let (env, _) ← Assemble.assembleHybrid d leak
        let tc ← IO.monoMsNow
        IO.eprintln s!"round {r}: decoded in {tb - ta} ms, assembled in {tc - tb} ms, constants {env.constants.map₁.size}"
        snap s!"round{r}-assembled"
      snap "rounds-done"
      return 0
    let d ← Assemble.decodeAll sp mods (omitProofs := !keepProofs)
    let t2 ← IO.monoMsNow
    snap "decoded"
    if stopAfter == "decode" then
      IO.eprintln s!"decoded {d.mods.size} modules in {t2 - t1} ms (proofs {if keepProofs then "kept" else "omitted"}); stopping"
      return 0
    IO.eprintln s!"decoded {d.mods.size} modules in {t2 - t1} ms; constants {d.stats.constants}, entries decoded {d.stats.entriesDecoded}, entries not decoded {d.stats.entriesSkipped} in {d.stats.skippedExts.size} extensions"
    for (e, k) in d.stats.decodedExts.toArray.qsort (fun a b => a.1.toString < b.1.toString) do
      IO.eprintln s!"  decoded ext {e} {k}"
    for (e, k) in d.stats.skippedExts.toArray.qsort (fun a b => a.2 > b.2) do
      IO.eprintln s!"  not decoded ext {e} {k}"
    IO.eprintln s!"old world: modules {d.old.moduleNames.size}, constants {d.old.consts.size}, const2ModIdx {d.old.modOf.size}, modules with module docs {d.old.modDocs.size}, docstring keys {d.old.docKeys.size}, Verso docstring keys {d.old.versoKeys.size}, inherit_doc {d.old.inherit.size}, stored axiom lists {d.old.axiomKeys.size}"
    let (env, msg) ← Assemble.assembleHybrid d leak
    let t3 ← IO.monoMsNow
    IO.eprintln s!"{msg}\nassembled in {t3 - t2} ms"
    snap "assembled"
    if stopAfter == "assemble" then return 0
    let builtinRanges := (← builtinDeclRanges.get).size
    builtinDeclRanges.set {}
    IO.eprintln s!"builtinDeclRanges of v{Lean.versionString} cleared: {builtinRanges} entries"
    let mut noAxioms := 0
    let mut targetConsts := 0
    let mut walked : Array String := #[]
    for m in targets do
      for n in d.old.constNames[d.old.index[m]!]! do
        targetConsts := targetConsts + 1
        unless d.old.axiomKeys.contains n do
          noAxioms := noAxioms + 1
          walked := walked.push n.toString
    if let some p := (← IO.getEnv "HYBRID_NO_AXIOM_LIST") then
      IO.FS.writeFile p ("\n".intercalate walked.toList ++ "\n")
    IO.eprintln s!"target-module constants without a stored axiom list (collectAxioms walks the value there): {noAxioms} of {targetConsts}"
    let hs : HardStops := { verso := ← IO.mkRef #[], builtinDoc := ← IO.mkRef #[] }
    let world := hybridWorld env d.old hs
    let code ← if stopAfter == "keys-only" then pure 0 else Litedoc4.run cfg (some (env, world))
    let t4 ← IO.monoMsNow
    snap "extracted"
    let v ← hs.verso.get
    let b ← hs.builtinDoc.get
    IO.eprintln s!"extraction {t4 - t3} ms; total {t4 - t0} ms"
    IO.eprintln s!"HARD STOPS: Verso docstrings not decoded {v.size}, docstrings only in the builtin table {b.size}, tactic table 1 (no module carries tactics)"
    for n in v.toList.take 20 do IO.eprintln s!"  verso: {n}"
    for n in b.toList.take 20 do IO.eprintln s!"  builtin: {n}"
    if let some p ← IO.getEnv "HYBRID_KEYS" then
      let t5 ← IO.monoMsNow
      let (n, missing) ← PrintKey.writeKeys env world targets p
      let t6 ← IO.monoMsNow
      IO.eprintln s!"keys {n} (missing {missing}) in {t6 - t5} ms"
      snap "keyed"
    return code
  | _ =>
    IO.eprintln "usage: hybrid <searchpath-file> <modules.txt> <events.jsonl> [extractor options]"
    return 2

unsafe def main (args : List String) : IO UInt32 := hybridMain args
