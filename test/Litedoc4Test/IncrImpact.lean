/- The closure, and the one file in this tree whose empty form is a blank line.

The selection's UTF-16 order is `sortUtf16`'s and is stated where that lives; the
two things below are the ones no other module's guards reach. -/
import Litedoc4.Incr.Impact
import Litedoc4Test.IncrFixture

namespace Litedoc4Test
open Litedoc4 System

def edgesOf (pairs : List (String × List String)) : Std.HashMap String (Array String) :=
  pairs.foldl (fun m (from_, to) => m.insert from_ to.toArray) (Std.HashMap.emptyWithCapacity 8)

/-- The stack is seeded and the visited set is not, so a seed is in its own
closure exactly when something leads back to it. Lean cannot produce an import
cycle, so no IR the extractor writes reaches the second half — and the counts
every caller quotes are built on the seeds being *outside* the answer. -/
def theSeedIsInItsOwnClosureOnlyWhenSomethingLeadsBackToIt : Bool :=
  let acyclic := reachable #["A"] (edgesOf [("A", ["B"]), ("B", ["C"])])
  let cyclic := reachable #["A"] (edgesOf [("A", ["B"]), ("B", ["A"])])
  acyclic.size == 2 && !acyclic.contains "A"
    && cyclic.size == 2 && cyclic.contains "A"

#guard theSeedIsInItsOwnClosureOnlyWhenSomethingLeadsBackToIt

/-- The two writers of a name-per-line file disagree on the empty set, on
purpose, and the disagreement is the whole reason `impactPrintSet` exists:
`linesFile` backs `--only-from`, where an empty file has to mean "render
nothing", while `--print-set`'s bytes are compared against a fixture that has the
blank line in it. Written as one statement because the failure to avoid is the
two converging — either of them alone reads as correct. -/
def anEmptySelectionIsOneBlankLineAndAnEmptySetIsNoLineAtAll : Bool :=
  impactPrintSet #[] == "\n" && linesFile #[] == ""
    && impactPrintSet #["Pkg.A"] == "Pkg.A\n" && linesFile #["Pkg.A"] == "Pkg.A\n"
    && impactPrintSet #["Pkg.A", "Pkg.B"] == "Pkg.A\nPkg.B\n"
    && linesFile #["Pkg.A", "Pkg.B"] == "Pkg.A\nPkg.B\n"

#guard anEmptySelectionIsOneBlankLineAndAnEmptySetIsNoLineAtAll

def setOf (names : List String) : Std.HashSet String :=
  names.foldl (·.insert ·) (Std.HashSet.emptyWithCapacity 8)

def chosen (mode : ImpactMode) : Option (Array String) :=
  (modeSelection mode (setOf ["Pkg.A"]) (setOf ["Pkg.B"]) (setOf ["Pkg.B", "Pkg.C"])
    (setOf ["Pkg", "Pkg.A", "Pkg.B", "Pkg.C"])).toOption.map (sortUtf16 ·.toArray)

/-- `--mode` is not a preference: `self` is what an olean-hash ledger already
knows, `referrers` adds the pages that *name* the changed declaration, and
`importers` is the sound transitive bound.

**The changed module is in every selection.** `referrers` and `importers` are
sets of other modules, so without the union the edited module's own page is the
one page a re-extraction does not re-render — a site stale in exactly the page
the author is looking at. `all` is the one that does not consult the changed set,
which is why it is the answer when the renderer's input moved rather than any
module's. -/
def everyModeButAllSelectsTheChangedModuleTooAndAllIgnoresIt : Bool :=
  chosen .selfOnly == some #["Pkg.A"]
    && chosen .referrers == some #["Pkg.A", "Pkg.B"]
    && chosen .importers == some #["Pkg.A", "Pkg.B", "Pkg.C"]
    && chosen .all == some #["Pkg", "Pkg.A", "Pkg.B", "Pkg.C"]
    && chosen (.unrecognised "sideways") == none

#guard everyModeButAllSelectsTheChangedModuleTooAndAllIgnoresIt

def impactSaying (i : ImpactInputs) : IO (ImpactRun × Option String) := do
  match ← runImpact i with
  | .error (code, why) => return (default, some s!"impact refused with {code}: {why}")
  | .ok run => return (run, none)

/-- Two shapes only a hand-edited or an empty tree has, and both are about a
denominator rather than about the selection. An index that names one module twice
is one module — the set folds it — while the byte total is summed over the index
*entries*, because it is quoted as the cost of a read the selection has not made
yet and both entries would be read. A package with no modules at all is the only
input that tells `--print-set`'s blank line from an empty file. -/
def aRepeatedIndexEntryIsOneModuleAndTwoReads : Invariant where
  name := "a repeated index entry folds into one module and counts its bytes twice, \
    and an empty package's --print-set is one blank line"
  check := do
    let work ← incrWorkDir "impact-index"
    let ir := work / "ir"
    writeIrTree ir 5 #[{ name := "Pkg.A", decls := #[("Pkg.A.a", #[])] }] #["Pkg.A"]
    let (repeated, repeatedRefusal) ←
      impactSaying { ir, changed := #["Pkg.A"], mode := .selfOnly }
    let bytes := (← IO.FS.readFile (ir / "modules" / "Pkg.A.json")).utf8ByteSize

    let empty := work / "empty"
    writeIrTree empty 5 #[]
    let set := work / "set.txt"
    let (nothing, emptyRefusal) ←
      impactSaying { ir := empty, mode := .all, printSet := some set }
    let written ← IO.FS.readFile set
    removeDir work
    let one := repeated.summary.getD default
    return first [
      repeatedRefusal, emptyRefusal,
      eq one.ownModules 1,
      eq one.selected #["Pkg.A"],
      eq one.selectedIrBytes (bytes * 2),
      eq (nothing.summary.map (·.selected)) (some #[]),
      eq written "\n"]

end Litedoc4Test
