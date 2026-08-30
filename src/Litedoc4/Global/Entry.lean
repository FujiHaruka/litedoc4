/- `crates/litedoc4-global/src/entry.rs`: the four pages a reader arrives at
rather than navigates to — the front door, the one GitHub Pages serves for
anything missing, the one the top bar's form submits to, and the one every
`Sort` / `Type` / `Prop` span in every signature links to.

WHY THE MARKUP IS BUILT HERE AND NOT IN `Render`
  What decides a page's *shape* is `Render.Frame`, and all four take theirs from
  there unchanged. What decides a page's *content* is a fact about the whole
  package — how many modules, which ones, how many declarations — and the whole
  package is what this namespace is about; building them in the renderer would
  mean handing it the module list a second time, from the other side of the
  pipeline. What would falsify this: a landing page whose content is a fact about
  one module.

These pages are one column and carry no repository link. A drawer button that
opens an empty drawer is worse than no button, and the repository URL is
`--source-url`, which reaches the renderer and not this stage. -/
import Litedoc4.Render.Frame

namespace Litedoc4

/-- All four pages sit at the site root, so every asset is one hop away. -/
def entryRoot : String := "./"

structure ModuleRow where
  name : String := ""
  page : String := ""
  /-- The module docstring's opening heading, as Markdown source. `none` draws no
  element, where an empty one would be a placeholder a reader cannot tell from a
  module that described itself with a blank line. -/
  summary : Option String := none
  deriving Inhabited

/-- The `data-module` attribute is empty on purpose: `app.js` reads it to decide
which tree node is current, and none of these pages *is* a module. -/
def plainPage (pageTitle title body : String) : String := Id.run do
  let mut out := headHtml "<!DOCTYPE html><html lang=\"en\">" pageTitle entryRoot title
  out := out ++ "<body class=\"plain\" data-root=\"./\" data-module=\"\">\
    <a class=\"skip\" href=\"#content\">Skip to content</a>"
  out := topbarHtml out entryRoot title false
  out := out ++ "<div class=\"shell\"><main class=\"content\" id=\"content\">" ++ body
  return out ++ "</main></div></body></html>"

def grouped (n : Nat) : String := Id.run do
  let digits := (toString n).toList
  let mut out := ""
  let mut i := 0
  for c in digits do
    if i > 0 && (digits.length - i) % 3 == 0 then out := out.push ','
    out := out.push c
    i := i + 1
  return out

/-- `NoLinks`, so a declaration name in a heading stays a code span: the row
already has one destination, and hundreds of rows of prose each carrying their
own would be a list nobody can scan. The same holds for the configured intro,
where the answer to "does this name have a page" needs a map this stage does not
have — a code span that stays a code span is right, a link to a page nobody wrote
is not. -/
def entryRenderer : Renderer := { root := entryRoot, links := noLinks }

/-- The math spans that fell back here are **not** added to the run's count: the
same span is rendered again on the module's own page, where it is already
counted, and the number means "spans in this package the converter could not
read", not "renderings that fell back". -/
def summaryHtml (out : String) (summary : String) : String :=
  (Id.run ((inlineMd out entryRenderer summary).run 0)).1

/-- The rendered `litedoc4.toml` `index`, for the one page that carries it. -/
def introHtml (markdown : String) : String :=
  (Id.run ((docstring "" entryRenderer markdown).run 0)).1

/-- The front page. **The module list is the whole list, spelled out in the
HTML** — the sidebar is a JSON fetch, and this is the page its `<noscript>` sends
a reader to, so it is the one page that may not need JavaScript to say anything.

`modules` is expected already sorted, in the UTF-16 order everything else is.
`leanVersion` is `index.json`'s, which is the toolchain the environment was read
from rather than the one the reader has; an empty one draws no row, because a
page saying `Lean ` says less than nothing. -/
def indexHtml (title : String) (intro : Option String) (modules : Array ModuleRow)
    (declarations : Nat) (leanVersion : String) : String := Id.run do
  let mut body := escapeInto "<div class=\"modhead\"><h1>" title
  body := body ++ "</h1><p class=\"lede\">API documentation for every module of this package, \
    generated from the compiled environment. Declarations link to their pinned source; an \
    import of a dependency links to that dependency's source at the revision this package is \
    built against.</p></div>"
  -- Between the lede and the counts: it is what the package wants said about
  -- itself, and the counts are what this tool has to say about it.
  match intro with
  | some html => body := body ++ "<div class=\"intro doc\">" ++ html ++ "</div>"
  | none => pure ()
  body := body ++ "<dl class=\"stats\"><div><dt>Modules</dt><dd>" ++ grouped modules.size
    ++ "</dd></div><div><dt>Declarations</dt><dd>" ++ grouped declarations ++ "</dd></div>"
  if !leanVersion.isEmpty then
    body := escapeInto (body ++ "<div><dt>Lean</dt><dd>") leanVersion ++ "</dd></div>"
  body := body ++ "</dl><h2 class=\"section-title\">Modules</h2><ul class=\"modlist"
  if modules.any (·.summary.isSome) then body := body ++ " modlist-described"
  body := body ++ "\">"
  for row in modules do
    body := escapeInto (body ++ "<li><a href=\"./") row.page ++ "\">"
    -- The same per-component markup the module headings and the sidebar use, so
    -- a long name wraps between components rather than mid-word.
    body := breakWithin body row.name ++ "</a>"
    match row.summary with
    | some summary =>
      body := summaryHtml (body ++ "<span class=\"modsummary\">") summary ++ "</span>"
    | none => pure ()
    body := body ++ "</li>"
  return plainPage title title (body ++ "</ul>")

/-- Static markup with two holes `app.js` fills: `#missing-path` gets the URL
that was asked for, `#how-about` the nearest declaration names. The heading above
the list starts `hidden` because "Did you mean" with nothing under it is worse
than silence, and the paragraph names the module index in prose because with
JavaScript off both holes stay empty. -/
def notFoundHtml (title : String) : String :=
  plainPage "Not found" title
    "<div class=\"modhead\"><h1>Page not found</h1><p class=\"lede\">Nothing in this \
    documentation is at <code class=\"missing-path\" id=\"missing-path\"></code>. If a \
    declaration has moved, the closest matches are below; otherwise the <a \
    href=\"./index.html\">module index</a> lists every page.</p></div><h2 \
    class=\"section-title\" id=\"how-about-heading\" hidden>Did you mean</h2><ul \
    class=\"results\" id=\"how-about\"></ul>"

/-- **There is no input field here.** `app.js` reads the top bar's
`#search-input`, seeds it from `?q=` and renders into `#page-results`; a second
box on a search page is a question about which one is real. The note is
`aria-live` because it is the only thing that says how many hits there were. -/
def searchHtml (title : String) : String :=
  plainPage "Search" title
    "<div class=\"modhead\"><h1>Search</h1><p class=\"lede\">Every declaration this package \
    documents, by name. Type in the box at the top of the page — a prefix of the last component \
    of a name is matched first, then a prefix of the whole name, then anything containing \
    it.</p></div><p class=\"results-note\" id=\"page-note\" aria-live=\"polite\"></p><ul \
    class=\"results\" id=\"page-results\"></ul><noscript><p class=\"results-note\">Search needs \
    JavaScript. The <a href=\"./index.html\">module index</a> lists every page.</p></noscript>"

/-- What `Type`, `Prop` and `Sort` mean, for the reader who clicked one in a
signature. Written here rather than copied from doc-gen4, whose page is another
project's prose under a different licence, and deliberately short: this is a
footnote reached from a signature, not a tutorial, and anything longer competes
with Lean's own documentation, which the last paragraph points at instead. -/
def foundationalTypesHtml (title : String) : String :=
  plainPage "Foundational types" title
    "<div class=\"modhead\"><h1>Foundational types</h1><p class=\"lede\">The sorts and the \
    function type are built into Lean rather than declared in a module, so they have no page of \
    their own to link to. This is that page.</p></div><div class=\"doc\"><h2><code>Sort \
    u</code></h2><p>The type of types, one level at a time. Every type in Lean belongs to some \
    <code>Sort u</code>, where the universe level <code>u</code> is a natural number or a \
    variable standing for one. A term of <code>Sort u</code> is itself a type, whose own terms \
    are the values.</p><p>The hierarchy is strict: <code>Sort u : Sort (u+1)</code>, and there \
    is no <code>Sort ∞</code>. That is what keeps the system consistent — a single type of all \
    types would contain itself.</p><h2><code>Prop</code></h2><p><code>Prop</code> is <code>Sort \
    0</code>, the sort of propositions. A term of a proposition is a proof of it, and \
    <code>Prop</code> is <em>proof-irrelevant</em>: any two proofs of the same proposition are \
    definitionally equal, so a proof can never be inspected to produce data. This is why \
    theorems can be erased at compile time and why they are shown apart from definitions in \
    this documentation.</p><h2><code>Type u</code></h2><p><code>Type u</code> abbreviates \
    <code>Sort (u+1)</code>, and <code>Type</code> on its own means <code>Type 0</code>. These \
    are the sorts data lives in: <code>Nat</code>, <code>List α</code> and every structure \
    declared in this package are terms of some <code>Type u</code>. Unlike <code>Prop</code>, \
    distinct terms of a type stay distinct.</p><h2>Dependent function types</h2><p><code>(x : \
    α) → β x</code> is the type of functions whose <em>result type may mention the \
    argument</em>. When <code>β</code> does not use <code>x</code> it is written <code>α → \
    β</code>, the ordinary function type. Binders in the signatures on these pages are the same \
    thing in another spelling: <code>∀ (x : α), β x</code> is the dependent function type when \
    the result is a proposition, and <code>{x : α}</code> or <code>[Inst α]</code> mark an \
    argument the elaborator is expected to supply.</p><p>For the rules behind any of this, see \
    Lean's own documentation — this page only names the things a signature on this site can \
    link to.</p></div>"

end Litedoc4
