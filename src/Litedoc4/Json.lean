/- A JSON reader for the IR, hand-written.

Not `Lean.Data.Json`: importing it costs 118 MB in the executable against
5.3 MB for one that stops at `Std` (measured 2026-08-30 →
`benchmarks/results/purelean-ci-probe-2026-08-30.txt`), and a consumer builds
this on every checkout. What would falsify this: a distribution model that
ships a built binary rather than a `require`. -/
import Litedoc4.Bytes

namespace Litedoc4

inductive JVal where
  | null
  | bool (b : Bool)
  | num (n : Int)
  /-- A number with a fraction or an exponent, kept as the bytes it was written
  as. Not a `Float`: Lean has no shortest-round-trip printer, so a document read
  and written back would carry a different spelling of the same value. What would
  falsify this: a number of this shape that is arithmetic rather than passed
  through — the ones there are (the extractor's phase timers, folded into one
  record by whoever ran it) are only ever copied. -/
  | real (lexeme : String)
  | str (s : String)
  | arr (a : Array JVal)
  | obj (a : Array (String × JVal))
  /-- Where the document stopped making sense, and why. A constructor rather
  than an `Except` threading through the scanner: the IR is tens of megabytes of
  values and wrapping every one of them would double the allocations on the only
  path that reads it. Only `parse` ever holds one — it refuses — so no consumer
  can be handed a `.bad` to fall through its catch-all. What would falsify this:
  a caller that wants the prefix that did parse. -/
  | bad (why : String)
  deriving Inhabited

namespace JScan

@[inline] def isWs (c : UInt8) : Bool := c == 32 || c == 10 || c == 13 || c == 9

partial def skipWs (s : String) (n i : Nat) : Nat :=
  if i < n && isWs (byteAt s i) then skipWs s n (i + 1) else i

partial def scanStrEnd (s : String) (n i : Nat) (esc : Bool) : Nat × Bool :=
  if i >= n then (i, esc)
  else
    let c := byteAt s i
    if c == 34 then (i, esc)
    else if c == 92 then scanStrEnd s n (i + 2) true
    else scanStrEnd s n (i + 1) esc

def hexVal (c : UInt8) : Nat :=
  if c >= 48 && c <= 57 then c.toNat - 48
  else if c >= 97 && c <= 102 then c.toNat - 87
  else if c >= 65 && c <= 70 then c.toNat - 55
  else 0

partial def unescape (s : String) (endq : Nat) (segStart i : Nat) (acc : String) : String :=
  if i >= endq then acc ++ byteSub s segStart endq
  else if byteAt s i == 92 then
    let acc := acc ++ byteSub s segStart i
    let e := byteAt s (i + 1)
    if e == 117 then
      let v := hexVal (byteAt s (i+2)) * 4096 + hexVal (byteAt s (i+3)) * 256
             + hexVal (byteAt s (i+4)) * 16 + hexVal (byteAt s (i+5))
      if v >= 0xD800 && v < 0xDC00 && i + 11 < endq
         && byteAt s (i+6) == 92 && byteAt s (i+7) == 117 then
        let lo := hexVal (byteAt s (i+8)) * 4096 + hexVal (byteAt s (i+9)) * 256
                + hexVal (byteAt s (i+10)) * 16 + hexVal (byteAt s (i+11))
        let cp := 0x10000 + (v - 0xD800) * 1024 + (lo - 0xDC00)
        unescape s endq (i + 12) (i + 12) (acc.push (Char.ofNat cp))
      else
        unescape s endq (i + 6) (i + 6) (acc.push (Char.ofNat v))
    else
      let ch : Char :=
        if e == 110 then '\n'
        else if e == 116 then '\t'
        else if e == 114 then '\x0d'
        else if e == 98 then '\x08'
        else if e == 102 then '\x0c'
        else if e == 34 then '"'
        else if e == 92 then '\\'
        else if e == 47 then '/'
        else Char.ofNat 0xfffd
      unescape s endq (i + 2) (i + 2) (acc.push ch)
  else unescape s endq segStart (i + 1) acc

@[inline] def readStr (s : String) (n i : Nat) : String × Nat :=
  let (e, esc) := scanStrEnd s n i false
  if esc then (unescape s e i i "", e + 1) else (byteSub s i e, e + 1)

/-- Whether `lit` is the bytes at `i`. Byte by byte rather than `byteSub` and a
`String` comparison, which would allocate once per `true`, `false` and `null` in
the IR. -/
def isLit (s : String) (n i : Nat) (lit : String) : Bool := Id.run do
  let m := lit.utf8ByteSize
  if i + m > n then return false
  let mut k := 0
  while k < m do
    if byteAt s (i + k) != byteAt lit k then return false
    k := k + 1
  return true

partial def digits (s : String) (n i : Nat) (acc : Nat) : Nat × Nat :=
  if i < n then
    let c := byteAt s i
    if c >= 48 && c <= 57 then digits s n (i + 1) (acc * 10 + (c.toNat - 48)) else (acc, i)
  else (acc, i)

/-- `.`, `e` and `E`: what tells a number the integer path cannot carry from one
it can, at the byte the digits stopped on. -/
@[inline] def isRealByte (c : UInt8) : Bool := c == 46 || c == 101 || c == 69

/-- The end of a number whose digits ran into a `.` or an exponent. The whole
character class is taken in one sweep rather than the grammar being followed
arm by arm, because the value is never inspected: what is wanted is where the
number stops so the bytes before it can be kept. -/
partial def realEnd (s : String) (n i : Nat) : Nat :=
  if i < n then
    let c := byteAt s i
    if (c >= 48 && c <= 57) || isRealByte c || c == 43 || c == 45 then realEnd s n (i + 1)
    else i
  else i

mutual

partial def pVal (s : String) (n i : Nat) : JVal × Nat :=
  if i >= n then (.bad s!"a value was expected at {i}, and the document ends there", n)
  else
  let c := byteAt s i
  if c == 123 then pObj s n (i + 1) (Array.mkEmpty 24)
  else if c == 91 then pArr s n (i + 1) (Array.mkEmpty 8)
  else if c == 34 then
    let (v, i) := readStr s n (i + 1)
    (.str v, i)
  else if isLit s n i "true" then (.bool true, i + 4)
  else if isLit s n i "false" then (.bool false, i + 5)
  else if isLit s n i "null" then (.null, i + 4)
  else
    let neg := c == 45
    let start := i
    let d0 := if neg then i + 1 else i
    let (d, j) := digits s n d0 0
    if j == d0 then (.bad s!"a value was expected at {i}, and byte {c} begins none", n)
    else if j < n && isRealByte (byteAt s j) then
      let e := realEnd s n j
      (.real (byteSub s start e), e)
    else
      (.num (if neg then -(Int.ofNat d) else Int.ofNat d), j)

partial def pArr (s : String) (n i : Nat) (acc : Array JVal) : JVal × Nat :=
  let i := skipWs s n i
  if i < n && byteAt s i == 93 then (.arr acc, i + 1)
  else
    let (v, i) := pVal s n i
    match v with
    | .bad _ => (v, n)
    | _ =>
      let acc := acc.push v
      let i := skipWs s n i
      let c := byteAt s i
      if i < n && c == 44 then pArr s n (i + 1) acc
      else if i < n && c == 93 then (.arr acc, i + 1)
      else (.bad s!"an array wanted `,` or `]` at {i}, and found byte {c}", n)

partial def pObj (s : String) (n i : Nat) (acc : Array (String × JVal)) : JVal × Nat :=
  let i := skipWs s n i
  if i < n && byteAt s i == 125 then (.obj acc, i + 1)
  else if i >= n || byteAt s i != 34 then
    (.bad s!"an object wanted a key at {i}, and found byte {byteAt s i}", n)
  else
    let (k, i) := readStr s n (i + 1)
    let i := skipWs s n i
    if i >= n || byteAt s i != 58 then
      (.bad s!"the key `{k}` wanted `:` at {i}, and found byte {byteAt s i}", n)
    else
    let (v, i) := pVal s n (skipWs s n (i + 1))
    match v with
    | .bad _ => (v, n)
    | _ =>
      let acc := acc.push (k, v)
      let i := skipWs s n i
      let c := byteAt s i
      if i < n && c == 44 then pObj s n (skipWs s n (i + 1)) acc
      else if i < n && c == 125 then (.obj acc, i + 1)
      else (.bad s!"an object wanted `,` or `}` at {i}, and found byte {c}", n)

end

end JScan

/-- The whole document, or what is wrong with it and where.

The scanner's leniencies are refusals here rather than defaults: a key with no
`:`, a `tru`, a `,` where a `]` belongs, bytes after the last value. M5 reads
files this run did not write — a ledger any version may have written, a marker a
broken run left, an IR tree a cache restored — and for those "it did not parse"
has to be sayable, with the file's name, instead of a value nobody chose. -/
def parseJson (text : String) : Except String JVal :=
  let n := text.utf8ByteSize
  let (v, i) := JScan.pVal text n (JScan.skipWs text n 0)
  match v with
  | .bad why => .error why
  | _ =>
    let e := JScan.skipWs text n i
    if e == n then .ok v
    else .error s!"the value ends at {i} and the document has {n - e} more byte(s)"

@[inline] def asStr : JVal → String | .str s => s | _ => ""
@[inline] def asNat : JVal → Nat | .num n => n.toNat | _ => 0
@[inline] def asArr : JVal → Array JVal | .arr a => a | _ => #[]
@[inline] def asObj : JVal → Array (String × JVal) | .obj a => a | _ => #[]
@[inline] def asBool : JVal → Bool | .bool b => b | _ => false
@[inline] def isNull : JVal → Bool | .null => true | _ => false

/-- The last value under `key`, which is what a JSON parser backed by a map
leaves behind for a document that repeats one. -/
def jvalGet? (j : JVal) (key : String) : Option JVal := Id.run do
  let mut found : Option JVal := none
  for (k, v) in asObj j do
    if k == key then found := some v
  return found

end Litedoc4
