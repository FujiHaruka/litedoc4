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

/-- The code point at byte offset `i`, with its width in bytes. -/
@[inline] def cpAt (s : String) (i : Nat) : UInt32 × Nat :=
  let b := (byteAt s i).toUInt32
  if b < 0x80 then (b, 1)
  else if b < 0xE0 then
    (((b &&& 0x1F) <<< 6) ||| ((byteAt s (i + 1)).toUInt32 &&& 0x3F), 2)
  else if b < 0xF0 then
    (((b &&& 0x0F) <<< 12) ||| (((byteAt s (i + 1)).toUInt32 &&& 0x3F) <<< 6)
      ||| ((byteAt s (i + 2)).toUInt32 &&& 0x3F), 3)
  else
    (((b &&& 0x07) <<< 18) ||| (((byteAt s (i + 1)).toUInt32 &&& 0x3F) <<< 12)
      ||| (((byteAt s (i + 2)).toUInt32 &&& 0x3F) <<< 6)
      ||| ((byteAt s (i + 3)).toUInt32 &&& 0x3F), 4)

/-- The first UTF-16 code unit `cp` encodes as. -/
@[inline] def leadUnit (cp : UInt32) : UInt32 :=
  if cp ≥ 0x10000 then (0xD800 : UInt32) + ((cp - 0x10000) >>> 10) else cp

/-- `crates/litedoc4-ir/src/utf16.rs`'s `cmp_utf16`.

Not `byteLt`, which is what every other order in this tree uses: UTF-8 byte order
is code point order, and UTF-16 puts an astral character *below* U+E000..U+FFFF
because it leads with a high surrogate — `𝒜` (U+1D49C) sorts under `ﬀ` (U+FB00)
here and over it there. What would falsify this: a package with no name outside
the BMP, which `e2e/micro`'s `Example.script𝒜` already is not. -/
def cmpUtf16 (a b : String) : Ordering := Id.run do
  let na := a.utf8ByteSize
  let nb := b.utf8ByteSize
  let mut i := 0
  let mut j := 0
  while i < na && j < nb do
    let (x, wx) := cpAt a i
    let (y, wy) := cpAt b j
    if x != y then
      let lx := leadUnit x
      let ly := leadUnit y
      return if lx == ly then compare x y else compare lx ly
    i := i + wx
    j := j + wy
  return if i < na then .gt else if j < nb then .lt else .eq

@[inline] def ltUtf16 (a b : String) : Bool :=
  match cmpUtf16 a b with
  | .lt => true
  | _ => false

def sortUtf16 (xs : Array String) : Array String := xs.qsort ltUtf16

/-- Adjacent duplicates dropped, which on a sorted array is every duplicate. -/
def dedupSorted (xs : Array String) : Array String := Id.run do
  let mut out : Array String := Array.mkEmpty xs.size
  for x in xs do
    if out.isEmpty || out[out.size - 1]! != x then out := out.push x
  return out

end Litedoc4
