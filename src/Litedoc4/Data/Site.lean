/- The site `store render` writes from a store: every data file once, under the
address of its bytes, and per version one shell per page that names the
addresses its page needs. -/
import Litedoc4.Assets
import Litedoc4.Data.FromStore
import Litedoc4.Data.Layout
import Litedoc4.Fs
import Litedoc4.Gzip
import Litedoc4.Md.Escape

open System

namespace Litedoc4
namespace Data
namespace Site

structure DataFile where
  private mk ::
  address : String
  ext : String
  raw : ByteArray
  what : String

def DataFile.of (ext what : String) (raw : ByteArray) : DataFile :=
  { address := hexAddressOf raw, ext, raw, what }

def DataFile.path (f : DataFile) : String := s!"d/{f.address}.{f.ext}.gz"

/-- The address, not the path `store measure`'s candidates name: the key a
locator sits under already says the kind, and so the extension. -/
def locator (f : DataFile) : String := jsonStr "" f.address

def compressed (raw : ByteArray) : ByteArray := Gzip.compress 6 raw

structure VersionMeta where
  commit : String
  lean : String
  source : String

def VersionMeta.of (r : Store.Record) : VersionMeta :=
  { commit := r.commit, lean := r.leanVersion, source := r.sourceUrl }

def versionFileJson (version title : String) (m : VersionMeta) (roots : Array (String × String))
    (modules search instances references : DataFile) (front : Option DataFile) : String :=
    Id.run do
  let mut o := jsonStr "{\"version\":" version
  o := jsonStr (o ++ ",\"title\":") title
  o := jsonStr (o ++ ",\"commit\":") m.commit
  o := jsonStr (o ++ ",\"lean\":") m.lean
  o := jsonStr (o ++ ",\"source\":") m.source
  o := o ++ ",\"roots\":{"
  for ((root, base), i) in roots.zipIdx do
    if i > 0 then o := o.push ','
    o := jsonStr (jsonStr o root |>.push ':') base
  o := o ++ "},\"modules\":" ++ locator modules ++ ",\"search\":" ++ locator search
    ++ ",\"instances\":" ++ locator instances ++ ",\"references\":" ++ locator references
    ++ ",\"front\":" ++ ((front.map locator).getD "null")
  return o.push '}'

def rootAt (depth : Nat) : String :=
  if depth == 0 then "./" else String.join (List.replicate depth "../")

def assetsDir : String := "assets/"

def drawnByScript : String :=
  "<noscript>These pages are drawn by JavaScript, which is off.</noscript>"

def shell (title : Option String) (depth : Nat) (attrs : Array (String × String))
    (body : String := drawnByScript) : String := Id.run do
  let root := rootAt depth
  let assets := root ++ assetsDir
  let mut o := "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n\
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
  if let some t := title then o := escapeInto (o ++ "<title>") t ++ "</title>\n"
  o := escapeInto (o ++ "<link rel=\"stylesheet\" href=\"") (assets ++ "style.css") ++ "\">\n"
  o := escapeInto (o ++ "<link rel=\"icon\" href=\"") (assets ++ "favicon.svg") ++ "\">\n"
  o := o ++ "<script>" ++ themeBootJs ++ "</script>\n"
  o := escapeInto (o ++ "<script type=\"module\" src=\"") (assets ++ "site.js")
    ++ "\"></script>\n</head>\n<body data-root=\""
  o := escapeInto o root |>.push '"'
  for (key, value) in attrs do
    o := escapeInto (o ++ s!" data-{key}=\"") value |>.push '"'
  return o ++ ">" ++ body ++ "</body>\n</html>\n"

def shellPath (version module : String) : String := s!"{version}/{modulePath module}.html"

def moduleShell (version module : String) (versionFile page usedBy : DataFile) : String :=
  shell (some module) (moduleComponents module).size
    #[("version", version), ("module", module), ("data", versionFile.address),
      ("page", page.address), ("used-by", usedBy.address)]

def versionIndexShell (version : String) (versionFile : DataFile) : String :=
  shell none 1 #[("version", version), ("data", versionFile.address)]

/-- At the path a citation's `references.html#ref_<key>` reaches from the
version's root (`markWord`). -/
def referencesShell (version : String) (versionFile references : DataFile) : String :=
  shell (some "References") 1
    #[("version", version), ("data", versionFile.address), ("references", references.address)]

/-- Not a data file: the text is every version's, and in the shell it costs no
fetch and reads without JavaScript. -/
def searchShell (version : String) (versionFile : DataFile) : String :=
  shell (some "Search") 1
    #[("version", version), ("data", versionFile.address), ("kind", "search")] searchBody

def foundationalTypesShell (version : String) (versionFile : DataFile) : String :=
  shell (some "Foundational types") 1
    #[("version", version), ("data", versionFile.address), ("kind", "foundational")]
    foundationalTypesBody

def searchPage : String := "search.html"

def foundationalTypesPage : String := "foundational_types.html"

/-- The newest version's, so the site root can draw it without `versions.json`. -/
def siteIndexShell (newest : String) (newestFile : String) : String :=
  shell none 0 #[("version", newest), ("data", newestFile)]

def versionsJson (entries : Array (String × String)) : String :=
  pushEach "" entries fun o (name, address) =>
    jsonStr (jsonStr (o ++ "{\"name\":") name ++ ",\"data\":") address |>.push '}'

structure Rendered where
  versionFile : DataFile
  data : Array DataFile
  shells : Array (String × String)

def render (m : VersionMeta) (v : VersionData) : Except String Rendered := do
  let usedBy : Std.HashMap String ByteArray := Std.HashMap.ofList v.usedBy.toList
  let modules := DataFile.of "json" s!"{v.name}'s module list" v.modules
  let search := DataFile.of "bin" s!"{v.name}'s search index" v.search
  let instances := DataFile.of "json" s!"{v.name}'s instances" v.instances
  let references := DataFile.of "json" s!"{v.name}'s references" v.references
  let front := v.front.map fun f =>
    DataFile.of "json" s!"{v.name}'s front page" (frontPageJson f).toUTF8
  let versionFile := DataFile.of "json" s!"{v.name}'s version file"
    (versionFileJson v.name v.title m (versionRoots v.links) modules search instances references
      front).toUTF8
  let mut data := #[modules, search, instances, references] ++ front.toArray ++ #[versionFile]
  let mut shells := #[(s!"{v.name}/index.html", versionIndexShell v.name versionFile),
    (s!"{v.name}/{referencesPage}", referencesShell v.name versionFile references),
    (s!"{v.name}/{searchPage}", searchShell v.name versionFile),
    (s!"{v.name}/{foundationalTypesPage}", foundationalTypesShell v.name versionFile)]
  for p in v.pages do
    let content := if p.items.isEmpty then none else
      some (DataFile.of "json" s!"{v.name}'s content of {p.module}" (arrayOf (p.items.map (·.content))))
    let page := DataFile.of "json" s!"{v.name}'s page file of {p.module}"
      (pageJson p ((content.map locator).getD "null")).toUTF8
    let some body := usedBy.get? p.module | throw s!"{v.name}: {p.module} has a page and no Used by"
    let used := DataFile.of "json" s!"{v.name}'s Used by of {p.module}" body
    data := data ++ content.toArray ++ #[page, used]
    shells := shells.push (shellPath v.name p.module, moduleShell v.name p.module versionFile page used)
  return { versionFile, data, shells }

/-! ## On disk -/

structure Tally where
  files : Nat := 0
  raw : Nat := 0
  stored : Nat := 0
  deriving BEq, Repr

def Tally.add (t : Tally) (raw stored : Nat) : Tally :=
  { files := t.files + 1, raw := t.raw + raw, stored := t.stored + stored }

def Tally.plus (a b : Tally) : Tally :=
  { files := a.files + b.files, raw := a.raw + b.raw, stored := a.stored + b.stored }

def Tally.json (t : Tally) : String :=
  s!"\{\"files\":{t.files},\"rawBytes\":{t.raw},\"storedBytes\":{t.stored}}"

structure VersionCounts where
  version : String
  modules : Nat
  shells : Tally
  referenced : Nat
  added : Tally

def VersionCounts.json (c : VersionCounts) : String :=
  jsonStr "{\"version\":" c.version ++ s!",\"modules\":{c.modules},\"shells\":{c.shells.json}"
    ++ s!",\"dataReferenced\":{c.referenced},\"dataAdded\":{c.added.json}}"

def writeText (out : FilePath) (path body : String) : IO Tally := do
  writeFile (out / path) body
  return Tally.add {} body.utf8ByteSize body.utf8ByteSize

/-- Compared, not skipped because the name exists: two contents under one
address would otherwise ship whichever was written first. -/
def writeData (out : FilePath) (f : DataFile) : ExceptT String IO (Option Tally) := do
  let stored := compressed f.raw
  let target := out / f.path
  let before ← if ← target.pathExists then some <$> IO.FS.readBinFile target else pure none
  match isNewAt target.toString before stored with
  | .error why => throw s!"{why}: {f.what} is other bytes than the file already there"
  | .ok false => return none
  | .ok true =>
    IO.FS.writeBinFile target stored
    return some (Tally.add {} f.raw.size stored.size)

def writeVersion (out : FilePath) (m : VersionMeta) (v : VersionData) :
    ExceptT String IO (VersionCounts × DataFile) := do
  let r ← ExceptT.mk (pure (render m v))
  IO.FS.createDirAll (out / "d")
  let mut referenced : Std.HashSet String := {}
  let mut added : Tally := {}
  for f in r.data do
    if referenced.contains f.path then continue
    referenced := referenced.insert f.path
    if let some t ← writeData out f then added := added.plus t
  let mut shells : Tally := {}
  for (path, body) in r.shells do shells := shells.plus (← writeText out path body)
  return ({ version := v.name, modules := v.pages.size, shells, referenced := referenced.size
            added }, r.versionFile)

structure Counts where
  versions : Array VersionCounts
  assets : Tally
  root : Tally

def Counts.json (c : Counts) : String :=
  let shells := c.versions.foldl (·.plus ·.shells) ({} : Tally)
  let data := c.versions.foldl (·.plus ·.added) ({} : Tally)
  let total := ((shells.plus data).plus c.assets).plus c.root
  pushEach "{\"command\":\"store render\",\"versions\":" c.versions (· ++ ·.json)
    ++ s!",\"total\":\{\"files\":{total.files},\"rawBytes\":{total.raw}"
    ++ s!",\"storedBytes\":{total.stored},\"shells\":{shells.json},\"data\":{data.json}"
    ++ s!",\"assets\":{c.assets.json},\"root\":{c.root.json}}}"

def writeAssets (out : FilePath) : IO Tally :=
  storeAssets.foldlM (init := {}) fun t (name, body) =>
    return t.plus (← writeText out (assetsDir ++ name) body)

/-- Not every version's data at once, as `store measure` holds it: a Mathlib
version is ≈ 8.5k pages and a site has 11 or more. -/
def renderStore (store out : FilePath) (names : Array Store.VersionName) :
    ExceptT String IO Counts := do
  for v in names do
    if let .error why := Store.checkoutOf (← Store.readRecord store v) then
      throw s!"store entry {v.text}: {why}"
  let mut versions : Array VersionCounts := #[]
  let mut entries : Array (String × String) := #[]
  for v in names do
    let s ← Store.read store v
    let input ← match inputOf s.record s.files with
      | .ok input => pure input
      | .error why => throw s!"store entry {v.text}: {why}"
    if let some warning := input.site.bibliography.warning then
      IO.eprintln s!"warning: store entry {v.text}: {warning}"
    let (counts, versionFile) ← writeVersion out (VersionMeta.of s.record) (versionData input)
    versions := versions.push counts
    entries := entries.push (v.text, versionFile.address)
  let some (newest, newestFile) := entries.back? | throw "no version to render"
  let root := (← writeText out "versions.json" (versionsJson entries)).plus
    (← writeText out "index.html" (siteIndexShell newest newestFile))
  return { versions, assets := ← writeAssets out, root }

end Site
end Data
end Litedoc4
