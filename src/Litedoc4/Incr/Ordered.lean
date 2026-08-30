/- `crates/litedoc4-incr/src/ordered.rs`: a `name -> value` map that remembers
the order its keys arrived in.

Two files this build writes are JSON objects whose **key order is part of the
bytes**: the ledger's `extractKey` / `renderKey` and the merged `index.json`.
Both are compared against bytes a JavaScript object produced, and a JavaScript
object keeps insertion order.

An array of pairs and not a hash map: the maps it backs hold a handful of keys
each, the order is the point, and callers that need a lookup inside a loop build
their own index. -/

namespace Litedoc4

/-- On a repeated key the first position is kept and the last value taken, which
is what assigning to a JavaScript object property does — it is what makes the
merged index keep the base index's key order, and what lets a hand-edited file
with a duplicated key round-trip. -/
def orderedInsert (o : Array (String × α)) (key : String) (value : α) : Array (String × α) :=
  match o.findIdx? (·.1 == key) with
  | some i => o.set! i (key, value)
  | none => o.push (key, value)

def orderedGet? (o : Array (String × α)) (key : String) : Option α :=
  (o.find? (·.1 == key)).map (·.2)

end Litedoc4
