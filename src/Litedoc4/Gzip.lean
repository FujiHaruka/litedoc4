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

end Gzip
end Litedoc4
