/- A duration printed to a fixed number of places, which is what `format!`'s
`{:.4}` does on the Rust side. Its own module because four stages that share no
other code print one — the build, the ledger's timings, `ownership` and
`merge` — and a formatter living in whichever of them was written first is a
dependency the others pay for the whole of. -/

namespace Litedoc4

/-- `format!("{n:.digits$}")` for a non-negative rational, rounded half up.
Lean's `Float.toString` takes no width. -/
def fixed (num den digits : Nat) : String :=
  if den == 0 then "n/a" else
  let scale := 10 ^ digits
  let scaled := (2 * num * scale + den) / (2 * den)
  let frac := toString (scaled % scale)
  s!"{scaled / scale}." ++ String.ofList (List.replicate (digits - frac.length) '0') ++ frac

def seconds (nanos : Nat) (digits : Nat) : String := fixed nanos 1000000000 digits

end Litedoc4
