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
import Litedoc4.Incr.Ordered
import Litedoc4.Ir.Utf16
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
measurement target. `sha256` is the reference — cryptographic, and not an
undocumented implementation detail of the build tool.

A name rather than an enumeration, because the ledger stores it verbatim and
**anything that is not `lake` reads and hashes the bytes**: an unknown algorithm
in a file this build did not write degrades to the reference one rather than to
nothing, and round-trips its own name back into the file it came from. What would
falsify this: a third algorithm that reads something other than the olean's
bytes, at which point the name has to be dispatched on rather than tested. -/
structure Algorithm where
  name : String
  deriving Inhabited

def Algorithm.sha256 : Algorithm := { name := "sha256" }

def Algorithm.lake : Algorithm := { name := "lake" }

def Algorithm.hashesBytes (a : Algorithm) : Bool := a.name != Algorithm.lake.name

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
  algorithm : Algorithm
  target : String
  libDir : String
  extractKey : Array (String × String)
  /-- Read as empty at the comparison, but **`none` stays absent on the way
  out**: `touch` rewrites the file it read, and a key this build invented would
  be a byte nobody asked for. -/
  renderKey : Option (Array (String × String))
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
  let mut o := "{\"ledgerSchema\":" ++ toString ledgerSchema ++ ",\"algorithm\":"
  o := jsonStr o l.algorithm.name
  o := jsonStr (o ++ ",\"target\":") l.target
  o := jsonStr (o ++ ",\"libDir\":") l.libDir
  o := o ++ ",\"extractKey\":" ++ keySetJson l.extractKey
  if let some render := l.renderKey then
    o := o ++ ",\"renderKey\":" ++ keySetJson render
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
  | .real lex => lex
  | .bad _ => "null"
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
    let path := ir / "index.json"
    let text ← IO.FS.readFile path
    let j ← match parseJson text with
      | .error why => throw (IO.userError s!"{path}: {why}")
      | .ok j => pure j
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
    let file : LedgerFile ←
      if algorithm.hashesBytes then do
        let bytes ← IO.FS.readBinFile path
        pure { path := relativePath target path, bytes := bytes.size, hash := sha256Hex bytes }
      else do
        let hash ← IO.FS.readFile (path ++ ".hash")
        pure { path := relativePath target path, bytes := -1, hash := hash.trimAscii.toString }
    files := files.push file
  if files.isEmpty then return none
  let combined := "\n".intercalate (files.toList.map fun f => s!"{f.path} {f.hash}")
  return some { module, files, hash := sha256Text combined }

/-- The sum every stage reports as `hashedBytes`. Clamped per file, because the
`-1` a `lake` entry carries is "nothing was read", not "minus one byte". -/
def hashedBytesOf (modules : Array LedgerModule) : Nat :=
  modules.foldl (fun n m => m.files.foldl (fun k f => k + f.bytes.toNat) n) 0

def fileCountOf (modules : Array LedgerModule) : Nat :=
  modules.foldl (fun n m => n + m.files.size) 0

/-- The monotonic clock at each boundary of a run, so that the phases subtract.
Absolute rather than already-differenced because the caller adds two more
boundaries of its own — the file write, and the record it writes last. -/
structure BuildPhases where
  started : Nat
  keyDone : Nat
  hashDone : Nat
  deriving Inhabited

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
  algorithm : Algorithm := Algorithm.sha256

/-- `.error` is the refusal that exits 3: at `build` time the module list and
the build tree are supposed to agree, and a ledger that silently omitted a
module would report it as *added* on the next `check` — the one direction that
looks like progress. -/
def buildLedger (i : LedgerInputs) : IO (Except String (Ledger × BuildPhases)) := do
  let started ← IO.monoNanosNow
  let target := trimTrailingSlash i.target
  let libDir := s!"{target}/.lake/build/lib/lean"
  let extract ← extractKey target i.ir
  let render := renderKey i.sourceUrl (← linkIndexDigest i.linkIndex) i.externalLinks
  let keyDone ← IO.monoNanosNow
  let mut modules : Array LedgerModule := #[]
  let mut missing : Array String := #[]
  for module in i.modules do
    match ← hashModule i.algorithm target libDir module with
    | some entry => modules := modules.push entry
    | none => missing := missing.push module
  let hashDone ← IO.monoNanosNow
  if !missing.isEmpty then
    return .error s!"no olean under {libDir} for: {", ".intercalate missing.toList}"
  return .ok ({ algorithm := i.algorithm, target, libDir, extractKey := extract
                renderKey := some render, modules },
              { started, keyDone, hashDone })

/-- One name per line; blank lines and `#` comments are dropped. -/
def readModuleList (path : System.FilePath) : IO (Array String) := do
  let text ← IO.FS.readFile path
  let mut out : Array String := #[]
  for line in text.splitOn "\n" do
    let line := line.trimAscii.toString
    if !line.isEmpty && !line.startsWith "#" then out := out.push line
  return out

def keySetInsert (kv : Array (String × String)) (key value : String) :
    Array (String × String) := orderedInsert kv key value

def keySetGet (kv : Array (String × String)) (key : String) : Option String :=
  orderedGet? kv key

/-- The names of the keys **present in either set** whose values differ, in
`cmpUtf16` order.

The union is what makes a missing key loud: a key that vanished — an `--ir` that
was not passed this time, a forgotten `--source-url` — compares `none != some _`
and counts as a change. Over-extracting and over-rendering are the safe
directions; the failure this prevents is silently rendering too little, which
nobody reports because the site still looks built. -/
def keySetDiff (before now : Array (String × String)) : Array String := Id.run do
  let mut names : Array String := #[]
  for (name, _) in before ++ now do
    if !names.contains name then names := names.push name
  let mut changed : Array String := #[]
  for name in names do
    if keySetGet before name != keySetGet now name then changed := changed.push name
  return sortUtf16 changed

/-- What a refusal from this stage carries: the exit code, and what to say.
1 is a file that would not read or parse, 3 is the world and the files
disagreeing. -/
abbrev LedgerRefusal := UInt32 × String

def ledgerUnreadable (path why : String) : LedgerRefusal := (1, s!"{path}: {why}")

def ledgerField (path : String) (o : Array (String × JVal)) (key : String) :
    Except LedgerRefusal JVal :=
  match o.find? (·.1 == key) with
  | some (_, v) => .ok v
  | none => .error (ledgerUnreadable path s!"missing field `{key}`")

def ledgerString (path : String) (o : Array (String × JVal)) (key : String) :
    Except LedgerRefusal String := do
  match ← ledgerField path o key with
  | .str s => return s
  | _ => .error (ledgerUnreadable path s!"`{key}` is not a string")

def readKeySet (path field : String) (j : JVal) :
    Except LedgerRefusal (Array (String × String)) := do
  let .obj kvs := j
    | .error (ledgerUnreadable path s!"`{field}` is not a map of strings to strings")
  let mut out : Array (String × String) := #[]
  for (k, v) in kvs do
    let .str value := v
      | .error (ledgerUnreadable path s!"`{field}.{k}` is not a string")
    out := keySetInsert out k value
  return out

def readLedgerFile (path : String) (j : JVal) : Except LedgerRefusal LedgerFile := do
  let .obj o := j | .error (ledgerUnreadable path "a `files` entry is not an object")
  let filePath ← ledgerString path o "path"
  let .num bytes ← ledgerField path o "bytes"
    | .error (ledgerUnreadable path s!"`{filePath}.bytes` is not a number")
  return { path := filePath, bytes, hash := ← ledgerString path o "hash" }

def readLedgerModule (path : String) (j : JVal) : Except LedgerRefusal LedgerModule := do
  let .obj o := j | .error (ledgerUnreadable path "a `modules` entry is not an object")
  let module ← ledgerString path o "module"
  let .arr entries ← ledgerField path o "files"
    | .error (ledgerUnreadable path s!"`{module}.files` is not an array")
  let mut files : Array LedgerFile := #[]
  for entry in entries do
    files := files.push (← readLedgerFile path entry)
  return { module, files, hash := ← ledgerString path o "hash" }

/-- A ledger as a file **any** version may have written, and a hand-edited one is
expected, so every field this needs is required to be there with the right shape
rather than defaulted. A default for a missing `target` or `modules` would answer
"nothing changed" about a file that says nothing at all.

`renderKey` is the one legitimate absence, and `ledgerSchema` the one legitimate
default: a file without it is a schema-1 file, which is refused **as schema 1**
rather than as a parse failure, so that the refusal can name what is wrong with
it. -/
def readLedger (path text : String) : Except LedgerRefusal Ledger := do
  let j ← match parseJson text with
    | .error why => .error (ledgerUnreadable path why)
    | .ok j => pure j
  let .obj o := j | .error (ledgerUnreadable path "the document is not an object")
  let schema ← match o.find? (·.1 == "ledgerSchema") with
    | none => pure 1
    | some (_, .num n) => pure n.toNat
    | some _ => .error (ledgerUnreadable path "`ledgerSchema` is not a number")
  if schema < ledgerSchema then
    throw (3, s!"{path} is ledgerSchema {schema}; this build needs {ledgerSchema} (the single \
      envKey was split into extractKey/renderKey). Rebuild the ledger.")
  let algorithm ← ledgerString path o "algorithm"
  let target ← ledgerString path o "target"
  let libDir ← ledgerString path o "libDir"
  let extract ← readKeySet path "extractKey" (← ledgerField path o "extractKey")
  let render ← match o.find? (·.1 == "renderKey") with
    | none => pure none
    | some (_, v) => pure (some (← readKeySet path "renderKey" v))
  let .arr entries ← ledgerField path o "modules"
    | .error (ledgerUnreadable path "`modules` is not an array")
  let mut modules : Array LedgerModule := #[]
  for entry in entries do
    modules := modules.push (← readLedgerModule path entry)
  return { algorithm := { name := algorithm }, target, libDir, extractKey := extract
           renderKey := render, modules }

structure CheckInputs where
  ledger : System.FilePath
  /-- `none` keeps the ledger's own algorithm, which is the usual case: the two
  hashes are not comparable, so changing it makes every module differ. -/
  algorithm : Option Algorithm := none
  /-- **`none` and `some #[]` are different questions.** `none` re-reads the
  ledger's module list, which cannot see a module that appeared or vanished since
  `build`; `some` is the current list, and an empty one says every module in the
  ledger is gone. -/
  modules : Option (Array String) := none
  ir : Option System.FilePath := none
  sourceUrl : String := ""
  linkIndex : Option System.FilePath := none
  externalLinks : Option String := none
  changedOut : Option System.FilePath := none
  removedOut : Option System.FilePath := none
  renderAllOut : Option System.FilePath := none

/-- The four durations partition the run, so they subtract: read the ledger,
build the keys, hash the modules, compare the sets. The output files are written
after the last of them. -/
structure CheckPhases where
  started : Nat
  readDone : Nat
  keyDone : Nat
  hashDone : Nat
  compareDone : Nat
  deriving Inhabited

structure CheckSummary where
  /-- The algorithm actually used — the ledger's, unless overridden. -/
  algorithm : Algorithm
  /-- Whether the module list came from `--modules` rather than from the ledger. -/
  fromList : Bool
  /-- Modules that still have an olean. -/
  modules : Nat
  files : Nat
  hashedBytes : Nat
  extractKeyChanged : Array String
  renderKeyChanged : Array String
  changed : Array String
  added : Array String
  removed : Array String
  reExtract : Array String
  /-- **The ledger this check would leave behind if the run it licenses
  succeeds** — the hashes as they were *here*, before anything was extracted from
  them, and **not written by `checkLedger`**: `check` answers a question, and a
  caller that stops on the answer must not have moved the ledger.

  Taken here rather than re-hashed afterwards because the race has one silent
  direction: an olean that moves *while* the run is in flight, re-hashed at the
  end, would be recorded as the one its IR came from, and that module is then
  never re-extracted again. -/
  fresh : Ledger
  phases : CheckPhases
  deriving Inhabited

def CheckSummary.extractInvalidated (s : CheckSummary) : Bool := !s.extractKeyChanged.isEmpty

def CheckSummary.renderAll (s : CheckSummary) : Bool := !s.renderKeyChanged.isEmpty

def checkLedger (i : CheckInputs) : IO (Except LedgerRefusal CheckSummary) := do
  let started ← IO.monoNanosNow
  let path := i.ledger.toString
  let ledger ← match readLedger path (← IO.FS.readFile i.ledger) with
    | .error refusal => return .error refusal
    | .ok ledger => pure ledger
  let readDone ← IO.monoNanosNow
  let algorithm := i.algorithm.getD ledger.algorithm

  let extract ← extractKey ledger.target i.ir
  let render := renderKey i.sourceUrl (← linkIndexDigest i.linkIndex) i.externalLinks
  let keyDone ← IO.monoNanosNow

  -- One key invalidates the IR, the other only the pages rendered from it.
  let extractKeyChanged := keySetDiff ledger.extractKey extract
  let renderKeyChanged := keySetDiff (ledger.renderKey.getD #[]) render

  -- A repeated module keeps its first position and takes its last value.
  let mut previous : Array (String × LedgerModule) := #[]
  for entry in ledger.modules do
    match previous.findIdx? (·.1 == entry.module) with
    | some k => previous := previous.set! k (entry.module, entry)
    | none => previous := previous.push (entry.module, entry)
  let current := i.modules.getD (previous.map (·.1))

  let mut hashed : Array (Option LedgerModule) := #[]
  for module in current do
    hashed := hashed.push (← hashModule algorithm ledger.target ledger.libDir module)
  let hashDone ← IO.monoNanosNow

  let mut present : Array LedgerModule := #[]
  let mut changed : Array String := #[]
  let mut added : Array String := #[]
  let mut removed : Array String := #[]
  for k in [0 : current.size] do
    let module := current[k]!
    match hashed[k]! with
    -- In the list, no olean on disk.
    | none => removed := removed.push module
    | some entry =>
      match previous.find? (·.1 == module) with
      | none => added := added.push module
      | some (_, was) => if was.hash != entry.hash then changed := changed.push module
      present := present.push entry
  let goneFromDisk := removed
  for (module, _) in previous do
    if !current.contains module && !goneFromDisk.contains module then
      removed := removed.push module

  -- A changed extract key invalidates every module's IR. The set is then the
  -- present modules in list order — what was just hashed — not the sorted union.
  let reExtract :=
    if extractKeyChanged.isEmpty then sortUtf16 (changed ++ added)
    else present.map (·.module)
  let compareDone ← IO.monoNanosNow

  if let some out := i.changedOut then writeLines out reExtract
  if let some out := i.removedOut then writeLines out removed
  if let some out := i.renderAllOut then
    writeLines out (renderKeyChanged.map (s!"renderKey:{·}"))

  return .ok
    { algorithm, fromList := i.modules.isSome
      modules := present.size, files := fileCountOf present
      hashedBytes := hashedBytesOf present
      extractKeyChanged, renderKeyChanged, changed, added, removed, reExtract
      -- The algorithm is the one that produced these hashes — the ledger's own
      -- unless `--algorithm` overrode it — because a ledger whose entries and
      -- whose declared algorithm disagree compares every module as changed for
      -- ever after.
      fresh := { algorithm, target := ledger.target, libDir := ledger.libDir
                 extractKey := extract, renderKey := some render, modules := present }
      phases := { started, readDone, keyDone, hashDone, compareDone } }

/-- Invalidates one module's entry, so that the next `check` reports it as
**changed**. Invalidating rather than deleting is the point: a deleted entry
would be reported as *added*, and an added module is not what an edit produces.
The olean is not touched — the injected fact is about the ledger. -/
def touchLedger (path module : String) (ledger : Ledger) : Except LedgerRefusal Ledger :=
  match ledger.modules.findIdx? (·.module == module) with
  | none => .error (3, s!"no such module in the ledger {path}: {module}")
  | some k =>
    let entry := ledger.modules[k]!
    .ok { ledger with
            modules := ledger.modules.set! k
              { entry with hash := s!"injected-change:{entry.hash}" } }

end Litedoc4
