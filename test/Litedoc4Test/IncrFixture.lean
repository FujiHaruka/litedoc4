/- The trees the incremental stages' run-time invariants are asked about.

Every stage here reads and writes directories, and none of them owns a corpus, so
the input is written on the way in and removed on the way out. The work area
carries the process id: `litedoc4-test` is one executable a gate may run while
another copy of it is running, and two runs sharing a directory make each other's
failures look like the stage's. -/
import Litedoc4.Ir
import Litedoc4.JsonWrite
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4 System

def incrWorkDir (name : String) : IO FilePath := do
  let base : FilePath := ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩
  let dir := base / s!"litedoc4-lean-test-incr-{name}-{← IO.Process.getPID}"
  if ← dir.pathExists then IO.FS.removeDirAll dir
  IO.FS.createDirAll dir
  return dir

def removeDir (dir : FilePath) : IO Unit := do
  if ← dir.pathExists then IO.FS.removeDirAll dir

def writeUnder (dir : FilePath) (relative body : String) : IO Unit := do
  let path := irPath dir relative
  if let some parent := path.parent then IO.FS.createDirAll parent
  IO.FS.writeFile path body

/-- A module's references, as `(defining module, name)` — the pair the IR stores
because the printed token and the constant it links to often have no textual
relation. -/
abbrev SynthRefs := Array (String × String)

structure SynthIrModule where
  name : String
  schemaVersion : Nat := 5
  imports : Array String := #[]
  /-- One declaration per entry, named after the module. -/
  decls : Array (String × SynthRefs) := #[]
  /-- Reaches `index.json`'s `contentHash`, which is what `merge` compares to
  decide a module's IR moved. -/
  contentHash : String := "1111111111111111"
  deriving Inhabited

def synthIrModuleJson (m : SynthIrModule) : String := Id.run do
  let mut o := jsonStr "{\"module\":" m.name
  o := o ++ s!",\"schemaVersion\":{m.schemaVersion},\"imports\":["
  let mut first := true
  for name in m.imports do
    if !first then o := o.push ','
    first := false
    o := jsonStr o name
  o := o ++ "],\"moduleDocs\":[],\"declarations\":["
  first := true
  for (name, refs) in m.decls do
    if !first then o := o.push ','
    first := false
    o := jsonStr (o ++ "{\"name\":") name
    o := o ++ ",\"kind\":\"def\",\"doc\":\"\",\"typeCode\":[],\"attrs\":[],\"members\":[],\"refs\":["
    let mut firstRef := true
    for (owner, refName) in refs do
      if !firstRef then o := o.push ','
      firstRef := false
      o := jsonStr (jsonStr (o ++ "[") owner ++ ",") refName ++ "]"
    o := o ++ "]}"
  return o ++ "],\"tactics\":[]}"

/-- `index.json`, `modules/` and an empty `deps/`: the shape every stage here
opens. `bytes` is the module file's own size, which `impact` quotes as the cost
of a selection before it has opened anything. -/
def writeIrTree (dir : FilePath) (schemaVersion : Nat) (modules : Array SynthIrModule)
    (repeated : Array String := #[]) : IO Unit := do
  removeDir dir
  IO.FS.createDirAll (dir / "modules")
  IO.FS.createDirAll (dir / "deps")
  let mut entries : Array String := #[]
  for m in modules do
    let text := synthIrModuleJson m
    let file := s!"modules/{m.name}.json"
    writeUnder dir file text
    let entry := jsonStr (jsonStr "{\"module\":" m.name ++ ",\"file\":") file
      ++ s!",\"bytes\":{text.utf8ByteSize}," ++ jsonStr "\"contentHash\":" m.contentHash ++ "}"
    entries := entries.push entry
    if repeated.contains m.name then entries := entries.push entry
  IO.FS.writeFile (dir / "index.json")
    (s!"\{\"schemaVersion\":{schemaVersion},\"generator\":\"litedoc4-test\""
      ++ ",\"leanVersion\":\"4.31.0\",\"ablations\":[],\"modules\":["
      ++ ",".intercalate entries.toList ++ "],\"dependencyMaps\":[]}")

end Litedoc4Test
