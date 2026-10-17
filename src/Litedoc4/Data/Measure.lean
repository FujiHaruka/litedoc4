/- The counters a storage candidate is chosen by, read off its layout without a
browser. -/
import Litedoc4.Data.Layout

namespace Litedoc4
namespace Data

structure Spread where
  total : Nat := 0
  max : Nat := 0
  deriving BEq, Repr

def Spread.add (s : Spread) (n : Nat) : Spread := { total := s.total + n, max := Nat.max s.max n }

structure VersionCounts where
  version : String
  pages : Nat := 0
  items : Nat := 0
  addresses : Nat := 0
  newAddresses : Nat := 0
  linkNames : Nat := 0
  docTokens : Nat := 0
  addedFiles : Nat := 0
  addedRaw : Nat := 0
  addedStored : Nat := 0
  addedContentFiles : Nat := 0
  addedContentItems : Nat := 0
  fetches : Spread := {}
  bytes : Spread := {}
  contentFetches : Spread := {}
  contentBytes : Spread := {}
  itemsFetched : Nat := 0
  deriving BEq, Repr

structure Counts where
  files : Nat
  raw : Nat
  stored : Nat
  versions : Array VersionCounts
  deriving BEq, Repr

def Fetch.bytes (f : Fetch) (sizes : Std.HashMap String Nat) : Nat :=
  match f.range with
  | some (a, b) => b - a
  | none => sizes.getD f.path 0

def counts (vs : Array VersionData) (l : Layout) : Counts := Id.run do
  let mut sizes : Std.HashMap String Nat := {}
  for f in l.files do sizes := sizes.insert f.path f.stored.size
  let mut out : Array VersionCounts := vs.map ({ version := ·.name })
  let mut earlier : Std.HashSet ContentAddress := {}
  for (v, k) in vs.zipIdx do
    let mut own : Std.HashSet ContentAddress := {}
    let mut items := 0
    for p in v.pages do
      for it in p.items do
        own := own.insert it.address
        items := items + 1
    let fresh := own.fold (fun n a => if earlier.contains a then n else n + 1) 0
    earlier := own.fold (·.insert ·) earlier
    out := out.modify k fun c => { c with
      pages := v.pages.size, items, addresses := own.size, newAddresses := fresh
      linkNames := v.linkNames, docTokens := v.docTokens }
  for f in l.files do
    let content := f.path.startsWith contentPrefix
    out := out.modify f.firstVersion fun c => { c with
      addedFiles := c.addedFiles + 1, addedRaw := c.addedRaw + f.raw
      addedStored := c.addedStored + f.stored.size
      addedContentFiles := c.addedContentFiles + (if content then 1 else 0)
      addedContentItems := c.addedContentItems + f.items }
  for view in l.views do
    let content := view.fetches.filter (·.isContent)
    let bytes := view.fetches.foldl (fun n f => n + f.bytes sizes) 0
    let contentBytes := content.foldl (fun n f => n + f.bytes sizes) 0
    out := out.modify view.version fun c => { c with
      fetches := c.fetches.add view.fetches.size, bytes := c.bytes.add bytes
      contentFetches := c.contentFetches.add content.size
      contentBytes := c.contentBytes.add contentBytes
      itemsFetched := c.itemsFetched + view.itemsFetched }
  return { files := l.files.size, raw := l.files.foldl (· + ·.raw) 0
           stored := l.files.foldl (· + ·.stored.size) 0, versions := out }

def Spread.json (s : Spread) : String := s!"\{\"total\":{s.total},\"max\":{s.max}}"

def VersionCounts.json (c : VersionCounts) : String :=
  jsonStr "{\"version\":" c.version
    ++ s!",\"pages\":{c.pages},\"items\":{c.items},\"addresses\":{c.addresses}"
    ++ s!",\"newAddresses\":{c.newAddresses},\"linkNames\":{c.linkNames}"
    ++ s!",\"docTokens\":{c.docTokens}"
    ++ s!",\"added\":\{\"files\":{c.addedFiles},\"rawBytes\":{c.addedRaw}"
    ++ s!",\"storedBytes\":{c.addedStored},\"contentFiles\":{c.addedContentFiles}"
    ++ s!",\"contentItems\":{c.addedContentItems}}"
    ++ s!",\"view\":\{\"fetches\":{c.fetches.json},\"bytes\":{c.bytes.json}"
    ++ s!",\"contentFetches\":{c.contentFetches.json},\"contentBytes\":{c.contentBytes.json}"
    ++ s!",\"itemsFetched\":{c.itemsFetched}}}"

def Counts.json (c : Counts) (candidate : String) (chunkBytes : Option Nat) : String :=
  let chunk := match chunkBytes with
    | some n => s!",\"chunkBytes\":{n}"
    | none => ""
  pushEach (s!"\{\"command\":\"store measure\",\"candidate\":\"{candidate}\"{chunk}"
    ++ s!",\"hosted\":\{\"files\":{c.files},\"rawBytes\":{c.raw},\"storedBytes\":{c.stored}}"
    ++ ",\"versions\":") c.versions (· ++ ·.json) ++ "}"

end Data
end Litedoc4
