/- `crates/litedoc4/src/deps_docs.rs`: reading a dependency's own doc-gen4
declaration table, and the resolved map `build` writes for the commands that
render without one.

The table scan and the map are both text in and a value out, so what is left in
`IO` is one `readFile` each — `parseDepsDocsMap` was split out of
`readDepsDocsMap` for exactly that reason and the round trip below is compile
time because of it.

The refusals (`a_table_of_another_shape_is_refused_by_name`,
`a_module_entry_with_no_url_is_refused`, `a_resolved_map_of_another_shape_is_refused`,
`a_flag_that_says_two_things_about_one_root_is_refused`) are not here: every one
of them is reachable from the command line and belongs to a refusal gate. -/
import Litedoc4.DepsDocs
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4 System

/-- doc-gen4's `JsonIndex` (`DocGen4/Output/ToJson.lean`: `declarations`,
`instances`, `modules`, `instancesFor`, a module's link under `url` and a
declaration's under `docLink`). Seven entries, so that every branch of the rule
has a witness: a name asked for and present, one present and not asked for, one
asked for and absent, and a root that was never asked about. -/
def declarationTable : String :=
"{
  \"declarations\": {
    \"Dep.wanted\": { \"kind\": \"def\", \"docLink\": \"./Dep/Home.html#Dep.wanted\" },
    \"Dep.unwanted\": { \"kind\": \"theorem\", \"docLink\": \"./Dep/Home.html#Dep.unwanted\" },
    \"Dep.elsewhere\": { \"kind\": \"def\", \"docLink\": \"./Dep/Home.html#Dep.elsewhere\" },
    \"Other.thing\": { \"kind\": \"def\", \"docLink\": \"./Other/Elsewhere.html#Other.thing\" }
  },
  \"instances\": {
    \"Dep.Cls\": [\"Dep.inst\"]
  },
  \"modules\": {
    \"Dep\": { \"importedBy\": [], \"url\": \"./Dep.html\" },
    \"Dep.Home\": { \"importedBy\": [\"Dep\"], \"url\": \"./Dep/Home.html\" },
    \"Other.Elsewhere\": { \"importedBy\": [], \"url\": \"./Other/Elsewhere.html\" }
  },
  \"instancesFor\": {
    \"Dep.Ty\": [\"Dep.inst\"]
  }
}
"

def wantNames (pairs : Array (String × String)) : Std.HashMap String String :=
  pairs.foldl (fun m (name, root) => m.insert name root) {}

def scanned (want : Array (String × String)) (roots : Array String) :
    Except String FoundTable :=
  scanTable declarationTable (wantNames want) roots

def sectionOf (t : FoundTable) (declarations : Bool) (root : String) : Array (String × String) :=
  (if declarations then t.declarations else t.modules).getD root #[]

/-- A table read for no root keeps nothing at all — the state
`litedoc4 build --deps-docs-map` is in before any root has resolved — and the
file is full of names either way, so this is the filter answering rather than
the fixture being small.

The second half is the asymmetry the two sections are filtered by: a declaration
is kept because **this run's IR** says which root defines it, a module because
its own first component names one. Asking for the root and for none of its names
therefore keeps the modules and no declarations, which a reader who assumed one
filter for both would have backwards. -/
def aTableReadForNoRootKeepsNothing : Bool :=
  match scanned #[] #[], scanned #[] #["Dep"] with
  | .ok nothing, .ok rootOnly =>
    nothing.declarations.isEmpty && nothing.modules.isEmpty
      && rootOnly.declarations.isEmpty
      && (sectionOf rootOnly false "Dep").size == 2
      && !rootOnly.modules.contains "Other"
  | _, _ => false

#guard aTableReadForNoRootKeepsNothing

/-- `instances` and `instancesFor` are stepped over rather than read, and an
unknown key would be too: mathlib4_docs gains fields, and a reader that broke on
a new one would break on the day it does. The counts are what says the skipping
landed in the right place — a scan that lost its position inside `instances`
would come back with the sections short. -/
def theSectionsThisDoesNotReadAreSkipped : Bool :=
  match scanned #[("Dep.wanted", "Dep")] #["Dep"] with
  | .ok t =>
    (sectionOf t true "Dep") == #[("Dep.wanted", "./Dep/Home.html#Dep.wanted")]
      && (sectionOf t false "Dep")
        == #[("Dep", "./Dep.html"), ("Dep.Home", "./Dep/Home.html")]
      && !t.declarations.contains "Other"
  | _ => false

#guard theSectionsThisDoesNotReadAreSkipped

/-- The default index is the site's own table under the URL it was given, and an
override may be a local path — which is not a testing convenience but what makes
the feature usable from a machine with no outbound network. -/
def theIndexDefaultsToTheSitesOwnTableAndAnOverrideMayBeALocalFile : Bool :=
  let describe (urls indexes : Array String) : Option (String × String) :=
    match parseDocsSites urls indexes with
    | .ok sites => sites[0]?.map fun s => (s.base, s.index.describe)
    | .error _ => none
  describe #["Dep=https://host.invalid/docs/"] #[]
      == some ("https://host.invalid/docs/",
               "https://host.invalid/docs/" ++ defaultDeclarationIndex)
    && describe #["Dep=https://host.invalid/docs"] #["Dep=/tmp/table.json"]
      == some ("https://host.invalid/docs", "/tmp/table.json")
    && (match parseDocsSites #["Dep=https://host.invalid/docs"] #["Dep=/tmp/table.json"] with
        | .ok sites => match sites[0]? with
          | some site => match site.index with
            | .file _ => true
            | .url _ => false
          | none => false
        | .error _ => false)

#guard theIndexDefaultsToTheSitesOwnTableAndAnOverrideMayBeALocalFile

def resolvedSample : ResolvedSite :=
  { root := "Dep", requestedNames := 3
    docs := mkDepDocs "https://host.invalid/docs"
      #[("Dep.wanted", "./Dep/Home.html#Dep.wanted")]
      #[("Dep.Home", "./Dep/Home.html"), ("Dep", "./Dep.html")] }

/-- The artifact `build` writes is the one `render`, `site`, `incremental` and
`ledger` read, so a value that did not survive the round trip would move a third
of a page's links on the second command without moving them on the first.

The line is asserted rather than only compared with itself: **a round trip
between two wrong values is also a round trip**, and this one carries both
denominators — a report of only what went to the site would make a table that
answers nothing look like one that answers everything. -/
def theResolvedMapRoundTrips : Bool :=
  match parseDepsDocsMap "deps-docs-map.json" (depsDocsMapJson #[resolvedSample]) with
  | .ok read =>
    read.size == 1 && read.all fun site =>
      site.root == "Dep" && site.requestedNames == 3
        && site.docs.base == resolvedSample.docs.base
        && site.docs.declarations == resolvedSample.docs.declarations
        && site.docs.modules == resolvedSample.docs.modules
        && site.line == resolvedSample.line
        && site.line == "deps    Dep: 1/3 name(s) and 2 module(s) -> \
             https://host.invalid/docs, 2 name(s) not in the table -> version-pinned source"
  | .error _ => false

#guard theResolvedMapRoundTrips

end Litedoc4Test
