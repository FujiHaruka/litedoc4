import Litedoc4.Versions
import Litedoc4Test.Basis

namespace Litedoc4Test
namespace VersionsTest
open Litedoc4 Litedoc4.Versions System

def named (names : Array String) : Array Store.VersionName :=
  names.filterMap (Store.VersionName.parse · |>.toOption)

def theToolchainsAreTheFirstColumnOfEveryRowAndNoComment : Bool :=
  toolchainRows "# toolchain   attr\n\nleanprover/lean4:v4.31.0     a\n  leanprover/lean4:v4.33.0 b\n"
      == #["leanprover/lean4:v4.31.0", "leanprover/lean4:v4.33.0"]
    && !supportedToolchains.isEmpty
    && supportedToolchains.all (·.startsWith "leanprover/lean4:v")

#guard theToolchainsAreTheFirstColumnOfEveryRowAndNoComment

def theMathlibCacheIsFetchedForMathlibAndWhatRequiresItAndForNothingElse : Bool :=
  let asks (text : String) :=
    (parseManifest "lake-manifest.json" text).toOption.map fetchesMathlibCache
  let path (name : String) := s!"\{\"type\":\"path\",\"name\":\"{name}\",\"dir\":\"../{name}\"}"
  asks s!"\{\"name\":\"mathlib\",\"packages\":[{path "batteries"}]}" == some true
    && asks s!"\{\"name\":\"probe\",\"packages\":[{path "batteries"},{path "mathlib"}]}" == some true
    && asks s!"\{\"name\":\"micro\",\"packages\":[{path "«micro-dep»"}]}" == some false
    && asks s!"\{\"packages\":[{path "mathlib-extras"}]}" == some false

#guard theMathlibCacheIsFetchedForMathlibAndWhatRequiresItAndForNothingElse

def aToolchainWithNoRowIsRefusedNamingTheVersionAndTheToolchain : Bool :=
  let rows := #["leanprover/lean4:v4.31.0"]
  (named #["v6"]).size == 1 && (named #["v6"]).all fun v =>
    unlistedToolchain v "abc" "leanprover/lean4:v4.31.0" rows == none
      && match unlistedToolchain v "abc" "leanprover/lean4:v4.34.1" rows with
        | some m => m.startsWith "version v6 (abc) pins `leanprover/lean4:v4.34.1`, which has no row"
        | none => false

#guard aToolchainWithNoRowIsRefusedNamingTheVersionAndTheToolchain

def theExtractedLineCountsAgainstTheVersionListAndNamesWhatRan : Bool :=
  let all := named #["v1", "v2", "v3", "v4", "v5"]
  extractedLine all (named #["v3"]) == "versions extracted: 1 of 5 (v3)"
    && extractedLine all #[] == "versions extracted: 0 of 5 ()"
    && extractedLine all all == "versions extracted: 5 of 5 (v1, v2, v3, v4, v5)"

#guard theExtractedLineCountsAgainstTheVersionListAndNamesWhatRan

def theExtractedLineNamesWhatTheReaderFilledAndOnlyThen : Bool :=
  let all := named #["v1", "v2", "v3"]
  extractedLine all all (named #["v1", "v2"])
      == "versions extracted: 3 of 3 (v1, v2, v3), through the reader: 2 (v1, v2)"
    && extractedLine all (named #["v3"]) #[] == "versions extracted: 1 of 3 (v3)"

#guard theExtractedLineNamesWhatTheReaderFilledAndOnlyThen

def fillNames (fills : Array Store.Fill) : List String := fills.toList.map Store.Fill.name

def theReaderFillsOlderVersionsOnlyFromNothingWithTheNewestOnItsToolchain : Bool :=
  let vs := named #["v1", "v2", "v3"]
  let empty := #[Held.absent, .absent, .absent]
  fillNames (fillsOf vs empty true #[]) == ["reader", "reader", "own"]
    && fillNames (fillsOf vs empty false #[]) == ["own", "own", "own"]
    && fillNames (fillsOf vs #[.absent, .absent, .filled .own] true #[]) == ["reader", "reader", "own"]
    && fillNames (fillsOf vs #[.filled .own, .absent, .absent] true #[]) == ["own", "own", "own"]
    && fillNames (fillsOf vs #[.unreadable, .absent, .absent] true #[]) == ["own", "own", "own"]
    && fillNames (fillsOf vs #[.filled .reader, .absent, .absent] true #[])
      == ["reader", "own", "own"]
    && fillNames (fillsOf vs #[.filled .own, .filled .own, .absent] true (named #["v2"]))
      == ["own", "reader", "own"]
    && fillNames (fillsOf vs empty false (named #["v1"])) == ["reader", "own", "own"]
    && fillNames (fillsOf (named #["v1"]) #[.absent] true #[]) == ["own"]

#guard theReaderFillsOlderVersionsOnlyFromNothingWithTheNewestOnItsToolchain

def plannedAt (names : Array String) (toolchain : String) : Array Planned :=
  (named names).map fun name => { name, commit := "abc", toolchain }

def theForcingFlagIsRefusedByNameOutsideTheSetOnTheNewestAndOffTheReadersToolchain : Bool :=
  let vs := named #["v1", "v2", "v3"]
  (plannedAt #["v3"] "leanprover/lean4:v4.34.1").all fun onReader =>
  (plannedAt #["v3"] "leanprover/lean4:v4.32.2").all fun offReader =>
  let says (r : Option (UInt32 × String)) (code : UInt32) (start : String) : Bool :=
    match r with
    | some (c, m) => c == code && m.startsWith start
    | none => false
  throughReaderRefusal vs onReader "leanprover/lean4:v4.34.1" (named #["v1"]) == none
    && throughReaderRefusal vs offReader "leanprover/lean4:v4.34.1" #[] == none
    && says (throughReaderRefusal vs onReader "leanprover/lean4:v4.34.1" (named #["v9"])) 2
      "--through-reader names v9, which --versions does not"
    && says (throughReaderRefusal vs onReader "leanprover/lean4:v4.34.1" (named #["v3"])) 2
      "--through-reader names v3, the newest version"
    && says (throughReaderRefusal vs offReader "leanprover/lean4:v4.34.1" (named #["v1"])) 3
      "--through-reader: the newest version v3 (abc) pins `leanprover/lean4:v4.32.2`, and the \
        reader runs on `leanprover/lean4:v4.34.1`"
    && (readerUnavailable (named #["v1", "v2"]) offReader "leanprover/lean4:v4.34.1").startsWith
      "v1, v2 were filled through the reader and have to be filled again, and the newest version v3"

#guard theForcingFlagIsRefusedByNameOutsideTheSetOnTheNewestAndOffTheReadersToolchain

def aToolchainWithNoRowIsRefusedOnlyForAVersionFilledNatively : Bool :=
  let rows := #["leanprover/lean4:v4.31.0"]
  let planned := plannedAt #["v1"] "leanprover/lean4:v4.29.0"
    ++ plannedAt #["v2"] "leanprover/lean4:v4.31.0"
  planned.size == 2 && unlistedNative planned #[.reader, .own] rows == none
    && match unlistedNative planned #[.own, .own] rows with
      | some m => m.startsWith "version v1 (abc) pins `leanprover/lean4:v4.29.0`, which has no row"
      | none => false

#guard aToolchainWithNoRowIsRefusedOnlyForAVersionFilledNatively

def theCutRemovesTheTrailingMainAndRefusesAnyOtherShape : Bool :=
  (cutMain "def a := 1\n\ndef main : IO Unit := pure ()\n  -- body\n\n").toOption
      == some "def a := 1\n"
    && (cutMain "def a := 1\ndef main_loop := 2\ndef main := 3\n").toOption
      == some "def a := 1\ndef main_loop := 2\n"
    && (match cutMain "def a := 1\n" with
      | .error m => m.startsWith "0 top-level `def main` lines"
      | .ok _ => false)
    && (match cutMain "def main := 1\ndef main := 2\n" with
      | .error m => m.startsWith "2 top-level `def main` lines"
      | .ok _ => false)
    && (match cutMain "def main := 1\nend Foo\n" with
      | .error m => m == "`def main` is not the last declaration: `end Foo` follows it"
      | .ok _ => false)

#guard theCutRemovesTheTrailingMainAndRefusesAnyOtherShape

def theReaderIsBuiltOnTheLastRowOutOfEveryEmbeddedSourceAndTheCutExtractor : Bool :=
  match readerBuild with
  | .error _ => false
  | .ok b =>
    some b.toolchain == supportedToolchains.back?
      && b.files.map (·.1) == #["Extract.lean"] ++ readerSources.map (·.1)
      && b.dirName.startsWith s!"reader-{toolchainDirName b.toolchain}-"
      && readerSources.all (fun (path, text) => path.startsWith "OleanReader/" && !text.isEmpty)
      && (readerBuildOf #[] extractorSource readerSources).toOption.isNone
      && (match readerBuildOf supportedToolchains "def a := 1\n" readerSources with
        | .error m => m.startsWith "extractor/Extract.lean cannot be cut for the reader"
        | .ok _ => false)

#guard theReaderIsBuiltOnTheLastRowOutOfEveryEmbeddedSourceAndTheCutExtractor

def theReaderIsHandedTheExtractorsOwnFlagsAfterTheTwoSearchPaths : Bool :=
  readerArgv #["/o1", "/o2"] #["/n"] "/r.txt" "/m.txt" "/e.jsonl" "/ir" 2 #[] "/l.lidx"
    == #["extract", "--old", "/o1", "--old", "/o2", "--new", "/n", "--new-roots", "/r.txt"]
      ++ extractorArgs "/m.txt" "/e.jsonl" "/ir" 2 #[] (some "/l.lidx") (some "/m.txt") none
    && extractArgv "/bin" "/m.txt" "/e.jsonl" "/ir" 2 #[] none none none
      == #["env", "/bin", "/m.txt", "/e.jsonl", "--equations", "--refs", "--write-ir",
        "--tagged-code", "--jobs", "2", "--ir-dir", "/ir"]

#guard theReaderIsHandedTheExtractorsOwnFlagsAfterTheTwoSearchPaths

def onlyADirectoryOutsideTheNewestCheckoutAndItsLeanIsShared : Bool :=
  sharedSearchDirs #["/o/micro-dep/.lake/build/lib/lean", "/o/checkout/.lake/build/lib/lean",
      "/o/checkout/.lake/packages/mathlib/.lake/build/lib/lean", "/e/toolchains/v4.34.1/lib/lean",
      "/o/checkout-read/.lake/build/lib/lean"] "/o/checkout" "/e/toolchains/v4.34.1"
    == #["/o/micro-dep/.lake/build/lib/lean", "/o/checkout-read/.lake/build/lib/lean"]

#guard onlyADirectoryOutsideTheNewestCheckoutAndItsLeanIsShared

def freeDiskIsTheAvailableColumnOfDfInKibibytes : Bool :=
  dfAvailableBytes "Filesystem 1024-blocks Used Available Capacity Mounted on\n\
      /dev/disk3s1s1 239362496 12599092 8474844 60% /\n" == some (8474844 * 1024)
    && dfAvailableBytes "" == none
    && diskLine "v1 read" (some (8 * 1024 * 1024 * 1024)) == "disk    v1 read 8.00 GiB free"

#guard freeDiskIsTheAvailableColumnOfDfInKibibytes

def theRenderedLineCountsAgainstTheVersionListAndNamesWhatWasRendered : Bool :=
  let all := named #["v1", "v2", "v3", "v4", "v5"]
  renderedLine all (named #["v5"]) == "versions rendered: 1 of 5 (v5)"
    && renderedLine all #[] == "versions rendered: 0 of 5 ()"

#guard theRenderedLineCountsAgainstTheVersionListAndNamesWhatWasRendered

def aMarkerIsCompleteOnlyWithTheVersionsItExtractedAndRendered : Bool :=
  let all := named #["v1", "v2"]
  versionsMarkerJson "/r" "/s" all none
      == "{\"tool\":\"litedoc4 build\",\"layout\":" ++ toString layoutVersion ++ ",\"root\":\"/r\",\
        \"store\":\"/s\",\"versions\":[\"v1\",\"v2\"],\"complete\":false,\"versionsExtracted\":null,\
        \"versionsThroughReader\":null,\"versionsRendered\":null}\n"
    && versionsMarkerJson "/r" "/s" all (some
        { extracted := named #["v1", "v2"], rendered := named #["v1"], read := named #["v1"] })
      == "{\"tool\":\"litedoc4 build\",\"layout\":" ++ toString layoutVersion ++ ",\"root\":\"/r\",\
        \"store\":\"/s\",\"versions\":[\"v1\",\"v2\"],\"complete\":true,\
        \"versionsExtracted\":{\"count\":2,\"of\":2,\"names\":[\"v1\",\"v2\"]},\
        \"versionsThroughReader\":{\"count\":1,\"of\":2,\"names\":[\"v1\"]},\
        \"versionsRendered\":{\"count\":1,\"of\":2,\"names\":[\"v1\"]}}\n"

#guard aMarkerIsCompleteOnlyWithTheVersionsItExtractedAndRendered

def theRenderLedgerIsAmongWhatAVersionedBuildOwnsAndOutsideTheSite : Bool :=
  ownedNames.contains renderLedgerName && renderLedgerName != siteName
    && ownedNames.contains readCheckoutName && readCheckoutName != checkoutName
    && ownedNames.contains newestCopiesName
    && (layoutOf "/o").renderLedger == ("/o" : FilePath) / renderLedgerName

#guard theRenderLedgerIsAmongWhatAVersionedBuildOwnsAndOutsideTheSite

def aToolchainBecomesOneDirectoryName : Bool :=
  toolchainDirName "leanprover/lean4:v4.32.2" == "leanprover-lean4-v4.32.2"

#guard aToolchainBecomesOneDirectoryName

def scratch (name : String) : IO FilePath := do
  let dir : FilePath :=
    ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩ / s!"litedoc4-lean-test-versions-{name}-{← IO.Process.getPID}"
  if ← dir.pathExists then IO.FS.removeDirAll dir
  IO.FS.createDirAll dir
  return dir

def git (dir : FilePath) (args : List String) : IO Unit := do
  let out ← IO.Process.output
    { cmd := "git", args := #["-C", dir.toString, "-c", "user.name=t", "-c",
        "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"]
        ++ args.toArray }
  if out.exitCode != 0 then throw (IO.userError s!"git {args}: {out.stderr}")

def planOf (root : FilePath) (names : List String) : IO (Except String (Array Planned)) := do
  match ← repositoryOf root with
  | .error why => return .error why
  | .ok repo => return (← plan repo (named names.toArray)).bind fun planned =>
    match unlistedNative planned (planned.map fun _ => .own) #["leanprover/lean4:v4.31.0"] with
    | some why => .error why
    | none => .ok planned

def refusal : Except String α → String
  | .error why => why
  | .ok _ => ""

def everyVersionIsRefusedByNameBeforeAnythingIsCheckedOut : Invariant where
  name := "--versions refuses a root outside git, a ref that resolves to no commit, a commit \
    with no lean-toolchain and one whose toolchain has no row, each by name, and plans the rest"
  check := do
    let dir ← scratch "plan"
    let outside := dir / "outside"
    IO.FS.createDirAll outside
    let repo := dir / "repo"
    IO.FS.createDirAll (repo / "pkg")
    git repo ["init", "-q"]
    IO.FS.writeFile (repo / "pkg" / "lean-toolchain") "leanprover/lean4:v4.31.0\n"
    git repo ["add", "."]
    git repo ["commit", "-q", "-m", "a"]
    git repo ["tag", "good"]
    IO.FS.writeFile (repo / "pkg" / "lean-toolchain") "leanprover/lean4:v4.34.1\n"
    git repo ["commit", "-q", "-am", "b"]
    git repo ["tag", "unlisted"]
    IO.FS.removeFile (repo / "pkg" / "lean-toolchain")
    git repo ["commit", "-q", "-am", "c"]
    git repo ["tag", "none"]
    let good ← planOf (repo / "pkg") ["good"]
    let notGit := refusal (← planOf outside ["good"])
    let unresolved := refusal (← planOf (repo / "pkg") ["good", "nope"])
    let unlisted := refusal (← planOf (repo / "pkg") ["good", "unlisted"])
    let noFile := refusal (← planOf (repo / "pkg") ["none"])
    let says (text part : String) := (text.splitOn part).length ≥ 2
    let answer := first [
      if notGit.startsWith "--versions reads the versions out of --root's git refs, and" then none
        else some s!"outside git: {notGit}",
      if unresolved.startsWith "version nope: `nope` is not a tag, a branch or a commit of" then none
        else some s!"unresolved: {unresolved}",
      if unlisted.startsWith "version unlisted (" &&
          says unlisted "pins `leanprover/lean4:v4.34.1`, which has no row" then none
        else some s!"unlisted: {unlisted}",
      if noFile.startsWith "version none (" && says noFile "has no pkg/lean-toolchain" then none
        else some s!"no lean-toolchain: {noFile}",
      eq (good.toOption.map (·.map (·.toolchain))) (some #["leanprover/lean4:v4.31.0"])]
    IO.FS.removeDirAll dir
    return answer

end VersionsTest
end Litedoc4Test
