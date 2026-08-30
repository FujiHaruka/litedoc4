import Lean.Data.Json
import MathML4Lean

open Lean

namespace Mathml

structure Row where
  id : Nat
  source : String
  display : MathML4Lean.Display
  latex : String
  mathml : Option String

structure Header where
  total : Nat
  converts : Nat
  refuses : Nat

structure Options where
  file : System.FilePath
  check : Bool := false

def usage : String :=
  "usage: mathml <file> [--check]\n\
   \n\
   <file> is a consumer-spans JSONL file: a '#' header carrying the counts,\n\
   then one JSON object per math span with math-core's frozen answer.\n\
   \n\
   Without --check, converts every row and prints it.\n\
   With --check, also compares byte for byte against the frozen answers and\n\
   reconciles the counts against the header."

def parseArgs (args : List String) : Except String Options :=
  go args none false
where
  go : List String → Option System.FilePath → Bool → Except String Options
    | [], none, _ => .error "no file given"
    | [], some f, c => .ok { file := f, check := c }
    | "--check" :: rest, f, _ => go rest f true
    | a :: rest, f, c =>
      if a.startsWith "-" then .error s!"unknown argument {a}"
      else match f with
        | none => go rest (some a) c
        | some _ => .error s!"more than one file given: {a}"

def trim (s : String) : String :=
  s.trimAscii.toString

def headerValue (headers : Array String) (key : String) : Option Nat := Id.run do
  for line in headers do
    let body := trim (line.drop 1).toString
    if body.startsWith key then
      let rest := trim (body.drop key.length).toString
      if let some n := rest.toNat? then
        return some n
  return none

def parseHeader (headers : Array String) : Except String Header := do
  let get (key : String) : Except String Nat :=
    match headerValue headers key with
    | some n => .ok n
    | none => .error s!"the header has no `{key}` count"
  return {
    total := ← get "spans total"
    converts := ← get "math-core converts"
    refuses := ← get "math-core refuses"
  }

def displayName : MathML4Lean.Display → String
  | .inline => "inline"
  | .block => "block"

def parseDisplay (s : String) : Except String MathML4Lean.Display :=
  match s with
  | "inline" => .ok .inline
  | "block" => .ok .block
  | _ => .error s!"display is neither inline nor block: {s}"

def parseRow (line : String) : Except String Row := do
  let json ← Json.parse line
  let id ← json.getObjValAs? Nat "id"
  let source ← json.getObjValAs? String "source"
  let display ← parseDisplay (← json.getObjValAs? String "display")
  let latex ← json.getObjValAs? String "latex"
  let mathml ← match ← json.getObjVal? "mathml" with
    | .null => pure none
    | .str s => pure (some s)
    | other => .error s!"mathml is neither a string nor null: {other.compress}"
  return { id, source, display, latex, mathml }

def show? : Option String → String
  | some s => s
  | none => "<none>"

/--
Convert the file's rows, and with `--check` assert them against the frozen
answers.

WHY NO DEPARTURE-RULE TABLE
  MathML4Lean's own corpus gate carries one because Mathlib's 2,113 spans reach
  constructions where the specification and math-core disagree. This input is
  one consumer's docstrings, and on it the two halves already agree byte for
  byte, so there is nothing to name — and a rule that covers nothing is worse
  than no rule. A departure here is a defect until a rule is written in
  MathML4Lean and this file is pointed at it.
-/
def run (o : Options) : IO UInt32 := do
  let fail (msg : String) : IO UInt32 := do
    IO.eprintln s!"mathml FAILED: {msg}"
    return 1

  if !(← o.file.pathExists) then
    return ← fail s!"file not found: {o.file}"

  let text ← IO.FS.readFile o.file
  let lines := text.splitOn "\n" |>.map trim |>.filter (fun l => !l.isEmpty)
  let headers := lines.filter (·.startsWith "#") |>.toArray
  let rowLines := lines.filter (fun l => !l.startsWith "#")

  let header ← match parseHeader headers with
    | .ok h => pure h
    | .error e => return ← fail s!"{o.file}: {e}"

  let mut rows : Array Row := #[]
  for line in rowLines do
    match parseRow line with
    | .ok r => rows := rows.push r
    | .error e => return ← fail s!"{o.file}: row {rows.size + 1} does not parse: {e}"

  if rowLines.isEmpty then
    return ← fail s!"{o.file} holds no rows, so this run would assert nothing"
  if rowLines.length != header.total then
    return ← fail
      s!"the header claims {header.total} spans but the file has {rowLines.length} rows"

  unless o.check do
    IO.println s!"mathml: {o.file}"
    IO.println s!"  rows                {rowLines.length}"
    for row in rows do
      IO.println ""
      IO.println s!"  id {row.id}  {row.source}  {displayName row.display}"
      IO.println s!"    latex   {row.latex}"
      IO.println s!"    mathml  {show? (MathML4Lean.toMathML row.latex row.display)}"
    return 0

  let mut examined := 0
  let mut asserted := 0
  let mut matched := 0
  let mut declined : Array Row := #[]
  let mut differing : Array (Row × String × String) := #[]
  let mut oracleRefusals : Array (Row × Option String) := #[]

  for row in rows do
    let ours := MathML4Lean.toMathML row.latex row.display
    examined := examined + 1
    match row.mathml with
    | none => oracleRefusals := oracleRefusals.push (row, ours)
    | some expected =>
      asserted := asserted + 1
      match ours with
      | none => declined := declined.push row
      | some ours =>
        if ours == expected then
          matched := matched + 1
        else
          differing := differing.push (row, expected, ours)

  if examined != rowLines.length then
    return ← fail s!"examined {examined} rows but the file has {rowLines.length}"
  if asserted + oracleRefusals.size != examined then
    return ← fail
      s!"examined {examined} rows but {asserted + oracleRefusals.size} were sorted into an answer or a refusal"
  if asserted != header.converts then
    return ← fail
      s!"the header claims math-core converts {header.converts} rows but {asserted} rows carry an answer"
  if oracleRefusals.size != header.refuses then
    return ← fail
      s!"the header claims math-core refuses {header.refuses} rows but {oracleRefusals.size} rows are null"
  if matched + declined.size + differing.size != asserted then
    return ← fail
      s!"{asserted} rows carry an answer but {matched + declined.size + differing.size} were sorted"

  IO.println s!"mathml gate: {o.file}"
  IO.println s!"  rows in file        {rowLines.length}"
  IO.println s!"  header claims       {header.total}"
  IO.println s!"  examined            {examined}"
  IO.println s!"  asserted            {asserted}"
  IO.println s!"  matched             {matched}"
  IO.println s!"  refused by us       {declined.size}"
  IO.println s!"  differing           {differing.size}"
  IO.println s!"  refused by oracle   {oracleRefusals.size}"

  if !oracleRefusals.isEmpty then
    IO.println ""
    IO.println s!"math-core refuses these {oracleRefusals.size} rows; what this library does with"
    IO.println "them is reported, not asserted:"
    for (row, ours) in oracleRefusals do
      IO.println s!"  id {row.id}  {row.source}  {row.latex}"
      IO.println s!"    ours   {show? ours}"

  if !declined.isEmpty then
    IO.println ""
    IO.println s!"refused {declined.size} rows math-core converts:"
    for row in declined do
      IO.println s!"  id {row.id}  {row.source}  {row.latex}"
      IO.println s!"    oracle {show? row.mathml}"
      IO.println "    ours   <none>"

  if !differing.isEmpty then
    IO.println ""
    IO.println s!"differ from the oracle: {differing.size}"
    for (row, expected, ours) in differing do
      IO.println s!"  id {row.id}  {row.source}  {row.latex}"
      IO.println s!"    oracle {expected}"
      IO.println s!"    ours   {ours}"

  IO.println ""
  if !differing.isEmpty then
    return ← fail
      s!"{differing.size} of {asserted} rows differ from the Rust half, and on this input a difference is a defect"
  if !declined.isEmpty then
    return ← fail
      s!"{declined.size} of {asserted} rows math-core converts were refused"
  IO.println s!"mathml gate result: {matched} / {asserted} match the Rust half byte for byte"
  return 0

end Mathml

def main (args : List String) : IO UInt32 := do
  match Mathml.parseArgs args with
  | .ok o => Mathml.run o
  | .error e =>
    IO.eprintln s!"mathml FAILED: {e}"
    IO.eprintln Mathml.usage
    return 1
