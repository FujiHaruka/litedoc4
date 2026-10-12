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

def bytesText (path : String) : Option ByteArray → Except String String
  | none => throw s!"the entry holds no `{path}`"
  | some bytes => match String.fromUTF8? bytes with
    | some s => pure s
    | none => throw s!"`{path}` is not UTF-8"

def textAt (byPath : Std.HashMap String ByteArray) (path : String) : Except String String :=
  bytesText path (byPath.get? path)

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

-- Not a closure over `byPath`: the loader would hold every module's bytes until the last page is built.
structure StoredModule where
  path : String
  module : String
  bytes : Option ByteArray

def StoredModule.of (byPath : Std.HashMap String ByteArray) (e : IndexEntry) : StoredModule :=
  let path := Store.irPrefix ++ e.file
  { path, module := e.module, bytes := byPath.get? path }

def StoredModule.load (s : StoredModule) (_ : Unit) : Except String Module := do
  let m ← match parseModule (← bytesText s.path s.bytes) with
    | .ok m => pure m
    | .error why => throw s!"parsing `{s.path}`: {why}"
  if m.schemaVersion < minSchemaVersion then throw (schemaRefusal s.path m.schemaVersion)
  if m.name != s.module then throw (mismatchRefusal s.path s.module m.name)
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
  let stored := o.index.modules.map (StoredModule.of o.byPath)
  o.finish (stored.map StoredModule.load)

end Data
end Litedoc4
