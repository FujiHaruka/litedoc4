/- `crates/litedoc4-incr/src/prune.rs`: the one stage that deletes.

`PageRoot.under` is the lexical guard, split from `PageRoot.resolve` so that what
it decides can be asked of a `String`; everything below it needs a real tree,
because what is being claimed is which files are still there afterwards. -/
import Litedoc4.Incr.Prune
import Litedoc4Test.IncrFixture

namespace Litedoc4Test
open Litedoc4 System

def pagesRoot : PageRoot := { given := "/site/pages" }

def underPath (relative : String) : Option String :=
  (pagesRoot.under relative).toOption.map (·.toString)

/-- `pageUrl` turns every dot into a separator, which is why a Lean module name
cannot normally carry a `..` past it — but `«…»` is Lean's own escape and its
contents are not split, so `«..».Foo` comes out as `../Foo.html`. That makes this
a check and not an argument, and nothing over a real package reaches it. -/
def aNameThatWouldLeaveThePageRootIsRefusedRatherThanResolved : Bool :=
  underPath (pageUrl "Pkg.B") == some "/site/pages/Pkg/B.html"
    && underPath (pageUrl "«..».Foo") == none
    && underPath "../escape.html" == none
    && underPath "Pkg/../../escape.html" == none
    && underPath "Pkg/\x00.html" == none
    && underPath "Pkg/..dots.html" == some "/site/pages/Pkg/..dots.html"

#guard aNameThatWouldLeaveThePageRootIsRefusedRatherThanResolved

/-- The path is **concatenated**, never joined with `FilePath./`, which with an
absolute right-hand side discards the left: a `--remove` line of `/etc/passwd`
would name `/etc/passwd.html` — a deletion outside the tree — instead of the
double-slashed path inside it that the filesystem collapses to
`/site/pages/etc/passwd.html`. -/
def anAbsoluteLookingModuleNameStaysInsideThePageRoot : Bool :=
  underPath (pageUrl "/etc/passwd") == some "/site/pages//etc/passwd.html"

#guard anAbsoluteLookingModuleNameStaysInsideThePageRoot

/-- Not module pages and named by no ledger, so a run that deleted them would
leave a site rendering unstyled until the next full generation. The frozen corpus
holds no site with assets in it. -/
def assetNames : Array String := #["style.css", "app.js", "favicon.svg"]

def assetBody : String := "/* the shipped bytes */"

/-- Two module pages, the assets, and `index.html` — a whole-package artifact the
orphan rule really does take, kept here so that the invariant cannot pass by the
rule having stopped deleting anything at all. -/
def writeSiteWithAssets (pages : FilePath) : IO Unit := do
  removeDir pages
  IO.FS.createDirAll (pages / "Pkg")
  IO.FS.writeFile (pages / "Pkg.html") "<html>Pkg</html>"
  IO.FS.writeFile (pages / "Pkg" / "B.html") "<html>Pkg.B</html>"
  IO.FS.writeFile (pages / "index.html") "<html>the front page</html>"
  for name in assetNames do IO.FS.writeFile (pages / name) assetBody

def assetsIntact (pages : FilePath) : IO (Option String) := do
  for name in assetNames do
    let path := pages / name
    let body ← if ← path.pathExists then IO.FS.readFile path else pure ""
    if body != assetBody then return some s!"{path} was deleted or rewritten by prune"
  return none

/-- A refusal is carried as the invariant's own line rather than thrown: the
runner would name the invariant but not which of its runs stopped. -/
def pruneSaying (i : PruneInputs) : IO (PruneSummary × Option String) := do
  match ← prune i with
  | .error (code, why) => return (default, some s!"prune refused with {code}: {why}")
  | .ok summary => return (summary, none)

/-- Both halves over one site: the deletion list, which is the caller's usual
call and the path the empty-directory pass runs on, and the orphan rule, which is
the half that walks the whole tree. Stated together because the rule they share
is one — "a file that is not a module page stays" — and either half alone reads
as held while the other takes the site's stylesheet.

`--dry-run` is asked first, over the tree the real run is about to change: it has
to compute **the same answer** and write nothing, or "what would this remove" is
a question nobody can afford to ask of a tree they are unwilling to lose. Asking
it of a different tree would let a dry run that silently answered nothing pass. -/
def neitherHalfOfPruneTakesAFileThatIsNotAModulePage : Invariant where
  name := "prune deletes module pages and orphaned .html, leaves every other file alone, \
    and --dry-run gives the same answer having deleted nothing"
  check := do
    let work ← incrWorkDir "prune-assets"
    let pages := work / "site"
    let ir := work / "ir"
    writeIrTree ir 5 #[{ name := "Pkg" }, { name := "Pkg.B" }]

    writeSiteWithAssets pages
    IO.FS.writeFile (work / "removed.txt") "Pkg.B\n"
    -- One page and one module that never had one: a module deleted before it was
    -- ever rendered is not an error, and `1/2 requested` is where that shows.
    IO.FS.writeFile (work / "dry.txt") "Pkg.B\nPkg.Never\n"
    let (dry, dryRefusal) ←
      pruneSaying { pages, remove := some (work / "dry.txt"), dryRun := true }
    let survivedTheDryRun ← (pages / "Pkg" / "B.html").pathExists
    let dirSurvived ← (pages / "Pkg").pathExists
    let (removed, removeRefusal) ← pruneSaying { pages, remove := some (work / "removed.txt") }
    let afterRemove ← assetsIntact pages
    let bStillThere ← (pages / "Pkg" / "B.html").pathExists
    let frontPage ← (pages / "index.html").pathExists

    writeSiteWithAssets pages
    let (orphans, orphanRefusal) ← pruneSaying { pages, ir := some ir }
    let afterOrphans ← assetsIntact pages
    let rootPage ← (pages / "Pkg.html").pathExists
    let liveB ← (pages / "Pkg" / "B.html").pathExists
    let frontPageGone ← (pages / "index.html").pathExists
    removeDir work
    return first [
      dryRefusal, removeRefusal, orphanRefusal,
      -- **`emptied` is empty and that is the honest answer**, not a simulation
      -- of one: nothing was unlinked, so no directory became empty. A dry run
      -- that predicted it would be reporting a second implementation of the
      -- deletion rather than the one the real run uses.
      eq (dry.dryRun, dry.deleted, dry.emptied) (true, #["Pkg.B"], #[]),
      eq (dry.requested, dry.alreadyAbsent) (2, #["Pkg.Never"]),
      eq (survivedTheDryRun, dirSurvived) (true, true),
      eq removed.deleted #["Pkg.B"],
      eq removed.emptied #["Pkg"],
      eq bStillThere false,
      eq frontPage true,
      afterRemove,
      eq orphans.orphans #["index.html"],
      eq frontPageGone false,
      eq (rootPage, liveB) (true, true),
      afterOrphans]

def symlink (target link : FilePath) : IO Unit := do
  let _ ← IO.Process.run { cmd := "ln", args := #["-s", target.toString, link.toString] }

/-- The page tree is the caller's, so it can hold shapes the renderer never
writes, and none of the three below is one a real run produces. A symlinked
directory is neither walked into nor counted as nothing — the second is what
would take the directory holding it away as empty. A page that is a **dangling**
symlink is absent, because `metadata` follows links, and the link survives;
`symlinkMetadata` there would call it present and unlink it. And a module named
`/tmp/evil` is deleted *inside* the root, which is the concatenation the guard
above states reaching a file: joined instead, the path would have been
`/tmp/evil.html`, which is not there, and the module would have come back as
already absent rather than as deleted.

The root itself is never removed even when the tree ends up empty: the caller
stops one level above it, and `allowRemoveDir` says so a second time. -/
def pruneOnlyEverUnlinksInsideTheRootAndNeverThroughASymlink : Invariant where
  name := "prune leaves symlinks, dangling pages and the page root itself alone"
  check := do
    let work ← incrWorkDir "prune-symlink"
    let outside := work / "outside"
    IO.FS.createDirAll outside
    IO.FS.writeFile (outside / "kept.html") "<html>outside the root</html>"
    let ir := work / "ir"
    writeIrTree ir 5 #[]

    let pages := work / "site"
    IO.FS.createDirAll (pages / "Sub")
    symlink outside (pages / "Link")
    symlink outside (pages / "Sub" / "Link")
    let (walked, walkRefusal) ← pruneSaying { pages, ir := some ir }
    let outsideKept ← (outside / "kept.html").pathExists
    let linkKept ← ((pages / "Link").symlinkMetadata.toBaseIO)
    let subKept ← (pages / "Sub").pathExists

    removeDir pages
    IO.FS.createDirAll (pages / "Pkg")
    symlink ⟨"../nowhere.html"⟩ (pages / "Pkg" / "A.html")
    IO.FS.writeFile (work / "removed.txt") "Pkg.A\n"
    let (dangling, danglingRefusal) ← pruneSaying { pages, remove := some (work / "removed.txt") }
    let danglingLink ← ((pages / "Pkg" / "A.html").symlinkMetadata.toBaseIO)
    let pkgKept ← (pages / "Pkg").pathExists

    removeDir pages
    IO.FS.createDirAll (pages / "tmp")
    IO.FS.writeFile (pages / "tmp" / "evil.html") "<html>inside after all</html>"
    IO.FS.writeFile (work / "absolute.txt") "/tmp/evil\n"
    let (absolute, absoluteRefusal) ← pruneSaying { pages, remove := some (work / "absolute.txt") }
    let insideGone ← (pages / "tmp" / "evil.html").pathExists
    let rootKept ← pages.pathExists
    removeDir work
    return first [
      walkRefusal, danglingRefusal, absoluteRefusal,
      eq walked.orphans #[],
      eq (outsideKept, linkKept.toOption.isSome, subKept) (true, true, true),
      eq dangling.alreadyAbsent #["Pkg.A"],
      eq dangling.deleted #[],
      eq (danglingLink.toOption.isSome, pkgKept) (true, true),
      eq absolute.deleted #["/tmp/evil"],
      eq absolute.alreadyAbsent #[],
      eq insideGone false,
      eq rootKept true]

end Litedoc4Test
