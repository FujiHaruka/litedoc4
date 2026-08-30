/- Byte access into a `String`. Lean-specific: the Rust side reads the same
bytes with a `&str` slice and needs no helper. -/

namespace Litedoc4

@[inline] def byteAt (s : String) (i : Nat) : UInt8 :=
  if h : (⟨i⟩ : String.Pos.Raw) < s.rawEndPos then s.getUTF8Byte ⟨i⟩ h else 0

@[inline] def byteSub (s : String) (a b : Nat) : String :=
  String.Pos.Raw.extract s ⟨a⟩ ⟨b⟩

end Litedoc4
