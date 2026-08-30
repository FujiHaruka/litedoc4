/- `crates/litedoc4-ir/src/name.rs`. -/
import Litedoc4.Bytes

namespace Litedoc4

def components (s : String) : Array String := Id.run do
  let n := s.utf8ByteSize
  let mut out : Array String := #[]
  let mut a := 0
  let mut i := 0
  while i < n do
    if byteAt s i == 46 then
      out := out.push (byteSub s a i)
      a := i + 1
    i := i + 1
  out := out.push (byteSub s a n)
  return out

end Litedoc4
