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
        \"versionsRendered\":null}\n"
    && versionsMarkerJson "/r" "/s" all (some { extracted := named #["v2"], rendered := named #["v1"] })
      == "{\"tool\":\"litedoc4 build\",\"layout\":" ++ toString layoutVersion ++ ",\"root\":\"/r\",\
        \"store\":\"/s\",\"versions\":[\"v1\",\"v2\"],\"complete\":true,\
        \"versionsExtracted\":{\"count\":1,\"of\":2,\"names\":[\"v2\"]},\
        \"versionsRendered\":{\"count\":1,\"of\":2,\"names\":[\"v1\"]}}\n"

#guard aMarkerIsCompleteOnlyWithTheVersionsItExtractedAndRendered

def theRenderLedgerIsAmongWhatAVersionedBuildOwnsAndOutsideTheSite : Bool :=
  ownedNames.contains renderLedgerName && renderLedgerName != siteName
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
  | .ok repo => plan repo (named names.toArray) #["leanprover/lean4:v4.31.0"]

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
