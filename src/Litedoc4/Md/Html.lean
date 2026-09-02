/-
Derived from doc-gen4 (Apache-2.0, Copyright (c) 2021 Henrik Böving) by way of
`git show rust-frozen:crates/litedoc4-md/src/html.rs` — in that tag, not in
this tree — and changed; see this repository's NOTICE and `docs/provenance.md`.
-/
import Litedoc4.Bytes
import Litedoc4.Md
import Litedoc4.Md.Escape
import Litedoc4.Md.Gc
import MathML4Lean

namespace Litedoc4

/-- `LinkResolver`. `nameToLink?` needs the union of the IR's module names, the
ledger's `known` and the `.lidx`'s `@` section, none of which belongs to a
Markdown renderer; the resolver is how that stays on the other side of the
boundary. `sourcePathToLink` takes the word without its `.lean`.

What would falsify the indirection: a Markdown renderer that emits no links at
all. -/
structure LinkResolver where
  nameToLink : String → Option String
  sourcePathToLink : String → Option String
  deriving Inhabited

/-- `NoLinks`: every name stays what the author wrote. -/
def noLinks : LinkResolver :=
  { nameToLink := fun _ => none, sourcePathToLink := fun _ => none }

/-- `root` is the relative path from the page being written back to the site
root (`"./"`, `"../"`, `"../.././"`, …). It is prepended to every relative link,
so it is part of the bytes. -/
structure Renderer where
  root : String
  links : LinkResolver
  deriving Inhabited

def resolveLink (c : Renderer) (s : String) : Option String :=
  if s.endsWith ".lean" && s.any (· == '/') then
    c.links.sourcePathToLink (byteSub s 0 (s.utf8ByteSize - 5))
  else c.links.nameToLink s

@[inline] def pushAnchor (out : String) (href text : String) : String :=
  escapeInto (escapeInto (out ++ "<a href=\"") href ++ "\">") text ++ "</a>"

/-- Where the run starting at byte `i` ends: separators while `sep` is true, the
words between them while it is false.

**Code points and not bytes.** `splitAround` splits on `Z | C`, which holds of
U+007F, U+00A0 and U+3000 among others; a byte test would leave `a<NBSP>b` one
word and neither name in it would be looked up, where doc-gen4 splits both out
and links them. What would falsify it: an `isZC` that agreed with `· ≤ 32`
everywhere, which is what its ASCII half looks like on its own. -/
def zcRunEnd (s : String) (n i : Nat) (sep : Bool) : Nat := Id.run do
  let mut j := i
  while j < n do
    let (cp, w) := cpAt s j
    if isZC cp != sep then return j
    j := j + w
  return n

/-- `autoLinkInline`. Two lookups per word: the word itself, then whatever
follows its last `.`, so that `Nat.succ` links `succ` when the qualified name is
unknown. -/
def autoLinkInline (out : String) (c : Renderer) (s : String) : String := Id.run do
  let n := s.utf8ByteSize
  let mut acc := out
  let mut i := 0
  while i < n do
    let a := i
    i := zcRunEnd s n i true
    if i > a then acc := escapeSub acc s a i
    let b := i
    i := zcRunEnd s n i false
    if i > b then
      let piece := byteSub s b i
      match resolveLink c piece with
      | some l => acc := pushAnchor acc l piece
      | none =>
        let pn := piece.utf8ByteSize
        let mut dot := pn
        let mut k := 0
        while k < pn do
          if byteAt piece k == 46 then dot := k
          k := k + 1
        let tail := if dot == pn then piece else byteSub piece (dot + 1) pn
        match resolveLink c tail with
        | some l =>
          if dot != pn then acc := escapeSub acc piece 0 (dot + 1)
          acc := pushAnchor acc l tail
        | none => acc := escapeSub acc piece 0 pn
  return acc

/-! ## Markdown

`DocGen4/Output/DocString.lean`, transcribed. The parser is `Md`, which runs
`vendor/md4c/md4c.c`, so the dialect a docstring is read in is md4c's.

Math is `MathML4Lean`; a span it refuses falls back to the dollars and the
escaped source, which is what doc-gen4 emits when its own LaTeX parser refuses
one. -/

open Md in
def docstringFlags : UInt32 :=
  MD_DIALECT_GITHUB ||| MD_FLAG_LATEXMATHSPANS ||| MD_FLAG_NOHTML

/-- `attrTextToString`: a link destination, title or info string flattened.
Entities stay as written. -/
def attrToString (a : Array Md.AttrText) : String :=
  a.foldl (fun acc x => match x with
    | .normal s => acc ++ s
    | .entity s => acc ++ s
    | .nullchar => acc ++ "�") ""

/-- `textToPlaintext`: an inline run with all formatting dropped. -/
partial def textToPlain (out : String) (t : Md.Text) : String :=
  match t with
  | .normal s => out ++ s
  | .entity s => out ++ s
  | .nullchar => out ++ "�"
  | .br _ => out ++ "\n"
  | .softbr _ => out ++ "\n"
  | .em ts => ts.foldl textToPlain out
  | .strong ts => ts.foldl textToPlain out
  | .u ts => ts.foldl textToPlain out
  | .del ts => ts.foldl textToPlain out
  | .a _ _ _ ts => ts.foldl textToPlain out
  | .wikiLink _ ts => ts.foldl textToPlain out
  | .img _ _ alt => alt.foldl textToPlain out
  | .code ps => ps.foldl (· ++ ·) out
  | .latexMath ps => ps.foldl (· ++ ·) out
  | .latexMathDisplay ps => ps.foldl (· ++ ·) out

/-- `mdGetHeadingId`: the plain text with every run of `P | Z | C` replaced by
one `-`, the empty pieces dropped first so there is no leading or trailing one.
Cases are preserved. -/
def headingId (texts : Array Md.Text) : String := Id.run do
  let plain := texts.foldl textToPlain ""
  let mut out := ""
  let mut piece := ""
  let mut first := true
  for c in plain.toList do
    if isPZC c.val then
      if !piece.isEmpty then
        if first then first := false else out := out.push '-'
        out := out ++ piece
        piece := ""
    else
      piece := piece.push c
  if !piece.isEmpty then
    if !first then out := out.push '-'
    out := out ++ piece
  return out

/-- `extendLink`. The `http` test is `startsWith "http"`, not a scheme check. -/
def extendLink (c : Renderer) (s : String) : String :=
  if s.startsWith "##" then
    let name := byteSub s 2 s.utf8ByteSize
    match resolveLink c name with
    | some l => l
    | none => c.root ++ "find/?pattern=" ++ name ++ "#doc"
  else if s.startsWith "#" || s.startsWith "http" then s
  else c.root ++ s

/-- The MathML goes in as markup — escaping it would print it — and a span the
converter refuses falls back to the dollars and the escaped source, which is
what doc-gen4 emits for every span, so such a page is no worse than a doc-gen4
page. Refusal is a contract and not a rare branch: 6 of Mathlib's 2,113 spans
take it.

The state counts the spans that took the fallback. It is threaded through the
renderer rather than recounted afterwards because a second walk over the parsed
document would answer the same question along a second path: a span one walk
reaches and the other does not is a wrong count on a right page. What would
falsify that: a span whose fallback is decidable without rendering it. -/
def mdMath (out : String) (latex : String) (display : Bool) : StateM Nat String :=
  match MathML4Lean.toMathML latex (if display then .block else .inline) with
  | some mathml => pure (out ++ mathml)
  | none => do
    modify (· + 1)
    let d := if display then "$$" else "$"
    return escapeInto (out ++ d) latex ++ d

mutual

partial def mdTexts (out : String) (c : Renderer) (ts : Array Md.Text)
    (inLink : Bool) : StateM Nat String :=
  ts.foldlM (fun acc t => mdText acc c t inLink) out

partial def mdWrap (out : String) (c : Renderer) (tag : String)
    (ts : Array Md.Text) (inLink : Bool) : StateM Nat String := do
  let acc ← mdTexts (out ++ "<" ++ tag ++ ">") c ts inLink
  return acc ++ "</" ++ tag ++ ">"

/-- `renderText`. `inLink` suppresses auto-linking inside an `<a>`, which is what
stops the output from nesting anchors. -/
partial def mdText (out : String) (c : Renderer) (t : Md.Text)
    (inLink : Bool) : StateM Nat String :=
  match t with
  | .normal s => pure (escapeInto out s)
  | .nullchar => pure (out ++ "�")
  | .br _ => pure (out ++ "<br>\n")
  | .softbr _ => pure (out ++ "\n")
  | .entity s => pure (out ++ s)
  | .em ts => mdWrap out c "em" ts inLink
  | .strong ts => mdWrap out c "strong" ts inLink
  | .u ts => mdWrap out c "u" ts inLink
  | .del ts => mdWrap out c "del" ts inLink
  | .a href title _ ts => do
    let ttl := attrToString title
    let acc := escapeInto (out ++ "<a href=\"") (extendLink c (attrToString href)) ++ "\""
    let acc := if ttl.isEmpty then acc else escapeInto (acc ++ " title=\"") ttl ++ "\""
    let acc ← mdTexts (acc ++ ">") c ts true
    return acc ++ "</a>"
  | .img src title alt =>
    let ttl := attrToString title
    let acc := escapeInto (out ++ "<img src=\"") (attrToString src) ++ "\" alt=\""
    let acc := escapeInto acc (alt.foldl textToPlain "") ++ "\""
    let acc := if ttl.isEmpty then acc else escapeInto (acc ++ " title=\"") ttl ++ "\""
    pure (acc ++ ">")
  | .code ps =>
    let acc := out ++ "<code>"
    let acc := if inLink then ps.foldl (fun a p => escapeInto a p) acc
               else ps.foldl (fun a p => autoLinkInline a c p) acc
    pure (acc ++ "</code>")
  | .latexMath ps => mdMath out (ps.foldl (· ++ ·) "") false
  | .latexMathDisplay ps => mdMath out (ps.foldl (· ++ ·) "") true
  | .wikiLink tgt ts => do
    let acc := escapeInto (out ++ "<x-wikilink data-target=\"") (attrToString tgt) ++ "\">"
    let acc ← mdTexts acc c ts inLink
    return acc ++ "</x-wikilink>"

partial def mdBlocks (out : String) (c : Renderer) (bs : Array Md.Block)
    (tight : Bool) : StateM Nat String :=
  bs.foldlM (fun acc b => mdBlock acc c b tight) out

/-- `renderLi`. -/
partial def mdLi (out : String) (c : Renderer) (li : Md.Li Md.Block)
    (tight : Bool) : StateM Nat String := do
  let acc := out ++ "<li>"
  let acc := if li.isTask then
      acc ++ (if li.taskChar == some 'x' || li.taskChar == some 'X'
              then "<input type=\"checkbox\" checked=\"\" disabled=\"\">"
              else "<input type=\"checkbox\" disabled=\"\">")
    else acc
  let acc ← mdBlocks acc c li.contents tight
  return acc ++ "</li>"

/-- `renderBlock`. `tight` reaches only `.p`. -/
partial def mdBlock (out : String) (c : Renderer) (b : Md.Block)
    (tight : Bool) : StateM Nat String :=
  match b with
  | .p ts =>
    if tight then mdTexts out c ts false
    else do
      let acc ← mdTexts (out ++ "<p>") c ts false
      return acc ++ "</p>"
  | .ul t _ items => do
    let acc ← items.foldlM (fun a i => mdLi a c i t) (out ++ "<ul>")
    return acc ++ "</ul>"
  | .ol t start _ items => do
    let acc := if start == 1 then out ++ "<ol>"
               else out ++ "<ol start=\"" ++ toString start ++ "\">"
    let acc ← items.foldlM (fun a i => mdLi a c i t) acc
    return acc ++ "</ol>"
  | .hr => pure (out ++ "<hr>\n")
  | .header level ts => do
    let id := headingId ts
    let acc := escapeInto (out ++ "<h" ++ toString level ++ " id=\"") id
    let acc ← mdTexts (acc ++ "\" class=\"markdown-heading\">") c ts false
    return escapeInto (acc ++ " <a class=\"hover-link\" href=\"#") id
      ++ "\">#</a></h" ++ toString level ++ ">"
  | .code _ lang _ content =>
    let l := attrToString lang
    let acc := out ++ "<pre><code"
    let acc := if l.isEmpty then acc
               else escapeInto (acc ++ " class=\"language-") l ++ "\""
    let acc := acc ++ ">"
    let acc := if l.isEmpty || l == "lean"
               then content.foldl (fun a p => autoLinkInline a c p) acc
               else content.foldl (fun a p => escapeInto a p) acc
    pure (acc ++ "</code></pre>")
  | .html content => pure (content.foldl (· ++ ·) out)
  | .blockquote bs => do
    let acc ← mdBlocks (out ++ "<blockquote>") c bs false
    return acc ++ "</blockquote>"
  | .table head body => do
    let acc ← head.foldlM (fun a cell => do
      let a ← mdTexts (a ++ "<th>") c cell false
      return a ++ "</th>") (out ++ "<table><thead><tr>")
    let acc := acc ++ "</tr></thead><tbody>"
    let acc ← body.foldlM (fun a row => do
      let a ← row.foldlM (fun a2 cell => do
        let a2 ← mdTexts (a2 ++ "<td>") c cell false
        return a2 ++ "</td>") (a ++ "<tr>")
      return a ++ "</tr>") acc
    return acc ++ "</tbody></table>"

end

/-- `docStringToHtml`. The trailing `"\n\n"` is doc-gen4's `refsMarkdown` with an
empty bibliography, and it is not cosmetic — it terminates whatever block the
docstring ended in the middle of. -/
def docstring (out : String) (c : Renderer) (text : String) : StateM Nat String :=
  match Md.parse (text ++ "\n\n") docstringFlags with
  | some doc => mdBlocks out c doc.blocks false
  | none =>
    pure (escapeInto
      (out ++ "<span style='color:red;'>Error: failed to parse markdown: </span>") text)

/-- `Renderer::inline`: a run of Markdown rendered without the block element it
arrived in — a heading's own text, put somewhere that is not a heading.

Not `docstring` with the `<p>` trimmed back off: nothing downstream can tell that
wrapper from a `<p>` the author wrote, and the input is only one paragraph when
it parses as one. Anything else is escaped, so a caller that hands this a list or
a table gets the author's characters rather than markup it did not ask for. What
would falsify this: a caller that owns the whole element it puts the result in. -/
def inlineMd (out : String) (c : Renderer) (text : String) : StateM Nat String :=
  match Md.parse (text ++ "\n\n") docstringFlags with
  | some doc =>
    match doc.blocks.toList with
    | [.p texts] => mdTexts out c texts false
    | _ => pure (escapeInto out text)
  | none => pure (escapeInto out text)

end Litedoc4
