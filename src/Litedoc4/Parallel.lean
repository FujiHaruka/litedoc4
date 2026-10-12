namespace Litedoc4

def parallelMap (workers : Nat) (items : Array α) (f : α → IO β) : IO (Array β) := do
  let n := items.size
  let workers := max 1 (min workers n)
  -- Items taken out of a ref rather than read from `items`: each is released once `f` has run on it, not after the last.
  let pending ← IO.mkRef (items.map some)
  let take (k : Nat) : IO (Option α) := pending.modifyGet fun a => (a[k]?.join, a.set! k none)
  if workers == 1 then
    let mut out := Array.mkEmpty n
    repeat
      let some item ← take out.size | break
      out := out.push (← f item)
    return out
  let next ← IO.mkRef 0
  let tasks ← (Array.range workers).mapM fun _ =>
    IO.asTask (prio := .dedicated) (α := Array (Nat × Except IO.Error β)) do
      let mut done := #[]
      repeat
        let k ← next.modifyGet fun k => (k, k + 1)
        let some item ← take k | break
        done := done.push (k, ← (f item).toBaseIO)
      return done
  let mut results : Array (Option (Except IO.Error β)) := Array.replicate n none
  for task in tasks do
    for (k, result) in ← MonadExcept.ofExcept (← IO.wait task) do
      results := results.set! k (some result)
  -- The first failure in list order, not in completion order: the one a sequential walk throws.
  results.mapIdxM fun k result => match result with
    | some result => MonadExcept.ofExcept result
    | none => throw (IO.userError s!"parallelMap: item {k} of {n} was never claimed")

end Litedoc4
