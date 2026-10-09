/- The store of kept versions: `<store>/<version>/` holds `entry.pack.gz`, the
version's whole IR tree, its dependency link index and its bibliography and
front page in one deterministic container compressed once, and `record.json`,
what the IR does not say about the version and what the pack must hash to. -/
import Litedoc4.Bytes
import Litedoc4.Config
import Litedoc4.Fs
import Litedoc4.Gzip
import Litedoc4.Incr.Resident
import Litedoc4.Ir
import Litedoc4.Json
import Litedoc4.JsonWrite
import Litedoc4.Packages
import Litedoc4.Sha256

open System

namespace Litedoc4
namespace Store

structure VersionName where
  private mk ::
  text : String
  deriving BEq, Repr

def versionNameMaxBytes : Nat := 128

def isAlnumByte (b : UInt8) : Bool :=
  (b ≥ 48 && b ≤ 57) || (b ≥ 65 && b ≤ 90) || (b ≥ 97 && b ≤ 122)

def isVersionNameByte (b : UInt8) : Bool :=
  isAlnumByte b || b == 46 || b == 95 || b == 43 || b == 45

def VersionName.parse (s : String) : Except String VersionName := Id.run do
  let refuse (why : String) : Except String VersionName :=
    .error s!"`{s}` is not a version name: {why}"
  let n := s.utf8ByteSize
  if n == 0 then return .error "a version name is empty"
  if n > versionNameMaxBytes then return refuse s!"it is longer than {versionNameMaxBytes} bytes"
  -- Not any leading byte: `.put-<name>` and `.old-<name>` beside an entry must never be one.
  if !isAlnumByte (byteAt s 0) then return refuse "it does not start with a letter or a digit"
  for i in [0:n] do
    if !isVersionNameByte (byteAt s i) then
      return refuse "it holds a character other than a letter, a digit, `.`, `_`, `+` or `-`"
  if (s.splitOn "..").length > 1 then return refuse "it holds `..`"
  return .ok ⟨s⟩

/-! ## The container -/

def packMagic : String := "litedoc4-pack 1\n"

def irPathRefusal? (path : String) : Option String :=
  if path.isEmpty then some "a path is empty"
  else if path.startsWith "/" then some s!"`{path}` is absolute"
  else if path.any (fun c => c == '\n' || c == '\x00') then
    some s!"`{path}` holds a newline or a NUL"
  else if (path.splitOn "/").any (fun c => c.isEmpty || c == "." || c == "..") then
    some s!"`{path}` has an empty, `.` or `..` component"
  else none

/-- Sorted here rather than trusted to arrive sorted: equal trees have to give
equal bytes whatever order the directory was listed in. -/
def encode (files : Array (String × ByteArray)) : Except String ByteArray := do
  let sorted := files.qsort (fun a b => byteLt a.1 b.1)
  let mut total := packMagic.utf8ByteSize + 21
  for i in [0:sorted.size] do
    let (path, bytes) := sorted[i]!
    if let some why := irPathRefusal? path then throw s!"cannot pack it: {why}"
    if i > 0 && sorted[i - 1]!.1 == path then throw s!"cannot pack it: `{path}` twice"
    total := total + path.utf8ByteSize + 22 + bytes.size
  let mut out := ByteArray.emptyWithCapacity total
  out := out.append packMagic.toUTF8
  out := out.append s!"{sorted.size}\n".toUTF8
  for (path, bytes) in sorted do
    out := out.append s!"{path}\n{bytes.size}\n".toUTF8
    out := out.append bytes
  return out

def lineEnd? (b : ByteArray) (start : Nat) : Option Nat := Id.run do
  let mut i := start
  while i < b.size do
    if b[i]! == 10 then return some i
    i := i + 1
  return none

/-- `0` or digits without a leading zero, at most 20 of them: one spelling per
number, so a decoded pack re-encodes to its own bytes. -/
def canonicalDecimal? (b : ByteArray) (start stop : Nat) : Option Nat := Id.run do
  let n := stop - start
  if n == 0 || n > 20 then return none
  if n > 1 && b[start]! == 48 then return none
  let mut acc := 0
  for i in [start:stop] do
    let c := b[i]!
    if c < 48 || c > 57 then return none
    acc := acc * 10 + (c - 48).toNat
  return some acc

def decode (b : ByteArray) : Except String (Array (String × ByteArray)) := do
  let magic := packMagic.toUTF8
  if b.size < magic.size || b.extract 0 magic.size != magic then
    throw "not a pack: it does not open with `litedoc4-pack 1`"
  let some countEnd := lineEnd? b magic.size | throw "the file count has no line end"
  let some count := canonicalDecimal? b magic.size countEnd
    | throw "the file count is not a decimal number"
  let mut out : Array (String × ByteArray) := #[]
  let mut previous : Option String := none
  let mut i := countEnd + 1
  for k in [0:count] do
    if i ≥ b.size then throw s!"the pack holds {k} of the {count} files it declares"
    let some pathEnd := lineEnd? b i | throw s!"file {k + 1} of {count}: its path has no line end"
    let some path := String.fromUTF8? (b.extract i pathEnd)
      | throw s!"file {k + 1} of {count}: its path is not UTF-8"
    if let some why := irPathRefusal? path then throw s!"file {k + 1} of {count}: {why}"
    if let some before := previous then
      if !byteLt before path then
        throw s!"`{path}` follows `{before}`: the paths are not in strictly ascending byte order"
    let some lengthEnd := lineEnd? b (pathEnd + 1) | throw s!"`{path}`: its length has no line end"
    let some length := canonicalDecimal? b (pathEnd + 1) lengthEnd
      | throw s!"`{path}`: its length is not a decimal number"
    let start := lengthEnd + 1
    if start + length > b.size then
      throw s!"`{path}` claims {length} bytes and {b.size - start} remain"
    out := out.push (path, b.extract start (start + length))
    previous := some path
    i := start + length
  if i != b.size then throw s!"{b.size - i} byte(s) follow the last of the {count} files"
  return out

/-! ## The record -/

inductive Fill where
  | own
  | reader
  deriving BEq, Repr

def Fill.name : Fill → String
  | .own => "own"
  | .reader => "reader"

def Fill.parse? : String → Option Fill
  | "own" => some .own
  | "reader" => some .reader
  | _ => none

structure ExtractorIdentity where
  private mk ::
  text : String
  fields : Array (String × String)
  deriving BEq, Repr

def identityFields (s : String) : Option (Array (String × String)) := Id.run do
  let mut fields : Array (String × String) := #[]
  for token in s.splitOn " " do
    match token.splitOn "=" with
    | key :: rest =>
      if key.isEmpty || rest.isEmpty || fields.any (·.1 == key) then return none
      fields := fields.push (key, "=".intercalate rest)
    | [] => return none
  return some fields

/-- Taken as it is, never trimmed: the identity is judged by content, and two
spellings of one would be two identities. -/
def ExtractorIdentity.of? (s : String) : Option ExtractorIdentity :=
  if s.isEmpty || s.any (· == '\n') then none
  else (identityFields s).map (⟨s, ·⟩)

def toolchainFields : List String := ["lean", "leanGithash"]

def ExtractorIdentity.beyondToolchain (i : ExtractorIdentity) : Array (String × String) :=
  i.fields.filter (!toolchainFields.contains ·.1)

def ExtractorIdentity.key (i : ExtractorIdentity) : String :=
  " ".intercalate (i.beyondToolchain.toList.map fun (k, v) => s!"{k}={v}")

structure Dependency where
  name : String
  rev : Option String
  deriving BEq, Repr

/-- What a put reads from the build's checkout rather than from its output: each
dependency root's pinned source and the site configuration (`readSiteSources`),
whose title is here and whose files are in the pack. A record an older put wrote
holds less, and putting the same build again reads all of it without
re-extracting anything. -/
inductive Checkout where
  | beforeSources
  | beforeSite (roots : Array (String × Option String))
  | read (roots : Array (String × Option String)) (title : Option String)
  deriving BEq, Repr

structure Record where
  version : VersionName
  commit : String
  leanVersion : String
  leanGithash : String
  fill : Fill
  sourceUrl : String
  dependencies : Array Dependency
  checkout : Checkout
  extractorIdentity : ExtractorIdentity
  packSha256 : String
  packBytes : Nat
  irFiles : Nat
  irBytes : Nat
  linkIndexBytes : Nat
  deriving BEq, Repr

def recordSchema : Nat := 4

def Checkout.schema : Checkout → Nat
  | .beforeSources => 2
  | .beforeSite _ => 3
  | .read .. => recordSchema

-- Not the whole line: a version's commit pins its Lean, so one extractor on any toolchain answers.
def ExtractorIdentity.staleAgainst (written current : ExtractorIdentity) : Bool :=
  written.key != current.key

def stale (r : Record) (current : ExtractorIdentity) : Bool :=
  r.extractorIdentity.staleAgainst current

structure FromCheckout where
  sources : Array (String × Option String)
  title : Option String
  deriving BEq, Repr

def needsReputRefusal (v : VersionName) (c : Checkout) : String :=
  let (holds, consequence) := match c with
    | .beforeSources => ("no dependency source map and no site configuration",
        "would link into no dependency and cite nothing")
    | _ => ("no site configuration (bibliography, front page, title)",
        "would cite nothing and have no front page")
  s!"its record (schema {c.schema}) holds {holds}, and pages rendered from it {consequence}: \
    put it again with `litedoc4 store put --version {v.text} --from <its build directory>`, \
    which reads them from the build's checkout without re-extracting"

/-- **The one judgement of whether an entry can be rendered from**: `list`,
`check-stale`, `measure` and `render` all ask it. -/
def checkoutOf (r : Record) : Except String FromCheckout :=
  match r.checkout with
  | .read roots title => .ok { sources := roots, title }
  | c => .error (needsReputRefusal r.version c)

def sourceMapOf (m : ExternalLinks) : Array (String × Option String) :=
  (m.roots.map fun r =>
    (r.name, match m.sourceFor r.name with
      | .pinned base => some base
      | .unpinned | .absent => none)).qsort (fun a b => byteLt a.1 b.1)

def linksOf (roots : Array (String × Option String)) : ExternalLinks :=
  mkExternalLinks (roots.map fun (root, base) => (root, base.getD ""))

def Record.toJson (r : Record) : String := Id.run do
  let mut o := s!"\{\"recordSchema\":{r.checkout.schema},\"version\":"
  o := jsonStr o r.version.text
  o := jsonStr (o ++ ",\"commit\":") r.commit
  o := jsonStr (o ++ ",\"leanVersion\":") r.leanVersion
  o := jsonStr (o ++ ",\"leanGithash\":") r.leanGithash
  o := jsonStr (o ++ ",\"fill\":") r.fill.name
  o := jsonStr (o ++ ",\"sourceUrl\":") r.sourceUrl
  o := o ++ ",\"dependencies\":["
  let mut first := true
  for d in r.dependencies do
    if !first then o := o.push ','
    first := false
    o := jsonStr (o ++ "{\"name\":") d.name ++ ",\"rev\":"
    o := match d.rev with
      | some rev => jsonStr o rev
      | none => o ++ "null"
    o := o.push '}'
  o := o.push ']'
  let pushSources (o : String) (roots : Array (String × Option String)) : String := Id.run do
    let mut o := o ++ ",\"sources\":["
    for i in [0:roots.size] do
      let (root, base) := roots[i]!
      if i > 0 then o := o.push ','
      o := jsonStr (o.push '[') root |>.push ','
      o := (match base with
        | some b => jsonStr o b
        | none => o ++ "null").push ']'
    return o.push ']'
  match r.checkout with
  | .beforeSources => pure ()
  | .beforeSite roots => o := pushSources o roots
  | .read roots title =>
    o := pushSources o roots ++ ",\"title\":"
    o := match title with
      | some t => jsonStr o t
      | none => o ++ "null"
  o := jsonStr (o ++ ",\"extractorIdentity\":") r.extractorIdentity.text
  o := jsonStr (o ++ ",\"pack\":{\"sha256\":") r.packSha256
  o := o ++ s!",\"bytes\":{r.packBytes}},\"ir\":\{\"files\":{r.irFiles},\"bytes\":{r.irBytes}},\"linkIndex\":\{\"bytes\":{r.linkIndexBytes}}}\n"
  return o

def Record.parse (text : String) : Except String Record := do
  let j ← parseJson text
  let field (obj : JVal) (key : String) : Except String JVal :=
    match jvalGet? obj key with
    | some v => .ok v
    | none => .error s!"no `{key}`"
  let str (obj : JVal) (key : String) : Except String String := do
    match ← field obj key with
    | .str s => .ok s
    | _ => .error s!"`{key}` is not a string"
  let nat (obj : JVal) (key : String) : Except String Nat := do
    match ← field obj key with
    | .num n => if n < 0 then .error s!"`{key}` is negative" else .ok n.toNat
    | _ => .error s!"`{key}` is not a whole number"
  let schema ← nat j "recordSchema"
  if schema < Checkout.beforeSources.schema || schema > recordSchema then
    throw s!"record schema {schema}; this reader reads schemas {Checkout.beforeSources.schema} to \
      {recordSchema}"
  let version ← VersionName.parse (← str j "version")
  let fillName ← str j "fill"
  let some fill := Fill.parse? fillName | throw s!"`fill` is `{fillName}`, not `own` or `reader`"
  let some extractorIdentity := ExtractorIdentity.of? (← str j "extractorIdentity")
    | throw "`extractorIdentity` is empty, holds a newline, or is not `key=value` fields"
  let dependencies ← match ← field j "dependencies" with
    | .arr items => items.mapM fun d => do
      let name ← str d "name"
      let rev ← match ← field d "rev" with
        | .str s => pure (some s)
        | .null => pure none
        | _ => throw s!"dependency `{name}`: `rev` is neither a string nor null"
      pure { name, rev : Dependency }
    | _ => throw "`dependencies` is not an array"
  let sources : Except String (Array (String × Option String)) := do
    match ← field j "sources" with
    | .arr items => do
      let mut roots : Array (String × Option String) := #[]
      for item in items do
        let (root, base) ← match item with
          | .arr #[.str root, .str base] =>
            if base.isEmpty then throw s!"source root `{root}`: its base is empty, not null"
            else pure (root, some base)
          | .arr #[.str root, .null] => pure (root, none)
          | _ => throw "a `sources` entry is not [root, base or null]"
        if let some (before, _) := roots.back? then
          if !byteLt before root then
            throw s!"source root `{root}` follows `{before}`: not in strictly ascending byte order"
        roots := roots.push (root, base)
      pure roots
    | _ => throw "`sources` is not an array"
  let checkout ← if schema == Checkout.beforeSources.schema then pure Checkout.beforeSources
    else if schema == (Checkout.beforeSite #[]).schema then pure (Checkout.beforeSite (← sources))
    else
      let title ← match ← field j "title" with
        | .str t => if t.isEmpty then throw "`title` is empty, not null" else pure (some t)
        | .null => pure none
        | _ => throw "`title` is neither a string nor null"
      pure (Checkout.read (← sources) title)
  let pack ← field j "pack"
  let ir ← field j "ir"
  let linkIndex ← field j "linkIndex"
  return { version, commit := ← str j "commit", leanVersion := ← str j "leanVersion"
           leanGithash := ← str j "leanGithash", fill, sourceUrl := ← str j "sourceUrl"
           dependencies, checkout, extractorIdentity
           packSha256 := ← str pack "sha256", packBytes := ← nat pack "bytes"
           irFiles := ← nat ir "files", irBytes := ← nat ir "bytes"
           linkIndexBytes := ← nat linkIndex "bytes" }

/-! ## What an entry holds -/

def irPrefix : String := "ir/"
def linkIndexEntry : String := "link-index.lidx"
def bibliographyEntry : String := "site/references.bib"
def frontPageEntry : String := "site/index.md"

structure EntryParts where
  irFiles : Nat
  irBytes : Nat
  linkIndexBytes : Nat
  deriving BEq, Repr

def entryParts (files : Array (String × ByteArray)) : Except String EntryParts := do
  let mut parts : EntryParts := ⟨0, 0, 0⟩
  let mut sawLinkIndex := false
  for (path, bytes) in files do
    if path == linkIndexEntry then
      sawLinkIndex := true
      parts := { parts with linkIndexBytes := bytes.size }
    else if path.startsWith irPrefix then
      parts := { parts with irFiles := parts.irFiles + 1, irBytes := parts.irBytes + bytes.size }
    else if path != bibliographyEntry && path != frontPageEntry then
      throw s!"`{path}` is neither under `{irPrefix}` nor one of `{linkIndexEntry}`, \
        `{bibliographyEntry}` and `{frontPageEntry}`"
  if !sawLinkIndex then throw s!"it holds no `{linkIndexEntry}`"
  if parts.irFiles == 0 then throw s!"it holds nothing under `{irPrefix}`"
  return parts

/-! ## The entries on disk -/

def packFile : String := "entry.pack.gz"
def recordFile : String := "record.json"

def entryDir (store : FilePath) (v : VersionName) : FilePath := store / v.text
def stagingDir (store : FilePath) (v : VersionName) : FilePath := store / s!".put-{v.text}"
def retiredDir (store : FilePath) (v : VersionName) : FilePath := store / s!".old-{v.text}"

-- Through a ref, not a `let`: a pure `let` is free to float past the second clock read.
@[noinline] def timed (f : Unit → α) : IO (α × Nat) := do
  let start ← IO.monoNanosNow
  let cell ← IO.mkRef (f ())
  let stop ← IO.monoNanosNow
  return (← cell.get, stop - start)

partial def readTree (root : FilePath) : IO (Array (String × ByteArray)) := do
  let rec go (dir : FilePath) (prefix_ : String) (acc : Array (String × ByteArray)) :
      IO (Array (String × ByteArray)) := do
    let mut acc := acc
    for entry in ← dir.readDir do
      let relative := prefix_ ++ entry.fileName
      if ← entry.path.isDir then acc ← go entry.path (relative ++ "/") acc
      else acc := acc.push (relative, ← IO.FS.readBinFile entry.path)
    return acc
  go root "" #[]

structure Origin where
  commit : String
  leanGithash : String
  sourceUrl : String
  dependencies : Array Dependency
  sources : ExternalLinks
  site : SiteSources
  fill : Fill := .own

structure PutSummary where
  record : Record
  packedBytes : Nat
  readNanos : Nat
  packNanos : Nat
  compressNanos : Nat
  digestNanos : Nat
  writeNanos : Nat

def install (store : FilePath) (v : VersionName) : IO Unit := do
  let entry := entryDir store v
  let retired := retiredDir store v
  if ← retired.pathExists then IO.FS.removeDirAll retired
  if ← entry.pathExists then IO.FS.rename entry retired
  IO.FS.rename (stagingDir store v) entry
  if ← retired.pathExists then IO.FS.removeDirAll retired

def siteFiles (s : SiteSources) : Array (String × ByteArray) :=
  (s.bibliography.map (bibliographyEntry, ·.toUTF8)).toArray
    ++ (s.indexMarkdown.map (frontPageEntry, ·.toUTF8)).toArray

def siteSourcesOf (title : Option String) (files : Array (String × ByteArray)) :
    Except String SiteSources := do
  let text (path : String) : Except String (Option String) :=
    match files.find? (·.1 == path) with
    | none => .ok none
    | some (_, bytes) => match String.fromUTF8? bytes with
      | some s => .ok (some s)
      | none => .error s!"`{path}` is not UTF-8"
  return { title, indexMarkdown := ← text frontPageEntry, bibliography := ← text bibliographyEntry }

def put (store : FilePath) (v : VersionName) (origin : Origin) (ir linkIndex : FilePath) :
    IO PutSummary := do
  let started ← IO.monoNanosNow
  let tree ← openIrTree ir
  let some extractorIdentity := ExtractorIdentity.of? tree.index.extractorIdentity
    | throw (IO.userError s!"{ir}: its index.json carries no extractorIdentity, so an entry made \
        from it could never be judged fresh or stale. Re-extract it with an extractor that \
        writes one")
  if tree.index.leanVersion.isEmpty then
    throw (IO.userError s!"{ir}: its index.json carries no leanVersion")
  if !(← isRegularFile linkIndex) then
    throw (IO.userError s!"{linkIndex}: there is no link index. An entry holds the IR and the \
      dependency link index the renderer reads beside it, and a build given --link-index reads \
      somebody else's file rather than writing this one")
  let files := (← readTree ir).map (fun (path, bytes) => (irPrefix ++ path, bytes))
    |>.push (linkIndexEntry, ← IO.FS.readBinFile linkIndex)
    |>.append (siteFiles origin.site)
  let parts ← match entryParts files with
    | .ok parts => pure parts
    | .error why => throw (IO.userError s!"{ir}: {why}")
  let read ← IO.monoNanosNow
  let (packed, packNanos) ← timed fun _ => encode files
  let packed ← match packed with
    | .ok bytes => pure bytes
    | .error why => throw (IO.userError s!"{ir}: {why}")
  let (compressed, compressNanos) ← timed fun _ => Gzip.compress 6 packed
  let (digest, digestNanos) ← timed fun _ => sha256Hex compressed
  let record : Record :=
    { version := v, commit := origin.commit, leanVersion := tree.index.leanVersion
      leanGithash := origin.leanGithash, fill := origin.fill, sourceUrl := origin.sourceUrl
      dependencies := origin.dependencies
      checkout := .read (sourceMapOf origin.sources) origin.site.title
      extractorIdentity
      packSha256 := digest, packBytes := compressed.size
      irFiles := parts.irFiles, irBytes := parts.irBytes, linkIndexBytes := parts.linkIndexBytes }
  let writeStarted ← IO.monoNanosNow
  let staging := stagingDir store v
  if ← staging.pathExists then IO.FS.removeDirAll staging
  IO.FS.createDirAll staging
  try
    IO.FS.writeBinFile (staging / packFile) compressed
    IO.FS.writeFile (staging / recordFile) record.toJson
    install store v
  catch e =>
    if ← staging.pathExists then IO.FS.removeDirAll staging
    throw e
  let done ← IO.monoNanosNow
  return { record, packedBytes := packed.size, readNanos := read - started, packNanos
           compressNanos, digestNanos, writeNanos := done - writeStarted }

def readRecord (store : FilePath) (v : VersionName) : IO Record := do
  let path := entryDir store v / recordFile
  match Record.parse (← readTextFile path) with
  | .error why => throw (IO.userError s!"store entry {v.text}: {path}: {why}")
  | .ok record =>
    if record.version != v then
      throw (IO.userError s!"store entry {v.text}: its record names version \
        {record.version.text}")
    return record

structure ReadSummary where
  record : Record
  files : Array (String × ByteArray)
  packedBytes : Nat
  readNanos : Nat
  verifyNanos : Nat
  decompressNanos : Nat
  unpackNanos : Nat

def read (store : FilePath) (v : VersionName) : IO ReadSummary := do
  let started ← IO.monoNanosNow
  let dir := entryDir store v
  if !(← dir.isDir) then throw (IO.userError s!"store entry {v.text}: there is no {dir}")
  let record ← readRecord store v
  let compressed ← IO.FS.readBinFile (dir / packFile)
  let read ← IO.monoNanosNow
  let damaged := s!"store entry {v.text}: {dir / packFile}"
  if compressed.size != record.packBytes then
    throw (IO.userError s!"{damaged} is {compressed.size} bytes and its record says \
      {record.packBytes}: the entry is damaged — remove it and put it again")
  let (digest, verifyNanos) ← timed fun _ => sha256Hex compressed
  if digest != record.packSha256 then
    throw (IO.userError s!"{damaged} has SHA-256 {digest} and its record says \
      {record.packSha256}: the entry is damaged — remove it and put it again")
  let (packed, decompressNanos) ← timed fun _ => Gzip.decompress compressed
  let packed ← match packed with
    | .ok bytes => pure bytes
    | .error why => throw (IO.userError s!"{damaged}: {why}")
  let (files, unpackNanos) ← timed fun _ => decode packed
  let files ← match files with
    | .ok files => pure files
    | .error why => throw (IO.userError s!"{damaged}: {why}")
  let parts ← match entryParts files with
    | .ok parts => pure parts
    | .error why => throw (IO.userError s!"{damaged}: {why}")
  let recorded : EntryParts := ⟨record.irFiles, record.irBytes, record.linkIndexBytes⟩
  if parts != recorded then
    throw (IO.userError s!"{damaged} unpacks to {parts.irFiles} IR files of {parts.irBytes} \
      bytes and a link index of {parts.linkIndexBytes}, and its record says {recorded.irFiles}, \
      {recorded.irBytes} and {recorded.linkIndexBytes}")
  return { record, files, packedBytes := packed.size, readNanos := read - started
           verifyNanos, decompressNanos, unpackNanos }

def unpackTo (out : FilePath) (files : Array (String × ByteArray)) : IO Unit := do
  if (← out.pathExists) && !(← isEmptyDir out) then
    throw (IO.userError s!"{out} is not an empty directory: an entry is unpacked only where \
      nothing it did not write can be mixed into it")
  IO.FS.createDirAll out
  for (path, bytes) in files do
    let target := out / path
    if let some parent := target.parent then IO.FS.createDirAll parent
    IO.FS.writeBinFile target bytes

structure Listing where
  entries : Array (VersionName × Except String Record)
  strays : Array String

def list (store : FilePath) : IO Listing := do
  let mut names : Array VersionName := #[]
  let mut strays : Array String := #[]
  for entry in ← store.readDir do
    if entry.fileName.startsWith "." then continue
    match VersionName.parse entry.fileName with
    | .ok v => names := names.push v
    | .error _ => strays := strays.push entry.fileName
  let mut entries : Array (VersionName × Except String Record) := #[]
  for v in names.qsort (fun a b => byteLt a.text b.text) do
    match ← (readRecord store v).toBaseIO with
    | .ok record => entries := entries.push (v, .ok record)
    | .error e => entries := entries.push (v, .error (toString e))
  return { entries, strays := strays.qsort byteLt }

def remove (store : FilePath) (v : VersionName) : IO Unit := do
  let entry := entryDir store v
  if !(← entry.isDir) then throw (IO.userError s!"store entry {v.text}: there is no {entry}")
  let retired := retiredDir store v
  if ← retired.pathExists then IO.FS.removeDirAll retired
  IO.FS.rename entry retired
  IO.FS.removeDirAll retired

/-! ## What fills an entry's record, and what judges it -/

def dependencyRevisions (root : FilePath) : IO (Except String (Array Dependency)) := do
  match ← readManifest (root / "lake-manifest.json") with
  | .error why => return .error why
  | .ok m => return .ok (m.packages.map fun p => { name := p.name, rev := p.rev })

def identityArgv (noEquationsUnder : Array String) : Array String :=
  #["--identity"] ++ outputFlags noEquationsUnder

def currentIdentity (bin : FilePath) (noEquationsUnder : Array String)
    (subcommand : Array String := #[]) : IO ExtractorIdentity := do
  let args := subcommand ++ identityArgv noEquationsUnder
  let out ← IO.Process.output { cmd := bin.toString, args }
  let spelled := " ".intercalate args.toList
  if out.exitCode != 0 then
    throw (IO.userError s!"{bin} {spelled} exited {out.exitCode}: {trimWs out.stderr}")
  let line := if out.stdout.endsWith "\n" then (out.stdout.dropEnd 1).toString else out.stdout
  match ExtractorIdentity.of? line with
  | some identity => return identity
  | none => throw (IO.userError s!"{bin} {spelled} printed no one-line identity of \
      `key=value` fields")

def versionList (list : String) : Except String (Array VersionName) := do
  let mut out : Array VersionName := #[]
  for name in list.splitOn "," do
    let v ← VersionName.parse name
    if out.contains v then throw s!"--versions names `{name}` twice"
    out := out.push v
  return out

end Store
end Litedoc4
