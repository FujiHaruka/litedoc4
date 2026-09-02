/- `litedoc4.toml`, what a package says about its own site.

The two keys and what a blank one means are closed, because `parseConfig` now
answers them: the "an empty title is not a title" rule used to sit in the `IO`
shell 40 lines from the reader that produced the title, where nothing could ask
it. What is left in `IO` is the one claim that is about the filesystem — that an
absent file and no package root are the same answer. -/
import Litedoc4.Config
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4 System

def keysOf (text : String) : Option ConfigKeys := (parseConfig text).toOption

/-- `title = ""` would otherwise put a blank where every page names the site, so
a blank title is no title and the derived one stands. Whitespace only is blank:
the trim is over Unicode `White_Space`, so a title of one ideographic space is
not a title either. -/
def aBlankTitleFallsBackToTheDerivedOne : Bool :=
  ["title = \"\"\n", "title = \"   \"\n", "title = \"\\t\"\n", "title = \"\u3000\"\n"].all
      (fun text => keysOf text == some {})
    && keysOf "title = \" MyPkg \"\n" == some { title := some " MyPkg " }

#guard aBlankTitleFallsBackToTheDerivedOne

/-- The one claim left in `IO`: no package root and a root holding no
`litedoc4.toml` are the empty configuration, and an absent file is the ordinary
case rather than a failure — most packages configure nothing.

The work area carries the process id: `litedoc4-test` is one executable a gate
may run while another copy of it is running, and two runs sharing a directory
make each other's failures look like the stage's. -/
def noRootAndNoFileAreTheSameAnswer : Invariant where
  name := "no package root and a root with no litedoc4.toml are the empty configuration"
  check := do
    let base : FilePath := ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩
    let dir := base / s!"litedoc4-lean-test-config-{← IO.Process.getPID}"
    if ← dir.pathExists then IO.FS.removeDirAll dir
    IO.FS.createDirAll dir
    let noRoot ← readSiteConfig none
    let noFile ← readSiteConfig (some dir)
    IO.FS.writeFile (dir / configFile) "title = \"MyPkg\"\nindex = \"docs/index.md\"\n"
    IO.FS.createDirAll (dir / "docs")
    IO.FS.writeFile (dir / "docs" / "index.md") "# Hello\n"
    let read ← readSiteConfig (some dir)
    IO.FS.removeDirAll dir
    return first [
      eq noRoot.title (none : Option String), eq noRoot.indexMarkdown (none : Option String),
      eq noFile.title (none : Option String), eq noFile.indexMarkdown (none : Option String),
      -- The control, and it is load-bearing: without it "an absent file is the
      -- empty configuration" would also hold of a reader that never read
      -- anything. The Markdown is the file's **contents** and not its path,
      -- because the path is relative to the package root and resolving it
      -- anywhere else would be a second place that knows what it is relative to.
      eq read.title (some "MyPkg"), eq read.indexMarkdown (some "# Hello\n")]

end Litedoc4Test
