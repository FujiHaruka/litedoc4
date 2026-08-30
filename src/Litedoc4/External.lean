/- `crates/litedoc4-render/src/external.rs`: where a dependency's source lives.

An empty `base` is a value and not a missing entry: it says "this root belongs to
a dependency and there is no version-pinned URL for it", which `linkTo` turns
into no link rather than into a relative one to a page this site never writes. -/
import Litedoc4.Ir.Name
import Litedoc4.Sha256

namespace Litedoc4

structure ExternalRoot where
  name : String
  base : String
  deriving Inhabited

structure ExternalLinks where
  roots : Array ExternalRoot := #[]
  deriving Inhabited

def trimTrailingSlash (s : String) : String := Id.run do
  let mut n := s.utf8ByteSize
  while n > 0 && byteAt s (n - 1) == 47 do
    n := n - 1
  return byteSub s 0 n

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
per entry sorted by root. Sorted rather than in resolution order because the
roots are unique, so two maps that resolve every module alike have to hash
alike whatever order they were built in. -/
def ExternalLinks.canonical (m : ExternalLinks) : String := Id.run do
  let mut out := "litedoc4 external-links v1\n"
  for r in m.roots.qsort (fun a b => byteLt a.name b.name) do
    out := out ++ r.name ++ "\t" ++ r.base ++ "\n"
  return out

def ExternalLinks.digest (m : ExternalLinks) : String := sha256Text m.canonical

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
