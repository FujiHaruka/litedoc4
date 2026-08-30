/- Filesystem questions Lean core does not answer, in one place because two of
them decide whether a directory is deleted (`crates/litedoc4/src/extract.rs`'s
`absolute` and `resolve`, and `crates/litedoc4/src/build.rs`'s `is_empty_dir`). -/

open System

namespace Litedoc4

/-- `Path::is_file`: symlinks are followed, so a link to a file is a file. The
one place that must **not** follow them is a directory listing, where a link
would let one module be listed twice under two names — that one asks
`symlinkMetadata` instead. -/
def isRegularFile (p : FilePath) : BaseIO Bool := do
  match ← p.metadata.toBaseIO with
  | .ok m => return m.type == .file
  | .error _ => return false

def isEmptyDir (p : FilePath) : BaseIO Bool := do
  match ← p.readDir.toBaseIO with
  | .ok entries => return entries.isEmpty
  | .error _ => return false

/-- `p` made absolute **without touching what it spells** — the one for a command
line, where `resolvePath` is the one for a comparison. Resolving symlinks would
hand the child a path the caller did not write (`/tmp/x` becomes `/private/tmp/x`
on this platform). -/
def absolutePath (p : FilePath) : IO FilePath :=
  if p.isAbsolute then return p else return (← IO.currentDir) / p

private partial def resolveFrom (full p : FilePath) (tail : List String) : IO FilePath := do
  match ← (IO.FS.realPath p).toBaseIO with
  | .ok real => return tail.foldl (fun acc part => acc / (⟨part⟩ : FilePath)) real
  | .error _ =>
    match p.fileName, p.parent with
    | some name, some parent => resolveFrom full parent (name :: tail)
    | _, _ => return full

/-- `p` made absolute and with every existing component's symlinks resolved.

Not `IO.FS.realPath`, which needs the whole path to exist: the guard that uses
this runs **before** the directory is created, because creating it is already a
write and a write inside the package being documented is the one thing the guard
prevents. -/
def resolvePath (p : FilePath) : IO FilePath := do
  let full ← absolutePath p
  resolveFrom full full []

/-- Whether `candidate` resolves inside `container`. Compared after
`resolvePath`, not as given: `/tmp/x` and `/private/tmp/x` are one directory on
this platform, and a guard that says otherwise can be walked around by
spelling. -/
def isInside (container candidate : FilePath) : Bool :=
  let c := container.toString
  let x := candidate.toString
  x == c || x.startsWith (c ++ "/")

/-- Writes `body` to `path`, making its directory first. -/
def writeFile (path : FilePath) (body : String) : IO Unit := do
  if let some dir := path.parent then
    if !dir.toString.isEmpty then IO.FS.createDirAll dir
  IO.FS.writeFile path body

/-- One name per line; blank lines and `#` comments are dropped. The reading
side of `writeLines` below, and in the same module for that reason: the two
decide together what an empty set looks like on disk. -/
def readModuleList (path : FilePath) : IO (Array String) := do
  let text ← IO.FS.readFile path
  let mut out : Array String := #[]
  for line in text.splitOn "\n" do
    let line := line.trimAscii.toString
    if !line.isEmpty && !line.startsWith "#" then out := out.push line
  return out

/-- One name per line, and **no line at all** when there are no names: the sets
this writes are handed to `--only-from`, where an empty file has to mean "render
nothing" rather than "render everything". -/
def linesFile (items : Array String) : String :=
  if items.isEmpty then "" else "\n".intercalate items.toList ++ "\n"

def writeLines (path : FilePath) (items : Array String) : IO Unit :=
  writeFile path (linesFile items)

end Litedoc4
