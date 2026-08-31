/- `crates/litedoc4-ir/tests/reading_a_broken_tree.rs::open_unvalidated_reads_exactly_what_open_refuses`. -/
import Litedoc4.Ir
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4 System

def indexJson (schema : Nat) (ablations : List String) : String :=
  "{\"schemaVersion\":" ++ toString schema
    ++ ",\"generator\":\"litedoc4-test\",\"leanVersion\":\"4.31.0\",\"ablations\":["
    ++ ",".intercalate (ablations.map fun a => "\"" ++ a ++ "\"")
    ++ "],\"modules\":[],\"dependencyMaps\":[]}"

def refuses {α : Type} (act : IO α) : IO Bool := do
  try
    let _ ← act
    return false
  catch _ => return true

/-- Both refusals have to be exactly the difference between the two doors —
otherwise one of them is decoration, and the stages that ask a question *about* a
tree rather than rendering it (`ownership`, `merge`) have no way in.

An `Invariant` and not a `#guard`: a door takes a directory, and there is no tree
to open without writing one. The work area is removed on the way out, on both
arms — nothing else sweeps it. -/
def openUnvalidatedReadsExactlyWhatOpenRefuses : Invariant where
  name := "openIrTree refuses an old or an ablated index and openIrTreeUnvalidated reads it"
  check := do
    let base : FilePath := ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩
    let dir := base / "litedoc4-lean-test-irtree"
    let mut why : Option String := none
    for (what, index) in [("an old", indexJson (minSchemaVersion - 1) []),
                          ("an ablated", indexJson minSchemaVersion ["no-refs"])] do
      if ← dir.pathExists then IO.FS.removeDirAll dir
      IO.FS.createDirAll dir
      IO.FS.writeFile (dir / "index.json") index
      if !(← refuses (openIrTree dir)) then
        if why.isNone then why := some s!"openIrTree accepted {what} index"
      else
        let tree ← openIrTreeUnvalidated dir
        if tree.root.toString != dir.toString || tree.index.modules.size != 0 then
          if why.isNone then
            why := some s!"openIrTreeUnvalidated read {what} index as \
              {tree.root} with {tree.index.modules.size} modules"
    if ← dir.pathExists then IO.FS.removeDirAll dir
    return why

end Litedoc4Test
