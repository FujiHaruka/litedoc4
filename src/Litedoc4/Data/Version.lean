/- One version's own data: what its pages hold in which order, where each name
its content spells resolves in this version, and the whole-package files. -/
import Litedoc4.Config
import Litedoc4.Data.Content
import Litedoc4.External
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
  sources : ExternalLinks
  site : SiteConfig := {}

structure Item where
  private mk ::
  content : Content
  address : ContentAddress
  lines : Option (Nat × Nat)

def Item.of (content : Content) (lines : Option (Nat × Nat)) : Item :=
  { content, address := content.address, lines }

inductive Resolved where
  | own (module : String) (anchor : Option String)
  | dependency (root base module : String) (lines : Option (Nat × Nat))
  deriving BEq, Repr

def resolvedOf : LinkDest → Option Resolved
  | .page module anchor => some (.own module anchor)
  | .source root base module lines => some (.dependency root base module lines)
  /- Not reached: `versionData`'s index carries no documentation site (plan D1b). -/
  | .docs _ => none

structure Page where
  module : String
  imports : Array String
  items : Array Item
  /-- What the page's signatures link to, by `constTarget`'s and
  `declNameToLink`'s rules. -/
  names : Array (String × Resolved)
  /-- What its docstrings link to (`markWord`), by `wordDest`. -/
  words : Array (String × Resolved)

/-- `litedoc4.toml`'s `index`, rendered as a docstring is, against no
bibliography: a citation there would be a back-reference from a page that has no
module. -/
structure FrontPage where
  html : String
  words : Array (String × Resolved)

structure VersionData where
  name : String
  title : String
  pages : Array Page
  front : Option FrontPage
  references : ByteArray
  modules : ByteArray
  search : ByteArray
  instances : ByteArray
  usedBy : Array (String × ByteArray)
  linkNames : Nat
  docTokens : Nat

def modulePath (module : String) : String := "/".intercalate (moduleComponents module).toList

/-- Not the page files: those carry each candidate's own locator. -/
def VersionData.files (v : VersionData) : Array (String × ByteArray) :=
  #[("modules.json", v.modules), ("search-index.bin", v.search), ("instances.json", v.instances)]
    ++ v.usedBy.map fun (module, body) => (s!"used-by/{modulePath module}.json", body)

def namesTable (ix : NameIndex) (spanNames memberNames : Array String) :
    Array (String × Resolved) := Id.run do
  let members : Std.HashSet String := Std.HashSet.ofArray memberNames
  let mut out : Array (String × Resolved) := #[]
  for name in dedupSorted (sortUtf16 (spanNames ++ memberNames)) do
    let target := (constTarget ix {} name).orElse fun _ =>
      if members.contains name then (moduleOf ix name).map (·, some name) else none
    if let some (module, anchor) := target then
      if let some r := (linkDest ix module anchor).bind resolvedOf then
        out := out.push (name, r)
  return out

def wordsTable (c : PageCtx) (words : Array String) : Array (String × Resolved) :=
  (dedupSorted (sortUtf16 words)).filterMap fun w => ((wordDest c w).bind resolvedOf).map (w, ·)

def pageOf (bib : Bibliography) (ix : NameIndex) (m : Module) (sup : Std.HashSet String) :
    Page := Id.run do
  let mut items : Array Item := #[]
  let mut spanNames : Array String := #[]
  let mut memberNames : Array String := #[]
  let mut words : Array String := #[]
  for it in pageItems m sup do
    if it.isDoc then
      let doc := docOf bib m.moduleDocs[it.idx]!.text
      items := items.push (Item.of (moduleDocContent doc) none)
      words := words ++ doc.words
    else
      let d := m.decls[it.idx]!
      let decl := declOf bib m d
      items := items.push (Item.of decl.content (some (d.line, d.endLine)))
      spanNames := spanNames ++ decl.spanNames
      memberNames := memberNames ++ decl.memberNames
      words := words ++ decl.docWords
  return { module := m.name, imports := sortedImports m.imports, items
           names := namesTable ix spanNames memberNames
           words := wordsTable (mkPageCtx ix m) words }

def usedByFiles (d : Derived) : Array (String × ByteArray) := Id.run do
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
          jsonStr (jsonStr (out.push '[') user |>.push ',') (d.nameMap.getD user "") |>.push ']'
      return o.push '}'
    (module, body.toUTF8)

def moduleListOf (d : Derived) : String :=
  moduleListJson d.pages d.importers (·.summary.map (summaryHtml ""))
    s!",\"declarations\":{d.declarations}"

def frontPageOf (ix : NameIndex) (markdown : String) : FrontPage :=
  let doc := docOf {} markdown
  { html := doc.html, words := wordsTable { ix, decls := #[] } doc.words }

def referencesJson (items : Array BibItem) (backrefs : Array Backref) : String :=
  let byKey := backrefsByKey backrefs
  pushEach "" items fun o item =>
    let o := jsonStr (jsonStr (jsonStr (o ++ "{\"key\":") item.citekey ++ ",\"tag\":") item.tag
      ++ ",\"html\":") item.html
    pushEach (o ++ ",\"by\":") (byKey.getD item.citekey #[]) (fun out b =>
      jsonStr (jsonStr (out.push '[') b.module ++ s!",{b.index},") b.citation.funName |>.push ']')
      |>.push '}'

def versionData (v : Input) : VersionData := Id.run do
  let bib := v.site.bibliography
  let facts := v.modules.map (factsOf · "" bib)
  let d := deriveData facts v.depMaps
  let sup := suppressedOf v.modules
  let mut byName : Std.HashMap String Module := {}
  for m in v.modules do byName := byName.insert m.name m
  let sources : ExternalLinks := { roots := v.sources.roots.map ({ · with docs := none }) }
  let ix := buildIndex v.depMaps v.modules v.lidx sources
  let mut pages : Array Page := #[]
  for name in d.modules do
    if let some m := byName.get? name then pages := pages.push (pageOf bib ix m sup)
  return { name := v.name, title := v.site.title.getD (siteTitle d.modules), pages
           front := v.site.indexMarkdown.map (frontPageOf ix)
           references := (referencesJson bib.items (backrefsOf facts)).toUTF8
           modules := (moduleListOf d).toUTF8, search := d.searchIndexBin
           instances := d.instancesJson.toUTF8, usedBy := usedByFiles d
           linkNames := pages.foldl (fun n p => n + p.names.size + p.words.size) 0
           docTokens := (dedupSorted (sortUtf16 (facts.flatMap (·.tokens)))).size }

def pushResolved (out : String) (rootAt : String → Nat) (key : String) : Resolved → String
  | .own module none => jsonStr (out.push '[') module ++ ",null]"
  | .own module (some anchor) =>
    if anchor == key then jsonStr (out.push '[') module |>.push ']'
    else jsonStr (jsonStr (out.push '[') module |>.push ',') anchor |>.push ']'
  | .dependency root _ module lines =>
    let o := jsonStr (out ++ s!"[{rootAt root},") module
    (match lines with
      | some (a, b) => o ++ s!",{a},{b}"
      | none => o).push ']'

def pushTable (out : String) (rootAt : String → Nat) (t : Array (String × Resolved)) :
    String := Id.run do
  let mut o := out.push '{'
  let mut first := true
  for (key, r) in t do
    if !first then o := o.push ','
    first := false
    o := pushResolved (jsonStr o key |>.push ':') rootAt key r
  return o.push '}'

def rootsOf (links : Array (String × Resolved)) : Array String :=
  dedupSorted (sortUtf16 (links.filterMap fun (_, r) => match r with
    | .dependency root .. => some root
    | .own .. => none))

def pageRoots (p : Page) : Array String := rootsOf (p.names ++ p.words)

def VersionData.links (v : VersionData) : Array (String × Resolved) :=
  v.pages.flatMap (fun p => p.names ++ p.words) ++ (v.front.map (·.words)).getD #[]

def versionRoots (links : Array (String × Resolved)) : Array (String × String) := Id.run do
  let mut bases : Std.HashMap String String := {}
  for (_, r) in links do
    if let .dependency root base _ _ := r then bases := bases.insert root base
  return (sortUtf16 (bases.toArray.map (·.1))).map fun root => (root, bases.getD root "")

def pageJson (p : Page) (locator : String) : String := Id.run do
  let roots := pageRoots p
  let rootAt := fun root => (roots.idxOf? root).getD 0
  let mut o := pushStrings (jsonStr "{\"module\":" p.module ++ ",\"imports\":") p.imports
  o := o ++ ",\"content\":" ++ locator
  o := pushEach (o ++ ",\"lines\":") p.items fun out it => match it.lines with
    | some (a, b) => out ++ s!"[{a},{b}]"
    | none => out.push '0'
  o := pushStrings (o ++ ",\"roots\":") roots
  o := pushTable (o ++ ",\"names\":") rootAt p.names
  o := pushTable (o ++ ",\"words\":") rootAt p.words
  return o.push '}'

def frontPageJson (f : FrontPage) : String :=
  let roots := rootsOf f.words
  let rootAt := fun root => (roots.idxOf? root).getD 0
  let o := pushStrings (jsonStr "{\"html\":" f.html ++ ",\"roots\":") roots
  pushTable (o ++ ",\"words\":") rootAt f.words |>.push '}'

end Data
end Litedoc4
