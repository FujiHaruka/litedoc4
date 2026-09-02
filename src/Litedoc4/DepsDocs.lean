/- Linking a dependency's declarations at
**its own documentation site**, for the names that site was verified to document.

Everything that touches the network is here, and nothing downstream of this file
knows there is a network.

# The rule

A dependency's documentation is built from *a* revision (mathlib4_docs from
`master`; no versioned copy exists (measured 2026-08-19,
`benchmarks/results/deps-link-rot-2026-08-19.txt` §9)) and the manifest pins
*another*, so the two can disagree about whether a name exists:

* the site's declaration table holds the name ⇒ **the docs page**;
* it does not ⇒ **the version-pinned source**;
* the table could not be read at all ⇒ **the version-pinned source for everything
  of that root**, and the run says so on its own line.

There is no "try the docs site and fall back on a 404": a build cannot see a 404,
and avoiding one is the entire reason the source link is pinned.

**`curl` rather than an HTTP client**, which would be a dependency tree with a
TLS implementation under it for one GET per build of an optional feature — so
this shells out as `build` does to `git` and `extract` to `lake`.

**The table is walked, not parsed into a value**: the real one is 66,715,005 B of
JSON with 420,714 declarations and 11,351 modules (measured 2026-08-19), and a
build of the measurement target already peaks near 4 GB. `scanTable` reads it
with the IR's own byte scanner and keeps only the entries a root was asked about;
every other value is stepped over without being built. What would falsify the
choice not to build a `JVal`: a table small enough that one pass costs nothing,
which the one this exists for is not. -/
import Std.Data.HashMap
import Litedoc4.External
import Litedoc4.Fs
import Litedoc4.Ir
import Litedoc4.Ir.Utf16
import Litedoc4.JsonWrite

open System

namespace Litedoc4

/-- Where doc-gen4 writes the declaration table under a site's root. The
extension says `bmp` and the bytes are JSON; that is the other side's choice and
copying it is how the default finds the file. -/
def defaultDeclarationIndex : String := "declarations/declaration-data.bmp"

/-- An `IO.Error` names the file on a second line, and these messages are folded
into a one-line `deps` report that already names it. Nothing downstream can
render a newline. -/
def firstLine (message : String) : String :=
  (message.splitOn "\n").headD message

/-- The handshake only: 5.7 MB gzipped (measured) over a slow link is a long
download and a correct one. This catches a host that never answers. -/
def curlConnectTimeout : String := "10"

/-- The whole transfer, which `--connect-timeout` does not bound — a stalled one
would hang the build with no output. Not a tuning knob: the measured fetch of
mathlib4_docs' table is 0.63 s (measured 2026-08-19,
`benchmarks/results/deps-link-rot-2026-08-19.txt`), so anything near this is a
link that is never going to finish. -/
def curlMaxTime : String := "120"

/-- Where a declaration table is read from. The local path is not a testing
convenience: it is what makes the feature usable from a machine with no outbound
network.

`http://` and `https://` are URLs; everything else is a path. A scheme this
cannot fetch (`ftp://`, `file://`) is handed to `curl` as a path and fails to
open with its own name in the message, which is the right amount of guessing to
do. -/
inductive TableSource where
  | url (u : String)
  | file (p : String)
  deriving Inhabited

def TableSource.parse (value : String) : TableSource :=
  if value.startsWith "https://" || value.startsWith "http://" then .url value else .file value

def TableSource.describe : TableSource → String
  | .url u => u
  | .file p => p

structure DocsSite where
  root : String
  base : String
  index : TableSource
  deriving Inhabited

def splitRootValue (raw flag : String) : Except (UInt32 × String) (String × String) := Id.run do
  let wrong : Except (UInt32 × String) (String × String) :=
    .error (2, s!"{flag} wants <Root>=<value>, not `{raw}`: the root is the module name's first \
      component, as `litedoc4 links` prints it")
  let n := raw.utf8ByteSize
  let mut i := 0
  while i < n && byteAt raw i != 61 do
    i := i + 1
  if i >= n || i == 0 then return wrong
  return .ok (byteSub raw 0 i, byteSub raw (i + 1) n)

/-- Repeats and an index for a root with no site are refused rather than
resolved: both are a caller saying two things about one root, and picking one of
them is how a build links somewhere nobody asked for. -/
def parseDocsSites (urls indexes : Array String) :
    Except (UInt32 × String) (Array DocsSite) := Id.run do
  let mut sites : Array DocsSite := #[]
  for raw in urls do
    match splitRootValue raw "--deps-docs-url" with
    | .error e => return .error e
    | .ok (root, base) =>
      if base.isEmpty then
        return .error (2, s!"--deps-docs-url {root}= has no URL: the site's own root is what a \
          docLink is joined onto, and an empty one would produce an absolute path on whatever \
          host serves this site")
      if sites.any (·.root == root) then
        return .error (2, s!"--deps-docs-url names `{root}` twice: a root has one documentation \
          site, and taking either of two would be this command choosing which links the site gets")
      sites := sites.push
        { root, base
          index := TableSource.parse (trimTrailingSlash base ++ "/" ++ defaultDeclarationIndex) }
  for raw in indexes do
    match splitRootValue raw "--deps-docs-index" with
    | .error e => return .error e
    | .ok (root, value) =>
      match sites.findIdx? (·.root == root) with
      | none =>
        return .error (2, s!"--deps-docs-index {root}=… without --deps-docs-url {root}=…: this \
          flag says where a site's declaration table is, and there is no site for `{root}` to \
          have one")
      | some i => sites := sites.set! i { sites[i]! with index := TableSource.parse value }
  return .ok sites

/-- Refused before anything is written, and refused rather than warned about: a
run that quietly linked nowhere would print the line a table that came out empty
prints. -/
def checkDocsRoots (sites : Array DocsSite) (links : ExternalLinks) :
    Except (UInt32 × String) Unit := Id.run do
  for site in sites do
    if links.sourceFor site.root != .absent then continue
    let known := links.roots.toList.map (·.name)
    return .error (3, s!"--deps-docs-url {site.root}=…: `{site.root}` is not a module root of any \
      dependency this package resolves. The roots it does resolve are: \
      {if known.isEmpty then "none — no dependency could be resolved at all, so there is nothing \
        to link" else ", ".intercalate known}. (`litedoc4 links --root <repo>` prints them with \
      their sources.)")
  return .ok ()

structure ResolvedSite where
  root : String
  /-- How many names of this root the IR refers to. Stored in the artifact rather
  than recomputed: `litedoc4 render` has no IR request set of its own and has to
  report the same fact `build` did. -/
  requestedNames : Nat
  docs : DepDocs

/-- Both halves of the rule with their denominators: a line reporting only what
went to the site would make a table that answers nothing look like one that
answers everything. -/
def ResolvedSite.line (s : ResolvedSite) : String :=
  s!"deps    {s.root}: {s.docs.declarations.size}/{s.requestedNames} name(s) and \
    {s.docs.modules.size} module(s) -> {s.docs.base}, \
    {s.requestedNames - s.docs.declarations.size} name(s) not in the table -> version-pinned source"

/-- The printing is here rather than at the two producers so that a run driven by
`--deps-docs-url` and one driven by `--deps-docs-map` report the same fact in the
same words: the second is supposed to reproduce the first. -/
def attachDocs (links : ExternalLinks) (resolved : Array ResolvedSite) : IO ExternalLinks := do
  let mut entries : Array (String × DepDocs) := Array.mkEmpty resolved.size
  for site in resolved do
    IO.println site.line
    entries := entries.push (site.root, site.docs)
  return links.withDocs entries

/-! ## The request set -/

/-- Every name in the IR's dependency slices whose **defining module** is under
one of `roots` — bucketed by the defining module rather than by which
`deps/<Package>.json` the name was in, because that is the question the renderer
asks: `ExternalLinks.docsUrlFor` finds the root from the module the IR says a
name lives in, so a name filed under one package and defined in another root's
module would otherwise be looked for in a site that was never asked about it. -/
def wantedNames (ir : FilePath) (roots : Array String) :
    IO (Std.HashMap String String) := do
  let tree ← openIrTree ir
  let mut names : Std.HashMap String String := Std.HashMap.emptyWithCapacity 1024
  for slice in ← tree.loadDepMaps do
    for (name, module) in slice do
      if let some root := (moduleComponents module)[0]? then
        if roots.contains root then names := names.insert name root
  return names

def wantedCount (names : Std.HashMap String String) (root : String) : Nat := Id.run do
  let mut n := 0
  for (_, owner) in names do
    if owner == root then n := n + 1
  return n

/-! ## Reading a declaration table -/

/-- The machine cannot fetch at all, or the table itself is not there, not
served, or not the shape it has to be. The first is refused by name, as a missing
`git` is; the second costs that site and nothing else. -/
inductive TableProblem where
  | missing (why : String)
  | unreadable (why : String)

structure FoundTable where
  /-- root -> name -> `docLink`. -/
  declarations : Std.HashMap String (Array (String × String)) := {}
  /-- root -> module -> `url`. -/
  modules : Std.HashMap String (Array (String × String)) := {}
  deriving Inhabited

namespace TableScan

open JScan

/-- Steps over one value without building it. The counterpart of serde's
`IgnoredAny`, and the reason a 66 MB table does not become a 66 MB tree. -/
partial def skipVal (s : String) (n i : Nat) : Nat :=
  if i >= n then n
  else
    let c := byteAt s i
    if c == 34 then (scanStrEnd s n (i + 1) false).1 + 1
    else if c == 123 || c == 91 then
      let close : UInt8 := if c == 123 then 125 else 93
      skipContainer s n (i + 1) close
    else if isLit s n i "true" then i + 4
    else if isLit s n i "false" then i + 5
    else if isLit s n i "null" then i + 4
    else realEnd s n (if c == 45 then i + 1 else i)
where
  /-- An object's members are `"key": value` and an array's are values, so the
  two cannot share one step: skipping an object's key and then looking for `,`
  lands on the `:`. -/
  skipContainer (s : String) (n i : Nat) (close : UInt8) : Nat :=
    let i := skipWs s n i
    if i >= n then n
    else if byteAt s i == close then i + 1
    else
      let i :=
        if close == 125 then
          let k := skipWs s n (skipVal s n i)
          if k < n && byteAt s k == 58 then skipVal s n (skipWs s n (k + 1)) else n
        else skipVal s n i
      let i := skipWs s n i
      if i < n && byteAt s i == 44 then skipContainer s n (skipWs s n (i + 1)) close
      else if i < n && byteAt s i == close then i + 1
      else n

/-- The one string field of a table entry, with every other key stepped over.
Unknown keys are skipped rather than refused, because the table gains them and a
reader that broke on a new one would break on the day mathlib4_docs adds a
field. -/
partial def entryField (s : String) (n i : Nat) (key : String) :
    Except String (String × Nat) :=
  let i := skipWs s n i
  if i >= n || byteAt s i != 123 then
    .error s!"an entry at {i} is not an object"
  else
    let rec loop (i : Nat) (found : Option String) : Except String (String × Nat) :=
      let i := skipWs s n i
      if i >= n then .error "an entry is not closed before the end of the table"
      else if byteAt s i == 125 then
        match found with
        | some v => .ok (v, i + 1)
        | none => .error s!"an entry has no `{key}` string"
      else if byteAt s i != 34 then .error s!"an entry wanted a key at {i}"
      else
        let (k, j) := readStr s n (i + 1)
        let j := skipWs s n j
        if j >= n || byteAt s j != 58 then .error s!"the key `{k}` wanted `:` at {j}"
        else
          let j := skipWs s n (j + 1)
          if k == key && j < n && byteAt s j == 34 then
            let (v, j) := readStr s n (j + 1)
            let j := skipWs s n j
            if j < n && byteAt s j == 44 then loop (j + 1) (some v)
            else if j < n && byteAt s j == 125 then .ok (v, j + 1)
            else .error s!"an entry wanted `,` or `}` at {j}"
          else if k == key then .error s!"an entry's `{key}` is not a string"
          else
            let j := skipVal s n j
            let j := skipWs s n j
            if j < n && byteAt s j == 44 then loop (j + 1) found
            else if j < n && byteAt s j == 125 then
              match found with
              | some v => .ok (v, j + 1)
              | none => .error s!"an entry has no `{key}` string"
            else .error s!"an entry wanted `,` or `}` at {j}"
    loop (i + 1) none

/-- One `name -> entry` section. A declaration is answered by the root that
defines it *according to this run's IR*; a module by its own first component,
since there is nothing else it could belong to. -/
partial def section_ (s : String) (n i : Nat) (declarations : Bool)
    (want : Std.HashMap String String) (roots : Array String)
    (acc : Std.HashMap String (Array (String × String))) :
    Except String (Std.HashMap String (Array (String × String)) × Nat) :=
  let i := skipWs s n i
  if i >= n || byteAt s i != 123 then .error s!"a section at {i} is not an object"
  else
    let key := if declarations then "docLink" else "url"
    let rec loop (i : Nat) (acc : Std.HashMap String (Array (String × String))) :
        Except String (Std.HashMap String (Array (String × String)) × Nat) :=
      let i := skipWs s n i
      if i >= n then .error "a section is not closed before the end of the table"
      else if byteAt s i == 125 then .ok (acc, i + 1)
      else if byteAt s i != 34 then .error s!"a section wanted a name at {i}"
      else
        let (name, j) := readStr s n (i + 1)
        let j := skipWs s n j
        if j >= n || byteAt s j != 58 then .error s!"the name `{name}` wanted `:` at {j}"
        else
          let owner :=
            if declarations then want[name]?
            else
              -- `[0]?`, not `[0]!`: these keys are the *table's*, so an empty one
              -- is input rather than a broken invariant.
              match (moduleComponents name)[0]? with
              | some root => if roots.contains root then some root else none
              | none => none
          match owner with
          | none =>
            let j := skipVal s n (skipWs s n (j + 1))
            let j := skipWs s n j
            if j < n && byteAt s j == 44 then loop (j + 1) acc
            else if j < n && byteAt s j == 125 then .ok (acc, j + 1)
            else .error s!"a section wanted `,` or `}` at {j}"
          | some root =>
            match entryField s n (j + 1) key with
            | .error why => .error why
            | .ok (link, j) =>
              let acc := acc.insert root ((acc.getD root #[]).push (name, link))
              let j := skipWs s n j
              if j < n && byteAt s j == 44 then loop (j + 1) acc
              else if j < n && byteAt s j == 125 then .ok (acc, j + 1)
              else .error s!"a section wanted `,` or `}` at {j}"
    loop (i + 1) acc

end TableScan

/-- `{"declarations": {...}, "modules": {...}, …}` — the two sections that are
read, and every other key skipped. Both are required: a table with no
`declarations` is a file of some other shape, not a table with nothing in it. -/
partial def scanTable (text : String) (want : Std.HashMap String String) (roots : Array String) :
    Except String FoundTable :=
  let n := text.utf8ByteSize
  let i := JScan.skipWs text n 0
  if i >= n || byteAt text i != 123 then
    .error "the table is not a JSON object"
  else
    let rec loop (i : Nat) (found : FoundTable) (sawDecls sawModules : Bool) :
        Except String FoundTable :=
      let i := JScan.skipWs text n i
      if i >= n then .error "the table is not closed before the end of the file"
      else if byteAt text i == 125 then
        if !sawDecls then
          .error "no `declarations` object: this is not a doc-gen4 declaration table, and reading \
            one that is missing a half would report names as absent when they were never looked for"
        else if !sawModules then
          .error "no `modules` object: this is not a doc-gen4 declaration table, and reading one \
            that is missing a half would report names as absent when they were never looked for"
        else .ok found
      else if byteAt text i != 34 then .error s!"the table wanted a key at {i}"
      else
        let (k, j) := JScan.readStr text n (i + 1)
        let j := JScan.skipWs text n j
        if j >= n || byteAt text j != 58 then .error s!"the key `{k}` wanted `:` at {j}"
        else
          let j := JScan.skipWs text n (j + 1)
          let step (next : Nat) (found : FoundTable) (d m : Bool) : Except String FoundTable :=
            let next := JScan.skipWs text n next
            if next < n && byteAt text next == 44 then loop (next + 1) found d m
            else if next < n && byteAt text next == 125 then
              loop next found d m
            else .error s!"the table wanted `,` or `}` at {next}"
          if k == "declarations" then
            match TableScan.section_ text n j true want roots found.declarations with
            | .error why => .error why
            | .ok (declarations, next) => step next { found with declarations } true sawModules
          else if k == "modules" then
            match TableScan.section_ text n j false want roots found.modules with
            | .error why => .error why
            | .ok (modules, next) => step next { found with modules } sawDecls true
          else step (TableScan.skipVal text n j) found sawDecls sawModules
    loop (i + 1) {} false false

/-- `curl`, whose exit code is read **before** any parse error is believed: a
failed request produces an empty body, so a parser looking at it fails first with
"the table is not a JSON object" — true and useless. -/
def fetchTable (url : String) : IO (Except TableProblem String) := do
  let args := #["--fail", "--silent", "--show-error", "--location", "--compressed",
    "--connect-timeout", curlConnectTimeout, "--max-time", curlMaxTime, url]
  match ← (IO.Process.output { cmd := "curl", args }).toBaseIO with
  | .error e =>
    -- The message names `curl` either way, so a machine without it is told what
    -- to install rather than shown an errno.
    return .error (.missing s!"curl is not on PATH, and --deps-docs-url needs it to read {url}: \
      the declaration table is fetched by running `curl`, the way this command runs `git` for \
      --source-url and `lake` for the extraction. Install curl, or pass --deps-docs-index \
      <Root>=<path> to read a table from disk ({e})")
  | .ok out =>
    if out.exitCode != 0 then
      let said := trimWs out.stderr
      return .error (.unreadable
        (if said.isEmpty then s!"curl exited {out.exitCode}" else said))
    return .ok out.stdout

def readTable (source : TableSource) : IO (Except TableProblem String) := do
  match source with
  | .file path =>
    -- A path that is not there is `unreadable`, not `missing`: the machine is
    -- fine and the file the caller named is not, which is the same state a 404
    -- is and takes the same answer.
    match ← (IO.FS.readFile ⟨path⟩).toBaseIO with
    | .error e => return .error (.unreadable (firstLine (toString e)))
    | .ok text => return .ok text
  | .url url => fetchTable url

/-! ## The resolved map -/

def depsDocsMapVersion : Nat := 1

def depsDocsMapJson (resolved : Array ResolvedSite) : String := Id.run do
  let mut o := "{\"tool\":\"litedoc4 deps-docs\",\"version\":" ++ toString depsDocsMapVersion
    ++ ",\"roots\":["
  let mut firstRoot := true
  for site in resolved do
    if !firstRoot then o := o.push ','
    firstRoot := false
    o := jsonStr (o ++ "{\"root\":") site.root
    o := jsonStr (o ++ ",\"base\":") site.docs.base
    o := o ++ s!",\"requestedNames\":{site.requestedNames}"
    for (label, pairs) in [("declarations", site.docs.declarations),
        ("modules", site.docs.modules)] do
      o := o ++ ",\"" ++ label ++ "\":{"
      let mut first := true
      for (name, link) in pairs do
        if !first then o := o.push ','
        first := false
        o := jsonStr (jsonStr o name ++ ":") link
      o := o.push '}'
    o := o.push '}'
  return o ++ "]}\n"

/-- Every shape that is not this one is refused by name rather than read as far
as it goes: this file decides where a third of a page's links point, and a
partial read would move some of them and not others with nothing in the output to
say which.

`path` is carried only to name the file in a refusal; nothing here opens it. -/
def parseDepsDocsMap (path : FilePath) (text : String) :
    Except (UInt32 × String) (Array ResolvedSite) := Id.run do
  let refuse (why : String) : Except (UInt32 × String) (Array ResolvedSite) :=
    .error (3, s!"{path}: {why}")
  let record ← match parseJson text with
    | .error why => return refuse why
    | .ok record => pure record
  let version := match jvalGet? record "version" with
    | some (.num v) => some v.toNat
    | _ => none
  if version != some depsDocsMapVersion then
    return refuse s!"resolved documentation map version \
      {match version with | none => "absent" | some v => toString v}, and this build reads version \
      {depsDocsMapVersion}. Rebuild it with `litedoc4 build --deps-docs-url …`"
  let some (.arr roots) := jvalGet? record "roots" | return refuse "no `roots` array"
  let mut resolved : Array ResolvedSite := Array.mkEmpty roots.size
  for site in roots do
    let field (name : String) : Except (UInt32 × String) String :=
      match jvalGet? site name with
      | some (.str s) => .ok s
      | _ => .error (3, s!"{path}: a root with no `{name}` string")
    let entries (name : String) : Except (UInt32 × String) (Array (String × String)) := Id.run do
      let some (.obj pairs) := jvalGet? site name
        | return .error (3, s!"{path}: a root with no `{name}` object")
      let mut out : Array (String × String) := Array.mkEmpty pairs.size
      for (key, value) in pairs do
        match value with
        | .str link => out := out.push (key, link)
        | _ => return .error (3, s!"{path}: `{name}.{key}` is not a string")
      return .ok out
    let number (name : String) : Except (UInt32 × String) Nat :=
      match jvalGet? site name with
      | some (.num v) => .ok v.toNat
      | _ => .error (3, s!"{path}: a root with no `{name}` number")
    let entry : Except (UInt32 × String) ResolvedSite := do
      let root ← field "root"
      let base ← field "base"
      let requested ← number "requestedNames"
      let declarations ← entries "declarations"
      let modules ← entries "modules"
      return { root, requestedNames := requested
               docs := mkDepDocs base declarations modules }
    match entry with
    | .error e => return .error e
    | .ok entry => resolved := resolved.push entry
  return .ok resolved

def readDepsDocsMap (path : FilePath) : IO (Except (UInt32 × String) (Array ResolvedSite)) := do
  match ← (IO.FS.readFile path).toBaseIO with
  | .error e =>
    return .error (3, s!"{path}: {firstLine (toString e)}. \
      `litedoc4 build --deps-docs-url …` writes it")
  | .ok text => return parseDepsDocsMap path text

/-- A site whose table will not read costs that site and nothing else: the map
comes back without it, which is a *different digest* from a run that read it, so
the ledger cannot record a half-applied feature as up to date.

One pass per **table**, not per root: mathlib4_docs documents `Init` and `Lean`
as well as `Mathlib`, so two roots pointed at one site read one file. Grouped by
the index's spelling, which is what a caller controls. -/
def resolveDocs (sites : Array DocsSite) (ir : FilePath) (mapOut : Option FilePath) :
    IO (Except (UInt32 × String) (Array ResolvedSite)) := do
  if sites.isEmpty then return .ok #[]
  let roots := sites.map (·.root)
  let want ← wantedNames ir roots
  let mut indexes : Array String := #[]
  for site in sites do
    let spelling := site.index.describe
    if !indexes.contains spelling then indexes := indexes.push spelling
  -- Byte order over the index's spelling, which is `BTreeMap`'s: the resolved
  -- map's root order is a function of the command line and not of a hash seed.
  let mut resolved : Array ResolvedSite := #[]
  for spelling in indexes.qsort byteLt do
    let group := sites.filter (·.index.describe == spelling)
    let asked := group.map (·.root)
    let found ← match ← readTable group[0]!.index with
      | .error (.missing why) => return .error (3, why)
      | .error (.unreadable why) => do
        for site in group do
          IO.println s!"deps    {site.root}: the declaration table could not be read, so every \
            link -> version-pinned source ({spelling}: {why})"
        continue
      | .ok text =>
        match scanTable text want asked with
        | .error why => do
          for site in group do
            IO.println s!"deps    {site.root}: the declaration table could not be read, so every \
              link -> version-pinned source ({spelling}: {why})"
          continue
        | .ok found => pure found
    for site in group do
      resolved := resolved.push
        { root := site.root, requestedNames := wantedCount want site.root
          docs := mkDepDocs site.base (found.declarations.getD site.root #[])
            (found.modules.getD site.root #[]) }
  if let some path := mapOut then writeFile path (depsDocsMapJson resolved)
  return .ok resolved

/-- `--deps-docs-map` folded into a map that was resolved from a package, for the
four commands that read the artifact rather than write it. -/
def withDependencyDocs (links : ExternalLinks) (map : Option FilePath) :
    IO (Except (UInt32 × String) ExternalLinks) := do
  let some path := map | return .ok links
  match ← readDepsDocsMap path with
  | .error e => return .error e
  | .ok resolved => return .ok (← attachDocs links resolved)

end Litedoc4
