/- `crates/litedoc4-md/src/escape.rs`: the only escape doc-gen4 applies to HTML
text and attributes.

`escape_borrows_when_it_can` has no invariant here. It asks whether the Rust
`Cow` borrowed, and a `String` has no borrowed form to observe — the untouched
path and the rewriting path of `escapeSub` are told apart by nothing but the
characters they return, which is what the two guards below already say. -/
import Litedoc4.Md.Escape

namespace Litedoc4Test
open Litedoc4

def escape (s : String) : String := escapeInto "" s

/-- `& < > "` and no other character. The apostrophe is the one that decides it:
every general-purpose HTML escaper rewrites it and doc-gen4 does not, so one
`'` in a page is one byte of divergence from the output being reproduced. -/
def theFourCharactersAreRewrittenAndTheApostropheIsNot : Bool :=
  escape "a & b < c > d \" e" == "a &amp; b &lt; c &gt; d &quot; e"
    && escape "Nat.succ'" == "Nat.succ'"
    && escape "a/b" == "a/b"

#guard theFourCharactersAreRewrittenAndTheApostropheIsNot

/-- The scan walks bytes, which is safe only because the four are ASCII and
UTF-8 never encodes a non-ASCII scalar with an ASCII byte. -/
def escapingLeavesEveryNonAsciiCharacterAlone : Bool :=
  escape "ℕ ∑ ≐ μ 𝒜 日本語" == "ℕ ∑ ≐ μ 𝒜 日本語"

#guard escapingLeavesEveryNonAsciiCharacterAlone

end Litedoc4Test
