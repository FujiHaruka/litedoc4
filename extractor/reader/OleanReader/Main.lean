import OleanReader.Oracle
import OleanReader.Hybrid
open Lean OleanReader

def usage : String := "\n".intercalate [
  "usage: reader --writers",
  "       reader --registered-extensions",
  "       reader read <search-dir> <module>...",
  "       reader oracle <search-dir> <seed> <count|all>",
  "       reader extract ... (reader extract --help)",
  "       reader session ... (reader session --help)"]

def readMain (dir : String) (roots : Array Name) : IO UInt32 := do
  let s ← Session.new #[dir]
  let stats ← IO.mkRef ({} : ReadStats)
  let mods ← readClosure s roots stats
  let some (w, _) ← s.firstWriter.get | throw <| IO.userError "olean reader: nothing was read"
  for rm in mods do IO.println s!"module {rm.name}"
  let st ← stats.get
  IO.println s!"read {mods.size} modules written by Lean {w.leanVersion} ({w.githash}): \
    {st.constants} constants, {st.entriesDecoded} extension entries decoded, \
    {st.entriesSkipped} not decoded in {st.skippedExts.size} extensions"
  return 0

def oracleMain (dir seed count : String) : IO UInt32 := do
  let s ← Session.new #[dir]
  let k? := if count == "all" then none else some count.toNat!
  let st ← oracleText s (← IO.getStdout) seed.toNat!.toUInt64 k?
  IO.eprintln s!"oracle: {st.constants} constants, {st.entriesDecoded} entries decoded, \
    {st.entriesSkipped} not decoded; checked against the stored computed field: Name hashes \
    {st.names}, Level data {st.levels}, Expr data {st.exprs}"
  return 0

unsafe def main (args : List String) : IO UInt32 := do
  if let .error why := checkWriters (← registeredExts) then
    IO.eprintln s!"olean reader: the writer table is inconsistent: {why}"
    return 3
  if let "extract" :: rest := args then
    if rest == ["--help"] then
      IO.println Hybrid.usage
      return 0
    return ← Hybrid.extractMain rest
  if let "session" :: rest := args then
    return ← Hybrid.sessionMain rest
  try
    match args with
    | ["--writers"] =>
      for w in writers do IO.println w.describe
      return 0
    | ["--registered-extensions"] =>
      for n in ← registeredExts do IO.println n
      return 0
    | "read" :: dir :: m :: ms => readMain dir ((m :: ms).toArray.map String.toName)
    | ["oracle", dir, seed, count] => oracleMain dir seed count
    | _ =>
      IO.eprintln usage
      return 2
  catch e =>
    IO.eprintln s!"olean reader: refused: {e}"
    return 1
