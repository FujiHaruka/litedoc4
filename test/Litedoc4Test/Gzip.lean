/- The gzip members a version store keeps, and the refusals it reads them back
with. Every one of these calls the C in `csrc/gzip.c`, so all of it runs.

The two members Python's zlib wrote are bytes from an implementation nobody here
wrote, pinned as literals so that nothing in this tree can re-mint them. -/
import Litedoc4.Gzip
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4

def xorshiftBytes (n : Nat) : ByteArray := Id.run do
  let mut x : UInt32 := 2463534242
  let mut out := ByteArray.emptyWithCapacity n
  for _ in [0:n] do
    x := x ^^^ (x <<< 13)
    x := x ^^^ (x >>> 17)
    x := x ^^^ (x <<< 5)
    out := out.push x.toUInt8
  return out

def repeatedText (n : Nat) (line : String) : ByteArray := Id.run do
  let one := line.toUTF8
  let mut out := ByteArray.emptyWithCapacity (n * one.size)
  for _ in [0:n] do out := out ++ one
  return out

def storeSentence : ByteArray := repeatedText 3 "litedoc4 stores each version's IR compressed.\n"

def gzipInputs : List (String × ByteArray) := [
  ("empty", .empty),
  ("one byte", ⟨#[0]⟩),
  ("a sentence three times", storeSentence),
  ("a megabyte of text", repeatedText 21846 "theorem foo (n : Nat) : n + 0 = n := rfl\n"),
  ("a megabyte of incompressible bytes", xorshiftBytes 1048576),
  ("text then noise", repeatedText 2000 "def x := 1\n" ++ xorshiftBytes 70000)]

def gzipLevels : List UInt8 := [0, 1, 6, 9, 10]

def differenceBetween (got expected : ByteArray) : Option String :=
  if got == expected then none
  else
    let firstDiff := (List.range (min got.size expected.size)).find? (fun i => got[i]! != expected[i]!)
    some s!"{got.size} bytes against {expected.size}, first difference at {firstDiff.getD (min got.size expected.size)}"

def roundTrips (label : String) (level : UInt8) (input : ByteArray) : Option String :=
  match Gzip.decompress (Gzip.compress level input) with
  | .ok back => (differenceBetween back input).map (s!"{label} at level {level}: " ++ ·)
  | .error e => some s!"{label} at level {level}: refused its own member: {e}"

def aMemberRoundTripsAtEveryLevel : Invariant where
  name := "every input comes back byte for byte at every level, and a level above 10 is 10"
  check := return first <|
    (gzipInputs.flatMap fun (label, input) => gzipLevels.map (roundTrips label · input)) ++
    [eq (Gzip.compress 255 storeSentence).toList (Gzip.compress 10 storeSentence).toList]

def gzipFixedHeader : List UInt8 := [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]

def le32 (b : ByteArray) (at_ : Nat) : Nat :=
  b[at_]!.toNat ||| (b[at_ + 1]!.toNat <<< 8) ||| (b[at_ + 2]!.toNat <<< 16) ||| (b[at_ + 3]!.toNat <<< 24)

def theHeaderIsFixedAndTheTrailerCountsTheInput : Invariant where
  name := "the header is 1f 8b, deflate, no flags, mtime 0, XFL 0, OS 255, and the trailer ends with the length"
  check := return first <| gzipInputs.flatMap fun (label, input) => gzipLevels.map fun level =>
    let member := Gzip.compress level input
    (eq ((member.extract 0 10).toList, le32 member (member.size - 4))
      (gzipFixedHeader, input.size % 2 ^ 32)).map (s!"{label} at level {level}: " ++ ·)

def compressingTwiceGivesTheSameBytes : Invariant where
  name := "compressing the same input twice gives the same bytes"
  check := return first <| gzipInputs.map fun (label, input) =>
    -- A copy and not `input` twice: the compiler merges two identical pure calls into one.
    let again := input.extract 0 input.size
    (differenceBetween (Gzip.compress 6 input) (Gzip.compress 6 again)).map (s!"{label}: " ++ ·)

/-- miniz 3.1.2 at level 6 over `storeSentence`, accepted by Python's
`gzip.decompress` before it was pinned. A different deflate, or the same one
configured differently, changes these bytes before it changes any size the store
reports. -/
def pinnedMinizMember : List UInt8 := [
  0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xb5, 0xca, 0xb1, 0x0d, 0x80, 0x20,
  0x14, 0x04, 0xd0, 0xde, 0x29, 0xae, 0xb3, 0xb3, 0x72, 0x09, 0x5b, 0x37, 0x30, 0x9f, 0x4b, 0x24,
  0x01, 0x3e, 0xe1, 0x08, 0xf3, 0xc3, 0x12, 0xd4, 0xef, 0xa5, 0xd8, 0x19, 0xdc, 0x6e, 0xa8, 0x7b,
  0xa3, 0xc0, 0xcf, 0x7e, 0x0c, 0x36, 0x45, 0x2f, 0xa7, 0xf0, 0xbc, 0x30, 0xcf, 0x75, 0x89, 0x18,
  0xae, 0x23, 0x6d, 0xdc, 0x13, 0x62, 0x91, 0xc9, 0x7b, 0x8a, 0x00, 0x00, 0x00]

def aFixedInputCompressesToThePinnedBytes : Invariant where
  name := "a fixed input compresses to the bytes pinned for miniz 3.1.2 at level 6"
  check := return eq (Gzip.compress 6 storeSentence).toList pinnedMinizMember

/-- `gzip.compress(storeSentence, 6, mtime=0)`, Python 3's zlib. -/
def pythonMember : ByteArray := ⟨#[
  0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xcb, 0xc9, 0x2c, 0x49, 0x4d, 0xc9,
  0x4f, 0x36, 0x51, 0x28, 0x2e, 0xc9, 0x2f, 0x4a, 0x2d, 0x56, 0x48, 0x4d, 0x4c, 0xce, 0x50, 0x28,
  0x4b, 0x2d, 0x2a, 0xce, 0xcc, 0xcf, 0x53, 0x2f, 0x56, 0xf0, 0x0c, 0x52, 0x48, 0xce, 0xcf, 0x2d,
  0x00, 0xca, 0x14, 0xa7, 0xa6, 0xe8, 0x71, 0xe5, 0xd0, 0x50, 0x35, 0x00, 0x62, 0x91, 0xc9, 0x7b,
  0x8a, 0x00, 0x00, 0x00]⟩

/-- The same deflate body behind a header carrying every optional field: FEXTRA
(`ab 01 00`), FNAME `ir.json`, FCOMMENT `a comment` and FHCRC, with OS 3. -/
def pythonMemberWithEveryField : ByteArray := ⟨#[
  0x1f, 0x8b, 0x08, 0x1e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x04, 0x00, 0x61, 0x62, 0x01, 0x00,
  0x69, 0x72, 0x2e, 0x6a, 0x73, 0x6f, 0x6e, 0x00, 0x61, 0x20, 0x63, 0x6f, 0x6d, 0x6d, 0x65, 0x6e,
  0x74, 0x00, 0xf2, 0xc4, 0xcb, 0xc9, 0x2c, 0x49, 0x4d, 0xc9, 0x4f, 0x36, 0x51, 0x28, 0x2e, 0xc9,
  0x2f, 0x4a, 0x2d, 0x56, 0x48, 0x4d, 0x4c, 0xce, 0x50, 0x28, 0x4b, 0x2d, 0x2a, 0xce, 0xcc, 0xcf,
  0x53, 0x2f, 0x56, 0xf0, 0x0c, 0x52, 0x48, 0xce, 0xcf, 0x2d, 0x00, 0xca, 0x14, 0xa7, 0xa6, 0xe8,
  0x71, 0xe5, 0xd0, 0x50, 0x35, 0x00, 0x62, 0x91, 0xc9, 0x7b, 0x8a, 0x00, 0x00, 0x00]⟩

def decodesTo (label : String) (member expected : ByteArray) : Option String :=
  match Gzip.decompress member with
  | .ok back => (differenceBetween back expected).map (s!"{label}: " ++ ·)
  | .error e => some s!"{label}: refused: {e}"

def membersPythonsZlibWroteDecodeToTheirInput : Invariant where
  name := "members Python's zlib wrote, with and without every optional header field, decode to their input"
  check := return first [
    decodesTo "no optional fields" pythonMember storeSentence,
    decodesTo "every optional field" pythonMemberWithEveryField storeSentence]

def isRefused : Except String ByteArray → Bool
  | .error _ => true
  | .ok _ => false

def prefixesAndATrailingByteRefused (member : ByteArray) : List (Option String) :=
  let prefixes := (List.range member.size).map fun cut =>
    if isRefused (Gzip.decompress (member.extract 0 cut)) then none
    else some s!"the first {cut} of {member.size} bytes were accepted"
  let trailing := if isRefused (Gzip.decompress (member.push 0)) then none
    else some s!"a {member.size}-byte member with a byte after it was accepted"
  prefixes ++ [trailing]

def membersToCut : List ByteArray :=
  [pythonMember, Gzip.compress 6 storeSentence, Gzip.compress 0 storeSentence]

def everyProperPrefixAndAnyTrailingByteIsRefused : Invariant where
  name := "every proper prefix of a member is refused, and so is a member with a byte after it"
  check := return first <| membersToCut.flatMap prefixesAndATrailingByteRefused

def flipBit (b : ByteArray) (bit : Nat) : ByteArray :=
  b.set! (bit / 8) (b[bit / 8]! ^^^ ((1 : UInt8) <<< (bit % 8).toUInt8))

/-- The bits gzip leaves to the reader's discretion are FTEXT, MTIME, XFL and OS,
and the pad bits that end the deflate stream; everything else is checked. -/
def aBitTheFormatChecks (memberSize bit : Nat) : Bool :=
  let byte := bit / 8
  byte < 3 || (byte == 3 && bit % 8 != 0) || byte ≥ memberSize - 8

def flipsThatChangeTheAnswer (member : ByteArray) : List (Option String) :=
  let original := Gzip.decompress member
  (List.range (member.size * 8)).map fun bit =>
    match Gzip.decompress (flipBit member bit), original with
    | .error _, _ => none
    | .ok got, .ok want =>
      if got != want then some s!"flipping bit {bit} of {member.size} decoded to other bytes"
      else if aBitTheFormatChecks member.size bit then
        some s!"flipping bit {bit} of {member.size}, in a checked field, was accepted"
      else none
    | .ok _, .error e => some s!"the unflipped member was refused: {e}"

def membersToFlip : List ByteArray :=
  [Gzip.compress 6 storeSentence, Gzip.compress 6 (repeatedText 40 "x := y\n" ++ xorshiftBytes 300)]

def noSingleBitFlipDecodesToOtherBytes : Invariant where
  name := "no single-bit flip decodes to other bytes, and a flip in a checked field is refused"
  check := return first <| membersToFlip.flatMap flipsThatChangeTheAnswer

def withByte (b : ByteArray) (i : Nat) (v : UInt8) : ByteArray := b.set! i v

def withLe32 (b : ByteArray) (at_ : Nat) (v : Nat) : ByteArray :=
  (List.range 4).foldl (fun acc k => acc.set! (at_ + k) (v >>> (8 * k)).toUInt8) b

def refusedAs (label : String) (input : ByteArray) (why : Gzip.Refusal) : Option String :=
  match Gzip.decompress input with
  | .error e => (eq e why.message).map (s!"{label}: " ++ ·)
  | .ok _ => some s!"{label}: accepted, expected \"{why.message}\""

def malformedMembers : List (Option String) :=
  let m := pythonMember
  let n := m.size
  let header := m.extract 0 10
  let body := m.extract 10 (n - 8)
  let trailer := m.extract (n - 8) n
  [refusedAs "17 bytes" (m.extract 0 17) .shorterThanAMember,
   refusedAs "a zip signature" (withByte m 0 0x50) .notGzip,
   refusedAs "method 7" (withByte m 2 7) .notDeflate,
   refusedAs "flag bit 5" (withByte m 3 0x20) .reservedFlagSet,
   refusedAs "FNAME with no terminator" (withByte header 3 0x08 ++ "unterminated".toUTF8 ++ trailer)
     .headerRunsIntoTrailer,
   refusedAs "a wrong header CRC" (withByte pythonMemberWithEveryField 34 0) .headerChecksumMismatch,
   refusedAs "a length of 4 GiB - 1" (withLe32 m (n - 4) 0xffffffff) .trailerClaimsMoreThanDeflateCanHold,
   refusedAs "block type 3" (header ++ ⟨#[0x07]⟩ ++ trailer) .corruptDeflate,
   refusedAs "half a body" (header ++ body.extract 0 (body.size / 2) ++ trailer) .truncatedDeflate,
   refusedAs "a second trailer" (m ++ trailer) .bytesBetweenDeflateAndTrailer,
   refusedAs "a length one short" (withLe32 m (n - 4) (storeSentence.size - 1)) .longerThanItsTrailerSays,
   refusedAs "a length one long" (withLe32 m (n - 4) (storeSentence.size + 1)) .shorterThanItsTrailerSays,
   refusedAs "a CRC off by one" (withLe32 m (n - 8) (le32 m (n - 8) ^^^ 1)) .checksumMismatch]

def eachRefusalNamesWhatItFound : Invariant where
  name := "each malformed member is refused with the message for what is wrong with it"
  check := return first malformedMembers

end Litedoc4Test
