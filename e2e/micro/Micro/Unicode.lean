import Micro.Basic

/-!
# An identifier above U+FFFF, and Markdown in a docstring

Identifiers and docstrings that leave the Basic Multilingual Plane, and Markdown
that goes the whole way through.

`𝒜` is U+1D49C, above U+FFFF. That is where a site comes apart if one half of it
counts characters differently from the other: the pages are written by a program
that walks UTF-8, the search index is sorted in a browser that walks UTF-16, and
the two orders agree everywhere except above U+FFFF. Search for `𝒜` and the
entry is where the sort says it is.
-/

/-
This package carries the astral character **by construction** rather than by
luck, so a machine that has never seen a Mathlib-sized corpus still runs into
both traps: the sort order above U+FFFF, and IR offsets that are UTF-16 code
units, which make a naive byte slice land in the middle of a character.
-/

namespace Micro

/-- The script capital `𝒜` (U+1D49C) lives outside the BMP, which is where the
two orders part company. -/
def script𝒜 : Nat := 1

/-- Markdown in a docstring, rendered the same way every docstring on this site
is.

# A heading, which gets an id of its own

A paragraph with a `code span`, a reference to `Micro.double` that becomes a
link, and a list:

* first
* second

The heading above is linkable: its id is derived from its own text, so the
address of a section is decided by what the section says. -/
def documented : Nat := script𝒜 + double 1

end Micro
