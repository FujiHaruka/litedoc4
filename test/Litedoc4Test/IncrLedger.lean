/- `crates/litedoc4-incr/tests/ledger.rs`: the two cache keys.

`extractKey` reads three files and `extractKeyOf` decides what they mean, so the
key's own shape is a guard and only the seam needs a package on disk. -/
import Litedoc4.Ledger
import Litedoc4Test.IncrFixture

namespace Litedoc4Test
open Litedoc4 System

def sourceUrl : String :=
  "https://github.com/FujiHaruka/information-theory/blob/573793b243fb1343636088eb62d1789ab2b14cec"

def sourceUrl2 : String :=
  "https://github.com/FujiHaruka/information-theory/blob/0000000000000000000000000000000000000000"

/-- What the extractor writes into an IR tree's `generator`. -/
def irIndexOf (generator : String) : JVal :=
  .obj #[("schemaVersion", .num 5), ("generator", .str generator)]

/-- The identity strings are the cache's version key: sharing the frozen
prototype's would let a ledger one implementation wrote be trusted by the other.

The third clause is the opposite claim about a string that looks the same. The
IR's own `generator` is **not** renamed with them — it names what wrote the tree
on disk, which this port does not claim to be — so it has to come back out of the
index verbatim. A rename applied to all three at once passes the first two. -/
def theIdentityStringsAreNotTheFrozenPrototypes : Bool :=
  let key := extractKeyOf "leanprover/lean4:v4.31.0" "0011"
    (some (irIndexOf "lean-doc/experiments/stage4b"))
  extractorId != "lean-doc/experiments/stage4b"
    && rendererId != "lean-doc/experiments/stage4c"
    && keySetGet key "extractor" == some extractorId
    && keySetGet key "irGenerator" == some "lean-doc/experiments/stage4b"
    && keySetGet (renderKey sourceUrl none none) "renderer" == some rendererId
    && key.map (·.1) == #["leanToolchain", "manifestSha256", "extractor",
                          "irSchemaVersion", "irGenerator"]
    && (extractKeyOf "leanprover/lean4:v4.31.0" "0011" none).map (·.1)
      == #["leanToolchain", "manifestSha256", "extractor"]

#guard theIdentityStringsAreNotTheFrozenPrototypes

/-- Where each **dependency's** source lives reaches every page that links into
one, and it moves on exactly the occasion an incremental build runs — a bumped
dependency is a new `rev`. So it is a render key of its own, its position in the
ledger's bytes is its insertion order, and all three of appearing, vanishing and
moving count as a change. The last two clauses are why it is a fourth key rather
than folded into the `.lidx`'s: either digest can move without the other. -/
def theExternalLinksDigestIsARenderKeyOfItsOwn : Bool :=
  let without := renderKey sourceUrl none none
  let with_ := renderKey sourceUrl none (some "d1")
  let moved := renderKey sourceUrl none (some "d2")
  let both := renderKey sourceUrl (some "lidx") (some "d1")
  keySetGet without "externalLinks" == none
    && keySetGet with_ "externalLinks" == some "d1"
    && with_.map (·.1) == #["renderer", "sourceUrl", "externalLinks"]
    && keySetDiff without with_ == #["externalLinks"]
    && keySetDiff with_ without == #["externalLinks"]
    && keySetDiff with_ moved == #["externalLinks"]
    && keySetDiff with_ with_ == #[]
    && both == #[("renderer", rendererId), ("sourceUrl", sourceUrl),
                 ("linkIndex", "lidx"), ("externalLinks", "d1")]
    && keySetDiff both (renderKey sourceUrl (some "lidx") none) == #["externalLinks"]

#guard theExternalLinksDigestIsARenderKeyOfItsOwn

/-- A trailing slash is not a different source URL. Without this every consumer
whose configured URL ends in `/` re-renders every page of the site on the round
after the one that wrote the ledger, for ever. -/
def aTrailingSlashIsNotADifferentSourceUrl : Bool :=
  keySetDiff (renderKey sourceUrl none none) (renderKey (sourceUrl ++ "/") none none) == #[]
    && keySetDiff (renderKey sourceUrl none none) (renderKey sourceUrl2 none none)
      == #["sourceUrl"]
    && keySetDiff (renderKey sourceUrl none none) (renderKey "" none none) == #["sourceUrl"]

#guard aTrailingSlashIsNotADifferentSourceUrl

/-- A key written twice keeps its **first position** and its **last value**,
which is what lets a hand-edited ledger round-trip instead of being rewritten.
Stated over the reader and the writer together: either half alone would be a
claim about a value nobody can see in a file. -/
def aRepeatedKeyKeepsItsFirstPositionAndItsLastValue : Bool :=
  match parseJson "{\"a\":\"1\",\"b\":\"2\",\"a\":\"3\"}" with
  | .error _ => false
  | .ok j =>
    match readKeySet "ledger.json" "extractKey" j with
    | .error _ => false
    | .ok keys => keys == #[("a", "3"), ("b", "2")]
        && keySetJson keys == "{\"a\":\"3\",\"b\":\"2\"}"

#guard aRepeatedKeyKeepsItsFirstPositionAndItsLastValue

structure FakeModule where
  name : String
  /-- All three files of Lean's module system — the shape the measurement target
  does not have and only its dependencies do. -/
  threeFiles : Bool := false
  deriving Inhabited

/-- A target repository as `build` and `check` read one: the two files the
extract key is taken over, and an olean per module with the hash file `lake`
reads instead of its bytes. -/
def writeFakeRepo (repo : FilePath) (modules : Array FakeModule) : IO Unit := do
  removeDir repo
  IO.FS.createDirAll repo
  IO.FS.writeFile (repo / "lean-toolchain") "leanprover/lean4:v4.31.0\n"
  IO.FS.writeFile (repo / "lake-manifest.json") "{\"version\":\"1.1.0\",\"packages\":[]}\n"
  for m in modules do
    let base := ".lake/build/lib/lean/" ++ "/".intercalate (m.name.splitOn ".")
    for suffix in (if m.threeFiles then oleanSuffixes else #[".olean"]) do
      let body := s!"the olean bytes of {m.name}{suffix}"
      writeUnder repo (base ++ suffix) body
      writeUnder repo (base ++ suffix ++ ".hash") s!"{body.hash}\n"

def buildSaying (i : LedgerInputs) (out : FilePath) : IO (Ledger × Option String) := do
  match ← buildLedger i with
  | .error why => return (default, some s!"build refused: {why}")
  | .ok (ledger, _) =>
    IO.FS.writeFile out ledger.toJson
    return (ledger, none)

def checkSaying (i : CheckInputs) : IO (CheckSummary × Option String) := do
  match ← checkLedger i with
  | .error (code, why) => return (default, some s!"check refused with {code}: {why}")
  | .ok summary => return (summary, none)

def touchSaying (ledger : FilePath) (module : String) (out : FilePath) : IO (Option String) := do
  match readLedger ledger.toString (← IO.FS.readFile ledger) with
  | .error (code, why) => return some s!"the ledger would not read ({code}): {why}"
  | .ok read =>
    match touchLedger ledger.toString module read with
    | .error (code, why) => return some s!"touch refused with {code}: {why}"
    | .ok touched => IO.FS.writeFile out touched.toJson; return none

/-- The stage answering the questions it exists for, over a package this owns —
including the dependency shape the measurement target does not have.

Every claim is a deterministic integer or a list of names, never a duration: the
hashes are read through mmap and wall clock moves by 5× with the page cache.

The three that would be silent if they broke are the orders. `removed` puts the
module with no olean first, in the list's order, and then the one the list
dropped — two different reasons to be gone, and a caller reading the file cannot
see which. A touched module is reported as **changed** rather than as added,
because an edit does not add a module and a caller that re-extracts an "added"
one has been told the wrong thing about its history. And a changed extract key
re-extracts *everything present*, in list order, rather than the sorted union
that an unchanged key produces. -/
def theLedgerAnswersEveryScenarioOnASyntheticPackage : Invariant where
  name := "build, touch and check agree about a synthetic package's oleans, its two keys, \
    what a drifting module list means and what the re-extraction set is"
  check := do
    let work ← incrWorkDir "ledger"
    let package := work / "package"
    let dependency := work / "dependency"
    let ir := work / "ir"
    let modules := #["Pkg.A", "Pkg.B", "Pkg.C", "Pkg.D"]
    let depModules := #["Dep.One", "Dep.Two"]
    writeFakeRepo package (modules.map fun name => { name })
    writeFakeRepo dependency (depModules.map fun name => { name, threeFiles := true })
    writeIrTree ir 5 (modules.map fun name => { name })

    let target := package.toString
    let shaPath := work / "ledger-sha256.json"
    let (sha, shaRefusal) ← buildSaying
      { modules, target, ir := some ir, sourceUrl } shaPath
    let (lake, lakeRefusal) ← buildSaying
      { modules, target, ir := some ir, sourceUrl, algorithm := Algorithm.lake }
      (work / "ledger-lake.json")
    let minusAbPath := work / "ledger-minus-ab.json"
    let (_, minusAbRefusal) ← buildSaying
      { modules := modules.extract 2 modules.size, target, ir := some ir, sourceUrl } minusAbPath
    let noIrPath := work / "ledger-no-ir.json"
    let (_, noIrRefusal) ← buildSaying { modules, target, sourceUrl } noIrPath
    let (dep, depRefusal) ← buildSaying
      { modules := depModules, target := dependency.toString, ir := some ir, sourceUrl }
      (work / "ledger-dep.json")

    -- Two rounds through the same file: the second reads the ledger the first
    -- wrote, so a `touch` that dropped the other entries would show up here.
    let touchedPath := work / "ledger-touched.json"
    let touchA ← touchSaying shaPath "Pkg.A" touchedPath
    let touchB ← touchSaying touchedPath "Pkg.B" touchedPath

    let scenario (ledger : FilePath) (list : Option (Array String))
        (irDir : Option FilePath) (url : String) : IO (CheckSummary × Option String) :=
      checkSaying { ledger, modules := list, ir := irDir, sourceUrl := url }
    let all := some modules
    let (clean, cleanRefusal) ← scenario shaPath all (some ir) sourceUrl
    let (touched, touchedRefusal) ← scenario touchedPath all (some ir) sourceUrl
    let drifted := (modules.extract 0 2 ++ modules.extract 3 4).push "Pkg.Ghost"
    let (drift, driftRefusal) ← scenario minusAbPath (some drifted) (some ir) sourceUrl
    let (noIr, noIrCheckRefusal) ← scenario shaPath all none sourceUrl
    let (intoIr, intoIrRefusal) ← scenario noIrPath all (some ir) sourceUrl
    let (otherRev, otherRevRefusal) ← scenario shaPath all (some ir) sourceUrl2
    let (slash, slashRefusal) ← scenario shaPath all (some ir) (sourceUrl ++ "/")
    let (fromLedger, fromLedgerRefusal) ← scenario shaPath none (some ir) sourceUrl
    let (depCheck, depCheckRefusal) ←
      checkSaying { ledger := work / "ledger-dep.json", modules := some depModules
                    ir := some ir, sourceUrl }

    -- A module the package has gained, beside the two that were touched: the one
    -- shape where `changed` and `added` are both non-empty, and therefore the
    -- only one that can tell the re-extraction set from the `changed` line.
    let newBody := "the olean bytes of Pkg.E.olean"
    writeUnder package ".lake/build/lib/lean/Pkg/E.olean" newBody
    writeUnder package ".lake/build/lib/lean/Pkg/E.olean.hash" s!"{newBody.hash}\n"
    let (grown, grownRefusal) ←
      scenario touchedPath (some (modules.push "Pkg.E")) (some ir) sourceUrl
    removeDir work
    let irKeys := #["irGenerator", "irSchemaVersion"]
    return first [
      shaRefusal, lakeRefusal, minusAbRefusal, noIrRefusal, depRefusal,
      touchA, touchB,
      cleanRefusal, touchedRefusal, driftRefusal, noIrCheckRefusal, intoIrRefusal,
      otherRevRefusal, slashRefusal, fromLedgerRefusal, depCheckRefusal, grownRefusal,
      eq (sha.modules.size, fileCountOf sha.modules) (4, 4),
      eq (hashedBytesOf lake.modules) 0,
      eq (fileCountOf dep.modules) 6,
      eq (dep.modules[0]!.files.map (·.path))
        #[".lake/build/lib/lean/Dep/One.olean",
          ".lake/build/lib/lean/Dep/One.olean.server",
          ".lake/build/lib/lean/Dep/One.olean.private"],
      eq (depCheck.modules, depCheck.files) (2, 6),
      eq (clean.changed, clean.added, clean.removed) (#[], #[], #[]),
      eq touched.changed #["Pkg.A", "Pkg.B"],
      eq touched.added #[],
      eq drift.added #["Pkg.A", "Pkg.B"],
      eq drift.removed #["Pkg.Ghost", "Pkg.C"],
      eq noIr.extractKeyChanged irKeys,
      eq noIr.reExtract modules,
      eq intoIr.extractKeyChanged irKeys,
      eq otherRev.renderKeyChanged #["sourceUrl"],
      eq otherRev.reExtract #[],
      eq slash.renderKeyChanged #[],
      eq (fromLedger.fromList, fromLedger.modules) (false, 4),
      -- **The re-extraction set is `changed ∪ added`, not the `changed` line.** A
      -- caller handed the changed set alone leaves the added module with no IR at
      -- all, and every later check calls it added again: the page never appears
      -- and no count says so.
      eq (grown.changed, grown.added, grown.removed) (#["Pkg.A", "Pkg.B"], #["Pkg.E"], #[]),
      eq grown.reExtract #["Pkg.A", "Pkg.B", "Pkg.E"]]

end Litedoc4Test
