/- The docstrings a module page shows, in the order it shows them, and the
citations they make. Asked for a page's items, and by the whole-package step,
which lists the citations on the references page and cannot read their numbers
off pages it never sees. -/
import Std.Data.HashSet
import Litedoc4.Ir
import Litedoc4.Md.Html

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

/-! ## Citations -/

/-- `owner` is the top-level declaration whose section the docstring is in — the
structure for a field's — and empty for a module docstring: suppressing that
declaration takes the docstring off the page. -/
structure PageCitation where
  owner : String
  citation : Citation
  deriving BEq, Repr, Inhabited

/-- What a declaration shows a docstring for: its own, then its direct fields or
its constructors. -/
def declDocs (d : Decl) : Array (String × String) := Id.run do
  let mut docs := #[(d.name, d.doc)]
  if d.kind == "structure" || d.kind == "class" then
    for f in d.members do
      if f.label == "field" && !f.inherited then docs := docs.push (f.name, f.doc)
  else if d.kind == "inductive" || d.kind == "class_inductive" then
    for ctor in d.members do
      if ctor.label == "ctor" then docs := docs.push (ctor.name, ctor.doc)
  return docs

/-- The citation anchors the renderer's own walk writes for one docstring.

**That walk and not a second one over the parsed document**, so which links are
citations and in what order cannot be answered twice. Only a docstring that
names a key or the references page is parsed — none is in a package with no
bibliography. -/
def citationsIn (bib : Bibliography) (funName text : String) : Array Citation :=
  if (citedKeys bib text).isEmpty && (text.splitOn referencesPage).length == 1 then #[]
  else
    let walk := docstring "" { hrefs := .relative "" noLinks, bib } text
    (walk.run {}).2.cited.map ({ citekey := ·, funName })

/-- **The one answer to which citation anchors a page carries and in what
order**: the renderer checks the anchors it writes against it, and
`references.html` links to them through it. -/
def pageCitations (bib : Bibliography) (m : Module) (sup : Std.HashSet String) :
    Array PageCitation := Id.run do
  if bib.items.isEmpty then return #[]
  let mut out : Array PageCitation := #[]
  for it in pageItems m sup do
    let (owner, docs) :=
      if it.isDoc then ("", #[("", m.moduleDocs[it.idx]!.text)])
      else let d := m.decls[it.idx]!; (d.name, declDocs d)
    for (funName, text) in docs do
      for citation in citationsIn bib funName text do
        out := out.push { owner, citation }
  return out

/-- `pageCitations` under a wider suppressed set, for a caller that learns part
of the set after the module's citations were taken. -/
def dropSuppressed (cs : Array PageCitation) (sup : Std.HashSet String) :
    Array PageCitation :=
  cs.filter (!sup.contains ·.owner)

/-- The members of `m`'s declarations that are not `m`'s declarations — the part
of the site-wide suppressed set another module can contribute to this one's
pages, and normally empty. Sorted, so the bytes it is cached as do not depend on
hash order. -/
def foreignMembers (m : Module) : Array String := Id.run do
  let own : Std.HashSet String := m.decls.foldl (fun s d => s.insert d.name) {}
  let mut out : Array String := #[]
  for name in suppressedOf #[m] do
    if !own.contains name then out := out.push name
  return sortUtf16 out

end Litedoc4
