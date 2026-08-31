/- `crates/litedoc4/src/packages.rs`: which GitHub blob prefix each dependency's
module root belongs to.

`externalLinks` was three answers from the world with the whole rule in between;
the rule is now `assembleLinks`, a function of those three answers, so what is
left in `IO` is `lean --githash`, one `readFile` and one `readDir` per entry.
That is what puts the unpinnable third state below at compile time — it used to
need a package tree on disk to reach.

`a_lake_name_loses_its_guillemets` and `a_git_package_becomes_a_blob_base` are
`tools/pinned-dep-gate.sh`'s and are not repeated here. -/
import Litedoc4.Packages
import Litedoc4Test.IncrFixture

namespace Litedoc4Test
open Litedoc4 System

/-- 40 lower-case hex digits and nothing else. **`A`-`F` is rejected on
purpose**: the same string reaches `renderKey.externalLinks`, and two spellings
of one revision are two keys — every page would re-render on the run that
changed the spelling. A tag and a short hash are not version-pinned links at
all. -/
def onlyFortyLowerCaseHexDigitsAreARevision : Bool :=
  isFortyHex "fabf563a7c95a166b8d7b6efca11c8b4dc9d911f"
    && !isFortyHex "FABF563A7C95A166B8D7B6EFCA11C8B4DC9D911F"
    && !isFortyHex "fabf563a7c95a166b8d7b6efca11c8b4dc9d911F"
    && !isFortyHex "v4.31.0"
    && !isFortyHex "main"
    && !isFortyHex "fabf563"
    && !isFortyHex ""

#guard onlyFortyLowerCaseHexDigitsAreARevision

def pinnedRev : String := "fabf563a7c95a166b8d7b6efca11c8b4dc9d911f"

/-- Both shapes of unpinnable entry, because they are found in different places
on disk: a `path` dependency by its own `dir`, and a git dependency pinned at a
tag under `packagesDir`. -/
def threeKindsOfEntry : String :=
  "{\"packagesDir\": \".lake/packages\", \"packages\":
     [{\"type\": \"path\", \"name\": \"dep\", \"dir\": \"../dep\"},
      {\"url\": \"https://github.com/o/tagged\", \"type\": \"git\",
       \"rev\": \"v4.31.0\", \"name\": \"tagged\"},
      {\"url\": \"https://github.com/o/pinned\", \"type\": \"git\",
       \"rev\": \"" ++ pinnedRev ++ "\", \"name\": \"pinned\"}]}"

def scanOf (m : Manifest) (roots : Array (Array String)) : Array ScannedPackage :=
  m.packages.zipIdx.map fun (entry, i) =>
    { entry, dir := packageDir "/pkg" m.packagesDir entry, roots := .ok (roots.getD i #[]) }

/-- **A dropped entry still contributes its roots, with an empty base.** The
three counts are three different answers and are asserted apart: `declared` is
what the manifest listed, `resolved` is entries that contributed a root *with* a
URL, and `unpinnedRoots` is the roots the pages lose their links to.

A root in the map with an empty base and a root the map does not hold at all are
the two states this turns on — `RootSource.unpinned` against `.absent` — and the
second is a module of the package being documented, whose links are relative and
right. Dropping the unpinnable roots instead would silently turn every link into
the dependency into a relative one to a page this site never writes.

One problem line for `lake` and one per unpinnable entry, and **not** a second
line for the scan: an entry already reported as unlinkable would otherwise be
counted twice. -/
def anUnpinnableDependencyContributesRootsWithNoBase : Bool :=
  match parseManifest "lake-manifest.json" threeKindsOfEntry with
  | .error _ => false
  | .ok m =>
    let p := assembleLinks (.error "lean --githash: no such file") (.ok m)
      (scanOf m #[#["DepAux"], #["Tagged"], #["Pinned"]])
    p.declared == 3 && p.resolved == 1 && p.unpinnedRoots == 2
      && p.links.roots.map (fun r => (r.name, r.base))
        == #[("DepAux", ""), ("Tagged", ""), ("Pinned", "https://github.com/o/pinned/blob/" ++ pinnedRev)]
      && p.links.sourceFor "DepAux" == .unpinned
      && p.links.sourceFor "Tagged" == .unpinned
      && p.links.sourceFor "Pkg" == .absent
      && p.links.urlFor "DepAux.Basic" none == none
      && p.links.urlFor "Pinned.M" none
        == some ("https://github.com/o/pinned/blob/" ++ pinnedRev ++ "/Pinned/M.lean")
      && p.problems.size == 3
      && p.collisions.isEmpty

#guard anUnpinnableDependencyContributesRootsWithNoBase

/-- A `path` entry is looked for where it says it is and a fetched one under
`packagesDir`; taking `<packagesDir>/<name>` for both would scan a directory Lake
never created and cost that dependency every link it has. -/
def aPathEntryIsFoundWhereItSaysAndAFetchedOneUnderPackagesDir : Bool :=
  match parseManifest "lake-manifest.json" threeKindsOfEntry with
  | .error _ => false
  | .ok m =>
    (scanOf m #[]).map (·.dir.toString)
      == #["/pkg/../dep", "/pkg/.lake/packages/tagged", "/pkg/.lake/packages/pinned"]

#guard aPathEntryIsFoundWhereItSaysAndAFetchedOneUnderPackagesDir

/-- **The file is the rule**, and that is the half only a directory can answer:
which top-level `*.lean` files a package has decides which module roots it
provides, and neither a bare directory nor `lakefile.lean` is one. Sorted,
because two machines resolving the map in different directory orders would
otherwise write two different `externalLinks` digests and re-render every page. -/
def aRootIsATopLevelLeanFileWithOrWithoutADirectory : Invariant where
  name := "a module root is a top-level .lean file: a directory with none beside it is not one, \
    a file with no directory is, and lakefile.lean is never one"
  check := do
    let work ← incrWorkDir "packages-roots"
    let pkg := work / "pkg"
    for dir in ["Mathlib/Order", "MathlibTest", "Archive"] do
      IO.FS.createDirAll (pkg / dir)
    for file in ["Mathlib.lean", "Archive.lean", "MD4Lean.lean", "lakefile.lean",
        "Mathlib/Order/Basic.lean", "MathlibTest/Case.lean"] do
      IO.FS.writeFile (pkg / file) ""
    let found ← moduleRoots pkg
    let absent ← moduleRoots (work / "nowhere")
    removeDir work
    return first [
      eq found.toOption (some #["Archive", "MD4Lean", "Mathlib"]),
      -- A package in the manifest and not on disk is a problem line, not a
      -- throw: the run keeps the links it can still resolve.
      eq (match absent with
          | .error why => (why.splitOn "not on disk").length == 2
          | .ok _ => false) true]

end Litedoc4Test
