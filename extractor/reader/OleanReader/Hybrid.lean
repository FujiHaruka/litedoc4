import OleanReader.Check
import OleanReader.Patch
import OleanReader.PrintKey
import OleanReader.Carry
import Extract
import Std.Async.Process
open Lean OleanReader Litedoc4

namespace OleanReader.Hybrid

def readerSource : String := String.join [
  include_str "Writers.lean", include_str "Read.lean", include_str "Entries.lean",
  include_str "Module.lean", include_str "Serialize.lean", include_str "Oracle.lean",
  include_str "Assemble.lean", include_str "Check.lean", include_str "Patch.lean", include_str "PrintKey.lean",
  include_str "Carry.lean", include_str "Hybrid.lean", include_str "Main.lean"]

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

structure Phases where
  spans : IO.Ref (Array (String × Nat))
  last : IO.Ref Nat

def Phases.new : IO Phases := do
  let t ← IO.monoNanosNow
  return { spans := ← IO.mkRef #[], last := ← IO.mkRef t }

def Phases.add (p : Phases) (name : String) (ns : Nat) : IO Unit := p.spans.modify (·.push (name, ns))

def Phases.markLess (p : Phases) (name : String) (parts : Array (String × Nat)) : IO Unit := do
  let t ← IO.monoNanosNow
  p.add name (t - (← p.last.get) - parts.foldl (· + ·.2) 0)
  for (n, ns) in parts do p.add n ns
  p.last.set t

def Phases.mark (p : Phases) (name : String) : IO Unit := p.markLess name #[]

def msText (ns : Nat) : String :=
  let cs := ns / 10000
  let frac := toString (cs % 100)
  s!"{cs / 100}.{if frac.length < 2 then "0" ++ frac else frac} ms"

def Phases.line (p : Phases) : IO String := do
  p.mark "rest"
  let spans ← p.spans.get
  let total := spans.foldl (fun t (_, ns) => t + ns) 0
  return s!"phases               {", ".intercalate (spans.toList.map fun (n, ns) => s!"{n} {msText ns}")}; \
    total {msText total}"

structure Printed where
  keys : Std.HashMap Name UInt64
  out : Std.HashMap Name DeclOut

structure PatchSession where
  check : Bool
  perturb : Bool
  presence : Bool
  index : Patch.NewestIndex
  last : IO.Ref (Option (Assemble.Prev × Option (Patch.Built × String)))
  carry : IO.Ref (Option Carry.State)

structure ReuseSession where
  scx : Bool
  checkKeys : Bool
  printed : IO.Ref (Option Printed)
  patch? : Option PatchSession

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

unsafe def patchRound (p : PatchSession) (ph : Phases) (ms : Assemble.MImportState) (d : Assemble.Decoded)
    (sh : Assemble.Prev × Assemble.ShareCounts) (ask : Std.HashSet Name) :
    IO (Assemble.Merged × Array String × Option String × Option (Carry.State × Patch.Delta)) := do
  let (next, counts) := sh
  let carried ← p.carry.modifyGet fun c => (c, none)
  let from? := (← p.last.get).bind (·.2)
  let (b, m, st, delta) ← Patch.build p.index d ask (from?.map (·.1)) next.prints { perturb := p.perturb }
  let mut lines := #[patchLine (from?.map (·.2)) counts st p.index.names.size]
  if let some name := st.perturbed then lines := lines.push s!"patch-perturbed      {name} left unrewritten"
  if st.perturbedNothing then lines := lines.push "patch-perturbed      nothing: no changed constant made a newest module be rewritten"
  ph.mark "patch"
  if p.check then
    let c := Patch.compare m (← Assemble.rewriteMerge ms d ask)
    lines := lines ++ checkLines c
    ph.mark "check-patch"
    unless c.clean do
      p.last.set (some (next, none))
      return (m, lines, some (checkFailure c), none)
  p.last.set (some (next, some (b, d.writer.leanVersion)))
  return (m, lines, none, match carried, delta with
    | some c, some d => some (c, d)
    | _, _ => none)

def reused? (prev : Option Printed) (keys : Std.HashMap Name UInt64) (n : Name) : Option DeclOut := do
  let p ← prev
  let k ← keys[n]?
  guard (p.keys[n]? == some k)
  p.out[n]?

structure ReuseCounts where
  reused : Nat := 0
  keyDiffers : Nat := 0
  keyEqual : Nat := 0
  noPrevious : Nat := 0
  new : Nat := 0

def ReuseCounts.reprinted (c : ReuseCounts) : Nat := c.keyDiffers + c.keyEqual + c.noPrevious + c.new

-- Not `reused?` asked again: that counts what was offered; reused is an output holding the previous round's `Sig` object.
unsafe def countReuse (prev : Option Printed) (keys : Std.HashMap Name UInt64) (results : Array DeclOut) : ReuseCounts :=
  results.foldl (init := {}) fun c d =>
    match prev.map fun p => (p.keys[d.name]?, p.out[d.name]?) with
    | none | some (none, _) => { c with new := c.new + 1 }
    | some (some _, none) => { c with noPrevious := c.noPrevious + 1 }
    | some (some k, some o) =>
      if ptrAddrUnsafe o.sig == ptrAddrUnsafe d.sig then { c with reused := c.reused + 1 }
      else if keys[d.name]? == some k then { c with keyEqual := c.keyEqual + 1 }
      else { c with keyDiffers := c.keyDiffers + 1 }

def reuseLine (scx : Bool) (st : Carry.Stats) (threads : Nat) (c : ReuseCounts) (produced : Nat) : String :=
  let key := if scx then "N1X + own" else "N1 + own (--key-without-scx)"
  s!"reuse                {c.reused} of {produced} declarations reused, {c.reprinted} reprinted (key differs \
    {c.keyDiffers}, key equal {c.keyEqual}, no previous output {c.noPrevious}, new {c.new}); key {key} of \
    {st.candidates} candidates: carried {st.carried}, recomputed {st.recomputed} (stale {st.stale}, new {st.new}) \
    in {st.ms} ms on {if threads ≤ 1 then "one thread" else s!"{threads} threads"}"

def carryLine (presence : Bool) (st : Carry.Stats) : String :=
  let memos := s!"memos entries/stale/changed: records {st.recs.text}, resolutions {st.res.text}, \
    facts {st.facts.text}, structure-instance defaults {st.scx.text}"
  let dropped := if presence then "" else "; presence flips dropped (--carry-without-presence)"
  if st.fromPrevious then
    s!"carry                from the previous round: delta constants {st.deltaConsts}, entries \
      {st.deltaEntries}, alias names {st.aliasKeys}; {memos}{dropped}"
  else s!"carry                nothing to carry from: every key computed; {memos}{dropped}"

def checkKeysLines (diffs : Array Carry.Difference) (keys jobs ms : Nat) : Array String :=
  #[s!"check-keys           {diffs.size} keys differ from a fresh pass ({keys} keys, fresh memos, {jobs} \
      thread(s), {ms} ms)"] ++ diffs.map (s!"  check-keys-differ {·.line}")

def residentKb : IO (Option Nat) := do
  let out ← IO.Process.output { cmd := "ps", args := #["-o", "rss=", "-p", toString (← IO.Process.getPID)] }
  return if out.exitCode == 0 then out.stdout.trimAscii.toString.toNat? else none

def peakKb : IO Nat := return (← Std.IO.Process.getResourceUsage).peakResidentSetSizeKb.toNat

def mibText : Option Nat → String
  | some kb => s!"{kb / 1024} MiB"
  | none => "unknown"

structure RssAtExtract where
  peakBefore : Nat
  residentBefore : Option Nat
  peakAfter : Nat

def RssAtExtract.line (r : RssAtExtract) : String :=
  s!"rss-at-extract       before extraction: peak {r.peakBefore / 1024} MiB, resident {mibText r.residentBefore}; \
    after it: peak {r.peakAfter / 1024} MiB"

def extractMeasured (ph : Phases) (extract : IO α) : IO (α × RssAtExtract) := do
  let peakBefore ← peakKb
  let residentBefore ← residentKb
  ph.mark "rss probe"
  let x ← extract
  let peakAfter ← peakKb
  ph.mark "extract"
  return (x, { peakBefore, residentBefore, peakAfter })

def keyMap (outs : Std.HashMap Name PrintKey.KeyOut) : Std.HashMap Name UInt64 :=
  outs.fold (fun m n o => m.insert n o.key) (Std.HashMap.emptyWithCapacity outs.size)

structure KeyPass where
  keys : Std.HashMap Name UInt64
  stats : Carry.Stats
  threads : Nat
  lines : Array String
  failure : Option String := none

unsafe def carriedKeys (r : ReuseSession) (p : PatchSession) (ph : Phases) (cfg : Cfg) (env : Environment)
    (world : World) (targets : Array Name) (start : Option (Carry.State × Patch.Delta)) : IO KeyPass := do
  let (outs, state, st, d?) ← Carry.run env world targets r.scx start p.presence
  let keys := keyMap outs
  let mut lines := #[carryLine p.presence st]
  ph.mark "key pass"
  if r.checkKeys then
    let t0 ← IO.monoNanosNow
    let fresh ← PrintKey.keys env world targets cfg.jobs r.scx
    let diffs ← Carry.compare env r.scx d? state outs fresh
    lines := lines ++ checkKeysLines diffs fresh.size (max cfg.jobs 1) (((← IO.monoNanosNow) - t0) / 1000000)
    ph.mark "check-keys"
    if let some x := diffs[0]? then
      return { keys, stats := st, threads := 1, lines, failure := some s!"{x.line} ({diffs.size} key(s) in all)" }
  p.carry.set (some state)
  return { keys, stats := st, threads := 1, lines }

unsafe def freshKeys (r : ReuseSession) (ph : Phases) (cfg : Cfg) (env : Environment) (world : World)
    (targets : Array Name) : IO KeyPass := do
  let t0 ← IO.monoNanosNow
  let outs ← PrintKey.keys env world targets cfg.jobs r.scx
  let candidates := (← PrintKey.candidates world targets).size
  let st : Carry.Stats := { candidates, new := outs.size, ms := ((← IO.monoNanosNow) - t0) / 1000000 }
  ph.mark "key pass"
  let threads := max cfg.jobs 1
  unless r.checkKeys do return { keys := keyMap outs, stats := st, threads, lines := #[] }
  let t1 ← IO.monoNanosNow
  let again ← PrintKey.keys env world targets cfg.jobs r.scx
  let diffs ← Carry.compare env r.scx none { memo := {}, decls := {}, aliases := {} } outs again
  let lines := checkKeysLines diffs again.size threads (((← IO.monoNanosNow) - t1) / 1000000)
  ph.mark "check-keys"
  return { keys := keyMap outs, stats := st, threads, lines,
           failure := diffs[0]?.map fun x => s!"{x.line} ({diffs.size} key(s) in all)" }

structure Reusing where
  code : UInt32
  lines : Array String
  printed : Printed
  failure : Option String
  atExtract : Option RssAtExtract

unsafe def extractReusing (r : ReuseSession) (ph : Phases) (cfg : Cfg) (env : Environment) (world : World)
    (targets : Array Name) (prev : Option Printed) (start : Option (Carry.State × Patch.Delta)) : IO Reusing := do
  let kp ← match r.patch? with
    | some p => carriedKeys r p ph cfg env world targets start
    | none => freshKeys r ph cfg env world targets
  if kp.failure.isSome then
    return { code := 1, lines := kp.lines, printed := { keys := kp.keys, out := {} }, failure := kp.failure,
             atExtract := none }
  let out ← IO.mkRef #[]
  let (code, atExtract) ← extractMeasured ph <|
    Litedoc4.run cfg (some (env, world)) (some { prev := reused? prev kp.keys, out })
  let results ← out.get
  let out := results.foldl (fun m d => m.insert d.name d) (Std.HashMap.emptyWithCapacity results.size)
  return { code, lines := kp.lines.push (reuseLine r.scx kp.stats kp.threads (countReuse prev kp.keys results) results.size),
           printed := { keys := kp.keys, out }, failure := none, atExtract }

unsafe def readVersion (a : Args) (cfg : Cfg) (targets : Array Name) (newest : IO Newest) (resident : Bool)
    (ph : Phases) (reuse? : Option ReuseSession := none) : IO UInt32 := do
  let prevPrinted ← match reuse? with
    | some r => r.printed.modifyGet fun s => (s, none)
    | none => pure none
  let patch? := reuse?.bind (·.patch?)
  try
    let s ← Session.new a.old
    let manual ← askOldManualRoot s
    ph.mark "manual root"
    let mods ← closure s targets
    let some (writer, _) ← s.firstWriter.get | throw <| IO.userError "olean reader: nothing was read"
    unless writer.githash == manual.githash do
      throw <| IO.userError s!"manual root: {manual.lean} is Lean {manual.githash}, and the version read was \
        written by Lean {writer.leanVersion} ({writer.githash})"
    checkManualCopy manual writer
    ph.mark "closure"
    let prev? ← match patch? with
      | some p => pure (some (((← p.last.get).map (·.1)).getD {}))
      | none => pure none
    let (d, sh?) ← Assemble.decodeAll s mods prev? (PrintKey.keyExts.foldl (·.insert ·) {})
    ph.markLess "decode" #[("hash", sh?.map (·.2.hashNs) |>.getD 0)]
    let cl ← Check.closure d
    ph.mark "check closure"
    let il ← Check.ilean s d
    ph.mark "check ilean"
    if let some why := invariantFailure d cl il then
      IO.eprintln s!"reader extract: invariant failed, Lean {d.writer.leanVersion} is not read: {why}"
      return 1
    let uses := autoParamUses d targets
    ph.mark "autoparams"
    let n ← newest
    ph.mark "newest import"
    let ask := uses.foldl (fun acc (_, tac) => acc.insert tac) {}
    let (merged, patchLines, carried) ← match patch?, sh? with
      | some p, some sh =>
        let (m, lines, failure?, carried) ← patchRound p ph n.state d sh ask
        if let some why := failure? then
          for l in lines do IO.println l
          IO.eprintln s!"reader session: check-patch failed, Lean {d.writer.leanVersion} is not read: {why}"
          return 1
        pure (m, lines, carried)
      | _, _ => do
        let m ← Assemble.rewriteMerge n.state d ask
        ph.mark "merge"
        pure (m, #[], none)
    let env ← Assemble.finalizeHybrid merged.out n.imports merged.idxOf (leak := !resident)
    ph.mark "finalize"
    builtinDeclRanges.set {}
    let hs ← HardStops.new
    let world := hybridWorld env d.old d.writer manual.root hs
    ph.mark "world"
    let (code, reused, atExtract) ← match reuse? with
      | some r => do
        let x ← extractReusing r ph cfg env world targets prevPrinted carried
        if let some why := x.failure then
          for l in patchLines ++ x.lines do IO.println l
          IO.eprintln s!"reader session: check-keys failed, Lean {d.writer.leanVersion} is not read: {why}"
          return 1
        pure (x.code, some (x.lines, r, x.printed), x.atExtract)
      | none => do
        let (code, atExtract) ← extractMeasured ph (Litedoc4.run cfg (some (env, world)))
        pure (code, none, some atExtract)
    ph.mark "reuse count"
    let realizations ← if resident then Assemble.clearRealizations env else pure 0
    ph.mark "clear realizations"
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
    if let some (ls, _, _) := reused then for l in ls do IO.println l
    if let some x := atExtract then IO.println x.line
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
    if let some (_, r, printed) := reused then
      if code == 0 then r.printed.set (some printed)
    ph.mark "report"
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
  let ph ← Phases.new
  let code ← readVersion a cfg targets (importNewest a.new newRoots) (resident := false) ph
  IO.println (← ph.line)
  return code

def sessionUsage : String := "\n".intercalate [
  "usage: reader session --new <search-dir>... --new-roots <modules.txt> [--check-patch]",
  "                      [--perturb-patch] [--no-field-fn-index] [--key-without-scx] [--check-keys]",
  "                      [--carry-without-presence] [--no-patch]",
  "  imports the newest version once and prints `ready <nanoseconds> <modules>`; then one request per line",
  "  on stdin, its fields separated by tabs:",
  "    --old <search-dir>... <modules.txt> <events.jsonl> [extractor flags]",
  "  which is reader extract's command line without --new and --new-roots. The first request's hybrid",
  "  is built whole from the newest import, every later one patched from the last one built. A print",
  "  key is carried from the round before unless an input it read changed (`carry` line); a",
  "  declaration whose print key equals its key in the last round answered ok 0 takes that round's",
  "  printed part; every other one is printed. Each request is answered with `round <n>`, reader",
  "  extract's summary, a `patch` line, a `carry` line, a `reuse` line, an `rss` line and",
  "  `ok <exit code> <nanoseconds>`; one that is not run is answered `err <why>`. EOF or an empty line",
  "  ends the session. Each round also prints an `rss-at-extract` line, as reader extract does.",
  "  --check-patch        also build each request's hybrid from scratch and compare the two module by",
  "                       module, pointer by pointer; a difference fails the request before anything is",
  "                       written (`check-patch` lines)",
  "  --perturb-patch      leave the last module a changed constant would have rewritten as it was (for",
  "                       the gate)",
  "  --no-field-fn-index  do not rewrite the newest modules holding a structure field's default or",
  "                       autoParam function when the structure appears or disappears (for the gate)",
  "  --key-without-scx    leave out of the print key what structure-instance notation reads besides",
  "                       field names: field defaults and the anonymous-constructor attribute (for the gate)",
  "  --check-keys         also compute every print key afresh and compare it with the carried one; a",
  "                       difference fails the request before anything is written (`check-keys` lines,",
  "                       each naming the input that should have made the key stale)",
  "  --carry-without-presence",
  "                       carry a name resolution past a name appearing or disappearing among the",
  "                       names it looked up (for the gate)",
  "  --no-patch           build every request's hybrid from scratch, as reader extract does, and compute",
  "                       every print key afresh at --jobs; only the last round's keys and printed parts",
  "                       are kept between rounds (no `patch` or `carry` line). With --check-keys the keys",
  "                       are computed a second time and compared. --check-patch, --perturb-patch,",
  "                       --no-field-fn-index and --carry-without-presence are refused with it"]

def patchOnlyFlags : List String :=
  ["--check-patch", "--perturb-patch", "--no-field-fn-index", "--carry-without-presence"]

def sessionFlags : List String := patchOnlyFlags ++ ["--key-without-scx", "--check-keys", "--no-patch"]

def rssLine (round : Nat) : IO String := do
  let u ← Std.IO.Process.getResourceUsage
  let now ← residentKb
  return s!"rss                  round {round}: peak {u.peakResidentSetSizeKb.toNat / 1024} MiB (the process's \
    maximum so far: a round raises it only by needing more than every round before it), resident {mibText now} \
    after the round; cpu {u.cpuUserTime.toInt} ms user, {u.cpuSystemTime.toInt} ms system so far"

unsafe def sessionMain (args : List String) : IO UInt32 := do
  if args == ["--help"] then
    IO.println sessionUsage
    return 0
  let (flags, args) := args.partition sessionFlags.contains
  let noPatch := flags.contains "--no-patch"
  if noPatch then
    if let some f := patchOnlyFlags.find? flags.contains then
      IO.eprintln s!"reader session: {f} is refused with --no-patch, which builds no patch\n{sessionUsage}"
      return 2
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
  if let some e := PrintKey.keyExts.find? (placementOf · |>.isNone) then
    IO.eprintln s!"olean reader: refused: the print key reads {e}, which the reader does not decode, so a \
      carried key would never see it change"
    return 1
  let t0 ← IO.monoNanosNow
  let newest ← match ← (importNewest a.new newRoots).toBaseIO with
    | .ok n => pure n
    | .error e =>
      IO.eprintln s!"olean reader: refused: the newest version was not imported: {e}"
      return 1
  let patch? : Option PatchSession ← if noPatch then pure none else do
    pure (some {
      check := flags.contains "--check-patch", perturb := flags.contains "--perturb-patch"
      presence := !flags.contains "--carry-without-presence"
      index := Patch.buildNewestIndex newest.state (fieldFnIndex := !flags.contains "--no-field-fn-index")
      last := ← IO.mkRef none, carry := ← IO.mkRef none })
  let reuse : ReuseSession := {
    scx := !flags.contains "--key-without-scx", checkKeys := flags.contains "--check-keys"
    printed := ← IO.mkRef none, patch? }
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
      let ph ← Phases.new
      let code ← readVersion r cfg targets (pure newest) (resident := true) ph (some reuse)
      let phases ← ph.line
      let r1 ← IO.monoNanosNow
      IO.println phases
      IO.println (← rssLine round)
      IO.println s!"ok {code} {r1 - r0}"
    stdout.flush
  return 0

end OleanReader.Hybrid
