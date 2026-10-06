/- The data format and the three storage candidates, over a hand-written package
whose versions carry the churn the S input carries: unchanged, moved, reordered,
changed in docstring, signature, attributes and equations, renamed, and a
dependency's line range moving. Everything but compression is pure, so the
candidates run here with no compressor; `Gzip` is exercised at run time. -/
import Litedoc4.Data.CandidateA
import Litedoc4.Data.CandidateB
import Litedoc4.Data.CandidateC
import Litedoc4.Data.Measure
import Litedoc4.Gzip
import Litedoc4Test.Basis

namespace Litedoc4Test
namespace DataFormat
open Litedoc4

def dataSpan (start stop kind : Nat) (name : String := "") : Span := { start, stop, kind, name }

def fDecl : Decl :=
  { name := "P.A.f", kind := "definition", binders := #["(n : Nat)"]
    binderCode := #[#[dataSpan 1 2 0, dataSpan 5 8 1 "Nat"]], implicits := #[false]
    ty := "Nat", typeCode := #[dataSpan 0 3 1 "Nat"], line := 3, endLine := 4, index := 0
    doc := "Doubles.", equations := #["P.A.f n = n + n"]
    equationCode := #[#[dataSpan 0 15 1 "Eq", dataSpan 0 7 1 "P.A.f"]] }

def gDecl : Decl :=
  { name := "P.A.g", kind := "theorem", ty := "P.A.f 0 = Dep.x"
    typeCode := #[dataSpan 0 15 1 "Eq", dataSpan 0 7 1 "P.A.f", dataSpan 10 15 1 "Dep.x"]
    line := 6, endLine := 7, index := 1, attrs := #[("simp", "")] }

def hDecl : Decl :=
  { name := "P.B.h", kind := "definition", ty := "Nat", typeCode := #[dataSpan 0 3 1 "Nat"]
    line := 2, endLine := 2, index := 0 }

def moduleA (decls : Array Decl) : Module :=
  { name := "P.A", schemaVersion := 5, imports := #["P.B"]
    moduleDocs := #[{ line := 1, text := "# A" }], decls }

def moduleB (decls : Array Decl) : Module := { name := "P.B", schemaVersion := 5, decls }

def dataLidx (start : Nat) : Lidx :=
  parseLidx s!"#lidx2\n@Dep.Core\nDep.Core\n\tDep.x\t{start}\t{start + 2}\nInit.Prelude\n\tNat\t5\t9\n\tEq\t20\t30\n"

def dataVersion (name : String) (a : Array Decl) (depStart : Nat := 10)
    (b : Array Decl := #[hDecl]) : Data.VersionData :=
  Data.versionData
    { name, modules := #[moduleA a, moduleB b]
      depMaps := #[#[("Dep.x", "Dep.Core"), ("Nat", "Init.Prelude"), ("Eq", "Init.Prelude")]]
      lidx := dataLidx depStart, sources := #[("Init", "https://core/src")] }

def base : Data.VersionData := dataVersion "v1" #[fDecl, gDecl]
def moved : Data.VersionData :=
  dataVersion "moved" #[{ fDecl with line := 5, endLine := 6 }, { gDecl with line := 8, endLine := 9 }]
def reordered : Data.VersionData :=
  dataVersion "reordered" #[{ fDecl with line := 6, endLine := 7 }, { gDecl with line := 3, endLine := 4 }]
def docChanged : Data.VersionData := dataVersion "doc" #[{ fDecl with doc := "Twice." }, gDecl]
def signatureChanged : Data.VersionData :=
  dataVersion "signature" #[{ fDecl with ty := "Int", typeCode := #[dataSpan 0 3 1 "Int"] }, gDecl]
def attributeChanged : Data.VersionData := dataVersion "attribute" #[fDecl, { gDecl with attrs := #[] }]
def equationsChanged : Data.VersionData :=
  dataVersion "equations" #[{ fDecl with equations := #["P.A.f n = 2 * n"] }, gDecl]
def renamed : Data.VersionData := dataVersion "renamed" #[fDecl, { gDecl with name := "P.A.g2" }]
def dependencyMoved : Data.VersionData := dataVersion "dependency" #[fDecl, gDecl] (depStart := 40)
/-- `h`'s slot in the olean order moves from 0 to 1, as `usesHole`'s did in S. -/
def slotMoved : Data.VersionData :=
  dataVersion "slot" #[fDecl, gDecl]
    (b := #[{ hDecl with name := "P.B.k", line := 4, endLine := 4, index := 0 }, { hDecl with index := 1 }])

def pageAt (v : Data.VersionData) (module : String) : Option Data.Page :=
  v.pages.find? (·.module == module)

def addressesAt (v : Data.VersionData) (module : String) : Array String :=
  ((pageAt v module).map (·.items.map (·.address.hex))).getD #[]

def linesAt (v : Data.VersionData) (module : String) : Array (Option (Nat × Nat)) :=
  ((pageAt v module).map (·.items.map (·.lines))).getD #[]

def fileAt (v : Data.VersionData) (path : String) : Option ByteArray :=
  (v.files.find? (·.1 == path)).map (·.2)

def aManifestListsEachImportOnceInNameOrder : Bool :=
  let v := Data.versionData
    { name := "imports", modules := #[{ moduleA #[fDecl] with imports := #["P.B", "Init", "Init"] }]
      depMaps := #[], lidx := dataLidx 10, sources := #[] }
  ((pageAt v "P.A").map (·.imports)) == some #["Init", "P.B"]

#guard aManifestListsEachImportOnceInNameOrder

/-! ## The content address -/

def anUnchangedDeclarationKeepsItsAddressAcrossVersions : Bool :=
  [moved, reordered, docChanged, signatureChanged, attributeChanged, equationsChanged, renamed,
    dependencyMoved].all (fun v => addressesAt v "P.B" == addressesAt base "P.B")
    && (addressesAt slotMoved "P.B").take 1 == addressesAt base "P.B"

#guard anUnchangedDeclarationKeepsItsAddressAcrossVersions

def aMovedDeclarationKeepsItsAddressAndOnlyItsManifestPositionMoves : Bool :=
  addressesAt moved "P.A" == addressesAt base "P.A"
    && linesAt base "P.A" == #[none, some (3, 4), some (6, 7)]
    && linesAt moved "P.A" == #[none, some (5, 6), some (8, 9)]

#guard aMovedDeclarationKeepsItsAddressAndOnlyItsManifestPositionMoves

def aReorderKeepsBothAddressesAndSwapsThemInTheManifest : Bool :=
  let a := addressesAt base "P.A"
  a.size == 3 && addressesAt reordered "P.A" == #[a[0]!, a[2]!, a[1]!]
    && linesAt reordered "P.A" == #[none, some (3, 4), some (6, 7)]

#guard aReorderKeepsBothAddressesAndSwapsThemInTheManifest

/-- `f` is the page's second item and `g` its third. -/
def changesOnly (v : Data.VersionData) (item : Nat) : Bool :=
  let a := addressesAt base "P.A"
  let b := addressesAt v "P.A"
  a.size == 3 && b.size == 3 && (List.range 3).all fun i => (a[i]! == b[i]!) == (i != item)

def aDocstringSignatureAttributeOrEquationChangeGivesANewAddress : Bool :=
  changesOnly docChanged 1 && changesOnly signatureChanged 1 && changesOnly attributeChanged 2
    && changesOnly equationsChanged 1

#guard aDocstringSignatureAttributeOrEquationChangeGivesANewAddress

def aRenamedTheoremIsANewAddressBecauseTheNameIsContent : Bool := changesOnly renamed 2

#guard aRenamedTheoremIsANewAddressBecauseTheNameIsContent

def aDependencyLineRangeMovingLeavesEveryAddressAndChangesOnlyTheLinkTable : Bool :=
  addressesAt dependencyMoved "P.A" == addressesAt base "P.A"
    && fileAt dependencyMoved "links.json" != fileAt base "links.json"
    && (base.files.filter (·.1 != "links.json")).map (·.2)
      == (dependencyMoved.files.filter (·.1 != "links.json")).map (·.2)

#guard aDependencyLineRangeMovingLeavesEveryAddressAndChangesOnlyTheLinkTable

def linkTableText (v : Data.VersionData) : String :=
  ((fileAt v "links.json").bind String.fromUTF8?).getD ""

def theLinkTableResolvesOwnNamesToAModuleAndDependencyNamesToASourceAndARange : Bool :=
  linkTableText base == "{\"sources\":[[\"Dep\",null],[\"Init\",\"https://core/src\"]],\
    \"names\":{\"Dep.x\":[\"Dep.Core\",0,10,12],\"Eq\":[\"Init.Prelude\",1,20,30],\
    \"Nat\":[\"Init.Prelude\",1,5,9],\"P.A.f\":[0]}}"

#guard theLinkTableResolvesOwnNamesToAModuleAndDependencyNamesToASourceAndARange

def aSubtermWrapperIsDroppedAndASortAndANameAreKept : Bool :=
  let t := Data.textOf "{α : Type}" #[dataSpan 1 2 0, dataSpan 5 9 2, dataSpan 0 10 1 "X"]
  t.text == "{α : Type}"
    && t.refs == #[{ start := 5, stop := 9, target := .sort }, { start := 0, stop := 10, target := .name "X" }]

#guard aSubtermWrapperIsDroppedAndASortAndANameAreKept

/-! ## The candidates, uncompressed -/

def identity (b : ByteArray) : ByteArray := b

def addedContentFiles (l : Except String Data.Layout) (k : Nat) : List Nat :=
  match l with
  | .ok l => [(l.files.filter fun f => f.firstVersion == k && f.path.startsWith Data.contentPrefix).size,
              (l.files.filter (·.firstVersion == k)).foldl (· + ·.items) 0]
  | .error _ => []

def candidateADedupsAModuleFileOnlyWhenItsItemsAreUnchangedAndInOrder : Bool :=
  let moves := Data.CandidateA.layout identity #[base, moved, docChanged]
  let reorder := Data.CandidateA.layout identity #[base, reordered]
  addedContentFiles moves 0 == [2, 4] && addedContentFiles moves 1 == [0, 0]
    && addedContentFiles moves 2 == [1, 3] && addedContentFiles reorder 1 == [1, 3]

#guard candidateADedupsAModuleFileOnlyWhenItsItemsAreUnchangedAndInOrder

def candidateBAddsOneSegmentOfOneItemForOneChangedDeclaration : Bool :=
  let l := Data.CandidateB.layout identity #[base, moved, docChanged]
  addedContentFiles l 0 == [2, 4] && addedContentFiles l 1 == [0, 0]
    && addedContentFiles l 2 == [1, 1]
    && match l with
      | .ok l => (l.views.filter (·.version == 2)).map (·.fetches.filter (·.isContent) |>.size)
          == #[2, 1]
      | .error _ => false

#guard candidateBAddsOneSegmentOfOneItemForOneChangedDeclaration

/-- Every item of every page view, sliced out of the ranges its manifest names
in the stored files, by the offset and length the manifest gives. -/
def packSlices (l : Data.Layout) (vs : Array Data.VersionData)
    (decode : ByteArray → Array Nat → Option ByteArray) : Option (Array (Array String)) := do
  let mut out : Array (Array String) := #[]
  for v in vs do
    for p in v.pages do
      let manifest ← (l.files.find? (·.path == Data.manifestPath v p)).map (·.stored)
      let j ← (parseJson (← String.fromUTF8? manifest)).toOption
      let content ← jvalGet? j "content"
      let ranges := asArr (← jvalGet? content "r")
      let mut raws : Array ByteArray := #[]
      for r in ranges do
        let a := asArr r
        let pack ← (l.files.find? (·.path == asStr a[0]!)).map (·.stored)
        raws := raws.push (← decode (pack.extract (asNat a[1]!) (asNat a[2]!)) ((asArr a[3]!).map asNat))
      let mut slices : Array String := #[]
      for i in asArr (← jvalGet? content "i") do
        let a := asArr i
        let raw ← raws[asNat a[0]!]?
        slices := slices.push (Data.hexAddressOf (raw.extract (asNat a[1]!) (asNat a[1]! + asNat a[2]!)))
      out := out.push slices
  return out

def pageAddresses (vs : Array Data.VersionData) : Array (Array String) :=
  vs.flatMap (·.pages.map (·.items.map (·.address.hex)))

def uncompressed (bytes : ByteArray) (_ : Array Nat) : Option ByteArray := some bytes

def candidateCRangesCoverExactlyEachPagesItems : Bool :=
  let vs := #[base, docChanged, renamed]
  [1, 16384].all fun chunk =>
    match Data.CandidateC.layout identity chunk vs with
    | .ok l => packSlices l vs uncompressed == some (pageAddresses vs)
        && (chunk != 1 || (l.views.filter (·.version == 0)).all fun v => v.itemsFetched == v.items)
    | .error _ => false

#guard candidateCRangesCoverExactlyEachPagesItems

def countsOf (l : Except String Data.Layout) (vs : Array Data.VersionData) : List Nat :=
  match l with
  | .ok l => (Data.counts vs l).versions.toList.map (·.newAddresses)
  | .error _ => []

def everyCandidateCountsTheSameNewAddresses : Bool :=
  let vs := #[base, moved, docChanged, renamed]
  [Data.CandidateA.layout identity vs, Data.CandidateB.layout identity vs,
    Data.CandidateC.layout identity 16384 vs].all (countsOf · vs == [4, 0, 1, 1])

#guard everyCandidateCountsTheSameNewAddresses

def aContentFileOfOtherBytesUnderAnAddressAlreadyHostedIsRefused : Bool :=
  let file (b : ByteArray) : Data.Hosted := { path := "content/a/x.json", raw := b.size, stored := b, firstVersion := 0 }
  let one := "[1]".toUTF8
  let other := "[2]".toUTF8
  match Data.addOnce #[] {} (file one) one with
  | .ok (files, seen) =>
    (match Data.addOnce files seen (file one) one with
      | .ok (again, _) => again.size == 1
      | .error _ => false)
    && (match Data.addOnce files seen (file other) other with
      | .ok _ => false
      | .error _ => true)
  | .error _ => false

#guard aContentFileOfOtherBytesUnderAnAddressAlreadyHostedIsRefused

/-! ## With gzip -/

def gzipMembers (bytes : ByteArray) (sizes : Array Nat) : Option ByteArray := Id.run do
  let mut out : ByteArray := .empty
  let mut at_ := 0
  for n in sizes do
    match Gzip.decompress (bytes.extract at_ (at_ + n)) with
    | .ok raw => out := out ++ raw
    | .error _ => return none
    at_ := at_ + n
  return if at_ == bytes.size then some out else none

def everyHostedFileDecompressesToItsRawCountAndEveryPackRangeToItsItems : Invariant where
  name := "every hosted file is gzip of exactly its raw bytes, and every pack range a page \
    reads decompresses member by member into that page's items"
  check := do
    let vs := #[base, docChanged, renamed]
    let compress := Gzip.compress 6
    let layouts := [("a", Data.CandidateA.layout compress vs), ("b", Data.CandidateB.layout compress vs),
      ("c", Data.CandidateC.layout compress 1 vs), ("c", Data.CandidateC.layout compress 16384 vs)]
    let mut problems : List (Option String) := []
    for (name, l) in layouts do
      match l with
      | .error why => problems := problems ++ [some s!"{name}: {why}"]
      | .ok l =>
        for f in l.files do
          if f.path.endsWith ".pack" then continue
          match Gzip.decompress f.stored with
          | .ok raw => if raw.size != f.raw then
              problems := problems ++ [some s!"{name} {f.path}: {raw.size} bytes, counted {f.raw}"]
          | .error why => problems := problems ++ [some s!"{name} {f.path}: {why}"]
        if name == "c" then
          let manifests := l.files.map fun f =>
            if f.path.endsWith ".pack" then f
            else { f with stored := (Gzip.decompress f.stored).toOption.getD .empty }
          problems := problems ++
            [eq (packSlices { l with files := manifests } vs gzipMembers) (some (pageAddresses vs))]
    return first problems

end DataFormat
end Litedoc4Test
