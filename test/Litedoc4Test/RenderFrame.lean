/- `<head>`, the top bar, the sidebar, the module heading and the import block
— everything on a page that is not the module's own content.

All closed. None of these builders touches a docstring, so nothing here reaches
`Md.events` and every one is a `#guard`.

`module_source_url`'s own guard is `Litedoc4Test.RenderExternal`'s: the function
moved to `Litedoc4.External`, where the two callers that have to spell a source
URL alike both live. -/
import Litedoc4.Render.Frame
import Litedoc4Test.RenderAutolink

namespace Litedoc4Test
open Litedoc4

/-- Substring, spelled through `splitOn` because that is what the string API
gives: an assertion about markup is nearly always "does this fragment appear",
and the whole page in the failure would say less than the fragment does. -/
def emits (page needle : String) : Bool := (page.splitOn needle).length > 1

def emitCount (page needle : String) : Nat := (page.splitOn needle).length - 1

/-- Whether `a` comes before `b`, by the length of what precedes each. Both have
to be there: a needle that is absent leaves the whole page in front of it, which
is the longest prefix there is and would read as "last" rather than as
"missing". -/
def before (page a b : String) : Bool :=
  emits page a && emits page b
    && ((page.splitOn a).headD "").utf8ByteSize < ((page.splitOn b).headD "").utf8ByteSize

/-- `pages` are the modules this run wrote a file for, `external` is what it
knows about everything else. A whole index rather than a bare `ExternalLinks`,
because two of the import list's three answers need the page set. -/
def frameIndex (pages : List String) (external : List (String × String) := []) : NameIndex :=
  alIndex [] pages "" external

def emptyIndex : NameIndex := frameIndex []

/-- Inlined in `<head>` and *before* the module script, because an external
module runs after first paint and a reader on the dark theme would see a white
flash on every navigation. The order is the whole claim. -/
def theThemeIsSetInlineBeforeTheModuleScript : Bool :=
  before (headHtml "" "Foo" "./" "") "litedoc4-theme" "app.js"
    && emits (headHtml "" "Foo.Bar" ".././" "Pkg") "src=\".././app.js\""

#guard theThemeIsSetInlineBeforeTheModuleScript

/-- `themeBootJs` is minifier output pasted between `<script>` and `</script>`
without escaping — which is correct, script content is not HTML — so a
`</script` anywhere inside it would close the tag early and spill the rest of the
bundle into the document as text. `<!--` opens an HTML comment inside a classic
script for the same historical reason and has the same "silently eats the rest"
failure. The minifier chooses the output and nobody reviews it. -/
def theInlinedBootScriptCannotCloseItsOwnTag : Bool :=
  !emits themeBootJs.toLower "</script" && !emits themeBootJs "<!--"

#guard theInlinedBootScriptCannotCloseItsOwnTag

/-- The boot script and the theme toggle agree about the storage key by
construction — both come from `web/src/theme-key.ts`. This is the half that
reaches Lean. -/
def theBootScriptCarriesTheStorageKey : Bool := emits themeBootJs "litedoc4-theme"

#guard theBootScriptCarriesTheStorageKey

/-- The title is the module and then the site, except on the module whose name
*is* the site's — where the two would read as one name written twice — and
except when there is no site title at all. Both halves are escaped: a module name
really can hold a `"`, because `«A"B»` is a legal Lean module name. -/
def theTitleNamesTheModuleAndThenTheSiteWithoutRepeatingItself : Bool :=
  emits (headHtml "" "Foo.Bar" ".././" "Pkg") "<title>Foo.Bar · Pkg</title>"
    && emits (headHtml "" "Pkg" "./" "Pkg") "<title>Pkg</title>"
    && emits (headHtml "" "Foo" "./" "") "<title>Foo</title>"
    && emits (headHtml "" "A\"B" "./" "S") "<title>A&quot;B · S</title>"

#guard theTitleNamesTheModuleAndThenTheSiteWithoutRepeatingItself

/-- The drawer button opens the sidebar, so the pages that have no sidebar do not
get one: a button that opens nothing is worse than no button. Both bars still
search and still lead home. -/
def aPageWithoutASidebarGetsNoDrawerButton : Bool :=
  let withNav := topbarHtml "" "./" "T" true
  let without := topbarHtml "" "./" "T" false
  emits withNav "id=\"nav-toggle\"" && !emits without "id=\"nav-toggle\""
    && [withNav, without].all fun bar =>
      emits bar "id=\"search-input\"" && emits bar "href=\"./index.html\""

#guard aPageWithoutASidebarGetsNoDrawerButton

/-- The table of contents is the page's order and not a sort — it is a contents
list for what is below it — and a page with nothing on it gets no list at all
rather than an empty one. The module tree is empty markup `app.js` fills, and its
`<noscript>` link is the reason `index.html` has to exist. -/
def theSidebarListsThePageInPageOrderAndAnEmptyPageHasNoContents : Bool :=
  let side := sidebarHtml "" ".././" #["M.N.b", "M.N.a"]
  let empty := sidebarHtml "" "./" #[]
  before side "#M.N.b" "#M.N.a"
    && emits side "<div class=\"tree\" id=\"module-tree\">"
    && emits side "<noscript><a href=\".././index.html\">Module index</a></noscript>"
    && !emits empty "On this page" && emits empty "Modules"

#guard theSidebarListsThePageInPageOrderAndAnEmptyPageHasNoContents

/-- No breadcrumb: the name is spelled out in full here and the sidebar tree
already shows where it sits. -/
def theModuleHeadingIsTheNameAndItsSource : Bool :=
  moduleHeadHtml "" "M.N" "https://x/M/N.lean"
    == "<div class=\"modhead\"><h1><span class=\"name\">M</span>.\
        <span class=\"name\">N</span></h1><p class=\"modactions\">\
        <a class=\"src\" href=\"https://x/M/N.lean\">source</a></p></div>"

#guard theModuleHeadingIsTheNameAndItsSource

/-- Deduplicated **before** the sort, which is why it keeps the first occurrence
and not any other. The order is `Name.lt` and not string order: it compares
parents first, so the one-component names lead. -/
def importsAreDeduplicatedBeforeBeingSortedByNameLt : Bool :=
  sortedImports #["Mathlib.Order", "Init", "Mathlib.Order", "Init.Core", "Zzz"]
    == #["Init", "Zzz", "Init.Core", "Mathlib.Order"]

#guard importsAreDeduplicatedBeforeBeingSortedByNameLt

/-- The count is the imports, and "Imported by" is empty markup that starts
`hidden`: it is a fact about the whole site and `app.js` fills it. A module with
no imports still gets the block, and gets no count beside it. -/
def theMetaBlockCountsImportsAndLeavesImportedByToTheScript : Bool :=
  let block := moduleMetaHtml "" (frameIndex ["A", "B.C"]) ".././" #["B.C", "A"]
  emits block "<summary>Imports <span class=\"count\">2</span></summary>"
    && emits block "<ul><li><a href=\".././A.html\">A</a></li>\
        <li><a href=\".././B/C.html\">B.C</a></li></ul>"
    && emits block "data-fill=\"imported-by\" hidden"
    && emits (moduleMetaHtml "" emptyIndex "./" #[]) "<summary>Imports</summary><ul></ul>"

#guard theMetaBlockCountsImportsAndLeavesImportedByToTheScript

end Litedoc4Test
