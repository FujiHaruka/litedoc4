import Litedoc4.Build
import Litedoc4.Data.FromStore
import Litedoc4.Ledger
import Litedoc4.Store
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4 Litedoc4.Store System

def acceptsVersionName (s : String) : Bool := (VersionName.parse s).toOption.isSome

def refusalNamesTheInput (s : String) : Bool :=
  match VersionName.parse s with
  | .ok _ => false
  | .error why => s.isEmpty || (why.splitOn s!"`{s}`").length ≥ 2

def aVersionNameIsOneDirectoryNameOfABoundedCharsetAndAnythingElseIsRefusedByName : Bool :=
  ["v1", "v4.32.2", "0", "nightly-2026_01.01+x", "".pushn 'a' 128].all acceptsVersionName
    && ["", ".hidden", "-v", "+v", "_v", "a/b", "a..b", "..", "a b", "ü", "v1\n",
        "".pushn 'a' 129].all fun s => !acceptsVersionName s && refusalNamesTheInput s

#guard aVersionNameIsOneDirectoryNameOfABoundedCharsetAndAnythingElseIsRefusedByName

def bytesOf (s : String) : ByteArray := s.toUTF8

def sampleFiles : Array (String × ByteArray) := #[
  ("modules/Example.Basic.json", bytesOf "{\"module\":\"Example.Basic\"}"),
  ("index.json", bytesOf "{\"schemaVersion\":5}\n"),
  ("deps/empty.json", .empty),
  ("deps/lines.bin", ⟨#[10, 0, 10, 49, 10, 255]⟩),
  ("modules/Example.json", bytesOf "{}")]

def sortedSample : Array (String × ByteArray) := sampleFiles.qsort (fun a b => byteLt a.1 b.1)

def samePairs (a b : Array (String × ByteArray)) : Bool :=
  a.size == b.size && (a.zip b).all fun (x, y) => x.1 == y.1 && x.2 == y.2

def aPackDecodesToItsFilesSortedAndReencodesToItsOwnBytesWhateverOrderTheyCameIn : Bool :=
  match encode sampleFiles, encode sampleFiles.reverse with
  | .ok packed, .ok again =>
    packed == again
      && match decode packed with
        | .ok files => samePairs files sortedSample && (encode files).toOption == some packed
        | .error _ => false
  | _, _ => false

#guard aPackDecodesToItsFilesSortedAndReencodesToItsOwnBytesWhateverOrderTheyCameIn

def isError : Except String α → Bool
  | .error _ => true
  | .ok _ => false

def everyProperPrefixOfAPackAndAPackWithAByteAfterItAreRefused : Bool :=
  match encode sampleFiles with
  | .error _ => false
  | .ok packed =>
    (List.range packed.size).all (fun cut => isError (decode (packed.extract 0 cut)))
      && isError (decode (packed.push 0))

#guard everyProperPrefixOfAPackAndAPackWithAByteAfterItAreRefused

def packText (s : String) : Except String (Array (String × ByteArray)) := decode s.toUTF8

def aPackWithAnUnsafeUnorderedOrRepeatedPathOrANonCanonicalNumberIsRefused : Bool :=
  (packText "litedoc4-pack 1\n1\na\n1\nx").toOption.map (·.size) == some 1
    && ["litedoc4-pack 2\n1\na\n1\nx",
        "litedoc4-pack 1\n01\na\n1\nx",
        "litedoc4-pack 1\n1\na\n01\nx",
        "litedoc4-pack 1\n1\na\n-1\nx",
        "litedoc4-pack 1\n1\n../a\n1\nx",
        "litedoc4-pack 1\n1\n/a\n1\nx",
        "litedoc4-pack 1\n1\na//b\n1\nx",
        "litedoc4-pack 1\n1\na/./b\n1\nx",
        "litedoc4-pack 1\n1\n\n1\nx",
        "litedoc4-pack 1\n2\nb\n1\nxa\n1\nx",
        "litedoc4-pack 1\n2\na\n1\nxa\n1\nx",
        "litedoc4-pack 1\n1\na\n2\nx"].all (isError ∘ packText)
    && [#[("../a", ByteArray.empty)], #[("a\nb", ByteArray.empty)], #[("/a", ByteArray.empty)],
        #[("a", ByteArray.empty), ("a", ByteArray.empty)]].all (isError ∘ encode)

#guard aPackWithAnUnsafeUnorderedOrRepeatedPathOrANonCanonicalNumberIsRefused

def identityAText : String := "schema=5 source=fnv1a64:0123456789abcdef noEquationsUnder="

def identityBText : String :=
  "schema=5 source=fnv1a64:0123456789abcdef noEquationsUnder=Example"

def sampleRecordOf (v : VersionName) (identity : ExtractorIdentity) : Record :=
  { version := v
    commit := "0123456789abcdef0123456789abcdef01234567"
    leanVersion := "4.32.2", leanGithash := "89abcdef0123456789abcdef0123456789abcdef"
    fill := .own, sourceUrl := "https://github.com/o/r/blob/0123456789abcdef0123456789abcdef01234567"
    dependencies := #[{ name := "batteries", rev := some "fedcba9876543210fedcba9876543210fedcba98" },
                      { name := "micro-dep", rev := none }]
    checkout := .read #[
      ("Batteries", some "https://github.com/leanprover-community/batteries/blob/fedcba9876543210fedcba9876543210fedcba98"),
      ("Dep-Aux", none),
      ("Init", some "https://github.com/leanprover/lean4/blob/89abcdef0123456789abcdef0123456789abcdef/src")]
      (some "Sample")
    extractorIdentity := identity, packSha256 := "ab", packBytes := 12, irFiles := 3, irBytes := 40
    linkIndexBytes := 7 }

def withSample (f : Record → ExtractorIdentity → ExtractorIdentity → Bool) : Bool :=
  match VersionName.parse "v4.32.2", ExtractorIdentity.of? identityAText,
      ExtractorIdentity.of? identityBText with
  | .ok v, some a, some b => f (sampleRecordOf v a) a b
  | _, _, _ => false

def recordEdited (r : Record) (edit : Array (String × JVal) → Array (String × JVal)) : String :=
  match parseJson r.toJson with
  | .ok (.obj kv) => jvalJson (.obj (edit kv))
  | _ => ""

def recordWithout (r : Record) (key : String) : String :=
  recordEdited r (·.filter (·.1 != key))

def recordWith (r : Record) (key : String) (value : JVal) : String :=
  recordEdited r (·.map fun (k, v) => if k == key then (k, value) else (k, v))

def recordKeys : List String :=
  ["recordSchema", "version", "commit", "leanVersion", "leanGithash", "fill", "sourceUrl",
   "dependencies", "sources", "title", "extractorIdentity", "pack", "ir", "linkIndex"]

def aRecordRoundTripsThroughItsJsonAndAMissingOrWrongKeyIsRefused : Bool :=
  withSample fun r _ _ =>
    (Record.parse r.toJson).toOption == some r
      && recordKeys.all (fun key => isError (Record.parse (recordWithout r key)))
      && [recordWith r "recordSchema" (.num 1), recordWith r "fill" (.str "copied"),
          recordWith r "extractorIdentity" (.str ""), recordWith r "version" (.str "../v1"),
          recordWith r "pack" (.obj #[("sha256", .str "ab")]),
          recordWith r "dependencies" (.arr #[.obj #[("name", .str "x"), ("rev", .num 1)]]),
          recordWith r "sources" (.arr #[.arr #[.str "Init", .str ""]]),
          recordWith r "sources" (.arr #[.arr #[.str "Init", .num 1]]),
          recordWith r "sources" (.arr #[.arr #[.str "Init"]]),
          recordWith r "sources" (.arr #[.arr #[.str "Init", .null], .arr #[.str "Init", .null]]),
          recordWith r "sources" (.arr #[.arr #[.str "Lean", .null], .arr #[.str "Init", .null]]),
          recordWith r "sources" (.obj #[]),
          recordWith r "title" (.str ""), recordWith r "title" (.num 1)].all
        (isError ∘ Record.parse)

#guard aRecordRoundTripsThroughItsJsonAndAMissingOrWrongKeyIsRefused

def downgraded (r : Record) (schema : Nat) (dropped : List String) : String :=
  recordEdited r fun kv => (kv.filter (!dropped.contains ·.1)).map fun (k, v) =>
    if k == "recordSchema" then (k, .num schema) else (k, v)

def rootsOf (r : Record) : Array (String × Option String) :=
  match r.checkout with
  | .read roots _ | .beforeSite roots => roots
  | .beforeSources => #[]

def keyCount (text key : String) : Nat := (text.splitOn s!"\"{key}\"").length - 1

def anOlderRecordReadsAsWhatItsPutReadAndWritesBackAsItWas : Bool :=
  withSample fun r _ _ =>
    let two := { r with checkout := .beforeSources }
    let three := { r with checkout := .beforeSite (rootsOf r) }
    (Record.parse (downgraded r 2 ["sources", "title"])).toOption == some two
      && (Record.parse (downgraded r 3 ["title"])).toOption == some three
      && [two, three].all (fun old => (Record.parse old.toJson).toOption == some old)
      && (keyCount two.toJson "sources", keyCount three.toJson "sources") == (0, 1)
      && [two, three].all (keyCount ·.toJson "title" == 0)
      && isError (Record.parse (recordWith r "recordSchema" (.num 5)))
      && isError (Record.parse (recordWith r "recordSchema" (.num 1)))

#guard anOlderRecordReadsAsWhatItsPutReadAndWritesBackAsItWas

def refusalOf : Except String α → String
  | .error why => why
  | .ok _ => ""

def mentions (text part : String) : Bool := (text.splitOn part).length ≥ 2

def anEntryWithoutTheSiteConfigurationOrTheSourceMapNeedsReputAndACurrentOneDoesNot : Bool :=
  withSample fun r _ _ =>
    let noSources := { r with checkout := .beforeSources }
    let noSite := { r with checkout := .beforeSite (rootsOf r) }
    let refusedAsInput := [noSources, noSite].map (refusalOf <| Data.inputOf · #[])
    let read := refusalOf (Data.inputOf r #[])
    refusedAsInput.all (mentions · "litedoc4 store put --version v4.32.2")
      && refusedAsInput.all (mentions · "site configuration")
      && mentions refusedAsInput[0]! "source map" && !mentions refusedAsInput[1]! "source map"
      && [noSources, noSite].all (isError <| checkoutOf ·)
      && (checkoutOf r).toOption == some { sources := rootsOf r, title := some "Sample" }
      && !mentions read "store put" && mentions read "index.json"

#guard anEntryWithoutTheSiteConfigurationOrTheSourceMapNeedsReputAndACurrentOneDoesNot

def coreRevision : String := "89abcdef0123456789abcdef0123456789abcdef"

def theRecordedMapIsTheLinkMapsRootsInByteOrderWithoutDocsAndCoreAsItWasLinkedBefore : Bool :=
  let links := (assembleLinks (.ok coreRevision) (.error "no manifest") #[]).links
  let withDeps := (mkExternalLinks (links.roots.map (fun r => (r.name, r.base))
      ++ #[("Batteries", "https://b/blob/r/"), ("Dep-Aux", "")])).withDocs
    #[("Mathlib", mkDepDocs "https://docs" #[("Mathlib.x", "./Mathlib.html#x")] #[]),
      ("Batteries", mkDepDocs "https://bdocs" #[] #[])]
  let core := s!"https://github.com/leanprover/lean4/blob/{coreRevision}"
  let expected := #[("Batteries", some "https://b/blob/r"), ("Dep-Aux", none),
    ("Init", some s!"{core}/src"), ("Lake", some s!"{core}/src/lake"), ("Lean", some s!"{core}/src"),
    ("Mathlib", none), ("Std", some s!"{core}/src")]
  sourceMapOf withDeps == expected
    && expected.all fun (root, base) =>
      (linksOf expected).sourceFor root == match base with
        | some b => .pinned b
        | none => .unpinned

def staleIsTheRecordedIdentityDifferingFromTheCurrentOneByContent : Bool :=
  withSample fun r a b =>
    !stale r a && stale r b && stale { r with extractorIdentity := b } a
      && ExtractorIdentity.of? "" == none && ExtractorIdentity.of? "a\nb" == none

#guard staleIsTheRecordedIdentityDifferingFromTheCurrentOneByContent

def identityFieldsOf (fields : List (String × String)) : String :=
  " ".intercalate (fields.map fun (k, v) => s!"{k}={v}")

def extractorFields : List (String × String) :=
  [("schema", "5"), ("source", "fnv1a64:6cc825bf93f26025"), ("lean", "4.31.0"),
   ("leanGithash", "89abcdef0123456789abcdef0123456789abcdef"), ("equations", "1"),
   ("taggedCode", "1"), ("refs", "1"), ("skipAnalyze", "0"), ("ablations", ""), ("open", ""),
   ("only", ""), ("noEquationsUnder", "")]

def withField (key value : String) : List (String × String) :=
  extractorFields.map fun (k, v) => if k == key then (k, value) else (k, v)

def staleAgainst (recorded current : List (String × String)) : Option Bool :=
  match VersionName.parse "v1", ExtractorIdentity.of? (identityFieldsOf recorded),
      ExtractorIdentity.of? (identityFieldsOf current) with
  | .ok v, some r, some c => some (stale (sampleRecordOf v r) c)
  | _, _, _ => none

def identitiesDifferingOnlyInLeanAndLeanGithashAreFreshAndAnyOtherFieldIsStale : Bool :=
  staleAgainst extractorFields
      ((withField "lean" "4.32.2").map fun (k, v) =>
        if k == "leanGithash" then (k, "f3b06c705e6c85f5314019d5d3baab0fec5b580c") else (k, v))
    == some false
    && (extractorFields.filter (!toolchainFields.contains ·.1)).all (fun (key, value) =>
      staleAgainst extractorFields (withField key (value ++ "x")) == some true)
    && staleAgainst extractorFields (extractorFields.filter (·.1 != "noEquationsUnder"))
      == some true
    && staleAgainst extractorFields (withField "noEquationsUnder" "Example") == some true

#guard identitiesDifferingOnlyInLeanAndLeanGithashAreFreshAndAnyOtherFieldIsStale

def anIdentityIsSpaceSeparatedFieldsEachAKeyOnceAndAnEqualsSign : Bool :=
  ((ExtractorIdentity.of? "a=1 b= c=x=y").map (·.fields))
      == some #[("a", "1"), ("b", ""), ("c", "x=y")]
    && ["a", "a=1  b=2", "=1", "a=1 a=2", "a=1 ", " a=1"].all (ExtractorIdentity.of? · == none)

#guard anIdentityIsSpaceSeparatedFieldsEachAKeyOnceAndAnEqualsSign

#guard theRecordedMapIsTheLinkMapsRootsInByteOrderWithoutDocsAndCoreAsItWasLinkedBefore

def theIdentityIsAskedForWithTheFlagsAnExtractionStartsWith : Bool :=
  [#[], #["Example.Tactic", "Example.Meta"]].all fun ns =>
    let asked := identityArgv ns
    let started := extractArgv "/bin/extract" "/m.txt" "/e.jsonl" "/ir" 4 ns none none none
    asked[0]! == "--identity"
      && started.extract 4 (4 + asked.size - 1) == asked.extract 1 asked.size
      && started[4 + asked.size - 1]! == "--jobs"

#guard theIdentityIsAskedForWithTheFlagsAnExtractionStartsWith

def parts (paths : List String) : Except String EntryParts :=
  entryParts (paths.toArray.map (·, bytesOf "xy"))

def anEntryIsTheIrUnderIrOneLinkIndexAndAtMostTheTwoSiteFiles : Bool :=
  (parts ["ir/index.json", "ir/modules/A.json", "link-index.lidx"]).toOption == some ⟨2, 4, 2⟩
    && (parts ["ir/index.json", "link-index.lidx", "site/index.md", "site/references.bib"]).toOption
      == some ⟨1, 2, 2⟩
    && [["ir/index.json"], ["link-index.lidx"], ["ir/index.json", "link-index.lidx", "x"],
        ["index.json", "link-index.lidx"], ["ir/index.json", "ir-link-index.lidx"],
        ["ir/index.json", "link-index.lidx", "site/title"],
        ["ir/index.json", "link-index.lidx", "references.bib"]].all
      (isError ∘ parts)

#guard anEntryIsTheIrUnderIrOneLinkIndexAndAtMostTheTwoSiteFiles

def anUnpackedEntryIsLaidOutAsBuildLaysOutItsOut : Bool :=
  let out : FilePath := "/o"
  (layoutOf out).ir == out / (irPrefix.dropEnd 1).toString
    && (layoutOf out).linkIndex == out / linkIndexEntry

#guard anUnpackedEntryIsLaidOutAsBuildLaysOutItsOut

/-! ## On disk -/

def scratch (name : String) : IO FilePath := do
  let dir : FilePath := ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩ / s!"litedoc4-lean-test-store-{name}"
  if ← dir.pathExists then IO.FS.removeDirAll dir
  IO.FS.createDirAll dir
  return dir

def irIndex (identity : Option String) : String :=
  "{\"schemaVersion\":5,\"generator\":\"litedoc4-test\",\"leanVersion\":\"4.31.0\""
    ++ (match identity with
      | some text => ",\"extractorIdentity\":\"" ++ text ++ "\""
      | none => "")
    ++ ",\"ablations\":[],\"modules\":[],\"dependencyMaps\":[]}"

def writeIr (dir : FilePath) (identity : Option String) (body : String) : IO Unit := do
  IO.FS.createDirAll (dir / "modules")
  IO.FS.createDirAll (dir / "deps" / "nested")
  IO.FS.writeFile (dir / "index.json") (irIndex identity)
  IO.FS.writeFile (dir / "modules" / "Example.Basic.json") body
  IO.FS.writeBinFile (dir / "deps" / "nested" / "map.bin") ⟨#[0, 10, 255, 10]⟩
  IO.FS.writeFile (dir / "deps" / "empty.json") ""

def lidxBytes : ByteArray := bytesOf "#lidx2\n@Init\n@Example\nInit.Core\n\tId\t10\t12\n"

def writeOut (out : FilePath) (identity : Option String) (body : String) : IO Unit := do
  writeIr (out / "ir") identity body
  IO.FS.writeBinFile (out / "link-index.lidx") lidxBytes

def testOrigin : Origin :=
  { commit := "0123456789abcdef0123456789abcdef01234567"
    leanGithash := "89abcdef0123456789abcdef0123456789abcdef"
    sourceUrl := "https://github.com/o/r/blob/0123456789abcdef0123456789abcdef01234567"
    dependencies := #[{ name := "micro-dep", rev := none }]
    sources := mkExternalLinks #[("Init", "https://core/blob/r/src"), ("Dep-Aux", "")]
    site := { title := some "T", indexMarkdown := some "# Front\n"
              bibliography := some "@misc{K,\n  author = {Ann Author},\n  title = {A Title},\n  year = {2020}\n}\n" } }

def putOut (store : FilePath) (v : VersionName) (out : FilePath) : IO PutSummary :=
  put store v testOrigin (out / "ir") (out / "link-index.lidx")

def versionNamed (s : String) : IO VersionName := do
  match VersionName.parse s with
  | .ok v => return v
  | .error why => throw (IO.userError why)

def messageOf (act : IO α) : IO (Option String) := do
  try
    let _ ← act
    return none
  catch e => return some (toString e)

def says (message : Option String) (parts : List String) : Bool :=
  match message with
  | none => false
  | some text => parts.all fun part => (text.splitOn part).length ≥ 2

def namesIn (dir : FilePath) : IO (List String) := do
  return ((← dir.readDir).map (·.fileName)).qsort byteLt |>.toList

def anEntryReadsBackByteForByteAndItsRecordCountsWhatTheIrHolds : Invariant where
  name := "an entry reads back byte for byte, to memory and to a directory, its record counts the \
    IR, and its site configuration reads back as the put read it"
  check := do
    let dir ← scratch "round-trip"
    let build := dir / "build"
    writeOut build (some identityAText) "{\"module\":\"Example.Basic\"}"
    let v1 ← versionNamed "v1"
    let tree := (← readTree build) ++ siteFiles testOrigin.site |>.qsort (fun a b => byteLt a.1 b.1)
    let ir ← readTree (build / "ir")
    let put ← putOut (dir / "store") v1 build
    let back ← read (dir / "store") v1
    unpackTo (dir / "out") back.files
    let unpacked ← readTree (dir / "out")
    let r := put.record
    let site := (Data.inputOf back.record back.files).toOption.map (·.site)
    let answer := first [
      if samePairs back.files tree then none
        else some "read gave other files than the IR and the link index",
      if samePairs (unpacked.qsort (fun a b => byteLt a.1 b.1)) tree then none
        else some "the unpacked directory is not laid out as the build directory was",
      eq (r.irFiles, r.irBytes, r.linkIndexBytes)
        (ir.size, ir.foldl (fun n f => n + f.2.size) 0, lidxBytes.size),
      eq (r.extractorIdentity.text, r.leanVersion, r.commit) (identityAText, "4.31.0", testOrigin.commit),
      eq r.checkout (.read #[("Dep-Aux", none), ("Init", some "https://core/blob/r/src")] (some "T")),
      eq (back.record == r) true,
      eq ((back.files.map (·.1)).filter (·.startsWith "site/")).toList ["site/index.md", "site/references.bib"],
      eq (site.map fun c => (c.title, c.indexMarkdown, c.bibliography.items.map (·.citekey)))
        (some (some "T", some "# Front\n", #["K"]))]
    IO.FS.removeDirAll dir
    return answer

def replacingAnEntryLeavesOnlyTheNewEntryAndNoStagingDirectory : Invariant where
  name := "replacing an entry leaves the new one and nothing beside it, a crashed put's staging included"
  check := do
    let dir ← scratch "replace"
    let store := dir / "store"
    writeOut (dir / "old") (some identityAText) "old"
    writeOut (dir / "new") (some identityBText) "new and longer"
    let v1 ← versionNamed "v1"
    let _ ← putOut store v1 (dir / "old")
    IO.FS.createDirAll (stagingDir store v1 / "leftover")
    let _ ← putOut store v1 (dir / "new")
    let names ← namesIn store
    let back ← read store v1
    let body := back.files.find? (·.1 == "ir/modules/Example.Basic.json") |>.map (·.2)
    let answer := first [
      eq names ["v1"],
      eq back.record.extractorIdentity.text identityBText,
      eq (body.map (·.toList)) (some (bytesOf "new and longer").toList)]
    IO.FS.removeDirAll dir
    return answer

def aTamperedPackIsRefusedByItsDigestOrItsLengthNamingTheEntry : Invariant where
  name := "a pack changed in one byte, or cut short, is refused before decompressing, naming the entry"
  check := do
    let dir ← scratch "tamper"
    let store := dir / "store"
    writeOut dir (some identityAText) "{}"
    let v1 ← versionNamed "v1"
    let _ ← putOut store v1 dir
    let pack := entryDir store v1 / packFile
    let original ← IO.FS.readBinFile pack
    let middle := original.size / 2
    IO.FS.writeBinFile pack (original.set! middle (original[middle]! ^^^ 1))
    let flipped ← messageOf (read store v1)
    IO.FS.writeBinFile pack (original.extract 0 (original.size - 1))
    let cut ← messageOf (read store v1)
    IO.FS.writeBinFile pack original
    let intact ← messageOf (read store v1)
    let answer := first [
      if says flipped ["store entry v1", "SHA-256"] then none
        else some s!"a flipped byte was answered {flipped}",
      if says cut ["store entry v1", "bytes and its record says"] then none
        else some s!"a pack one byte short was answered {cut}",
      eq intact none]
    IO.FS.removeDirAll dir
    return answer

def anIrWithNoIdentityIsRefusedAndLeavesNothingInTheStore : Invariant where
  name := "an IR whose index carries no extractorIdentity is refused and leaves nothing in the store"
  check := do
    let dir ← scratch "no-identity"
    let store := dir / "store"
    IO.FS.createDirAll store
    writeOut dir none "{}"
    let v1 ← versionNamed "v1"
    let refused ← messageOf (putOut store v1 dir)
    let names ← namesIn store
    let answer := first [
      if says refused ["extractorIdentity"] then none
        else some s!"an IR with no identity was answered {refused}",
      eq names []]
    IO.FS.removeDirAll dir
    return answer

def anOutWithNoLinkIndexIsRefusedNamingItAndLeavesNothingInTheStore : Invariant where
  name := "a build directory with no link index is refused, naming the file, and leaves nothing in the store"
  check := do
    let dir ← scratch "no-link-index"
    let store := dir / "store"
    IO.FS.createDirAll store
    writeIr (dir / "ir") (some identityAText) "{}"
    let v1 ← versionNamed "v1"
    let refused ← messageOf (putOut store v1 dir)
    let names ← namesIn store
    let answer := first [
      if says refused [(dir / "link-index.lidx").toString, "no link index"] then none
        else some s!"a build directory with no link index was answered {refused}",
      eq names []]
    IO.FS.removeDirAll dir
    return answer

def theListingIsByteOrderAndSkipsStagingAndNamesStrays : Invariant where
  name := "list gives entries in byte order, skips staging siblings and names what is not a version"
  check := do
    let dir ← scratch "list"
    let store := dir / "store"
    writeOut dir (some identityAText) "{}"
    for name in ["v2", "v10", "a"] do
      let _ ← putOut store (← versionNamed name) dir
    IO.FS.createDirAll (store / ".put-v3")
    IO.FS.createDirAll (store / "not a version")
    let listing ← list store
    let answer := first [
      eq (listing.entries.map (·.1.text)).toList ["a", "v10", "v2"],
      eq listing.strays.toList ["not a version"],
      eq (listing.entries.all fun e => e.2.toOption.isSome) true]
    IO.FS.removeDirAll dir
    return answer

end Litedoc4Test
