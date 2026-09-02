/- The whole-package artifacts.

Rust reconciles `Artifacts::files()` against a second constant `ARTIFACT_PATHS`;
here there is one list and that reconciliation has nothing to compare, so what is
left of it is the shape of the paths themselves.

`chain` takes a flag rather than carrying its descriptions always: a description
is Markdown, `#guard` cannot call the Markdown parser, and everything below that
is *not* about descriptions would otherwise have to be an `Invariant` too. -/
import Litedoc4.Global.Artifacts
import Litedoc4Test.GlobalEntry
import Litedoc4Test.GlobalSearchIndex

namespace Litedoc4Test
open Litedoc4

def artifactPaths : Array String := (artifactFiles default).map (·.1)

/-- Every path is written under the site root by `buildGlobal`, so one that
starts at `/` or climbs out of it writes somewhere nobody asked for, and two that
are equal make the second silently the only one. -/
def theArtifactPathsAreDistinctAndStayUnderTheSite : Bool :=
  artifactPaths.all (fun p => !p.isEmpty && !p.startsWith "/" && !has p "..")
    && (dedupSorted (sortUtf16 artifactPaths)).size == artifactPaths.size

#guard theArtifactPathsAreDistinctAndStayUnderTheSite

/-- The five files that existed only for doc-gen4's JavaScript, named rather than
counted: "nine files came out" would still hold if `navbar.html` came back and
something else went. `declarations/name-map.json` is named for the same reason
from the other side — it is the map delta's `--before` file. -/
def theDocGen4OnlyArtifactsAreGone : Bool :=
  ["declarations/declaration-data.bmp", "navbar.html", "tactics.html", "references.bib",
    "references.html"].all (fun dropped => !artifactPaths.contains dropped)
    && artifactPaths.contains "declarations/name-map.json"

#guard theDocGen4OnlyArtifactsAreGone

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
def chain (described : Bool) : Array ModuleFacts :=
  let root : ModuleFacts :=
    { moduleFacts "Pkg" [] [("Pkg.a", "definition")] with
        summary := if described then some "The `Pkg` root" else none }
  let middle : ModuleFacts :=
    { moduleFacts "Pkg.B" ["Pkg"] [("Pkg.B.inst", "instance"), ("Pkg.dup", "theorem")] with
        -- Says only what the row says, so the two summary counts cannot be
        -- each other.
        summary := if described then some "b" else none
        instances := #[("Cls", "Pkg.B.inst")]
        instancesFor := #[("Pkg.a", "Pkg.B.inst"), ("Pkg.a", "Pkg.B.inst")]
        refs := refsOf [("Pkg.a", [0, 1])] }
  let leaf : ModuleFacts :=
    { moduleFacts "Pkg.C" ["Pkg", "Pkg.B"] [("Pkg.C.t", "theorem"), ("Pkg.dup", "theorem")] with
        refs := refsOf [("Pkg.a", [1]), ("Pkg.B.inst", [0]), ("Dep.outside", [0])] }
  #[root, middle, leaf]

def chainArtifacts : Artifacts := derive (chain false) #[] none none "4.31.0"

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
  let a := derive (chain false)
    #[#[("Dep.one", "Dep.Home"), ("Pkg.a", "Dep.Elsewhere")]] none none "4.31.0"
  a.nameMapJson ==
      "{\"Dep.one\":\"Dep.Home\",\"Pkg.B.inst\":\"Pkg.B\",\"Pkg.C.t\":\"Pkg.C\",\
        \"Pkg.a\":\"Pkg\",\"Pkg.dup\":\"Pkg.C\"}"
    && a.counts.dependencyNames == 2
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
  let a := derive #[declaringOne "Pkg.ﬀ" "Pkg.ﬀ.a", declaringOne "Pkg.𝒜" "Pkg.𝒜.a"]
    #[] none none "4.31.0"
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

/-- **Destructured rather than read field by field**, so a count added to
`Counts` stops this compiling until it is checked here too; a check that named
the fields it reads would go on holding when one was added.

An `Invariant` and not a `#guard` because two of the eight are about the module
descriptions, and reading one means parsing Markdown. -/
def theCountsAreWhatTheFilesHold : Invariant where
  name := "every count is the number of things the file it describes holds"
  check := do
    let a := derive (chain true) #[] none none "4.31.0"
    let ⟨declarations, dependencyNames, instanceClasses, instanceTypes, usedByTargets,
      usedByEdges, summariesRendered, summariesEchoingTheName⟩ := a.counts
    let instances := parsedObj a.instancesJson
    let usedBy := parsedObj a.usedByJson
    let indexed := (decodeSearchIndex a.searchIndexBin).map (·.names.size)
    return first [
      eq indexed (some declarations),
      eq instanceClasses (asObj (fieldOf instances "instances")).size,
      eq instanceTypes (asObj (fieldOf instances "instancesFor")).size,
      eq dependencyNames 0,
      eq a.nameMap.size (declarations + dependencyNames),
      -- The reconciliation e2e-micro's GATE 14 makes over a built site, made
      -- here over the string this stage produced: a renderer that dropped a row
      -- and a count derived from anything but the rows both land here.
      eq summariesRendered (countOf a.indexHtml "class=\"modsummary\""),
      eq (summariesRendered, summariesEchoingTheName) (2, 1),
      -- An empty artifact would let the two below hold with the derivation
      -- counting anything at all; `>` and not `≥` because a target with two
      -- users is what makes the per-key deduplication show in a count.
      if usedByEdges > usedByTargets && usedByTargets > 0 then none
        else some s!"the fixture holds the used-by counts to nothing: \
          {usedByTargets} target(s), {usedByEdges} edge(s)",
      eq usedByTargets usedBy.size,
      eq usedByEdges (usedBy.foldl (fun acc (_, users) => acc + (asArr users).size) 0)]

end Litedoc4Test

