/- A package's bibliography as the renderer and the whole-package step read it,
and the citations a docstring can make into it. -/
import Std.Data.HashMap
import Std.Data.HashSet
import Litedoc4.Bytes
import Litedoc4.Ir.Utf16

namespace Litedoc4

/-- doc-gen4's `BibItem`. `tag` and `plaintext` are text and are escaped where
they are written; `html` is markup that is already escaped. -/
structure BibItem where
  citekey : String
  tag : String
  html : String
  plaintext : String
  deriving Inhabited, BEq, Repr

structure Bibliography where
  /-- In the order `references.html` lists them. -/
  items : Array BibItem := #[]
  byKey : Std.HashMap String BibItem := {}
  /-- The SHA-256 of the file the items were read from, and `none` exactly when
  there was nothing to read. -/
  digest : Option String := none
  /-- What a reader of the file should be told about it, said by whoever reads
  it for a build rather than by `readBibliography`, which `watch` calls on every
  poll. -/
  warning : Option String := none
  deriving Inhabited

/-- A key given twice resolves to its **last** item, which is what doc-gen4's
`insertMany` into its `refsMap` leaves. -/
def Bibliography.of (items : Array BibItem) (digest : Option String) : Bibliography :=
  { items, digest, byKey := items.foldl (fun m item => m.insert item.citekey item) {} }

def referencesPage : String := "references.html"

def referenceAnchor (citekey : String) : String := "ref_" ++ citekey

def referenceHrefPrefix : String := referencesPage ++ "#" ++ referenceAnchor ""

def referenceHref (citekey : String) : String := referenceHrefPrefix ++ citekey

/-- doc-gen4's `BackrefItem` without what a page already knows: its module, and
its index, which is its position in the page's array of them. -/
structure Citation where
  citekey : String
  /-- The declaration or member whose docstring cites, and empty in a module
  docstring. -/
  funName : String
  deriving BEq, Repr, Inhabited

def backrefAnchor (index : Nat) : String := "_backref_" ++ toString index

/-- doc-gen4's `findBibitem?`: the item a link destination cites, if it is one. -/
def Bibliography.cited? (b : Bibliography) (href : String) : Option BibItem :=
  if href.startsWith referenceHrefPrefix then
    b.byKey.get? (byteSub href referenceHrefPrefix.utf8ByteSize href.utf8ByteSize)
  else none

/-- doc-gen4's `findAllReferences`: the contents of every `[…]` that is a key,
the search resuming at the `]` that closed it — so `[[Key]]` cites `[Key`, which
is no key. Sorted, where doc-gen4 returns a `HashSet` in whatever order it
iterates. -/
def citedKeys (b : Bibliography) (s : String) : Array String := Id.run do
  let n := s.utf8ByteSize
  let mut found : Std.HashSet String := {}
  let mut i := 0
  while i < n do
    if byteAt s i != 91 then
      i := i + 1
      continue
    let mut close := i + 1
    while close < n && byteAt s close != 93 do close := close + 1
    if close == n then break
    let key := byteSub s (i + 1) close
    if b.byKey.contains key then found := found.insert key
    i := close
  return sortUtf16 found.toArray

/-- doc-gen4's `refsMarkdown`: one link reference definition per cited key,
after a blank line that also ends whatever block the docstring stopped in. -/
def referenceDefinitions (keys : Array String) : String :=
  keys.foldl (fun acc key => acc ++ "[" ++ key ++ "]: " ++ referenceHref key ++ "\n") "\n\n"

end Litedoc4
