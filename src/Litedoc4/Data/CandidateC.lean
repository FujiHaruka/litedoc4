/- Candidate (c): every item stored once across all versions, in one pack per
version holding the items no earlier pack holds, in page order. A pack is a run
of chunks, each compressed on its own and cut once it reaches `chunkBytes` raw
bytes; a page reads the chunks its items sit in by byte range, adjacent chunks of
one pack in one request. A range lists its members' sizes rather than leaving the
reader to find them: a gzip decoder may refuse bytes after a member's end. -/
import Litedoc4.Data.Layout

namespace Litedoc4
namespace Data
namespace CandidateC

/-- Not one compressed member per item: compressing each declaration alone is
3.5× larger than compressing per module. -/
def defaultChunkBytes : Nat := 16384

structure Chunk where
  pack : Nat
  start : Nat
  stop : Nat
  rawSize : Nat
  items : Nat
  deriving Inhabited

structure Place where
  chunk : Nat
  offset : Nat
  length : Nat

structure Pending where
  raw : ByteArray := .empty
  items : Nat := 0
  placed : Array (ContentAddress × Nat × Nat) := #[]

def layout (compress : ByteArray → ByteArray) (chunkBytes : Nat) (vs : Array VersionData) :
    Except String Layout := do
  discard <| contentTable vs
  let mut files : Array Hosted := #[]
  let mut packPaths : Array String := #[]
  let mut chunks : Array Chunk := #[]
  let mut placed : Std.HashMap ContentAddress Place := {}
  let mut views : Array View := #[]
  for (v, k) in vs.zipIdx do
    let pack := packPaths.size
    let mut stored : ByteArray := .empty
    let mut rawAll : ByteArray := .empty
    let mut items := 0
    let mut pending : Pending := {}
    let mut queued : Std.HashSet ContentAddress := {}
    let mut flush : Array Pending := #[]
    for p in v.pages do
      for it in p.items do
        if placed.contains it.address || queued.contains it.address then continue
        queued := queued.insert it.address
        pending := { pending with
          placed := pending.placed.push (it.address, pending.raw.size, it.content.bytes.size)
          raw := pending.raw ++ it.content.bytes, items := pending.items + 1 }
        if pending.raw.size ≥ chunkBytes then
          flush := flush.push pending
          pending := {}
    if pending.items > 0 then flush := flush.push pending
    for c in flush do
      let member := compress c.raw
      let chunk := chunks.size
      chunks := chunks.push { pack, start := stored.size, stop := stored.size + member.size
                              rawSize := c.raw.size, items := c.items }
      for (address, offset, length) in c.placed do
        placed := placed.insert address { chunk, offset, length }
      stored := stored ++ member
      rawAll := rawAll ++ c.raw
      items := items + c.items
    if items > 0 then
      let path := s!"{contentPrefix}c/{hexAddressOf rawAll}.pack"
      packPaths := packPaths.push path
      files := files.push { path, raw := rawAll.size, stored, firstVersion := k, items }
    let mut locators : Array String := #[]
    let mut pageFetches : Array (Array Fetch × Nat) := #[]
    for p in v.pages do
      let mut wanted : Array Nat := #[]
      for it in p.items do
        let some place := placed.get? it.address | throw s!"{p.module}: an item was never placed"
        if !wanted.contains place.chunk then wanted := wanted.push place.chunk
      let sorted := wanted.qsort (· < ·)
      let mut ranges : Array (Nat × Nat) := #[]
      for c in sorted do
        match ranges.back? with
        | some (first, last) =>
          if last + 1 == c && chunks[last]!.pack == chunks[c]!.pack then
            ranges := ranges.pop.push (first, c)
          else ranges := ranges.push (c, c)
        | none => ranges := ranges.push (c, c)
      let rangeOf := fun (c : Nat) => (ranges.findIdx? fun (a, b) => a ≤ c && c ≤ b).getD 0
      let rawBefore := fun (c : Nat) =>
        let (first, _) := ranges[rangeOf c]!
        (List.range (c - first)).foldl (fun n j => n + chunks[first + j]!.rawSize) 0
      let mut locator := pushEach "{\"r\":" ranges fun out (a, b) =>
        let out := jsonStr (out.push '[') packPaths[chunks[a]!.pack]!
          ++ s!",{chunks[a]!.start},{chunks[b]!.stop},"
        pushEach out ((List.range (b + 1 - a)).toArray.map fun j => chunks[a + j]!.stop - chunks[a + j]!.start)
          (fun o n => o ++ toString n) |>.push ']'
      locator := locator ++ ",\"i\":["
      for (it, i) in p.items.zipIdx do
        let some pl := placed.get? it.address | throw s!"{p.module}: an item was never placed"
        if i > 0 then locator := locator.push ','
        locator := locator ++ s!"[{rangeOf pl.chunk},{rawBefore pl.chunk + pl.offset},{pl.length}]"
      locators := locators.push (locator ++ "]}")
      let fetched := sorted.foldl (fun n c => n + chunks[c]!.items) 0
      pageFetches := pageFetches.push (ranges.map fun (a, b) =>
        { path := packPaths[chunks[a]!.pack]!, range := some (chunks[a]!.start, chunks[b]!.stop) },
        fetched)
    let (own, fetches) := versionLayout compress k v locators
    files := files ++ own
    for (p, i) in v.pages.zipIdx do
      views := views.push { version := k, module := p.module, items := p.items.size
                            itemsFetched := pageFetches[i]!.2
                            fetches := fetches[i]! ++ pageFetches[i]!.1 }
  return { files, views }

end CandidateC
end Data
end Litedoc4
