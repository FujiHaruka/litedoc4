/- `crates/litedoc4-global/src/state.rs`: the `contentHash` cache.
`--state <dir>` keeps `<dir>/global-state.json`.

A hit is decided on the IR's own hash, never on the caller's idea of what
changed, so a driver that passes a wrong changed-set cannot corrupt this cache.

**Everything that can go wrong loads as "empty", silently** — a missing file, a
file that does not parse, an entry missing a field, any of the four version keys
disagreeing with the index. A cold cache is the normal first run, and a `--state`
directory left behind by another tool is not an error the caller can act on: the
only correct response is to rebuild, which is what happens. Being wrong this way
costs time, where trusting a foreign entry costs a wrong artifact that nobody
reports. -/
import Litedoc4.Global.Facts
import Litedoc4.JsonWrite

open System

namespace Litedoc4

def stateFile : String := "global-state.json"

/-- Bumped when the *file format* changes. Kept apart from `stateDerivation`,
which is bumped when the *facts* change, because the two rot for different
reasons. -/
def stateVersion : Nat := 1

/-- Which rule built the facts in the file. **Bump it whenever a field of
`ModuleFacts` or the way one is derived changes**: bumping makes every entry a
miss, which is correct and slow, where keeping entries built by an older rule is
fast and wrong.

The value is `crates/litedoc4-global/src/state.rs`'s, character for character,
and that is the point: a state file written by either half has to be readable by
the other, or the two are not comparable. It is deliberately **not** the frozen
prototype's `"stage7h/global.ts facts v1"` — that string names an
implementation with a different tokeniser, so its entries have to miss here. -/
def stateDerivation : String := "litedoc4-global facts v4"

/-! ## Reading a file nobody in this tree wrote -/

def stateField (fields : Array (String × JVal)) (key : String) : JVal := Id.run do
  for (k, v) in fields do
    if k == key then return v
  return .null

/-- The ten keys an entry has to carry. A missing one is a file written by
something that derived its facts differently, and reading it as a default would
serve an artifact derived from a fact that is silently absent. -/
def factKeys : Array String :=
  #["module", "contentHash", "imports", "tactics", "decls", "instances", "tokens",
    "instancesFor", "refs", "summary"]

def toNamePairs (v : JVal) : Array (String × String) :=
  (asArr v).map fun p =>
    let a := asArr p
    (asStr (a.getD 0 .null), asStr (a.getD 1 .null))

def toModuleFacts (v : JVal) : Option ModuleFacts := Id.run do
  let fields := asObj v
  for key in factKeys do
    if !fields.any (fun p => p.1 == key) then return none
  let mut f : ModuleFacts := {}
  for (k, x) in fields do
    if k == "module" then f := { f with module := asStr x }
    else if k == "contentHash" then f := { f with contentHash := asStr x }
    else if k == "imports" then f := { f with imports := toStrings x }
    else if k == "tactics" then f := { f with tactics := asNat x }
    else if k == "decls" then f := { f with decls := toNamePairs x }
    else if k == "instances" then f := { f with instances := toNamePairs x }
    else if k == "tokens" then f := { f with tokens := toStrings x }
    else if k == "instancesFor" then f := { f with instancesFor := toNamePairs x }
    else if k == "refs" then
      let entries := asObj x
      let mut refs : Std.HashMap String (Array Nat) :=
        Std.HashMap.emptyWithCapacity entries.size
      for (name, users) in entries do
        refs := refs.insert name ((asArr users).map asNat)
      f := { f with refs }
    else if k == "summary" then
      f := { f with summary := (match x with | .str text => some text | _ => none) }
  return some f

/-- The facts a previous run left behind, already checked against this run's
index. Empty is a complete and valid value: every module will be read. -/
structure State where
  modules : Std.HashMap String ModuleFacts := Std.HashMap.emptyWithCapacity 0

/-- The four version keys are checked against `index` here rather than at the hit
test, so a foreign state costs one parse and not one comparison per module.

Split from `State.load` because everything that decides whether a file is this
run's cache is in the text: with the read folded in, the only way to ask is to
write a file first, and the four rejections are then answered by a disk rather
than by the rule. -/
def stateOf (text : String) (index : Index) : State := Id.run do
  let .ok j := parseJson text | return {}
  let fields := asObj j
  if asNat (stateField fields "stateVersion") != stateVersion then return {}
  if asStr (stateField fields "derivation") != stateDerivation then return {}
  if asNat (stateField fields "schemaVersion") != index.schemaVersion then return {}
  if asStr (stateField fields "generator") != index.generator then return {}
  let entries := asObj (stateField fields "modules")
  let mut modules : Std.HashMap String ModuleFacts :=
    Std.HashMap.emptyWithCapacity entries.size
  for (name, entry) in entries do
    let some facts := toModuleFacts entry | return {}
    modules := modules.insert name facts
  return { modules }

def State.load (dir : Option FilePath) (index : Index) : IO State := do
  let some dir := dir | return {}
  match ← (IO.FS.readFile (dir / stateFile)).toBaseIO with
  | .error _ => return {}
  | .ok text => return stateOf text index

/-! ## Writing it back -/

def jsonStrArray (out : String) (xs : Array String) : String := Id.run do
  let mut o := out.push '['
  let mut first := true
  for x in xs do
    if !first then o := o.push ','
    first := false
    o := jsonStr o x
  return o.push ']'

def jsonPairArray (out : String) (xs : Array (String × String)) : String := Id.run do
  let mut o := out.push '['
  let mut first := true
  for (a, b) in xs do
    if !first then o := o.push ','
    first := false
    o := (jsonStr ((jsonStr (o.push '[') a).push ',') b).push ']'
  return o.push ']'

/-- `refs` is a `BTreeMap<String, _>` on the other side, so its keys are written
in **byte** order and not the UTF-16 order every artifact uses. -/
def jsonRefs (out : String) (refs : Std.HashMap String (Array Nat)) : String := Id.run do
  let mut keys : Array String := Array.mkEmpty refs.size
  for (k, _) in refs do keys := keys.push k
  let mut o := out.push '{'
  let mut first := true
  for k in keys.qsort byteLt do
    if !first then o := o.push ','
    first := false
    o := ((jsonStr o k).push ':').push '['
    let mut firstUser := true
    for user in refs.getD k #[] do
      if !firstUser then o := o.push ','
      firstUser := false
      o := o ++ toString user
    o := o.push ']'
  return o.push '}'

def jsonFacts (out : String) (f : ModuleFacts) : String := Id.run do
  let mut o := jsonStr (out ++ "{\"module\":") f.module
  o := jsonStr (o ++ ",\"contentHash\":") f.contentHash
  o := jsonStrArray (o ++ ",\"imports\":") f.imports
  o := o ++ ",\"tactics\":" ++ toString f.tactics
  o := jsonPairArray (o ++ ",\"decls\":") f.decls
  o := jsonPairArray (o ++ ",\"instances\":") f.instances
  o := jsonStrArray (o ++ ",\"tokens\":") f.tokens
  o := jsonPairArray (o ++ ",\"instancesFor\":") f.instancesFor
  o := jsonRefs (o ++ ",\"refs\":") f.refs
  o := o ++ ",\"summary\":"
  o := match f.summary with
    | none => o ++ "null"
    | some text => jsonStr o text
  return o.push '}'

/-- `<dir>/global-state.json`'s bytes.

**Only modules the index still lists are written, in index order.** An entry for
a module that has left the package has to disappear with it: keeping it would
leave a name in `name-map.json` and a module in `importedBy` that no IR file
backs, and a cache that only ever grows passes every other test. Index order
rather than hash order so that two runs over the same module set write the same
bytes.

Split from `State.save` for the reason `stateOf` is split from `State.load`: what
is written is decided by the index and the facts, and folding the write in would
make a directory the only way to ask what the rule is. -/
def stateJson (index : Index) (facts : Array ModuleFacts) : String := Id.run do
  -- Keying on the facts' own module name is keying on the index entry's:
  -- `IrTree.module` refuses a file that disagrees with the index about which
  -- module it holds.
  let mut byModule : Std.HashMap String ModuleFacts :=
    Std.HashMap.emptyWithCapacity facts.size
  for f in facts do byModule := byModule.insert f.module f
  let mut o := "{\"stateVersion\":" ++ toString stateVersion
  o := jsonStr (o ++ ",\"derivation\":") stateDerivation
  o := o ++ ",\"schemaVersion\":" ++ toString index.schemaVersion
  o := jsonStr (o ++ ",\"generator\":") index.generator
  o := o ++ ",\"modules\":{"
  let mut first := true
  for entry in index.modules do
    match byModule.get? entry.module with
    | none => pure ()
    | some f =>
      if !first then o := o.push ','
      first := false
      o := jsonFacts ((jsonStr o f.module).push ':') f
  return o ++ "}}"

/-- Writes the file and returns its size in bytes, or 0 when there is no state
directory. -/
def State.save (dir : Option FilePath) (index : Index) (facts : Array ModuleFacts) : IO Nat := do
  let some dir := dir | return 0
  IO.FS.createDirAll dir
  let body := stateJson index facts
  IO.FS.writeFile (dir / stateFile) body
  return body.utf8ByteSize

end Litedoc4
