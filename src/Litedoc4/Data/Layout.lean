/- What a storage candidate answers: the files a host holds, and what each module
page of each version fetches from them. -/
import Litedoc4.Data.Version

namespace Litedoc4
namespace Data

structure Fetch where
  path : String
  range : Option (Nat × Nat) := none
  deriving BEq, Repr

structure Hosted where
  path : String
  raw : Nat
  stored : ByteArray
  firstVersion : Nat
  items : Nat := 0

structure View where
  version : Nat
  module : String
  items : Nat
  itemsFetched : Nat
  fetches : Array Fetch

structure Layout where
  files : Array Hosted
  views : Array View

def contentPrefix : String := "content/"

def Fetch.isContent (f : Fetch) : Bool := f.path.startsWith contentPrefix

def versionPath (v : VersionData) (file : String) : String := v.name ++ "/" ++ file

def manifestPath (v : VersionData) (p : Page) : String :=
  versionPath v s!"m/{modulePath p.module}.json"

def versionLayout (compress : ByteArray → ByteArray) (k : Nat) (v : VersionData)
    (locators : Array String) : Array Hosted × Array (Array Fetch) := Id.run do
  let mut files : Array Hosted := #[]
  for (path, bytes) in v.files do
    files := files.push { path := versionPath v path, raw := bytes.size, stored := compress bytes
                          firstVersion := k }
  let mut fetches : Array (Array Fetch) := #[]
  for (p, i) in v.pages.zipIdx do
    let manifest := (manifestJson p (locators.getD i "null")).toUTF8
    files := files.push { path := manifestPath v p, raw := manifest.size
                          stored := compress manifest, firstVersion := k }
    fetches := fetches.push #[{ path := manifestPath v p }, { path := versionPath v "links.json" },
      { path := versionPath v "modules.json" }]
  return (files, fetches)

def arrayOf (items : Array Content) : ByteArray := Id.run do
  let mut out := ByteArray.mk #[91]
  let mut first := true
  for c in items do
    if !first then out := out.push 44
    first := false
    out := out ++ c.bytes
  return out.push 93

/-- Refused rather than keeping either: the same path with other bytes is two
contents under one address. -/
def addOnce (files : Array Hosted) (seen : Std.HashMap String ByteArray) (file : Hosted)
    (raw : ByteArray) : Except String (Array Hosted × Std.HashMap String ByteArray) :=
  match seen.get? file.path with
  | some before =>
    if before == raw then .ok (files, seen)
    else .error s!"{file.path}: two different contents hash to one address"
  | none => .ok (files.push file, seen.insert file.path raw)

def contentTable (vs : Array VersionData) :
    Except String (Std.HashMap ContentAddress Content) := do
  let mut table : Std.HashMap ContentAddress Content := {}
  for v in vs do
    for p in v.pages do
      for it in p.items do
        match table.get? it.address with
        | some c =>
          if c.bytes != it.content.bytes then
            throw s!"{it.address.hex}: two different contents hash to one address"
        | none => table := table.insert it.address it.content
  return table

end Data
end Litedoc4
