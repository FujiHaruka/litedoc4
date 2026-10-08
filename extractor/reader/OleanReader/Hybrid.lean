import OleanReader.Check
import OleanReader.Patch
import Extract
import Std.Async.Process
open Lean OleanReader Litedoc4

namespace OleanReader.Hybrid

def readerSource : String := String.join [
  include_str "Writers.lean", include_str "Read.lean", include_str "Entries.lean",
  include_str "Module.lean", include_str "Serialize.lean", include_str "Oracle.lean",
  include_str "Assemble.lean", include_str "Check.lean", include_str "Patch.lean", include_str "Hybrid.lean",
  include_str "Main.lean"]

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

/-! ## Lean reference manual links, rewritten with the version's own root

**Copied from Lean's `src/Lean/DocString/Links.lean` (v4.34.1)**, changed only by dropping its
comments, taking the root as an argument, and returning the text outside `BaseIO`:

    Copyright (c) 2025 Lean FRO, LLC. All rights reserved.
    Released under Apache 2.0 license as described in the file LICENSE.
    Authors: David Thrane Christiansen
-/

namespace ManualLinks

def domainMap : Std.HashMap String String :=
  Std.HashMap.ofList [
    ("section", "Verso.Genre.Manual.section"),
    ("errorExplanation", errorExplanationManualDomain)
  ]

def rw (path : String) : Except String String := do
  match path.split '/' |>.toStringList with
  | [] | [""] =>
    throw "Missing documentation type"
  | kind :: args =>
    if let some domain := domainMap.get? kind then
      if let [s] := args then
        if s.isEmpty then
          throw s!"Empty {kind} ID"
        return s!"find/?domain={domain}&name={s}"
      else
        throw s!"Expected one item after `{kind}`, but got {args}"
    else
      let acceptableKinds := ", ".intercalate <| domainMap.toList.map fun (k, _) => s!"`{k}`"
      throw s!"Unknown documentation type `{kind}`. Expected one of the following: {acceptableKinds}"

def urlChar (c : Char) : Bool :=
  c.isAlphanum || c == '-' || c == '.' || c == '_' || c == '~' ||
  c == ':' || c == '/' || c == '?' || c == '#' || c == '[' || c == ']' || c == '@' ||
  c == '!' || c == '$' || c == '&' || c == '\'' || c == '*' ||
  c == '+' || c == ',' || c == ';' || c == '='

def rewriteCore (root s : String) : Id (Array (Lean.Syntax.Range × String) × String) := do
  let scheme := "lean-manual://"
  let mut out := ""
  let mut errors := #[]
  let mut iter := s.startPos
  while h : ¬iter.IsAtEnd do
    let c := iter.get h
    let pre := iter
    iter := iter.next h

    match pre.skip? scheme with
    | none =>
      out := out.push c
      continue
    | some start =>
      let mut iter' := start
      while h' : ¬iter'.IsAtEnd do
        let c' := iter'.get h'
        let pre' := iter'
        iter' := iter'.next h'
        if urlChar c' && ¬iter'.IsAtEnd then
          continue
        match rw (s.extract start pre') with
        | .error err =>
          errors := errors.push (⟨pre.offset, pre'.offset⟩, err)
          out := out.push c
          break
        | .ok path =>
          out := out ++ root ++ path
          out := out.push c'
          iter := iter'
          break

  pure (errors, out)

def rewrite (root docString : String) : String := Id.run do
  let (errs, str) ← rewriteCore root docString
  if !errs.isEmpty then
    let errReport :=
      r#"**❌ Syntax Errors in Lean Language Reference Links**

The `lean-manual` URL scheme is used to link to the version of the Lean reference manual that
corresponds to this version of Lean. Errors occurred while processing the links in this documentation
comment:
"# ++
      String.join (errs.toList.map (fun (⟨s, e⟩, msg) => s!" * ```{String.Pos.Raw.extract docString s e}```: {msg}\n\n"))
    return str ++ "\n\n" ++ errReport
  return str

end ManualLinks

-- Not `findDocString?`: it ends in `rewriteManualLinks`, which reads the running Lean's manual root, fixed at process start.
def docStringBeforeLinks? (env : Environment) (declName : Name) : IO (Option String) := do
  let declName := (Parser.Tactic.Doc.alternativeOfTactic env declName).getD declName
  let exts := Parser.Tactic.Doc.getTacticExtensionString env declName
  let spellings := Parser.Term.Doc.getRecommendedSpellingString env declName
  return (← findSimpleDocString? env declName).map (· ++ exts ++ spellings)

def hybridWorld (env : Environment) (o : Assemble.OldWorld) (writer : WriterVersion) (manualRoot : String)
    (hs : HardStops) : World :=
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
        return (← docStringBeforeLinks? env n).map (ManualLinks.rewrite manualRoot)
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

def invariantFailure (d : Assemble.Decoded) (cl : Check.ClosureCounts) (il : Check.IleanCounts) : Option String :=
  if let some x := cl.dangling[0]? then
    some s!"module {x.module}: {x.constant} mentions {x.missing}, which no module of Lean \
      {d.writer.leanVersion}'s import closure declares ({cl.dangling.size} dangling reference(s) in all)"
  else if let some p := il.problems[0]? then
    some s!"{p} ({il.problems.size} disagreement(s) in all)"
  else none

def invariantLines (cl : Check.ClosureCounts) (il : Check.IleanCounts) : List String := [
  s!"invariants           closure: {cl.constants} constants, {cl.references} references checked, \
    {cl.dangling.size} dangling ({cl.ms} ms)",
  s!"  ilean              {il.modules} modules ({il.bytes} bytes), {il.compared} declarations listed and equal, \
    {il.problems.size} disagree ({il.ms} ms)",
  s!"  ilean-no-parent    {il.notListed} decoded ranges: no reference the module records has the \
    declaration as its parent, and the .ilean lists parents only",
  s!"  ilean-imported     {il.imported} listed parents declared by an imported module (an `attribute` \
    command on it): equal to that module's decoded range, which the writer looked up in the command's environment",
  s!"  ilean-in-theorem   {il.inTheorem} decoded ranges: a parent nested in a theorem's range (let rec, \
    where), elaborated asynchronously; the .ilean writer looks ranges up in the command's environment"]

def manualProbe : String :=
  "é [a](lean-manual://section/tactic-macro-extension) [b](lean-manual://errorExplanation/lean.unknownIdentifier)\n\
  ü lean-manual://nope/x (lean-manual://section/) lean-manual:// lean-manual://section/a/b\n\
  end lean-manual://section/last-one"

def utf8Hex (s : String) : String :=
  String.join (s.toUTF8.toList.map fun b => hexDigitRepr (b.toNat / 16) ++ hexDigitRepr (b.toNat % 16))

def manualRootProgram : String := "\n".intercalate [
  "import Lean.DocString.Links",
  s!"def probe : String := {manualProbe.quote}",
  "def hex (s : String) : String :=",
  "  String.join (s.toUTF8.toList.map fun b => hexDigitRepr (b.toNat / 16) ++ hexDigitRepr (b.toNat % 16))",
  "#eval show IO Unit from do IO.println s!\"{Lean.githash} {Lean.manualRoot} {hex (← Lean.rewriteManualLinks probe)}\"",
  ""]

structure OldManualRoot where
  lean : System.FilePath
  githash : String
  root : String
  probeHex : String
  ms : Nat

-- Not the old toolchain's include/lean/version.h: it holds only the pre-configured root, and `manualRoot`'s initializer also reads LEAN_MANUAL_ROOT and falls back to `latest`.
def askOldManualRoot (s : Session) : IO OldManualRoot := do
  let t0 ← IO.monoMsNow
  let prelude ← findOlean s `Init.Prelude
  let some lib := prelude.parent.bind (·.parent)
    | throw <| IO.userError s!"manual root: {prelude} has no toolchain directory above it"
  let some top := lib.parent.bind (·.parent)
    | throw <| IO.userError s!"manual root: {lib} is not a toolchain's lib/lean"
  let lean := top / "bin" / "lean"
  unless ← lean.pathExists do
    throw <| IO.userError s!"manual root: the version read takes Init.Prelude from {lib}, and there is no {lean} \
      to ask for its manual root"
  let out ← IO.FS.withTempFile fun h path => do
    h.putStr manualRootProgram
    h.flush
    IO.Process.output { cmd := lean.toString, args := #[path.toString], env := #[("LEAN_PATH", some lib.toString)] }
  let fail (why : String) : IO OldManualRoot :=
    throw <| IO.userError s!"manual root: {lean} was asked for Lean.manualRoot and {why}"
  if out.exitCode != 0 then
    return ← fail s!"exited {out.exitCode}: {(out.stdout ++ out.stderr).trimAscii.toString.take 400}"
  match out.stdout.trimAscii.toString.splitOn " " with
  | [githash, root, probeHex] => return { lean, githash, root, probeHex, ms := (← IO.monoMsNow) - t0 }
  | _ => fail s!"printed {out.stdout.take 400}, not a githash, a root and the probe's rewrite"

def checkManualCopy (r : OldManualRoot) (w : WriterVersion) : IO Unit := do
  let copy := utf8Hex (ManualLinks.rewrite r.root manualProbe)
  unless copy == r.probeHex do
    let same := (copy.toList.zip r.probeHex.toList).takeWhile (fun (a, b) => a == b) |>.length
    throw <| IO.userError s!"manual root: {r.lean} (Lean {w.leanVersion}) rewrites the probe docstring to \
      {r.probeHex.length / 2} bytes and the reader's copy of rewriteManualLinks, given the same root {r.root}, \
      to {copy.length / 2}; they differ from byte {same / 2}, so Lean {w.leanVersion}'s docstrings cannot be rewritten \
      as it would"

def manualRootLine (r : OldManualRoot) : String :=
  s!"manual root          {r.root} answered by {r.lean} in {r.ms} ms; the reader's copy rewrites the probe \
    docstring as it does ({r.probeHex.length / 2} bytes)"

def checkArgs (a : Args) : IO (Except String (Cfg × Array Name)) := do
  let cfg ← match parseArgs a.extractor with
    | .ok cfg => pure cfg
    | .error msg => return .error msg
  if let some (flag, why) := refusedFlag? cfg then
    return .error s!"{flag} is refused: {why}, and the version read is not the running Lean"
  if cfg.identity then return .error "--identity names no version to read"
  if a.old.isEmpty then return .error "--old needs at least one search directory"
  let targets ← readNameList cfg.modulesPath
  if targets.isEmpty then return .error s!"no module names in {cfg.modulesPath}"
  return .ok (cfg, targets)

structure Newest where
  state : Assemble.MImportState
  imports : Array Import

unsafe def importNewest (search : Array System.FilePath) (roots : Array Name) : IO Newest := do
  let imports := roots.map ({ module := · })
  return { state := ← Assemble.importNewest search imports, imports }

structure PatchSession where
  check : Bool
  perturb : Bool
  index : Patch.NewestIndex
  last : IO.Ref (Option (Assemble.Prev × Option (Patch.Built × String)))

def patchLine (from? : Option String) (sh : Assemble.ShareCounts) (st : Patch.Stats) (modules : Nat) : String :=
  let shared := s!"decoded objects replaced by the previous version's: constants {sh.constantsShared} of \
    {sh.constants}, entries {sh.entriesShared} of {sh.entries}"
  match from? with
  | none => s!"patch                built whole: {modules} newest modules rewritten; {shared}"
  | some v =>
    s!"patch                from Lean {v}: constants same {st.constSame}, changed {st.constChanged}, added \
      {st.constAdded}, removed {st.constRemoved}; {shared}; newest modules {modules}, rewritten {st.dirty} \
      (constants {st.dirtyConst}: by name {st.byName}, realizations {st.byRealization}, field functions \
      {st.byFieldFn}; entries {st.dirtyEntries}: placed old entries {st.byOlds}, kept-newest filter {st.byFilter})"

def checkLines (c : Patch.Comparison) : Array String :=
  #[s!"check-patch          {c.modules.size} modules differ from rewriteMerge's state, pointer by pointer; \
      {c.other.size} other differences"] ++
    c.modules.map (fun (m, why) => s!"  check-patch-module {m}: {why}") ++
    c.other.map (s!"  check-patch-other {·}")

def checkFailure (c : Patch.Comparison) : String :=
  match c.modules[0]?, c.other[0]? with
  | some (m, why), _ => s!"module {m} differs from rewriteMerge's: {why} ({c.modules.size} module(s) in all)"
  | none, some why => why
  | none, none => ""

unsafe def patchRound (p : PatchSession) (ms : Assemble.MImportState) (d : Assemble.Decoded)
    (sh : Assemble.Prev × Assemble.ShareCounts) (ask : Std.HashSet Name) :
    IO (Assemble.Merged × Array String × Option String) := do
  let (next, counts) := sh
  let from? := (← p.last.get).bind (·.2)
  let (b, m, st) ← Patch.build p.index d ask (from?.map (·.1)) { perturb := p.perturb }
  let mut lines := #[patchLine (from?.map (·.2)) counts st p.index.names.size]
  if let some name := st.perturbed then lines := lines.push s!"patch-perturbed      {name} left unrewritten"
  if st.perturbedNothing then lines := lines.push "patch-perturbed      nothing: no changed constant made a newest module be rewritten"
  if p.check then
    let c := Patch.compare m (← Assemble.rewriteMerge ms d ask)
    lines := lines ++ checkLines c
    unless c.clean do
      p.last.set (some (next, none))
      return (m, lines, some (checkFailure c))
  p.last.set (some (next, some (b, d.writer.leanVersion)))
  return (m, lines, none)

unsafe def readVersion (a : Args) (cfg : Cfg) (targets : Array Name) (newest : IO Newest) (resident : Bool)
    (patch? : Option PatchSession := none) : IO UInt32 := do
  try
    let s ← Session.new a.old
    let manual ← askOldManualRoot s
    let mods ← closure s targets
    let some (writer, _) ← s.firstWriter.get | throw <| IO.userError "olean reader: nothing was read"
    unless writer.githash == manual.githash do
      throw <| IO.userError s!"manual root: {manual.lean} is Lean {manual.githash}, and the version read was \
        written by Lean {writer.leanVersion} ({writer.githash})"
    checkManualCopy manual writer
    let prev? ← match patch? with
      | some p => pure (some (((← p.last.get).map (·.1)).getD {}))
      | none => pure none
    let (d, sh?) ← Assemble.decodeAll s mods prev?
    let cl ← Check.closure d
    let il ← Check.ilean s d
    if let some why := invariantFailure d cl il then
      IO.eprintln s!"reader extract: invariant failed, Lean {d.writer.leanVersion} is not read: {why}"
      return 1
    let uses := autoParamUses d targets
    let n ← newest
    let ask := uses.foldl (fun acc (_, tac) => acc.insert tac) {}
    let (merged, patchLines) ← match patch?, sh? with
      | some p, some sh =>
        let (m, lines, failure?) ← patchRound p n.state d sh ask
        if let some why := failure? then
          for l in lines do IO.println l
          IO.eprintln s!"reader session: check-patch failed, Lean {d.writer.leanVersion} is not read: {why}"
          return 1
        pure (m, lines)
      | _, _ => pure (← Assemble.rewriteMerge n.state d ask, #[])
    let env ← Assemble.finalizeHybrid merged.out n.imports merged.idxOf (leak := !resident)
    builtinDeclRanges.set {}
    let hs ← HardStops.new
    let code ← Litedoc4.run cfg (some (env, hybridWorld env d.old d.writer manual.root hs))
    let realizations ← if resident then Assemble.clearRealizations env else pure 0
    let autoParams := classifyAutoParams uses merged.sameValue
    let verso ← hs.verso.get
    let builtin ← hs.builtinDoc.get
    IO.println (manualRootLine manual)
    for l in invariantLines cl il do IO.println l
    IO.println s!"reader               Lean {d.writer.leanVersion} ({d.writer.githash}) read in Lean \
      {Lean.versionString}: {mods.size} modules, {d.stats.constants} constants, \
      {d.stats.entriesDecoded} extension entries decoded, {d.stats.entriesSkipped} not decoded \
      in {d.stats.skippedExts.size} extensions"
    for l in merged.counts.lines do IO.println s!"  {l}"
    for l in patchLines do IO.println l
    if resident then
      IO.println s!"realizations         {realizations} realized constants of imported declarations emptied \
        with the round's environment"
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

unsafe def extractMain (args : List String) : IO UInt32 := do
  let a := parseReaderArgs args {}
  if let .ok cfg := parseArgs a.extractor then
    if cfg.identity then
      IO.println (← extractorIdentity cfg "" "" readBy)
      return 0
  let some newRootsFile := a.newRoots | IO.eprintln s!"reader extract: --new-roots is required\n{usage}"; return 2
  if a.new.isEmpty then
    IO.eprintln s!"reader extract: --old and --new each need at least one search directory\n{usage}"
    return 2
  let (cfg, targets) ← match ← checkArgs a with
    | .ok r => pure r
    | .error why => IO.eprintln s!"reader extract: {why}\n{usage}"; return 2
  let newRoots ← readNameList newRootsFile
  if newRoots.isEmpty then
    IO.eprintln s!"reader extract: no module names in {newRootsFile}"
    return 2
  readVersion a cfg targets (importNewest a.new newRoots) (resident := false)

def sessionUsage : String := "\n".intercalate [
  "usage: reader session --new <search-dir>... --new-roots <modules.txt> [--check-patch]",
  "                      [--perturb-patch] [--no-field-fn-index]",
  "  imports the newest version once and prints `ready <nanoseconds> <modules>`; then one request per line",
  "  on stdin, its fields separated by tabs:",
  "    --old <search-dir>... <modules.txt> <events.jsonl> [extractor flags]",
  "  which is reader extract's command line without --new and --new-roots. The first request's hybrid",
  "  is built whole from the newest import, every later one patched from the last one built; each is",
  "  answered with `round <n>`, reader extract's summary, a `patch` line, an `rss` line and",
  "  `ok <exit code> <nanoseconds>`; one that is not run is answered `err <why>`. EOF or an empty line",
  "  ends the session.",
  "  --check-patch        also build each request's hybrid from scratch and compare the two module by",
  "                       module, pointer by pointer; a difference fails the request before anything is",
  "                       written (`check-patch` lines)",
  "  --perturb-patch      leave the last module a changed constant would have rewritten as it was (for",
  "                       the gate)",
  "  --no-field-fn-index  do not rewrite the newest modules holding a structure field's default or",
  "                       autoParam function when the structure appears or disappears (for the gate)"]

def sessionFlags : List String := ["--check-patch", "--perturb-patch", "--no-field-fn-index"]

def residentKb : IO (Option Nat) := do
  let out ← IO.Process.output { cmd := "ps", args := #["-o", "rss=", "-p", toString (← IO.Process.getPID)] }
  return if out.exitCode == 0 then out.stdout.trimAscii.toString.toNat? else none

def rssLine (round : Nat) : IO String := do
  let peak := (← Std.IO.Process.getResourceUsage).peakResidentSetSizeKb.toNat
  let now := match ← residentKb with
    | some kb => s!"{kb / 1024} MiB"
    | none => "unknown"
  return s!"rss                  round {round}: peak {peak / 1024} MiB (the process's maximum so far: a round \
    raises it only by needing more than every round before it), resident {now} after the round"

unsafe def sessionMain (args : List String) : IO UInt32 := do
  if args == ["--help"] then
    IO.println sessionUsage
    return 0
  let (flags, args) := args.partition sessionFlags.contains
  let a := parseReaderArgs args {}
  let some newRootsFile := a.newRoots | IO.eprintln s!"reader session: --new-roots is required\n{sessionUsage}"; return 2
  if a.new.isEmpty || !a.old.isEmpty || !a.extractor.isEmpty then
    IO.eprintln s!"reader session: the session takes --new and --new-roots only; each request names its version\n\
      {sessionUsage}"
    return 2
  let newRoots ← readNameList newRootsFile
  if newRoots.isEmpty then
    IO.eprintln s!"reader session: no module names in {newRootsFile}"
    return 2
  let t0 ← IO.monoNanosNow
  let newest ← match ← (importNewest a.new newRoots).toBaseIO with
    | .ok n => pure n
    | .error e =>
      IO.eprintln s!"olean reader: refused: the newest version was not imported: {e}"
      return 1
  let patch : PatchSession := {
    check := flags.contains "--check-patch", perturb := flags.contains "--perturb-patch"
    index := Patch.buildNewestIndex newest.state (fieldFnIndex := !flags.contains "--no-field-fn-index")
    last := ← IO.mkRef none }
  IO.println s!"ready {(← IO.monoNanosNow) - t0} {newest.state.moduleNames.size}"
  let stdout ← IO.getStdout
  stdout.flush
  let stdin ← IO.getStdin
  let mut round := 0
  repeat
    let line := (← stdin.getLine).trimAscii.toString
    if line.isEmpty then break
    let r := parseReaderArgs ((line.splitOn "\t").filter (!·.isEmpty)) {}
    let checked : Except String (Cfg × Array Name) ←
      if !r.new.isEmpty || r.newRoots.isSome then
        pure (.error "a request names no newest version: the session imported it at its start")
      else
        match ← (checkArgs r).toBaseIO with
        | .ok c => pure c
        | .error e => pure (.error (toString e))
    match checked with
    | .error why => IO.println s!"err {why}"
    | .ok (cfg, targets) =>
      round := round + 1
      IO.println s!"round {round}"
      let r0 ← IO.monoNanosNow
      let code ← readVersion r cfg targets (pure newest) (resident := true) (some patch)
      let r1 ← IO.monoNanosNow
      IO.println (← rssLine round)
      IO.println s!"ok {code} {r1 - r0}"
    stdout.flush
  return 0

end OleanReader.Hybrid
