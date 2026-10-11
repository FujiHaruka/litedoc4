namespace Litedoc4

def parallelMap (workers : Nat) (items : Array α) (f : α → IO β) : IO (Array β) := do
  let workers := max 1 (min workers items.size)
  if workers == 1 then return ← items.mapM f
  let next ← IO.mkRef 0
  let tasks ← (Array.range workers).mapM fun _ =>
    IO.asTask (prio := .dedicated) (α := Array (Nat × Except IO.Error β)) do
      let mut done := #[]
      repeat
        let k ← next.modifyGet fun k => (k, k + 1)
        let some item := items[k]? | break
        done := done.push (k, ← (f item).toBaseIO)
      return done
  let mut results : Array (Option (Except IO.Error β)) := Array.replicate items.size none
  for task in tasks do
    for (k, result) in ← MonadExcept.ofExcept (← IO.wait task) do
      results := results.set! k (some result)
  -- The first failure in list order, not in completion order: the one a sequential walk throws.
  results.mapIdxM fun k result => match result with
    | some result => MonadExcept.ofExcept result
    | none => throw (IO.userError s!"parallelMap: item {k} of {items.size} was never claimed")

end Litedoc4
