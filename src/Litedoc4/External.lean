/- `crates/litedoc4-render/src/external.rs`: where a dependency's source lives.

An empty `base` is a value and not a missing entry: it says "this root belongs to
a dependency and there is no version-pinned URL for it", which `linkTo` turns
into no link rather than into a relative one to a page this site never writes. -/
import Litedoc4.Ir.Name
import Litedoc4.Sha256

namespace Litedoc4

def trimTrailingSlash (s : String) : String := Id.run do
  let mut n := s.utf8ByteSize
  while n > 0 && byteAt s (n - 1) == 47 do
    n := n - 1
  return byteSub s 0 n

/-- A `docLink` as the table writes it — `./Mathlib/Order/Basic.html#Foo.bar` —
with the leading `./` removed so that it can be joined onto a base. A leading `/`
goes too: joined onto `https://host/mathlib4_docs` it would otherwise resolve at
the host's root, which is a different site. -/
def stripDocLink (link : String) : String :=
  let link := if link.startsWith "./" then (link.drop 2).toString else link
  if link.startsWith "/" then (link.drop 1).toString else link

/-- Sorted by name, byte order, with a repeated name keeping the **last** — the
reading `BTreeMap` gives, so that a table that names one declaration twice
resolves the same way on both sides. -/
def sortedPairs (raw : Array (String × String)) : Array (String × String) := Id.run do
  let sorted := raw.qsort (fun a b => byteLt a.1 b.1)
  let mut out : Array (String × String) := Array.mkEmpty sorted.size
  for pair in sorted do
    if let some last := out.back? then
      if last.1 == pair.1 then
        out := out.pop.push pair
        continue
    out := out.push pair
  return out

/-- Binary search over `sortedPairs`' order. -/
def lookupSorted (pairs : Array (String × String)) (key : String) : Option String := Id.run do
  let mut lo := 0
  let mut hi := pairs.size
  while lo < hi do
    let mid := (lo + hi) / 2
    let (k, v) := pairs[mid]!
    if k == key then return some v
    else if byteLt k key then lo := mid + 1
    else hi := mid
  return none

/-- A dependency's **already-rendered documentation**, and the names that were
verified to be on it.

The two maps are the site's own declaration table, cut down to what this run can
ask about. Their values are `docLink`s **as the table wrote them**, with the
leading `./` removed and nothing else changed: reconstructing the path from a
module name would be this side guessing at the other side's layout, which
`moduleSourceUrl` may do only because a checkout's layout *is* the module name.

Sorted rather than hashed for one reason that is not lookup speed:
`ExternalLinks.canonical` hashes these entries, so their order has to be a
function of the entries and not of how they were inserted. -/
structure DepDocs where
  base : String
  declarations : Array (String × String)
  modules : Array (String × String)
  deriving Inhabited

/-- Both maps are keyed by **full name** — `Mathlib.Order.Basic` is a key of
`modules` and `Nat.add_comm` a key of `declarations` — and their values are
stripped here rather than at either call site, so that the table reader and the
resolved-map reader cannot disagree about what a `docLink` means. -/
def mkDepDocs (base : String) (declarations modules : Array (String × String)) : DepDocs :=
  let entries (raw : Array (String × String)) :=
    sortedPairs (raw.map (fun (name, link) => (name, stripDocLink link)))
  -- A trailing slash would produce `…/mathlib4_docs//Mathlib/…`.
  { base := trimTrailingSlash base, declarations := entries declarations
    modules := entries modules }

/-- An empty base would produce `/Mathlib/Order/Basic.html`, an absolute path on
whatever host serves *this* site. A caller is expected to have refused it
already; this makes the failure a missing link rather than a wrong one if one
ever gets through. -/
def DepDocs.url (d : DepDocs) (link : String) : Option String :=
  if d.base.isEmpty then none else some (d.base ++ "/" ++ link)

/-- `none` means "not on that site", and the caller falls back to the
version-pinned source rather than to a guess. -/
def DepDocs.urlForName (d : DepDocs) (name : String) : Option String :=
  (lookupSorted d.declarations name).bind d.url

def DepDocs.urlForModule (d : DepDocs) (module : String) : Option String :=
  (lookupSorted d.modules module).bind d.url

structure ExternalRoot where
  name : String
  base : String
  /-- The dependency's own documentation site, when one was resolved and
  verified. **`none` is also what "the table could not be read" looks like**: the
  resolver drops the whole site rather than carrying a half-read one, so every
  name of that root takes the version-pinned source. -/
  docs : Option DepDocs := none
  deriving Inhabited

structure ExternalLinks where
  roots : Array ExternalRoot := #[]
  deriving Inhabited

/-- First-wins on a repeated root, because the caller orders the entries by
authority: core's four roots are not a package's to redefine. -/
def mkExternalLinks (entries : Array (String × String)) : ExternalLinks := Id.run do
  let mut roots : Array ExternalRoot := Array.mkEmpty entries.size
  for (name, base) in entries do
    let mut seen := false
    for r in roots do
      if r.name == name then seen := true
    if seen then continue
    roots := roots.push { name, base := trimTrailingSlash base }
  return { roots }

/-- `some ""` is a third state: a root known to be a dependency's with no prefix
for it. `urlFor` folds it into `none`; `linkTo` is the one caller that has to
tell it from this package's own module, and asks this. -/
def ExternalLinks.baseFor (m : ExternalLinks) (root : String) : Option String := Id.run do
  for r in m.roots do
    if r.name == root then return some r.base
  return none

/-- `getSourceUrl` for a module: a prefix, the module's components as
directories, and `.lean`. The prefix is configuration — `--source-url` for this
package's own pages, a dependency's `…/blob/<rev>` for everything else — and
the two callers share this so that the page's own source link and the links into
it cannot end up spelled apart. -/
def moduleSourceUrl (base module : String) : String := Id.run do
  let mut out := base
  for part in moduleComponents module do
    out := out ++ "/" ++ part
  return out ++ ".lean"

/-- The bytes the digest is taken over: a marker line, then one `<root>\t<base>\n`
per entry sorted by root — and then, only when some root publishes
documentation, the docs marker and a section per such root. Sorted rather than in
resolution order because the roots are unique, so two maps that resolve every
module alike have to hash alike whatever order they were built in.

The docs marker's **absence** keeps a map with no documentation site hashing to
the bytes it hashed to before that state existed, so turning the feature on moves
the key rather than leaving pages that link elsewhere looking up to date. A
section is `<root>\t<base>\t<n>\t<m>\n` and then its `n` declarations and `m`
modules, one `<name>\t<link>\n` each; the counts are there so that the
concatenation cannot be read two ways. -/
def ExternalLinks.canonical (m : ExternalLinks) : String := Id.run do
  let sorted := m.roots.qsort (fun a b => byteLt a.name b.name)
  let mut out := "litedoc4 external-links v1\n"
  for r in sorted do
    out := out ++ r.name ++ "\t" ++ r.base ++ "\n"
  if sorted.all (·.docs.isNone) then return out
  out := out ++ "litedoc4 external-links docs v1\n"
  for r in sorted do
    if let some docs := r.docs then
      out := out ++ r.name ++ "\t" ++ docs.base ++ "\t" ++ toString docs.declarations.size
        ++ "\t" ++ toString docs.modules.size ++ "\n"
      for (name, link) in docs.declarations ++ docs.modules do
        out := out ++ name ++ "\t" ++ link ++ "\n"
  return out

def ExternalLinks.digest (m : ExternalLinks) : String := sha256Text m.canonical

/-- **A root this map does not hold is added with an empty base** — the third
state, and the honest reading: the caller has just said the root belongs to a
dependency, so a name in it the docs site does not document must get *no* link
rather than a relative one to a page this site never writes. A repeated root
keeps the first, as `mkExternalLinks` does. -/
def ExternalLinks.withDocs (m : ExternalLinks) (docs : Array (String × DepDocs)) :
    ExternalLinks := Id.run do
  let mut roots := m.roots
  for (root, site) in docs do
    match roots.findIdx? (·.name == root) with
    | some i => if roots[i]!.docs.isNone then roots := roots.set! i { roots[i]! with docs := site }
    | none => roots := roots.push { name := root, base := "", docs := some site }
  return { roots }

def ExternalLinks.docsFor (m : ExternalLinks) (root : String) : Option DepDocs := Id.run do
  for r in m.roots do
    if r.name == root then return r.docs
  return none

/-- The root is `module`'s first component, unescaped, as `urlFor` reads it — but
the *name* is the key, because the table is a name -> page map and the whole
point of consulting it is that it knows where a name lives now. -/
def ExternalLinks.docsUrlFor (m : ExternalLinks) (module : String) (anchor : Option String) :
    Option String :=
  match m.docsFor (moduleComponents module)[0]! with
  | none => none
  | some docs =>
    match anchor with
    | some name => docs.urlForName name
    | none => docs.urlForModule module

def ExternalLinks.urlFor (m : ExternalLinks) (module : String) (lines : Option (Nat × Nat)) :
    Option String :=
  match m.baseFor (moduleComponents module)[0]! with
  | none => none
  | some base =>
    if base.isEmpty then none
    else
      let url := moduleSourceUrl base module
      match lines with
      | some (a, b) => some (url ++ "#L" ++ toString a ++ "-L" ++ toString b)
      | none => some url

end Litedoc4
