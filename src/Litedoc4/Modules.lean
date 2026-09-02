/- Every module of every named library, in UTF-16 order.

**One list, and it is handed to every stage that takes one** — the ledger, the
extractor, and the map's omit list — because its order is the ledger's `modules`
array order and the merged `index.json`'s. Two derivations of "the same" list is
exactly how that stops being true. -/
import Litedoc4.Fs
import Litedoc4.Ir.Name
import Litedoc4.Ir.Utf16
import Litedoc4.Lakefile

open System

namespace Litedoc4

/-- Every `*.lean` under `dir`, as a path relative to the repository root.

Symlinks are not followed — `symlinkMetadata`, so a link is neither a directory
nor a file here — because a symlinked directory inside a library would let one
module be listed twice under two names, and the second one has no olean. -/
partial def collectLean (dir : FilePath) (pathPrefix : String) (out : Array String) :
    IO (Array String) := do
  let mut out := out
  for entry in ← dir.readDir do
    let kind := (← entry.path.symlinkMetadata).type
    let relative := pathPrefix ++ "/" ++ entry.fileName
    if kind == .dir then
      out ← collectLean entry.path relative out
    else if kind == .file && entry.fileName.endsWith ".lean" then
      out := out.push relative
  return out

def moduleNames (root : FilePath) (libs : Array String) :
    IO (Except String (Array String)) := do
  let mut paths : Array String := #[]
  for lib in libs do
    let file := root / (lib ++ ".lean")
    let dir := root / lib
    let hasFile ← isRegularFile file
    let hasDir ← dir.isDir
    if !hasFile && !hasDir then
      return .error s!"no {lib}.lean and no {lib}/ under {root}: --lib names a library root, and \
        an empty module list would look like a package whose every module was deleted"
    if hasFile then paths := paths.push (lib ++ ".lean")
    if hasDir then paths ← collectLean dir lib paths
  -- **The path's components become a Lean *name*, and that is an escaping**
  -- (measured). `Alpha/Odd-Name.lean` is the module Lean spells
  -- `Alpha.«Odd-Name»`; written as `Alpha.Odd-Name` it does not parse — the
  -- extractor's `String.toName` yields `Name.anonymous` and the run dies with
  -- `import failed, trying to import module with anonymous name` before it has
  -- imported anything.
  let names := paths.map fun path =>
    let stem := if path.endsWith ".lean" then (path.dropEnd 5).toString else path
    escapeModule (stem.splitOn "/").toArray
  -- Deduplicated after the sort: two `--lib` arguments that overlap name the
  -- same module twice, and a ledger with a repeated module is one whose `check`
  -- compares it against itself.
  return .ok (dedupSorted (sortUtf16 names))

end Litedoc4
