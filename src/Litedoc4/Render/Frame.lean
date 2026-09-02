import Litedoc4.Assets
import Litedoc4.Render.Code
import Litedoc4.Render.Order

namespace Litedoc4

/-! ## The frame

The theme boot script is inlined in `<head>` on purpose: an external module runs
after first paint, so a reader on the dark theme would see a white flash on
every navigation. Its bytes come from `Litedoc4.Assets`, generated from
`assets/theme-boot.js`, rather than a literal copied to here: a copy is right on
the day it is made and goes stale without saying so. -/

def iconMenu : String :=
  "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M3 5h14M3 10h14M3 15h14\"/></svg>"

def iconTheme : String :=
  "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M10 3a7 7 0 1 0 7 7 5.5 5.5 0 0 1-7-7z\"/></svg>"

def siteTitle (modules : Array String) : String := Id.run do
  if modules.isEmpty then return "Documentation"
  let head := (moduleComponents modules[0]!)[0]!
  for m in modules do
    if (moduleComponents m)[0]! != head then return "Documentation"
  return head

def headHtml (out : String) (module root title : String) : String := Id.run do
  let mut acc := escapeInto (out ++ "<head><meta charset=\"utf-8\"><meta name=\"viewport\" \
    content=\"width=device-width, initial-scale=1\"><title>") module
  if !title.isEmpty && title != module then
    acc := escapeInto (acc ++ " · ") title
  acc := escapeInto (acc ++ "</title><link rel=\"stylesheet\" href=\"") (root ++ "style.css")
  acc := escapeInto (acc ++ "\"><link rel=\"icon\" href=\"") (root ++ "favicon.svg")
  acc := acc ++ "\"><script>" ++ themeBootJs ++ "</script><script type=\"module\" src=\""
  acc := escapeInto acc (root ++ "app.js")
  return acc ++ "\"></script></head>"

/-- `withNav` is false on the pages that have no sidebar — the index, search and
not-found pages are one column, and a button that opens nothing is worse than no
button. -/
def topbarHtml (out : String) (root title : String) (withNav : Bool) : String := Id.run do
  let mut acc := out ++ "<header class=\"topbar\">"
  if withNav then
    acc := acc ++ "<button class=\"iconbtn\" id=\"nav-toggle\" aria-label=\"Modules\" \
      aria-expanded=\"false\" aria-controls=\"sidebar\">" ++ iconMenu ++ "</button>"
  acc := acc ++ "<a class=\"home\" href=\""
  acc := escapeInto acc (root ++ "index.html") ++ "\">"
  acc := escapeInto acc title
  acc := acc ++ "</a><form class=\"search\" role=\"search\" action=\""
  acc := escapeInto acc (root ++ "search.html")
  acc := acc ++ "\"><input type=\"search\" id=\"search-input\" name=\"q\" autocomplete=\"off\" \
    spellcheck=\"false\" placeholder=\"Search declarations\" aria-label=\"Search declarations\">\
    <ul class=\"search-results\" id=\"search-results\" hidden></ul></form>\
    <button class=\"iconbtn\" id=\"theme-toggle\" aria-label=\"Theme\">" ++ iconTheme
  return acc ++ "</button></header>"

/-- The module tree is empty markup `app.js` fills: doc-gen4's equivalent is
57,949 B for this package, and putting it on all 422 pages would add ~25 MB. -/
def sidebarHtml (out : String) (root : String) (memberNames : Array String) : String := Id.run do
  let mut acc := out ++ "<div class=\"scrim\" id=\"scrim\" hidden></div><nav class=\"sidebar\" \
    id=\"sidebar\" aria-label=\"Navigation\">"
  if !memberNames.isEmpty then
    acc := acc ++ "<section class=\"side\"><h2 class=\"side-title\">On this page</h2>\
      <ul class=\"toc\">"
    for name in memberNames do
      acc := escapeInto (acc ++ "<li><a href=\"#") name ++ "\">"
      acc := breakWithin acc name
      acc := acc ++ "</a></li>"
    acc := acc ++ "</ul></section>"
  acc := acc ++ "<section class=\"side\"><h2 class=\"side-title\">Modules</h2>\
    <div class=\"tree\" id=\"module-tree\"><noscript><a href=\""
  acc := escapeInto acc (root ++ "index.html")
  return acc ++ "\">Module index</a></noscript></div></section></nav>"

def moduleHeadHtml (out : String) (module moduleUrl : String) : String := Id.run do
  let mut acc := breakWithin (out ++ "<div class=\"modhead\"><h1>") module
  acc := acc ++ "</h1><p class=\"modactions\"><a class=\"src\" href=\""
  acc := escapeInto acc moduleUrl
  return acc ++ "\">source</a></p></div>"

/-- Duplicates dropped keeping the first occurrence, then a sort by `Name.lt`.
Nearly every import of a package like this one is a dependency's module and this
site has a page for none of them, so most `<li>`s carry no `<a>` at all. -/
def sortedImports (imports : Array String) : Array String := Id.run do
  let mut seen : Std.HashSet String := Std.HashSet.emptyWithCapacity 16
  let mut out : Array String := #[]
  for im in imports do
    if !seen.contains im then
      seen := seen.insert im
      out := out.push im
  return out.qsort nameLt

def moduleMetaHtml (out : String) (ix : NameIndex) (root : String) (imports : Array String) :
    String := Id.run do
  let sorted := sortedImports imports
  let mut acc := out ++ "<div class=\"modmeta\"><details class=\"imports\"><summary>Imports"
  if !sorted.isEmpty then
    acc := acc ++ " <span class=\"count\">" ++ toString sorted.size ++ "</span>"
  acc := acc ++ "</summary><ul>"
  for im in sorted do
    match linkTo ix root im none with
    | some href =>
      acc := escapeInto (acc ++ "<li><a href=\"") href ++ "\">"
      acc := escapeInto acc im ++ "</a></li>"
    | none => acc := escapeInto (acc ++ "<li>") im ++ "</li>"
  return acc ++ "</ul></details><details class=\"imports\" data-fill=\"imported-by\" hidden>\
    <summary>Imported by</summary><ul></ul></details></div>"

end Litedoc4
