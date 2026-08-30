/- `crates/litedoc4/src/lakefile.rs`: where `--lib` comes from when it is not
passed.

A Lake package declares its libraries in one of two files, and they are not the
same kind of thing:

* **`lakefile.toml`** — data. `[[lean_lib]]` blocks with a `name` key, which is
  what this reads.
* **`lakefile.lean`** — *code*. `lean_lib` is a Lake DSL command in a Lean file
  that Lake elaborates; the library name can come from an `open`ed namespace,
  from string interpolation, from an `if`. Reading it honestly means running
  Lake, which this command does not do. **It is refused by name, with `--lib` as
  the answer** — never parsed hopefully.

The same rule runs one level deeper. This is **not** a TOML parser: it is a
recogniser for the exact shape `[[lean_lib]]`/`name` is written in, and every
line it cannot account for stops it rather than being skipped. The failure it is
built against is silent under-reading — a `[[lean_lib]]` in a spelling the
recogniser skips produces a *shorter* module list, and a module list missing a
library looks exactly like a package whose modules were deleted: the pages are
never written and nothing says so. So every refusal here ends in the same
sentence — pass `--lib`.

**`defaultTargets` is not consulted.** It answers a different question: what
`lake build` builds with no arguments (and it can name executables, which have no
modules to document), where this list is "which module roots does this package
own". -/
import Litedoc4.Fs
import Litedoc4.Ir.Utf16

open System

namespace Litedoc4

structure Libraries where
  names : Array String
  /-- For the log line: a caller that gets a surprising module list needs to
  know which file the surprise came from. -/
  file : FilePath

namespace Lakefile

/-- The text after `name` and its `=`, when the line's key is exactly `name` —
`name_of = "x"` is a different key and must not match. -/
def keyIsName (line : String) : Option String :=
  if !line.startsWith "name" then none else
  let rest := trimStartWs (line.drop 4).toString
  if !rest.startsWith "=" then none else
  some (trimStartWs (rest.drop 1).toString)

/-- `"<value>"`, optionally followed by a `#` comment, and nothing else. -/
def plainString (text : String) : Option String :=
  if !text.startsWith "\"" then none else
  let parts : List String := (text.drop 1).toString.splitOn "\""
  if parts.length < 2 then none else
  let value := parts[0]!
  let rest := trimWs ("\"".intercalate (parts.drop 1))
  if value.isEmpty || value.contains '\\' then none
  else if rest.isEmpty || rest.startsWith "#" then some value
  else none

/-- A block with no `name` is refused rather than skipped: Lake defaults the
library's name to the package's, and guessing that here would produce a module
root nobody wrote down. -/
def close (path : FilePath) (number : Nat) (open_ : Option (Option String))
    (names : Array String) : Except String (Array String) :=
  match open_ with
  | none => .ok names
  | some (some name) => .ok (names.push name)
  | some none =>
    .error s!"{path}: the [[lean_lib]] block ending at line {number} has no `name` key. Lake \
      fills that in from the package, and inventing the value here would glob a module root \
      nobody wrote down. Pass --lib <Name>"

/-- Every `[[lean_lib]]`'s `name`, in the order the file declares them.

The recogniser, stated as rules so that what it does **not** understand is
visible:

1. a line whose first non-blank character is `[` is a table header; the only one
   that opens a library block is exactly `[[lean_lib]]`;
2. inside such a block, a `name` key must be `name = "<Ident>"`, with an optional
   `#` comment after it and no escapes in the string;
3. any other line is skipped **only because rules 1 and 2 make a missed
   `[[lean_lib]]` impossible to reach**: a header mentioning `lean_lib` in any
   other spelling stops the run;
4. multi-line strings (`"""` / `'''`) stop the run before any of the above,
   because their content can be an arbitrary line and rule 1 would read it as
   structure. -/
def leanLibs (text : String) (path : FilePath) : Except String (Array String) := Id.run do
  if (text.splitOn "\"\"\"").length > 1 then
    return .error s!"{path}: multi-line strings are not read — inside one, a line can be \
      anything, and this recogniser reads a leading `[` as a table header. Pass --lib <Name>"
  if (text.splitOn "'''").length > 1 then
    return .error s!"{path}: multi-line strings are not read — inside one, a line can be \
      anything, and this recogniser reads a leading `[` as a table header. Pass --lib <Name>"
  let lines := text.splitOn "\n"
  let mut names : Array String := #[]
  let mut open_ : Option (Option String) := none
  let mut number := 0
  for raw in lines do
    number := number + 1
    let line := trimWs raw
    if line.isEmpty || line.startsWith "#" then continue
    if line.startsWith "[" then
      match close path number open_ names with
      | .error message => return .error message
      | .ok updated => names := updated
      open_ := none
      if line == "[[lean_lib]]" then
        open_ := some none
        continue
      -- Rule 3's guard. `[ [lean_lib] ]` and `[[lean_lib.extra]]` are valid TOML
      -- that this does not understand; treating either as "some other table"
      -- would drop a library without a word.
      if (line.splitOn "lean_lib").length > 1 then
        return .error s!"{path}:{number}: `{line}` mentions lean_lib in a spelling this does \
          not read (only a bare `[[lean_lib]]` header is). Skipping it would document fewer \
          libraries than the package has, silently. Pass --lib <Name>"
      continue
    let some slot := open_ | continue
    let some rest := keyIsName line | continue
    let some name := plainString rest
      | return .error s!"{path}:{number}: `{line}` is a `name` this does not read — it wants \
          `name = \"<Ident>\"`, one plain double-quoted string with no escapes. Pass --lib <Name>"
    if slot.isSome then
      return .error s!"{path}:{number}: a second `name` in one [[lean_lib]] block. \
        Pass --lib <Name>"
    open_ := some (some name)
  match close path lines.length open_ names with
  | .error message => return .error message
  | .ok updated => names := updated
  if names.isEmpty then
    return .error s!"{path}: no [[lean_lib]] block. A package with no library has no modules to \
      document; if it has one under another spelling, pass --lib <Name>"
  return .ok names

end Lakefile

/-- `.error` is the refusal that exits 3 rather than the usage error that exits
2: the command line was fine and the *package* is a shape this cannot read,
which is the same kind of answer as "this module has no olean". -/
def readLibraries (root : FilePath) : IO (Except String Libraries) := do
  let toml := root / "lakefile.toml"
  let lean := root / "lakefile.lean"
  if !(← isRegularFile toml) then
    if ← isRegularFile lean then
      return .error s!"{lean} is Lean code, not data: `lean_lib` there is a Lake DSL command \
        whose argument can come from an `open`ed namespace or from any Lean expression, so \
        reading it honestly means elaborating it with Lake — which this command does not do. \
        Pass --lib <Name> (repeatable) and the glob will use it"
    return .error s!"no lakefile.toml and no lakefile.lean under {root}: --root names a Lake \
      package, and the library names come from its lakefile. Pass --lib <Name> to name them \
      yourself"
  let text ← IO.FS.readFile toml
  match Lakefile.leanLibs text toml with
  | .error message => return .error message
  | .ok names => return .ok { names, file := toml }

end Litedoc4
