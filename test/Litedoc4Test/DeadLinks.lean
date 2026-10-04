/- A docstring link that names no file of the site: which destinations are
asked about, what they resolve to, and the line a build prints for each. -/
import Litedoc4.Render.Site
import Litedoc4Test.GlobalBuild
import Litedoc4Test.RenderPage

namespace Litedoc4Test
open Litedoc4 System

def onePage : String → Bool := (· == "Pkg/Dead.html")

def aFragmentAWikiNameAUrlAndASchemeAreNotFiles : Bool :=
  ["#Pkg.Dead.f", "##Pkg.Dead.f", "##Missing", "https://example.org/x.html", "http://h",
    "mailto:a@b.c", "ftp://h/x", "javascript:void(0)"].all (linkTarget · == .notAFile)

#guard aFragmentAWikiNameAUrlAndASchemeAreNotFiles

def aDestinationThatClimbsAboveTheRootIsDead : Bool :=
  linkTarget "../X" == .aboveRoot
    && linkTarget "../Hom/NonUnitalAlg" == .aboveRoot
    && linkTarget "Pkg/../../X.html" == .aboveRoot
    && linkTarget "Pkg/../Pkg/Dead.html" == .file "Pkg/Dead.html"
    && isDeadLink (fun _ => true) "../X"

#guard aDestinationThatClimbsAboveTheRootIsDead

def theQueryAndTheFragmentAreNotPartOfTheFile : Bool :=
  linkTarget "Pkg/Dead.html#Pkg.Dead.f" == .file "Pkg/Dead.html"
    && linkTarget "Pkg/Dead.html?q=1#x" == .file "Pkg/Dead.html"
    && !isDeadLink onePage "Pkg/Dead.html#Pkg.Dead.f"
    && !isDeadLink onePage "./Pkg/Dead.html"

#guard theQueryAndTheFragmentAreNotPartOfTheFile

def aDirectoryIsItsIndex : Bool :=
  linkTarget "" == .file "index.html"
    && linkTarget "Pkg/" == .file "Pkg/index.html"
    && linkTarget "Pkg/." == .file "Pkg/index.html"
    && linkTarget "Pkg/Sub/.." == .file "Pkg/index.html"

#guard aDirectoryIsItsIndex

def aNameThatIsNoPageIsDead : Bool :=
  ["fderiv.html", "Geck2017", "defs", "Mathlib/Algebra/FiniteSupport/Basic.lean",
    "Pkg/Dead"].all (isDeadLink onePage)

#guard aNameThatIsNoPageIsDead

def theWholePackageFilesAndTheAssetsAreOnTheSite : Bool :=
  let site := (nonModuleFiles.contains ·)
  !isDeadLink site "references.html#ref_Geck2017"
    && !isDeadLink site "index.html"
    && !isDeadLink site "declarations/name-map.json"
    && !isDeadLink site "style.css"
    && isDeadLink site "tactics.html"

#guard theWholePackageFilesAndTheAssetsAreOnTheSite

def geck : Bibliography :=
  Bibliography.of #[{ citekey := "Geck2017", tag := "[Gec17]", html := "Geck.",
                      plaintext := "Geck." }] (some "digest")

/-- One docstring of each kind holding a dead link, beside the links that are
not: a page of the site with a fragment, a citation and the references page,
`mailto:`, a `##` name and a fragment. -/
def deadLinkModuleDoc : String :=
  "See [the derivative](fderiv.html), [f](Pkg/Dead.html#Pkg.Dead.f), \
    [the book][Geck2017], [all of them](references.html), [mail](mailto:a@b.c), [f](##Pkg.Dead.f) \
    and [here](#Pkg.Dead.f)."

def deadLinkPage : Module :=
  { name := "Pkg.Dead", schemaVersion := 5,
    moduleDocs := #[{ line := 1, col := 0, text := deadLinkModuleDoc }],
    decls := #[
      { name := "Pkg.Dead.f", kind := "theorem", ty := "T", doc := "As in [Geck](Geck2017).",
        line := 3, col := 0, endLine := 3, endCol := 1, index := 0 },
      { name := "Pkg.Dead.S", kind := "structure", ty := "T", doc := "A structure.",
        line := 5, col := 0, endLine := 7, endCol := 1, index := 1,
        members := #[{ label := "field", name := "Pkg.Dead.S.x", text := "T",
                       doc := "Up [one](../X)." }] },
      { name := "Pkg.Dead.I", kind := "inductive", ty := "T", doc := "",
        line := 9, col := 0, endLine := 10, endCol := 1, index := 2,
        members := #[{ label := "ctor", name := "Pkg.Dead.I.c", text := "I",
                       doc := "Bad [path](defs)." }] }] }

def deadLinkWarnings (m : Module) : Except String (Array String) :=
  let sup := suppressedOf #[m]
  let ix := buildIndex #[] #[m] emptyLidx (mkExternalLinks #[]) nonModuleFiles
  let citations := (pageCitations geck m sup).map (·.citation)
  let page := pageHtml ix geck citations m sup "https://h/o/r/blob/dead" "Pkg"
  (page.run {}).map fun (_, s) => s.deadLinks.map (deadLinkWarning m.name)

def aDeadLinkIsWarnedWithItsModuleItsDocstringAndALine : Invariant where
  name := "a dead docstring link is warned with its module, its docstring and a line"
  check := do
    match deadLinkWarnings deadLinkPage with
    | .error message => return some s!"the page was refused: {message}"
    | .ok got => return eq got #[
        "warning: Pkg.Dead:1: the module docstring links to `fderiv.html`, \
          which is not a file on this site",
        "warning: Pkg.Dead:3: the docstring of Pkg.Dead.f links to `Geck2017`, \
          which is not a file on this site; `Geck2017` is a bibliography key: \
          cite it as [text][Geck2017]",
        "warning: Pkg.Dead:5: the docstring of Pkg.Dead.S.x, a field of Pkg.Dead.S \
          (the line is Pkg.Dead.S's), links to `../X`, which is not a file on this site",
        "warning: Pkg.Dead:9: the docstring of Pkg.Dead.I.c, a constructor of Pkg.Dead.I \
          (the line is Pkg.Dead.I's), links to `defs`, which is not a file on this site"]

/-- What `renderSite` itself writes to stderr: the warnings in page order, and
nothing at all for a site with no dead link. -/
def renderPrintsEachDeadLinkOnceAndNothingElse : Invariant where
  name := "render prints each dead link on stderr once, and nothing for a site with none"
  check := do
    let tmp : FilePath := (← IO.getEnv "TMPDIR").getD "/tmp"
    let dir := tmp / s!"litedoc4-lean-test-dead-links-{← IO.Process.getPID}"
    let ir := dir / "ir"
    let stderrOf (modules : Array SynthModule) : IO String := do
      writeSyntheticIr ir modules
      let (err, _) ← IO.FS.withIsolatedStreams (isolateStderr := true) do
        renderSite { ir, pages := dir / "site", sourceUrl := "https://h/o/r/blob/dead",
                     linkIndex := none, bibliography := geck }
      return err
    let clean ← stderrOf #[
      { name := "Pkg.A", decls := #[("Pkg.A.f", "[b](Pkg/B.html#Pkg.B.g)")] },
      { name := "Pkg.B", decls := #[("Pkg.B.g", "[the book][Geck2017]")] }]
    let dead ← stderrOf #[{ name := "Pkg.A", decls := #[("Pkg.A.f", "[x](fderiv.html)")] },
      { name := "Pkg.B", decls := #[("Pkg.B.g", "[Geck](Geck2017)")] }]
    IO.FS.removeDirAll dir
    return first [
      eq clean "",
      eq dead
        ("warning: Pkg.A:0: the docstring of Pkg.A.f links to `fderiv.html`, \
          which is not a file on this site\n\
          warning: Pkg.B:0: the docstring of Pkg.B.g links to `Geck2017`, \
          which is not a file on this site; `Geck2017` is a bibliography key: \
          cite it as [text][Geck2017]\n")]

end Litedoc4Test
