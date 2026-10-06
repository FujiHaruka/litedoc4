/- The data format and the three storage candidates, over a hand-written package
whose versions carry the churn the S input carries: unchanged, moved, reordered,
changed in docstring, signature, attributes and equations, renamed, and a
dependency's line range moving. Content renders docstrings through md4c, which
`#guard` cannot reach, so everything whose fixture has a docstring runs. -/
import Litedoc4.Data.CandidateA
import Litedoc4.Data.CandidateB
import Litedoc4.Data.CandidateC
import Litedoc4.Data.Measure
import Litedoc4.Data.Site
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
    line := 6, endLine := 7, index := 1, attrs := #[("simp", "")], refs := #[("P.A", "P.A.f")] }

def hDecl : Decl :=
  { name := "P.B.h", kind := "definition", ty := "Nat", typeCode := #[dataSpan 0 3 1 "Nat"]
    line := 2, endLine := 2, index := 0 }

def moduleA (decls : Array Decl) : Module :=
  { name := "P.A", schemaVersion := 5, imports := #["P.B"]
    moduleDocs := #[{ line := 1, text := "# A" }], decls }

def moduleB (decls : Array Decl) : Module := { name := "P.B", schemaVersion := 5, decls }

def dataLidx (start : Nat) : Lidx :=
  parseLidx s!"#lidx2\n@Dep.Core\nDep.Core\n\tDep.x\t{start}\t{start + 2}\nInit.Prelude\n\tNat\t5\t9\n\tEq\t20\t30\n"

def dataDepMaps : Array (Array (String × String)) :=
  #[#[("Dep.x", "Dep.Core"), ("Nat", "Init.Prelude"), ("Eq", "Init.Prelude")]]

def pinned : ExternalLinks := mkExternalLinks #[("Init", "https://core/src"), ("Dep", "https://dep/src")]

def dataVersion (name : String) (a : Array Decl) (depStart : Nat := 10)
    (b : Array Decl := #[hDecl]) (others : Array Module := #[]) (sources := pinned) :
    Data.VersionData :=
  Data.versionData
    { name, modules := #[moduleA a, moduleB b] ++ others, depMaps := dataDepMaps
      lidx := dataLidx depStart, sources }

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

/-- With no locator, which is the one part a candidate writes. -/
def pageText (v : Data.VersionData) (module : String) : String :=
  ((pageAt v module).map (Data.pageJson · "null")).getD ""

def itemText (v : Data.VersionData) (module : String) (i : Nat) : String :=
  (((pageAt v module).bind (·.items[i]?)).bind (String.fromUTF8? ·.content.bytes)).getD ""

def aPageFileListsEachImportOnceInNameOrder : Bool :=
  let v := Data.versionData
    { name := "imports", modules := #[{ moduleB #[hDecl] with imports := #["P.A", "Init", "Init"] }]
      depMaps := #[], lidx := dataLidx 10, sources := {} }
  ((pageAt v "P.B").map (·.imports)) == some #["Init", "P.A"]

#guard aPageFileListsEachImportOnceInNameOrder

/-! ## The content address -/

def anUnchangedDeclarationKeepsItsAddressAcrossVersions : Invariant where
  name := "an unchanged declaration keeps its address in every version, and in a version where \
    its olean slot moved"
  check := pure <| first <|
    [moved, reordered, docChanged, signatureChanged, attributeChanged, equationsChanged, renamed,
      dependencyMoved].map (fun v => eq (v.name, addressesAt v "P.B") (v.name, addressesAt base "P.B"))
    ++ [eq ((addressesAt slotMoved "P.B").take 1) (addressesAt base "P.B")]

def aMovedDeclarationKeepsItsAddressAndOnlyItsPagePositionMoves : Invariant where
  name := "a moved declaration keeps its address, and only its line range in the page moves"
  check := pure <| first [eq (addressesAt moved "P.A") (addressesAt base "P.A"),
    eq (linesAt base "P.A") #[none, some (3, 4), some (6, 7)],
    eq (linesAt moved "P.A") #[none, some (5, 6), some (8, 9)]]

def aReorderKeepsBothAddressesAndSwapsThemInThePage : Invariant where
  name := "a reorder keeps both addresses and swaps them in the page"
  check := pure <|
    let a := addressesAt base "P.A"
    first [eq a.size 3, eq (addressesAt reordered "P.A") #[a[0]!, a[2]!, a[1]!],
      eq (linesAt reordered "P.A") #[none, some (3, 4), some (6, 7)]]

/-- `f` is the page's second item and `g` its third: which of the three items
kept their address. -/
def keptAgainstBase (v : Data.VersionData) : List Bool :=
  let a := addressesAt base "P.A"
  let b := addressesAt v "P.A"
  (List.range 3).map fun i => a[i]? == b[i]? && a[i]?.isSome

def aDocstringSignatureAttributeOrEquationChangeGivesANewAddress : Invariant where
  name := "a docstring, signature, attribute or equation change gives that item, and only it, \
    a new address"
  check := pure <| first [eq (keptAgainstBase docChanged) [true, false, true],
    eq (keptAgainstBase signatureChanged) [true, false, true],
    eq (keptAgainstBase attributeChanged) [true, true, false],
    eq (keptAgainstBase equationsChanged) [true, false, true]]

def aRenamedTheoremIsANewAddressBecauseTheNameIsContent : Invariant where
  name := "a renamed theorem is a new address, because the name is content"
  check := pure <| eq (keptAgainstBase renamed) [true, true, false]

/-! ## The page file -/

def thePageFileResolvesOwnNamesToAModuleAndDependencyNamesToARootAndARange : Invariant where
  name := "the page file resolves own names to a module and dependency names to a page-local \
    root and a line range"
  check := pure <| eq (pageText base "P.A")
    "{\"module\":\"P.A\",\"imports\":[\"P.B\"],\"content\":null,\"lines\":[0,[3,4],[6,7]],\
    \"roots\":[\"Dep\",\"Init\"],\"names\":{\"Dep.x\":[0,\"Dep.Core\",10,12],\
    \"Eq\":[1,\"Init.Prelude\",20,30],\"Nat\":[1,\"Init.Prelude\",5,9],\"P.A.f\":[\"P.A\"]},\
    \"words\":{}}"

def aPageTableHoldsOnlyTheNamesItsOwnItemsReference : Invariant where
  name := "a page's tables hold only the names its own items reference, and its roots only \
    the roots those names are in"
  check := pure <| eq (pageText base "P.B")
    "{\"module\":\"P.B\",\"imports\":[],\"content\":null,\"lines\":[[2,2]],\
    \"roots\":[\"Init\"],\"names\":{\"Nat\":[0,\"Init.Prelude\",5,9]},\"words\":{}}"

def anUnpinnedOrUnmappedRootGivesNoEntry : Invariant where
  name := "a root the source map leaves unpinned, or does not hold, gives its names no entry \
    and is not among the page's roots"
  check := pure <|
    let without := "{\"module\":\"P.A\",\"imports\":[\"P.B\"],\"content\":null,\
      \"lines\":[0,[3,4],[6,7]],\"roots\":[\"Init\"],\"names\":{\
      \"Eq\":[0,\"Init.Prelude\",20,30],\"Nat\":[0,\"Init.Prelude\",5,9],\"P.A.f\":[\"P.A\"]},\
      \"words\":{}}"
    let unpinned := dataVersion "unpinned" #[fDecl, gDecl]
      (sources := mkExternalLinks #[("Init", "https://core/src"), ("Dep", "")])
    let unmapped := dataVersion "unmapped" #[fDecl, gDecl]
      (sources := mkExternalLinks #[("Init", "https://core/src")])
    first [eq (pageText unpinned "P.A") without, eq (pageText unmapped "P.A") without]

def aDependencyLineRangeMovingChangesOnlyThePageFilesThatLinkToIt : Invariant where
  name := "a dependency's line range moving leaves every address and every version file, and \
    changes only the page files that link to it"
  check := pure <| first [eq (addressesAt dependencyMoved "P.A") (addressesAt base "P.A"),
    eq (dependencyMoved.files.map (·.2.toList)) (base.files.map (·.2.toList)),
    eq (pageText dependencyMoved "P.B") (pageText base "P.B"),
    eq ((pageText dependencyMoved "P.A").replace "[0,\"Dep.Core\",40,42]" "[0,\"Dep.Core\",10,12]")
      (pageText base "P.A"),
    eq (pageText dependencyMoved "P.A" == pageText base "P.A") false]

/-- `O` sorts before both, so every position in the module order moves. -/
def earlyModule : Module :=
  { name := "O", schemaVersion := 5, decls := #[{ hDecl with name := "O.z", line := 1, endLine := 1 }] }

def aModuleAddedBeforeAnotherLeavesItsPageAndUsedByFilesUnchanged : Invariant where
  name := "a module added ahead of another in the module order leaves that module's page file \
    and Used by file byte for byte"
  check := pure <|
    let more := dataVersion "more" #[fDecl, gDecl] (others := #[earlyModule])
    first [eq ((pageAt more "O").isSome, more.pages.map (·.module)) (true, #["O", "P.A", "P.B"]),
      eq (pageText more "P.A") (pageText base "P.A"),
      eq (pageText more "P.B") (pageText base "P.B"),
      eq ((fileAt more "used-by/P/A.json").map (·.toList)) ((fileAt base "used-by/P/A.json").map (·.toList)),
      eq ((fileAt base "used-by/P/A.json").bind String.fromUTF8?)
        (some "{\"P.A.f\":[[\"P.A.g\",\"P.A\"]]}")]

/-! ## Docstrings in the content -/

def wordsDecl : Decl :=
  { name := "P.A.w", kind := "definition", ty := "Nat", line := 9, endLine := 9, index := 2
    doc := "See `P.A.f`, `Foo.g`, `Nat` and `zzz`." }

def aDocstringWordIsMarkedAndResolvedPerPageWordTailOrNotAtAll : Invariant where
  name := "every word a docstring's code holds is marked in the content, and the page's words \
    table holds the word when it resolves, its tail when only that does, and neither otherwise"
  check := pure <|
    let v := dataVersion "words" #[fDecl, gDecl, wordsDecl]
    let page := pageText v "P.A"
    let words := (page.splitOn "\"words\":").getLastD ""
    first [eq ((itemText v "P.A" 3).splitOn "\"doc\":").length 2,
      eq (((itemText v "P.A" 3).splitOn "\"doc\":").getLastD "")
        "\"<p>See <code><w>P.A.f</w></code>, <code><w>Foo.g</w></code>, <code><w>Nat</w></code> \
        and <code><w>zzz</w></code>.</p>\"}",
      eq words "{\"Nat\":[1,\"Init.Prelude\",5,9],\"P.A.f\":[\"P.A\"],\"f\":[\"P.A\",\"P.A.f\"],\
        \"g\":[\"P.A\",\"P.A.g\"]}}"]

def linkDoc : String := "[x](other.html) [y](##P.A.f) [z](#frag) [w](https://h/p)"

def linksDecl : Decl :=
  { name := "P.A.l", kind := "theorem", ty := "True", line := 11, endLine := 11, index := 3
    doc := linkDoc }

def deepModule : Module :=
  { name := "P.Deep.Er.M", schemaVersion := 5
    decls := #[{ linksDecl with name := "P.A.l", line := 2, endLine := 2, index := 0 }] }

def contentCarriesNoRootPrefixAtAnyDepth : Invariant where
  name := "a docstring's relative and `##name` links carry no root prefix in the content, so the \
    same docstring on pages at two depths is the same bytes, where today's renderer differs"
  check := pure <|
    let v := dataVersion "links" #[fDecl, gDecl, linksDecl] (others := #[deepModule])
    let shallow := itemText v "P.A" 3
    let deep := itemText v "P.Deep.Er.M" 0
    let relative (root : String) : String :=
      (docstring "" { hrefs := .relative root noLinks, bib := {} } linkDoc).run' {}
    first [eq (relative (pageRoot "P.A") == relative (pageRoot "P.Deep.Er.M")) false,
      eq shallow deep,
      eq ((shallow.splitOn "\"doc\":").getLastD "")
        "\"<p><a href=\\\"other.html\\\">x</a> <a href=\\\"##P.A.f\\\">y</a> \
        <a href=\\\"#frag\\\">z</a> <a href=\\\"https://h/p\\\">w</a></p>\"}",
      eq (((pageText v "P.A").splitOn "\"words\":").getLastD "") "{\"P.A.f\":[\"P.A\"]}}"]

def aCitationWithNoBibliographyIsTheAuthorsText : Invariant where
  name := "with no bibliography in the store, a citation is the author's bracketed text and a \
    link to the references page is a relative link like any other"
  check := pure <| eq (Data.docOf {} "As in [Key] and [t](references.html#ref_Key).").html
    "<p>As in [Key] and <a href=\"references.html#ref_Key\">t</a>.</p>"

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

def candidateADedupsAModuleFileOnlyWhenItsItemsAreUnchangedAndInOrder : Invariant where
  name := "candidate (a) stores a module file again only when its items changed or moved in order"
  check := pure <|
    let moves := Data.CandidateA.layout identity #[base, moved, docChanged]
    let reorder := Data.CandidateA.layout identity #[base, reordered]
    eq [addedContentFiles moves 0, addedContentFiles moves 1, addedContentFiles moves 2,
        addedContentFiles reorder 1] [[2, 4], [0, 0], [1, 3], [1, 3]]

def candidateBAddsOneSegmentOfOneItemForOneChangedDeclaration : Invariant where
  name := "candidate (b) adds one segment of one item for one changed declaration"
  check := pure <|
    let l := Data.CandidateB.layout identity #[base, moved, docChanged]
    first [eq [addedContentFiles l 0, addedContentFiles l 1, addedContentFiles l 2]
        [[2, 4], [0, 0], [1, 1]],
      eq (match l with
        | .ok l => (l.views.filter (·.version == 2)).map (·.fetches.filter (·.isContent) |>.size)
        | .error _ => #[]) #[2, 1]]

/-- Every item of every page view, sliced out of the ranges its page file names
in the stored files, by the offset and length the page file gives. -/
def packSlices (l : Data.Layout) (vs : Array Data.VersionData)
    (decode : ByteArray → Array Nat → Option ByteArray) : Option (Array (Array String)) := do
  let mut out : Array (Array String) := #[]
  for v in vs do
    for p in v.pages do
      let page ← (l.files.find? (·.path == Data.pagePath v p)).map (·.stored)
      let j ← (parseJson (← String.fromUTF8? page)).toOption
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

def candidateCRangesCoverExactlyEachPagesItems : Invariant where
  name := "candidate (c)'s ranges cover exactly each page's items, at one item a chunk and at the \
    default chunk size"
  check := pure <|
    let vs := #[base, docChanged, renamed]
    first <| [1, 16384].map fun chunk =>
      match Data.CandidateC.layout identity chunk vs with
      | .ok l => first [eq (packSlices l vs uncompressed) (some (pageAddresses vs)),
          eq (chunk != 1 || (l.views.filter (·.version == 0)).all fun v => v.itemsFetched == v.items) true]
      | .error why => some why

def countsOf (l : Except String Data.Layout) (vs : Array Data.VersionData) : List Nat :=
  match l with
  | .ok l => (Data.counts vs l).versions.toList.map (·.newAddresses)
  | .error _ => []

def everyCandidateCountsTheSameNewAddresses : Invariant where
  name := "every candidate counts the same new addresses per version"
  check := pure <|
    let vs := #[base, moved, docChanged, renamed]
    first <| [Data.CandidateA.layout identity vs, Data.CandidateB.layout identity vs,
      Data.CandidateC.layout identity 16384 vs].map fun l => eq (countsOf l vs) [4, 0, 1, 1]

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
          let pages := l.files.map fun f =>
            if f.path.endsWith ".pack" then f
            else { f with stored := (Gzip.decompress f.stored).toOption.getD .empty }
          problems := problems ++
            [eq (packSlices { l with files := pages } vs gzipMembers) (some (pageAddresses vs))]
    return first problems

/-! ## The rendered site -/

def siteMeta : Data.Site.VersionMeta :=
  { commit := "c0ffee", lean := "4.31.0", source := "https://h/o/r/blob/c0ffee" }

def renderedOf (v : Data.VersionData) : Option Data.Site.Rendered := (Data.Site.render siteMeta v).toOption

def dataNamed (r : Data.Site.Rendered) (what : String) : Option Data.Site.DataFile :=
  r.data.find? (·.what == what)

def aShellClimbsOutOfItsModuleDirectoriesAndItsVersionDirectory : Bool :=
  let f := Data.Site.DataFile.of "json" "" "{}".toUTF8
  Data.Site.moduleShell "v1" "A.B.C" f f f ==
    s!"<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n\
      <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\
      <title>A.B.C</title>\n<link rel=\"stylesheet\" href=\"../../../assets/style.css\">\n\
      <link rel=\"icon\" href=\"../../../assets/favicon.svg\">\n<script>{themeBootJs}</script>\n\
      <script type=\"module\" src=\"../../../assets/site.js\"></script>\n</head>\n\
      <body data-root=\"../../../\" data-version=\"v1\" data-module=\"A.B.C\" \
      data-data=\"{f.address}\" data-page=\"{f.address}\" data-used-by=\"{f.address}\">\
      <noscript>These pages are drawn by JavaScript, which is off.</noscript></body>\n</html>\n"
    && (Data.Site.versionIndexShell "v1" f).contains "data-root=\"../\""
    && (Data.Site.siteIndexShell "v1" f.address).contains
      "<script type=\"module\" src=\"./assets/site.js\""
    && storeAssets.map (·.1) == #["style.css", "favicon.svg", "site.js"]
    && Data.Site.shellPath "v1" "A.B.C" == "v1/A/B/C.html"

#guard aShellClimbsOutOfItsModuleDirectoriesAndItsVersionDirectory

/-- No docstring anywhere, so `#guard` reaches it without md4c. -/
def undocumented (modules : Array Module) : Data.VersionData :=
  Data.versionData { name := "u", modules, depMaps := dataDepMaps, lidx := dataLidx 10, sources := pinned }

def theVersionFileListsExactlyTheRootsItsPagesNameWithTheBaseTheyResolvedUnder : Bool :=
  let onlyB := undocumented #[moduleB #[hDecl]]
  let both := undocumented #[moduleB #[hDecl], { name := "P.C", schemaVersion := 5, decls := #[gDecl] }]
  let f := Data.Site.DataFile.of "json" "" "[]".toUTF8
  Data.versionRoots onlyB.links == #[("Init", "https://core/src")]
    && Data.versionRoots both.links == #[("Dep", "https://dep/src"), ("Init", "https://core/src")]
    && Data.Site.versionFileJson "u" both.title siteMeta (Data.versionRoots both.links) f f f f
        none ==
      s!"\{\"version\":\"u\",\"title\":\"P\",\"commit\":\"c0ffee\",\"lean\":\"4.31.0\",\
        \"source\":\"https://h/o/r/blob/c0ffee\",\"roots\":\{\"Dep\":\"https://dep/src\",\
        \"Init\":\"https://core/src\"},\"modules\":\"{f.address}\",\"search\":\"{f.address}\",\
        \"instances\":\"{f.address}\",\"references\":\"{f.address}\",\"front\":null}"

#guard theVersionFileListsExactlyTheRootsItsPagesNameWithTheBaseTheyResolvedUnder

def theVersionFileNamesItsReferencesAndFrontPageFilesAndCarriesTheTitle : Bool :=
  let f := Data.Site.DataFile.of "json" "" "[]".toUTF8
  let g := Data.Site.DataFile.of "json" "" "{}".toUTF8
  let text := Data.Site.versionFileJson "u" "A \"T\"" siteMeta #[] f f f g (some f)
  text.startsWith "{\"version\":\"u\",\"title\":\"A \\\"T\\\"\","
    && text.endsWith s!",\"references\":\"{g.address}\",\"front\":\"{f.address}\"}"
    && (undocumented #[moduleB #[hDecl]]).references.toList == "[]".toUTF8.toList

#guard theVersionFileNamesItsReferencesAndFrontPageFilesAndCarriesTheTitle

def aPageFileNamesItsContentByAddressAndAnEmptyPageNamesNone : Invariant where
  name := "a page file names its content file by the address of that file's bytes, its shell \
    names the page file by its address, and a page with no items names no content and has none"
  check := pure <|
    match renderedOf (dataVersion "v1" #[fDecl, gDecl] (others := #[{ name := "P.E", schemaVersion := 5 }])) with
    | none => some "render refused"
    | some r =>
      let text := fun (f : Data.Site.DataFile) => (String.fromUTF8? f.raw).getD ""
      match dataNamed r "v1's content of P.A", dataNamed r "v1's page file of P.A",
          dataNamed r "v1's page file of P.E", pageAt base "P.A" with
      | some content, some page, some empty, some p =>
        first [eq content.raw.toList (Data.arrayOf (p.items.map (·.content))).toList,
          eq ((text page).splitOn s!"\"content\":\"{content.address}\"").length 2,
          eq content.address (Data.hexAddressOf content.raw),
          eq ((r.shells.find? (·.1 == "v1/P/A.html")).map (·.2.splitOn s!"data-page=\"{page.address}\"" |>.length)) (some 2),
          eq ((text empty).splitOn "\"content\":null").length 2,
          eq (dataNamed r "v1's content of P.E").isSome false]
      | _, _, _, _ => some "a content or page file is missing"

def aChangedDocstringAddsOnlyItsContentItsPageFileAndTheVersionFile : Invariant where
  name := "a version whose only change is one docstring shares every data file with the one \
    before except that page's content and page files and its own version file"
  check := pure <|
    match renderedOf base, renderedOf docChanged with
    | some before, some after =>
      let had : Std.HashSet String := Std.HashSet.ofArray (before.data.map (·.path))
      let added := (after.data.filter fun f => !had.contains f.path).map (·.what)
      eq (sortUtf16 added) #["doc's content of P.A", "doc's page file of P.A", "doc's version file"]
    | _, _ => some "render refused"

/-! ## The version's site configuration -/

def dataBibText : String :=
  "@misc{K,\n  author = {Ann Author},\n  title = {A Title},\n  year = {2020}\n}\n"

def dataBib : Bibliography := ((bibliographyOf "test" (some dataBibText)).toOption).getD {}

def citingDecl (name : String) (line : Nat) (doc : String) : Decl :=
  { name, kind := "theorem", ty := "True", line, endLine := line, index := line, doc }

def deepCiting : Module :=
  { name := "P.Deep.Er.M", schemaVersion := 5
    decls := #[citingDecl "P.Deep.Er.M.c" 2 "As in [K]."] }

def siteVersion (name : String) (a : Array Decl) (front : Option String := none) :
    Data.VersionData :=
  Data.versionData
    { name, modules := #[moduleA a, moduleB #[hDecl], deepCiting], depMaps := dataDepMaps
      lidx := dataLidx 10, sources := pinned
      site := { title := some "T", indexMarkdown := front, bibliography := dataBib } }

def docHtml (item : String) : String :=
  match parseJson item with
  | .ok j => ((jvalGet? j "doc").map asStr).getD ""
  | .error _ => ""

def citing : Data.VersionData :=
  siteVersion "cites" #[fDecl, gDecl, citingDecl "P.A.c" 13 "As in [K].",
    citingDecl "P.A.d" 15 "Also [K]."]

def aCitationInContentLinksToTheReferencesPageWithNoRootPrefixAndNoAnchorId : Invariant where
  name := "a citation in content resolves against the version's bibliography, its tag and title \
    the entry's, and links to `references.html` with no root prefix and no anchor id, so the \
    same docstring at two depths is the same markup"
  check := pure <|
    match dataBib.items[0]? with
    | none => some "the test bibliography has no entry"
    | some item =>
      let today := (docstring "" { hrefs := .relative (pageRoot "P.Deep.Er.M") noLinks, bib := dataBib }
        "As in [K].").run' {}
      first [eq (docHtml (itemText citing "P.A" 3))
          (escapeInto (escapeInto "<p>As in <a href=\"references.html#ref_K\" title=\""
            item.plaintext ++ "\" data-cite>") item.tag ++ "</a>.</p>"),
        eq (docHtml (itemText citing "P.A" 3)) (docHtml (itemText citing "P.Deep.Er.M" 0)),
        eq ((today.splitOn "href=\"../../.././references.html#ref_K\"").length,
            (today.splitOn "id=\"_backref_0\"").length) (2, 2),
        eq (((itemText citing "P.A" 4).splitOn "_backref").length) 1]

def theReferencesDataListsEachEntryWithItsCitationsInModuleAndPageOrder : Invariant where
  name := "the references data lists each entry, tag and markup with the citations of it: \
    modules in name order, each page's numbered from 0 in page order"
  check := pure <|
    match dataBib.items[0]? with
    | none => some "the test bibliography has no entry"
    | some item =>
      let head := jsonStr (jsonStr (jsonStr "[{\"key\":\"K\",\"tag\":" item.tag ++ ",\"html\":")
        item.html ++ ",\"by\":[[\"P.A\",0,") "P.A.c"
      eq (String.fromUTF8? citing.references)
        (some (head ++ "],[\"P.A\",1,\"P.A.d\"],[\"P.Deep.Er.M\",0,\"P.Deep.Er.M.c\"]]}]"))

def frontMarkdown : String := "# Front\n\nSee `P.A.f` and [K]."

def theRenderedVersionNamesItsFrontPageAndReferencesFilesAndTheReferencesPageHasAShell :
    Invariant where
  name := "a rendered version's file names its references and front page data files by \
    address, the references page has a shell naming its data, and the front page is the index \
    Markdown, deferred, with its own words table and no bibliography"
  check := pure <|
    match renderedOf (siteVersion "v1" #[fDecl, gDecl] (front := some frontMarkdown)) with
    | none => some "render refused"
    | some r =>
      let text := fun (f : Data.Site.DataFile) => (String.fromUTF8? f.raw).getD ""
      match dataNamed r "v1's references", dataNamed r "v1's front page" with
      | some refs, some front =>
        let html := (docstring "" { hrefs := .deferred, bib := {} } frontMarkdown).run' {}
        first [
          eq ((text r.versionFile).splitOn s!"\"references\":\"{refs.address}\",\"front\":\"{front.address}\"}").length 2,
          eq ((text r.versionFile).splitOn "\"title\":\"T\"").length 2,
          eq ((r.shells.find? (·.1 == "v1/references.html")).map
            (·.2.splitOn s!"data-references=\"{refs.address}\"" |>.length)) (some 2),
          eq (text front) (jsonStr "{\"html\":" html ++ ",\"roots\":[],\"words\":{\"P.A.f\":[\"P.A\"]}}"),
          eq ((html.splitOn "<w>P.A.f</w>").length, (html.splitOn "[K]").length) (2, 2)]
      | _, _ => some "the references or front page data file is missing"

end DataFormat
end Litedoc4Test
