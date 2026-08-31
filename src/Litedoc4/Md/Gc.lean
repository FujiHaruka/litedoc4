/-
The tables hold Lean 4 / Unicode Basic's answers (Apache-2.0, Copyright © 2023-2026
François G. Dorais), whose data derives from Unicode® character databases
(Copyright © 1991-2025 Unicode, Inc., <https://www.unicode.org/copyright.html>),
by way of `Litedoc4.Md.GcTable`; see this repository's NOTICE and
`docs/provenance.md`.
-/
import Litedoc4.Bytes
import Litedoc4.Md.GcTable

namespace Litedoc4

/-- Decodes the `lo-hi` hex pairs of `pzcTable` / `zcTable` / `v8ZcTable`. The
tables are string literals rather than array literals because 839 array elements
are elaborated one by one and a string is one token; a renderer that was not
being timed for its build would take the package. -/
def gcRanges (s : String) : Array (UInt32 × UInt32) := Id.run do
  let n := s.utf8ByteSize
  let mut out : Array (UInt32 × UInt32) := Array.mkEmpty (n / 8)
  let mut cur : UInt32 := 0
  let mut lo : UInt32 := 0
  let mut i := 0
  while i < n do
    let b := byteAt s i
    if b == 45 then
      lo := cur
      cur := 0
    else if b == 44 then
      out := out.push (lo, cur)
      cur := 0
    else
      cur := cur * 16 + (if b <= 57 then b.toUInt32 - 48 else b.toUInt32 - 55)
    i := i + 1
  return out.push (lo, cur)

def inGcRanges (rs : Array (UInt32 × UInt32)) (v : UInt32) : Bool := Id.run do
  let mut lo := 0
  let mut hi := rs.size
  while lo < hi do
    let mid := (lo + hi) / 2
    let (a, b) := rs[mid]!
    if v < a then hi := mid
    else if v > b then lo := mid + 1
    else return true
  return false

def pzcRanges : Array (UInt32 × UInt32) := gcRanges pzcTable

/-- What `autoLinkInline` splits code on, and half of what `isTokenSeparator`
does. Punctuation is deliberately absent where `pzcRanges` has it: `Nat.succ` has
to stay one word. -/
def zcRanges : Array (UInt32 × UInt32) := gcRanges zcTable

def isPZC (c : UInt32) : Bool := inGcRanges pzcRanges c

def isZC (c : UInt32) : Bool := inGcRanges zcRanges c

end Litedoc4
