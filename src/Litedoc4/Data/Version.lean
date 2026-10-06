/- One version's own data: what its pages hold in which order, where each name
its content spells resolves in this version, and the whole-package files. -/
import Litedoc4.Data.Content
import Litedoc4.Global.Artifacts
import Litedoc4.Render.Frame
import Litedoc4.Render.LinkIndex

namespace Litedoc4
namespace Data

structure Input where
  name : String
  modules : Array Module
  depMaps : Array (Array (String × String))
  lidx : Lidx
  sources : Array (String × String)

structure Item where
  private mk ::
  content : Content
  address : ContentAddress
  lines : Option (Nat × Nat)

def Item.of (content : Content) (lines : Option (Nat × Nat)) : Item :=
  { content, address := content.address, lines }

structure Page where
  module : String
  imports : Array String
  items : Array Item

structure VersionData where
  name : String
  pages : Array Page
  /-- Not the manifests: those carry each candidate's own locator. -/
  files : Array (String × ByteArray)
  linkNames : Nat
  docTokens : Nat

def modulePath (module : String) : String := "/".intercalate (moduleComponents module).toList

structure PageBuild where
  page : Page
  spanNames : Array String
  memberNames : Array String

def pageOf (m : Module) (sup : Std.HashSet String) : PageBuild :=
  Id.run do
    let mut items : Array Item := #[]
    let mut spanNames : Array String := #[]
    let mut memberNames : Array String := #[]
    for it in pageItems m sup do
      if it.isDoc then items := items.push (Item.of (moduleDocContent m.moduleDocs[it.idx]!.text) none)
      else
        let d := m.decls[it.idx]!
        let decl := declOf m d
        items := items.push (Item.of decl.content (some (d.line, d.endLine)))
        spanNames := spanNames ++ decl.spanNames
        memberNames := memberNames ++ decl.memberNames
    return { page := { module := m.name, imports := sortedImports m.imports, items }, spanNames, memberNames }

inductive Resolved where
  | own (module : Nat) (anchor : Option String)
  | dependency (module : String) (source : Nat) (lines : Option (Nat × Nat))

def rootOf (module : String) : String := (moduleComponents module)[0]!

structure LinkTable where
  sources : Array (String × Option String)
  names : Array (String × Resolved)

def linkTable (ix : NameIndex) (moduleAt : Std.HashMap String Nat)
    (sources : Array (String × String)) (spanNames memberNames : Array String) : LinkTable :=
  Id.run do
    let members : Std.HashSet String := Std.HashSet.ofArray memberNames
    let all := dedupSorted (sortUtf16 (spanNames ++ memberNames))
    let mut targets : Array (String × (String × Option String)) := #[]
    let mut roots : Array String := #[]
    for name in all do
      let target := (constTarget ix {} name).orElse fun _ =>
        if members.contains name then (moduleOf ix name).map (·, some name) else none
      if let some (module, anchor) := target then
        targets := targets.push (name, (module, anchor))
        if !moduleAt.contains module then roots := roots.push (rootOf module)
    let sorted := dedupSorted (sortUtf16 roots)
    let mut rootAt : Std.HashMap String Nat := {}
    for i in [0:sorted.size] do rootAt := rootAt.insert sorted[i]! i
    let names := targets.map fun (name, (module, anchor)) =>
      match moduleAt.get? module with
      | some k => (name, Resolved.own k anchor)
      | none => (name, Resolved.dependency module (rootAt.getD (rootOf module) 0)
          (anchor.bind ix.lidx.rangeOf))
    let base := fun root => (sources.find? (·.1 == root)).map (·.2)
    return { sources := sorted.map fun root => (root, base root), names }

def LinkTable.json (t : LinkTable) : String := Id.run do
  let mut o := pushEach "{\"sources\":" t.sources fun out (root, base) =>
    let out := jsonStr (out.push '[') root |>.push ','
    (match base with
      | some b => jsonStr out b
      | none => out ++ "null").push ']'
  o := o ++ ",\"names\":{"
  let mut first := true
  for (name, resolved) in t.names do
    if !first then o := o.push ','
    first := false
    o := jsonStr o name |>.push ':'
    o := match resolved with
      | .own k none => o ++ s!"[{k},null]"
      | .own k (some anchor) => if anchor == name then o ++ s!"[{k}]"
          else jsonStr (o ++ s!"[{k},") anchor |>.push ']'
      | .dependency module source lines =>
        let o := jsonStr (o.push '[') module ++ s!",{source}"
        (match lines with
          | some (a, b) => o ++ s!",{a},{b}"
          | none => o).push ']'
  return o ++ "}}"

def usedByFiles (d : Derived) (moduleAt : Std.HashMap String Nat) :
    Array (String × ByteArray) := Id.run do
  let mut byModule : Std.HashMap String (Array (String × Array String)) := {}
  for (target, users) in d.usedByPairs do
    if let some module := d.nameMap.get? target then
      byModule := byModule.insert module ((byModule.getD module #[]).push (target, users))
  return d.modules.map fun module =>
    let pairs := byModule.getD module #[]
    let body := Id.run do
      let mut o := "{"
      for i in [0:pairs.size] do
        let (target, users) := pairs[i]!
        if i > 0 then o := o.push ','
        o := pushEach (jsonStr o target |>.push ':') users fun out user =>
          let k := moduleAt.getD (d.nameMap.getD user "") 0
          jsonStr (out.push '[') user ++ s!",{k}]"
      return o.push '}'
    (s!"used-by/{modulePath module}.json", body.toUTF8)

def versionData (v : Input) : VersionData := Id.run do
  let facts := v.modules.map (factsOf · "" {})
  let d := deriveData facts v.depMaps
  let mut moduleAt : Std.HashMap String Nat := {}
  for i in [0:d.modules.size] do moduleAt := moduleAt.insert d.modules[i]! i
  let sup := suppressedOf v.modules
  let mut byName : Std.HashMap String Module := {}
  for m in v.modules do byName := byName.insert m.name m
  let mut pages : Array Page := #[]
  let mut spanNames : Array String := #[]
  let mut memberNames : Array String := #[]
  for name in d.modules do
    if let some m := byName.get? name then
      let built := pageOf m sup
      pages := pages.push built.page
      spanNames := spanNames ++ built.spanNames
      memberNames := memberNames ++ built.memberNames
  let ix := buildIndex v.depMaps v.modules v.lidx {}
  let links := linkTable ix moduleAt v.sources spanNames memberNames
  let files := #[("modules.json", d.modulesJson.toUTF8), ("links.json", links.json.toUTF8),
    ("search-index.bin", d.searchIndexBin), ("instances.json", d.instancesJson.toUTF8)]
    ++ usedByFiles d moduleAt
  return { name := v.name, pages, files, linkNames := links.names.size
           docTokens := (dedupSorted (sortUtf16 (facts.flatMap (·.tokens)))).size }

def manifestJson (p : Page) (locator : String) : String := Id.run do
  let mut o := pushStrings (jsonStr "{\"module\":" p.module ++ ",\"imports\":") p.imports
  o := pushEach (o ++ ",\"items\":") p.items fun out it =>
    let out := jsonStr (out.push '[') it.address.hex
    (match it.lines with
      | some (a, b) => out ++ s!",{a},{b}"
      | none => out).push ']'
  return o ++ ",\"content\":" ++ locator ++ "}"

end Data
end Litedoc4
