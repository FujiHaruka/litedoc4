/- What the pages a reader arrives at rather than navigates to say: the search
page, the page every `Sort` / `Type` / `Prop` span in a signature links to, a
module's one-line summary in the module list, and the citation backlinks the
references page lists. The page around them is the page script's. -/
import Litedoc4.Render.Code

namespace Litedoc4

def entryRoot : String := "./"

structure ModuleRow where
  name : String := ""
  page : String := ""
  /-- The module docstring's opening heading, as Markdown source. `none` draws no
  element, where an empty one would be a placeholder a reader cannot tell from a
  module that described itself with a blank line. -/
  summary : Option String := none
  deriving Inhabited

def grouped (n : Nat) : String := Id.run do
  let digits := (toString n).toList
  let mut out := ""
  let mut i := 0
  for c in digits do
    if i > 0 && (digits.length - i) % 3 == 0 then out := out.push ','
    out := out.push c
    i := i + 1
  return out

/-- `NoLinks` and no bibliography, so a declaration name or a citation in a
heading stays text: the row already has one destination, and hundreds of rows of
prose each carrying their own would be a list nobody can scan. The same holds for the configured intro,
where the answer to "does this name have a page" needs a map this stage does not
have — a code span that stays a code span is right, a link to a page nobody wrote
is not. -/
def entryRenderer : Renderer := { hrefs := .relative entryRoot noLinks, bib := {} }

/-- The math spans that fell back here are **not** added to the run's count: the
same span is rendered again on the module's own page, where it is already
counted, and the number means "spans in this package the converter could not
read", not "renderings that fell back". -/
def summaryHtml (out : String) (summary : String) : String :=
  (Id.run ((inlineMd out entryRenderer summary).run {})).1

/-- **There is no input field here.** The page script reads the top bar's
`#search-input`, seeds it from `?q=` and renders into `#page-results`; a second
box on a search page is a question about which one is real. The note is
`aria-live` because it is the only thing that says how many hits there were. -/
def searchBody : String :=
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
def foundationalTypesBody : String :=
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

/-- doc-gen4's `BackrefItem`: the `index`-th citation anchor on `module`'s page. -/
structure Backref where
  module : String
  index : Nat
  citation : Citation
  deriving BEq, Repr, Inhabited

/-- doc-gen4's `references`: written whether or not the package has a
bibliography, as doc-gen4 writes it, so an empty one is a page with an empty
list. An entry's back-references are listed in the order `backrefs` holds them. -/
def backrefsByKey (backrefs : Array Backref) : Std.HashMap String (Array Backref) :=
  backrefs.foldl (init := {}) fun m b =>
    m.insert b.citation.citekey ((m.getD b.citation.citekey #[]).push b)

end Litedoc4
