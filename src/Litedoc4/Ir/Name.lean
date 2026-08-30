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

/-- `«` and `»` at byte `i`, as their two UTF-8 bytes. -/
@[inline] def isGuillemet (s : String) (i : Nat) (closing : Bool) : Bool :=
  byteAt s i == 0xC2 && byteAt s (i + 1) == (if closing then 0xBB else 0xAB)

/-- `«Odd.Name»` → `Odd.Name`; anything not wrapped in both is itself. -/
def unescapeComponent (s : String) : String :=
  let n := s.utf8ByteSize
  if n ≥ 4 && isGuillemet s 0 false && isGuillemet s (n - 2) true then byteSub s 2 (n - 2)
  else s

/-- `module_components`: the dot separates only outside `«…»`, and each
component comes back unescaped, so `Alpha.«Odd.Name»` is two components.

**Not interchangeable with `components`, and the Rust side is not confused about
which is which**: a path, a link href, a source URL and the site title take this
one, because they have to name the file the renderer wrote; `Name.lt` and the
tail match take the plain split, because they compare a *spelling* against
another spelling. Feeding either to the other's callers is a divergence no byte
comparison of one side finds — the page is written under one name and linked
under the other. What would falsify this: a Lean that stopped escaping such
components with guillemets. -/
def moduleComponents (s : String) : Array String := Id.run do
  let n := s.utf8ByteSize
  let mut out : Array String := #[]
  let mut a := 0
  let mut i := 0
  let mut depth := 0
  while i < n do
    if isGuillemet s i false then
      depth := depth + 1
      i := i + 2
    else if isGuillemet s i true then
      depth := depth - 1
      i := i + 2
    else
      if byteAt s i == 46 && depth == 0 then
        out := out.push (unescapeComponent (byteSub s a i))
        a := i + 1
      i := i + 1
  out := out.push (unescapeComponent (byteSub s a n))
  return out

end Litedoc4
