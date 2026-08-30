/- `crates/litedoc4-render/src/order.rs`. -/
import Litedoc4.Bytes
import Litedoc4.Ir.Name

namespace Litedoc4

/-! ## Order

`String.lt` is code-point order, and UTF-8 byte order coincides with it.
`Name.lt` compares the **parents** first, so `Init` and `Mathlib` both precede
`Init.Core`; the import list is sorted with it. -/

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

partial def nameLtC (a b : Array String) : Bool :=
  if a.isEmpty then !b.isEmpty
  else if b.isEmpty then false
  else
    let pa := a.pop
    let pb := b.pop
    if nameLtC pa pb then true
    else if pa == pb then byteLt a.back! b.back!
    else false

def nameLt (a b : String) : Bool := nameLtC (components a) (components b)

end Litedoc4
