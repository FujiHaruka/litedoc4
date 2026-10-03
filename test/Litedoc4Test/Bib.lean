/- A bibliography: which citations a docstring makes, what the renderer appends
for them, and what a `.bib` file reads as. All of it is closed, so all of it is a
`#guard`; what a citation renders as needs md4c and is in `MdHtml`. -/
import Litedoc4.Bibtex

namespace Litedoc4Test
open Litedoc4

def bibItem (citekey tag plaintext : String) : BibItem :=
  { citekey, tag, html := s!"<i>{citekey}</i>.", plaintext }

def twoKeys : Bibliography :=
  Bibliography.of #[bibItem "Doe12" "[DJ12]" "Doe.", bibItem "Roe13" "[RR13]" "Roe."]
    (some "digest")

def citedKeysAreTheBracketedKeysOnceEachAndSorted : Bool :=
  citedKeys twoKeys "[Roe13] then [the book][Doe12], [Roe13] again, and [Nobody]"
      == #["Doe12", "Roe13"]
    && citedKeys twoKeys "no brackets at all" == #[]
    && citedKeys {} "[Doe12]" == #[]

#guard citedKeysAreTheBracketedKeysOnceEachAndSorted

/-- doc-gen4's scan pairs each `[` with the next `]` and resumes there, so a key
inside a longer bracket is not found. Reproduced rather than improved: a citation
that links here and not on a doc-gen4 site, or the reverse, is a difference
between two renderings of one docstring. -/
def theScanPairsEachOpeningBracketWithTheNextClosingOne : Bool :=
  citedKeys twoKeys "[[Doe12]]" == #[]
    && citedKeys twoKeys "[x [Doe12]" == #[]
    && citedKeys twoKeys "[Doe12" == #[]
    && citedKeys twoKeys "[x] [Doe12]" == #["Doe12"]

#guard theScanPairsEachOpeningBracketWithTheNextClosingOne

/-- With nothing cited the suffix is the blank line alone, which is what keeps a
package with no bibliography rendering the bytes it rendered before there was
one. -/
def nothingCitedAppendsTheBlankLineAlone : Bool :=
  referenceDefinitions #[] == "\n\n"
    && referenceDefinitions (citedKeys twoKeys "[Nobody]") == "\n\n"
    && referenceDefinitions #["Doe12", "Roe13"]
      == "\n\n[Doe12]: references.html#ref_Doe12\n[Roe13]: references.html#ref_Roe13\n"

#guard nothingCitedAppendsTheBlankLineAlone

/-- The destination as the author wrote it, before the page's root is put in
front: only that spelling is a citation, and only of a key there is. -/
def aDestinationCitesOnlyTheReferencesPageAndOnlyAKey : Bool :=
  (twoKeys.cited? "references.html#ref_Doe12").map (·.tag) == some "[DJ12]"
    && (twoKeys.cited? "references.html#ref_Nobody").isNone
    && (twoKeys.cited? "../references.html#ref_Doe12").isNone
    && (twoKeys.cited? "references.html").isNone

#guard aDestinationCitesOnlyTheReferencesPageAndOnlyAKey

def aKeyGivenTwiceIsItsLastItem : Bool :=
  let b := Bibliography.of #[bibItem "K" "[first]" "", bibItem "K" "[second]" ""] none
  (b.byKey.get? "K").map (·.tag) == some "[second]" && b.items.size == 2

#guard aKeyGivenTwiceIsItsLastItem

/-- BibtexQuery's answer for one entry, which is the tag and the text a doc-gen4
site shows for it. `html` is escaped markup and `plaintext` is not escaped. -/
def anEntryReadsAsBibtexQuerysTagAndText : Bool :=
  (processBibtex "% a note outside any entry\n@book{K, author={Doe, John}, \
      title={Fish \\& Chips}, year={2012}, publisher={P}}\n").toOption
    == some { items := #[{ citekey := "K", tag := "[Doe12]"
                           html := "John Doe.\n<i>Fish &amp; Chips</i>.\nP, 2012."
                           plaintext := "John Doe.\nFish & Chips.\nP, 2012." }]
              unread := none }
    && (processBibtex "no entry here").toOption == some { items := #[], unread := none }

#guard anEntryReadsAsBibtexQuerysTagAndText

/-- BibtexQuery stops at the first entry it cannot read and succeeds with the ones
before it. Those are kept, as doc-gen4 keeps them, and where it stopped is
reported with every `@` from there on, so the `@book{L…}` below is not dropped in
silence. -/
def anEntryTheParserStopsAtKeepsTheOnesBeforeAndSaysWhere : Bool :=
  let read (text : String) : Option (Array String × Option Unread) :=
    (processBibtex text).toOption.map fun r => (r.items.map (·.citekey), r.unread)
  read "@book{K, title={T}, year={2012}}\n\n@comment{x}\n@book{L, title={U}, year={2013}}\n"
      == some (#["K"], some { line := 3, ats := 2 })
    && read "@book{K, title={T" == some (#[], some { line := 1, ats := 1 })

#guard anEntryTheParserStopsAtKeepsTheOnesBeforeAndSaysWhere

end Litedoc4Test
