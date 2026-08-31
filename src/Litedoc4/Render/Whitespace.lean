/-
Derived from doc-gen4 (Apache-2.0, Copyright (c) 2021 Henrik Böving) by way of
`crates/litedoc4-render/src/whitespace.rs`, and changed; see this repository's NOTICE
and `docs/provenance.md`.
-/
import Litedoc4.Ir
import Litedoc4.Ir.Utf16

namespace Litedoc4

/-- `splitWhitespaces` replayed from the schema-3 widths: length-preserving in
UTF-16 units, so no offset moves. Skipped entirely when every unit in the runs
is already a space, which is the common case. -/
def mkFrag (text : String) (spans : Array Span) : Frag := Id.run do
  let f0 := mkFragOf text
  let mut ranges : Array (Nat × Nat) := #[]
  for s in spans do
    if s.front > 0 then ranges := ranges.push (s.start - s.front, s.start)
    if s.back > 0 then ranges := ranges.push (s.stop, s.stop + s.back)
  if ranges.isEmpty then return f0
  ranges := ranges.qsort (fun a b => a.1 < b.1)
  let units := f0.units
  let mut changed := false
  for (a, b) in ranges do
    if b > units then continue
    let mut i := f0.bpos a
    let e := f0.bpos b
    while i < e do
      if byteAt text i != 32 then changed := true
      i := i + 1
  if !changed then return f0
  let mut out := ""
  let mut pos := 0
  for (a, b) in ranges do
    if b > units then continue
    out := out ++ byteSub text (f0.bpos pos) (f0.bpos a)
    for _ in [a:b] do out := out.push ' '
    pos := b
  out := out ++ byteSub text (f0.bpos pos) text.utf8ByteSize
  return mkFragOf out

end Litedoc4
