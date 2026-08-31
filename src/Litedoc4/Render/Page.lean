/- `crates/litedoc4-render/src/page.rs`. -/
import Litedoc4.Render.Decl
import Litedoc4.Render.Frame

open System

namespace Litedoc4

/-- Every name that is some declaration's member, over the **whole site**: a
structure declared in `A` can have its projections attributed to `B`, and a
per-module set leaves those on `B`'s page. -/
def suppressedOf (mods : Array Module) : Std.HashSet String := Id.run do
  let mut s : Std.HashSet String := Std.HashSet.emptyWithCapacity 512
  for m in mods do
    for d in m.decls do
      for mem in d.members do
        s := s.insert mem.name
  return s

/-! ## Page order

A stable sort on `(line, col)` plus a running sequence number: the module
docstrings take `0..k` and a declaration takes `k + index`, which is what keeps
a docstring ahead of a declaration at the same position. -/

structure Item where
  line : Nat
  col : Nat
  seq : Nat
  isDoc : Bool
  idx : Nat
  deriving Inhabited

def itemLt (a b : Item) : Bool :=
  a.line < b.line || (a.line == b.line &&
    (a.col < b.col || (a.col == b.col && a.seq < b.seq)))

def pageItems (m : Module) (sup : Std.HashSet String) : Array Item := Id.run do
  let mut items : Array Item := Array.mkEmpty (m.moduleDocs.size + m.decls.size)
  let mut seq := 0
  for md in m.moduleDocs do
    items := items.push { line := md.line, col := md.col, seq, isDoc := true, idx := seq }
    seq := seq + 1
  for i in [0:m.decls.size] do
    let d := m.decls[i]!
    if sup.contains d.name then continue
    items := items.push
      { line := d.line, col := d.col, seq := seq + d.index, isDoc := false, idx := i }
  return items.qsort itemLt

def pageHtml (ix : NameIndex) (m : Module) (sup : Std.HashSet String)
    (sourceUrl title : String) : RenderM String := do
  let root := pageRoot m.name
  let moduleUrl := moduleSourceUrl sourceUrl m.name
  let c := mkPageCtx ix root m
  let md := pageRenderer c
  let dr : DeclRenderer := { ix, root, md }
  let mut main := ""
  let mut memberNames : Array String := #[]
  for it in pageItems m sup do
    if it.isDoc then
      main ← renderDocstring (main ++ "<div class=\"moddoc\">") md m.moduleDocs[it.idx]!.text
      main := main ++ "</div>"
    else
      let d := m.decls[it.idx]!
      memberNames := memberNames.push d.name
      main ← declHtml main dr m d moduleUrl
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
