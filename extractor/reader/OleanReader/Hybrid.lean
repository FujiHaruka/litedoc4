import OleanReader.Assemble
import Extract
open Lean OleanReader Litedoc4

namespace OleanReader.Hybrid

def readerSource : String := String.join [
  include_str "Writers.lean", include_str "Read.lean", include_str "Entries.lean",
  include_str "Module.lean", include_str "Serialize.lean", include_str "Oracle.lean",
  include_str "Assemble.lean", include_str "Hybrid.lean", include_str "Main.lean"]

def readBy : List (String × String) :=
  [("reader", fnv1a64Hex readerSource), ("readerLean", Lean.versionString),
   ("readerLeanGithash", Lean.githash)]

structure HardStops where
  verso : IO.Ref (Array Name)
  builtinDoc : IO.Ref (Array Name)

def HardStops.new : IO HardStops := return { verso := ← IO.mkRef #[], builtinDoc := ← IO.mkRef #[] }

partial def inheritTarget (inherit : Std.HashMap Name Name) (n : Name) (seen : NameSet := {}) : Name :=
  match inherit[n]? with
  | some u => if seen.contains u then n else inheritTarget inherit u (seen.insert n)
  | none => n

def hybridWorld (env : Environment) (o : Assemble.OldWorld) (writer : WriterVersion) (hs : HardStops) :
    World :=
  { moduleNames := o.moduleNames
    moduleIndex? := fun m => o.index[m]?
    constNames := fun i => o.constNames[i]!
    imports := fun i => o.imports[i]!
    moduleOf? := fun n => o.modOf[n]?
    contains := fun n => o.consts.contains n
    moduleDocs := fun m => o.modDocs.getD m #[]
    docString? := fun n => do
      let t := inheritTarget o.inherit ((Parser.Tactic.Doc.alternativeOfTactic env n).getD n)
      if o.docKeys.contains t then
        findDocString? env n
      else if o.versoKeys.contains t then
        hs.verso.modify (·.push n)
        return some s!"<hard stop: the docstring of {t} is Verso and was not decoded>"
      else
        match ← findDocString? env n with
        | none => return none
        | some _ =>
          hs.builtinDoc.modify (·.push n)
          return some s!"<hard stop: the docstring of {t} came from Lean {Lean.versionString}'s builtin table>"
    tactics := pure none
    leanVersion := writer.leanVersion
    leanGithash := writer.githash
    readBy }

def autoParamTactics (e : Expr) : Array Name :=
  let used := e.getUsedConstants
  if !used.contains ``autoParam then #[]
  else used.filter fun c =>
    (e.find? fun s => s.isAppOfArity ``autoParam 2 && s.appArg!.isConstOf c).isSome

structure AutoParams where
  oldOnly : Array (Name × Name) := #[]
  newestDiffers : Array (Name × Name) := #[]
  newestEqual : Nat := 0

def autoParamUses (d : Assemble.Decoded) (targets : Array Name) : Array (Name × Name) := Id.run do
  let mut out := #[]
  for (m, md) in d.mods do
    unless targets.contains m do continue
    for ci in md.constants do
      for tac in autoParamTactics ci.type do out := out.push (ci.name, tac)
  return out

def classifyAutoParams (uses : Array (Name × Name)) (sameValue : Std.HashMap Name Bool) : AutoParams :=
  uses.foldl (init := {}) fun a (decl, tac) =>
    match sameValue[tac]? with
    | none => { a with oldOnly := a.oldOnly.push (decl, tac) }
    | some false => { a with newestDiffers := a.newestDiffers.push (decl, tac) }
    | some true => { a with newestEqual := a.newestEqual + 1 }

structure Args where
  old : Array System.FilePath := #[]
  new : Array System.FilePath := #[]
  newRoots : Option System.FilePath := none
  extractor : List String := []

def usage : String := "\n".intercalate [
  "usage: reader extract --old <search-dir>... --new <search-dir>... --new-roots <modules.txt>",
  "                      <modules.txt> <events.jsonl> [extractor flags]",
  "       reader extract --identity [extractor flags]",
  "  --old        a search directory of the version read: its Lean's lib/lean and its packages' builds",
  "  --new        a search directory of the newest version, built by this reader's Lean",
  "  --new-roots  the newest version's modules, imported for its code (notation, delaborators)",
  "  everything after these is the extractor's own command line (Extract.lean's parseArgs)"]

def parseReaderArgs : List String → Args → Args
  | "--old" :: d :: rest, a => parseReaderArgs rest { a with old := a.old.push d }
  | "--new" :: d :: rest, a => parseReaderArgs rest { a with new := a.new.push d }
  | "--new-roots" :: f :: rest, a => parseReaderArgs rest { a with newRoots := some f }
  | rest, a => { a with extractor := rest }

def refusedFlag? (cfg : Cfg) : Option (String × String) :=
  if cfg.tacticsDumpPath.isSome then some ("--dump-tactics", "it lists the running Lean's tactic table")
  else if cfg.tacticsEmulate then some ("--tactics-emulate", "it runs doc-gen4's tactic collection over the running Lean's tables")
  else if cfg.tacticsProbe then some ("--tactics-probe", "it times the running Lean's tactic tables")
  else if cfg.serve then some ("--serve", "a resident extractor re-imports natively")
  else none

unsafe def extractMain (args : List String) : IO UInt32 := do
  let a := parseReaderArgs args {}
  let cfg ← match parseArgs a.extractor with
    | .ok cfg => pure cfg
    | .error msg => IO.eprintln s!"{msg}\n{usage}"; return 2
  if let some (flag, why) := refusedFlag? cfg then
    IO.eprintln s!"reader extract: {flag} is refused: {why}, and the version read is not the running Lean"
    return 2
  if cfg.identity then
    IO.println (← extractorIdentity cfg "" "" readBy)
    return 0
  let some newRootsFile := a.newRoots | IO.eprintln s!"reader extract: --new-roots is required\n{usage}"; return 2
  if a.old.isEmpty || a.new.isEmpty then
    IO.eprintln s!"reader extract: --old and --new each need at least one search directory\n{usage}"
    return 2
  let targets ← readNameList cfg.modulesPath
  let newRoots ← readNameList newRootsFile
  if targets.isEmpty || newRoots.isEmpty then
    IO.eprintln s!"reader extract: no module names in {if targets.isEmpty then cfg.modulesPath else newRootsFile}"
    return 2
  try
    let s ← Session.new a.old
    let mods ← closure s targets
    let d ← Assemble.decodeAll s mods
    let uses := autoParamUses d targets
    let (env, merged) ← Assemble.assembleHybrid d a.new newRoots
      (uses.foldl (fun acc (_, tac) => acc.insert tac) {})
    builtinDeclRanges.set {}
    let hs ← HardStops.new
    let code ← Litedoc4.run cfg (some (env, hybridWorld env d.old d.writer hs))
    let autoParams := classifyAutoParams uses merged.sameValue
    let verso ← hs.verso.get
    let builtin ← hs.builtinDoc.get
    IO.println s!"reader               Lean {d.writer.leanVersion} ({d.writer.githash}) read in Lean \
      {Lean.versionString}: {mods.size} modules, {d.stats.constants} constants, \
      {d.stats.entriesDecoded} extension entries decoded, {d.stats.entriesSkipped} not decoded \
      in {d.stats.skippedExts.size} extensions"
    for l in merged.counts.lines do IO.println s!"  {l}"
    IO.println s!"hard stops           verso={verso.size} builtin-doc={builtin.size} tactic-table=1 \
      autoparam-old-only={autoParams.oldOnly.size} autoparam-newest={autoParams.newestDiffers.size}"
    IO.println s!"  tactic-table: no module carries tactics; the running Lean's table is not the old version's"
    IO.println s!"  autoparam: {autoParams.newestEqual} binder tactic(s) whose newest code has the old value"
    for n in verso do IO.println s!"  verso {n}"
    for n in builtin do IO.println s!"  builtin-doc {n}"
    for (decl, tac) in autoParams.oldOnly do
      IO.println s!"  autoparam-old-only {decl} {tac}: no newest code to evaluate, the declaration fails to print"
    for (decl, tac) in autoParams.newestDiffers do
      IO.println s!"  autoparam-newest {decl} {tac}: printed with the newest version's tactic text"
    return code
  catch e =>
    IO.eprintln s!"olean reader: refused: {e}"
    return 1

end OleanReader.Hybrid
