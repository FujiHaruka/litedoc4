/- `crates/litedoc4-incr/src/prune.rs`: deleting the pages of modules that are
gone.

The renderer only ever writes: `render --only` writes the pages it was asked for
and never looks at what else is in the tree. So without this a deleted module's
page survives every later incremental run and looks exactly like a live one — a
failure nothing downstream can notice.

This is the one stage that deletes, so the guards are structural:

1. **Every path is built by the renderer's own rule and checked against the
   root.** A name really does carry a `..` past that rule — `«..».Foo` comes out
   of `pageUrl` as `../Foo.html` — so `PageRoot` is a check and not an argument:
   lexically before the path is used, physically (`realPath`) before anything is
   unlinked. A path that resolves outside the page root is a refusal, not a
   deletion.
2. **Paths are concatenated, never joined with `FilePath./`**, which with an
   absolute right-hand side *discards the left*: a `--remove` line of
   `/etc/passwd` would name `/etc/passwd.html` instead of
   `<pages>//etc/passwd.html`, which is a deletion outside the tree.
3. **The walk never descends a symlink.** `symlinkMetadata` does not follow, so a
   symlinked subdirectory is neither a directory to recurse into nor a file to
   keep.

`--ir` deletes every `.html` under the root whose relative path is not `pageUrl`
of a module in the IR, and on a real **site** that is not only the dead pages:
four of the whole-package artifacts are `.html` files no module owns —
`index.html`, `404.html`, `search.html`, `foundational_types.html` — so the rule
calls them orphans and takes the site's front door with them (measured
2026-08-12). The caller passes only `--remove` for that reason; turning the
orphan rule on over a whole site is a plausible-looking change that is not one. -/
import Std.Data.HashSet
import Litedoc4.Duration
import Litedoc4.Fs
import Litedoc4.Ir
import Litedoc4.Ir.Name
import Litedoc4.JsonWrite

open System

namespace Litedoc4

/-- 1 is a file that would not read, 3 is the world and the files disagreeing. -/
abbrev PruneRefusal := UInt32 × String

abbrev PruneM := ExceptT PruneRefusal IO

/-- The tree `prune` is allowed to delete inside.

Holds the string the caller gave, and resolves the canonical form **at the moment
of a deletion** rather than up front: `--dry-run --remove` over a page tree that
is not there has to report every module as already absent and exit 0, which
resolving in a constructor would turn into a failure. -/
structure PageRoot where
  /-- Trailing slashes and all, as given. -/
  given : String

def outsidePageRoot (root path : String) : PruneRefusal :=
  (3, s!"refusing to delete {path} — it is not under the page root {root}")

/-- `` `${root}/${relative}` ``, refused if `relative` could leave the tree.

Lexical, and it runs before the path is used for anything — a missing file must
still be a *refusal* when the name was suspect, not an "already absent".
**Concatenation, not `FilePath./`**, which would discard the root for an absolute
`relative`. -/
def PageRoot.under (r : PageRoot) (relative : String) : Except PruneRefusal FilePath :=
  if (relative.splitOn "/").any (fun part => part == ".." || part.contains '\x00') then
    .error (outsidePageRoot r.given relative)
  else .ok ⟨r.given ++ "/" ++ relative⟩

def PageRoot.resolve (r : PageRoot) (relative : String) : PruneM FilePath :=
  match r.under relative with
  | .error refusal => throw refusal
  | .ok path => pure path

private def PageRoot.contains (r : PageRoot) (path resolve : FilePath) (strictly : Bool) :
    PruneM Unit := do
  let root ← (IO.FS.realPath ⟨r.given⟩ : IO FilePath)
  let resolved ← (IO.FS.realPath resolve : IO FilePath)
  if !isInside root resolved || (strictly && resolved.toString == root.toString) then
    throw (outsidePageRoot root.toString path.toString)

/-- The last check before an unlink: the file's directory really is inside the
root once every symlink on the way has been followed. -/
def PageRoot.allowDelete (r : PageRoot) (path : FilePath) : PruneM Unit :=
  r.contains path (path.parent.getD ⟨"."⟩) false

/-- The same check for a directory this stage is about to remove, plus the root
itself: the caller stops one level above it, and this says so a second time. -/
def PageRoot.allowRemoveDir (r : PageRoot) (path : FilePath) : PruneM Unit :=
  r.contains path path true

structure PruneInputs where
  /-- The page tree. Nothing outside it is ever touched. -/
  pages : FilePath
  /-- Modules whose pages are to be deleted, one name per line. -/
  remove : Option FilePath := none
  /-- An IR tree. With it, every `.html` with no module in that IR is deleted
  too — read the orphan rule above before turning this on over a site. -/
  ir : Option FilePath := none
  /-- Report and delete nothing. The empty-directory pass does not run either:
  there is nothing for it to have emptied. -/
  dryRun : Bool := false
  json : Option FilePath := none

structure PruneSummary where
  /-- `--pages` as it was given. -/
  pages : String
  dryRun : Bool
  requested : Nat
  /-- Modules whose page was there. Under `--dry-run` these are the ones that
  *would* be deleted. -/
  deleted : Array String
  /-- Asked for, no page there — already gone. Not an error: a module can be
  deleted before it was ever rendered. -/
  alreadyAbsent : Array String
  /-- Pages with no module in the IR, relative to the page root, in walk order. -/
  orphans : Array String
  /-- Directories the deletions left empty, relative to the page root, deepest
  first. Empty under `--dry-run`. -/
  emptied : Array String
  totalNanos : Nat
  deriving Inhabited

def orphansInSummary : Nat := 20

def orphansInLog : Nat := 10

/-- One directory's entries, in the order the filesystem lists them.

**Not sorted**: the order reaches the summary's `orphanPages` field, so sorting
here would change the bytes under comparison rather than the answer. -/
private def dirEntries (root : PageRoot) (relative : String) :
    PruneM (Array (String × IO.FS.FileType)) := do
  let dir ← if relative.isEmpty then pure (⟨root.given⟩ : FilePath) else root.resolve relative
  let listing ← (dir.readDir : IO (Array IO.FS.DirEntry))
  let mut out : Array (String × IO.FS.FileType) := Array.mkEmpty listing.size
  for found in listing do
    let kind := (← (found.path.symlinkMetadata : IO IO.FS.Metadata)).type
    out := out.push (found.fileName, kind)
  return out

private def joinRelative (relative name : String) : String :=
  if relative.isEmpty then name else relative ++ "/" ++ name

/-- Depth first, in directory order.

`relative` is the path of the directory under the root, `""` at the top. Built up
rather than cut off the front of the absolute path, so a `--pages` with a
trailing slash does not shift the cut by one.

Only the renderer's own lower-case `.html` is a page; a `.HTML` is left alone. -/
private partial def walkOrphans (root : PageRoot) (dryRun : Bool)
    (live : Std.HashSet String) (relative : String) (orphans : Array String) :
    PruneM (Array String) := do
  let mut acc := orphans
  for (name, kind) in ← dirEntries root relative do
    let child := joinRelative relative name
    if kind == .dir then
      acc ← walkOrphans root dryRun live child acc
    else if name.endsWith ".html" && !live.contains child then
      -- Whether the entry is a *file* is not asked: anything that is not a
      -- directory and ends in `.html` is a candidate, symlinks included, and
      -- unlinking one removes the link.
      acc := acc.push child
      if !dryRun then
        let path ← root.resolve child
        root.allowDelete path
        (IO.FS.removeFile path : IO Unit)
  return acc

/-- Deepest first, and never the root. Returns whether `relative` was itself
removed, which is how the caller knows whether it still counts as content. -/
private partial def pruneEmpty (root : PageRoot) (relative : String) (emptied : Array String) :
    PruneM (Bool × Array String) := do
  let mut any := false
  let mut acc := emptied
  for (name, kind) in ← dirEntries root relative do
    if kind == .dir then
      let (removed, next) ← pruneEmpty root (joinRelative relative name) acc
      acc := next
      if !removed then any := true
    else
      any := true
  if !any && !relative.isEmpty then
    let path ← root.resolve relative
    root.allowRemoveDir path
    (IO.FS.removeDir path : IO Unit)
    return (true, acc.push relative)
  return (false, acc)

/-- The IR's module names, read as plain JSON rather than through `IrTree`: one
column of `index.json` is all this needs, and the tree may have just been
rewritten by the merge. -/
private def readIndexModules (ir : FilePath) : PruneM (Array String) := do
  let path := irPath ir "index.json"
  -- Counted like every other IR read. It never fires on the caller's usual path,
  -- which passes no `--ir`, so a run whose counter moves here is a run that
  -- turned the orphan rule on.
  recordIrRead .index
  let index ← match parseJson (← (readIrFile path : IO String)) with
    | .error why => throw (1, s!"{path}: {why}")
    | .ok j => pure j
  let some (.arr modules) := jvalGet? index "modules"
    | throw (3, s!"{path}: modules is not an array")
  let mut out : Array String := Array.mkEmpty modules.size
  for entry in modules do
    -- An entry with no `module` string is refused rather than skipped, as
    -- `merge` refuses the same shape.
    let some (.str module) := jvalGet? entry "module"
      | throw (3, s!"{path}: {indexEntryRefusal "string" "module"}")
    out := out.push module
  return out

private def pruneRun (i : PruneInputs) : PruneM PruneSummary := do
  let started ← (IO.monoNanosNow : IO Nat)
  let root : PageRoot := { given := i.pages.toString }
  let requested ← match i.remove with
    | some path => (readModuleList path : IO (Array String))
    | none => pure #[]

  let mut deleted : Array String := #[]
  let mut alreadyAbsent : Array String := #[]
  for module in requested do
    let path ← root.resolve (pageUrl module)
    -- `metadata` follows symlinks, so a dangling link counts as absent and the
    -- link itself survives.
    match ← (path.metadata.toBaseIO : IO _) with
    | .error _ => alreadyAbsent := alreadyAbsent.push module
    | .ok _ =>
      if !i.dryRun then
        root.allowDelete path
        (IO.FS.removeFile path : IO Unit)
      deleted := deleted.push module

  let mut orphans : Array String := #[]
  if let some ir := i.ir then
    let mut live : Std.HashSet String := Std.HashSet.emptyWithCapacity 512
    for module in ← readIndexModules ir do live := live.insert (pageUrl module)
    orphans ← walkOrphans root i.dryRun live "" #[]

  -- Directories the deletions left empty. Harmless if left, but then the page
  -- tree is not equal to a from-scratch one — and byte equality with a
  -- from-scratch build is the only oracle this project trusts.
  let mut emptied : Array String := #[]
  if !i.dryRun then
    let (_, found) ← pruneEmpty root "" #[]
    emptied := found
  let total ← (IO.monoNanosNow : IO Nat)
  return { pages := root.given, dryRun := i.dryRun, requested := requested.size
           deleted, alreadyAbsent, orphans, emptied, totalNanos := total - started }

/-- `serde_json::to_string_pretty`: two spaces per level, and the field order is
the record's. `totalSeconds` is a diagnostic — wall clock, different every run,
and no comparison may assert on it. -/
def pruneJson (s : PruneSummary) : String := Id.run do
  let names (out : String) (items : Array String) : String := Id.run do
    if items.isEmpty then return out ++ "[]"
    let mut o := out ++ "[\n"
    for k in [0 : items.size] do
      o := jsonStr (o ++ "    ") items[k]!
      o := o ++ (if k + 1 == items.size then "\n" else ",\n")
    return o ++ "  ]"
  let mut o := jsonStr "{\n  \"pages\": " s.pages
  o := o ++ s!",\n  \"dryRun\": {s.dryRun}"
  o := o ++ s!",\n  \"requested\": {s.requested}"
  o := o ++ s!",\n  \"deleted\": {s.deleted.size}"
  o := names (o ++ ",\n  \"deletedModules\": ") s.deleted
  o := o ++ s!",\n  \"alreadyAbsent\": {s.alreadyAbsent.size}"
  o := o ++ s!",\n  \"orphans\": {s.orphans.size}"
  o := names (o ++ ",\n  \"orphanPages\": ") (s.orphans.extract 0 orphansInSummary)
  o := o ++ s!",\n  \"emptiedDirectories\": {s.emptied.size}"
  o := o ++ s!",\n  \"totalSeconds\": {seconds s.totalNanos 9}"
  return o ++ "\n}\n"

/-- Deletes the pages of removed modules, the orphans and the emptied
directories. -/
def prune (i : PruneInputs) : IO (Except PruneRefusal PruneSummary) := do
  match ← (pruneRun i).run with
  | .error refusal => return .error refusal
  | .ok summary =>
    if let some path := i.json then writeFile path (pruneJson summary)
    return .ok summary

end Litedoc4
