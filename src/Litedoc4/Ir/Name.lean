import Litedoc4.Bytes

namespace Litedoc4

def components (s : String) : Array String := Id.run do
  let n := s.utf8ByteSize
  let mut out : Array String := #[]
  let mut a := 0
  let mut i := 0
  while i < n do
    if byteAt s i == 46 then
      out := out.push (byteSub s a i)
      a := i + 1
    i := i + 1
  out := out.push (byteSub s a n)
  return out

/-- `«` and `»` at byte `i`, as their two UTF-8 bytes. -/
@[inline] def isGuillemet (s : String) (i : Nat) (closing : Bool) : Bool :=
  byteAt s i == 0xC2 && byteAt s (i + 1) == (if closing then 0xBB else 0xAB)

/-- `«Odd.Name»` → `Odd.Name`; anything not wrapped in both is itself. -/
def unescapeComponent (s : String) : String :=
  let n := s.utf8ByteSize
  if n ≥ 4 && isGuillemet s 0 false && isGuillemet s (n - 2) true then byteSub s 2 (n - 2)
  else s

/-- `module_components`: the dot separates only outside `«…»`, and each
component comes back unescaped, so `Alpha.«Odd.Name»` is two components.

**Not interchangeable with `components`, and the Rust side is not confused about
which is which**: a path, a link href, a source URL and the site title take this
one, because they have to name the file the renderer wrote; `Name.lt` and the
tail match take the plain split, because they compare a *spelling* against
another spelling. Feeding either to the other's callers is a divergence no byte
comparison of one side finds — the page is written under one name and linked
under the other. What would falsify this: a Lean that stopped escaping such
components with guillemets. -/
def moduleComponents (s : String) : Array String := Id.run do
  let n := s.utf8ByteSize
  let mut out : Array String := #[]
  let mut a := 0
  let mut i := 0
  let mut depth := 0
  while i < n do
    if isGuillemet s i false then
      depth := depth + 1
      i := i + 2
    else if isGuillemet s i true then
      depth := depth - 1
      i := i + 2
    else
      if byteAt s i == 46 && depth == 0 then
        out := out.push (unescapeComponent (byteSub s a i))
        a := i + 1
      i := i + 1
  out := out.push (unescapeComponent (byteSub s a n))
  return out

/-- `Lean.isLetterLike` — `Init/Meta/Defs.lean:101-112`. Written out rather than
reached for in a Unicode table: `Char.isAlpha` is ASCII in Lean, so every
non-ASCII identifier character comes from these ranges, and a different UCD
would spell a different module name than the extractor's. -/
def isLetterLike (c : Char) : Bool :=
  let v := c.val
  (0x3b1 ≤ v && v ≤ 0x3c9 && v != 0x3bb)
    || (0x391 ≤ v && v ≤ 0x3a9 && v != 0x3a0 && v != 0x3a3)
    || (0x3ca ≤ v && v ≤ 0x3fb)
    || (0x1f00 ≤ v && v ≤ 0x1ffe)
    || (0x2100 ≤ v && v ≤ 0x214f)
    || (0x1d49c ≤ v && v ≤ 0x1d59f)
    || (0xc0 ≤ v && v ≤ 0xff && v != 0xd7 && v != 0xf7)
    || (0x100 ≤ v && v ≤ 0x17f)

/-- `Lean.isSubScriptAlnum` — `Init/Meta/Defs.lean:114-118`. -/
def isSubScriptAlnum (c : Char) : Bool :=
  let v := c.val
  (0x2080 ≤ v && v ≤ 0x2089) || (0x2090 ≤ v && v ≤ 0x209c)
    || (0x1d62 ≤ v && v ≤ 0x1d6a) || v == 0x2c7c

/-- `Lean.isIdFirst`. `Char.isAlpha` is ASCII in Lean, which is the whole reason
`isLetterLike` is here beside it. -/
def isIdFirst (c : Char) : Bool := c.isAlpha || c == '_' || isLetterLike c

/-- `Lean.isIdRest`. `Char.isAlphanum` is ASCII in Lean. -/
def isIdRest (c : Char) : Bool :=
  c.isAlphanum || c == '_' || c == '\'' || c == '!' || c == '?'
    || isLetterLike c || isSubScriptAlnum c

/-- Whether a component is spelled as itself by `Name.toString`. -/
def needsNoEscape (component : String) : Bool :=
  match component.toList with
  | [] => false
  | first :: rest => isIdFirst first && rest.all isIdRest

/-- `Name.escapePart` with `force := false` (`Init/Meta/Defs.lean:198-207`).

A component containing `»` is **not** escaped, because wrapping it would produce
something that does not parse back. Transcribed, not improved — the spelling
this has to agree with is the extractor's. -/
def escapeComponent (component : String) : String :=
  if needsNoEscape component || component.contains '»' then component
  else "«" ++ component ++ "»"

/-- A module name built from path components, as `Name.toString` spells it.
The inverse direction of `moduleComponents`, and the reason a module list is not
just the paths with `/` replaced: `Alpha/Odd-Name.lean` is the module Lean spells
`Alpha.«Odd-Name»`, and the extractor's `String.toName` yields
`Name.anonymous` for anything else. -/
def escapeModule (components : Array String) : String :=
  ".".intercalate (components.map escapeComponent).toList

/-- `Alpha.«Odd-Name»` → `Alpha/Odd-Name.html`, relative to the site root, with
`/` on every platform because this is a URL path as much as a file path.

**Three readers need this rule and it has to be one rule**: the renderer writes
the page, `prune` deletes it, and the whole-package artifacts link to it. Writer
and remover disagreeing leaves the dead page behind; writer and index
disagreeing emits `href`s to pages that are not there, and **neither shows up in
a byte comparison of either side**.

**A name can carry a `..` through this** — `«..».Foo` comes out as
`../Foo.html` — so the tree a deletion is allowed inside checks rather than
trusts (`Litedoc4.PageRoot`). -/
def pageUrl (module : String) : String :=
  String.intercalate "/" (moduleComponents module).toList ++ ".html"

end Litedoc4
