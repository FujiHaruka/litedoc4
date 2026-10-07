/- The whole-package data: the name map, the module list, the search index, the
instance maps and who uses what, derived from every module's facts.

All closed: the derivation reads facts, not docstrings, so nothing here reaches
`Md.events`. -/
import Litedoc4.Global.Artifacts
import Litedoc4Test.GlobalEntry
import Litedoc4Test.GlobalSearchIndex

namespace Litedoc4Test
open Litedoc4

def moduleFacts (module : String) (imports : List String)
    (decls : List (String × String)) : ModuleFacts :=
  { module, contentHash := "0000000000000000", imports := imports.toArray,
    decls := decls.toArray }

def refsOf (pairs : List (String × List Nat)) : Std.HashMap String (Array Nat) := Id.run do
  let mut m : Std.HashMap String (Array Nat) :=
    Std.HashMap.emptyWithCapacity (pairs.length * 2 + 8)
  for (name, users) in pairs do m := m.insert name users.toArray
  return m

/-- Three modules in a chain, so "imports" and "imported by" cannot be confused
for each other by symmetry.

**The references are load-bearing**: with none of them `used-by.json` is `{}` and
both used-by counts are 0, which every assertion about them would survive. Hence
a target two declarations mention, a target one does, a reference to a name this
package does not declare, and `Pkg.dup` declared by **two** modules — the only
way one target's user list holds the same name twice, and so the only way the
per-key deduplication shows up in a count. -/
def chain : Array ModuleFacts :=
  let root : ModuleFacts := moduleFacts "Pkg" [] [("Pkg.a", "definition")]
  let middle : ModuleFacts :=
    { moduleFacts "Pkg.B" ["Pkg"] [("Pkg.B.inst", "instance"), ("Pkg.dup", "theorem")] with
        instances := #[("Cls", "Pkg.B.inst")]
        instancesFor := #[("Pkg.a", "Pkg.B.inst"), ("Pkg.a", "Pkg.B.inst")]
        refs := refsOf [("Pkg.a", [0, 1])] }
  let leaf : ModuleFacts :=
    { moduleFacts "Pkg.C" ["Pkg", "Pkg.B"] [("Pkg.C.t", "theorem"), ("Pkg.dup", "theorem")] with
        refs := refsOf [("Pkg.a", [1]), ("Pkg.B.inst", [0]), ("Dep.outside", [0])] }
  #[root, middle, leaf]

def chainArtifacts : Derived := deriveData chain #[]

def cites (owner citekey funName : String) : PageCitation :=
  { owner, citation := { citekey, funName } }

/-- The modules in the order `index.html` lists them rather than the order the
facts arrive in, and a module's anchors numbered **after** the declarations
another module suppresses are dropped — the renderer numbers the page it writes,
and that page does not carry them. -/
def backReferencesFollowTheModuleListAndSkipWhatAnotherModuleSuppresses : Bool :=
  let late : ModuleFacts :=
    { moduleFacts "Pkg.B" [] [] with
        citations := #[cites "" "K" "", cites "Pkg.B.y" "K" "Pkg.B.y", cites "Pkg.B.z" "L" "Pkg.B.w"] }
  let early : ModuleFacts :=
    { moduleFacts "Pkg" [] [] with
        citations := #[cites "" "L" ""], foreignMembers := #["Pkg.B.y"] }
  backrefsOf #[late, early] ==
    #[{ module := "Pkg", index := 0, citation := { citekey := "L", funName := "" } },
      { module := "Pkg.B", index := 0, citation := { citekey := "K", funName := "" } },
      { module := "Pkg.B", index := 1, citation := { citekey := "L", funName := "Pkg.B.w" } }]
    && (backrefsOf #[late]).size == 3

#guard backReferencesFollowTheModuleListAndSkipWhatAnotherModuleSuppresses

def parsedObj (json : String) : Array (String × JVal) :=
  match parseJson json with
  | .ok v => asObj v
  | .error _ => #[]

def fieldOf (obj : Array (String × JVal)) (key : String) : JVal :=
  ((obj.find? (·.1 == key)).map (·.2)).getD .null

/-- Getting `modules[].i` backwards renders an "Imported by" block that lists the
module's imports — markup that is well formed, styled, populated and wrong. The
chain is not its own mirror image, which is what lets this fail: `Pkg` is
imported by both of the others and `Pkg.C` by nobody. -/
def theModuleIndexListsImportersNotImports : Bool :=
  chainArtifacts.modulesJson ==
    "{\"modules\":[{\"n\":\"Pkg\",\"p\":\"Pkg.html\",\"i\":[1,2]},\
      {\"n\":\"Pkg.B\",\"p\":\"Pkg/B.html\",\"i\":[2]},\
      {\"n\":\"Pkg.C\",\"p\":\"Pkg/C.html\",\"i\":[]}]}"

#guard theModuleIndexListsImportersNotImports

/-- Three rules in one file, and each of them decides a link: a name is written
once, a declaration of this package beats a dependency slice of the same name,
and two modules declaring one name leave the **later** one in the map. -/
def aNameDeclaredHereBeatsADependencySliceAndIsWrittenOnce : Bool :=
  let a := deriveData chain #[#[("Dep.one", "Dep.Home"), ("Pkg.a", "Dep.Elsewhere")]]
  a.nameMapJson ==
      "{\"Dep.one\":\"Dep.Home\",\"Pkg.B.inst\":\"Pkg.B\",\"Pkg.C.t\":\"Pkg.C\",\
        \"Pkg.a\":\"Pkg\",\"Pkg.dup\":\"Pkg.C\"}"
    && a.dependencyNames == 2
    -- The map the delta asks one name at a time and the file the next run reads
    -- as `--before` are built in the same loop and have to stay one map; the two
    -- counts do not add up to it, because `Pkg.a` is on both sides and written
    -- once.
    && a.nameMap.size == (parsedObj a.nameMapJson).size

#guard aNameDeclaredHereBeatsADependencySliceAndIsWrittenOnce

def declaringOne (module name : String) : ModuleFacts :=
  moduleFacts module [] [(name, "definition")]

/-- `𝒜` is above the BMP and `ﬀ` is not, which is the pair that tells UTF-16
order from byte order: sorted by bytes the astral name comes last. Both files are
asked, because they carry the order twice — `modules.json` as rows and
`search-index.bin` as the array those rows are indexed by. -/
def theNewFilesSortInUtf16OrderToo : Bool :=
  let a := deriveData #[declaringOne "Pkg.ﬀ" "Pkg.ﬀ.a", declaringOne "Pkg.𝒜" "Pkg.𝒜.a"] #[]
  a.modulesJson ==
      "{\"modules\":[{\"n\":\"Pkg.𝒜\",\"p\":\"Pkg/𝒜.html\",\"i\":[]},\
        {\"n\":\"Pkg.ﬀ\",\"p\":\"Pkg/ﬀ.html\",\"i\":[]}]}"
    && (match decodeSearchIndex a.searchIndexBin with
        | none => false
        | some d => d.names == #["Pkg.𝒜.a", "Pkg.ﬀ.a"])

#guard theNewFilesSortInUtf16OrderToo

/-- The search index's module subscript indexes **`modules.json`'s** array and
nothing in its own file, so the two are only one answer while they are read
together. A subscript into an array that is no longer beside it is a link to the
wrong page, and every page still validates. -/
def theTwoIndexesAgreeOnWhichModuleDeclaresWhat : Bool :=
  let a := chainArtifacts
  let rows := asArr (fieldOf (parsedObj a.modulesJson) "modules")
  let nameMap := parsedObj a.nameMapJson
  match decodeSearchIndex a.searchIndexBin with
  | none => false
  | some d =>
    -- Every declared name, and the same population `name-map.json` has: a
    -- narrowed index and an empty one would both make the agreement below hold
    -- over nothing.
    d.names.size == (parsedObj a.nameMapJson).size && d.names.size > 0
      && d.names.size == d.kindOf.size && d.names.size == d.modules.size
      && d.kindOf.all (· < d.labels.size)
      && d.modules.all (· < rows.size)
      && (Array.range d.names.size).all fun i =>
          asStr (fieldOf nameMap d.names[i]!)
            == asStr (fieldOf (asObj rows[d.modules[i]!]!) "n")

#guard theTwoIndexesAgreeOnWhichModuleDeclaresWhat

/-- `instances.json`'s two maps: a class to its instances, and a type to the
instances that mention it. The type named twice by one instance is listed once —
doc-gen4 collects each list into an `RBTree`, and the deduplication is that. -/
def theInstanceMapsDeduplicateTheWayDocGen4Does : Bool :=
  chainArtifacts.instancesJson ==
    "{\"instances\":{\"Cls\":[\"Pkg.B.inst\"]},\"instancesFor\":{\"Pkg.a\":[\"Pkg.B.inst\"]}}"

#guard theInstanceMapsDeduplicateTheWayDocGen4Does

/-- Every count is the number of things the file it describes holds. -/
def theCountsAreWhatTheFilesHold : Bool :=
  let a := chainArtifacts
  let instances := parsedObj a.instancesJson
  let usedBy := parsedObj (nameListsJson a.usedByPairs)
  let usedByEdges := a.usedByPairs.foldl (fun acc p => acc + p.2.size) 0
  (decodeSearchIndex a.searchIndexBin).map (·.names.size) == some a.declarations
    && a.instanceClasses == (asObj (fieldOf instances "instances")).size
    && a.instanceTypes == (asObj (fieldOf instances "instancesFor")).size
    && a.dependencyNames == 0
    && a.nameMap.size == a.declarations + a.dependencyNames
    -- `>` and not `≥`: a target with two users is what makes the per-key
    -- deduplication show in a count, and an empty map would let the two below
    -- hold over nothing.
    && usedByEdges > a.usedByTargets && a.usedByTargets > 0
    && a.usedByTargets == usedBy.size
    && usedByEdges == usedBy.foldl (fun acc (_, users) => acc + (asArr users).size) 0

#guard theCountsAreWhatTheFilesHold

end Litedoc4Test

