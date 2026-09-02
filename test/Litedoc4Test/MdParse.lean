/- What the parser does with the shapes that are undefined behaviour on
MD4Lean's side, and the claim this half could not otherwise make — that nothing
takes the process down.

All of it runs. Every one of these calls `Md.events`, which is `@[extern]` C
linked only into the executable, so there is nothing here a `#guard` could ask.

The halves of those three files that walk a frozen fixture (`crashes_md4lean`,
`crashes_doc_gen4`) are not here: they compare against committed bytes, and that
is the tranche that decides those together. -/
import Litedoc4Test.MdHtml

namespace Litedoc4Test
open Litedoc4

def parseBlocks (s : String) : Option (Array Md.Block) :=
  (Md.parse s docstringFlags).map (·.blocks)

/-- MD4Lean dies on both of these — a SIGSEGV on the first and a SIGABRT on the
second — so there are no bytes to reproduce and what is pinned is what this half
chose instead: U+FFFD for a NUL in verbatim content, which is CommonMark's rule
and what doc-gen4 renders `.nullchar` as, and an empty `<tbody>` for a table with
a header and no body row.

The NUL survives **twice**: md4c reports it as `MD_TEXT_NULLCHAR` and then
resumes the verbatim text *at* the NUL rather than past it, so the replacement
character is followed by the byte itself. That is md4c's behaviour and not a
decision made here — in ordinary text and in a code span the same NUL comes back
once, which is why those two are stated beside it. -/
def theShapesThatKillMd4LeanParseAndRenderHere : Invariant where
  name := "a NUL and a table with no body row are parsed and rendered, not crashed on"
  check := return first [
    eq (parseBlocks "a\u0000b\n") (some #[Md.Block.p #[.normal "a", .nullchar, .normal "b"]]),
    eq (parseBlocks "`a\u0000b`\n") (some #[Md.Block.p #[.code #["a\u0000b"]]]),
    eq (render "```\na\u0000b\n```\n") "<pre><code>a\uFFFD\u0000b\n</code></pre>",
    eq (render "| a | b |\n|---|---|\n")
      "<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody></tbody></table>"]

def repeated (n : Nat) (s : String) : String := Id.run do
  let mut out := ""
  for _ in [0:n] do out := out ++ s
  return out

/-- Every input shape known to be dangerous, carried as text rather than as
files. The Rust side read a directory and had to count what it found, because a
corpus that silently emptied would have left the test passing having checked
nothing; here the corpus is this array, so a case that goes missing is a diff.

The last three are duplicates of shapes the committed corpus also holds, kept
because a case that only exists as a file is one a reader has to remember to
load. -/
def hostileInputs : Array String := #[
  "",
  "Astral: 𝒜 😀 and a combining mark: e\u0301\n\n# 𝒜 heading\n\n`𝒜`\n",
  "---\n***\n___\n\n    indented code\n\n1. a\n2. b\n\n[ref]: https://example.invalid\n[use][ref]\n",
  repeated 400 "> " ++ "deep\n" ++ repeated 200 "- " ++ "item\n",
  "&amp; &#65; &#x1D49C; &nosuch; &999999999;\n",
  "| a | b |\n| --- | --- |\n",
  "<div class=\"raw\">\n<script>alert(1)</script>\n</div>\n\n<https://example.invalid/auto>\n",
  "\r\n\r\nCRLF line endings\r\nand a lone \rcarriage return\n",
  "Nested `` `backticks` `` and ```triple `inside` ```\n",
  "A fenced block holding a NUL byte.\n\n```lean\nexample : Nat := \u0000 1\n```\n",
  "An unclosed [link, an unclosed `code span, an unclosed <div, and an\nunclosed ```fence\n",
  "".pushn 'x' 200000 ++ "\n",
  "```\n\u0000\n```\n",
  "prose\n\n```lean\nexample : Nat := \u0000 1\n```\n",
  "text\n\n| only | a | header |\n| --- | --- | --- |\n\nmore\n"]

def fragments : Array String := #[
  "```", "~~~", "\u0000", "| a |", "| --- |", "> ", "- ", "#", "`", "**",
  "[", "]", "(", ")", "<div>", "</div>", "\r", "\n", "  ", "\t",
  "𝒜", "é", "&#x1D49C;", "&", ";", "$", "\\", "http://x.invalid",
  "_", "*", "!", "^", "~", "|", "=", "'", "\"", "<", ">"]

/-- xorshift64*, small enough to read, which is the only property that matters.
The seed is fixed: a gate that fails on one push in fifty and passes on the
retry teaches people to hit retry. New shapes come from raising the round count
or adding to `fragments`, deliberately — never from the clock. -/
def draw (s : UInt64) : UInt64 × UInt64 :=
  let s := s ^^^ (s >>> 12)
  let s := s ^^^ (s <<< 25)
  let s := s ^^^ (s >>> 27)
  (s * 0x2545F4914F6CDD1D, s)

/-- Splices of `fragments` and nothing well-formed, because the failure being
guarded against is a memory-safety failure in C and those do not need
well-formed Markdown to happen. -/
def generatedInputs : Array String := Id.run do
  let mut st : UInt64 := 0x5EED1234ABCD0001
  let mut out : Array String := Array.mkEmpty 4000
  for _ in [0:4000] do
    let (count, st1) := draw st
    st := st1
    let mut input := ""
    for _ in [0:(count % 24).toNat + 1] do
      let (pick, st2) := draw st
      st := st2
      input := input ++ fragments[pick.toNat % fragments.size]!
    out := out.push input
  return out

/-- What is asserted is that control comes back for each one. A wrong `<p>` is
another invariant's business; a segfault is this one's whole subject, and it
shows up as the executable not reaching its own summary line.

The widest rendering is what forces the work — a loop whose result nothing reads
is a loop the compiler may drop — and it names the one input where a buffer bug
would be likeliest: the 200 KB line. -/
def noHostileOrGeneratedInputCrashesTheRenderer : Invariant where
  name := "every input known to be dangerous, and 4,000 generated ones, come back"
  check := do
    let inputs := hostileInputs ++ generatedInputs
    let mut ran := 0
    let mut widest := 0
    for input in inputs do
      let out := render input
      if out.utf8ByteSize > widest then widest := out.utf8ByteSize
      ran := ran + 1
    return first [
      eq ran inputs.size,
      if widest < 200000 then
        some s!"the widest rendering was {widest} bytes; the 200 KB line did not go through"
      else none]

/-- An FFI boundary is where "the same input twice gives the same bytes" stops
being obvious: uninitialised memory read back as a length, or a buffer reused
between calls, shows up exactly here and nowhere else.

Two passes and not two calls side by side, because `Md.events` is `opaque` and
therefore pure to the compiler, which may answer the second call with the first
one's result and check nothing. -/
def renderingIsDeterministicOverTheHostileCorpus : Invariant where
  name := "the same hostile input rendered twice gives the same bytes"
  check := do
    let once := hostileInputs.map render
    let mut why : Option String := none
    for i in [0:hostileInputs.size] do
      if render hostileInputs[i]! != once[i]! && why.isNone then
        why := some s!"hostile input {i} rendered differently the second time"
    return why

end Litedoc4Test
