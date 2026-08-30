/- `crates/litedoc4-global/src/delta.rs`: the whole-package map delta — which
pages a moved name makes stale.

`--print-set` is the input to the incremental impact analysis. A module missing
from it keeps a page that links a name to the module it used to live in, and
**nothing downstream notices** — the site builds, every page is well-formed, and
the link is wrong; over-reporting only costs a re-render. So both halves err wide
on purpose: `autolinkTokens` over-approximates, and `changed` is taken over the
**union** of the two key sets, so that a name present on only one side counts as
a change. -/
import Std.Data.HashMap
import Std.Data.HashSet
import Litedoc4.Duration
import Litedoc4.Fs
import Litedoc4.Global.Facts
import Litedoc4.Ir.Utf16
import Litedoc4.JsonWrite

namespace Litedoc4

/-- `DeltaWitness` and not `Witness`: `ownership` has one too, and Rust keeps
them apart by crate where this namespace cannot. -/
structure DeltaWitness where
  module : String
  name : String
  deriving Inhabited

structure Delta where
  beforeNames : Nat := 0
  afterNames : Nat := 0
  /-- Every name whose module differs between the two maps, **sorted in UTF-16
  code unit order**. -/
  changed : Array String := #[]
  /-- The modules to re-render, sorted in UTF-16 code unit order. -/
  affected : Array String := #[]
  /-- One token per affected module, for the first `deltaWitnessLimit` of them in
  **index order** — diagnostics, not a contract. The token is the first of the
  module's sorted, deduplicated tokens that is in `changed`, which is not in
  general the first one its docstrings produced. -/
  witnesses : Array DeltaWitness := #[]
  deriving Inhabited

def deltaWitnessLimit : Nat := 20

def deltaChangedSample : Nat := 20

/-- `x`, computed, and the monotonic clock read after it was.

Not `let x := …` followed by a bare `IO.monoNanosNow`: the compiler may move a
pure `let` to the first place its value is looked at, and here it does — written
that way the delta reported a `scanSeconds` of 84 ns while 212 modules were
being scanned somewhere after the second read (measured 2026-08-31). `IO.mkRef`
is an opaque extern that has to be handed the value, so the work cannot cross
it. What would falsify this: a `mkRef` the optimiser can see through. -/
def timedPure (x : α) : IO (α × Nat) := do
  let box ← IO.mkRef x
  return (← box.get, ← IO.monoNanosNow)

/-- Split out of the computation only so that the caller can time the two
halves separately; they are one operation. -/
def deltaChanged (before after : Std.HashMap String String) : Array String := Id.run do
  let mut out : Array String := #[]
  -- Two loops and no deduplication: a key is unique within each map, so the
  -- first arm takes every name whose value moved or vanished and the second only
  -- the names the first could not see.
  for (name, module) in before do
    if after.get? name != some module then out := out.push name
  for (name, _) in after do
    if !before.contains name then out := out.push name
  return sortUtf16 out

/-- The modules whose docstrings mention a changed name, scanned in index
order. -/
def deltaScan (beforeNames afterNames : Nat) (changed : Array String)
    (facts : Array ModuleFacts) : Delta := Id.run do
  let mut affected : Array String := #[]
  let mut witnesses : Array DeltaWitness := #[]
  -- Only an optimisation, and it decides nothing: with an empty changed set the
  -- loop finds nothing anyway. It is here because "nothing moved" is the
  -- pipeline's common case and the scan is the second-most expensive thing here.
  if !changed.isEmpty then
    let mut lookup : Std.HashSet String := Std.HashSet.emptyWithCapacity (changed.size * 2 + 8)
    for name in changed do lookup := lookup.insert name
    for f in facts do
      let some hit := f.tokens.find? (lookup.contains ·) | continue
      affected := affected.push f.module
      if witnesses.size < deltaWitnessLimit then
        witnesses := witnesses.push { module := f.module, name := hit }
  return { beforeNames, afterNames, changed, affected := sortUtf16 affected, witnesses }

/-- The `--print-set` file: one module per line.

`linesFile` and not a `join`, so that **an empty set is an empty file, with no
newline**. The consumer counts lines, so a lone newline would be one module named
by the empty string — and the renderer has to tell "no subset asked for" apart
from "a subset that came out empty", which this file is how to spell. -/
def deltaPrintSet (d : Delta) : String := linesFile d.affected

private def deltaJsonNames (out : String) (items : Array String) : String := Id.run do
  if items.isEmpty then return out ++ "[]"
  let mut o := out ++ "[\n"
  for k in [0 : items.size] do
    o := jsonStr (o ++ "    ") items[k]!
    o := o ++ (if k + 1 == items.size then "\n" else ",\n")
  return o ++ "  ]"

/-- The `--delta-json` file, as `serde_json::to_string_pretty` writes it: two
spaces per level, and the field order is the record's.

**Nothing may assert on this file's bytes** — the three durations are wall clock,
and the two halves do not even spell a float the same way (Lean has no
shortest-round-trip printer, so they go out at a fixed nine places). Assert on
`--print-set`, which has no floats in it. -/
def deltaJson (d : Delta) (diffNanos scanNanos totalNanos : Nat) : String := Id.run do
  let mut o := "{\n  \"command\": \"delta\""
  o := o ++ s!",\n  \"beforeNames\": {d.beforeNames}"
  o := o ++ s!",\n  \"afterNames\": {d.afterNames}"
  o := o ++ s!",\n  \"changedNames\": {d.changed.size}"
  o := deltaJsonNames (o ++ ",\n  \"changedSample\": ") (d.changed.extract 0 deltaChangedSample)
  o := o ++ s!",\n  \"affected\": {d.affected.size}"
  o := deltaJsonNames (o ++ ",\n  \"affectedModules\": ") d.affected
  o := o ++ ",\n  \"witnesses\": "
  if d.witnesses.isEmpty then o := o ++ "[]"
  else
    o := o ++ "[\n"
    for k in [0 : d.witnesses.size] do
      let w := d.witnesses[k]!
      o := jsonStr (o ++ "    {\n      \"module\": ") w.module
      o := jsonStr (o ++ ",\n      \"name\": ") w.name
      o := o ++ "\n    }" ++ (if k + 1 == d.witnesses.size then "\n" else ",\n")
    o := o ++ "  ]"
  o := o ++ s!",\n  \"diffSeconds\": {seconds diffNanos 9}"
  o := o ++ s!",\n  \"scanSeconds\": {seconds scanNanos 9}"
  o := o ++ s!",\n  \"totalSeconds\": {seconds totalNanos 9}"
  return o ++ "\n}\n"

end Litedoc4
