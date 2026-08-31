/- `crates/litedoc4-render/src/link_index.rs`: the dependency closure's `.lidx`. -/
import Std.Data.HashMap
import Std.Data.HashSet
import Litedoc4.Bytes

namespace Litedoc4

structure LidxEntry where
  startLine : Nat
  endLine : Nat
  module : String
  deriving Inhabited

structure Lidx where
  names : Std.HashMap String LidxEntry
  modules : Std.HashSet String
  deriving Inhabited

/-- The digits of one field, or `none` when it is empty or holds anything else.

**Not a truncating scan.** `(byteAt s i).toNat - 48` is `Nat` subtraction, which
floors at zero, so `-3` would read as 3 and ` 67` as 67 — a range invented out of
a field that says it has none, and a link anchored at `#L3-L7` is worse than one
with no anchor. What would falsify the check: a writer that could not put
anything but digits there, which is not this one — the reader is deliberately the
half with no error path. -/
@[inline] def digitsAt (s : String) (a b : Nat) : Option Nat := Id.run do
  if a ≥ b then return none
  let mut acc := 0
  let mut i := a
  while i < b do
    let d := byteAt s i
    if d < 48 || d > 57 then return none
    acc := acc * 10 + (d.toNat - 48)
    i := i + 1
  return some acc

/-- The `.lidx` reader: line-oriented, first byte decides, no error path. The
byte scan `purelean-microbench-optimised-2026-08-30.txt` measured at 0.0877 s,
split so that the `@` module set and the declaration map stay apart the way
`crates/litedoc4-render/src/link_index.rs` keeps them. -/
def parseLidx (text : String) : Lidx := Id.run do
  let n := text.utf8ByteSize
  let mut names : Std.HashMap String LidxEntry := Std.HashMap.emptyWithCapacity 524288
  let mut modules : Std.HashSet String := Std.HashSet.emptyWithCapacity 8192
  let mut group := ""
  let mut i := 0
  while i < n do
    let a := i
    let mut j := a
    while j < n && byteAt text j != 10 do
      j := j + 1
    if a < j then
      let c := byteAt text a
      if c == 35 then
        pure ()
      else if c == 64 then
        modules := modules.insert (byteSub text (a + 1) j)
      else if c == 9 then
        let mut t1 := a + 1
        while t1 < j && byteAt text t1 != 9 do
          t1 := t1 + 1
        let name := byteSub text (a + 1) t1
        let mut entry : LidxEntry := { module := group, startLine := 0, endLine := 0 }
        if t1 < j then
          let mut t2 := t1 + 1
          while t2 < j && byteAt text t2 != 9 do
            t2 := t2 + 1
          if t2 < j then
            -- The third field ends at the next tab and not at the end of the
            -- line: a fourth field is **ignored**, so a later writer can add one
            -- without this reader being taught about it first. Reading to the
            -- line end instead would cost every entry in such a file its range,
            -- which is a whole site's source anchors going missing in silence.
            let mut t3 := t2 + 1
            while t3 < j && byteAt text t3 != 9 do
              t3 := t3 + 1
            if let some startLine := digitsAt text (t1 + 1) t2 then
              if let some endLine := digitsAt text (t2 + 1) t3 then
                entry := { module := group, startLine, endLine }
        names := names.insert name entry
      else
        group := byteSub text a j
    i := j + 1
  return { names, modules }

/-- `none` covers two different things on purpose — a name the map does not
hold, and a name it holds with no range — because the caller does the same thing
with both: build the URL without an anchor if the module resolves at all. A `0`
start line is the second case; the `.lidx` counts lines from 1, which is what
`crates/litedoc4-render/src/link_index.rs` spells with `NonZeroU32`. -/
def Lidx.rangeOf (l : Lidx) (name : String) : Option (Nat × Nat) :=
  match l.names.get? name with
  | some e => if e.startLine == 0 then none else some (e.startLine, e.endLine)
  | none => none

def emptyLidx : Lidx :=
  { names := Std.HashMap.emptyWithCapacity 0, modules := Std.HashSet.emptyWithCapacity 0 }

end Litedoc4
