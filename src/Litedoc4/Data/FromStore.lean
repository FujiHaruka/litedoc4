/- A store entry, as the data format's input, read in memory. -/
import Litedoc4.Data.Version
import Litedoc4.Store

namespace Litedoc4
namespace Data

structure Opened where
  record : Store.Record
  checkout : Store.FromCheckout
  files : Array (String × ByteArray)
  byPath : Std.HashMap String ByteArray
  index : Index
  pages : Option SitePages

def textAt (byPath : Std.HashMap String ByteArray) (path : String) : Except String String := do
  let some bytes := byPath.get? path | throw s!"the entry holds no `{path}`"
  let some s := String.fromUTF8? bytes | throw s!"`{path}` is not UTF-8"
  pure s

def parseAt (byPath : Std.HashMap String ByteArray) (path : String) : Except String JVal := do
  match parseJson (← textAt byPath path) with
  | .ok j => pure j
  | .error why => throw s!"parsing `{path}`: {why}"

def openEntry (r : Store.Record) (files : Array (String × ByteArray))
    (pages : Option SitePages := none) : Except String Opened := do
  let checkout ← Store.checkoutOf r
  let mut byPath : Std.HashMap String ByteArray := {}
  for (path, bytes) in files do byPath := byPath.insert path bytes
  let index ← toIndex (← parseAt byPath s!"{Store.irPrefix}index.json")
  if index.schemaVersion < minSchemaVersion then
    throw (schemaRefusal "index.json" index.schemaVersion)
  return { record := r, checkout, files, byPath, index, pages }

def Opened.module (o : Opened) (e : IndexEntry) : Except String Module := do
  let path := Store.irPrefix ++ e.file
  let m ← match parseModule (← textAt o.byPath path) with
    | .ok m => pure m
    | .error why => throw s!"parsing `{path}`: {why}"
  if m.schemaVersion < minSchemaVersion then throw (schemaRefusal path m.schemaVersion)
  if m.name != e.module then throw (mismatchRefusal path e.module m.name)
  return m

def Opened.finish (o : Opened) (modules : Array (Unit → Except String Module)) :
    Except String Input := do
  let mut depMaps : Array (Array (String × String)) := #[]
  for e in o.index.dependencyMaps do
    depMaps := depMaps.push (depMapOf (← parseAt o.byPath (Store.irPrefix ++ e.file)))
  let stored ← Store.siteSourcesOf o.checkout.title o.files
  let site ← (o.pages.elim stored stored.withPages).config Store.bibliographyEntry
  return { name := o.record.version.text, modules, depMaps
           lidx := parseLidx (← textAt o.byPath Store.linkIndexEntry)
           sources := Store.linksOf o.checkout.sources, site }

def inputOf (r : Store.Record) (files : Array (String × ByteArray))
    (pages : Option SitePages := none) : Except String Input := do
  let o ← openEntry r files pages
  o.finish (o.index.modules.map fun e _ => o.module e)

end Data
end Litedoc4
