/-
Derived from doc-gen4 (Apache-2.0, Copyright (c) 2021 Henrik Böving) by way of
`crates/litedoc4-render/src/autolink.rs`, and changed; see this repository's NOTICE
and `docs/provenance.md`.
-/
import Litedoc4.Ir
import Litedoc4.Ir.Name
import Litedoc4.Md.Html
import Litedoc4.Render.LinkIndex

namespace Litedoc4

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
  deriving Inhabited

def buildIndex (deps : Array (Array (String × String))) (mods : Array Module)
    (lidx : Lidx) : IO NameIndex := do
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
  return { known, lidx, pages, knownModules, knownModuleArray := knownModules.toArray }

/-! ## Lean name syntax

`Lean.isLetterLike` and `Lean.isSubScriptAlnum`, which is what lets `α`, `ℕ` and
`𝒜` start an identifier. The last range is above the BMP; a port that drops it
still resolves every ASCII name, which is nearly all of them. -/

def isLetterLike (c : Char) : Bool :=
  let v := c.val.toNat
  ((0x3b1 ≤ v && v ≤ 0x3c9) && v != 0x3bb)
    || ((0x391 ≤ v && v ≤ 0x3a9) && v != 0x3a0 && v != 0x3a3)
    || (0x3ca ≤ v && v ≤ 0x3fb)
    || (0x1f00 ≤ v && v ≤ 0x1ffe)
    || (0x2100 ≤ v && v ≤ 0x214f)
    || (0x1d49c ≤ v && v ≤ 0x1d59f)
    || ((0xc0 ≤ v && v ≤ 0xff) && v != 0xd7 && v != 0xf7)
    || (0x100 ≤ v && v ≤ 0x17f)

def isSubScriptAlnum (c : Char) : Bool :=
  let v := c.val.toNat
  (0x2080 ≤ v && v ≤ 0x2089) || (0x2090 ≤ v && v ≤ 0x209c)
    || (0x1d62 ≤ v && v ≤ 0x1d6a) || v == 0x2c7c

def isIdFirst (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || c == '_' || isLetterLike c

def isIdRest (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9')
    || c == '_' || c == '\'' || c == '!' || c == '?'
    || isLetterLike c || isSubScriptAlnum c

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

/-- `NameIndex::link_to`. The measurement target is rendered with an **empty**
dependency map (`external no package named (--root)` in `render.log`), so the
two external branches are constant `none` here — but the `.lidx` probe for the
source range they consume is not, and it runs on every anchored link, which is
where most of this renderer's link-index traffic comes from. -/
@[inline] def linkTo (ix : NameIndex) (root module : String) (anchor : Option String) :
    Option String :=
  let _range := match anchor with
    | some name => ix.lidx.names.get? name
    | none => none
  if !ix.pages.contains module then none
  else match anchor with
    | some a => some (moduleLink root module ++ "#" ++ a)
    | none => some (moduleLink root module)

/-! ## What a name on this page can link to -/

structure PageCtx where
  ix : NameIndex
  root : String
  /-- `nameToLink?`'s last resort walks these, in declaration-range order. -/
  declNames : Array String
  declComps : Array (Array String)
  deriving Inhabited

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
  if !isNameLit s then none
  else
    let viaMap := if s.startsWith privatePrefix then none else moduleOf c.ix s
    match viaMap with
    | some m => linkTo c.ix c.root m (some s)
    | none =>
      if c.ix.knownModules.contains s then linkTo c.ix c.root s none
      else Id.run do
        let want := components s
        for i in [0:c.declNames.size] do
          if tailMatch want c.declComps[i]! then
            let name := c.declNames[i]!
            match c.ix.known.get? name with
            | some m => return linkTo c.ix c.root m (some name)
            | none => return none
        return none

/-- `nameToLink?`'s first branch: a word that ends in `.lean` and contains a `/`
is a path to a source file. Which module it names is decided against the known
modules — two matches is `none`, because a link to the wrong page is worse than
no link. -/
def sourcePathToLink (c : PageCtx) (path : String) : Option String := Id.run do
  let candidate := path.replace "/" "."
  if c.ix.knownModules.contains candidate then
    return linkTo c.ix c.root candidate none
  let cn := candidate.utf8ByteSize
  let mut found : Option String := none
  for m in c.ix.knownModuleArray do
    let mn := m.utf8ByteSize
    if mn <= cn then continue
    if byteAt m (mn - cn - 1) != 46 then continue
    if byteSub m (mn - cn) mn != candidate then continue
    if found.isSome then return none
    found := some m
  match found with
  | some m => return linkTo c.ix c.root m none
  | none => return none

def pageResolver (c : PageCtx) : LinkResolver :=
  { nameToLink := nameToLink c, sourcePathToLink := sourcePathToLink c }

/-- Both halves take the same `root`: it reaches the output through the
renderer's own `extendLink` as well as through this resolver, and handing them
different values produces links that are half right. -/
def pageRenderer (c : PageCtx) : Renderer :=
  { root := c.root, links := pageResolver c }

/-- `res.moduleInfo[current].members`: every `DocInfo` of the module including
the ones that get no page entry, minus the private ones, in declaration-range
order — which is **not** the IR's order. -/
def moduleDeclNames (m : Module) : Array String :=
  let ds := m.decls.filter (fun d => !d.name.startsWith privatePrefix)
  let sorted := ds.qsort fun a b =>
    a.line < b.line || (a.line == b.line &&
      (a.col < b.col || (a.col == b.col && a.index < b.index)))
  sorted.map (·.name)

end Litedoc4
