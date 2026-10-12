/- C under `csrc/` rather than Lean the way `Sha256` is: a deflate whose output
size is worth comparing is thousands of lines of match finding, and miniz is an
existing one (`vendor/miniz/PROVENANCE.md`). -/

namespace Litedoc4
namespace Gzip

/-- One gzip member: no file name, mtime 0, OS byte 255, so equal input gives
equal bytes on every platform. Levels above 10 are level 10. -/
@[extern "litedoc4_gzip_compress"]
opaque compress (level : UInt8 := 6) (input : @& ByteArray) : ByteArray

inductive Refusal where
  | shorterThanAMember
  | notGzip
  | notDeflate
  | reservedFlagSet
  | headerRunsIntoTrailer
  | headerChecksumMismatch
  | trailerClaimsMoreThanDeflateCanHold
  | corruptDeflate
  | truncatedDeflate
  | bytesBetweenDeflateAndTrailer
  | longerThanItsTrailerSays
  | shorterThanItsTrailerSays
  | checksumMismatch
deriving Inhabited, Repr, BEq

def Refusal.message : Refusal → String
  | .shorterThanAMember => "gzip: shorter than the 18 bytes of an empty member"
  | .notGzip => "gzip: not a gzip member (the first two bytes are not 1f 8b)"
  | .notDeflate => "gzip: the compression method is not deflate"
  | .reservedFlagSet => "gzip: a reserved header flag is set"
  | .headerRunsIntoTrailer => "gzip: the header's optional fields run into the trailer"
  | .headerChecksumMismatch => "gzip: the header checksum does not match the header"
  | .trailerClaimsMoreThanDeflateCanHold =>
    "gzip: the trailer claims a length the deflate stream is too short to hold"
  | .corruptDeflate => "gzip: the deflate stream is corrupt"
  | .truncatedDeflate => "gzip: the deflate stream is truncated"
  | .bytesBetweenDeflateAndTrailer =>
    "gzip: bytes follow the deflate stream before the trailer (a second member, or trailing data)"
  | .longerThanItsTrailerSays => "gzip: the content is longer than the trailer says"
  | .shorterThanItsTrailerSays => "gzip: the content is shorter than the trailer says"
  | .checksumMismatch => "gzip: the content's CRC-32 does not match the trailer"

@[extern "litedoc4_gzip_inflate_member"]
private opaque inflateMember (input : @& ByteArray) : Except Refusal ByteArray

/-- Exactly one member, with nothing after it. -/
def decompress (input : ByteArray) : Except String ByteArray :=
  (inflateMember input).mapError Refusal.message

private opaque ReaderPointed : NonemptyType

/-- One member of a known length, inflated a piece at a time; it answers a
refusal or the end only once every byte of the member has reached it. -/
def Reader : Type := ReaderPointed.type

instance : Nonempty Reader := ReaderPointed.property

@[extern "litedoc4_gzip_reader_new"]
private opaque Reader.new (memberBytes : USize) : BaseIO Reader

private structure Pulled where
  dest : ByteArray
  pos : Nat
  outcome : Except Refusal Nat
  deriving Inhabited

@[extern "litedoc4_gzip_reader_pull"]
private opaque Reader.pull (r : @& Reader) (input : @& ByteArray) (pos : USize) (dest : ByteArray)
  (want : USize) (toLineEnd : Bool) : BaseIO Pulled

inductive Piece where
  | whole (bytes : ByteArray)
  | last (bytes : ByteArray)

def clampedUSize (n : Nat) : USize :=
  if n < USize.size then n.toUSize else USize.ofNat (USize.size - 1)

/-- A member whose bytes `next` hands over a chunk at a time. -/
structure Inflow where
  private reader : Reader
  private next : IO ByteArray
  private input : IO.Ref (ByteArray × Nat)

def Inflow.new (memberBytes : Nat) (next : IO ByteArray) : IO Inflow := do
  return { reader := ← Reader.new (clampedUSize memberBytes), next, input := ← IO.mkRef (.empty, 0) }

/-- `want` bytes, or the bytes up to a line end and without it, as `whole`;
`last` when the member ended first. -/
partial def Inflow.pull (f : Inflow) (want : Nat) (toLineEnd : Bool) :
    IO (Except Refusal Piece) := do
  let (input, pos) ← f.input.get
  let rec go (input : ByteArray) (pos : Nat) (dest : ByteArray) : IO (Except Refusal Piece) := do
    let ⟨dest, pos, outcome⟩ ← f.reader.pull input pos.toUSize dest (clampedUSize want) toLineEnd
    if outcome matches .ok 0 then
      let more ← f.next
      if !more.isEmpty then return ← go more 0 dest
    f.input.set (input, pos)
    return match outcome with
      | .ok 0 => .error .truncatedDeflate
      | .ok 1 => .ok (.whole dest)
      | .ok _ => .ok (.last dest)
      | .error why => .error why
  go input pos .empty

end Gzip
end Litedoc4
