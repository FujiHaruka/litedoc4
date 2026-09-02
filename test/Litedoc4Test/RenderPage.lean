/- Which declarations get an entry, in what order they and the module
docstrings appear, and the frame around them.

The first two are closed now that `suppressedOf` is not in `IO` — it reads no
file and opened none, and while it was an `IO` action the set it computes could
not be asked a question at compile time. The third builds a whole page, whose
docstrings are Markdown, so it runs.

`page_path` has no guard of its own: the rule is `pageUrl`'s, guarded in
`Litedoc4Test.IrName` against the path spelling beside it. -/
import Litedoc4.Render.Page
import Litedoc4Test.Basis
import Litedoc4Test.RenderDecl

namespace Litedoc4Test
open Litedoc4

/-- Two docstrings and three declarations, one of which is another declaration's
member. `Pkg.Two.b` has in-module index 0 and sits at the same `(line, col)` as
the second module docstring, so `index` and `k + index` disagree about which
comes first — and only here. -/
def pkgTwoPage : Module :=
  { name := "Pkg.Two", schemaVersion := 5,
    moduleDocs := #[{ line := 1, col := 0, text := "first" },
      { line := 7, col := 0, text := "second" }],
    decls := #[
      { name := "Pkg.Two.b", kind := "theorem", ty := "T",
        line := 7, col := 0, endLine := 7, endCol := 1, index := 0 },
      { name := "Pkg.Two.a", kind := "structure", ty := "T",
        line := 5, col := 0, endLine := 5, endCol := 1, index := 1,
        members := #[{ label := "ctor", name := "Pkg.Two.a.mk" }] },
      { name := "Pkg.Two.a.mk", kind := "constructor", ty := "T",
        line := 5, col := 0, endLine := 5, endCol := 1, index := 2 }] }

/-- The same declaration, filed under a module that does not own the structure it
is a member of. -/
def pkgOnePage : Module :=
  { name := "Pkg.One", schemaVersion := 5,
    decls := #[
      { name := "Pkg.One.s", kind := "structure", ty := "T",
        line := 1, col := 0, endLine := 1, endCol := 1, index := 0,
        members := #[{ label := "ctor", name := "Pkg.Two.b" }] }] }

/-- What the page shows, in the order it shows it: a docstring by its text, a
declaration by its name. -/
def shownOn (m : Module) (sup : Std.HashSet String) : Array String :=
  (pageItems m sup).map fun it =>
    if it.isDoc then m.moduleDocs[it.idx]!.text else m.decls[it.idx]!.name

/-- `DocInfo.ofConstant` sets `render := false` for exactly the names that appear
as some declaration's `members`, so the rule is "is this name a member of
*anything*" — collected across **every** module, because a structure declared in
`A` can have its projections attributed to `B`. A per-module set leaves those on
`B`'s page, which is what the second half here shows: were it ever to stop
leaving them, the first half would stop proving anything. -/
def theSuppressedSetSpansTheSite : Bool :=
  let site := suppressedOf #[pkgTwoPage, pkgOnePage]
  let perModule := suppressedOf #[pkgTwoPage]
  site.contains "Pkg.Two.a.mk" && site.contains "Pkg.Two.b" && site.size == 2
    && !perModule.contains "Pkg.Two.b"
    && shownOn pkgTwoPage perModule == #["first", "Pkg.Two.a", "second", "Pkg.Two.b"]
    && shownOn pkgTwoPage site == #["first", "Pkg.Two.a", "second"]

#guard theSuppressedSetSpansTheSite

/-- The tie-breaker is a **running sequence number** and not `Decl.index`: the
docstrings take `0..k` and a declaration takes `k + index`, which is what keeps a
docstring ahead of a declaration at the same position. Using `index` directly
puts declaration 0 ahead of the second module docstring whenever the two share
one. The declarations keep their own relative order all the same, which is what
the offset preserves. -/
def aModuleDocstringPrecedesADeclarationAtTheSamePosition : Bool :=
  shownOn pkgTwoPage (Std.HashSet.emptyWithCapacity 0)
    == #["first", "Pkg.Two.a", "Pkg.Two.a.mk", "second", "Pkg.Two.b"]

#guard aModuleDocstringPrecedesADeclarationAtTheSamePosition

/-- The body is assembled in a different order from the one it is written in: the
sidebar's table of contents is the page's declarations *in page order*, which is
only known once they have been laid out, so `main` is built first and the frame
around it second. That makes the docstring ordering reach two places in the
output rather than one, and both are asserted.

The doctype is not decoration: without it the browser is in quirks mode, where
`box-sizing` and the grid the page is laid out on behave differently. -/
def thePageWrapsMainInTheFrame : Invariant where
  name := "a page is doctype, head, body, the frame, and main in page order"
  check := do
    let ix := declIndex [] pkgTwoPage
    let sup := suppressedOf #[pkgTwoPage]
    let title := siteTitle #[pkgTwoPage.name]
    match (pageHtml ix pkgTwoPage sup "https://h/o/r/blob/dead" title).run 0 with
    | .error message => return some s!"the page was refused: {message}"
    | .ok (html, _) =>
      let toc := (html.splitOn "<main").headD ""
      return first [
        if html.startsWith "<!DOCTYPE html><html lang=\"en\"><head>" then none
          else some s!"the page does not open with the doctype: {html}",
        if emits html "</head><body data-root=\".././\" data-module=\"Pkg.Two\">" then none
          else some s!"the page does not tell app.js where it is: {html}",
        if emits html "<main class=\"content\" id=\"content\"><div class=\"modhead\">" then none
          else some s!"the module heading does not open main: {html}",
        if before html "<div class=\"modmeta\">" "<div class=\"moddoc\"><p>first</p></div>"
          then none else some s!"the imports do not precede the module's own first word: {html}",
        if html.endsWith "</main></div></body></html>" then none
          else some s!"the page does not close: {html}",
        if before toc "#Pkg.Two.a\"" "#Pkg.Two.b\"" then none
          else some s!"the table of contents is not in page order: {toc}"]

end Litedoc4Test
