/- `crates/litedoc4-incr/src/merge.rs`: folding a partial extraction back into
the package IR.

The extractor writes a *complete* IR tree for whatever module list it was given,
so a one-module run produces a one-module tree. Two things therefore have to be
repaired before that tree is usable as an update:

1. `index.json` must keep the other modules' entries. The entry for the
   re-extracted module is taken verbatim from the partial run — including its
   `contentHash`, which only Lean can compute.

2. `deps/*.json` is **package-global and cannot be produced by a partial run at
   all.** The extractor decides "dependency" as "defining module not in the
   target list", so with a one-module target list the package's own other modules
   are misfiled as dependencies. The fix is not to merge that file but to
   recompute the slice from the merged module files.

**Nothing this module writes is ordered its own way** — every order in a merged
tree is the one Lean's from-scratch writer would have produced, so that "every
file an incremental build produces is byte for byte the one a from-scratch
extraction would have written" is an invariant rather than a hope. That means
each `deps/<Root>.json` sorted, each `dependencyMaps` entry's keys alphabetical,
and the `dependencyMaps` array in **code point order** (`byteLt`) — Lean compares
`String`s by their characters, which agrees with UTF-16 order throughout the BMP
and parts company at U+10000. The top-level key order is the base index's.

`index.json`'s **`modules` array** follows `--modules` when it is given, because
a from-scratch extraction's order is the order the extractor was handed its
module list in. That order reaches one more thing than the index: the dependency
slice is recomputed by walking the package's modules and letting the **last**
writer own a name. -/
import Std.Data.HashMap
import Std.Data.HashSet
import Litedoc4.Duration
import Litedoc4.Fs
import Litedoc4.Incr.Ordered
import Litedoc4.Ir
import Litedoc4.Ir.Name
import Litedoc4.Ledger

open System

namespace Litedoc4

/-- What a refusal from this stage carries, under `LedgerRefusal`'s rule: 1 is a
file that would not read or parse, 3 is the world and the files disagreeing. -/
abbrev MergeRefusal := UInt32 × String

/-- An `index.json` that parses as JSON but is not an index. No shape of index
this can come out of a real extraction, so it is a refusal rather than a guess at
what was meant. -/
def indexShape (path message : String) : MergeRefusal := (3, s!"{path}: {message}")

/-- The **raw object is what goes back out**, key order and unknown keys
included: the merged index carries the extractor's entries verbatim, so a typed
entry here would quietly rewrite them into this build's field order. -/
structure MergeIndexEntry where
  module : String
  file : String
  raw : JVal
  deriving Inhabited

/-- Two lookups compare equal exactly when Rust's two `Option<&Value>` do.
`JVal` carries no `BEq` — deriving one over `Array JVal` is a knot — and the
written bytes decide the question anyway, as long as an absent key stays
distinguishable from a `null` one. -/
def jvalKey : Option JVal → String
  | none => ""
  | some v => "=" ++ jvalJson v

/-- A repeated key collapsed under `orderedInsert`'s rule — first position, last
value — **at every depth**, which is what a parser backed by an insertion-ordered
map leaves behind.

Applied on the way in rather than left to the lookups: the merged `index.json` is
the base file's own values written back out, so a document that repeats a key has
to come back as the one entry it was read as. Doing it only where a value is read
would make the file grow a second copy of the key nobody wrote twice. -/
partial def jvalCollapse : JVal → JVal
  | .obj entries => Id.run do
    let mut o : Array (String × JVal) := Array.mkEmpty entries.size
    for (k, v) in entries do o := orderedInsert o k (jvalCollapse v)
    return .obj o
  | .arr items => .arr (items.map jvalCollapse)
  | v => v

/-- This stage's own reader, for the IR files it takes as **untyped JSON**: the
merged `index.json` is written back with keys this build does not model, which
`IrTree` would drop. Being the one IR read that does not go through the loader,
it records the work itself, or the metrics would report a merge as costing
nothing. -/
def readJsonObject (path : FilePath) (kind : IrFile) : IO (Array (String × JVal)) := do
  recordIrRead kind
  let text ← readIrFile path
  match parseJson text with
  | .error why => throw (IO.userError s!"{path}: {why}")
  | .ok (.obj entries) => return asObj (jvalCollapse (.obj entries))
  | .ok _ => throw (IO.userError s!"{path}: expected a JSON object")

/-- `index.modules`, refused rather than guessed at when it is not an array of
objects each carrying `module` and `file` as strings: no extraction produces that
shape, so there is nothing to recover. -/
def indexEntries (path : String) (index : Array (String × JVal)) :
    Except MergeRefusal (Array MergeIndexEntry) := do
  let some (.arr modules) := orderedGet? index "modules"
    | .error (indexShape path "modules is not an array")
  let mut out : Array MergeIndexEntry := Array.mkEmpty modules.size
  for entry in modules do
    let some (.str module) := jvalGet? entry "module"
      | .error (indexShape path (indexEntryRefusal "string" "module"))
    let some (.str file) := jvalGet? entry "file"
      | .error (indexShape path (indexEntryRefusal "string" "file"))
    out := out.push { module, file, raw := entry }
  return out

/-- A caller needs a name to start from, not a list that scrolls a screenful of
terminal away. -/
def namesInRefusal : Nat := 10

def someOf (names : Array String) : String :=
  if names.isEmpty then "none" else
  let shown := ", ".intercalate (names.extract 0 namesInRefusal).toList
  if names.size > namesInRefusal then s!"{shown}, … and {names.size - namesInRefusal} more"
  else shown

/-- The merged index's module order, taken from the package's own list.

`kept` is the base index's modules with the deletions already dropped, `inc` the
partial extraction's entries; together they are the set the merge is about to
write, before a single byte of it exists.

A repeated name is deduplicated, keeping its first position: a list that names a
module twice is one list, not two modules. A list that does not describe the tree
is refused — both ways of carrying on are silent, and neither moves a page
byte. -/
def listedOrder (list kept : Array String) (inc : Array MergeIndexEntry) :
    Except MergeRefusal (Array String) := Id.run do
  let mut inTree : Std.HashSet String := Std.HashSet.emptyWithCapacity (kept.size * 2 + 8)
  let mut merged : Array String := kept
  for module in kept do inTree := inTree.insert module
  for e in inc do
    if !inTree.contains e.module then
      inTree := inTree.insert e.module
      merged := merged.push e.module
  let mut inList : Std.HashSet String := Std.HashSet.emptyWithCapacity (list.size * 2 + 8)
  let mut wanted : Array String := Array.mkEmpty list.size
  for module in list do
    if !inList.contains module then
      inList := inList.insert module
      wanted := wanted.push module
  let missing := wanted.filter (!inTree.contains ·)
  let extra := merged.filter (!inList.contains ·)
  if missing.isEmpty && extra.isEmpty then return .ok wanted
  return .error (3, s!"--modules and the merged IR name different modules: {missing.size} in the \
    list with nothing behind them ({someOf missing}), {extra.size} in the merged tree the list \
    does not name ({someOf extra}). index.json's module order is this list's, so the odd ones out \
    would have to be guessed at — and a wrong guess moves index.json alone, where no page byte \
    follows it")

/-- Field order **is** the file's key order, and it is Lean's alphabetical one. -/
structure DepMapRecord where
  bytes : Nat
  entries : Nat
  file : String
  package : String
  deriving Inhabited

def DepMapRecord.toJVal (r : DepMapRecord) : JVal :=
  .obj #[("bytes", .num (Int.ofNat r.bytes)), ("entries", .num (Int.ofNat r.entries)),
         ("file", .str r.file), ("package", .str r.package)]

structure MergeInputs where
  /-- The IR to update. **Never modified in place unless `out` says so.** -/
  base : FilePath
  inc : Option FilePath := none
  /-- Where the merged tree goes. Passing `base` merges in place. -/
  out : FilePath
  /-- Modules that no longer exist. They leave the index and their module files
  are deleted. -/
  removed : Array String := #[]
  /-- The package's module list, in the order a from-scratch extraction would be
  handed it. -/
  modules : Option (Array String) := none
  /-- The modules whose IR `contentHash` moved, one per line — the render set's
  input, and **not** the same as the re-extracted set. -/
  changedOut : Option FilePath := none
  timings : Option FilePath := none

structure MergeSummary where
  /-- Every module the partial extraction carried, in its index order. -/
  updated : Array String
  /-- How many of `removed` were actually in the base index. -/
  removed : Nat
  /-- The modules whose `contentHash` moved. A re-extracted module whose hash did
  not move produces the same page, so it does not enter the render set: this is
  the second ledger, and the one that decides what to re-render. -/
  irChanged : Array String
  modules : Nat
  declarations : Nat
  depMaps : Array DepMapRecord
  copyNanos : Nat
  depsNanos : Nat
  totalNanos : Nat
  deriving Inhabited

/-- First component of a module name, split on the plain dot: the root a
dependency slice is filed under is the one the extractor's own file names use. -/
def moduleRoot (module : String) : String := (components module)[0]!

/-- The lower of two `schemaVersion` values. Keeps the base's whenever the two
cannot be compared as numbers, including the case where the base has none: a tree
without the key is a schema-1 file, and answering with the incremental tree's
number would invent a claim the base never made. -/
def weakestSchema : Option JVal → Option JVal → Option JVal
  | some b, some x => match b, x with
    | .num nb, .num nx => if nx ≥ 0 && nb ≥ 0 && nx < nb then some x else some b
    | _, _ => some b
  | b, _ => b

def copyFile (source destination : FilePath) : IO Unit := do
  IO.FS.writeBinFile destination (← IO.FS.readBinFile source)

/-- Whether `base` and `out` name one tree, however each is spelled.

**Not a string comparison.** `x/../x` and `x` are two spellings of one directory,
and reading that as "out is a separate tree" is not a wasted write but a
destructive one: a copy that opens the destination before it reads the source
empties the file. The files emptied would be the modules the partial extraction
did not touch — and when `--out` names the base, that tree is the only copy there
was. A side that does not resolve is not the other one: `out` exists by the time
this is asked, so the only unresolvable side is a `base` that is not there, and
the read that follows says so with a better message than a bool could. -/
def sameTree (base out : FilePath) : IO Bool := do
  let a ← (IO.FS.realPath base).toBaseIO
  let b ← (IO.FS.realPath out).toBaseIO
  match a, b with
  | .ok a, .ok b => return a.toString == b.toString
  | _, _ => return false

/-- Folds `inc` into `base` and writes the result to `out`. -/
def merge (i : MergeInputs) : IO (Except MergeRefusal MergeSummary) := do
  let started ← IO.monoNanosNow
  let baseIndexPath := irPath i.base "index.json"
  let baseIndex ← readJsonObject baseIndexPath .index
  let mut incSchema : Option JVal := none
  let mut incModules : Array MergeIndexEntry := #[]
  if let some dir := i.inc then
    let path := irPath dir "index.json"
    let index ← readJsonObject path .index
    incSchema := orderedGet? index "schemaVersion"
    match indexEntries path.toString index with
    | .error refusal => return .error refusal
    | .ok entries => incModules := entries
  let mut baseModules : Array MergeIndexEntry := #[]
  match indexEntries baseIndexPath.toString baseIndex with
  | .error refusal => return .error refusal
  | .ok entries => baseModules := entries

  let mut entries : Std.HashMap String MergeIndexEntry :=
    Std.HashMap.emptyWithCapacity (baseModules.size * 2)
  let mut order : Array String := Array.mkEmpty baseModules.size
  for e in baseModules do
    order := order.push e.module
    entries := entries.insert e.module e

  -- A module that no longer exists has to leave the index, or it keeps a page
  -- and keeps feeding names to the dependency slice and the global maps.
  let mut gone : Array String := #[]
  let mut droppedFiles : Array String := #[]
  let mut goneSet : Std.HashSet String := Std.HashSet.emptyWithCapacity 8
  for module in i.removed do
    if let some e := entries.get? module then
      if !goneSet.contains module then
        goneSet := goneSet.insert module
        droppedFiles := droppedFiles.push e.file
        gone := gone.push module
  for module in gone do entries := entries.erase module
  order := order.filter (!goneSet.contains ·)

  -- Decided **before anything is written**: the set the merge is about to
  -- produce is already known, so a list that does not describe it is refused
  -- with the tree untouched rather than half updated.
  let mut listed : Option (Array String) := none
  if let some list := i.modules then
    match listedOrder list order incModules with
    | .error refusal => return .error refusal
    | .ok wanted => listed := some wanted

  IO.FS.createDirAll (i.out / "modules")
  IO.FS.createDirAll (i.out / "deps")

  let mut inInc : Std.HashSet String := Std.HashSet.emptyWithCapacity (incModules.size * 2 + 8)
  for e in incModules do inInc := inInc.insert e.module
  if !(← sameTree i.base i.out) then
    -- The cost of not updating in place; a caller that keeps one directory
    -- rewrites only the changed files.
    for e in baseModules do
      if goneSet.contains e.module || inInc.contains e.module then continue
      copyFile (irPath i.base e.file) (irPath i.out e.file)
  else
    for file in droppedFiles do
      -- A file that is already gone is the state this line wants.
      let _ ← (IO.FS.removeFile (irPath i.out file)).toBaseIO

  let mut updated : Array String := Array.mkEmpty incModules.size
  let mut irChanged : Array String := #[]
  if let some dir := i.inc then
    for e in incModules do
      copyFile (irPath dir e.file) (irPath i.out e.file)
      let before := entries.get? e.module
      if before.isNone then order := order.push e.module
      let moved := match before with
        | none => true
        | some was => jvalKey (jvalGet? was.raw "contentHash")
                        != jvalKey (jvalGet? e.raw "contentHash")
      if moved then irChanged := irChanged.push e.module
      entries := entries.insert e.module e
      updated := updated.push e.module
  -- Before the dependency slice is recomputed, not after: the slice is walked in
  -- this order and its last writer wins, so an order applied only to the index
  -- would leave the two disagreeing about the same package.
  if let some wanted := listed then order := wanted
  let modulesDone ← IO.monoNanosNow

  let mut own : Std.HashSet String := Std.HashSet.emptyWithCapacity (order.size * 2 + 8)
  for module in order do own := own.insert module
  let mut dep : Std.HashMap String String := Std.HashMap.emptyWithCapacity 2048
  let mut declarations := 0
  for module in order do
    let e := entries.get! module
    let parsed ← readModuleFile (irPath i.out e.file)
    declarations := declarations + parsed.decls.size
    for d in parsed.decls do
      for (owner, name) in d.refs do
        -- Last writer wins, as `Map.prototype.set` does.
        if !own.contains owner then dep := dep.insert name owner

  let sorted := dep.toArray.qsort (fun a b => byteLt a.1 b.1)
  let mut roots : Array String := #[]
  let mut byRoot : Std.HashMap String (Array (String × String)) :=
    Std.HashMap.emptyWithCapacity 16
  for (name, module) in sorted do
    let root := moduleRoot module
    if !byRoot.contains root then roots := roots.push root
    byRoot := byRoot.insert root ((byRoot.getD root #[]).push (name, module))
  -- The roots become `index.json`'s `dependencyMaps` order, so they are sorted
  -- the way Lean's writer sorts them: code point order, not UTF-16.
  let rootList := roots.qsort byteLt

  -- **The weakest claim any file under the merged tree makes**, which is not
  -- always the base's: the incremental module files are copied in verbatim, so a
  -- tree can hold two extractor runs' output at once, and an older binary
  -- merging into a newer tree leaves modules below the index's number.
  let schema := weakestSchema (orderedGet? baseIndex "schemaVersion") incSchema
  let mut depMaps : Array DepMapRecord := Array.mkEmpty rootList.size
  let mut kept : Std.HashSet String := Std.HashSet.emptyWithCapacity 16
  for root in rootList do
    let slice := byRoot.getD root #[]
    let mut body := "{\"declarations\":{"
    let mut first := true
    for (name, module) in slice do
      if !first then body := body.push ','
      first := false
      body := jsonStr (jsonStr body name ++ ":") module
    body := jsonStr (body ++ "},\"package\":") root
    -- Never *adds* the key: a tree without one is a schema-1 file.
    if let some version := schema then
      body := body ++ ",\"schemaVersion\":" ++ jvalJson version
    body := body ++ "}"
    let file := "deps/" ++ root ++ ".json"
    writeFile (irPath i.out file) body
    kept := kept.insert file
    depMaps := depMaps.push
      { bytes := body.utf8ByteSize, entries := slice.size, file, package := root }

  -- Drop dependency files that no longer belong (a package that stopped being
  -- referenced, or the own-package slice a partial run wrongly produced).
  let mut stale : Array String := #[]
  for found in ← (i.out / "deps").readDir do
    let relative := "deps/" ++ found.fileName
    if !kept.contains relative then stale := stale.push relative
  -- Sorted so that a failure names the same file whatever the directory
  -- listing's order was; the removal itself does not care.
  for relative in stale.qsort byteLt do IO.FS.removeFile (irPath i.out relative)

  let mut index := baseIndex
  if let some version := schema then index := orderedInsert index "schemaVersion" version
  index := orderedInsert index "moduleCount" (.num (Int.ofNat order.size))
  index := orderedInsert index "declarationCount" (.num (Int.ofNat declarations))
  index := orderedInsert index "modules" (.arr (order.map (fun m => (entries.get! m).raw)))
  index := orderedInsert index "dependencyMaps" (.arr (depMaps.map DepMapRecord.toJVal))
  writeFile (irPath i.out "index.json") (jvalJson (.obj index))
  let total ← IO.monoNanosNow

  if let some path := i.changedOut then writeLines path irChanged
  if let some path := i.timings then
    writeFile path
      (s!"\{\"command\":\"merge\",\"updated\":{updated.size},\"removed\":{gone.size}" ++
       s!",\"irChanged\":{irChanged.size},\"modules\":{order.size}" ++
       s!",\"copySeconds\":{seconds (modulesDone - started) 9}" ++
       s!",\"depsSeconds\":{seconds (total - modulesDone) 9}" ++
       s!",\"totalSeconds\":{seconds (total - started) 9}" ++ "}\n")
  return .ok { updated, removed := gone.size, irChanged, modules := order.size, declarations
               depMaps, copyNanos := modulesDone - started, depsNanos := total - modulesDone
               totalNanos := total - started }

/-- The result of `merge --verify A --against B`. -/
structure VerifyReport where
  /-- One line per finding, in the order they were found. -/
  lines : Array String
  /-- Zero is exit 0. -/
  problems : Nat
  deriving Inhabited

def VerifyReport.toText (r : VerifyReport) : String :=
  r.lines.foldl (fun out line => out ++ line ++ "\n") ""

def verifyDepFailures : Nat := 10

/-- A key that is not there prints as `undefined`. -/
def jsDisplay : Option JVal → String
  | none => "undefined"
  | some (.str text) => text
  | some other => jvalJson other

/-- A repeated module keeps its first position and takes its last value —
`orderedInsert`'s rule. -/
def moduleMap (path : String) (index : Array (String × JVal)) :
    Except MergeRefusal (Array (String × MergeIndexEntry)) := do
  let entries ← indexEntries path index
  let mut out : Array (String × MergeIndexEntry) := #[]
  for e in entries do out := orderedInsert out e.module e
  return out

/-- Every dependency slice of a tree, flattened to `name -> module` in file
order. A tree with no `dependencyMaps` key is empty rather than a failure, and a
name two slices both carry follows `orderedInsert`'s rule. -/
def depMapping (root : FilePath) (path : String) (index : Array (String × JVal)) :
    IO (Except MergeRefusal (Array (String × String))) := do
  let entries ← match orderedGet? index "dependencyMaps" with
    | none => pure #[]
    | some .null => pure #[]
    | some (.arr entries) => pure entries
    | some _ => return .error (indexShape path "dependencyMaps is not an array")
  let mut out : Array (String × String) := #[]
  for entry in entries do
    let some (.str file) := jvalGet? entry "file"
      | return .error (indexShape path "a dependencyMaps entry has no string `file`")
    let slicePath := irPath root file
    let slice ← readJsonObject slicePath .depMap
    let some (.obj declarations) := orderedGet? slice "declarations"
      | return .error (indexShape slicePath.toString "declarations is not an object")
    for (name, module) in declarations do
      out := orderedInsert out name (match module with | .str m => m | other => jvalJson other)
  return .ok out

def readBytes (path : FilePath) : IO ByteArray := do
  -- Counted as a module read even though nothing is parsed: the bytes are pulled
  -- in, which is the work the counter is about.
  recordIrRead .module
  IO.FS.readBinFile path

def sameBytes (a b : ByteArray) : Bool := Id.run do
  if a.size != b.size then return false
  let mut i := 0
  while i < a.size do
    if a[i]! != b[i]! then return false
    i := i + 1
  return true

/-- Compares two IR trees: module files byte for byte, index entries field by
field, dependency slices **as name -> module maps**.

The slices could be compared byte for byte too, but the mapping is what tells a
caller that two trees *mean* the same thing, and it is the only check that
survives a future extractor emitting them in another order. -/
def verify (a b : FilePath) : IO (Except MergeRefusal VerifyReport) := do
  let aIndexPath := irPath a "index.json"
  let bIndexPath := irPath b "index.json"
  let indexA ← readJsonObject aIndexPath .index
  let indexB ← readJsonObject bIndexPath .index
  let mut mapA : Array (String × MergeIndexEntry) := #[]
  match moduleMap aIndexPath.toString indexA with
  | .error refusal => return .error refusal
  | .ok m => mapA := m
  let mut mapB : Array (String × MergeIndexEntry) := #[]
  match moduleMap bIndexPath.toString indexB with
  | .error refusal => return .error refusal
  | .ok m => mapB := m

  let mut lines : Array String := #[]
  let mut problems := 0
  if mapA.size != mapB.size then
    lines := lines.push s!"FAIL module count {mapA.size} vs {mapB.size}"
    problems := problems + 1
  let mut same := 0
  for (name, entryA) in mapA do
    match orderedGet? mapB name with
    | none =>
      lines := lines.push s!"FAIL missing in B: {name}"
      problems := problems + 1
    | some entryB =>
      for key in #["file", "bytes", "declarations", "contentHash"] do
        if jvalKey (jvalGet? entryA.raw key) != jvalKey (jvalGet? entryB.raw key) then
          lines := lines.push s!"FAIL index.{key} {name}: \
            {jsDisplay (jvalGet? entryA.raw key)} vs {jsDisplay (jvalGet? entryB.raw key)}"
          problems := problems + 1
      let bytesA ← readBytes (irPath a entryA.file)
      let bytesB ← readBytes (irPath b entryB.file)
      if sameBytes bytesA bytesB then same := same + 1
      else
        lines := lines.push s!"FAIL bytes differ: {name}"
        problems := problems + 1
  lines := lines.push s!"module files byte-identical: {same}/{mapA.size}"

  let mut depA : Array (String × String) := #[]
  match ← depMapping a aIndexPath.toString indexA with
  | .error refusal => return .error refusal
  | .ok m => depA := m
  let mut depB : Array (String × String) := #[]
  match ← depMapping b bIndexPath.toString indexB with
  | .error refusal => return .error refusal
  | .ok m => depB := m
  let mut lookupB : Std.HashMap String String := Std.HashMap.emptyWithCapacity (depB.size * 2 + 8)
  for (name, module) in depB do lookupB := lookupB.insert name module
  let mut lookupA : Std.HashSet String := Std.HashSet.emptyWithCapacity (depA.size * 2 + 8)
  for (name, _) in depA do lookupA := lookupA.insert name
  let mut depBad := 0
  for (name, module) in depA do
    if lookupB.get? name != some module then
      if depBad < verifyDepFailures then
        let found := (lookupB.get? name).getD "undefined"
        lines := lines.push s!"FAIL dep {name}: {module} vs {found}"
      depBad := depBad + 1
  for (name, _) in depB do
    if !lookupA.contains name then
      if depBad < verifyDepFailures then lines := lines.push s!"FAIL dep only in B: {name}"
      depBad := depBad + 1
  lines := lines.push s!"dependency map entries: {depA.size} vs {depB.size}, mismatches {depBad}"
  problems := problems + depBad
  lines := lines.push
    (if problems == 0 then "VERIFY OK" else s!"VERIFY FAILED ({problems} problems)")
  return .ok { lines, problems }

end Litedoc4
