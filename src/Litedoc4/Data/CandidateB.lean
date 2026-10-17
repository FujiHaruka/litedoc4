/- Candidate (b): per-module segments. Each version appends to a module one
segment holding only the items no earlier segment of that module holds; a page
fetches every segment one of its items sits in. The versions' order is the order
they are given in. -/
import Litedoc4.Data.Layout

namespace Litedoc4
namespace Data
namespace CandidateB

structure Placed where
  segment : String
  index : Nat
  segmentItems : Nat

def layout (compress : ByteArray → ByteArray) (vs : Array VersionData) : Except String Layout := do
  discard <| contentTable vs
  let mut files : Array Hosted := #[]
  let mut seen : Std.HashMap String ByteArray := {}
  let mut placed : Std.HashMap (String × ContentAddress) Placed := {}
  let mut views : Array View := #[]
  for (v, k) in vs.zipIdx do
    let mut locators : Array String := #[]
    let mut pageFetches : Array (Array Fetch × Nat) := #[]
    for p in v.pages do
      let mut fresh : Array Item := #[]
      for it in p.items do
        if !placed.contains (p.module, it.address) && !fresh.any (·.address == it.address) then
          fresh := fresh.push it
      if !fresh.isEmpty then
        let raw := arrayOf (fresh.map (·.content))
        let path := s!"{contentPrefix}b/{hexAddressOf raw}.json"
        (files, seen) ← addOnce files seen
          { path, raw := raw.size, stored := compress raw, firstVersion := k, items := fresh.size } raw
        for (it, i) in fresh.zipIdx do
          placed := placed.insert (p.module, it.address)
            { segment := path, index := i, segmentItems := fresh.size }
      let mut segments : Array String := #[]
      let mut fetched := 0
      let mut at_ : Array (Nat × Nat) := #[]
      for it in p.items do
        let some place := placed.get? (p.module, it.address)
          | throw s!"{p.module}: an item was never placed"
        let s := match segments.idxOf? place.segment with
          | some s => s
          | none => segments.size
        if s == segments.size then
          segments := segments.push place.segment
          fetched := fetched + place.segmentItems
        at_ := at_.push (s, place.index)
      let mut locator := pushStrings "{\"s\":" segments ++ ",\"i\":["
      for i in [0:at_.size] do
        if i > 0 then locator := locator.push ','
        locator := locator ++ s!"[{at_[i]!.1},{at_[i]!.2}]"
      locators := locators.push (locator ++ "]}")
      pageFetches := pageFetches.push (segments.map ({ path := · }), fetched)
    let (own, fetches) := versionLayout compress k v locators
    files := files ++ own
    for (p, i) in v.pages.zipIdx do
      views := views.push { version := k, module := p.module, items := p.items.size
                            itemsFetched := pageFetches[i]!.2
                            fetches := fetches[i]! ++ pageFetches[i]!.1 }
  return { files, views }

end CandidateB
end Data
end Litedoc4
