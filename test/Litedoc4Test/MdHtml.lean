/- doc-gen4's `DocGen4/Output/DocString.lean`, transcribed twice.

Split by what can answer them. Everything reached from a `Md.Text` or a
`Md.Block` already in hand is closed and is a `#guard`; everything that has to
ask md4c what the Markdown *is* runs, because `#guard` evaluates in the
interpreter and `Md.events` is `@[extern]` C linked only into the executable.
The barrier is the call and not the import, which is why the guards below
elaborate in a module that imports `Litedoc4.Md.Html`. -/
import Litedoc4.Md.Html
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4

/-- A resolver that answers for four bare words. `Nat` and `succ` are both in it
so that the two lookups a word gets can be told apart: if the split ever took
`.` as a separator, `Nat` would become a link of its own. -/
def linkWords : LinkResolver :=
  { nameToLink := fun n =>
      if n == "a" || n == "b" || n == "Nat" || n == "succ"
      then some ("../" ++ n ++ ".html") else none,
    sourcePathToLink := fun _ => none }

def wordCtx : Renderer := { root := "../", links := linkWords }

def render (md : String) : String :=
  (docstring "" { root := "../", links := noLinks } md).run' 0

def inline (md : String) : String :=
  (inlineMd "" { root := "../", links := noLinks } md).run' 0

def linked (s : String) : String := autoLinkInline "" wordCtx s

def textOf (t : Md.Text) (inLink : Bool) : String := (mdText "" wordCtx t inLink).run' 0

def blockOf (b : Md.Block) : String := (mdBlock "" wordCtx b false).run' 0

/-- `splitAround` keeps every separator as a piece of its own, so the words
written back out reassemble the input exactly, and what it splits on is Unicode
`Z | C` rather than the ASCII blank. U+00A0, U+007F and U+3000 are the three
that decide it: under a byte test each of them sits *inside* the word, and
neither name around it is ever looked up. -/
def aCodeSpanSplitsOnUnicodeZCAndWritesEverySeparatorBackOut : Bool :=
  linked "a b" == "<a href=\"../a.html\">a</a> <a href=\"../b.html\">b</a>"
    && linked "a\u00A0b" == "<a href=\"../a.html\">a</a>\u00A0<a href=\"../b.html\">b</a>"
    && linked "a\u007Fb" == "<a href=\"../a.html\">a</a>\u007F<a href=\"../b.html\">b</a>"
    && linked "a\u3000b" == "<a href=\"../a.html\">a</a>\u3000<a href=\"../b.html\">b</a>"
    && linked "  " == "  "
    && linked "" == ""

#guard aCodeSpanSplitsOnUnicodeZCAndWritesEverySeparatorBackOut

/-- The second lookup, and why `Nat.succ` has to stay one word: the qualified
name is asked first, and only when nothing answers is whatever follows the last
`.` asked, with the head written out as text. -/
def aWordTheResolverRefusesIsAskedAgainAfterItsLastDot : Bool :=
  linked "Nat.succ" == "Nat.<a href=\"../succ.html\">succ</a>"
    && linked "a" == "<a href=\"../a.html\">a</a>"
    && linked "Nat.zero" == "Nat.zero"

#guard aWordTheResolverRefusesIsAskedAgainAfterItsLastDot

/-- The half `autoLinkInline` cannot say on its own. `inLink` is what stops the
output nesting anchors, and it reaches the code span rather than the link: a
`<code>` inside an `<a>` is escaped and looked up in nothing. -/
def aCodeSpanLinksItsWordsUnlessItIsInsideAnAnchor : Bool :=
  textOf (.code #["a x"]) false == "<code><a href=\"../a.html\">a</a> x</code>"
    && textOf (.code #["a x"]) true == "<code>a x</code>"
    && textOf (.a #[.normal "x"] #[] false #[.code #["a"]]) false
       == "<a href=\"../x\"><code>a</code></a>"

#guard aCodeSpanLinksItsWordsUnlessItIsInsideAnAnchor

/-- The id is the heading's plain text with every run of `P | Z | C` turned into
one `-`, the empty pieces dropped first so there is no leading or trailing one,
and the case kept. A code span contributes its own characters, which is why the
input here is the three texts md4c reports for `## Main results: `foo`!`. -/
def aHeadingIdTurnsRunsOfPunctuationIntoOneHyphenAndKeepsTheCase : Bool :=
  headingId #[.normal "Main results: ", .code #["Foo.bar"], .normal "!"]
      == "Main-results-Foo-bar"
    && headingId #[.normal "  spaced  "] == "spaced"
    && headingId #[] == ""

#guard aHeadingIdTurnsRunsOfPunctuationIntoOneHyphenAndKeepsTheCase

/-- `##name` is a name search: the resolver is asked first and the find page is
what an unanswered one falls back to, so a docstring never carries a dangling
link into a page nobody wrote. A bare `#` is a fragment of the page being
written and `http` is somebody else's site, so neither takes the root.

The `http` test is `startsWith` and not a scheme check, so `httpfoo:` is left
alone too. That is doc-gen4's behaviour and not a simplification of it. -/
def aLinkTakesTheRootUnlessItIsAFragmentOrAnAbsoluteUrl : Bool :=
  extendLink wordCtx "b.html" == "../b.html"
    && extendLink wordCtx "http://x/y" == "http://x/y"
    && extendLink wordCtx "httpfoo:z" == "httpfoo:z"
    && extendLink wordCtx "#e" == "#e"
    && extendLink wordCtx "##a" == "../a.html"
    && extendLink wordCtx "##Nope.zz" == "../find/?pattern=Nope.zz#doc"

#guard aLinkTakesTheRootUnlessItIsAFragmentOrAnAbsoluteUrl

/-- The info string becomes a class, and only an unlabelled block or one labelled
`lean` has its words looked up: a Python block naming `a` must not link to a Lean
declaration. -/
def aCodeBlockKeepsItsLanguageClassAndOnlyALeanOneIsLinked : Bool :=
  blockOf (.code #[] #[.normal "python"] none #["a = 1\n"])
      == "<pre><code class=\"language-python\">a = 1\n</code></pre>"
    && blockOf (.code #[] #[] none #["a\n"])
       == "<pre><code><a href=\"../a.html\">a</a>\n</code></pre>"
    && blockOf (.code #[] #[.normal "lean"] none #["a\n"])
       == "<pre><code class=\"language-lean\"><a href=\"../a.html\">a</a>\n</code></pre>"

#guard aCodeBlockKeepsItsLanguageClassAndOnlyALeanOneIsLinked

/-! ## The three that have to run

Each of these asks md4c what the input *is*, and the answer is the whole
invariant: which block the parser built, and whether it called a list tight. -/

/-- md4c reports anything entity-shaped as an entity and the renderer writes it
out untouched, so `&notanentity;` survives with its `&`; a bare `&` is not
entity-shaped, goes through the text path, and is escaped.

A `#guard` cannot ask this. `Md.events` is `opaque` with an `@[extern]` body, so
elaboration-time evaluation has no `litedoc4_md_events` to call — the C is
linked into the executable and nothing else. What would falsify it: a
`precompileModules` on the library, which would put the symbol in the
interpreter and cost every consumer a shared library. -/
def entitiesArePassedThroughRaw : Invariant where
  name := "an entity keeps its & and a bare & is escaped"
  check := return first [
    eq (render "&amp; &notanentity;\n") "<p>&amp; &notanentity;</p>",
    eq (render "a & b\n") "<p>a &amp; b</p>"]

/-- A paragraph is wrapped and its text escaped; an item of a tight list is not
wrapped and one of a loose list is. `tight` is the parser's answer and reaches
only `.p`, so nothing closed can be asked it. -/
def aParagraphIsWrappedAndATightItemIsNot : Invariant where
  name := "a paragraph is wrapped and escaped, and only a loose item wraps its own"
  check := return first [
    eq (render "a < b & c\n") "<p>a &lt; b &amp; c</p>",
    eq (render "- a\n- b\n") "<ul><li>a</li><li>b</li></ul>",
    eq (render "- a\n\n- b\n") "<ul><li><p>a</p></li><li><p>b</p></li></ul>"]

/-- `inline` is a run of Markdown rendered without the block element it arrived
in — a heading's own text, put somewhere that is not a heading.

Not `docstring` with the `<p>` trimmed back off: the input is only one paragraph
when it parses as one, and that is a question for md4c. Anything else reaches
the caller as its own characters, so a list in a place with no room for one is
still readable where a `<ul>` dropped into a table cell is not. -/
def inlineIsOneParagraphOrElseTheAuthorsOwnCharacters : Invariant where
  name := "inline renders a single paragraph unwrapped and escapes everything else"
  check := return first [
    eq (inline "The `observe` tactic") "The <code>observe</code> tactic",
    eq (inline "a < b & c") "a &lt; b &amp; c",
    eq (inline "") "",
    eq (byteSub (inline "$x^2$") 0 6) "<math>",
    eq (inline "- a\n- b") "- a\n- b",
    eq (inline "# H") "# H",
    eq (inline "a\n\nb") "a\n\nb"]

end Litedoc4Test
