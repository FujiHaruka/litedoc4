/- `crates/litedoc4-ir/src/{model,reader}.rs`: the IR as typed values, and the
tree on disk they are read from. -/
import Litedoc4.Json

open System

namespace Litedoc4

structure Span where
  start : Nat := 0
  stop : Nat := 0
  kind : Nat := 0
  name : String := ""
  front : Nat := 0
  back : Nat := 0
  deriving Inhabited

structure Member where
  label : String := ""
  name : String := ""
  text : String := ""
  code : Array Span := #[]
  binders : Array String := #[]
  binderCode : Array (Array Span) := #[]
  implicits : Array Bool := #[]
  doc : String := ""
  /-- `isDirect === false` is inherited; a *missing* key is direct. -/
  inherited : Bool := false
  deriving Inhabited

structure Decl where
  name : String := ""
  kind : String := ""
  modifiers : Array String := #[]
  binders : Array String := #[]
  implicits : Array Bool := #[]
  binderCode : Array (Array Span) := #[]
  ty : String := ""
  typeCode : Array Span := #[]
  line : Nat := 0
  col : Nat := 0
  endLine : Nat := 0
  endCol : Nat := 0
  index : Nat := 0
  members : Array Member := #[]
  doc : String := ""
  equations : Array String := #[]
  equationCode : Array (Array Span) := #[]
  /-- `[module, name]` on the wire; kept in that order. -/
  refs : Array (String × String) := #[]
  attrs : Array (String × String) := #[]
  /-- `"direct"` / `"transitive"`, or `""` for a key the writer left out.
  **Empty is not "no `sorry`" on its own** — below schema 5 the key could not
  exist, so the module's version decides which silence this is. -/
  sorryTag : String := ""
  /-- `[origin, from]`: the attribute that realized this declaration, and what
  it took as input one step back. -/
  generated : Option (String × String) := none
  instTypes : Array String := #[]
  deriving Inhabited

structure ModuleDoc where
  line : Nat := 0
  col : Nat := 0
  text : String := ""
  deriving Inhabited

structure Module where
  name : String := ""
  /-- 0 for a file that carries no `schemaVersion`, which is below every version
  this reads a key of. -/
  schemaVersion : Nat := 0
  imports : Array String := #[]
  moduleDocs : Array ModuleDoc := #[]
  decls : Array Decl := #[]
  /-- Only the length of `tactics` is ever read, so the entries are not. -/
  tacticCount : Nat := 0
  deriving Inhabited

def toSpan (v : JVal) : Span := Id.run do
  let a := asArr v
  let mut s : Span := { start := asNat a[0]!, stop := asNat a[1]!, kind := asNat a[2]! }
  if a.size > 3 then s := { s with name := asStr a[3]! }
  if a.size > 5 then s := { s with front := asNat a[4]!, back := asNat a[5]! }
  return s

@[inline] def toSpans (v : JVal) : Array Span := (asArr v).map toSpan

@[inline] def toSpanLists (v : JVal) : Array (Array Span) := (asArr v).map toSpans

@[inline] def toStrings (v : JVal) : Array String := (asArr v).map asStr

@[inline] def toBools (v : JVal) : Array Bool := (asArr v).map asBool

def toMember (v : JVal) : Member := Id.run do
  let mut m : Member := {}
  for (k, x) in asObj v do
    if k == "label" then m := { m with label := asStr x }
    else if k == "name" then m := { m with name := asStr x }
    else if k == "text" then m := { m with text := asStr x }
    else if k == "code" then m := { m with code := toSpans x }
    else if k == "binders" then m := { m with binders := toStrings x }
    else if k == "binderCode" then m := { m with binderCode := toSpanLists x }
    else if k == "implicits" then m := { m with implicits := toBools x }
    else if k == "doc" then m := { m with doc := asStr x }
    else if k == "isDirect" then
      m := { m with inherited := (match x with | .bool b => !b | _ => false) }
  return m

def toDecl (v : JVal) : Decl := Id.run do
  let mut d : Decl := {}
  for (k, x) in asObj v do
    if k == "name" then d := { d with name := asStr x }
    else if k == "kind" then d := { d with kind := asStr x }
    else if k == "type" then d := { d with ty := asStr x }
    else if k == "typeCode" then d := { d with typeCode := toSpans x }
    else if k == "binders" then d := { d with binders := toStrings x }
    else if k == "binderCode" then d := { d with binderCode := toSpanLists x }
    else if k == "implicits" then d := { d with implicits := toBools x }
    else if k == "line" then d := { d with line := asNat x }
    else if k == "col" then d := { d with col := asNat x }
    else if k == "endLine" then d := { d with endLine := asNat x }
    else if k == "endCol" then d := { d with endCol := asNat x }
    else if k == "index" then d := { d with index := asNat x }
    else if k == "doc" then d := { d with doc := asStr x }
    else if k == "modifiers" then d := { d with modifiers := toStrings x }
    else if k == "members" then d := { d with members := (asArr x).map toMember }
    else if k == "equations" then d := { d with equations := toStrings x }
    else if k == "equationCode" then d := { d with equationCode := toSpanLists x }
    else if k == "refs" then
      d := { d with refs := (asArr x).map fun r =>
        let a := asArr r; (asStr a[0]!, asStr a[1]!) }
    else if k == "attrs" then
      d := { d with attrs := (asArr x).map fun r =>
        let a := asArr r; (asStr a[0]!, asStr a[1]!) }
    else if k == "instTypes" then d := { d with instTypes := toStrings x }
    else if k == "sorry" then d := { d with sorryTag := asStr x }
    else if k == "generated" then
      let a := asArr x
      if a.size == 2 then d := { d with generated := some (asStr a[0]!, asStr a[1]!) }
  return d

def toModule (v : JVal) : Module := Id.run do
  let mut m : Module := {}
  for (k, x) in asObj v do
    if k == "module" then m := { m with name := asStr x }
    else if k == "schemaVersion" then m := { m with schemaVersion := asNat x }
    else if k == "imports" then m := { m with imports := toStrings x }
    else if k == "declarations" then m := { m with decls := (asArr x).map toDecl }
    else if k == "tactics" then m := { m with tacticCount := (asArr x).size }
    else if k == "moduleDocs" then
      m := { m with moduleDocs := (asArr x).map fun md => Id.run do
        let mut r : ModuleDoc := {}
        for (k2, y) in asObj md do
          if k2 == "line" then r := { r with line := asNat y }
          else if k2 == "col" then r := { r with col := asNat y }
          else if k2 == "text" then r := { r with text := asStr y }
        return r }
  return m

def parseModule (text : String) : Module :=
  let n := text.utf8ByteSize
  let (j, _) := JScan.pVal text n (JScan.skipWs text n 0)
  toModule j

structure IndexEntry where
  module : String := ""
  /-- Relative to the IR root, e.g. `modules/Foo.Bar.json`. -/
  file : String := ""
  deriving Inhabited

structure DepMapEntry where
  file : String := ""
  deriving Inhabited

structure Index where
  schemaVersion : Nat := 0
  leanVersion : String := ""
  ablations : Array String := #[]
  modules : Array IndexEntry := #[]
  dependencyMaps : Array DepMapEntry := #[]
  deriving Inhabited

def toIndexEntry (v : JVal) : IndexEntry := Id.run do
  let mut e : IndexEntry := {}
  for (k, x) in asObj v do
    if k == "module" then e := { e with module := asStr x }
    else if k == "file" then e := { e with file := asStr x }
  return e

def toDepMapEntry (v : JVal) : DepMapEntry := Id.run do
  let mut e : DepMapEntry := {}
  for (k, x) in asObj v do
    if k == "file" then e := { e with file := asStr x }
  return e

def toIndex (v : JVal) : Index := Id.run do
  let mut ix : Index := {}
  for (k, x) in asObj v do
    if k == "schemaVersion" then ix := { ix with schemaVersion := asNat x }
    else if k == "leanVersion" then ix := { ix with leanVersion := asStr x }
    else if k == "ablations" then ix := { ix with ablations := toStrings x }
    else if k == "modules" then ix := { ix with modules := (asArr x).map toIndexEntry }
    else if k == "dependencyMaps" then
      ix := { ix with dependencyMaps := (asArr x).map toDepMapEntry }
  return ix

/-- A floor of 5 buys one meaning per absence: schema 5 adds `sorry`,
`selectionRange` and `generated`, and for each of them an *absent* key says
something a schema-4 file cannot say, because there the key could not exist. -/
def minSchemaVersion : Nat := 5

def schemaRefusal (what : String) (found : Nat) : String :=
  s!"{what} is schema {found}; this reader needs schema {minSchemaVersion} or newer \
    (re-extract with --tagged-code)"

def ablatedRefusal (ablations : Array String) : String :=
  s!"this IR was written with ablations [{", ".intercalate ablations.toList}] \
    and is incomplete on purpose; it is for the stopwatch only"

def mismatchRefusal (path : FilePath) (expected found : String) : String :=
  s!"{path} declares module {found}, but the index files it under {expected}"

/-- Not `FilePath./`: it appends a separator unconditionally, so an `--ir` that
already ends in one yields `…/ir//modules/Foo.json`. The file opens either way,
but the path is quoted verbatim in three refusals whose wording has to match
Rust's `Path::join`. What would falsify this: a caller that normalizes the root
before it gets here. -/
def irPath (root : FilePath) (sub : String) : FilePath :=
  let s : FilePath := ⟨sub⟩
  let r := root.toString
  if s.isAbsolute || r.isEmpty then s
  else if FilePath.pathSeparators.contains r.back then ⟨r ++ sub⟩
  else root / s

def readIrFile (path : FilePath) : IO String := do
  try
    IO.FS.readFile path
  catch e =>
    throw (IO.userError s!"reading {path}: {e}")

/-- An IR tree on disk: `index.json`, `modules/`, `deps/`. -/
structure IrTree where
  root : FilePath
  index : Index

def openIrTree (root : FilePath) : IO IrTree := do
  let text ← readIrFile (irPath root "index.json")
  let n := text.utf8ByteSize
  let (j, _) := JScan.pVal text n (JScan.skipWs text n 0)
  let index := toIndex j
  if index.schemaVersion < minSchemaVersion then
    throw (IO.userError (schemaRefusal "index.json" index.schemaVersion))
  if !index.ablations.isEmpty then
    throw (IO.userError (ablatedRefusal index.ablations))
  return { root, index }

/-- The `schemaVersion` is checked here too: an incremental tree is a merge of
files from several extractor runs, so the index's version does not vouch for the
modules'. -/
def IrTree.module (t : IrTree) (e : IndexEntry) : IO Module := do
  let path := irPath t.root e.file
  let m := parseModule (← readIrFile path)
  if m.schemaVersion < minSchemaVersion then
    throw (IO.userError (schemaRefusal path.toString m.schemaVersion))
  if m.name != e.module then
    throw (IO.userError (mismatchRefusal path e.module m.name))
  return m

/-- The index names the modules and their order; a sorted listing of `modules/`
would answer the same on a tree the extractor just wrote and diverge on any
other — a stale file left in the directory becomes a page, and a merged tree's
order becomes the file names' rather than the index's. What would falsify this:
an index that stopped carrying `modules`. -/
def IrTree.loadModules (t : IrTree) : IO (Array Module) := do
  let mut out : Array Module := Array.mkEmpty t.index.modules.size
  for e in t.index.modules do
    out := out.push (← t.module e)
  return out

def IrTree.depMap (t : IrTree) (e : DepMapEntry) : IO (Array (String × String)) := do
  let text ← readIrFile (irPath t.root e.file)
  let n := text.utf8ByteSize
  let (j, _) := JScan.pVal text n (JScan.skipWs text n 0)
  let mut ds : Array (String × String) := #[]
  for (k, v) in asObj j do
    if k == "declarations" then
      for (name, m) in asObj v do
        ds := ds.push (name, asStr m)
  return ds

def IrTree.loadDepMaps (t : IrTree) : IO (Array (Array (String × String))) := do
  let mut out : Array (Array (String × String)) :=
    Array.mkEmpty t.index.dependencyMaps.size
  for e in t.index.dependencyMaps do
    out := out.push (← t.depMap e)
  return out

end Litedoc4
