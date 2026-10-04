import Litedoc4.Render.Decl
import Litedoc4.Render.Frame
import Litedoc4.Render.PageDocs

open System

namespace Litedoc4

/-- `citations` is what `pageCitations` answers for this page, and the page is
refused unless its anchors are exactly those. -/
def pageHtml (ix : NameIndex) (bib : Bibliography) (citations : Array Citation) (m : Module)
    (sup : Std.HashSet String) (sourceUrl title : String) : RenderM String := do
  let root := pageRoot m.name
  let moduleUrl := moduleSourceUrl sourceUrl m.name
  let c := mkPageCtx ix root m
  let md := pageRenderer c bib
  let dr : DeclRenderer := { ix, root, md, citations }
  let mut main := ""
  let mut memberNames : Array String := #[]
  for it in pageItems m sup do
    if it.isDoc then
      let doc := m.moduleDocs[it.idx]!
      main ← renderDocstring (main ++ "<div class=\"moddoc\">") dr { line := doc.line } doc.text
      main := main ++ "</div>"
    else
      let d := m.decls[it.idx]!
      memberNames := memberNames.push d.name
      main ← declHtml main dr m d moduleUrl
  let written := (← get).cited.size
  if written < citations.size then
    throw s!"{citations.size - written} citation(s) of {citations.size} the page was \
      expected to carry were not written, the first citing {citations[written]!.citekey}"
  let mut out := "<!DOCTYPE html><html lang=\"en\">"
  out := headHtml out m.name root title
  out := escapeInto (out ++ "<body data-root=\"") root
  out := escapeInto (out ++ "\" data-module=\"") m.name
  out := out ++ "\"><a class=\"skip\" href=\"#content\">Skip to content</a>"
  out := topbarHtml out root title true
  out := sidebarHtml (out ++ "<div class=\"shell\">") root memberNames
  out := out ++ "<main class=\"content\" id=\"content\">"
  out := moduleHeadHtml out m.name moduleUrl
  out := moduleMetaHtml out ix root m.imports
  return out ++ main ++ "</main></div></body></html>"

/-- `pageUrl`'s rule as a path, built component by component.

**Not `outDir / pageUrl module`**, which would say the rule once: a URL path
joins with `/` on every platform, and appending one whole to a `FilePath` puts a
`/` inside a path whose separator is a backslash on Windows. The two spellings are
kept apart the way the Rust half keeps `litedoc4_ir::page_path` and
`litedoc4_render::page_path` apart. What would falsify this: dropping Windows
from the release triples, after which one spelling would do. -/
def pagePath (outDir : FilePath) (module : String) : FilePath := Id.run do
  let parts := moduleComponents module
  let mut p := outDir
  for i in [0:parts.size] do
    p := p / (if i + 1 == parts.size then parts[i]! ++ ".html" else parts[i]!)
  return p

end Litedoc4
