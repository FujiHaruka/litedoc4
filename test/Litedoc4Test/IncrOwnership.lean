/- Which modules point at a name that has moved.

**The stage the ledger cannot see.** Moving a declaration from `Pkg.A` to
somewhere else leaves the referring module's olean byte identical (measured), so
`detect` reports nothing and widening the *render* set cannot help either — the
stale bytes are in the referrer's IR and the referrer has to be re-**extracted**.
That is the whole reason the round loop has a second half.

It is a run-time invariant rather than a guard because both answers are read off
two IR trees on disk, and the stage's own arithmetic is over maps built from
them. `ownership_refuses_a_base_with_neither_an_inc_tree_nor_a_removal_list` is
not here: it is a refusal reachable from the command line, and
`tools/refusal-gate.sh` holds it as `ownership-base-alone`. -/
import Litedoc4.Incr.Ownership
import Litedoc4Test.IncrFixture

namespace Litedoc4Test
open Litedoc4 System

/-- `Pkg.B` refers to `Pkg.A.moved`, which `Pkg.A` defines, and to
`Dep.elsewhere`, which no module of this package defines. The second reference is
what stops a stage that reported *every* unresolved reference from passing:
`Dep.elsewhere` never has an owner here and must never make `Pkg.B` stale. -/
def ownershipPackage : Array SynthIrModule :=
  #[{ name := "Pkg", decls := #[("Pkg.core", #[])] },
    { name := "Pkg.A", decls := #[("Pkg.A.moved", #[]), ("Pkg.A.stay", #[])] },
    { name := "Pkg.B",
      decls := #[("Pkg.B.b", #[("Pkg.A", "Pkg.A.moved"), ("Dep.Home", "Dep.elsewhere")])] },
    { name := "Pkg.C", decls := #[("Pkg.C.c", #[])] }]

/-- The re-extracted `Pkg.A`, without `Pkg.A.moved`. -/
def ownershipReextractedA : Array SynthIrModule :=
  #[{ name := "Pkg.A", decls := #[("Pkg.A.stay", #[])] }]

def witnessLine (w : Witness) : String := s!"{w.rule} {w.module} {w.refModule} {w.refName}"

/-- Both ways a name loses its owner, over one package.

The **re-extraction** is the ordinary round: a partial tree that no longer
declares `Pkg.A.moved`, so `Pkg.B`'s reference points at nothing and `Pkg.B` is
the next round's input. `Pkg.A` itself is not — it was just extracted.

The **deletion** is the case that has no partial tree at all, and a stage that
required `--inc` could not ask it: a pure deletion re-extracts nothing. Both of
the deleted module's declarations are lost, and the deleted module must not
report *itself* as needing re-extraction — a round that put it back in the input
would extract a module whose source is gone, every round, for ever.

The witness is checked and not just the count: `1 module(s) need re-extraction`
is the same line whichever reference gave the module away, and the caller reading
`--print-set` cannot tell a right answer from a lucky one. -/
def ownershipNamesTheReferrerAndNeverTheModuleThatWentAway : Invariant where
  name := "ownership makes the referrer of a moved name stale by name, leaves an unresolvable \
    dependency reference alone, and never puts a deleted module in its own --print-set"
  check := do
    let work ← incrWorkDir "ownership"
    let base := work / "base"
    let inc := work / "inc"
    writeIrTree base 5 ownershipPackage
    writeIrTree inc 5 ownershipReextractedA

    let reSet := work / "stale-reextract.txt"
    let reJson := work / "ownership.json"
    let reExtracted ← runOwnership
      { base, inc := some inc, printSet := some reSet, json := some reJson }
    let reLines ← IO.FS.readFile reSet
    let reRecord ← IO.FS.readFile reJson

    let removed := work / "removed.txt"
    IO.FS.writeFile removed "Pkg.A\n"
    let delSet := work / "stale-delete.txt"
    let deleted ← runOwnership
      { base, removed := some removed, printSet := some delSet }
    let delLines ← IO.FS.readFile delSet

    -- The same deletion with `Pkg.B` already scheduled: an excluded module is
    -- fresh by definition, so the answer is empty rather than the same list
    -- again — without it the loop hands round 2 what round 1 has just done.
    let excludeFile := work / "exclude.txt"
    IO.FS.writeFile excludeFile "Pkg.B\n"
    let excluded ← runOwnership
      { base, removed := some removed, exclude := some excludeFile }
    removeDir work

    return first [
      eq (reExtracted.incModules, reExtracted.removedModules) (1, 0),
      eq (reExtracted.lostNames, reExtracted.gainedNames) (1, 0),
      eq reExtracted.staleModules #["Pkg.B"],
      eq (reExtracted.witnesses.map witnessLine) #["lostOwner Pkg.B Pkg.A Pkg.A.moved"],
      eq reLines "Pkg.B\n",
      eq ((reRecord.splitOn "\"staleModules\"").length) 2,
      eq (deleted.removedModules, deleted.incModules) (1, 0),
      eq (deleted.lostNames, deleted.gainedNames) (2, 0),
      eq deleted.staleModules #["Pkg.B"],
      eq delLines "Pkg.B\n",
      eq excluded.staleModules #[]]

end Litedoc4Test
