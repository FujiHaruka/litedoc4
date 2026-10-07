/- Allocate one block of `MiB` MiB, touch every byte, drop it, three times; print the RSS floor
after each. Run with `lean --run` under the toolchain being asked. -/
def floor : IO String := do
  match ← (IO.FS.readFile "/proc/self/status").toBaseIO with
  | .ok s => pure (String.intercalate " " ((s.splitOn "\n").filter (·.startsWith "VmRSS")))
  | .error _ => pure "no /proc"

def main (args : List String) : IO Unit := do
  let mib := (args.head? >>= String.toNat?).getD 66
  let n := mib * 1048576
  for i in [0:3] do
    let mut b := ByteArray.emptyWithCapacity n
    for j in [0:n] do b := b.push j.toUInt8
    IO.println s!"{mib} MiB, iteration {i + 1}: {b.size} bytes"
    IO.sleep 3000
    IO.println s!"  floor {← floor}"
