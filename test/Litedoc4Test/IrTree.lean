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

def indexEntryKeys : Array (String × String) :=
  #[("module", "\"M\""), ("file", "\"modules/M.json\""),
    ("bytes", "1"), ("contentHash", "\"1111111111111111\"")]

def entryIndexJson (keys : Array (String × String)) : String :=
  "{\"schemaVersion\":" ++ toString minSchemaVersion
    ++ ",\"generator\":\"litedoc4-test\",\"leanVersion\":\"4.31.0\",\"ablations\":[],\"modules\":[{"
    ++ ",".intercalate (keys.toList.map fun (k, v) => "\"" ++ k ++ "\":" ++ v)
    ++ "}],\"dependencyMaps\":[]}"

/-- Stated over **both** doors and over all four keys. `openIrTreeUnvalidated` is
there for a tree too old to render, and an entry missing a key is not that case —
the extractor writes all four whatever the schema — so letting that door through
would leave `ownership` reading an entry whose `contentHash` is a default that
compares equal to every other default.

An `Invariant` and not a `#guard` for the same reason as the one above: a door
takes a directory. It opens with the whole entry, because an invariant made only
of refusals holds on a reader that refuses everything. -/
def bothIrDoorsRefuseAnIndexEntryMissingAKey : Invariant where
  name := "an index entry with no module, file, bytes or contentHash is refused by both IR doors"
  check := do
    let base : FilePath := ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩
    let dir := base / "litedoc4-lean-test-ir-entry"
    let write (keys : Array (String × String)) : IO Unit := do
      if ← dir.pathExists then IO.FS.removeDirAll dir
      IO.FS.createDirAll dir
      IO.FS.writeFile (dir / "index.json") (entryIndexJson keys)
    let mut why : Option String := none
    write indexEntryKeys
    if (← refuses (openIrTree dir)) || (← refuses (openIrTreeUnvalidated dir)) then
      why := some "a whole index entry was refused, so the refusals below say nothing"
    for (dropped, _) in indexEntryKeys do
      write (indexEntryKeys.filter (·.1 != dropped))
      let validated ← refuses (openIrTree dir)
      let unvalidated ← refuses (openIrTreeUnvalidated dir)
      if !(validated && unvalidated) && why.isNone then
        let read := if validated then "openIrTreeUnvalidated"
          else if unvalidated then "openIrTree" else "both doors"
        why := some s!"an index entry with no `{dropped}` was read by {read}"
    if ← dir.pathExists then IO.FS.removeDirAll dir
    return why

end Litedoc4Test
