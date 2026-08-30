/- Byte access into a `String`. Lean-specific: the Rust side reads the same
bytes with a `&str` slice and needs no helper. -/

namespace Litedoc4

@[inline] def byteAt (s : String) (i : Nat) : UInt8 :=
  if h : (⟨i⟩ : String.Pos.Raw) < s.rawEndPos then s.getUTF8Byte ⟨i⟩ h else 0

@[inline] def byteSub (s : String) (a b : Nat) : String :=
  String.Pos.Raw.extract s ⟨a⟩ ⟨b⟩

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
