/- `crates/litedoc4-global/src/search_index.rs`: `search-index.bin`, every
declaration the package documents, as bytes.

The decoder is here and not in `src/`: the real reader is the site's own
TypeScript, and a second one in the product would be a second thing to keep in
step. It is not what decides the format — it is the other direction of one, which
is the only way an encoder with no reader beside it can be asked whether the
bytes it wrote mean what it meant.

One corpus wherever a guard needs a whole package, so that "which shapes were
reached" is one question with one answer —
`theCorpusTheseGuardsUseReachesEveryShapeTheFormatHas` is that answer, and it
fails when a shape leaves the corpus rather than when a guard silently stops
exercising one. The two guards that are about a *section* rather than about the
names take their own two-entry inputs, because a section is read by its offset
and a corpus would only move that offset further away. -/
import Litedoc4.Global.SearchIndex
import Litedoc4.Ir.Utf16

namespace Litedoc4Test
open Litedoc4

def byteOf (b : ByteArray) (i : Nat) : Nat :=
  if i < b.size then (b.get! i).toNat else 0

def u16At (b : ByteArray) (i : Nat) : Nat := byteOf b i + byteOf b (i + 1) * 0x100

def u32At (b : ByteArray) (i : Nat) : Nat :=
  byteOf b i + byteOf b (i + 1) * 0x100 + byteOf b (i + 2) * 0x10000
    + byteOf b (i + 3) * 0x1000000

structure DecodedIndex where
  names : Array String := #[]
  labels : Array String := #[]
  kindOf : Array Nat := #[]
  modules : Array Nat := #[]
  deriving Inhabited

/-- `none` when the bytes are not a v2 index. Every read is bounds-checked
through `byteOf`, so a truncated file decodes to something wrong rather than
taking the process down — the callers here are asking whether a file is
well formed. -/
def decodeSearchIndex (b : ByteArray) : Option DecodedIndex := Id.run do
  if byteOf b 0 != 76 || byteOf b 1 != 68 || byteOf b 2 != 52 || byteOf b 3 != 83 then
    return none
  if u32At b 4 != searchVersion then return none
  let count := u32At b 8
  let namesOff := u32At b 16
  let labelsOff := u32At b 28
  let kindOfOff := u32At b 36
  let moduleOff := u32At b 40
  let mut names : Array String := Array.mkEmpty count
  let mut pos := namesOff
  let mut previous : ByteArray := ByteArray.empty
  for _ in [0:count] do
    let shared := byteOf b pos
    pos := pos + 1
    let mut len := byteOf b pos
    if len == searchLongSuffix then
      len := u16At b (pos + 1)
      pos := pos + 3
    else
      pos := pos + 1
    if shared > previous.size then return none
    let name := previous.extract 0 shared ++ b.extract pos (pos + len)
    pos := pos + len
    previous := name
    let some text := String.fromUTF8? name | return none
    names := names.push text
  let labelCount := u32At b labelsOff
  let mut labels : Array String := Array.mkEmpty labelCount
  let mut la := labelsOff + 4
  for _ in [0:labelCount] do
    let len := byteOf b la
    let some text := String.fromUTF8? (b.extract (la + 1) (la + 1 + len)) | return none
    labels := labels.push text
    la := la + 1 + len
  return some {
    names, labels
    kindOf := (Array.range count).map fun i => byteOf b (kindOfOff + i)
    modules := (Array.range count).map fun i => u16At b (moduleOff + i * 2) }

/-- The corpus the site's TypeScript decoder is tested against, name for name.
Every entry is here for something a reader can get wrong; which ones is
`theCorpusTheseGuardsUseReachesEveryShapeTheFormatHas` below.

Transcribed from `crates/litedoc4-global/tests/web_fixture.rs`, and what this
encoder makes of it **is** the committed fixture — 761 B, identical (measured
2026-08-31 → `benchmarks/results/lean-global-oracles-2026-08-31.txt`). That test
is the fixture's only writer and it goes with `crates/`. -/
def searchCases : Array (String × Nat × Nat) := #[
  ("NoDot", 0, 0),
  ("Pkg.a", 0, 1),
  ("Pkg.alpha", 1, 1),
  ("Pkg.alphabet", 1, 2),
  ("Pkg.b", 0, 2),
  ("Pkg.block.n00", 0, 3),
  ("Pkg.block.n01", 0, 3),
  ("Pkg.block.n02", 0, 3),
  ("Pkg.block.n03", 0, 3),
  ("Pkg.block.n04", 0, 3),
  ("Pkg.block.n05", 0, 3),
  ("Pkg.block.n06", 0, 3),
  ("Pkg.block.n07", 0, 3),
  ("Pkg.block.n08", 0, 3),
  ("Pkg.block.n09", 0, 3),
  ("Pkg.block.n10", 1, 3),
  ("Pkg.block.n11", 1, 3),
  ("Pkg.block.n12", 1, 3),
  ("Pkg.block.n13", 1, 3),
  ("Pkg.block.n14", 1, 3),
  ("Pkg.block.n15", 1, 3),
  ("Pkg.block.n16", 1, 3),
  ("Pkg.block.n17", 1, 3),
  ("Pkg.block.n18", 1, 3),
  ("Pkg.block.n19", 1, 3),
  ("Pkg.Nested.deep.name", 2, 4),
  ("Pkg.script𝒜", 2, 4),
  ("Pkg.\u0393amma", 3, 5),
  ("Pkg.\u03B2eta", 3, 5)]

def searchKinds : Array String := #["def", "theorem", "structure", "instance"]

/-- Past 254 bytes, where the one-byte suffix length escapes to a u16. -/
def longSearchName : String := "Pkg." ++ String.ofList (List.replicate 400 'x')

def searchCorpus : Array SearchEntry :=
  (searchCases.map fun (name, kind, module) => { name, kind, module }).push
    { name := longSearchName, kind := 0, module := 5 }

def searchCorpusBytes : ByteArray := searchIndex searchCorpus searchKinds

/-- The four parallel arrays come back as they went in. The long name is in the
corpus, so this is also where the escaped suffix length is read back. -/
def theCorpusRoundTripsThroughTheDecoder : Bool :=
  match decodeSearchIndex searchCorpusBytes with
  | none => false
  | some d =>
    d.names == searchCorpus.map (·.name)
      && d.labels == searchKinds
      && d.kindOf == searchCorpus.map (·.kind)
      && d.modules == searchCorpus.map (·.module)

#guard theCorpusRoundTripsThroughTheDecoder

/-- A guard is only as strong as what it was handed, so what the corpus reaches
is stated rather than believed: a name that crosses a restart block, one above
the BMP, one ASCII folding is wrong for, one past the one-byte suffix length,
and one with no components at all. -/
def theCorpusTheseGuardsUseReachesEveryShapeTheFormatHas : Bool :=
  let names := searchCorpus.map (·.name)
  searchCorpus.size > searchRestart + 1
    && names.any (fun n => n.any fun (c : Char) => c.val > 0xFFFF)
    && names.any (fun n => toLowercase n != asciiFold n)
    && names.any (fun n => n.utf8ByteSize > 254)
    && names.any fun n => !(n.any fun (c : Char) => c == '.')

#guard theCorpusTheseGuardsUseReachesEveryShapeTheFormatHas

/-- The first name of the second block shares a long prefix with the last of the
first, and still has to be written out whole: the reader starts a block from
nothing, so a shared count carried across one would rebuild the name from a
prefix it never read. -/
def everyRestartBlockStandsAlone : Bool :=
  let b := searchCorpusBytes
  let namesOff := u32At b 16
  let restartsOff := u32At b 24
  let secondBlock := u32At b (restartsOff + 4)
  searchCorpus.size > searchRestart
    && searchCorpus[searchRestart]!.name.take 12 == searchCorpus[searchRestart - 1]!.name.take 12
    && searchCorpus[searchRestart]!.name != searchCorpus[searchRestart - 1]!.name
    && byteOf b (namesOff + secondBlock) == 0

#guard everyRestartBlockStandsAlone

/-- Both directions, because a fold section that is always empty and one that
always fills would each pass one of them. -/
def onlyTheNamesAsciiFoldingIsWrongForAreCarried : Bool :=
  let ascii := searchIndex #[{ name := "Pkg.Abc", kind := 0, module := 0 },
                             { name := "Pkg.dEF", kind := 0, module := 0 }] #["def"]
  let greek := searchIndex #[{ name := "Pkg.Γamma", kind := 0, module := 0 }] #["def"]
  let foldOff := u32At greek 44
  u32At ascii (u32At ascii 44) == 0
    && u32At greek foldOff == 1
    && u32At greek (foldOff + 4) == 0
    && String.fromUTF8? (greek.extract (foldOff + 10)
        (foldOff + 10 + u16At greek (foldOff + 8))) == some "pkg.γamma"

#guard onlyTheNamesAsciiFoldingIsWrongForAreCarried

/-- A package with nothing in it still writes a file with a header: `app.js`
fetches this unconditionally, and a zero-length response is a parse error where
an empty index is an answer. -/
def anEmptyPackageIsStillAFile : Bool :=
  let b := searchIndex #[] #[]
  byteOf b 0 == 76 && byteOf b 1 == 68 && byteOf b 2 == 52 && byteOf b 3 == 83
    && b.size > searchHeaderBytes
    && (match decodeSearchIndex b with
        | none => false
        | some d => d.names.isEmpty && d.labels.isEmpty)

#guard anEmptyPackageIsStillAFile

end Litedoc4Test
