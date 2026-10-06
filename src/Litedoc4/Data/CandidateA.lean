/- Candidate (a): one content file per module per version, all of that page's
items in page order, named by the hash of its bytes, so it is shared only with a
version whose page holds the same items in the same order. -/
import Litedoc4.Data.Layout

namespace Litedoc4
namespace Data
namespace CandidateA

def layout (compress : ByteArray → ByteArray) (vs : Array VersionData) : Except String Layout := do
  discard <| contentTable vs
  let mut files : Array Hosted := #[]
  let mut seen : Std.HashMap String ByteArray := {}
  let mut views : Array View := #[]
  for (v, k) in vs.zipIdx do
    let mut locators : Array String := #[]
    let mut contentFetches : Array (Array Fetch) := #[]
    for p in v.pages do
      if p.items.isEmpty then
        locators := locators.push "null"
        contentFetches := contentFetches.push #[]
      else
        let raw := arrayOf (p.items.map (·.content))
        let path := s!"{contentPrefix}a/{hexAddressOf raw}.json"
        (files, seen) ← addOnce files seen
          { path, raw := raw.size, stored := compress raw, firstVersion := k, items := p.items.size } raw
        locators := locators.push (jsonStr "" path)
        contentFetches := contentFetches.push #[{ path }]
    let (own, fetches) := versionLayout compress k v locators
    files := files ++ own
    for (p, i) in v.pages.zipIdx do
      views := views.push { version := k, module := p.module, items := p.items.size
                            itemsFetched := p.items.size
                            fetches := fetches[i]! ++ contentFetches[i]! }
  return { files, views }

end CandidateA
end Data
end Litedoc4
