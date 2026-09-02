/- The whole stage, over an IR tree written here.

Rust runs the same sequence a second time over the measurement target and
`#[ignore]`s it; that one is a gate's question and not a test's, and it is not
here. What is here is the synthetic half, which is the one that says the cache is
correct rather than that it is fast. -/
import Litedoc4.Global
import Litedoc4Test.GlobalArtifacts

namespace Litedoc4Test
open Litedoc4 System

structure SynthModule where
  name : String
  imports : Array String := #[]
  /-- `(declaration name, docstring)`. -/
  decls : Array (String × String) := #[]
  deriving Inhabited

def synthModuleJson (m : SynthModule) : String := Id.run do
  let mut o := jsonStr "{\"module\":" m.name
  o := o ++ ",\"schemaVersion\":5,\"imports\":["
  let mut first := true
  for name in m.imports do
    if !first then o := o.push ','
    first := false
    o := jsonStr o name
  o := jsonStr (o ++ "],\"moduleDocs\":[{\"line\":1,\"col\":0,\"text\":") s!"# {m.name}"
  o := o ++ "}],\"declarations\":["
  first := true
  for (name, doc) in m.decls do
    if !first then o := o.push ','
    first := false
    o := jsonStr (o ++ "{\"name\":") name
    o := jsonStr (o ++ ",\"kind\":\"def\",\"doc\":") doc
    o := o ++ ",\"typeCode\":[],\"refs\":[],\"attrs\":[],\"members\":[]}"
  return o ++ "],\"tactics\":[]}"

/-- `contentHash` is Lean's hash of the module's own text, which is what the
extractor writes. Anything constant would make the third state below — a module
whose bytes changed — a hit, and the sequence would hold with no cache key at
all. -/
def writeSyntheticIr (dir : FilePath) (modules : Array SynthModule) : IO Unit := do
  if ← dir.pathExists then IO.FS.removeDirAll dir
  IO.FS.createDirAll (dir / "modules")
  let mut entries := ""
  let mut first := true
  for m in modules do
    let text := synthModuleJson m
    let file := s!"modules/{m.name}.json"
    IO.FS.writeFile (irPath dir file) text
    if !first then entries := entries.push ','
    first := false
    entries := jsonStr (entries ++ "{\"module\":") m.name
    entries := jsonStr (entries ++ ",\"file\":") file
    entries := entries ++ s!",\"bytes\":{text.utf8ByteSize},\"contentHash\":\"{text.hash}\"" ++ "}"
  IO.FS.writeFile (dir / "index.json")
    ("{\"schemaVersion\":5,\"generator\":\"litedoc4-test\",\"leanVersion\":\"4.31.0\""
      ++ ",\"ablations\":[],\"modules\":[" ++ entries ++ "],\"dependencyMaps\":[]}")

def baseModules : Array SynthModule := #[
  { name := "Pkg", decls := #[("Pkg.a", "The root, which `Pkg.B.b` uses.")] },
  { name := "Pkg.B", imports := #["Pkg"], decls := #[("Pkg.B.b", "Built on `Pkg.a`.")] },
  { name := "Pkg.C", imports := #["Pkg"], decls := #[("Pkg.C.c", "")] },
  { name := "Pkg.D", imports := #["Pkg.B"], decls := #[("Pkg.D.d", "")] },
  { name := "Pkg.E", imports := #["Pkg.B"], decls := #[("Pkg.E.e", "")] }]

def modifiedModules : Array SynthModule :=
  baseModules.set! 0 { baseModules[0]! with decls := #[("Pkg.a_renamed", "The root.")] }

def removedModules : Array SynthModule := modifiedModules.extract 0 3

def addedModules : Array SynthModule :=
  removedModules.push { name := "Pkg.F", imports := #["Pkg"], decls := #[("Pkg.F.f", "")] }

def sameBytes (a b : ByteArray) : Bool :=
  a.size == b.size && (Array.range a.size).all fun i => a.get! i == b.get! i

def sameSite (a b : Array (String × ByteArray)) : Option String := Id.run do
  if a.size != b.size then return some s!"{a.size} artifact(s) against {b.size}"
  for i in [0:a.size] do
    if !sameBytes a[i]!.2 b[i]!.2 then return some s!"{a[i]!.1} differs"
  return none

def buildOnce (work : FilePath) (modules : Array SynthModule) (state : Option FilePath) :
    IO (Nat × Nat × Array (String × ByteArray)) := do
  let ir := work / "ir"
  let out := work / "site"
  writeSyntheticIr ir modules
  if ← out.pathExists then IO.FS.removeDirAll out
  let summary ← buildGlobal { ir, out, state }
  let mut files : Array (String × ByteArray) := #[]
  for path in artifactPaths do
    files := files.push (path, ← IO.FS.readBinFile (irPath out path))
  return (summary.cacheHits, summary.cacheMisses, files)

partial def relativeFiles (root : FilePath) (rel : String) : IO (Array String) := do
  let mut out : Array String := #[]
  for entry in ← root.readDir do
    let name := if rel.isEmpty then entry.fileName else rel ++ "/" ++ entry.fileName
    if ← entry.path.isDir then out := out ++ (← relativeFiles entry.path name)
    else out := out.push name
  return out

/-- The pid is in the name because two `litedoc4-test` processes can share a
`TMPDIR` — a local run beside a gate's, or two gates on one machine — and a
fixed name makes each one delete the other's tree mid-run. The failure would
read as the invariant being false rather than as the work area being shared,
which is the shape CLAUDE.md records for `litedoc4 watch`. -/
def workDir : IO FilePath := do
  return ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩ / s!"litedoc4-lean-test-global-{← IO.Process.getPID}"

/-- Eight builds of one package, seven of them through the cache. The counts are
deterministic integers on purpose — wall clock moves by 5× with the page cache
and would say nothing about whether the cache is *right*.

**The site is compared as well as the counts**, against the run that had no
cache at all. A cache is correct only if the artifacts do not depend on it, and
the counts alone cannot see a hit that served the wrong facts. -/
def theCacheSequenceAgreesWithAFromScratchBuild : Invariant where
  name := "the seven states of the --state cache hit and miss as many as they should, \
    and every run over the same tree writes the same site"
  check := do
    let work ← workDir
    if ← work.pathExists then IO.FS.removeDirAll work
    IO.FS.createDirAll work
    let state := work / "state"
    let n := baseModules.size
    -- 0. no --state at all: what the cache has to keep agreeing with.
    let (h0, m0, site) ← buildOnce work baseModules none
    -- 1. --state on, and nothing in it yet.
    let (h1, m1, site1) ← buildOnce work baseModules (some state)
    -- 2. the same tree again: every module is a hit and the bytes must not move.
    let (h2, m2, site2) ← buildOnce work baseModules (some state)
    -- 3. one module's bytes change, and the hash moves with them.
    let (h3, m3, _) ← buildOnce work modifiedModules (some state)
    -- 4. two modules disappear; the index is the authority on what exists, so
    --    their cache entries go with them.
    let (h4, m4, _) ← buildOnce work removedModules (some state)
    -- 5. a module appears, with a declaration nothing has seen.
    let (h5, m5, _) ← buildOnce work addedModules (some state)
    -- 6. back to the original tree, with a state that has seen all of the
    --    above. A cache that only ever grows passes every step so far and fails
    --    this one.
    let (h6, m6, site6) ← buildOnce work baseModules (some state)
    -- 7. a state written by a different derivation is a guess, not a cache.
    let stale := (← IO.FS.readFile (state / stateFile)).replace stateDerivation "an older rule"
    IO.FS.writeFile (state / stateFile) stale
    let (h7, m7, site7) ← buildOnce work baseModules (some state)
    if ← work.pathExists then IO.FS.removeDirAll work
    return first [
      eq (h0, m0) (0, n),
      eq (h1, m1) (0, n),
      eq (h2, m2) (n, 0),
      eq (h3, m3) (n - 1, 1),
      eq (h4, m4) (n - 2, 0),
      eq (h5, m5) (n - 2, 1),
      eq (h6, m6) (n - 3, 3),
      eq (h7, m7) (0, n),
      sameSite site site1, sameSite site site2, sameSite site site6, sameSite site site7]

/-- The tree a build leaves behind is exactly `artifactFiles`, named rather than
counted: "nine files came out" would still hold if one came back under an old
name and another went. Every body is non-empty, because an artifact written as
zero bytes is a page that loads and a fetch that parses to nothing. -/
def theSiteTreeIsExactlyTheWholePackageArtifacts : Invariant where
  name := "a build writes the whole-package artifacts and nothing else, none of them empty"
  check := do
    let root ← workDir
    let work := root / "tree"
    if ← root.pathExists then IO.FS.removeDirAll root
    IO.FS.createDirAll work
    let (_, _, files) ← buildOnce work baseModules none
    let written ← relativeFiles (work / "site") ""
    -- The root and not `work`: `createDirAll` made both, and removing only the
    -- leaf leaves one empty directory per run in a shared `TMPDIR`.
    if ← root.pathExists then IO.FS.removeDirAll root
    return first [
      eq (sortUtf16 written) (sortUtf16 artifactPaths),
      eq (files.filterMap (fun (path, body) => if body.isEmpty then some path else none)) #[]]

end Litedoc4Test
