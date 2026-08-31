/- Byte access into a `String`. Lean-specific: the Rust side reads the same
bytes with a `&str` slice and needs no helper. -/

namespace Litedoc4

@[inline] def byteAt (s : String) (i : Nat) : UInt8 :=
  if h : (⟨i⟩ : String.Pos.Raw) < s.rawEndPos then s.getUTF8Byte ⟨i⟩ h else 0

@[inline] def byteSub (s : String) (a b : Nat) : String :=
  String.Pos.Raw.extract s ⟨a⟩ ⟨b⟩

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

/-- `String.lt` is code-point order, and UTF-8 byte order coincides with it. -/
def byteLt (a b : String) : Bool := Id.run do
  let na := a.utf8ByteSize
  let nb := b.utf8ByteSize
  let mut i := 0
  while i < na && i < nb do
    let x := byteAt a i
    let y := byteAt b i
    if x != y then return x < y
    i := i + 1
  return na < nb

@[inline] def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

end Litedoc4
