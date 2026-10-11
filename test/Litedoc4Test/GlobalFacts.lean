/- Everything the whole-package artifacts need from one module, and the
tokeniser the map delta is made of.

All closed and none of it reaches `Md.events` — this file's subject is exactly
the part of a docstring that is read *without* parsing Markdown. -/
import Litedoc4.Global.Facts
import Litedoc4Test.MdGc

namespace Litedoc4Test
open Litedoc4

def modDoc (line : Nat) (text : String) : ModuleDoc := { line, col := 0, text }

def theHeadingIsTheFirstOneByPositionNotByOrder : Bool :=
  leadingHeading #[modDoc 90 "# Later", modDoc 12 "# First\n\nprose"] == some "First"

#guard theHeadingIsTheFirstOneByPositionNotByOrder

/-- e2e-micro's GATE 14 reaches two of these — `# Title` and the one module that
opens with prose — over a built site. The other four negatives are shapes the
sample package does not have, and each of them is a row that would appear on the
front page saying something the module did not. -/
def onlyALevelOneAtxHeadingThatOpensTheDocstringCounts : Bool :=
  leadingHeading #[modDoc 1 "# Title"] == some "Title"
    && leadingHeading #[modDoc 1 "\n  # Title  \nmore"] == some "Title"
    && ["## Sub", "#NoSpace", "Prose first\n\n# Title", "# ", ""].all
        fun text => leadingHeading #[modDoc 1 text] == none
    && leadingHeading #[] == none

#guard onlyALevelOneAtxHeadingThatOpensTheDocstringCounts

/-- A closing run of hashes is CommonMark's, so it needs the space CommonMark
needs before it; `# C#` is a module about C#. -/
def aClosingHashRunIsDroppedAndATrailingHashIsNot : Bool :=
  leadingHeading #[modDoc 1 "# Title #"] == some "Title"
    && leadingHeading #[modDoc 1 "# Title ###"] == some "Title"
    && leadingHeading #[modDoc 1 "# C#"] == some "C#"

#guard aClosingHashRunIsDroppedAndATrailingHashIsNot

/-- ``/`([^`\n]+)`/g``. An empty span is not a match and its closing backtick can
open the next one, which is why `` ``a` `` is one span and not none. -/
def codeSpansAreFoundTheWayTheRegexFindsThem : Bool :=
  codeSpans "`a`" == #["a"]
    && codeSpans "x `a` y `b` z" == #["a", "b"]
    && codeSpans "``a`" == #["a"]
    && codeSpans "``" == #[]
    && codeSpans "`a\nb`" == #[]
    && codeSpans "`a`b`c`" == #["a", "c"]
    && codeSpans "no ticks" == #[]
    && codeSpans "`α → β`" == #["α → β"]

#guard codeSpansAreFoundTheWayTheRegexFindsThem

/-- `/\]\(([^)\s]+)\)/g`. The greedy class eats everything that is neither `)`
nor a JavaScript space, so `](](x)` yields `](x` and not `x`. -/
def linkTargetsAreFoundTheWayTheRegexFindsThem : Bool :=
  linkTargets "[t](Foo.Bar)" == #["Foo.Bar"]
    && linkTargets "[a](x) [b](y)" == #["x", "y"]
    && linkTargets "[t](a b)" == #[]
    && linkTargets "[t]()" == #[]
    && linkTargets "[t](a\u00A0b)" == #[]
    && linkTargets "](](x)" == #["](x"]
    && linkTargets "](" == #[]

#guard linkTargetsAreFoundTheWayTheRegexFindsThem

def aPartEndingInADotContributesTheEmptyString : Bool :=
  autolinkTokens "`a.`" == #["a.", ""]
    && autolinkTokens "`Nat.succ`" == #["Nat.succ", "succ"]
    && autolinkTokens "`n`" == #["n"]
    && autolinkTokens "`  a  `" == #["a"]

#guard aPartEndingInADotContributesTheEmptyString

def aSeparatorOfBothImplementationsSplits : Bool :=
  autolinkTokens "`Nat.succ\u00A0Foo`" == #["Nat.succ", "succ", "Foo"]

#guard aSeparatorOfBothImplementationsSplits

def rangeCard (rs : Array (UInt32 × UInt32)) : Nat :=
  rs.foldl (fun acc (lo, hi) => acc + (hi.toNat - lo.toNat + 1)) 0

/-- Rust walks all 1,114,112 code points and counts the two differences. Ranges
say the same thing about the same whole space in one pass, **given the two
sortedness premises restated here**: with both tables sorted and disjoint each
one's cardinality is the sum of its ranges, and every `Z | C` range fitting
inside one V8 range makes `Z | C` a subset, so the difference is a subtraction
rather than a scan. What would falsify the shortcut: either table growing ranges
that overlap, where a subset range could straddle two of them.

That the union is `isZC || isV8ZC` is not asserted — it is `isTokenSeparator`'s
definition, and there is no second place for it to disagree with.
(measured 2026-10-11 → `benchmarks/results/v8-gc-table-node-2026-10-11.txt`) -/
def theTwoSeparatorSetsAreEqualTheWayNodeMeasuredThem : Bool :=
  sortedAndDisjoint v8ZcRanges && sortedAndDisjoint zcRanges
    && zcRanges.all (fun (lo, hi) => v8ZcRanges.any fun (a, b) => a ≤ lo && hi ≤ b)
    && rangeCard v8ZcRanges - rangeCard zcRanges == 0
    && isTokenSeparator 0x00A0 && isZC 0x00A0

#guard theTwoSeparatorSetsAreEqualTheWayNodeMeasuredThem

end Litedoc4Test
