/- `crates/litedoc4-global/src/entry.rs`: the four pages a reader arrives at
rather than navigates to.

Split by what a page is made of, not by which page it is. Everything a module row
carries but its *description* is string building, so it is a `#guard`; a
description is Markdown, which reaches `Md.events`, so those two are
`Invariant`s. -/
import Litedoc4.Global.Entry
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4

def has (haystack needle : String) : Bool := (haystack.splitOn needle).length > 1

def countOf (haystack needle : String) : Nat := (haystack.splitOn needle).length - 1

def row (name page : String) : ModuleRow := { name, page }

def countsAreGroupedInThrees : Bool :=
  grouped 0 == "0" && grouped 432 == "432" && grouped 4750 == "4,750"
    && grouped 1000000 == "1,000,000"

#guard countsAreGroupedInThrees

/-- A rename on either side of these ids is a page that loads, validates and does
nothing. The count on `search-input` is the whole of what the Rust assertion
said: the top bar already carries one, and a page with two is a question about
which of them `app.js` is reading. -/
def theScriptFindsTheHolesItFills : Bool :=
  let notFound := notFoundHtml "T"
  let search := searchHtml "T"
  ["missing-path", "how-about", "how-about-heading"].all
      (fun id => has notFound s!"id=\"{id}\"")
    && has notFound "id=\"how-about-heading\" hidden"
    && ["page-results", "page-note"].all (fun id => has search s!"id=\"{id}\"")
    && countOf search "id=\"search-input\"" == 1

#guard theScriptFindsTheHolesItFills

/-- The toolchain the environment was read from, and silence when the IR did not
say — an empty row would read as a package built with no Lean. -/
def theIndexNamesTheToolchainTheIrWasReadFrom : Bool :=
  let modules := #[row "Pkg" "Pkg.html"]
  has (indexHtml "T" none modules 1 "4.33.0") "<dt>Lean</dt><dd>4.33.0</dd>"
    && !has (indexHtml "T" none modules 1 "") "Lean"

#guard theIndexNamesTheToolchainTheIrWasReadFrom

/-- e2e-micro's GATE 14 counts the rows and follows their links, but every module
of that sample is spelled with plain identifiers, so the escaping here is reached
by nothing over a built site. A module name really can hold a `<`: `«A<B»` is a
legal Lean module name and `pageUrl` puts it in the path unchanged. -/
def theIndexListsEveryModuleAndEscapesWhatItPrints : Bool :=
  let page := indexHtml "T" none #[row "Pkg" "Pkg.html", row "Pkg.A<B" "Pkg/A<B.html"] 4750 "4.31.0"
  has page "<dd>2</dd>" && has page "<dd>4,750</dd>"
    && has page "href=\"./Pkg.html\""
    && has page "href=\"./Pkg/A&lt;B.html\""
    && has page "<span class=\"name\">A&lt;B</span>"

#guard theIndexListsEveryModuleAndEscapesWhatItPrints

def theFoundationalPageCoversTheFourThingsASignatureLinksTo : Bool :=
  let page := foundationalTypesHtml "T"
  ["Sort u", "Prop", "Type u", "Dependent function types"].all (has page)

#guard theFoundationalPageCoversTheFourThingsASignatureLinksTo

def described (name page summary : String) : ModuleRow :=
  { name, page, summary := some summary }

/-- An `Invariant` and not a `#guard`: a description is the one thing on these
pages that goes through the Markdown parser, and that is `@[extern]` C the
interpreter cannot call. -/
def aModuleDescriptionIsEscapedLikeEverythingElse : Invariant where
  name := "a module description is escaped on the way into the front page"
  check := do
    let page := indexHtml "T" none #[described "Pkg" "Pkg.html" "a < b & c"] 1 "4.31.0"
    return if has page ">a &lt; b &amp; c</span>" then none
      else some s!"the description reached the page unescaped: {page}"

def classNames (page : String) : Array String := Id.run do
  let mut out : Array String := #[]
  for chunk in (page.splitOn "class=\"").drop 1 do
    for name in ((chunk.splitOn "\"").headD "").splitOn " " do
      if !name.isEmpty then out := out.push name
  return out

/-- `Render`'s own version of this reads the renderer's four source files and
cannot see this stage, so a class invented here — `modlist` was one for months —
is styled by nobody and nothing says so. Read off the built pages rather than off
the literals, because that is where a class on only one branch shows up, which is
why one row carries a description and the other does not. -/
def everyClassTheEntryPagesEmitIsStyled : Invariant where
  name := "every class the four entry pages emit has a rule in style.css"
  check := do
    let modules := #[described "Pkg" "Pkg.html" "Described", row "Pkg.B" "Pkg/B.html"]
    let mut seen := 0
    let mut missing : Array String := #[]
    for page in [indexHtml "T" none modules 1 "4.31.0", notFoundHtml "T", searchHtml "T",
        foundationalTypesHtml "T"] do
      for cls in classNames page do
        seen := seen + 1
        if !has styleCss ("." ++ cls) then missing := missing.push cls
    return first [
      eq missing #[],
      if seen > 20 then none else some s!"only {seen} class name(s) found — the scan broke"]

end Litedoc4Test
