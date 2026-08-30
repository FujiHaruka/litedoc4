/- `crates/litedoc4-ir/src/utf16.rs`: a fragment's text with the UTF-16 index
the IR's spans are stated in. -/
import Litedoc4.Bytes

namespace Litedoc4

structure Frag where
  text : String
  ascii : Bool
  /-- UTF-16 index to byte offset; empty when `ascii`. -/
  u2b : Array Nat
  deriving Inhabited

@[inline] def Frag.bpos (f : Frag) (i : Nat) : Nat := if f.ascii then i else f.u2b[i]!

def isAscii (s : String) : Bool := Id.run do
  let n := s.utf8ByteSize
  let mut i := 0
  while i < n do
    if byteAt s i >= 128 then return false
    i := i + 1
  return true

def buildU2B (s : String) : Array Nat := Id.run do
  let n := s.utf8ByteSize
  let mut a : Array Nat := Array.mkEmpty (n + 1)
  let mut i := 0
  while i < n do
    let b := byteAt s i
    let w := if b < 0x80 then 1 else if b < 0xE0 then 2 else if b < 0xF0 then 3 else 4
    a := a.push i
    if w == 4 then a := a.push i
    i := i + w
  return a.push n

def mkFragOf (text : String) : Frag :=
  if isAscii text then { text, ascii := true, u2b := #[] }
  else { text, ascii := false, u2b := buildU2B text }

end Litedoc4
