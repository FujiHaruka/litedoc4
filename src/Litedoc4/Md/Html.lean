/-
Derived from doc-gen4 (Apache-2.0, Copyright (c) 2021 Henrik Böving) by way of
`crates/litedoc4-md/src/html.rs`, and changed; see this repository's NOTICE
and `docs/provenance.md`.
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

@[inline] def isSep (c : UInt8) : Bool := c <= 32

/-- `autoLinkInline`. Two lookups per word: the word itself, then whatever
follows its last `.`, so that `Nat.succ` links `succ` when the qualified name is
unknown. -/
def autoLinkInline (out : String) (c : Renderer) (s : String) : String := Id.run do
  let n := s.utf8ByteSize
  let mut acc := out
  let mut i := 0
  while i < n do
    let a := i
    while i < n && isSep (byteAt s i) do i := i + 1
    if i > a then acc := escapeSub acc s a i
    let b := i
    while i < n && !isSep (byteAt s i) do i := i + 1
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

`crates/litedoc4-md/src/html.rs`, transcribed — which is itself
`DocGen4/Output/DocString.lean`, transcribed. The parser is `Md`, which runs
`vendor/md4c/md4c.c` — byte for byte the file the Rust side vendors — so what
differs between the two sides is the language the renderer is written in and
nothing about the dialect.

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
    if isPZC c then
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

/-- `math_into` in `crates/litedoc4-md/src/html.rs`. The MathML goes in as
markup — escaping it would print it — and a span the converter refuses falls
back to the dollars and the escaped source, which is what doc-gen4 emits for
every span, so such a page is no worse than a doc-gen4 page. Refusal is a
contract and not a rare branch: 6 of Mathlib's 2,113 spans take it. -/
def mdMath (out : String) (latex : String) (display : Bool) : String :=
  match MathML4Lean.toMathML latex (if display then .block else .inline) with
  | some mathml => out ++ mathml
  | none =>
    let d := if display then "$$" else "$"
    escapeInto (out ++ d) latex ++ d

mutual

partial def mdTexts (out : String) (c : Renderer) (ts : Array Md.Text)
    (inLink : Bool) : String :=
  ts.foldl (fun acc t => mdText acc c t inLink) out

partial def mdWrap (out : String) (c : Renderer) (tag : String)
    (ts : Array Md.Text) (inLink : Bool) : String :=
  mdTexts (out ++ "<" ++ tag ++ ">") c ts inLink ++ "</" ++ tag ++ ">"

/-- `renderText`. `inLink` suppresses auto-linking inside an `<a>`, which is what
stops the output from nesting anchors. -/
partial def mdText (out : String) (c : Renderer) (t : Md.Text)
    (inLink : Bool) : String :=
  match t with
  | .normal s => escapeInto out s
  | .nullchar => out ++ "�"
  | .br _ => out ++ "<br>\n"
  | .softbr _ => out ++ "\n"
  | .entity s => out ++ s
  | .em ts => mdWrap out c "em" ts inLink
  | .strong ts => mdWrap out c "strong" ts inLink
  | .u ts => mdWrap out c "u" ts inLink
  | .del ts => mdWrap out c "del" ts inLink
  | .a href title _ ts =>
    let ttl := attrToString title
    let acc := escapeInto (out ++ "<a href=\"") (extendLink c (attrToString href)) ++ "\""
    let acc := if ttl.isEmpty then acc else escapeInto (acc ++ " title=\"") ttl ++ "\""
    mdTexts (acc ++ ">") c ts true ++ "</a>"
  | .img src title alt =>
    let ttl := attrToString title
    let acc := escapeInto (out ++ "<img src=\"") (attrToString src) ++ "\" alt=\""
    let acc := escapeInto acc (alt.foldl textToPlain "") ++ "\""
    let acc := if ttl.isEmpty then acc else escapeInto (acc ++ " title=\"") ttl ++ "\""
    acc ++ ">"
  | .code ps =>
    let acc := out ++ "<code>"
    let acc := if inLink then ps.foldl (fun a p => escapeInto a p) acc
               else ps.foldl (fun a p => autoLinkInline a c p) acc
    acc ++ "</code>"
  | .latexMath ps => mdMath out (ps.foldl (· ++ ·) "") false
  | .latexMathDisplay ps => mdMath out (ps.foldl (· ++ ·) "") true
  | .wikiLink tgt ts =>
    let acc := escapeInto (out ++ "<x-wikilink data-target=\"") (attrToString tgt) ++ "\">"
    mdTexts acc c ts inLink ++ "</x-wikilink>"

partial def mdBlocks (out : String) (c : Renderer) (bs : Array Md.Block)
    (tight : Bool) : String :=
  bs.foldl (fun acc b => mdBlock acc c b tight) out

/-- `renderLi`. -/
partial def mdLi (out : String) (c : Renderer) (li : Md.Li Md.Block)
    (tight : Bool) : String :=
  let acc := out ++ "<li>"
  let acc := if li.isTask then
      acc ++ (if li.taskChar == some 'x' || li.taskChar == some 'X'
              then "<input type=\"checkbox\" checked=\"\" disabled=\"\">"
              else "<input type=\"checkbox\" disabled=\"\">")
    else acc
  mdBlocks acc c li.contents tight ++ "</li>"

/-- `renderBlock`. `tight` reaches only `.p`. -/
partial def mdBlock (out : String) (c : Renderer) (b : Md.Block)
    (tight : Bool) : String :=
  match b with
  | .p ts =>
    if tight then mdTexts out c ts false
    else mdTexts (out ++ "<p>") c ts false ++ "</p>"
  | .ul t _ items =>
    (items.foldl (fun a i => mdLi a c i t) (out ++ "<ul>")) ++ "</ul>"
  | .ol t start _ items =>
    let acc := if start == 1 then out ++ "<ol>"
               else out ++ "<ol start=\"" ++ toString start ++ "\">"
    (items.foldl (fun a i => mdLi a c i t) acc) ++ "</ol>"
  | .hr => out ++ "<hr>\n"
  | .header level ts =>
    let id := headingId ts
    let acc := escapeInto (out ++ "<h" ++ toString level ++ " id=\"") id
    let acc := mdTexts (acc ++ "\" class=\"markdown-heading\">") c ts false
    escapeInto (acc ++ " <a class=\"hover-link\" href=\"#") id
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
    acc ++ "</code></pre>"
  | .html content => content.foldl (· ++ ·) out
  | .blockquote bs => mdBlocks (out ++ "<blockquote>") c bs false ++ "</blockquote>"
  | .table head body =>
    let acc := head.foldl (fun a cell => mdTexts (a ++ "<th>") c cell false ++ "</th>")
      (out ++ "<table><thead><tr>")
    let acc := acc ++ "</tr></thead><tbody>"
    let acc := body.foldl (fun a row =>
      (row.foldl (fun a2 cell => mdTexts (a2 ++ "<td>") c cell false ++ "</td>")
        (a ++ "<tr>")) ++ "</tr>") acc
    acc ++ "</tbody></table>"

end

/-- `docStringToHtml`. The trailing `"\n\n"` is doc-gen4's `refsMarkdown` with an
empty bibliography, and it is not cosmetic — it terminates whatever block the
docstring ended in the middle of. -/
def docstring (out : String) (c : Renderer) (text : String) : String :=
  match Md.parse (text ++ "\n\n") docstringFlags with
  | some doc => mdBlocks out c doc.blocks false
  | none =>
    escapeInto (out ++ "<span style='color:red;'>Error: failed to parse markdown: </span>") text

end Litedoc4
