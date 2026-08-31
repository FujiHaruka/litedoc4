/-
Derived from doc-gen4 (Apache-2.0, Copyright (c) 2021 Henrik Böving) by way of
`crates/litedoc4-render/src/autolink.rs`, and changed; see this repository's NOTICE
and `docs/provenance.md`.
-/
import Litedoc4.External
import Litedoc4.Ir
import Litedoc4.Ir.Name
import Litedoc4.Md.Html
import Litedoc4.Render.LinkIndex

namespace Litedoc4

/-! ## Lean name syntax

`isIdFirst` / `isIdRest` and the two ranges under them are `Litedoc4.Ir.Name`'s:
the same tables decide whether a component of a module *name* needs escaping and
whether a character can start an identifier the autolinker will resolve, and two
copies of them are two answers to one question. -/

/-- `Lean.Syntax.decodeNameLit ("`" ++ s)`. The empty string is **not** a name
literal: the autolink splitter hands `""` over routinely, and a resolver that
answered would anchor every double space. -/
def isNameLit (s : String) : Bool := Id.run do
  let n := s.utf8ByteSize
  let mut i := 0
  while true do
    if i >= n then return false
    let c := String.Pos.Raw.get s ⟨i⟩
    let w := c.utf8Size
    let mut after := 0
    if c == '«' then
      let mut j := i + w
      let mut found := false
      while j < n do
        let d := String.Pos.Raw.get s ⟨j⟩
        j := j + d.utf8Size
        if d == '»' then
          after := j
          found := true
          break
      if !found then return false
    else if isIdFirst c then
      let mut j := i + w
      while j < n do
        let d := String.Pos.Raw.get s ⟨j⟩
        if isIdRest d then j := j + d.utf8Size else break
      after := j
    else if '0' ≤ c && c ≤ '9' then
      let mut j := i
      while j < n && byteAt s j >= 48 && byteAt s j <= 57 do
        j := j + 1
      after := j
    else
      return false
    if after >= n then return true
    if byteAt s after == 46 then i := after + 1 else return false
  return false

/-! ## The name index

`known` is the IR's own map (dependency slices, then every declaration, then
every reference that fills a gap); `pages` is the set of modules this run writes
a file for; `knownModules` is the union of the `.lidx`'s `@` section with the
modules `known` names. The three answer different questions and
`crates/litedoc4-render/src/autolink.rs` explains why collapsing them is a dead
link. -/

structure NameIndex where
  known : Std.HashMap String String
  lidx : Lidx
  pages : Std.HashSet String
  knownModules : Std.HashSet String
  /-- The same set as an array, because the source-path branch scans it. -/
  knownModuleArray : Array String
  /-- The **unescaped** spelling of a known module, back to the module — the
  `.lidx`'s spelling of a name the IR quotes, `Dep-Aux.Basic` for
  `«Dep-Aux».Basic`. A map and not `escapeModule` on the query, because
  unescaping is not injective: `«Dep-Aux».Basic` and `«Dep-Aux.Basic»` unescape
  alike, and no rule applied to the query can tell which was meant. Two answers
  is no answer, and the collision is settled here rather than at the lookup. -/
  unescapedModules : Std.HashMap String String
  external : ExternalLinks
  deriving Inhabited

def buildIndex (deps : Array (Array (String × String))) (mods : Array Module)
    (lidx : Lidx) (external : ExternalLinks) : NameIndex := Id.run do
  let mut known : Std.HashMap String String := Std.HashMap.emptyWithCapacity 16384
  for dep in deps do
    for (name, module) in dep do
      known := known.insert name module
  for m in mods do
    for d in m.decls do
      known := known.insert d.name m.name
      for (rmod, rname) in d.refs do
        if !known.contains rname then
          known := known.insert rname rmod
  let mut pages : Std.HashSet String := Std.HashSet.emptyWithCapacity 1024
  for m in mods do
    pages := pages.insert m.name
  let mut knownModules := lidx.modules
  for (_, module) in known.toArray do
    knownModules := knownModules.insert module
  for m in mods do
    knownModules := knownModules.insert m.name
  let knownModuleArray := knownModules.toArray
  let mut claimed : Std.HashMap String (Option String) := Std.HashMap.emptyWithCapacity 16
  for module in knownModuleArray do
    let spelling := ".".intercalate (moduleComponents module).toList
    -- **`isNameLit` and not membership of `knownModules`**: that set is a
    -- mixture of spellings — the IR contributes `«Dep-Aux».Basic` and the
    -- `.lidx`'s `@` section `Dep-Aux.Basic` for the same module — so being in it
    -- says nothing about which branch reaches the string. What this map is for
    -- is the words the ordinary branches refuse, and they refuse exactly the
    -- ones that are not name literals.
    if spelling != module && !isNameLit spelling then
      claimed := claimed.alter spelling fun
        | some _ => some none
        | none => some (some module)
  let mut unescapedModules : Std.HashMap String String :=
    Std.HashMap.emptyWithCapacity (claimed.size * 2 + 1)
  for (spelling, module) in claimed.toArray do
    if let some module := module then
      unescapedModules := unescapedModules.insert spelling module
  return { known, lidx, pages, knownModules, knownModuleArray, unescapedModules, external }

def privatePrefix : String := "_private."

def moduleLink (root : String) (module : String) : String := Id.run do
  let mut out := root
  let mut first := true
  for part in moduleComponents module do
    if !first then out := out ++ "/"
    out := out ++ part
    first := false
  return out ++ ".html"

def pageRoot (module : String) : String := Id.run do
  let depth := (moduleComponents module).size - 1
  let mut out := ""
  for _ in [0:depth] do out := out ++ "../"
  return out ++ "./"

/-- `NameIndex::link_to`, **the only copy of the decision**: every call site that
builds a link to another module goes through here.

`none` means "render the name, draw no link", and **no caller falls through to a
later branch**: a resolved name that happens to be unlinkable must not be
re-resolved to some other declaration that happens to have a page.

**The documentation question is asked first, and it is a different question, not
a preference between two links.** It asks whether the dependency's own
documentation site was **verified to document this name**; a `no` falls through
to the version-pinned source. There is in particular no "try the docs site and
see": a 404 is not visible from here, and avoiding one is the whole reason the
pin is there. -/
@[inline] def linkTo (ix : NameIndex) (root module : String) (anchor : Option String) :
    Option String :=
  match ix.external.docsUrlFor module anchor with
  | some url => some url
  | none =>
  match ix.external.sourceFor (moduleComponents module)[0]! with
  | .pinned base => some (sourceUrlAt base module (anchor.bind ix.lidx.rangeOf))
  | .unpinned => none
  | .absent =>
    if !ix.pages.contains module then none
    else match anchor with
      | some a => some (moduleLink root module ++ "#" ++ a)
      | none => some (moduleLink root module)

/-! ## What a name on this page can link to -/

/-- `res.moduleInfo[current].members`: every `DocInfo` of the module including
the ones that get no page entry, minus the private ones, in declaration-range
order — which is **not** the IR's order. -/
def moduleDeclNames (m : Module) : Array String :=
  let ds := m.decls.filter (fun d => !d.name.startsWith privatePrefix)
  let sorted := ds.qsort fun a b =>
    a.line < b.line || (a.line == b.line &&
      (a.col < b.col || (a.col == b.col && a.index < b.index)))
  sorted.map (·.name)

/-- One declaration of the page being written, as `nameToLink`'s last branch
needs it. -/
structure PageDecl where
  name : String
  components : Array String
  module : String
  deriving Inhabited

structure PageCtx where
  ix : NameIndex
  root : String
  /-- `nameToLink?`'s last resort walks these, in declaration-range order.

  **Each carries the module it is placed in, and not a name to look up.** The
  straightforward shape is a list of names, which is what
  `crates/litedoc4-render/src/autolink.rs` takes — and then the branch holds a
  lookup that can answer `none` for a declaration of this page the index cannot
  place, which is not a question the branch can do anything with; Rust refuses
  such a list where it is handed over (`PageLinks::new`) so that a broken wiring
  names itself instead. Resolving once in `mkPageCtx`, the only way in, leaves no
  such state to answer for. What would falsify this: a caller whose names did not
  come from a module the index was built from. -/
  decls : Array PageDecl
  deriving Inhabited

def mkPageCtx (ix : NameIndex) (root : String) (m : Module) : PageCtx :=
  { ix, root
    decls := (moduleDeclNames m).filterMap fun name =>
      (ix.known.get? name).map fun module =>
        { name, components := components name, module } }

def moduleOf (ix : NameIndex) (name : String) : Option String :=
  match ix.known.get? name with
  | some m => some m
  | none => (ix.lidx.names.get? name).map (·.module)

/-- Components compared from the end, over as many as the shorter has: `succ`
matches `Nat.succ`, and `Nat.succ` matches `Foo.Nat.succ`. -/
def tailMatch (want have_ : Array String) : Bool := Id.run do
  let k := min want.size have_.size
  for t in [0:k] do
    if want[want.size - 1 - t]! != have_[have_.size - 1 - t]! then return false
  return true

/-- `nameToLink?` from its second branch on. A branch that answers returns its
answer, `none` included: continuing would let the last branch link a name to
whatever declaration of *this* page ends the same way. -/
def nameToLink (c : PageCtx) (s : String) : Option String :=
  if !isNameLit s then
    match c.ix.unescapedModules.get? s with
    | some m => linkTo c.ix c.root m none
    | none => none
  else
    let viaMap := if s.startsWith privatePrefix then none else moduleOf c.ix s
    match viaMap with
    | some m => linkTo c.ix c.root m (some s)
    | none =>
      if c.ix.knownModules.contains s then linkTo c.ix c.root s none
      else Id.run do
        let want := components s
        for d in c.decls do
          if tailMatch want d.components then
            return linkTo c.ix c.root d.module (some d.name)
        return none

/-- Which module a **source path** written in a docstring names: that name
itself when it is a known module — the repository-root-relative path doc-gen4
assumes — and otherwise the one known module that has it as a proper suffix on a
component boundary, which is the path a docstring writes relative to its own
module.

**Two matches is `none`, not the first one.** A link to the wrong page is worse
than no link: the reader who follows a 404 knows something is missing, and the
reader who lands on a plausible wrong page does not.

Its own function and not part of `sourcePathToLink`, because *which module* and
*what link* are the two questions a wrong answer here can be wrong in, and only
the first of them is decided by the path. -/
def moduleForSourcePath (ix : NameIndex) (path : String) : Option String := Id.run do
  -- `escapeModule` and not `path.replace "/" "."`: a directory whose name is not
  -- an identifier is a *quoted* component of the module it belongs to, so
  -- `Odd-Name/Inner.lean` is `«Odd-Name».Inner` and the plain join matches no
  -- module at all. What would falsify this: a Lean that stopped quoting them.
  let candidate := escapeModule (path.splitOn "/").toArray
  if ix.knownModules.contains candidate then
    return some candidate
  let cn := candidate.utf8ByteSize
  let mut found : Option String := none
  for m in ix.knownModuleArray do
    let mn := m.utf8ByteSize
    if mn <= cn then continue
    if byteAt m (mn - cn - 1) != 46 then continue
    if byteSub m (mn - cn) mn != candidate then continue
    if found.isSome then return none
    found := some m
  return found

/-- `nameToLink?`'s first branch: a word that ends in `.lean` and contains a `/`
is a path to a source file, and the link is that module's — through `linkTo`
like every other module link, so a path into a dependency reaches its pinned
source rather than a page this site never wrote. -/
def sourcePathToLink (c : PageCtx) (path : String) : Option String :=
  (moduleForSourcePath c.ix path).bind fun m => linkTo c.ix c.root m none

def pageResolver (c : PageCtx) : LinkResolver :=
  { nameToLink := nameToLink c, sourcePathToLink := sourcePathToLink c }

/-- Both halves take the same `root`: it reaches the output through the
renderer's own `extendLink` as well as through this resolver, and handing them
different values produces links that are half right. -/
def pageRenderer (c : PageCtx) : Renderer :=
  { root := c.root, links := pageResolver c }

end Litedoc4
