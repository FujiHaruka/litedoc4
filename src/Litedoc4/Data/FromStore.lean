/- A store entry, as the data format's input, read in memory. -/
import Litedoc4.Data.Version
import Litedoc4.Store

namespace Litedoc4
namespace Data

def inputOf (r : Store.Record) (files : Array (String × ByteArray)) : Except String Input := do
  let .recorded sources := r.sources | throw (Store.needsReputRefusal r.version)
  let mut byPath : Std.HashMap String ByteArray := {}
  for (path, bytes) in files do byPath := byPath.insert path bytes
  let text := fun (path : String) => do
    let some bytes := byPath.get? path | throw s!"the entry holds no `{path}`"
    let some s := String.fromUTF8? bytes | throw s!"`{path}` is not UTF-8"
    pure s
  let parse := fun (path : String) => do
    match parseJson (← text path) with
    | .ok j => pure j
    | .error why => throw s!"parsing `{path}`: {why}"
  let index ← toIndex (← parse s!"{Store.irPrefix}index.json")
  if index.schemaVersion < minSchemaVersion then
    throw (schemaRefusal "index.json" index.schemaVersion)
  let mut modules : Array Module := #[]
  for e in index.modules do
    let path := Store.irPrefix ++ e.file
    let m ← match parseModule (← text path) with
      | .ok m => pure m
      | .error why => throw s!"parsing `{path}`: {why}"
    if m.schemaVersion < minSchemaVersion then throw (schemaRefusal path m.schemaVersion)
    if m.name != e.module then throw (mismatchRefusal path e.module m.name)
    modules := modules.push m
  let mut depMaps : Array (Array (String × String)) := #[]
  for e in index.dependencyMaps do
    depMaps := depMaps.push (depMapOf (← parse (Store.irPrefix ++ e.file)))
  return { name := r.version.text, modules, depMaps
           lidx := parseLidx (← text Store.linkIndexEntry)
           sources := Store.linksOf sources }

end Data
end Litedoc4
