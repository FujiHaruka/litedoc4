/- SHA-256 (FIPS 180-4): the ledger's per-file hashes and its two key digests.

Lean rather than C under `csrc/`: the C route is `vendor/md4c`'s and a
transcribed implementation carries an attribution obligation
(`docs/provenance.md`), for a hash that runs here at 112 MB/s single-threaded —
2.03 s for the measurement target's 422 oleans against a 60 s budget
(measured 2026-08-31 → `benchmarks/results/purelean-sha256-2026-08-31.txt`).
What would falsify this: an input an order of magnitude larger, or a caller that
hashes it more than once per build. -/
import Litedoc4.Bytes

namespace Litedoc4
namespace Sha256

@[inline] def rotr (x : UInt32) (n : UInt32) : UInt32 := (x >>> n) ||| (x <<< (32 - n))

def roundConstants : Array UInt32 := #[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

structure State where
  a : UInt32
  b : UInt32
  c : UInt32
  d : UInt32
  e : UInt32
  f : UInt32
  g : UInt32
  h : UInt32
  deriving Inhabited

def initial : State :=
  ⟨0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19⟩

@[inline] def beWord (bs : ByteArray) (i : Nat) : UInt32 :=
  ((bs.get! i).toUInt32 <<< 24) ||| ((bs.get! (i + 1)).toUInt32 <<< 16) |||
    ((bs.get! (i + 2)).toUInt32 <<< 8) ||| (bs.get! (i + 3)).toUInt32

def expand : Nat → Nat → Array UInt32 → Array UInt32
  | 0, _, w => w
  | n + 1, i, w =>
    let x := w[i - 15]!
    let y := w[i - 2]!
    let s0 := rotr x 7 ^^^ rotr x 18 ^^^ (x >>> 3)
    let s1 := rotr y 17 ^^^ rotr y 19 ^^^ (y >>> 10)
    expand n (i + 1) (w.push (w[i - 16]! + s0 + w[i - 7]! + s1))

def schedule (bs : ByteArray) (off : Nat) : Array UInt32 := Id.run do
  let mut w : Array UInt32 := Array.mkEmpty 64
  for j in [0:16] do
    w := w.push (beWord bs (off + j * 4))
  return expand 48 16 w

/-- The eight working variables are arguments rather than a `State`, so that the
64 rounds allocate one structure between them instead of one apiece. What would
falsify this: a Lean that stopped unboxing `UInt32` arguments. -/
def rounds : Nat → Nat → Array UInt32 →
    UInt32 → UInt32 → UInt32 → UInt32 → UInt32 → UInt32 → UInt32 → UInt32 → State
  | 0, _, _, a, b, c, d, e, f, g, h => ⟨a, b, c, d, e, f, g, h⟩
  | n + 1, i, w, a, b, c, d, e, f, g, h =>
    let t1 := h + (rotr e 6 ^^^ rotr e 11 ^^^ rotr e 25) + ((e &&& f) ^^^ (~~~e &&& g))
      + roundConstants[i]! + w[i]!
    let t2 := (rotr a 2 ^^^ rotr a 13 ^^^ rotr a 22)
      + ((a &&& b) ^^^ (a &&& c) ^^^ (b &&& c))
    rounds n (i + 1) w (t1 + t2) a b c (d + t1) e f g

def block (s : State) (bs : ByteArray) (off : Nat) : State :=
  let r := rounds 64 0 (schedule bs off) s.a s.b s.c s.d s.e s.f s.g s.h
  ⟨s.a + r.a, s.b + r.b, s.c + r.c, s.d + r.d, s.e + r.e, s.f + r.f, s.g + r.g, s.h + r.h⟩

def blocks : Nat → ByteArray → Nat → State → State
  | 0, _, _, s => s
  | n + 1, bs, off, s => blocks n bs (off + 64) (block s bs off)

/-- The trailing partial block, the `0x80`, the zero fill and the 64-bit length,
as the one or two blocks they make. Built rather than appended to the input: the
input is an olean read whole, and padding it in place would copy it. -/
def tail (bs : ByteArray) (from_ : Nat) : ByteArray := Id.run do
  let n := bs.size
  let rest := n - from_
  let mut out : ByteArray := ByteArray.emptyWithCapacity 128
  for i in [from_:n] do
    out := out.push (bs.get! i)
  out := out.push 0x80
  let target := if rest < 56 then 56 else 120
  for _ in [out.size:target] do
    out := out.push 0
  let bits : Nat := n * 8
  for i in [0:8] do
    out := out.push (UInt8.ofNat ((bits >>> ((7 - i) * 8)) % 256))
  return out

def digestBytes (s : State) : ByteArray := Id.run do
  let mut out : ByteArray := ByteArray.emptyWithCapacity 32
  for w in #[s.a, s.b, s.c, s.d, s.e, s.f, s.g, s.h] do
    out := out.push (w >>> 24).toUInt8
    out := out.push (w >>> 16).toUInt8
    out := out.push (w >>> 8).toUInt8
    out := out.push w.toUInt8
  return out

def hash (bs : ByteArray) : ByteArray :=
  let full := bs.size / 64
  let s := blocks full bs 0 initial
  let t := tail bs (full * 64)
  digestBytes (blocks (t.size / 64) t 0 s)

end Sha256

def sha256Hex (bs : ByteArray) : String := Id.run do
  let d := Sha256.hash bs
  let mut out := ""
  for i in [0:d.size] do
    let b := (d.get! i).toNat
    out := (out.push (hexDigit (b / 16))).push (hexDigit (b % 16))
  return out

def sha256Text (s : String) : String := sha256Hex s.toUTF8

def sha256File (path : System.FilePath) : IO String := do
  return sha256Hex (← IO.FS.readBinFile path)

end Litedoc4
