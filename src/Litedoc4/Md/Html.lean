/-
Derived from doc-gen4 (Apache-2.0, Copyright (c) 2021 Henrik Böving) by way of
`git show rust-frozen:crates/litedoc4-md/src/html.rs` — in that tag, not in
this tree — and changed; see this repository's NOTICE and `docs/provenance.md`.
-/
import Litedoc4.Bib
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
  isSiteFile : String → Bool := fun _ => true
  deriving Inhabited

/-- `NoLinks`: every name stays what the author wrote, and every file a link
names is taken to be there. -/
def noLinks : LinkResolver :=
  { nameToLink := fun _ => none, sourcePathToLink := fun _ => none }

/-- Whose docstring is being rendered. A member has no position of its own, so
its line is the declaration's that holds it. -/
inductive DocOwner where
  | module
  | decl (name : String)
  | member (kind name owner : String)
  deriving Inhabited, BEq, Repr

structure DocSite where
  line : Nat := 0
  owner : DocOwner := .module
  deriving Inhabited, BEq, Repr

/-- The declaration or member whose docstring it is, and empty in a module
docstring — the spelling a `Citation` carries. -/
def DocSite.funName (s : DocSite) : String :=
  match s.owner with
  | .module => ""
  | .decl name => name
  | .member _ name _ => name

/-- Where the links a docstring writes point. -/
inductive Hrefs where
  /-- `root` is the relative path from the page being written back to the site
  root (`"./"`, `"../"`, `"../.././"`, …). It is prepended to every relative link,
  so it is part of the bytes. -/
  | relative (root : String) (links : LinkResolver)
  /-- Nothing resolved and no root: every place `relative` would prefix the root
  or ask the resolver carries what `markWord` describes instead. -/
  | deferred
  deriving Inhabited

structure Renderer where
  hrefs : Hrefs
  bib : Bibliography
  site : DocSite := {}
  deriving Inhabited

/-- `resolveLink`'s one dispatch: a word that ends in `.lean` and contains a `/`
is a source path, handed over without its `.lean`, and anything else a name. -/
@[inline] def resolveWith (sourcePath name : String → Option α) (s : String) : Option α :=
  if s.endsWith ".lean" && s.any (· == '/') then sourcePath (byteSub s 0 (s.utf8ByteSize - 5))
  else name s

def LinkResolver.resolve (l : LinkResolver) (s : String) : Option String :=
  resolveWith l.sourcePathToLink l.nameToLink s

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

/-- Where the tail of a word starts: one past its last `.`, or 0 when it has none. -/
def tailStart (piece : String) : Nat := Id.run do
  let mut start := 0
  for k in [0:piece.utf8ByteSize] do
    if byteAt piece k == 46 then start := k + 1
  return start

/-- `autoLinkInline`'s split: the separators between the words and the words. -/
@[inline] def foldWords (s : String) (init : α) (gap : α → Nat → Nat → α)
    (word : α → String → α) : α := Id.run do
  let n := s.utf8ByteSize
  let mut acc := init
  let mut i := 0
  while i < n do
    let a := i
    i := zcRunEnd s n i true
    if i > a then acc := gap acc a i
    let b := i
    i := zcRunEnd s n i false
    if i > b then acc := word acc (byteSub s b i)
  return acc

/-- `autoLinkInline`. Two lookups per word: the word itself, then whatever
follows its last `.`, so that `Nat.succ` links `succ` when the qualified name is
unknown. -/
def autoLinkInline (out : String) (links : LinkResolver) (s : String) : String :=
  foldWords s out (fun acc a i => escapeSub acc s a i) fun acc piece =>
    match links.resolve piece with
    | some l => pushAnchor acc l piece
    | none =>
      let start := tailStart piece
      let pn := piece.utf8ByteSize
      match links.resolve (byteSub piece start pn) with
      | some l => pushAnchor (escapeSub acc piece 0 start) l (byteSub piece start pn)
      | none => escapeSub acc piece 0 pn

/-- **Deferred content: the marker, and the one rule that makes links of it.**

Content rendered with `Hrefs.deferred` holds no site root and no resolved URL.
Where `Hrefs.relative` would have written either, it holds one of three shapes,
and the browser turns each into an href by this rule, against the page's own
`"words"` table and the site root of the URL mode it is serving:

- `<w>word</w>`, around every word `autoLinkInline` would try. The key is the
  element's text. If `"words"` holds the word, the whole word links to its
  target. Otherwise, if the word has a `.`, the tail after its last `.` is looked
  up, and if `"words"` holds it only the tail links: the part up to and including
  that `.` stays text. Otherwise the word stays text.
- `href="##name"`, the destination as the author wrote it: `"words"` holds
  `name` (no tail is tried) → its target; otherwise the site root followed by
  `find/?pattern=name#doc`.
- any other `href` is the destination as the author wrote it. One that starts
  with `#` is a fragment of this page and one that starts with `http` is left as
  it is (a prefix test, not a scheme check); every other one is relative to the
  site root.

`"words"` holds only the strings that resolve in that version, so a missing key
is the answer "no link", never a lookup still to be made. -/
def markWord (out piece : String) : String := escapeInto (out ++ "<w>") piece ++ "</w>"

/-- `markWord` over every word of `s`, and the strings the browser will look
up for them: each word, and its tail when it has a `.`. -/
def markWords (acc : String × Array String) (s : String) : String × Array String :=
  foldWords s acc (fun (out, words) a i => (escapeSub out s a i, words))
    fun (out, words) piece =>
      let start := tailStart piece
      let words := words.push piece
      (markWord out piece,
        if start == 0 then words else words.push (byteSub piece start piece.utf8ByteSize))

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
def extendLink (root : String) (links : LinkResolver) (s : String) : String :=
  if s.startsWith "##" then
    let name := byteSub s 2 s.utf8ByteSize
    match links.resolve name with
    | some l => l
    | none => root ++ "find/?pattern=" ++ name ++ "#doc"
  else if s.startsWith "#" || s.startsWith "http" then s
  else root ++ s

/-- What a link destination names among the files of the site being built.
A destination that starts with `http` is `notAFile` by its spelling, the one
`extendLink` tests, and not by a scheme check. -/
inductive LinkTarget where
  | notAFile
  | aboveRoot
  | file (path : String)
  deriving BEq, Repr

def hasScheme (s : String) : Bool := Id.run do
  let n := s.utf8ByteSize
  if n == 0 then return false
  let isAlpha (b : UInt8) := (b ≥ 65 && b ≤ 90) || (b ≥ 97 && b ≤ 122)
  if !isAlpha (byteAt s 0) then return false
  let mut i := 1
  while i < n do
    let b := byteAt s i
    if b == 58 then return true
    if !(isAlpha b || (b ≥ 48 && b ≤ 57) || b == 43 || b == 45 || b == 46) then return false
    i := i + 1
  return false

/-- The site-relative path `root ++ dest` reaches: the query and fragment cut
off, `.` and `..` taken the way a browser takes them, and a directory read as
its `index.html`, which is what a static host serves for one. -/
def linkTarget (dest : String) : LinkTarget := Id.run do
  if dest.startsWith "#" || dest.startsWith "http" || hasScheme dest then return .notAFile
  let n := dest.utf8ByteSize
  let mut cut := n
  let mut i := 0
  while i < n do
    let b := byteAt dest i
    if b == 63 || b == 35 then
      cut := i
      break
    i := i + 1
  let segments := (byteSub dest 0 cut).splitOn "/"
  let mut kept : Array String := #[]
  for seg in segments do
    if seg == "." then continue
    if seg == ".." then
      if kept.isEmpty then return .aboveRoot
      kept := kept.pop
    else kept := kept.push seg
  let last := segments.getLastD ""
  if last.isEmpty || last == "." || last == ".." then
    kept := (if last.isEmpty then kept.pop else kept).push "index.html"
  return .file ("/".intercalate kept.toList)

def isDeadLink (isSiteFile : String → Bool) (dest : String) : Bool :=
  match linkTarget dest with
  | .notAFile => false
  | .aboveRoot => true
  | .file path => !isSiteFile path

structure DeadLink where
  dest : String
  site : DocSite
  isBibliographyKey : Bool
  deriving Inhabited, BEq, Repr

/-- What a walk over one page's docstrings carries from one to the next.

`mathFallbacks` counts the spans that fell back to their source. It is threaded
through the renderer rather than recounted afterwards because a second walk over
the parsed document would answer the same question along a second path: a span
one walk reaches and the other does not is a wrong count on a right page. What
would falsify that: a span whose fallback is decidable without rendering it.

`cited` is threaded for the same reason: a citation anchor's `id` is its position
among the page's citations, and the list a page is checked against is read off
this same walk. -/
structure MdState where
  mathFallbacks : Nat := 0
  cited : Array String := #[]
  deadLinks : Array DeadLink := #[]
  /-- What a deferred walk leaves the browser to look up (`markWord`). -/
  words : Array String := #[]
  deriving Inhabited

/-- The MathML goes in as markup — escaping it would print it — and a span the
converter refuses falls back to the dollars and the escaped source, which is
what doc-gen4 emits for every span, so such a page is no worse than a doc-gen4
page. Refusal is a contract and not a rare branch: 6 of Mathlib's 2,113 spans
take it. -/
def mdMath (out : String) (latex : String) (display : Bool) : StateM MdState String :=
  match MathML4Lean.toMathML latex (if display then .block else .inline) with
  | some mathml => pure (out ++ mathml)
  | none => do
    modify fun s => { s with mathFallbacks := s.mathFallbacks + 1 }
    let d := if display then "$$" else "$"
    return escapeInto (out ++ d) latex ++ d

/-- Where a link destination points, and what the walk records about it: a
dead link under `relative`, the name of a `##name` under `deferred`. -/
def destination (c : Renderer) (target : String) : StateM MdState String :=
  match c.hrefs with
  | .relative root links => do
    if isDeadLink links.isSiteFile target then
      let dead := { dest := target, site := c.site,
                    isBibliographyKey := c.bib.byKey.contains target }
      modify fun s => { s with deadLinks := s.deadLinks.push dead }
    return extendLink root links target
  | .deferred => do
    if target.startsWith "##" then
      modify fun s => { s with words := s.words.push (byteSub target 2 target.utf8ByteSize) }
    return target

def autoLinkAll (out : String) (c : Renderer) (ps : Array String) : StateM MdState String :=
  match c.hrefs with
  | .relative _ links => pure (ps.foldl (fun a p => autoLinkInline a links p) out)
  | .deferred => modifyGet fun s =>
    let (html, words) := ps.foldl markWords (out, s.words)
    (html, { s with words })

mutual

partial def mdTexts (out : String) (c : Renderer) (ts : Array Md.Text)
    (inLink : Bool) : StateM MdState String :=
  ts.foldlM (fun acc t => mdText acc c t inLink) out

partial def mdWrap (out : String) (c : Renderer) (tag : String)
    (ts : Array Md.Text) (inLink : Bool) : StateM MdState String := do
  let acc ← mdTexts (out ++ "<" ++ tag ++ ">") c ts inLink
  return acc ++ "</" ++ tag ++ ">"

/-- `renderText`. `inLink` suppresses auto-linking inside an `<a>`, which is what
stops the output from nesting anchors. -/
partial def mdText (out : String) (c : Renderer) (t : Md.Text)
    (inLink : Bool) : StateM MdState String :=
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
    let target := attrToString href
    let acc := escapeInto (out ++ "<a href=\"") (← destination c target) ++ "\""
    match c.bib.cited? target with
    | some item =>
      let index ← modifyGet fun s => (s.cited.size, { s with cited := s.cited.push item.citekey })
      let acc := escapeInto (acc ++ " title=\"") item.plaintext ++ "\" id=\""
      let acc := acc ++ backrefAnchor index ++ "\">"
      let acc ← match ts with
        | #[.normal s] => if s == item.citekey then pure (escapeInto acc item.tag)
                          else mdTexts acc c ts true
        | _ => mdTexts acc c ts true
      return acc ++ "</a>"
    | none =>
      let ttl := attrToString title
      let acc := if ttl.isEmpty then acc else escapeInto (acc ++ " title=\"") ttl ++ "\""
      let acc ← mdTexts (acc ++ ">") c ts true
      return acc ++ "</a>"
  | .img src title alt =>
    let ttl := attrToString title
    let acc := escapeInto (out ++ "<img src=\"") (attrToString src) ++ "\" alt=\""
    let acc := escapeInto acc (alt.foldl textToPlain "") ++ "\""
    let acc := if ttl.isEmpty then acc else escapeInto (acc ++ " title=\"") ttl ++ "\""
    pure (acc ++ ">")
  | .code ps => do
    let acc := out ++ "<code>"
    let acc ← if inLink then pure (ps.foldl (fun a p => escapeInto a p) acc)
               else autoLinkAll acc c ps
    return acc ++ "</code>"
  | .latexMath ps => mdMath out (ps.foldl (· ++ ·) "") false
  | .latexMathDisplay ps => mdMath out (ps.foldl (· ++ ·) "") true
  | .wikiLink tgt ts => do
    let acc := escapeInto (out ++ "<x-wikilink data-target=\"") (attrToString tgt) ++ "\">"
    let acc ← mdTexts acc c ts inLink
    return acc ++ "</x-wikilink>"

partial def mdBlocks (out : String) (c : Renderer) (bs : Array Md.Block)
    (tight : Bool) : StateM MdState String :=
  bs.foldlM (fun acc b => mdBlock acc c b tight) out

/-- `renderLi`. -/
partial def mdLi (out : String) (c : Renderer) (li : Md.Li Md.Block)
    (tight : Bool) : StateM MdState String := do
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
    (tight : Bool) : StateM MdState String :=
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
  | .code _ lang _ content => do
    let l := attrToString lang
    let acc := out ++ "<pre><code"
    let acc := if l.isEmpty then acc
               else escapeInto (acc ++ " class=\"language-") l ++ "\""
    let acc := acc ++ ">"
    let acc ← if l.isEmpty || l == "lean" then autoLinkAll acc c content
               else pure (content.foldl (fun a p => escapeInto a p) acc)
    return acc ++ "</code></pre>"
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

/-- `docStringToHtml`. -/
def docstring (out : String) (c : Renderer) (text : String) : StateM MdState String :=
  match Md.parse (text ++ referenceDefinitions (citedKeys c.bib text)) docstringFlags with
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
def inlineMd (out : String) (c : Renderer) (text : String) : StateM MdState String :=
  match Md.parse (text ++ referenceDefinitions (citedKeys c.bib text)) docstringFlags with
  | some doc =>
    match doc.blocks.toList with
    | [.p texts] => mdTexts out c texts false
    | _ => pure (escapeInto out text)
  | none => pure (escapeInto out text)

end Litedoc4
