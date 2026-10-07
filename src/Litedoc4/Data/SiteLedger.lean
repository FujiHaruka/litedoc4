/- The render ledger sits beside `<out>/site`, not in it: the site is what is hosted. -/
import Litedoc4.Data.Site
import Litedoc4.Fs
import Litedoc4.Json
import Litedoc4.JsonWrite
import Litedoc4.Sha256
import Litedoc4.Store

open System

namespace Litedoc4
namespace Data
namespace SiteLedger

open Site

structure Row where
  name : Store.VersionName
  key : String
  data : String
  routes : Option String
  modules : Nat
  shells : Tally
  referenced : Nat
  added : Tally
  paths : Array String

def Row.of (name : Store.VersionName) (key : String) (w : Written) : Row :=
  { name, key, data := w.listed.data, routes := w.listed.routes, modules := w.counts.modules
    shells := w.counts.shells, referenced := w.counts.referenced, added := w.counts.added
    paths := w.paths }

def Row.listed (r : Row) : Listed := { name := r.name.text, data := r.data, routes := r.routes }

def Row.counts (r : Row) : VersionCounts :=
  { version := r.name.text, modules := r.modules, shells := r.shells, referenced := r.referenced
    added := r.added }

structure RenderLedger where
  renderer : String
  hashUrls : Bool
  rows : Array Row

def Row.push (o : String) (r : Row) : String :=
  let o := jsonStr (jsonStr (o ++ "{\"name\":") r.name.text ++ ",\"key\":") r.key
  let o := jsonStr (o ++ ",\"data\":") r.data ++ ",\"routes\":"
  let o := match r.routes with
    | some routes => jsonStr o routes
    | none => o ++ "null"
  let o := o ++ s!",\"modules\":{r.modules},\"shells\":{r.shells.json},\
    \"dataReferenced\":{r.referenced},\"dataAdded\":{r.added.json},\"paths\":"
  (pushEach o r.paths jsonStr).push '}'

def RenderLedger.toJson (l : RenderLedger) : String :=
  pushEach (jsonStr "{\"renderer\":" l.renderer ++ s!",\"hashUrls\":{l.hashUrls},\"versions\":")
    l.rows Row.push ++ "}\n"

private def field (obj : JVal) (key : String) : Except String JVal :=
  match jvalGet? obj key with
  | some v => .ok v
  | none => .error s!"no `{key}`"

private def str (obj : JVal) (key : String) : Except String String := do
  match ← field obj key with
  | .str s => .ok s
  | _ => .error s!"`{key}` is not a string"

private def nat (obj : JVal) (key : String) : Except String Nat := do
  match ← field obj key with
  | .num n => if n < 0 then .error s!"`{key}` is negative" else .ok n.toNat
  | _ => .error s!"`{key}` is not a whole number"

private def tally (obj : JVal) (key : String) : Except String Tally := do
  let t ← field obj key
  return { files := ← nat t "files", raw := ← nat t "rawBytes", stored := ← nat t "storedBytes" }

def Row.parse (j : JVal) : Except String Row := do
  let name ← Store.VersionName.parse (← str j "name")
  let routes ← match ← field j "routes" with
    | .str s => pure (some s)
    | .null => pure none
    | _ => throw s!"{name.text}: `routes` is neither a string nor null"
  let paths ← match ← field j "paths" with
    | .arr items => items.mapM fun
      | .str s => pure s
      | _ => throw s!"{name.text}: a path is not a string"
    | _ => throw s!"{name.text}: `paths` is not an array"
  return { name, key := ← str j "key", data := ← str j "data", routes
           modules := ← nat j "modules", shells := ← tally j "shells"
           referenced := ← nat j "dataReferenced", added := ← tally j "dataAdded", paths }

def RenderLedger.parse (text : String) : Except String RenderLedger := do
  let j ← parseJson text
  let hashUrls ← match ← field j "hashUrls" with
    | .bool b => pure b
    | _ => throw "`hashUrls` is not a boolean"
  let rows ← match ← field j "versions" with
    | .arr items => items.mapM Row.parse
    | _ => throw "`versions` is not an array"
  return { renderer := ← str j "renderer", hashUrls, rows }

inductive Found where
  | absent
  | unreadable (why : String)
  | ledger (l : RenderLedger)

inductive Step where
  | keep (row : Row)
  | render (name : Store.VersionName) (key : String)

inductive Decision where
  | everything (why : String)
  | reuse (steps : Array Step)

def Decision.steps (d : Decision) (requested : Array (Store.VersionName × String)) : Array Step :=
  match d with
  | .everything _ => requested.map fun (v, key) => .render v key
  | .reuse steps => steps

def heldAway (l : RenderLedger) (requested : Array (Store.VersionName × String)) : Option String :=
  l.rows.findSome? fun row =>
    match requested.find? (·.1 == row.name) with
    | none => some s!"{row.name.text} is in the site and not in the list"
    | some (_, key) =>
      if key != row.key then some s!"{row.name.text}'s store entry is not the one its pages were \
        rendered from"
      else none

def decide (found : Found) (renderer : String) (hashUrls : Bool)
    (requested : Array (Store.VersionName × String))
    (missing : Option (Store.VersionName × String)) : Decision :=
  match found with
  | .absent => .everything "no render ledger beside the site"
  | .unreadable why => .everything s!"the render ledger does not read: {why}"
  | .ledger l =>
    if l.renderer != renderer then
      .everything "the site was rendered by another litedoc4 executable"
    else if l.hashUrls != hashUrls then
      .everything s!"the site was rendered {if l.hashUrls then "with" else "without"} --hash-urls"
    else if let some why := heldAway l requested then .everything why
    else if let some (v, path) := missing then
      .everything s!"{path}, which {v.text}'s render wrote, is not in the site"
    else .reuse <| requested.map fun (v, key) =>
      match l.rows.find? (·.name == v) with
      | some row => .keep row
      | none => .render v key

/-! ## On disk -/

-- Not the version string: one not bumped with the renderer would keep a stale site.
def rendererIdentity : IO String := do
  return sha256Hex (← IO.FS.readBinFile (← IO.appPath))

def entryKey (store : FilePath) (v : Store.VersionName) : IO String := do
  let dir := Store.entryDir store v
  let pack := sha256Hex (← IO.FS.readBinFile (dir / Store.packFile))
  let record := sha256Hex (← IO.FS.readBinFile (dir / Store.recordFile))
  return sha256Text s!"{pack} {record}"

def readLedger (path : FilePath) : IO Found := do
  if !(← path.pathExists) then return .absent
  match ← (IO.FS.readFile path).toBaseIO with
  | .error e => return .unreadable (toString e)
  | .ok text =>
    match RenderLedger.parse text with
    | .error why => return .unreadable why
    | .ok l => return .ledger l

def firstMissing (site : FilePath) (l : RenderLedger) : IO (Option (Store.VersionName × String)) := do
  for row in l.rows do
    for path in row.paths do
      if !(← isRegularFile (site / path)) then return some (row.name, path)
  return none

structure Outcome where
  counts : Counts
  rendered : Array Store.VersionName

/-- The old ledger is deleted before anything is written and the new one written
last, so a render that stops part way leaves no ledger to claim its files. -/
def renderSite (store site ledgerPath : FilePath) (names : Array Store.VersionName)
    (hashUrls : Bool) : ExceptT String IO Outcome := do
  checkEntries store names
  let renderer ← rendererIdentity
  let mut requested : Array (Store.VersionName × String) := #[]
  for v in names do requested := requested.push (v, ← entryKey store v)
  let found ← readLedger ledgerPath
  let missing ← match found with
    | .ledger l => firstMissing site l
    | _ => pure none
  let decision := decide found renderer hashUrls requested missing
  if ← ledgerPath.pathExists then IO.FS.removeFile ledgerPath
  if let .everything why := decision then
    IO.println s!"render  every version: {why}"
    if ← site.pathExists then IO.FS.removeDirAll site
  let mut rows : Array Row := #[]
  let mut rendered : Array Store.VersionName := #[]
  for step in decision.steps requested do
    match step with
    | .keep row => rows := rows.push row
    | .render v key =>
      rows := rows.push (Row.of v key (← writeEntry store site v hashUrls))
      rendered := rendered.push v
  let root ← writeRoot site (rows.map (·.listed)) hashUrls
  let counts := { versions := rows.map (·.counts), assets := ← writeAssets site, root }
  writeFile ledgerPath ({ renderer, hashUrls, rows } : RenderLedger).toJson
  return { counts, rendered }

end SiteLedger
end Data
end Litedoc4
