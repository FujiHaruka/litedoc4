/- `crates/litedoc4-incr/src/ledger.rs`: what a module's inputs hash to, and the
two global keys.

What is hashed is the `.olean`, because that is the extractor's only view of a
module. The `.lean` source is one step too early — it carries changes the olean
does not and misses the ones a rebuilt dependency puts there — and the IR's own
`contentHash` is one step too late, because computing it means running the
extraction this stage exists to skip.

**Module hashes are taken before the extraction they license, and the file is
written after the render.** A ledger written first would claim modules are up to
date whose IR a failed run never produced. -/
import Litedoc4.External
import Litedoc4.Fs
import Litedoc4.Json
import Litedoc4.JsonWrite
import Litedoc4.Metrics
import Litedoc4.Sha256

namespace Litedoc4

def ledgerSchema : Nat := 2

/-- Which implementation will run when the key says "re-extract". Bump it
whenever a re-extraction can produce different IR bytes, including when
`irSchemaVersion` cannot see the difference. -/
def extractorId : String := "litedoc4 extractor v3"

/-- Which implementation will run when the key says "re-render everything".
Bump it whenever the renderer's output bytes can change with the IR held
fixed. -/
def rendererId : String := "litedoc4 renderer v4"

/-- In the order they are hashed. -/
def oleanSuffixes : Array String := #[".olean", ".olean.server", ".olean.private"]

/-- What a module's hash is taken over. `lake` reads the `<file>.hash` Lake
already wrote beside every olean (`computeBinFileHash`, `Lake/Build/Common.lean`)
instead of the olean's bytes: a string read, 6.9 KB instead of 227 MB on the
measurement target. The ledger is always `sha256` — cryptographic, and not an
undocumented implementation detail of the build tool. -/
inductive Algorithm where
  | sha256
  | lake

structure LedgerFile where
  path : String
  /-- **`-1` under `.lake`**: nothing was read but the hash file, so there is no
  byte count to report and a zero would read as an empty olean. -/
  bytes : Int
  hash : String
  deriving Inhabited

structure LedgerModule where
  module : String
  files : Array LedgerFile
  hash : String
  deriving Inhabited

structure Ledger where
  target : String
  libDir : String
  extractKey : Array (String × String)
  renderKey : Array (String × String)
  modules : Array LedgerModule
  deriving Inhabited

def keySetJson (kv : Array (String × String)) : String := Id.run do
  let mut o := "{"
  let mut first := true
  for (k, v) in kv do
    if !first then o := o.push ','
    first := false
    o := jsonStr (jsonStr o k ++ ":") v
  return o.push '}'

def Ledger.toJson (l : Ledger) : String := Id.run do
  let mut o := "{\"ledgerSchema\":" ++ toString ledgerSchema
    ++ ",\"algorithm\":\"sha256\",\"target\":"
  o := jsonStr o l.target
  o := jsonStr (o ++ ",\"libDir\":") l.libDir
  o := o ++ ",\"extractKey\":" ++ keySetJson l.extractKey
  o := o ++ ",\"renderKey\":" ++ keySetJson l.renderKey
  o := o ++ ",\"modules\":["
  let mut firstModule := true
  for m in l.modules do
    if !firstModule then o := o.push ','
    firstModule := false
    o := jsonStr (o ++ "{\"module\":") m.module
    o := o ++ ",\"files\":["
    let mut firstFile := true
    for f in m.files do
      if !firstFile then o := o.push ','
      firstFile := false
      o := jsonStr (o ++ "{\"path\":") f.path
      o := jsonStr (o ++ s!",\"bytes\":{f.bytes},\"hash\":") f.hash
      o := o.push '}'
    o := jsonStr (o ++ "],\"hash\":") m.hash
    o := o.push '}'
  return o ++ "]}\n"

partial def jvalJson : JVal → String
  | .null => "null"
  | .bool b => if b then "true" else "false"
  | .num n => toString n
  | .str s => jsonStr "" s
  | .arr a => "[" ++ ",".intercalate (a.toList.map jvalJson) ++ "]"
  | .obj a => "{" ++ ",".intercalate (a.toList.map fun (k, v) => jsonStr "" k ++ ":" ++ jvalJson v)
      ++ "}"

/-- A missing key becomes the string `"undefined"`, which is what makes an IR
without a `schemaVersion` compare equal to another IR without one. -/
def jsString (j : JVal) (key : String) : String := Id.run do
  let mut found : Option JVal := none
  for (k, v) in asObj j do
    if k == key then found := some v
  match found with
  | none => "undefined"
  | some (.str s) => s
  | some v => jvalJson v

/-- Everything that can change the IR bytes. The split from `renderKey` is not
cosmetic: `--source-url` carries a git revision, so it changes on every commit,
and under one key every incremental build would pay a full re-extraction for an
input Lean cannot see. -/
def extractKey (target : String) (ir : Option System.FilePath) :
    IO (Array (String × String)) := do
  let root : System.FilePath := ⟨target⟩
  let mut key : Array (String × String) := #[]
  key := key.push ("leanToolchain", (← IO.FS.readFile (root / "lean-toolchain")).trimAscii.toString)
  key := key.push ("manifestSha256", sha256Text (← IO.FS.readFile (root / "lake-manifest.json")))
  key := key.push ("extractor", extractorId)
  if let some ir := ir then
    recordIrRead .index
    let text ← IO.FS.readFile (ir / "index.json")
    let n := text.utf8ByteSize
    let (j, _) := JScan.pVal text n (JScan.skipWs text n 0)
    key := key.push ("irSchemaVersion", jsString j "schemaVersion")
    key := key.push ("irGenerator", jsString j "generator")
  return key

/-- What changes the page bytes with the IR held fixed. Changed ⇒ re-extract
nothing, re-render everything. -/
def renderKey (sourceUrl : String) (linkIndex externalLinks : Option String) :
    Array (String × String) := Id.run do
  let mut key : Array (String × String) := #[("renderer", rendererId)]
  if !sourceUrl.isEmpty then
    key := key.push ("sourceUrl", trimTrailingSlash sourceUrl)
  if let some digest := linkIndex then
    key := key.push ("linkIndex", digest)
  if let some digest := externalLinks then
    key := key.push ("externalLinks", digest)
  return key

/-- `none` when the file is not there, which is a real state and not an error: a
first `build` computes the ledger's hashes before the extraction that writes the
map. Any other I/O failure still throws — a map that exists and cannot be read
is not a map that is absent. -/
def linkIndexDigest : Option System.FilePath → IO (Option String)
  | none => return none
  | some path => do
    if ← path.pathExists then return some (← sha256File path) else return none

/-- The olean files a module actually has, in `oleanSuffixes` order. A suffix
that is absent is not an error: this build simply does not use Lean's module
system for that module. -/
def modulePaths (libDir module : String) : IO (Array String) := do
  let base := s!"{libDir}/" ++ "/".intercalate (moduleComponents module).toList
  let mut out : Array String := #[]
  for suffix in oleanSuffixes do
    let path := base ++ suffix
    if ← isRegularFile ⟨path⟩ then out := out.push path
  return out

/-- Relative to the target repository. A path that does not begin with the
target — a `libDir` hand-edited to point outside it — is kept whole rather than
cut at an arbitrary offset. -/
def relativePath (target path : String) : String :=
  let t := target.utf8ByteSize
  let n := path.utf8ByteSize
  if t < n && byteSub path 0 t == target && byteAt path t == 47 then byteSub path (t + 1) n
  else path

/-- `none` is a real answer, not an error: a module can be deleted between
`build` and `check`, and the deletion is exactly what the caller needs to hear
about.

A module that has an olean but whose `<file>.hash` is missing under `.lake` is a
different case and *is* an error: the file the algorithm names is not there, and
reporting the module as removed would delete its pages. -/
def hashModule (algorithm : Algorithm) (target libDir module : String) :
    IO (Option LedgerModule) := do
  let mut files : Array LedgerFile := #[]
  for path in ← modulePaths libDir module do
    let file : LedgerFile ← match algorithm with
      | .sha256 => do
        let bytes ← IO.FS.readBinFile path
        pure { path := relativePath target path, bytes := bytes.size, hash := sha256Hex bytes }
      | .lake => do
        let hash ← IO.FS.readFile (path ++ ".hash")
        pure { path := relativePath target path, bytes := -1, hash := hash.trimAscii.toString }
    files := files.push file
  if files.isEmpty then return none
  let combined := "\n".intercalate (files.toList.map fun f => s!"{f.path} {f.hash}")
  return some { module, files, hash := sha256Text combined }

structure LedgerInputs where
  /-- The modules to hash, in the order they will appear in the ledger. -/
  modules : Array String
  /-- The target repository. Trailing slashes are stripped, because the string
  is a prefix of every recorded path. -/
  target : String
  ir : Option System.FilePath := none
  sourceUrl : String := ""
  linkIndex : Option System.FilePath := none
  externalLinks : Option String := none

/-- `.error` is the refusal that exits 3: at `build` time the module list and
the build tree are supposed to agree, and a ledger that silently omitted a
module would report it as *added* on the next `check` — the one direction that
looks like progress. -/
def buildLedger (i : LedgerInputs) : IO (Except String Ledger) := do
  let target := trimTrailingSlash i.target
  let libDir := s!"{target}/.lake/build/lib/lean"
  let extract ← extractKey target i.ir
  let render := renderKey i.sourceUrl (← linkIndexDigest i.linkIndex) i.externalLinks
  let mut modules : Array LedgerModule := #[]
  let mut missing : Array String := #[]
  for module in i.modules do
    match ← hashModule .sha256 target libDir module with
    | some entry => modules := modules.push entry
    | none => missing := missing.push module
  if !missing.isEmpty then
    return .error s!"no olean under {libDir} for: {", ".intercalate missing.toList}"
  return .ok { target, libDir, extractKey := extract, renderKey := render, modules }

/-- One name per line; blank lines and `#` comments are dropped. -/
def readModuleList (path : System.FilePath) : IO (Array String) := do
  let text ← IO.FS.readFile path
  let mut out : Array String := #[]
  for line in text.splitOn "\n" do
    let line := line.trimAscii.toString
    if !line.isEmpty && !line.startsWith "#" then out := out.push line
  return out

end Litedoc4
