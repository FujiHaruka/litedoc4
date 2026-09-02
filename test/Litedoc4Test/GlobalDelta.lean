/- Which pages a moved name makes stale.

Rust's `Delta::compute` is two functions here — `deltaChanged` and `deltaScan`,
split so the pipeline can time the halves separately — so the guards compose them
the way `buildGlobal` does.

Nothing asserts on `deltaJson`: three of its fields are wall clock, and the two
halves do not spell a float the same way. `--print-set` is the file with no
floats in it and is what the incremental stage actually reads. -/
import Litedoc4.Global.Delta

namespace Litedoc4Test
open Litedoc4

def mapOf (pairs : List (String × String)) : Std.HashMap String String := Id.run do
  let mut m : Std.HashMap String String := Std.HashMap.emptyWithCapacity (pairs.length * 2 + 8)
  for (k, v) in pairs do m := m.insert k v
  return m

def factsWith (module : String) (tokens : List String) : ModuleFacts :=
  { module, contentHash := "0000000000000000", tokens := tokens.toArray }

def computeDelta (before after : List (String × String)) (facts : List ModuleFacts) : Delta :=
  let b := mapOf before
  let a := mapOf after
  deltaScan b.size a.size (deltaChanged b a) facts.toArray

/-- `gone` is in neither map's intersection and `new` is only in the second: a
diff taken over one key set would miss one of them, and the module that mentions
it would keep a link pointing at where the name used to live. -/
def changedIsTheUnionOfBothKeySets : Bool :=
  let d := computeDelta
    [("moved", "A"), ("gone", "A"), ("same", "A")]
    [("moved", "B"), ("new", "A"), ("same", "A")] []
  d.changed == #["gone", "moved", "new"] && d.beforeNames == 3 && d.afterNames == 3

#guard changedIsTheUnionOfBothKeySets

/-- An empty affected set is an empty file and not a file holding one blank
line: the renderer has to tell "no subset was asked for" from "a subset that came
out empty", and a lone newline is one module named by the empty string. -/
def nothingChangedMeansNothingIsScanned : Bool :=
  let d := computeDelta [("a", "A")] [("a", "A")] [factsWith "Pkg.One" ["a"]]
  d.changed.isEmpty && d.affected.isEmpty && deltaPrintSet d == ""

#guard nothingChangedMeansNothingIsScanned

/-- The two orders are different orders and the fixture makes them disagree:
`affected` is sorted, the witnesses stay in the order the modules were scanned
in, which is the index's. -/
def affectedIsSortedAndWitnessesAreInIndexOrder : Bool :=
  let d := computeDelta [("x", "A"), ("y", "A")] [("x", "B"), ("y", "B")]
    [factsWith "Pkg.Zed" ["unrelated", "y"],
     factsWith "Pkg.Alpha" ["x", "y"],
     factsWith "Pkg.None" ["nothing"]]
  d.affected == #["Pkg.Alpha", "Pkg.Zed"]
    && d.witnesses.map (fun w => (w.module, w.name)) == #[("Pkg.Zed", "y"), ("Pkg.Alpha", "x")]
    && deltaPrintSet d == "Pkg.Alpha\nPkg.Zed\n"

#guard affectedIsSortedAndWitnessesAreInIndexOrder

/-- The witness list is diagnostics and is capped; the affected set is the
contract and is not. A cap applied to both would silently re-render 20 modules
out of a package that needed 25. -/
def theWitnessesStopAtTheLimitAndTheAffectedSetDoesNot : Bool :=
  let modules := (Array.range (deltaWitnessLimit + 5)).map fun i =>
    factsWith s!"Pkg.M{i}" ["x"]
  let d := deltaScan 1 1 #["x"] modules
  d.affected.size == deltaWitnessLimit + 5 && d.witnesses.size == deltaWitnessLimit

#guard theWitnessesStopAtTheLimitAndTheAffectedSetDoesNot

/-- `𝒜` is above the BMP, where UTF-16 order inverts byte order — sorted by
bytes it would come after `ﬀ`. The corpus has no such module name, so this is the
only place the sort in `deltaScan` is told from a scan that kept its own order.
-/
def theAffectedSetSortsInUtf16OrderAndNotInScanOrder : Bool :=
  let d := deltaScan 1 1 #["x"]
    #[factsWith "Pkg.ﬀ" ["x"], factsWith "Pkg.𝒜" ["x"], factsWith "Pkg.A" ["x"]]
  d.affected == #["Pkg.A", "Pkg.𝒜", "Pkg.ﬀ"]
    && d.witnesses.map (·.module) == #["Pkg.ﬀ", "Pkg.𝒜", "Pkg.A"]
    && deltaPrintSet d == "Pkg.A\nPkg.𝒜\nPkg.ﬀ\n"

#guard theAffectedSetSortsInUtf16OrderAndNotInScanOrder

end Litedoc4Test
