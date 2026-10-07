/- What the pages a reader arrives at rather than navigates to say.

Split by what a page is made of, not by which page it is. The search and
foundational-types bodies are string building, so they are `#guard`s; a module
description is Markdown, which reaches `Md.events`, so those two are
`Invariant`s. -/
import Litedoc4.Assets
import Litedoc4.Global.Entry
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4

def has (haystack needle : String) : Bool := (haystack.splitOn needle).length > 1

def countOf (haystack needle : String) : Nat := (haystack.splitOn needle).length - 1

def countsAreGroupedInThrees : Bool :=
  grouped 0 == "0" && grouped 432 == "432" && grouped 4750 == "4,750"
    && grouped 1000000 == "1,000,000"

#guard countsAreGroupedInThrees

/-- A rename on either side of these ids is a page that loads, validates and does
nothing. The body carries no `search-input`: the top bar already carries one,
and a page with two is a question about which of them the page script is
reading. -/
def theScriptFindsTheHolesItFills : Bool :=
  ["page-results", "page-note"].all (fun id => has searchBody s!"id=\"{id}\"")
    && countOf searchBody "id=\"search-input\"" == 0

#guard theScriptFindsTheHolesItFills

def theFoundationalPageCoversTheFourThingsASignatureLinksTo : Bool :=
  ["Sort u", "Prop", "Type u", "Dependent function types"].all (has foundationalTypesBody)

#guard theFoundationalPageCoversTheFourThingsASignatureLinksTo

/-- An `Invariant` and not a `#guard`: a description is the one thing on these
pages that goes through the Markdown parser, and that is `@[extern]` C the
interpreter cannot call. -/
def aModuleDescriptionIsEscapedLikeEverythingElse : Invariant where
  name := "a module description is escaped on the way into the module list"
  check := do
    let html := summaryHtml "" "a < b & c"
    return if has html "a &lt; b &amp; c" then none
      else some s!"the description reached the module list unescaped: {html}"

def classNames (page : String) : Array String := Id.run do
  let mut out : Array String := #[]
  for chunk in (page.splitOn "class=\"").drop 1 do
    for name in ((chunk.splitOn "\"").headD "").splitOn " " do
      if !name.isEmpty then out := out.push name
  return out

/-- A class invented here — `modlist` was one for months — is styled by nobody
and nothing says so. `tools/assets-gate.sh` checks the classes the page script
assigns; this is the half Lean writes. -/
def everyClassTheEntryPagesEmitIsStyled : Invariant where
  name := "every class the entry bodies and a module description emit has a rule in style.css"
  check := do
    let mut seen := 0
    let mut missing : Array String := #[]
    for page in [searchBody, foundationalTypesBody, summaryHtml "" "Described"] do
      for cls in classNames page do
        seen := seen + 1
        if !has styleCss ("." ++ cls) then missing := missing.push cls
    return first [
      eq missing #[],
      if seen > 5 then none else some s!"only {seen} class name(s) found — the scan broke"]

end Litedoc4Test
