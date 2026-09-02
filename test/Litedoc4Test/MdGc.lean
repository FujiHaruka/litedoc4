/- The two Unicode category tables, which are UnicodeBasic's answers and
therefore Lean's own — `isPZC` decides where a heading id breaks and `isZC`
decides where `autoLinkInline` splits a code span.

Not a table of code points but a table of ranges, so the guards below are stated
about ranges. -/
import Litedoc4.Md.Gc

namespace Litedoc4Test
open Litedoc4

def sortedAndDisjoint (rs : Array (UInt32 × UInt32)) : Bool :=
  rs.all (fun (lo, hi) => lo <= hi)
    && (List.range (rs.size - 1)).all fun i =>
        (rs[i]!.2).toNat + 1 < (rs[i + 1]!.1).toNat

/-- `inGcRanges` binary-searches, so a table that is out of order or holds two
ranges that touch answers the wrong question rather than a slower one. -/
def theTwoTablesAreSortedAndDisjoint : Bool :=
  sortedAndDisjoint pzcRanges && sortedAndDisjoint zcRanges

#guard theTwoTablesAreSortedAndDisjoint

/-- The difference between the two tables is exactly punctuation, so this fails
if they ever came from different dumps.

Rust walks all 1,114,112 code points; containment of ranges says the same thing
about the same whole space and costs one pass, **given the guard above** — with
`pzcRanges` sorted and disjoint, a `Z | C` range that fits inside one `P | Z | C`
range holds no code point that escapes it. What would falsify the shortcut: a
`P | Z | C` table whose ranges overlap, where a `Z | C` range could straddle two
of them and still cover only members. -/
def everyZCRangeSitsInsideAPZCRangeAndTheAsciiDifferenceIsPunctuation : Bool :=
  zcRanges.all (fun (lo, hi) => pzcRanges.any fun (a, b) => a <= lo && hi <= b)
    && "._'!?-:".toList.all fun c => isPZC c.val && !isZC c.val

#guard everyZCRangeSitsInsideAPZCRangeAndTheAsciiDifferenceIsPunctuation

/-- Both tables merge several general categories, so the only way to say which
merge they are is to name characters. U+00AD is the soft hyphen (`Cf`) and
U+2028 the line separator (`Zl`): neither is whitespace by any ASCII test, and
both split a word. U+0301 is a combining acute, which is a letter's business and
not punctuation's. -/
def theNamedCharactersAreInTheCategoriesTheyAreNamedFor : Bool :=
  [' ', '\t', '\n', '\u0000', '\u00A0', '\u00AD', '\u2028'].all (fun c => isZC c.val)
    && ['a', 'Z', '0', 'α', 'ℕ', '∑', '→', '×', '𝒩', '\u0301'].all
        fun c => !isPZC c.val

#guard theNamedCharactersAreInTheCategoriesTheyAreNamedFor

end Litedoc4Test
