/- `crates/litedoc4-render/src/config.rs`: `litedoc4.toml`, what a package says
about its own site.

```toml
title = "MyPkg"          # the top bar, and the second half of every <title>
index = "docs/index.md"  # Markdown to put at the top of the site's index
```

Both optional. An absent file, an empty file and a file with neither key are the
same answer.

**A file that is there and does not parse is an error**, and so is an `index`
naming a file that is not there: carrying on with the derived title would be a
site that silently ignores what the package asked for.

The recogniser below is not a TOML parser and refuses every line it cannot
account for, the way `crates/litedoc4/src/lakefile.rs` refuses a lakefile line it
cannot account for. A general parser would accept spellings this reader would
then have to interpret — a table header, an array, a literal string — and the
failure mode of guessing here is a site with the wrong title on every page,
which nothing downstream can see. What would falsify this: a package that has to
write its title in a spelling this refuses, which is a reason to widen the
recogniser rather than to stop reading it strictly. -/
import Litedoc4.Fs
import Litedoc4.Ir.Utf16

open System

namespace Litedoc4

structure SiteConfig where
  title : Option String := none
  /-- The **contents** of the file `index` named, not its path: the path is
  relative to the package root, and resolving it anywhere else would be a second
  place that knows what it is relative to. -/
  indexMarkdown : Option String := none
  deriving Inhabited

def configFile : String := "litedoc4.toml"

namespace Toml

def isSpace (c : Char) : Bool := c == ' ' || c == '\t'

def isKeyChar (c : Char) : Bool :=
  ('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9')
    || c == '_' || c == '-'

def hexDigit (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - 48)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 87)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 55)
  else none

partial def skipSpace : List Char → List Char
  | c :: rest => if isSpace c then skipSpace rest else c :: rest
  | [] => []

partial def takeKey : List Char → String → String × List Char
  | c :: rest, acc => if isKeyChar c then takeKey rest (acc.push c) else (acc, c :: rest)
  | [], acc => (acc, [])

def hexScalar (cs : List Char) (width : Nat) : Except String (Nat × List Char) := Id.run do
  let mut value := 0
  let mut rest := cs
  for _ in [0:width] do
    match rest with
    | c :: more =>
      match hexDigit c with
      | some d => value := value * 16 + d; rest := more
      | none => return .error "an escape needs hex digits"
    | [] => return .error "an escape needs hex digits"
  if value ≥ 0xD800 && value < 0xE000 then
    return .error "an escape names a surrogate, which is not a character"
  if value > 0x10FFFF then return .error "an escape names no character"
  return .ok (value, rest)

/-- A basic string, from just after the opening quote to just after the closing
one. Every escape TOML defines and no other: an unknown one is refused rather
than passed through, because a title is copy and a stray `\p` in it is not. -/
partial def basicString (cs : List Char) (acc : String) :
    Except String (String × List Char) :=
  match cs with
  | [] => .error "a string is not closed before the end of the line"
  | '"' :: rest => .ok (acc, rest)
  | '\\' :: e :: rest =>
    match e with
    | '"' => basicString rest (acc.push '"')
    | '\\' => basicString rest (acc.push '\\')
    | 'b' => basicString rest (acc.push '\x08')
    | 't' => basicString rest (acc.push '\t')
    | 'n' => basicString rest (acc.push '\n')
    | 'f' => basicString rest (acc.push '\x0c')
    | 'r' => basicString rest (acc.push '\x0d')
    | 'u' => do
      let (v, rest) ← hexScalar rest 4
      basicString rest (acc.push (Char.ofNat v))
    | 'U' => do
      let (v, rest) ← hexScalar rest 8
      basicString rest (acc.push (Char.ofNat v))
    | other => .error s!"`\\{other}` is not an escape this reader knows"
  | '\\' :: [] => .error "a string ends in a backslash"
  | c :: rest => basicString rest (acc.push c)

/-- `none` for a line that says nothing (blank, or a comment). -/
def line (text : String) : Except String (Option (String × String)) := do
  let cs := skipSpace text.toList
  match cs with
  | [] => return none
  | '#' :: _ => return none
  | _ =>
    let (key, rest) := takeKey cs ""
    if key.isEmpty then
      throw "a line that is neither blank, a comment, nor `key = \"value\"`"
    match skipSpace rest with
    | '=' :: rest =>
      match skipSpace rest with
      | '"' :: rest => do
        let (value, rest) ← basicString rest ""
        match skipSpace rest with
        | [] => return some (key, value)
        | '#' :: _ => return some (key, value)
        | _ => throw s!"`{key}` has something after its value"
      | _ => throw s!"`{key}` is not given a quoted string"
    | _ => throw s!"`{key}` is not followed by `=`"

end Toml

/-- The two keys as the file spells them, with `index` still a path.

Separate from `SiteConfig`, which carries the index file's **contents**: this is
what reading the text alone can answer, and `readSiteConfig` is what turns the
path into the Markdown behind it. -/
structure ConfigKeys where
  title : Option String := none
  index : Option String := none
  deriving BEq, Repr, Inhabited

/-- `title` and `index`, and an unknown key is a hard error rather than an
ignored line: a misspelled key that is silently dropped is a package whose
configuration does nothing and says nothing. -/
def parseConfig (text : String) : Except String ConfigKeys := Id.run do
  let mut title : Option String := none
  let mut index : Option String := none
  let mut number := 0
  for raw in text.splitOn "\n" do
    number := number + 1
    let trimmed :=
      if raw.endsWith "\r" then byteSub raw 0 (raw.utf8ByteSize - 1) else raw
    match Toml.line trimmed with
    | .error message => return .error s!"line {number}: {message}"
    | .ok none => pure ()
    | .ok (some (key, value)) =>
      if key == "title" then
        if title.isSome then return .error s!"line {number}: `title` is given twice"
        title := some value
      else if key == "index" then
        if index.isSome then return .error s!"line {number}: `index` is given twice"
        index := some value
      else
        return .error s!"line {number}: unknown key `{key}`"
  -- An empty title is not a title: `title = ""` would otherwise put a blank
  -- where every page names the site. Here rather than at the one caller so that
  -- reading the file and deciding what it said are not two answers.
  return .ok { title := title.filter (fun t => !(trimWs t).isEmpty), index }

/-- `<root>/litedoc4.toml`, or the empty configuration when `root` is `none` or
holds no such file. -/
def readSiteConfig (root : Option FilePath) : IO SiteConfig := do
  let some root := root | return {}
  let path := root / configFile
  let text ← try
      pure (some (← IO.FS.readFile path))
    catch
      | .noFileOrDirectory .. => pure none
      | e => throw (unreadable path e)
  let some text := text | return {}
  let keys ← match parseConfig text with
    | .ok keys => pure keys
    | .error message => throw (IO.userError s!"{path}: {message}")
  let indexMarkdown ← match keys.index with
    | some relative =>
      let resolved := root / relative
      pure (some (← readTextFile resolved))
    | none => pure none
  return { title := keys.title, indexMarkdown }

end Litedoc4
