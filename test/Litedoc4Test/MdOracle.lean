/- The two corpora nobody in this repository answered.

`fixtures/md/md4lean-expected.json` is MD4Lean's own parse tree for 533 inputs,
and `fixtures/md/docgen4-expected.json` is 327 renderings of `docStringToHtml`
— doc-gen4's on 322 of them, and this tree's own on the five whose maths became
MathML (`fixtures/md/PROVENANCE.md`). Both were minted outside the Lean half and
neither may be re-minted from it: an expected value produced by the thing being
checked is not an expected value.

The trees are compared through a serialiser rather than through `BEq`, so that a
difference says *where*: `Md.Block`'s `Repr` prints a tree, and finding one node
inside two printed trees is the reader's job. The encoding is
`tools/oracle/dump-ast.lean`'s, which is what the fixture holds.

Both run rather than guard, and for the usual reason: `Md.events` is `@[extern]`
C linked into the executable, and the interpreter `#guard` evaluates in has no
such symbol. -/
import Litedoc4.Md.Html
import Litedoc4Test.Basis
import Litedoc4Test.MdOracleCases

namespace Litedoc4Test
open Litedoc4

private def hexDigit (n : Nat) : Char :=
  Char.ofNat (if n < 10 then 48 + n else 87 + n)

/-- `json.dumps(..., ensure_ascii=False)`, which is what
`tools/gen-md-oracle-cases.py` writes the expected side with: the six short
escapes, `\u00xx` in lowercase for the rest of C0, and everything from U+0020
up written out raw. -/
private def jsonStr (out : String) (s : String) : String :=
  let body := s.foldl (init := out.push '"') fun acc c =>
    let n := c.toNat
    if n == 34 then acc ++ "\\\""
    else if n == 92 then acc ++ "\\\\"
    else if n == 8 then acc ++ "\\b"
    else if n == 12 then acc ++ "\\f"
    else if n == 10 then acc ++ "\\n"
    else if n == 13 then acc ++ "\\r"
    else if n == 9 then acc ++ "\\t"
    else if n < 0x20 then
      ((acc ++ "\\u00").push (hexDigit (n / 16))).push (hexDigit (n % 16))
    else acc.push c
  body.push '"'

private def encArray {α} (out : String) (xs : Array α)
    (enc : String → α → String) : String :=
  let (acc, _) := xs.foldl (init := (out.push '[', false)) fun (acc, sep) x =>
    (enc (if sep then acc.push ',' else acc) x, true)
  acc.push ']'

private def encChar (out : String) (c : Char) : String := jsonStr out (String.singleton c)

private def encOptChar (out : String) : Option Char → String
  | none => out ++ "null"
  | some c => encChar out c

private def encNat (out : String) (n : Nat) : String := out ++ toString n

private def encBool (out : String) (b : Bool) : String := out ++ (if b then "true" else "false")

private def openTag (out : String) (name : String) : String := jsonStr (out.push '[') name

private def encAttrText (out : String) : Md.AttrText → String
  | .normal s => (jsonStr ((openTag out "normal").push ',') s).push ']'
  | .entity s => (jsonStr ((openTag out "entity").push ',') s).push ']'
  | .nullchar => (openTag out "nullchar").push ']'

private def encAttrs (out : String) (a : Array Md.AttrText) : String :=
  encArray out a encAttrText

private def encStrings (out : String) (ss : Array String) : String :=
  encArray out ss jsonStr

private partial def encText (out : String) (t : Md.Text) : String :=
  match t with
  | .normal s => (jsonStr ((openTag out "normal").push ',') s).push ']'
  | .nullchar => (openTag out "nullchar").push ']'
  | .br s => (jsonStr ((openTag out "br").push ',') s).push ']'
  | .softbr s => (jsonStr ((openTag out "softbr").push ',') s).push ']'
  | .entity s => (jsonStr ((openTag out "entity").push ',') s).push ']'
  | .em ts => (encArray ((openTag out "em").push ',') ts encText).push ']'
  | .strong ts => (encArray ((openTag out "strong").push ',') ts encText).push ']'
  | .u ts => (encArray ((openTag out "u").push ',') ts encText).push ']'
  | .a href title isAuto ts =>
    let o := encAttrs ((openTag out "a").push ',') href
    let o := encAttrs (o.push ',') title
    let o := encBool (o.push ',') isAuto
    (encArray (o.push ',') ts encText).push ']'
  | .img src title alt =>
    let o := encAttrs ((openTag out "img").push ',') src
    let o := encAttrs (o.push ',') title
    (encArray (o.push ',') alt encText).push ']'
  | .code ss => (encStrings ((openTag out "code").push ',') ss).push ']'
  | .del ts => (encArray ((openTag out "del").push ',') ts encText).push ']'
  | .latexMath ss => (encStrings ((openTag out "latexMath").push ',') ss).push ']'
  | .latexMathDisplay ss => (encStrings ((openTag out "latexMathDisplay").push ',') ss).push ']'
  | .wikiLink target ts =>
    let o := encAttrs ((openTag out "wikiLink").push ',') target
    (encArray (o.push ',') ts encText).push ']'

private def encTexts (out : String) (ts : Array Md.Text) : String := encArray out ts encText

mutual

private partial def encLi (out : String) (li : Md.Li Md.Block) : String :=
  let o := encBool (out.push '[') li.isTask
  let o := encOptChar (o.push ',') li.taskChar
  let o := match li.taskMarkOffset with
    | none => (o.push ',') ++ "null"
    | some n => encNat (o.push ',') n.toNat
  (encArray (o.push ',') li.contents encBlock).push ']'

private partial def encBlock (out : String) (b : Md.Block) : String :=
  match b with
  | .p ts => (encTexts ((openTag out "p").push ',') ts).push ']'
  | .ul tight mark items =>
    let o := encBool ((openTag out "ul").push ',') tight
    let o := encChar (o.push ',') mark
    (encArray (o.push ',') items encLi).push ']'
  | .ol tight start mark items =>
    let o := encBool ((openTag out "ol").push ',') tight
    let o := encNat (o.push ',') start
    let o := encChar (o.push ',') mark
    (encArray (o.push ',') items encLi).push ']'
  | .hr => (openTag out "hr").push ']'
  | .header level ts =>
    let o := encNat ((openTag out "header").push ',') level
    (encTexts (o.push ',') ts).push ']'
  | .code info lang fenceChar content =>
    let o := encAttrs ((openTag out "code").push ',') info
    let o := encAttrs (o.push ',') lang
    let o := encOptChar (o.push ',') fenceChar
    (encStrings (o.push ',') content).push ']'
  | .html ss => (encStrings ((openTag out "html").push ',') ss).push ']'
  | .blockquote bs => (encArray ((openTag out "blockquote").push ',') bs encBlock).push ']'
  | .table head body =>
    let o := encArray ((openTag out "table").push ',') head encTexts
    (encArray (o.push ',') body (fun a row => encArray a row encTexts)).push ']'

end

private def encDocument (doc : Md.Document) : String := encArray "" doc.blocks encBlock

/-- The byte at which two answers first part company. Named in a failure because
the largest case here is 14 KB of tree and two of those printed side by side is
not a diff. -/
private def firstDiffAt (a b : String) : Nat := Id.run do
  let n := min a.utf8ByteSize b.utf8ByteSize
  let mut i := 0
  while i < n do
    if byteAt a i != byteAt b i then return i
    i := i + 1
  return n

private def report (what input got expected : String) : String :=
  let at_ := firstDiffAt got expected
  s!"{what}\n  input      {repr input}\n  first byte that differs: {at_}\n  \
    got        {repr got}\n  expected   {repr expected}"

/-- The oracle's own configuration: doc-gen4 run with an empty `AnalyzerResult`
(`tools/oracle/dump-html.lean`). Every *name* lookup misses, and a word ending in
`.lean` with a `/` in it still becomes a link — doc-gen4 builds that one by
swapping the extension onto the root and consults no index at all.

**Not `Litedoc4.noLinks`, and that is the whole reason this exists.** `noLinks`
answers `none` to a source path too, so a docstring naming
`Mathlib/Order/Basic.lean` renders as plain `<code>` where doc-gen4 renders an
anchor: nine of the 327 cases here (measured 2026-09-02 →
`benchmarks/results/md-oracle-invariants-2026-09-02.txt` §2a, which also carries
why the divergence is not patched out of `src/`). Using it would be comparing
against an oracle configured differently from the thing being asked. -/
def docGen4EmptyAnalyzer (root : String) : LinkResolver :=
  { nameToLink := fun _ => none,
    sourcePathToLink := fun path => some (root ++ path ++ ".html") }

/-- Written here and not beside the cases: a count generated from the same
fixture as the cases shrinks with them, so it could never notice a corpus that
lost half its entries. -/
def theDocGen4CorpusIsStill327CasesAndTheMd4LeanCorpusStill533 : Bool :=
  docgen4OracleCases.size == 327 && md4leanOracleCases.size == 533

#guard theDocGen4CorpusIsStill327CasesAndTheMd4LeanCorpusStill533

/-- The cases this tree answers differently from the file, named as a set.

The file's five maths cases hold **math-core's** MathML rather than doc-gen4's —
`fixtures/md/PROVENANCE.md`, "changed sides on 2026-08-22" — and this tree
converts through MathML4Lean, which "differs on 107 only where a named rule says
so", adopted as "a decision about output, not a gap to be closed"
(`benchmarks/purelean-report.md`, decided 2026-08-30, user's call). This is one
of the 107; the other four maths cases agree.

A set and not a skip. Dropping the case would be the exception list that swallows
the next real divergence, and re-minting its expected value from this tree would
replace the answer with the thing being checked. Written this way, a second
divergence and this one going away both fail. -/
def docGen4CasesMathML4LeanAnswersDifferently : Array String :=
  #["curated: math with markdown inside"]

/-- `docStringToHtml`, asked of the transcription. `root` varies per case because
it is prepended to every relative link and to the `find/?pattern=` fallback, so a
port that ignored it — or applied it twice — could not pass. The resolver is
`docGen4EmptyAnalyzer` and deliberately not `noLinks`; every name lookup misses
on both sides, which is what lets the whole corpus be compared rather than a
subset with the auto-links filtered out. -/
def theDocGen4CorpusDiffersFromItsRecordedHtmlOnlyWhereMathML4LeanSaysSo : Invariant where
  name := "fixtures/md/docgen4-expected.json renders to its recorded html, and the \
    cases that differ are exactly the maths MathML4Lean answers differently"
  check := do
    let mut differed : Array String := #[]
    let mut firstOne := ""
    for (what, root, md, html) in docgen4OracleCases do
      let c : Renderer := { root := root, links := docGen4EmptyAnalyzer root }
      let got : String := (docstring "" c md).run' 0
      if got != html then
        if differed.isEmpty then firstOne := report s!"{what} (root {repr root})" md got html
        differed := differed.push what
    if differed == docGen4CasesMathML4LeanAnswersDifferently then return none
    let appeared := differed.filter (!docGen4CasesMathML4LeanAnswersDifferently.contains ·)
    let gone := docGen4CasesMathML4LeanAnswersDifferently.filter (!differed.contains ·)
    return some s!"the set of cases that differ changed\n  \
      newly differing {repr appeared}\n  no longer differing {repr gone}\n\
      {firstOne}"

/-- `MD4Lean.parse`, asked of the vendored md4c and the builder over it. The
flags are the case's own and not `docstringFlags`: eight of the 533 were answered
under other flags so that the corners the docstring dialect cannot reach —
underline, wiki links, raw HTML, plain CommonMark — are MD4Lean's answer too
rather than a hand-written guess. -/
def theMd4LeanCorpusParsesToTheTreeItRecords : Invariant where
  name := "every case of fixtures/md/md4lean-expected.json parses to its recorded tree"
  check := do
    let mut differed := 0
    let mut firstOne := ""
    for (what, flags, md, ast) in md4leanOracleCases do
      let got : String := match Md.parse md flags with
        | some doc => encDocument doc
        | none => "null"
      if got != ast then
        if differed == 0 then firstOne := report s!"{what} (flags {flags})" md got ast
        differed := differed + 1
    if differed == 0 then return none
    return some s!"{differed} of {md4leanOracleCases.size} differ; first is {firstOne}"

end Litedoc4Test
