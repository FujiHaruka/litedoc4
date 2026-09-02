/- The refusal's name list, the schema a merged tree may claim, and the order
`--modules` imposes.

Nothing here states that a nested JSON object keeps its key order. Rust needs a
test for it because `preserve_order` is a cargo feature a build can lose; here
`JVal.obj` is an `Array (String × JVal)` and `MergeIndexEntry.raw` is the parsed
value itself, so the order is the type's and there is nothing left to check. -/
import Litedoc4.Incr.Merge
import Litedoc4Test.IncrFixture

namespace Litedoc4Test
open Litedoc4 System

def ghostNames (count : Nat) : Array String :=
  (Array.range count).map fun n => s!"Micro.M{n}"

/-- The empty list has an answer of its own. A refusal ending in `()` reads as a
name the message failed to print, and sends the caller looking for a list that is
not there. -/
def noNamesIsTheWordNoneAndNotAnEmptyLine : Bool :=
  someOf #[] == "none"

#guard noNamesIsTheWordNoneAndNotAnEmptyLine

/-- The three cases around the limit as one statement, because a cut that is
wrong by one reads as correct in two of them: at the limit nothing is elided, one
past it exactly one name is, and the eleventh is *counted* rather than shown. The
comparison is against the names themselves rather than against a length, so a cut
that kept the *last* ten and a cut at `namesInRefusal - 1` both fail. -/
def theElisionStartsOnePastTheLimitAndCountsTheRest : Bool :=
  let shown := (ghostNames namesInRefusal).toList
  (someOf (ghostNames namesInRefusal)).splitOn ", " == shown
    && (someOf (ghostNames (namesInRefusal + 1))).splitOn ", " == shown ++ ["… and 1 more"]
    && (someOf (ghostNames (namesInRefusal + 7))).splitOn ", " == shown ++ ["… and 7 more"]

#guard theElisionStartsOnePastTheLimitAndCountsTheRest

/-- The merged index has to be readable by every reader that can read the files
under it, and `merge` copies the incremental module files in verbatim — so a tree
can hold two extractor runs' output at once and the base's number is not the
weakest. The two clauses that are not "take the lower" are the ones that decide
what a claim nobody made becomes: a base without the key is a schema-1 file, and
answering with the incremental tree's number would invent one. -/
def theMergedIndexClaimsTheWeakestSchemaUnderTheTree : Bool :=
  let n (k : Int) : Option JVal := some (.num k)
  jvalKey (weakestSchema (n 6) (n 5)) == "=5"
    && jvalKey (weakestSchema (n 5) (n 6)) == "=5"
    && jvalKey (weakestSchema (n 5) (n 5)) == "=5"
    && jvalKey (weakestSchema none (n 5)) == ""
    && jvalKey (weakestSchema (n 5) none) == "=5"
    && jvalKey (weakestSchema (n 5) (some (.str "6"))) == "=5"

#guard theMergedIndexClaimsTheWeakestSchemaUnderTheTree

def entryFor (module : String) : MergeIndexEntry :=
  { module, file := s!"modules/{module}.json", raw := .null }

/-- A list that names one module twice is one list, not two modules, and the
first position is the one that stands — the same rule `orderedInsert` gives a
repeated key, because both end up as `index.json`'s `modules` order.

The list here is in neither sorted order nor the order the append rule produces,
so "it happened to already be right" cannot pass this. -/
def aModuleListNamingOneModuleTwiceIsOneList : Bool :=
  (listedOrder #["Pkg.B", "Pkg.A", "Pkg.B"] #["Pkg.A", "Pkg.B"] #[]).toOption
      == some #["Pkg.B", "Pkg.A"]
    && (listedOrder #["Pkg.C", "Pkg.A", "Pkg.B"] #["Pkg.A", "Pkg.B"] #[entryFor "Pkg.C"]).toOption
      == some #["Pkg.C", "Pkg.A", "Pkg.B"]

#guard aModuleListNamingOneModuleTwiceIsOneList

def mergeSaying (i : MergeInputs) : IO (MergeSummary × Option String) := do
  match ← merge i with
  | .error (code, why) => return (default, some s!"merge refused with {code}: {why}")
  | .ok summary => return (summary, none)

def schemaOf (index : FilePath) : IO String := do
  match parseJson (← IO.FS.readFile index) with
  | .error why => return s!"unparsable: {why}"
  | .ok j => return jvalKey (jvalGet? j "schemaVersion")

/-- The seam the two guards above cannot reach, over a tree holding two extractor
runs' output at once: `Pkg.B` is at schema 6 and the re-extracted `Pkg.A` at 5, so
the index's number is not the base's, and the dependency slice is written from
the same value.

The removal is what makes the two spellings of `out` decide different things, and
without it this fixture would hold whichever answer `sameTree` gave: the copy
branch it would take reads the whole file before it opens the destination, so
copying a module onto itself is a no-op here rather than an emptied file. What it
does skip is the removal, which would leave `Pkg.C`'s module file on disk with
nothing in the index naming it — a file every later stage reads as absent. -/
def anInPlaceMergeSpelledAnotherWayStillMergesInPlace : Invariant where
  name := "merge in place through a second spelling of the base removes and keeps \
    the right files, and the index claims the weakest schema under the tree"
  check := do
    let work ← incrWorkDir "merge-in-place"
    let base := work / "base"
    let inc := work / "inc"
    let refs : SynthRefs := #[("Dep.M", "Dep.x")]
    writeIrTree base 6 #[
      { name := "Pkg.A", schemaVersion := 6, decls := #[("Pkg.A.a", refs)], contentHash := "a0" },
      { name := "Pkg.B", schemaVersion := 6, decls := #[("Pkg.B.b", refs)], contentHash := "b0" },
      { name := "Pkg.C", schemaVersion := 6, decls := #[("Pkg.C.c", refs)], contentHash := "c0" }]
    writeIrTree inc 5 #[
      { name := "Pkg.A", decls := #[("Pkg.A.a", refs)], contentHash := "a1" }]
    let untouched := base / "modules" / "Pkg.B.json"
    let before ← IO.FS.readFile untouched

    -- One directory, two spellings: `..` is not normalised away, so this is the
    -- spelling that survives a comparison of the strings.
    let spelled : FilePath := ⟨base.toString ++ "/../base"⟩
    let (summary, refusal) ← mergeSaying
      { base, inc := some inc, out := spelled, removed := #["Pkg.C"] }
    let stillThere ← IO.FS.readFile untouched
    let goneFromDisk ← (base / "modules" / "Pkg.C.json").pathExists
    let schema ← schemaOf (base / "index.json")
    let depSlice ← IO.FS.readFile (base / "deps" / "Dep.json")
    removeDir work
    return first [
      refusal,
      eq stillThere before,
      eq goneFromDisk false,
      eq summary.removed 1,
      eq summary.irChanged #["Pkg.A"],
      eq summary.modules 2,
      eq schema "=5",
      eq (depSlice.splitOn "\"schemaVersion\":5").length 2]

/-- The other spelling of `out`, and the comparison a caller uses to check it.

A fold into a **fresh** `--out` has to leave the base tree byte for byte as it
was: `merge` is the one stage that reads a tree and writes one, and the default
`--out` is `<base>.merged` precisely so that a caller who forgets the flag keeps
the tree they were reading. The claim is over the base's own bytes rather than
over the summary, which would say the same thing for a run that had overwritten
them.

`--verify` is asked of **two directories written separately**, never of one path
twice: a comparison pointed at a single tree passes for a comparator that only
looked at its argument. And it is asked in both directions — yes for two trees
holding the same world, no for two that differ by one module's IR — because
either answer alone is what a comparator that always says the same thing gives.

The two trees here are both written from scratch. A *merged* tree is not the
comparison to make against a synthetic from-scratch one: `merge` recomputes
`dependencyMaps` from the module files it merged, while this fixture writes the
array empty, so the two would differ over the fixture rather than over the
merge. -/
def aFoldIntoAFreshOutLeavesTheBaseAloneAndVerifyTellsTheTwoTreesApart : Invariant where
  name := "merge into a fresh --out leaves every byte of the base, a deletion needs no \
    partial tree, and --verify says yes for two trees written separately and no for two \
    that differ"
  check := do
    let work ← incrWorkDir "merge-verify"
    let base := work / "base"
    let inc := work / "inc"
    let out := work / "out"
    let refs : SynthRefs := #[("Dep.M", "Dep.x")]
    let after : Array SynthIrModule :=
      #[{ name := "Pkg.A", decls := #[("Pkg.A.a", refs)], contentHash := "a1" },
        { name := "Pkg.B", decls := #[("Pkg.B.b", refs)], contentHash := "b0" }]
    writeIrTree base 5
      #[{ name := "Pkg.A", decls := #[("Pkg.A.a", refs)], contentHash := "a0" },
        { name := "Pkg.B", decls := #[("Pkg.B.b", refs)], contentHash := "b0" }]
    writeIrTree inc 5 #[after[0]!]
    let baseIndexBefore ← IO.FS.readFile (base / "index.json")
    let baseModuleBefore ← IO.FS.readFile (base / "modules" / "Pkg.A.json")

    let (summary, refusal) ← mergeSaying
      { base, inc := some inc, out, modules := some #["Pkg.A", "Pkg.B"] }
    let baseIndexAfter ← IO.FS.readFile (base / "index.json")
    let baseModuleAfter ← IO.FS.readFile (base / "modules" / "Pkg.A.json")

    -- **A deletion needs no partial extraction.** It is the shape a pure-deletion
    -- round takes — `inc` is `none` when nothing went stale — and a merge that
    -- required a tree could not express the commonest deletion at all.
    let dropped := work / "dropped"
    let (deletion, deletionRefusal) ←
      mergeSaying { base, out := dropped, removed := #["Pkg.B"] }
    let droppedIndex ← IO.FS.readFile (dropped / "index.json")
    let droppedFile ← (dropped / "modules" / "Pkg.B.json").pathExists

    -- The same world written into two directories, neither of them `out`: two
    -- trees a comparator has to call equal without having any byte of one in the
    -- other.
    let one := work / "one"
    let two := work / "two"
    writeIrTree one 5 after
    writeIrTree two 5 after
    let same ← verify one two
    -- One module's IR moved on: two trees a round apart, which is what `--verify`
    -- is run to find.
    let other := work / "other"
    writeIrTree other 5 #[after[0]!, { name := "Pkg.B", decls := #[("Pkg.B.b", refs)],
                                       contentHash := "b1" }]
    let differ ← verify one other
    removeDir work

    let problemsOf (r : Except MergeRefusal VerifyReport) : Option Nat :=
      match r with | .ok report => some report.problems | .error _ => none
    return first [
      refusal, deletionRefusal,
      eq summary.updated #["Pkg.A"],
      eq summary.irChanged #["Pkg.A"],
      eq baseIndexAfter baseIndexBefore,
      eq baseModuleAfter baseModuleBefore,
      eq (deletion.updated, deletion.removed, deletion.modules) (#[], 1, 1),
      eq (droppedIndex.splitOn "\"Pkg.B\"").length 1,
      eq droppedFile false,
      eq (problemsOf same) (some 0),
      eq ((problemsOf differ).map (· != 0)) (some true)]

end Litedoc4Test
