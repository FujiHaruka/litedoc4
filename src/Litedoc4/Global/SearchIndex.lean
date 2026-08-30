/- `crates/litedoc4-global/src/search_index.rs`: `search-index.bin`, every
declaration the package documents, as bytes.

  0   magic "LD4S"        4 bytes
  4   version             u32 = 2
  8   count               u32   declarations
  12  restart             u32   restart interval of the name section
  16  names_off/len       u32 u32
  24  restarts_off        u32   ceil(count / restart) entries of u32
  28  kind_labels_off/len u32 u32
  36  kind_of_off         u32   count bytes, one kind subscript each
  40  module_off          u32   count entries of u16
  44  fold_off/len        u32 u32

All integers are little-endian and unaligned-safe: the reader assembles them
byte by byte, so no section needs padding and no platform needs to agree about
alignment. -/
import Litedoc4.Bytes
import Litedoc4.Lower

namespace Litedoc4

structure SearchEntry where
  name : String
  /-- Subscript into the kind labels. -/
  kind : Nat
  /-- Subscript into `modules.json`'s array — **not** into anything here. -/
  module : Nat
  deriving Inhabited

/-- Bumped when a reader that does not know the change would be wrong. -/
def searchVersion : Nat := 2

/-- Declarations between full names in the name section. -/
def searchRestart : Nat := 16

/-- Everything before the first section. -/
def searchHeaderBytes : Nat := 52

/-- A suffix length of this value means the real length follows as a u16. -/
def searchLongSuffix : Nat := 255

def putU32 (b : ByteArray) (v : Nat) : ByteArray :=
  let v := v.toUInt32
  (((b.push v.toUInt8).push (v >>> 8).toUInt8).push (v >>> 16).toUInt8).push (v >>> 24).toUInt8

def putU16 (b : ByteArray) (v : Nat) : ByteArray :=
  let v := v.toUInt16
  (b.push v.toUInt8).push (v >>> 8).toUInt8

def putLen (b : ByteArray) (len : Nat) : ByteArray :=
  if len ≥ searchLongSuffix then putU16 (b.push searchLongSuffix.toUInt8) len
  else b.push len.toUInt8

/-- The ASCII-only lowering the reader does, which `Char.toLower` already is. -/
def asciiFold (s : String) : String := s.map Char.toLower

/-- `entries` must already be in the order the site wants them ranked in;
nothing here sorts. `kinds` are the badge labels the subscripts point at. -/
def searchIndex (entries : Array SearchEntry) (kinds : Array String) : ByteArray := Id.run do
  let mut names : ByteArray := ByteArray.emptyWithCapacity (entries.size * 24)
  let mut restarts : ByteArray := ByteArray.emptyWithCapacity (entries.size / searchRestart * 4 + 4)
  let mut folds : ByteArray := ByteArray.empty
  let mut foldCount : Nat := 0
  let mut previous : String := ""
  for i in [0:entries.size] do
    let entry := entries[i]!
    let name := entry.name
    let len := name.utf8ByteSize
    if i % searchRestart == 0 then
      restarts := putU32 restarts names.size
      previous := ""
    let previousLen := previous.utf8ByteSize
    let mut shared := 0
    -- Capped rather than escaped the way the suffix length below is: a shared
    -- prefix cut short only costs compression, while a suffix cut short would
    -- be a name the search disagrees with its own page about.
    while shared < previousLen && shared < len && shared < 254
        && byteAt previous shared == byteAt name shared do
      shared := shared + 1
    names := names.push shared.toUInt8
    names := putLen names (len - shared)
    for j in [shared:len] do
      names := names.push (byteAt name j)
    previous := name
    let lowered := toLowercase name
    if lowered != asciiFold name then
      foldCount := foldCount + 1
      folds := putU32 folds i
      folds := putU16 folds lowered.utf8ByteSize
      folds := folds ++ lowered.toUTF8

  let mut labels : ByteArray := putU32 ByteArray.empty kinds.size
  for kind in kinds do
    labels := labels.push kind.utf8ByteSize.toUInt8
    labels := labels ++ kind.toUTF8
  let mut kindOf : ByteArray := ByteArray.emptyWithCapacity entries.size
  for entry in entries do
    kindOf := kindOf.push entry.kind.toUInt8
  let mut modules : ByteArray := ByteArray.emptyWithCapacity (entries.size * 2)
  for entry in entries do
    modules := putU16 modules entry.module

  let namesOff := searchHeaderBytes
  let restartsOff := namesOff + names.size
  let labelsOff := restartsOff + restarts.size
  let kindOfOff := labelsOff + labels.size
  let moduleOff := kindOfOff + kindOf.size
  let foldOff := moduleOff + modules.size

  let mut out : ByteArray := ByteArray.emptyWithCapacity (foldOff + folds.size + 4)
  out := out ++ "LD4S".toUTF8
  out := putU32 out searchVersion
  out := putU32 out entries.size
  out := putU32 out searchRestart
  for value in [namesOff, names.size, restartsOff, labelsOff, labels.size, kindOfOff,
      moduleOff, foldOff] do
    out := putU32 out value
  out := putU32 out (4 + folds.size)
  out := ((((out ++ names) ++ restarts) ++ labels) ++ kindOf) ++ modules
  out := putU32 out foldCount
  return out ++ folds

end Litedoc4
