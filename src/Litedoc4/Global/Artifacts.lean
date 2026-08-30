/- `crates/litedoc4-global/src/artifacts.rs`: the whole-package artifacts.

**Every sort here goes through `cmpUtf16`**, including in the files nothing
compares against anything: byte order agrees with UTF-16 throughout the BMP and
inverts at U+10000, and a site with two orders in it is a site whose order is
nobody's. -/
import Std.Data.HashSet
import Litedoc4.Global.Entry
import Litedoc4.Global.Facts
import Litedoc4.JsonWrite
import Litedoc4.Ir.Name

namespace Litedoc4

/-- The renderer's path rule, as a **URL** path, so the separator is `/` on every
platform. It has to be the rule `pagePath` writes the page with: a disagreement
is not a wrong file but an index pointing at pages that were never written. -/
def pageUrl (module : String) : String :=
  String.intercalate "/" (moduleComponents module).toList ++ ".html"

/-- Case-insensitive, and against the source rather than the rendered text: a
heading of `` `Math` `` on `Pkg.Math` is not caught, which keeps this a count
that means one thing and never a claim that it found them all. -/
def eqIgnoreAsciiCase (a b : String) : Bool := Id.run do
  let n := a.utf8ByteSize
  if n != b.utf8ByteSize then return false
  let lower := fun (c : UInt8) => if c ≥ 65 && c ≤ 90 then c + 32 else c
  let mut i := 0
  while i < n do
    if lower (byteAt a i) != lower (byteAt b i) then return false
    i := i + 1
  return true

def echoesTheName (row : ModuleRow) : Bool :=
  match row.summary with
  | none => false
  | some summary => eqIgnoreAsciiCase summary (components row.name).back!

structure Counts where
  declarations : Nat := 0
  dependencyNames : Nat := 0
  instanceClasses : Nat := 0
  instanceTypes : Nat := 0
  usedByTargets : Nat := 0
  usedByEdges : Nat := 0
  summariesRendered : Nat := 0
  summariesEchoingTheName : Nat := 0
  deriving Inhabited

structure Artifacts where
  nameMapJson : String := ""
  indexHtml : String := ""
  notFoundHtml : String := ""
  searchHtml : String := ""
  foundationalTypesHtml : String := ""
  modulesJson : String := ""
  instancesJson : String := ""
  usedByJson : String := ""
  counts : Counts := {}
  deriving Inhabited

/-- `{ key: [name, …] }` with both levels in UTF-16 order and the names
deduplicated. The deduplication is doc-gen4's rule: it collects each list into an
`RBTree`, so an instance whose class application names the same type twice
appears once. -/
def nameListPairs (m : Std.HashMap String (Array String)) : Array (String × Array String) :=
  Id.run do
    let mut keys : Array String := Array.mkEmpty m.size
    for (k, _) in m do keys := keys.push k
    let mut out : Array (String × Array String) := Array.mkEmpty keys.size
    for k in sortUtf16 keys do
      out := out.push (k, dedupSorted (sortUtf16 (m.getD k #[])))
    return out

def nameListsJson (pairs : Array (String × Array String)) : String := Id.run do
  let mut out := "{"
  let mut first := true
  for (key, names) in pairs do
    if !first then out := out.push ','
    first := false
    out := (jsonStr out key).push ':'
    out := out.push '['
    let mut firstName := true
    for name in names do
      if !firstName then out := out.push ','
      firstName := false
      out := jsonStr out name
    out := out.push ']'
  return out.push '}'

/-- **Index order is behaviour, twice.** Two modules declaring the same name
leave the later one in the map, and a module's importer list is built in it
(before being sorted). Passing the facts in any other order is a different
answer. -/
def derive (facts : Array ModuleFacts) (depMaps : Array (Array (String × String)))
    (intro : Option String) (leanVersion : String) : Artifacts := Id.run do
  let mut nameMap : Std.HashMap String (String × String) := Std.HashMap.emptyWithCapacity 4096
  let mut instances : Std.HashMap String (Array String) := Std.HashMap.emptyWithCapacity 256
  let mut instancesFor : Std.HashMap String (Array String) := Std.HashMap.emptyWithCapacity 256
  for f in facts do
    for (name, kind) in f.decls do
      nameMap := nameMap.insert name (f.module, kind)
    for (cls, name) in f.instances do
      instances := instances.insert cls ((instances.getD cls #[]).push name)
    for (ty, name) in f.instancesFor do
      instancesFor := instancesFor.insert ty ((instancesFor.getD ty #[]).push name)

  let mut own : Std.HashSet String := Std.HashSet.emptyWithCapacity facts.size
  for f in facts do own := own.insert f.module
  let mut importedBy : Std.HashMap String (Array String) :=
    Std.HashMap.emptyWithCapacity facts.size
  for m in own do importedBy := importedBy.insert m #[]
  for f in facts do
    for import_ in f.imports do
      -- Imports of packages outside this one are dropped: the artifact is
      -- "who in *this* package imports me".
      match importedBy.get? import_ with
      | some importers => importedBy := importedBy.insert import_ (importers.push f.module)
      | none => pure ()

  let mut ownNames : Array String := Array.mkEmpty own.size
  for m in own do ownNames := ownNames.push m
  let ownSorted := sortUtf16 ownNames
  let mut summaries : Std.HashMap String String := Std.HashMap.emptyWithCapacity facts.size
  for f in facts do
    match f.summary with
    | some s => summaries := summaries.insert f.module s
    | none => pure ()
  let pages : Array ModuleRow := ownSorted.map fun m =>
    { name := m, page := pageUrl m, summary := summaries.get? m }
  let mut indexAt : Std.HashMap String Nat := Std.HashMap.emptyWithCapacity ownSorted.size
  for i in [0:ownSorted.size] do indexAt := indexAt.insert ownSorted[i]! i

  let mut deps : Std.HashMap String String := Std.HashMap.emptyWithCapacity 4096
  for map in depMaps do
    for (name, module) in map do deps := deps.insert name module

  let mut declNames : Array String := Array.mkEmpty nameMap.size
  for (k, _) in nameMap do declNames := declNames.push k
  let sortedNames := sortUtf16 declNames
  let mut depKeys : Array String := Array.mkEmpty deps.size
  for (k, _) in deps do depKeys := depKeys.push k
  let depNames := sortUtf16 depKeys

  -- The two lists are concatenated *before* sorting, so a name in both appears
  -- twice and a declaration always wins over a dependency slice.
  let merged := sortUtf16 (sortedNames ++ depNames)
  let mut nameMapJson := "{"
  let mut previous : Option String := none
  let mut firstName := true
  for name in merged do
    if previous == some name then continue
    previous := some name
    let module := match nameMap.get? name with
      | some (module, _) => module
      | none => deps.getD name ""
    if !firstName then nameMapJson := nameMapJson.push ','
    firstName := false
    nameMapJson := (jsonStr nameMapJson name).push ':'
    nameMapJson := jsonStr nameMapJson module
  nameMapJson := nameMapJson.push '}'

  let mut modulesJson := "{\"modules\":["
  for i in [0:pages.size] do
    let row := pages[i]!
    if i != 0 then modulesJson := modulesJson.push ','
    modulesJson := modulesJson ++ "{\"n\":"
    modulesJson := jsonStr modulesJson row.name
    modulesJson := modulesJson ++ ",\"p\":"
    modulesJson := jsonStr modulesJson row.page
    modulesJson := modulesJson ++ ",\"i\":["
    -- Subscripts into this same array, and **the direction is the whole
    -- point**: `i` is who imports *this* module, so a page's "Imported by"
    -- block is a lookup rather than a scan of every module.
    let mut previousAt : Option Nat := none
    let mut firstImporter := true
    for importer in sortUtf16 (importedBy.getD row.name #[]) do
      let k := indexAt.getD importer 0
      if previousAt == some k then continue
      previousAt := some k
      if !firstImporter then modulesJson := modulesJson.push ','
      firstImporter := false
      modulesJson := modulesJson ++ toString k
    modulesJson := modulesJson ++ "]}"
  modulesJson := modulesJson ++ "]}"

  -- Inverted **after** `nameMap` is complete, because the filter is "does this
  -- package declare the target" and that is not known until every module has
  -- contributed: a module early in index order refers to names later ones
  -- declare.
  let mut usedBy : Std.HashMap String (Array String) := Std.HashMap.emptyWithCapacity 4096
  for f in facts do
    for (target, users) in f.refs do
      if !nameMap.contains target then continue
      let mut entry := usedBy.getD target #[]
      for user in users do
        if user < f.decls.size then entry := entry.push f.decls[user]!.1
      usedBy := usedBy.insert target entry

  let usedByPairs := nameListPairs usedBy
  let title := siteTitle ownSorted
  return {
    nameMapJson
    indexHtml := indexHtml title intro pages sortedNames.size leanVersion
    notFoundHtml := notFoundHtml title
    searchHtml := searchHtml title
    foundationalTypesHtml := foundationalTypesHtml title
    modulesJson
    instancesJson :=
      "{\"instances\":" ++ nameListsJson (nameListPairs instances)
        ++ ",\"instancesFor\":" ++ nameListsJson (nameListPairs instancesFor) ++ "}"
    usedByJson := nameListsJson usedByPairs
    counts := {
      declarations := sortedNames.size
      dependencyNames := depNames.size
      instanceClasses := instances.size
      instanceTypes := instancesFor.size
      usedByTargets := usedBy.size
      -- Counted the way the file spells it — after the per-key dedup, not
      -- before. Two declarations of one module that mention the same name are
      -- one user.
      usedByEdges := usedByPairs.foldl (fun acc p => acc + p.2.size) 0
      summariesRendered := (pages.filter (·.summary.isSome)).size
      summariesEchoingTheName := (pages.filter echoesTheName).size } }

/-- Paired with the paths they go to, in `ARTIFACT_PATHS` order.

Eight of the nine. `search-index.bin` is the rest of M3 and is not written yet;
its place is between `modules.json` and `instances.json`. -/
def artifactFiles (a : Artifacts) : Array (String × String) :=
  #[("declarations/name-map.json", a.nameMapJson),
    ("index.html", a.indexHtml),
    ("404.html", a.notFoundHtml),
    ("search.html", a.searchHtml),
    ("foundational_types.html", a.foundationalTypesHtml),
    ("modules.json", a.modulesJson),
    ("instances.json", a.instancesJson),
    ("declarations/used-by.json", a.usedByJson)]

end Litedoc4
