/-
The two tables hold the answers of Rust's `str::to_lowercase`, enumerated code
point by code point rather than copied from its sources.

    Copyright © The Rust Project Developers
    Licensed under MIT OR Apache-2.0.

The character data it answers from is Unicode's `UnicodeData.txt` /
`SpecialCasing.txt` / `DerivedCoreProperties.txt`:

    Copyright © 1991-2025 Unicode®, Inc. All rights reserved.
    Distributed under the Unicode® Copyright and Terms of Use,
    https://www.unicode.org/copyright.html
-/
import Litedoc4.Bytes

namespace Litedoc4

@[inline] def hexValue (b : UInt8) : UInt32 :=
  if b ≤ 57 then b.toUInt32 - 48 else b.toUInt32 - 55

/-- Lowercase mappings as `lo:d`, `lo-hi:d` (every code point of the run) or
`lo~hi:d` (every second one), hex, in code point order, with `d` the signed
amount added to each. A string literal rather than an array literal because 185
array elements are elaborated one by one and a string is one token.

**Frozen: this table and `sigmaTable` have no generator and no oracle.** The
obvious move — a `tools/oracle/` script that re-derives them the way
`Litedoc4.Global.V8GcTable` is re-derived — has nothing to ask. What enumerated
them was Rust's `str::to_lowercase`, which is not in this tree, and V8
is not a stand-in for it: asked for every code point, V8 and this table disagree
on 28, all in the same direction (U+A7CE, U+A7D2, U+A7D4, and U+16EA0..U+16EB9),
this table lowercasing what V8 leaves alone, because Rust's character data
carries assignments deno's V8 does not (measured 2026-08-31 →
`benchmarks/results/unicode-table-regenerators-2026-08-31.txt` §4). Taking V8
anyway would make the answer move with the deno version.

The condition that falsifies this: vendoring the UCD files the table derives
from (`UnicodeData.txt`, `SpecialCasing.txt`, `DerivedCoreProperties.txt`), or
any oracle pinned to the same Unicode version. Either one makes both tables
re-derivable and this note wrong. -/
def lowerTable : String :=
  "41-5A:20,C0-D6:20,D8-DE:20,100~12E:1,132~136:1,139~147:1,14A~176:1,178:-79,179~17D:1,181:D2,182~184:1,186:CE,187:1,189-18A:CD,18B:1,18E:4F,18F:CA,190:CB,191:1,193:CD,194:CF,196:D3,197:D1,198:1,19C:D3,19D:D5,19F:D6,1A0~1A4:1,1A6:DA,1A7:1,1A9:DA,1AC:1,1AE:DA,1AF:1,1B1-1B2:D9,1B3~1B5:1,1B7:DB,1B8:1,1BC:1,1C4:2,1C5:1,1C7:2,1C8:1,1CA:2,1CB~1DB:1,1DE~1EE:1,1F1:2,1F2~1F4:1,1F6:-61,1F7:-38,1F8~21E:1,220:-82,222~232:1,23A:2A2B,23B:1,23D:-A3,23E:2A28,241:1,243:-C3,244:45,245:47,246~24E:1,370~372:1,376:1,37F:74,386:26,388-38A:25,38C:40,38E-38F:3F,391-3A1:20,3A3-3AB:20,3CF:8,3D8~3EE:1,3F4:-3C,3F7:1,3F9:-7,3FA:1,3FD-3FF:-82,400-40F:50,410-42F:20,460~480:1,48A~4BE:1,4C0:F,4C1~4CD:1,4D0~52E:1,531-556:30,10A0-10C5:1C60,10C7:1C60,10CD:1C60,13A0-13EF:97D0,13F0-13F5:8,1C89:1,1C90-1CBA:-BC0,1CBD-1CBF:-BC0,1E00~1E94:1,1E9E:-1DBF,1EA0~1EFE:1,1F08-1F0F:-8,1F18-1F1D:-8,1F28-1F2F:-8,1F38-1F3F:-8,1F48-1F4D:-8,1F59~1F5F:-8,1F68-1F6F:-8,1F88-1F8F:-8,1F98-1F9F:-8,1FA8-1FAF:-8,1FB8-1FB9:-8,1FBA-1FBB:-4A,1FBC:-9,1FC8-1FCB:-56,1FCC:-9,1FD8-1FD9:-8,1FDA-1FDB:-64,1FE8-1FE9:-8,1FEA-1FEB:-70,1FEC:-7,1FF8-1FF9:-80,1FFA-1FFB:-7E,1FFC:-9,2126:-1D5D,212A:-20BF,212B:-2046,2132:1C,2160-216F:10,2183:1,24B6-24CF:1A,2C00-2C2F:30,2C60:1,2C62:-29F7,2C63:-EE6,2C64:-29E7,2C67~2C6B:1,2C6D:-2A1C,2C6E:-29FD,2C6F:-2A1F,2C70:-2A1E,2C72:1,2C75:1,2C7E-2C7F:-2A3F,2C80~2CE2:1,2CEB~2CED:1,2CF2:1,A640~A66C:1,A680~A69A:1,A722~A72E:1,A732~A76E:1,A779~A77B:1,A77D:-8A04,A77E~A786:1,A78B:1,A78D:-A528,A790~A792:1,A796~A7A8:1,A7AA:-A544,A7AB:-A54F,A7AC:-A54B,A7AD:-A541,A7AE:-A544,A7B0:-A512,A7B1:-A52A,A7B2:-A515,A7B3:3A0,A7B4~A7C2:1,A7C4:-30,A7C5:-A543,A7C6:-8A38,A7C7~A7C9:1,A7CB:-A567,A7CC~A7DA:1,A7DC:-A641,A7F5:1,FF21-FF3A:20,10400-10427:28,104B0-104D3:28,10570-1057A:27,1057C-1058A:27,1058C-10592:27,10594-10595:27,10C80-10CB2:40,10D50-10D65:20,118A0-118BF:20,16E40-16E5F:20,16EA0-16EB8:1B,1E900-1E921:22"

/-- `(lo, hi, stride, delta)`, sorted and non-overlapping. -/
def lowerRuns : Array (UInt32 × UInt32 × UInt32 × UInt32) := Id.run do
  let s := lowerTable
  let n := s.utf8ByteSize
  let mut out : Array (UInt32 × UInt32 × UInt32 × UInt32) := Array.mkEmpty 200
  let mut cur : UInt32 := 0
  let mut lo : UInt32 := 0
  let mut hi : UInt32 := 0
  let mut stride : UInt32 := 1
  let mut hasHi := false
  let mut inDelta := false
  let mut neg := false
  let mut i := 0
  while i ≤ n do
    let b := if i < n then byteAt s i else 44
    if b == 44 then
      out := out.push (lo, if hasHi then hi else lo, stride, if neg then 0 - cur else cur)
      cur := 0; lo := 0; hi := 0; stride := 1; hasHi := false; inDelta := false; neg := false
    else if b == 58 then
      if hasHi then hi := cur else lo := cur
      cur := 0
      inDelta := true
    else if b == 45 && inDelta then
      neg := true
    else if b == 45 || b == 126 then
      lo := cur
      cur := 0
      hasHi := true
      stride := if b == 45 then 1 else 2
    else
      cur := cur * 16 + hexValue b
    i := i + 1
  return out

def lowerOf (cp : UInt32) : UInt32 := Id.run do
  let rs := lowerRuns
  let mut lo := 0
  let mut hi := rs.size
  while lo < hi do
    let mid := (lo + hi) / 2
    let (a, b, stride, delta) := rs[mid]!
    if cp < a then hi := mid
    else if cp > b then lo := mid + 1
    else if stride == 2 && (cp - a) % 2 == 1 then return cp
    else return cp + delta
  return cp

/-- The two code point sets `Final_Sigma` is stated in, as `lo` or `lo-hi` runs:
`i` is `Case_Ignorable`, `c` is cased and not case-ignorable, and a code point in
neither ends the scan without being cased.

Frozen for the reason stated at `lowerTable`, which is where the whole judgement
is kept: this table is `DerivedCoreProperties.txt`'s half of the same UCD and has
the same missing oracle. -/
def sigmaTable : String :=
  "27i,2Ei,3Ai,41-5Ac,5Ei,60i,61-7Ac,A8i,AAc,ADi,AFi,B4i,B5c,B7-B8i,BAc,C0-D6c,D8-F6c,F8-1BAc,1BC-1BFc,1C4-293c,296-2AFc,2B0-36Fi,370-373c,374-375i,376-377c,37Ai,37B-37Dc,37Fc,384-385i,386c,387i,388-38Ac,38Cc,38E-3A1c,3A3-3F5c,3F7-481c,483-489i,48A-52Fc,531-556c,559i,55Fi,560-588c,591-5BDi,5BFi,5C1-5C2i,5C4-5C5i,5C7i,5F4i,600-605i,610-61Ai,61Ci,640i,64B-65Fi,670i,6D6-6DDi,6DF-6E8i,6EA-6EDi,70Fi,711i,730-74Ai,7A6-7B0i,7EB-7F5i,7FAi,7FDi,816-82Di,859-85Bi,888i,890-891i,897-89Fi,8C9-902i,93Ai,93Ci,941-948i,94Di,951-957i,962-963i,971i,981i,9BCi,9C1-9C4i,9CDi,9E2-9E3i,9FEi,A01-A02i,A3Ci,A41-A42i,A47-A48i,A4B-A4Di,A51i,A70-A71i,A75i,A81-A82i,ABCi,AC1-AC5i,AC7-AC8i,ACDi,AE2-AE3i,AFA-AFFi,B01i,B3Ci,B3Fi,B41-B44i,B4Di,B55-B56i,B62-B63i,B82i,BC0i,BCDi,C00i,C04i,C3Ci,C3E-C40i,C46-C48i,C4A-C4Di,C55-C56i,C62-C63i,C81i,CBCi,CBFi,CC6i,CCC-CCDi,CE2-CE3i,D00-D01i,D3B-D3Ci,D41-D44i,D4Di,D62-D63i,D81i,DCAi,DD2-DD4i,DD6i,E31i,E34-E3Ai,E46-E4Ei,EB1i,EB4-EBCi,EC6i,EC8-ECEi,F18-F19i,F35i,F37i,F39i,F71-F7Ei,F80-F84i,F86-F87i,F8D-F97i,F99-FBCi,FC6i,102D-1030i,1032-1037i,1039-103Ai,103D-103Ei,1058-1059i,105E-1060i,1071-1074i,1082i,1085-1086i,108Di,109Di,10A0-10C5c,10C7c,10CDc,10D0-10FAc,10FCi,10FD-10FFc,135D-135Fi,13A0-13F5c,13F8-13FDc,1712-1714i,1732-1733i,1752-1753i,1772-1773i,17B4-17B5i,17B7-17BDi,17C6i,17C9-17D3i,17D7i,17DDi,180B-180Fi,1843i,1885-1886i,18A9i,1920-1922i,1927-1928i,1932i,1939-193Bi,1A17-1A18i,1A1Bi,1A56i,1A58-1A5Ei,1A60i,1A62i,1A65-1A6Ci,1A73-1A7Ci,1A7Fi,1AA7i,1AB0-1ADDi,1AE0-1AEBi,1B00-1B03i,1B34i,1B36-1B3Ai,1B3Ci,1B42i,1B6B-1B73i,1B80-1B81i,1BA2-1BA5i,1BA8-1BA9i,1BAB-1BADi,1BE6i,1BE8-1BE9i,1BEDi,1BEF-1BF1i,1C2C-1C33i,1C36-1C37i,1C78-1C7Di,1C80-1C8Ac,1C90-1CBAc,1CBD-1CBFc,1CD0-1CD2i,1CD4-1CE0i,1CE2-1CE8i,1CEDi,1CF4i,1CF8-1CF9i,1D00-1D2Bc,1D2C-1D6Ai,1D6B-1D77c,1D78i,1D79-1D9Ac,1D9B-1DFFi,1E00-1F15c,1F18-1F1Dc,1F20-1F45c,1F48-1F4Dc,1F50-1F57c,1F59c,1F5Bc,1F5Dc,1F5F-1F7Dc,1F80-1FB4c,1FB6-1FBCc,1FBDi,1FBEc,1FBF-1FC1i,1FC2-1FC4c,1FC6-1FCCc,1FCD-1FCFi,1FD0-1FD3c,1FD6-1FDBc,1FDD-1FDFi,1FE0-1FECc,1FED-1FEFi,1FF2-1FF4c,1FF6-1FFCc,1FFD-1FFEi,200B-200Fi,2018-2019i,2024i,2027i,202A-202Ei,2060-2064i,2066-206Fi,2071i,207Fi,2090-209Ci,20D0-20F0i,2102c,2107c,210A-2113c,2115c,2119-211Dc,2124c,2126c,2128c,212A-212Dc,212F-2134c,2139c,213C-213Fc,2145-2149c,214Ec,2160-217Fc,2183-2184c,24B6-24E9c,2C00-2C7Bc,2C7C-2C7Di,2C7E-2CE4c,2CEB-2CEEc,2CEF-2CF1i,2CF2-2CF3c,2D00-2D25c,2D27c,2D2Dc,2D6Fi,2D7Fi,2DE0-2DFFi,2E2Fi,3005i,302A-302Di,3031-3035i,303Bi,3099-309Ei,30FC-30FEi,A015i,A4F8-A4FDi,A60Ci,A640-A66Dc,A66F-A672i,A674-A67Di,A67Fi,A680-A69Bc,A69C-A69Fi,A6F0-A6F1i,A700-A721i,A722-A76Fc,A770i,A771-A787c,A788-A78Ai,A78B-A78Ec,A790-A7DCc,A7F1-A7F4i,A7F5-A7F6c,A7F8-A7F9i,A7FAc,A802i,A806i,A80Bi,A825-A826i,A82Ci,A8C4-A8C5i,A8E0-A8F1i,A8FFi,A926-A92Di,A947-A951i,A980-A982i,A9B3i,A9B6-A9B9i,A9BC-A9BDi,A9CFi,A9E5-A9E6i,AA29-AA2Ei,AA31-AA32i,AA35-AA36i,AA43i,AA4Ci,AA70i,AA7Ci,AAB0i,AAB2-AAB4i,AAB7-AAB8i,AABE-AABFi,AAC1i,AADDi,AAEC-AAEDi,AAF3-AAF4i,AAF6i,AB30-AB5Ac,AB5B-AB5Fi,AB60-AB68c,AB69-AB6Bi,AB70-ABBFc,ABE5i,ABE8i,ABEDi,FB00-FB06c,FB13-FB17c,FB1Ei,FBB2-FBC2i,FE00-FE0Fi,FE13i,FE20-FE2Fi,FE52i,FE55i,FEFFi,FF07i,FF0Ei,FF1Ai,FF21-FF3Ac,FF3Ei,FF40i,FF41-FF5Ac,FF70i,FF9E-FF9Fi,FFE3i,FFF9-FFFBi,101FDi,102E0i,10376-1037Ai,10400-1044Fc,104B0-104D3c,104D8-104FBc,10570-1057Ac,1057C-1058Ac,1058C-10592c,10594-10595c,10597-105A1c,105A3-105B1c,105B3-105B9c,105BB-105BCc,10780-10785i,10787-107B0i,107B2-107BAi,10A01-10A03i,10A05-10A06i,10A0C-10A0Fi,10A38-10A3Ai,10A3Fi,10AE5-10AE6i,10C80-10CB2c,10CC0-10CF2c,10D24-10D27i,10D4Ei,10D50-10D65c,10D69-10D6Di,10D6Fi,10D70-10D85c,10EAB-10EACi,10EC5i,10EFA-10EFFi,10F46-10F50i,10F82-10F85i,11001i,11038-11046i,11070i,11073-11074i,1107F-11081i,110B3-110B6i,110B9-110BAi,110BDi,110C2i,110CDi,11100-11102i,11127-1112Bi,1112D-11134i,11173i,11180-11181i,111B6-111BEi,111C9-111CCi,111CFi,1122F-11231i,11234i,11236-11237i,1123Ei,11241i,112DFi,112E3-112EAi,11300-11301i,1133B-1133Ci,11340i,11366-1136Ci,11370-11374i,113BB-113C0i,113CEi,113D0i,113D2i,113E1-113E2i,11438-1143Fi,11442-11444i,11446i,1145Ei,114B3-114B8i,114BAi,114BF-114C0i,114C2-114C3i,115B2-115B5i,115BC-115BDi,115BF-115C0i,115DC-115DDi,11633-1163Ai,1163Di,1163F-11640i,116ABi,116ADi,116B0-116B5i,116B7i,1171Di,1171Fi,11722-11725i,11727-1172Bi,1182F-11837i,11839-1183Ai,118A0-118DFc,1193B-1193Ci,1193Ei,11943i,119D4-119D7i,119DA-119DBi,119E0i,11A01-11A0Ai,11A33-11A38i,11A3B-11A3Ei,11A47i,11A51-11A56i,11A59-11A5Bi,11A8A-11A96i,11A98-11A99i,11B60i,11B62-11B64i,11B66i,11C30-11C36i,11C38-11C3Di,11C3Fi,11C92-11CA7i,11CAA-11CB0i,11CB2-11CB3i,11CB5-11CB6i,11D31-11D36i,11D3Ai,11D3C-11D3Di,11D3F-11D45i,11D47i,11D90-11D91i,11D95i,11D97i,11DD9i,11EF3-11EF4i,11F00-11F01i,11F36-11F3Ai,11F40i,11F42i,11F5Ai,13430-13440i,13447-13455i,1611E-16129i,1612D-1612Fi,16AF0-16AF4i,16B30-16B36i,16B40-16B43i,16D40-16D42i,16D6B-16D6Ci,16E40-16E7Fc,16EA0-16EB8c,16EBB-16ED3c,16F4Fi,16F8F-16F9Fi,16FE0-16FE1i,16FE3-16FE4i,16FF2-16FF3i,1AFF0-1AFF3i,1AFF5-1AFFBi,1AFFD-1AFFEi,1BC9D-1BC9Ei,1BCA0-1BCA3i,1CF00-1CF2Di,1CF30-1CF46i,1D167-1D169i,1D173-1D182i,1D185-1D18Bi,1D1AA-1D1ADi,1D242-1D244i,1D400-1D454c,1D456-1D49Cc,1D49E-1D49Fc,1D4A2c,1D4A5-1D4A6c,1D4A9-1D4ACc,1D4AE-1D4B9c,1D4BBc,1D4BD-1D4C3c,1D4C5-1D505c,1D507-1D50Ac,1D50D-1D514c,1D516-1D51Cc,1D51E-1D539c,1D53B-1D53Ec,1D540-1D544c,1D546c,1D54A-1D550c,1D552-1D6A5c,1D6A8-1D6C0c,1D6C2-1D6DAc,1D6DC-1D6FAc,1D6FC-1D714c,1D716-1D734c,1D736-1D74Ec,1D750-1D76Ec,1D770-1D788c,1D78A-1D7A8c,1D7AA-1D7C2c,1D7C4-1D7CBc,1DA00-1DA36i,1DA3B-1DA6Ci,1DA75i,1DA84i,1DA9B-1DA9Fi,1DAA1-1DAAFi,1DF00-1DF09c,1DF0B-1DF1Ec,1DF25-1DF2Ac,1E000-1E006i,1E008-1E018i,1E01B-1E021i,1E023-1E024i,1E026-1E02Ai,1E030-1E06Di,1E08Fi,1E130-1E13Di,1E2AEi,1E2EC-1E2EFi,1E4EB-1E4EFi,1E5EE-1E5EFi,1E6E3i,1E6E6i,1E6EE-1E6EFi,1E6F5i,1E6FFi,1E8D0-1E8D6i,1E900-1E943c,1E944-1E94Bi,1F130-1F149c,1F150-1F169c,1F170-1F189c,1F3FB-1F3FFi,E0001i,E0020-E007Fi,E0100-E01EFi"

def sigmaRuns : Array (UInt32 × UInt32 × UInt8) := Id.run do
  let s := sigmaTable
  let n := s.utf8ByteSize
  let mut out : Array (UInt32 × UInt32 × UInt8) := Array.mkEmpty 700
  let mut cur : UInt32 := 0
  let mut lo : UInt32 := 0
  let mut hasHi := false
  let mut i := 0
  while i < n do
    let b := byteAt s i
    if b == 105 || b == 99 then
      out := out.push (if hasHi then lo else cur, cur, if b == 105 then 1 else 2)
      cur := 0
      hasHi := false
    else if b == 45 then
      lo := cur
      cur := 0
      hasHi := true
    else if b != 44 then
      cur := cur * 16 + hexValue b
    i := i + 1
  return out

def caseClass (cp : UInt32) : UInt8 := Id.run do
  let rs := sigmaRuns
  let mut lo := 0
  let mut hi := rs.size
  while lo < hi do
    let mid := (lo + hi) / 2
    let (a, b, v) := rs[mid]!
    if cp < a then hi := mid
    else if cp > b then lo := mid + 1
    else return v
  return 0

def casedBefore (cs : Array Char) (i : Nat) : Bool := Id.run do
  let mut k := i
  while k > 0 do
    k := k - 1
    let c := caseClass cs[k]!.val
    if c != 1 then return c == 2
  return false

def casedAfter (cs : Array Char) (i : Nat) : Bool := Id.run do
  let mut k := i + 1
  while k < cs.size do
    let c := caseClass cs[k]!.val
    if c != 1 then return c == 2
    k := k + 1
  return false

/-- Unicode's `Final_Sigma`: something cased before and nothing cased after,
case-ignorable code points skipped on both sides. -/
def finalSigma (cs : Array Char) (i : Nat) : Bool :=
  casedBefore cs i && !casedAfter cs i

/-- What Rust's `str::to_lowercase` writes: every code point's Unicode
lowercase, plus the two answers a per-code-point mapping cannot give — `İ`
becomes two code points, and `Σ` becomes `ς` at the end of a word and `σ`
anywhere else.

Not `Char.toLower`, which is `A`..`Z` and nothing else: the fold section of
`search-index.bin` carries exactly the names the two disagree about, so a build
that had only the ASCII rule would write an empty fold section and call it
agreement. -/
def toLowercase (s : String) : String := Id.run do
  let cs := s.toList.toArray
  let mut out := ""
  for i in [0:cs.size] do
    let v := cs[i]!.val
    if v == 0x3A3 then
      out := out.push (Char.ofNat (if finalSigma cs i then 0x3C2 else 0x3C3))
    else if v == 0x130 then
      out := (out.push 'i').push (Char.ofNat 0x307)
    else
      out := out.push (Char.ofNat (lowerOf v).toNat)
  return out

end Litedoc4
