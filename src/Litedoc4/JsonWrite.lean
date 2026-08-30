/- Writing JSON the way `serde_json::to_string` writes it, which is what the
whole-package artifacts are compared against byte for byte.

Not a `JVal` renderer: the objects here are built already sorted and are
emitted straight into the output string, so an intermediate tree would only add
a place for the key order to be lost. What would falsify this: an artifact whose
shape is decided after it is built. -/
import Litedoc4.Bytes

namespace Litedoc4

/-- `serde_json` escapes `"`, `\` and the C0 controls, and nothing else: `/`
stays `/`, DEL stays DEL, and every non-ASCII code point goes out as raw UTF-8. -/
@[inline] def jsonNeedsEscape (b : UInt8) : Bool := b < 32 || b == 34 || b == 92

def jsonEscapeOf (b : UInt8) : String :=
  if b == 34 then "\\\""
  else if b == 92 then "\\\\"
  else if b == 8 then "\\b"
  else if b == 9 then "\\t"
  else if b == 10 then "\\n"
  else if b == 12 then "\\f"
  else if b == 13 then "\\r"
  else
    let n := b.toNat
    (("\\u00".push (hexDigit (n / 16))).push (hexDigit (n % 16)))

def jsonStr (out : String) (s : String) : String := Id.run do
  let n := s.utf8ByteSize
  let mut o := out.push '"'
  let mut seg := 0
  let mut i := 0
  while i < n do
    let b := byteAt s i
    if jsonNeedsEscape b then
      o := o ++ byteSub s seg i ++ jsonEscapeOf b
      seg := i + 1
    i := i + 1
  o := o ++ byteSub s seg n
  return o.push '"'

end Litedoc4
