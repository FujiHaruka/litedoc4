/-
Derived from doc-gen4 (Apache-2.0, Copyright (c) 2021 Henrik Böving) by way of
`crates/litedoc4-md/src/escape.rs`, and changed; see this repository's NOTICE
and `docs/provenance.md`.
-/
import Litedoc4.Bytes

namespace Litedoc4

/-! ## HTML escaping

`Html.escape` in doc-gen4: `& < > "` and nothing else. The fast path is the one
that matters — most fragments contain none of the four, and then the whole
string is one `memcpy`. -/

def escapeSub (out : String) (s : String) (a b : Nat) : String := Id.run do
  let mut i := a
  let mut seg := a
  let mut acc := out
  while i < b do
    let c := byteAt s i
    if c == 38 || c == 60 || c == 62 || c == 34 then
      acc := acc ++ byteSub s seg i
      acc := acc ++ (if c == 38 then "&amp;" else if c == 60 then "&lt;"
                     else if c == 62 then "&gt;" else "&quot;")
      seg := i + 1
    i := i + 1
  if seg == a then acc ++ byteSub s a b else acc ++ byteSub s seg b

@[inline] def escapeInto (out : String) (s : String) : String :=
  escapeSub out s 0 s.utf8ByteSize

end Litedoc4
