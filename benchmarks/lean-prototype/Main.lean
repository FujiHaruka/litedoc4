/-
Micro-benchmarks for the pure-Lean replacement study.

What is measured is the floor: what Lean pays to read the IR, parse it, parse
the link index, look names up in it, build the HTML strings and write the pages,
with none of the rendering logic in it. A renderer written in Lean cannot beat
this.

**Every phase returns a number computed inside `IO`.** A `timeIt` over
`pure (f x)` measures the cost of allocating a thunk — 1 microsecond — and not
the work; the first version of this file did exactly that and reported
`lidx.parse 0.000001`.
-/
import Lean.Data.Json
import Std.Data.HashMap

open Lean System

/-- The phase's result is forced by being a `Nat` the caller prints. -/
def timeIt (label : String) (act : IO (α × Nat)) : IO α := do
  let t0 ← IO.monoNanosNow
  let (a, n) ← act
  let t1 ← IO.monoNanosNow
  IO.println s!"{label}\t{(Float.ofNat (t1 - t0)) / 1e9}\t{n}"
  return a

def jsonFilesIn (dir : FilePath) : IO (Array FilePath) := do
  let entries ← dir.readDir
  let files := entries.filterMap fun e =>
    if e.fileName.endsWith ".json" then some e.path else none
  return files.qsort (·.toString < ·.toString)

structure LidxEntry where
  module : String
  startLine : Nat
  endLine : Nat
  deriving Inhabited

/-- The `.lidx` reader, in the shape `crates/litedoc4-render/src/link_index.rs`
describes: line-oriented, first byte decides, no error path. Written in `IO` so
the timer sees the work rather than a thunk. -/
def parseLidx (text : String) : IO (Std.HashMap String LidxEntry) := do
  let mut map : Std.HashMap String LidxEntry := {}
  let mut group := ""
  for line in text.splitOn "\n" do
    if line.isEmpty then continue
    let c := String.Pos.Raw.get line 0
    if c == '#' then continue
    else if c == '@' then
      let m := (line.drop 1).toString
      map := map.insert m { module := m, startLine := 0, endLine := 0 }
    else if c == '\t' then
      match (line.drop 1).toString.splitOn "\t" with
      | [name] => map := map.insert name { module := group, startLine := 0, endLine := 0 }
      | [name, s, e] =>
        map := map.insert name
          { module := group, startLine := s.toNat!, endLine := e.toNat! }
      | name :: _ => map := map.insert name { module := group, startLine := 0, endLine := 0 }
      | [] => pure ()
    else
      group := line
  return map

def main (args : List String) : IO UInt32 := do
  let some w := args.head? | do
    IO.eprintln "usage: bench <work-dir>"
    return 2
  let w : FilePath := w
  let irModules := w / "ir" / "modules"
  let linkIndex := w / "link-index.json"

  let files ← jsonFilesIn irModules
  let contents ← timeIt "ir.read" do
    let mut acc : Array String := #[]
    let mut bytes := 0
    for f in files do
      let c ← IO.FS.readFile f
      bytes := bytes + c.utf8ByteSize
      acc := acc.push c
    return (acc, bytes)

  let parsed ← timeIt "ir.parse" do
    let mut acc : Array Json := #[]
    let mut decls := 0
    for c in contents do
      match Json.parse c with
      | .ok j =>
        -- forced: reaching into the parsed value is what makes the parser run
        decls := decls + (match j.getObjValAs? (Array Json) "declarations" with
          | .ok ds => ds.size
          | .error _ => 0)
        acc := acc.push j
      | .error e => throw (IO.userError s!"parse: {e}")
    return (acc, decls)
  let _ := parsed

  let liText ← timeIt "lidx.read" do
    let t ← IO.FS.readFile linkIndex
    return (t, t.utf8ByteSize)

  let lidx ← timeIt "lidx.parse" do
    let m ← parseLidx liText
    return (m, m.size)

  let names := lidx.toArray.map (·.1)
  let _ ← timeIt "lidx.lookup" do
    let mut hits := 0
    for _ in [0:4] do
      for n in names do
        if (lidx.get? n).isSome then hits := hits + 1
    return ((), hits)

  let built ← timeIt "html.build" do
    let mut pages : Array String := #[]
    let mut bytes := 0
    for _ in [0:422] do
      let mut parts : Array String := #[]
      for i in [0:800] do
        parts := parts.push s!"<div class=\"decl\" id=\"d{i}\"><code>theorem foo{i}</code><p>text</p></div>\n"
      let page := String.join parts.toList
      bytes := bytes + page.utf8ByteSize
      pages := pages.push page
    return (pages, bytes)

  let outDir := w / "lean-bench-pages"
  IO.FS.createDirAll outDir
  let _ ← timeIt "html.write" do
    let mut i := 0
    for p in built do
      IO.FS.writeFile (outDir / s!"p{i}.html") p
      i := i + 1
    return ((), i)
  IO.FS.removeDirAll outDir
  return 0
