/- `litedoc4.toml`, what a package says about its own site.

The two keys and what a blank one means are closed, because `parseConfig` now
answers them: the "an empty title is not a title" rule used to sit in the `IO`
shell 40 lines from the reader that produced the title, where nothing could ask
it. What is left in `IO` is the one claim that is about the filesystem — that an
absent file and no package root are the same answer. -/
import Litedoc4.Config
import Litedoc4Test.Basis
import Litedoc4Test.GlobalEntry

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

def noEquationsUnderIsAOneLineListOfNamespaces : Bool :=
  keysOf "no_equations_under = [\"Mathlib.Tactic\", \"Mathlib.Meta\"]  # meta code\n"
      == some { noEquationsUnder := #["Mathlib.Tactic", "Mathlib.Meta"] }
    && keysOf "no_equations_under = []\n" == some {}
    && keysOf "no_equations_under = [ \"A\" , ]\ntitle = \"T\"\n"
      == some { title := some "T", noEquationsUnder := #["A"] }
    && [ "no_equations_under = \"Mathlib.Tactic\"\n",
         "no_equations_under = [\"Mathlib.Tactic\"\n",
         "no_equations_under = [Mathlib.Tactic]\n",
         "no_equations_under = [\"\"]\n",
         "no_equations_under = [\"Mathlib..Tactic\"]\n",
         "no_equations_under = [\"Mathlib Tactic\"]\n",
         "no_equations_under = [\"A,B\"]\n",
         "no_equations_under = [\"A\"] x\n",
         "no_equations_under = [\"A\"]\nno_equations_under = [\"B\"]\n",
         "title = [\"T\"]\n", "index = [\"docs/index.md\"]\n" ].all (keysOf · == none)

#guard noEquationsUnderIsAOneLineListOfNamespaces

def footerIsOneQuotedPathGivenOnce : Bool :=
  keysOf "footer = \"docs/footer.md\"\n" == some { footer := some "docs/footer.md" }
    && keysOf "title = \"T\"\nfooter = \"f.md\"  # every page\nindex = \"i.md\"\n"
      == some { title := some "T", index := some "i.md", footer := some "f.md" }
    && [ "footer = [\"docs/footer.md\"]\n", "footer = docs/footer.md\n",
         "footer = \"a.md\"\nfooter = \"b.md\"\n", "footers = \"a.md\"\n" ].all (keysOf · == none)

#guard footerIsOneQuotedPathGivenOnce

def indexAndFooterResolveBesideTheFileThatNamesThem : Bool :=
  resolveBeside (ConfigSource.given "/srv/hosting/mathlib/litedoc4.toml").file "footer.md"
      == ("/srv/hosting/mathlib/footer.md" : FilePath)
    && resolveBeside (ConfigSource.package "/pkg").file "docs/index.md"
      == ("/pkg/docs/index.md" : FilePath)
    && (ConfigSource.of "/pkg" none).file == ("/pkg/litedoc4.toml" : FilePath)
    && (ConfigSource.of "/pkg" (some "/elsewhere/site.toml")).file
      == ("/elsewhere/site.toml" : FilePath)

#guard indexAndFooterResolveBesideTheFileThatNamesThem

def eachOfTheThreePageKeysMovesThePagesDigest : Bool :=
  let digests := [({} : SitePages), { title := some "x" }, { indexMarkdown := some "x" },
    { footerMarkdown := some "x" }, { footerMarkdown := some "y" }].map (·.digest)
  digests.eraseDups.length == digests.length

#guard eachOfTheThreePageKeysMovesThePagesDigest

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

/-- A `--config` is read in place of the package's file: its `index` and
`footer` beside it, the bibliography still from the package root. Unlike the
package's own file, one that is not there is an error, and so is a `footer`
naming a file that is not there. -/
def aConfigElsewhereReadsBesideItselfAndAMissingFileIsAnError : Invariant where
  name := "--config's index and footer are read beside it and the bibliography from the root; \
    a --config or a footer that is not there is an error"
  check := do
    let base : FilePath := ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩
    let dir := base / s!"litedoc4-lean-test-config-given-{← IO.Process.getPID}"
    if ← dir.pathExists then IO.FS.removeDirAll dir
    let root := dir / "pkg"
    let hosting := dir / "hosting"
    IO.FS.createDirAll (root / "docs")
    IO.FS.createDirAll hosting
    IO.FS.writeFile (root / configFile) "title = \"Own\"\nfooter = \"docs/footer.md\"\n"
    IO.FS.writeFile (root / "docs" / "footer.md") "own footer\n"
    IO.FS.writeFile (root / "docs" / "references.bib")
      "@misc{K, author={Doe, John}, title={T}, year={2012}}\n"
    let given := hosting / "site.toml"
    IO.FS.writeFile given "title = \"Outside\"\nfooter = \"footer.md\"\n"
    IO.FS.writeFile (hosting / "footer.md") "outside footer\n"
    let own ← readSiteSources root
    let outside ← readSiteSources root (.given given)
    let absentConfig ← (readSiteSources root (.given (hosting / "absent.toml"))).toBaseIO
    IO.FS.removeFile (hosting / "footer.md")
    let absentFooter ← (readSiteSources root (.given given)).toBaseIO
    IO.FS.removeFile (root / "docs" / "footer.md")
    let absentOwnFooter ← (readSiteSources root).toBaseIO
    IO.FS.removeDirAll dir
    return first [
      eq (own.title, own.footerMarkdown) (some "Own", some "own footer\n"),
      eq (outside.title, outside.footerMarkdown) (some "Outside", some "outside footer\n"),
      eq (outside.bibliography.isSome, outside.bibliography == own.bibliography) (true, true),
      if absentConfig matches .error _ then none
        else some "a --config naming no file was read as the empty configuration",
      if absentFooter matches .error _ then none
        else some "a --config's footer naming no file was read as no footer",
      if absentOwnFooter matches .error _ then none
        else some "the package's footer naming no file was read as no footer"]

/-- `docs/references.bib` under the package root, read by convention: absent and
blank are no bibliography and no digest, so neither moves the render key; a file
with an entry is its items and the digest of its bytes; and one BibtexQuery stops
reading part of the way keeps the entries before that point and carries a warning
naming the file and the line, with or without a `litedoc4.toml` beside it. -/
def aBibliographyIsReadByConventionAndABadOneNamesTheFile : Invariant where
  name := "docs/references.bib: absent and blank are none, an entry is read with the \
    file's digest, and one read part of the way keeps its entries and warns naming the file"
  check := do
    let base : FilePath := ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩
    let dir := base / s!"litedoc4-lean-test-bib-{← IO.Process.getPID}"
    if ← dir.pathExists then IO.FS.removeDirAll dir
    IO.FS.createDirAll (dir / "docs")
    let bib := dir / "docs" / "references.bib"
    let absent ← readSiteConfig (some dir)
    IO.FS.writeFile bib " \n\t\n"
    let blank ← readSiteConfig (some dir)
    let entry := "@book{K, author={Doe, John}, title={T}, year={2012}, publisher={P}}\n"
    IO.FS.writeFile bib entry
    let read ← readSiteConfig (some dir)
    IO.FS.writeFile bib (entry ++ "@comment{x}\n")
    let halfRead ← readSiteConfig (some dir)
    IO.FS.removeDirAll dir
    return first [
      eq (absent.bibliography.items.size, absent.bibliography.digest) (0, none),
      eq (blank.bibliography.items.size, blank.bibliography.digest) (0, none),
      eq (read.bibliography.items.map (·.tag)) #["[Doe12]"],
      eq read.bibliography.digest (some (sha256Text entry)),
      eq (halfRead.bibliography.items.map (·.tag)) #["[Doe12]"],
      eq read.bibliography.warning (none : Option String),
      match halfRead.bibliography.warning with
      | some why => if has why bib.toString && has why "line 2:" then none
                    else some s!"the warning does not name the file and the line: {why}"
      | none => some "a bibliography BibtexQuery stops reading half-way carried no warning"]

end Litedoc4Test
