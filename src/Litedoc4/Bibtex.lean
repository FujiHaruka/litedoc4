/-
Derived from doc-gen4 (Apache-2.0, Copyright (c) 2021 Henrik Böving) — its
`DocGen4/Output/Bibtex.lean` at 84a46571f3 — and changed; see this repository's
NOTICE and `docs/provenance.md`.
-/
import BibtexQuery.Parser
import BibtexQuery.Format
import Litedoc4.Bib
import Litedoc4.Md.Escape

open BibtexQuery BibtexQuery.Xml

namespace Litedoc4

mutual

partial def bibElementHtml : Element → String
  | .Element n a c =>
    let attrs := a.foldl (init := "") fun acc k v => escapeInto (acc ++ s!" {k}=\"") v ++ "\""
    c.foldl (fun acc x => bibContentHtml acc x) s!"<{n}{attrs}>" ++ s!"</{n}>"

partial def bibContentHtml (out : String) : Content → String
  | .Element e => out ++ bibElementHtml e
  | .Comment c => out ++ s!"<!--{c}-->"
  | .Character c => escapeInto out c

end

partial def bibContentPlain (out : String) : Content → String
  | .Element (.Element _ _ c) => c.foldl bibContentPlain out
  | .Comment _ => out
  | .Character c => out ++ c

/-- Where BibtexQuery stopped reading: the line of the first `@` at or after
byte `start`, and how many `@` there are from it on. -/
structure Unread where
  line : Nat
  ats : Nat
  deriving BEq, Repr

def unreadFrom (contents : String) (start : Nat) : Option Unread := Id.run do
  let mut line := 1
  let mut found : Option Unread := none
  for i in [0:contents.utf8ByteSize] do
    let b := byteAt contents i
    if i ≥ start && b == 64 then
      found := match found with
        | none => some { line, ats := 1 }
        | some u => some { u with ats := u.ats + 1 }
    if b == 10 then line := line + 1
  return found

structure BibRead where
  items : Array BibItem
  unread : Option Unread
  deriving BEq, Repr

/-- doc-gen4's `Bibtex.process'`: entries that are not of a normal type are
dropped, the rest sorted and their tags made distinct by BibtexQuery, so the tag
and the formatted entry are the ones a doc-gen4 site shows.

**Changed: where it stopped is reported.** BibtexQuery's file parser stops at
the first entry it cannot read — `@string`, `@comment`, `@preamble`, a stray `@`
in a note — and succeeds with the ones before it. Those are kept, as doc-gen4
keeps them, and `unread` says where the rest were left out, so the caller can
say so instead of a bibliography whose later citations stop linking in silence. -/
def processBibtex (contents : String) : Except String BibRead := do
  match BibtexQuery.Parser.bibtexFile ⟨contents, contents.startPos⟩ with
  | .success rest entries =>
    let processed ← entries.toArray.filterMapM ProcessedEntry.ofEntry
    let items := (deduplicateTag (sortEntry processed)).map fun x =>
      let html := Formatter.format x
      { citekey := x.name, tag := x.tag
        html := html.foldl bibContentHtml ""
        plaintext := html.foldl bibContentPlain "" }
    return { items, unread := unreadFrom contents rest.2.offset.byteIdx }
  | .error it err => throw s!"failed to parse bib file at pos {it.2.offset}: {err}"

end Litedoc4
