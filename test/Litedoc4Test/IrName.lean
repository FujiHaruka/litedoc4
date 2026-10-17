/- The two spellings of a Lean module name, and the one rule that turns either
of them into a page.

All closed, so the compiler answers them and there is nothing to run. -/
import Litedoc4.Ir.Name

namespace Litedoc4Test
open Litedoc4

/-- Every module name of the measurement target is plain identifiers, so there
the two spellings are the identity and the path is the dots turned into
slashes. -/
def aPlainNameIsItsOwnSpellingAndItsOwnPath : Bool :=
  ["InformationTheory.Shannon.BroadcastChannel.Basic", "Alpha",
    "Mathlib.Data.Nat.Basic", "Alpha.AstralNames"].all fun m =>
      escapeModule (components m) == m
        && moduleComponents m == components m
        && pageUrl m == m.replace "." "/" ++ ".html"

#guard aPlainNameIsItsOwnSpellingAndItsOwnPath

def aComponentThatIsNotAnIdentifierIsEscapedAndComesBackUnescaped : Bool :=
  escapeModule #["Alpha", "Odd-Name"] == "Alpha.«Odd-Name»"
    && moduleComponents "Alpha.«Odd-Name»" == #["Alpha", "Odd-Name"]
    && pageUrl "Alpha.«Odd-Name»" == "Alpha/Odd-Name.html"

#guard aComponentThatIsNotAnIdentifierIsEscapedAndComesBackUnescaped

/-- U+FB00 is not in Lean's letter-like tables, so the ligature escapes even
alone while the astral script capital does not. -/
def anAstralLetterLikeCharacterIsAnIdentifierAndALigatureIsNot : Bool :=
  isIdFirst '𝒜' && !isIdFirst 'ﬀ'
    && escapeComponent "𝒜" == "𝒜"
    && escapeComponent "𝒜-z" == "«𝒜-z»"
    && escapeComponent "ﬀ" == "«ﬀ»"
    && escapeComponent "ﬀ-z" == "«ﬀ-z»"

#guard anAstralLetterLikeCharacterIsAnIdentifierAndALigatureIsNot

def aComponentHoldingTheClosingGuillemetIsLeftAlone : Bool :=
  escapeComponent "a»b" == "a»b"

#guard aComponentHoldingTheClosingGuillemetIsLeftAlone

def theSplitDoesNotCutInsideAnEscape : Bool :=
  moduleComponents "Alpha.«a.b».C" == #["Alpha", "a.b", "C"]
    && pageUrl "Alpha.«a.b».C" == "Alpha/a.b/C.html"

#guard theSplitDoesNotCutInsideAnEscape

/-- The split walks bytes rather than characters here, which is safe only
because neither `.` nor either half of `«`/`»` can occur as a continuation byte
of a longer sequence. -/
def aMultiByteCharacterDoesNotSplitAComponent : Bool :=
  moduleComponents "Pkg.𝒜.ﬀ" == #["Pkg", "𝒜", "ﬀ"]
    && pageUrl "Pkg.«𝒜-z»" == "Pkg/𝒜-z.html"

#guard aMultiByteCharacterDoesNotSplitAComponent

def anEmptyComponentEscapesRatherThanVanishing : Bool :=
  escapeComponent "" == "«»" && !needsNoEscape ""

#guard anEmptyComponentEscapesRatherThanVanishing

/-- A module name really can carry a `..` through the page rule, which is why
`Litedoc4.PageRoot` checks the tree a deletion lands in rather than arguing from
the spelling. -/
def anEscapedComponentCanSpellAParentDirectory : Bool :=
  pageUrl "«..».Foo" == "../Foo.html"

#guard anEscapedComponentCanSpellAParentDirectory

end Litedoc4Test
