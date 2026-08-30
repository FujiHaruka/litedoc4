/-
No `import Lean` anywhere below this module, and that is a distribution
constraint rather than a style one: an executable that imports `Lean` measures
226 MB and `Lean.Data.Json` alone 118 MB, against 5.3 MB for `Std`
(measured 2026-08-30 → `benchmarks/results/purelean-ci-probe-2026-08-30.txt`).
The extractor reads oleans and cannot avoid it, so it stays a separate
`lean_exe`. What would falsify this: a distribution model that ships a built
binary instead of a `require`, which is not the one this package has.
-/
import Litedoc4

namespace Litedoc4

def usage : String :=
"usage: litedoc4 build --root <repo> --out <dir> --extractor-bin <path>
                      [--lib <Name>] [--source-url <url>] [--lake <path>]
                      [--jobs <n>] [--full]
       litedoc4 modules --root <repo> [--lib <Name>] [--out <file>]
       litedoc4 render --ir <dir> --pages <dir> --source-url <url>
                       (--link-index <file> | --no-link-index)
                       [--root <dir>] [--lake <path>]
       litedoc4 site --ir <dir> --out <dir> --source-url <url>
                     (--link-index <file> | --no-link-index)
                     [--state <dir>] [--root <dir>] [--lake <path>]
       litedoc4 ledger build --modules <file> --target <repo> --out <ledger.json>
                             [--ir <dir>] [--source-url <url>] [--link-index <file>]
                             [--root <dir>] [--lake <path>] [--algorithm <name>]
                             [--concurrency <n>] [--timings <file>]
       litedoc4 ledger check --ledger <ledger.json> [--modules <file>] [--ir <dir>]
                             [--source-url <url>] [--link-index <file>]
                             [--root <dir>] [--lake <path>] [--algorithm <name>]
                             [--concurrency <n>] [--changed-out <file>]
                             [--removed-out <file>] [--render-all-out <file>]
                             [--timings <file>]
       litedoc4 ledger touch --ledger <ledger.json> --module <Module> [--out <file>]
       litedoc4 ownership --base <ir> (--inc <ir> | --removed <file>)
                          [--exclude <file>] [--print-set <file>] [--json <file>]
       litedoc4 merge --base <ir> (--inc <ir> | --remove <file>) [--out <ir>]
                      [--modules <file>] [--changed-out <file>] [--timings <file>]
       litedoc4 merge --verify <ir> --against <ir>
       litedoc4 --version
       litedoc4 --help"

structure RenderArgs where
  ir : Option String := none
  pages : Option String := none
  sourceUrl : Option String := none
  linkIndex : Option String := none
  noLinkIndex : Bool := false
  root : Option String := none
  lake : Option String := none
  help : Bool := false
  deriving Inhabited

/-- Flags the Rust `render` takes and this one does not. They are refused by
name rather than ignored: a run that silently dropped `--only` would write every
page, and the output would look like a match. -/
def renderUnimplemented : List String :=
  ["--deps-docs-map", "--only", "--only-from"]

partial def parseRender : List String → RenderArgs → Except String RenderArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    if flag == "--ir" then do
      let (v, more) ← value; parseRender more { acc with ir := some v }
    else if flag == "--pages" then do
      let (v, more) ← value; parseRender more { acc with pages := some v }
    else if flag == "--source-url" then do
      let (v, more) ← value; parseRender more { acc with sourceUrl := some v }
    else if flag == "--link-index" then do
      let (v, more) ← value; parseRender more { acc with linkIndex := some v }
    else if flag == "--no-link-index" then
      parseRender rest { acc with noLinkIndex := true }
    else if flag == "--root" then do
      let (v, more) ← value; parseRender more { acc with root := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseRender more { acc with lake := some v }
    else if flag == "--help" || flag == "-h" then
      parseRender rest { acc with help := true }
    else if renderUnimplemented.contains flag then
      .error s!"{flag} is a `render` flag this build does not implement"
    else
      .error s!"unknown argument `{flag}`"

def refuse (message : String) : IO UInt32 := do
  IO.eprintln s!"litedoc4: {message}"
  IO.eprintln ""
  IO.eprintln usage
  return 2

/-- Exit 3 and no usage text: the command line was fine and the *world* is a
shape this cannot work with, which is a thing a caller can act on. -/
def refusedWith (code : UInt32) (message : String) : IO UInt32 := do
  IO.eprintln s!"litedoc4: {message}"
  return code

/-- The cost is why the choice is not a default: the map is what turns a name in
a signature into a link, and a site built without one is a site of dead names. -/
def linkIndexRequired : String :=
  "pass --link-index <file>, or --no-link-index to say so on purpose"

structure RenderInputs where
  external : ExternalLinks
  config : SiteConfig

/-- What `render` and `site` both need before they can render anything, resolved
in one place because **no gate can see a disagreement between them**: the gates
compare the trees the two write, so handing both halves the same wrong reading
produces two identical wrong trees.

**Problems do not stop the run**: a package missing from disk, a manifest that
will not parse, a `lake` that will not run — each costs the roots it would have
contributed and is printed. Refusing would trade a site with some dead links for
no site at all. `litedoc4.toml` is the opposite and is an error, because there
the package asked for something by name. -/
def resolveExternal (root lake : Option String) : IO ExternalLinks := do
  match root with
  | none => do
    IO.println "external  no package named (--root), so links into a dependency stay relative \
      to pages this site does not write"
    return {}
  | some root => do
    let lake ← match lake with
      | some path => pure path
      | none => pure (((← IO.getEnv "LAKE").filter (!·.isEmpty)).getD "lake")
    let resolved ← externalLinks ⟨root⟩ ⟨lake⟩
    IO.println s!"external  {resolved.links.roots.size} root(s) from \
      {resolved.resolved}/{resolved.declared} package(s) + core"
    -- The roots in that count that carry no URL: they are in the map so that
    -- the pages stop linking into them, which is the opposite of what the line
    -- above reads like on its own.
    if resolved.unpinnedRoots > 0 then
      IO.println s!"external  note: {resolved.unpinnedRoots} of those root(s) have no \
        version-pinned URL, so names in them render without a link rather than linking at a \
        page this site does not write"
    for line in resolved.collisions ++ resolved.problems do
      IO.println s!"external  note: {line}"
    return resolved.links

def renderInputs (root lake : Option String) : IO RenderInputs := do
  return { external := ← resolveExternal root lake, config := ← readSiteConfig (root.map (⟨·⟩)) }

def render (args : List String) : IO UInt32 := do
  match parseRender args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let some ir := a.ir | refuse "--ir is required"
    let some pages := a.pages | refuse "--pages is required"
    let some sourceUrl := a.sourceUrl | refuse "--source-url is required"
    if sourceUrl.isEmpty then return ← refuse "--source-url is required"
    if a.linkIndex.isSome == a.noLinkIndex then return ← refuse linkIndexRequired
    try
      let inputs ← renderInputs a.root a.lake
      let summary ← renderSite
        { ir := ir, pages := pages, sourceUrl := sourceUrl
          linkIndex := a.linkIndex.map (⟨·⟩)
          external := inputs.external, title := inputs.config.title }
      printRenderSummary "" summary
      return 0
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      return 1

structure SiteArgs where
  ir : Option String := none
  out : Option String := none
  sourceUrl : Option String := none
  linkIndex : Option String := none
  noLinkIndex : Bool := false
  state : Option String := none
  root : Option String := none
  lake : Option String := none
  help : Bool := false
  deriving Inhabited

/-- Flags the Rust `site` takes and this one does not, refused by name for the
reason `renderUnimplemented` is. -/
def siteUnimplemented : List String :=
  ["--deps-docs-map", "--timings"]

/-- Flags the Rust `site` refuses by name because they belong to a subcommand it
calls: a caller needs *why it is not here*, not that it was misspelled. -/
def siteRefusal (flag : String) : Option String :=
  if flag == "--only" || flag == "--only-from" then
    some s!"{flag} is not a `site` flag: full generation renders every module, which is what \
      makes it full. Use `litedoc4 render {flag} ...` for a subset"
  else if flag == "--before" || flag == "--print-set" || flag == "--delta-json" then
    some s!"{flag} is not a `site` flag: the map delta names the pages an incremental round has \
      to re-render, and this command re-renders all of them. Use `litedoc4 global {flag} ...`"
  else if flag == "--pages" then
    some "`site` writes the pages and the six whole-package artifacts into one tree: name it \
      with --out"
  else none

partial def parseSite : List String → SiteArgs → Except String SiteArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    if flag == "--ir" then do
      let (v, more) ← value; parseSite more { acc with ir := some v }
    else if flag == "--out" then do
      let (v, more) ← value; parseSite more { acc with out := some v }
    else if flag == "--source-url" then do
      let (v, more) ← value; parseSite more { acc with sourceUrl := some v }
    else if flag == "--link-index" then do
      let (v, more) ← value; parseSite more { acc with linkIndex := some v }
    else if flag == "--no-link-index" then
      parseSite rest { acc with noLinkIndex := true }
    else if flag == "--state" then do
      let (v, more) ← value; parseSite more { acc with state := some v }
    else if flag == "--root" then do
      let (v, more) ← value; parseSite more { acc with root := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseSite more { acc with lake := some v }
    else if flag == "--help" || flag == "-h" then
      parseSite rest { acc with help := true }
    else match siteRefusal flag with
      | some message => .error message
      | none =>
        if siteUnimplemented.contains flag then
          .error s!"{flag} is a `site` flag this build does not implement"
        else
          .error s!"unknown argument `{flag}`"

def site (args : List String) : IO UInt32 := do
  match parseSite args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let some ir := a.ir | refuse "--ir is required"
    let some out := a.out | refuse "--out is required"
    let some sourceUrl := a.sourceUrl | refuse "--source-url is required"
    if sourceUrl.isEmpty then return ← refuse "--source-url is required"
    if a.linkIndex.isSome == a.noLinkIndex then return ← refuse linkIndexRequired
    try
      let inputs ← renderInputs a.root a.lake
      let rendered ← renderSite
        { ir := ir, pages := out, sourceUrl := sourceUrl
          linkIndex := a.linkIndex.map (⟨·⟩)
          external := inputs.external, title := inputs.config.title }
      let derived ← buildGlobal ir out (a.state.map (⟨·⟩)) inputs.config.indexMarkdown
        inputs.config.title
      -- Labelled per stage: one merged line would lose which half of the tree a
      -- number is about, and the two count different things under the same word
      -- ("modules").
      printRenderSummary "render  " rendered
      printGlobalSummary "global  " derived
      return 0
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      return 1

structure LedgerArgs where
  modules : Option String := none
  target : Option String := none
  out : Option String := none
  ledger : Option String := none
  ir : Option String := none
  sourceUrl : String := ""
  linkIndex : Option String := none
  root : Option String := none
  lake : Option String := none
  algorithm : Option String := none
  concurrency : Nat := 1
  module : Option String := none
  changedOut : Option String := none
  removedOut : Option String := none
  renderAllOut : Option String := none
  timings : Option String := none
  help : Bool := false
  deriving Inhabited

/-- Which `ledger` subcommand accepts which flag.

One flat parse followed by a dispatch on the subcommand accepts every flag for
all three and reads it for one: `ledger touch --concurrency 9` would run, ignore
the number, and say nothing. **A flag that does nothing is the shape this project
keeps finding** — the run looks right and the artefact is not the one that was
asked for. -/
def ledgerFlags : List (String × List String) :=
  [("--modules", ["build", "check"]),
   ("--target", ["build"]),
   ("--out", ["build", "touch"]),
   ("--ledger", ["check", "touch"]),
   ("--ir", ["build", "check"]),
   ("--source-url", ["build", "check"]),
   ("--link-index", ["build", "check"]),
   ("--root", ["build", "check"]),
   ("--lake", ["build", "check"]),
   ("--deps-docs-map", ["build", "check"]),
   ("--algorithm", ["build", "check"]),
   ("--concurrency", ["build", "check"]),
   ("--module", ["touch"]),
   ("--changed-out", ["check"]),
   ("--removed-out", ["check"]),
   ("--render-all-out", ["check"]),
   ("--timings", ["build", "check"])]

/-- Flags the Rust `ledger` takes and this one does not, refused by name rather
than ignored for the reason `renderUnimplemented` is. `--deps-docs-map` folds a
map of where a dependency's documentation is published into the render key, and a
run that dropped it would compute a key `build` never recorded. -/
def ledgerUnimplemented : List String :=
  ["--deps-docs-map"]

def ledgerFlagRefusal (command flag : String) : Option String :=
  match ledgerFlags.find? (·.1 == flag) with
  | some (_, accepted) =>
    if accepted.contains command then none
    else some s!"{flag} is not a flag of `ledger {command}`: it belongs to \
      {" / ".intercalate (accepted.map (s!"`ledger {·}`"))}"
  | none => none

partial def parseLedger (command : String) :
    List String → LedgerArgs → Except String LedgerArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    match ledgerFlagRefusal command flag with
    | some message => .error message
    | none =>
    if flag == "--modules" then do
      let (v, more) ← value; parseLedger command more { acc with modules := some v }
    else if flag == "--target" then do
      let (v, more) ← value; parseLedger command more { acc with target := some v }
    else if flag == "--out" then do
      let (v, more) ← value; parseLedger command more { acc with out := some v }
    else if flag == "--ledger" then do
      let (v, more) ← value; parseLedger command more { acc with ledger := some v }
    else if flag == "--ir" then do
      let (v, more) ← value; parseLedger command more { acc with ir := some v }
    else if flag == "--source-url" then do
      let (v, more) ← value; parseLedger command more { acc with sourceUrl := v }
    else if flag == "--link-index" then do
      let (v, more) ← value; parseLedger command more { acc with linkIndex := some v }
    else if flag == "--root" then do
      let (v, more) ← value; parseLedger command more { acc with root := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseLedger command more { acc with lake := some v }
    else if flag == "--algorithm" then do
      let (v, more) ← value; parseLedger command more { acc with algorithm := some v }
    else if flag == "--concurrency" then do
      let (v, more) ← value
      match v.toNat? with
      | some n => parseLedger command more { acc with concurrency := n }
      | none => .error s!"--concurrency takes a number, not `{v}`"
    else if flag == "--module" then do
      let (v, more) ← value; parseLedger command more { acc with module := some v }
    else if flag == "--changed-out" then do
      let (v, more) ← value; parseLedger command more { acc with changedOut := some v }
    else if flag == "--removed-out" then do
      let (v, more) ← value; parseLedger command more { acc with removedOut := some v }
    else if flag == "--render-all-out" then do
      let (v, more) ← value; parseLedger command more { acc with renderAllOut := some v }
    else if flag == "--timings" then do
      let (v, more) ← value; parseLedger command more { acc with timings := some v }
    else if flag == "--help" || flag == "-h" then
      parseLedger command rest { acc with help := true }
    else if ledgerUnimplemented.contains flag then
      .error s!"{flag} is a `ledger {command}` flag this build does not implement"
    else
      .error s!"unknown argument `{flag}`"

/-- `--concurrency` is accepted and its value is recorded, and a run that took it
must not read as though it had used it: this build hashes one module at a time. -/
def sequentialNote (concurrency : Nat) : IO Unit := do
  if concurrency > 1 then
    IO.println s!"ledger  --concurrency {concurrency} was asked for; this build hashes one module \
      at a time, and the timings record keeps the number that was asked for"

def jsonNames (out : String) (names : Array String) : String := Id.run do
  let mut o := out.push '['
  let mut first := true
  for name in names do
    if !first then o := o.push ','
    first := false
    o := jsonStr o name
  return o.push ']'

/-- `BuildTimings` in `crates/litedoc4-incr/src/detect.rs`. The key order is that
record's field order, and every value but the durations is compared against a
recording of it. -/
def buildTimingsJson (algorithm : String) (concurrency modules files hashedBytes : Nat)
    (keyNanos hashNanos writeNanos totalNanos : Nat) : String :=
  jsonStr "{\"command\":\"build\",\"algorithm\":" algorithm
    ++ s!",\"concurrency\":{concurrency},\"modules\":{modules},\"files\":{files}"
    ++ s!",\"hashedBytes\":{hashedBytes},\"keySeconds\":{seconds keyNanos 9}"
    ++ s!",\"hashSeconds\":{seconds hashNanos 9},\"writeSeconds\":{seconds writeNanos 9}"
    ++ s!",\"totalSeconds\":{seconds totalNanos 9}" ++ "}\n"

/-- `CheckTimings`, under the rule `buildTimingsJson` states. -/
def checkTimingsJson (concurrency : Nat) (s : CheckSummary) (totalNanos : Nat) : String :=
  let p := s.phases
  let o := jsonStr "{\"command\":\"check\",\"algorithm\":" s.algorithm.name
  let o := o ++ s!",\"concurrency\":{concurrency},\"modules\":{s.modules},\"moduleListSource\":"
  let o := jsonStr o (if s.fromList then "list" else "ledger")
  let o := o ++ s!",\"files\":{s.files},\"hashedBytes\":{s.hashedBytes},\"extractKeyChanged\":"
  let o := jsonNames o s.extractKeyChanged
  let o := o ++ s!",\"extractInvalidated\":{s.extractInvalidated},\"renderKeyChanged\":"
  let o := jsonNames o s.renderKeyChanged
  let o := o ++ s!",\"renderAll\":{s.renderAll},\"changed\":{s.changed.size},\"changedModules\":"
  let o := jsonNames o s.changed
  let o := o ++ s!",\"added\":{s.added.size},\"addedModules\":"
  let o := jsonNames o s.added
  let o := o ++ s!",\"removed\":{s.removed.size},\"removedModules\":"
  let o := jsonNames o s.removed
  o ++ s!",\"reExtract\":{s.reExtract.size}"
    ++ s!",\"readLedgerSeconds\":{seconds (p.readDone - p.started) 9}"
    ++ s!",\"keySeconds\":{seconds (p.keyDone - p.readDone) 9}"
    ++ s!",\"hashSeconds\":{seconds (p.hashDone - p.keyDone) 9}"
    ++ s!",\"compareSeconds\":{seconds (p.compareDone - p.hashDone) 9}"
    ++ s!",\"totalSeconds\":{seconds totalNanos 9}" ++ "}\n"

def ledgerBuildRun (a : LedgerArgs) (modules target out : String) : IO UInt32 := do
  let names ← readModuleList ⟨modules⟩
  let external ← resolveExternal a.root a.lake
  let algorithm : Algorithm := match a.algorithm with
    | some name => { name }
    | none => Algorithm.sha256
  let result ← buildLedger
    { modules := names, target := target, ir := a.ir.map (⟨·⟩), sourceUrl := a.sourceUrl
      linkIndex := a.linkIndex.map (⟨·⟩), externalLinks := some external.digest, algorithm }
  match result with
  | .error message => refusedWith 3 message
  | .ok (ledger, phases) =>
    let body := ledger.toJson
    writeFile ⟨out⟩ body
    let files := fileCountOf ledger.modules
    let hashed := hashedBytesOf ledger.modules
    if let some path := a.timings then
      let total ← IO.monoNanosNow
      writeFile ⟨path⟩ (buildTimingsJson algorithm.name a.concurrency ledger.modules.size files
        hashed (phases.keyDone - phases.started) (phases.hashDone - phases.keyDone)
        (total - phases.hashDone) (total - phases.started))
    sequentialNote a.concurrency
    IO.println s!"build {ledger.modules.size} modules, {files} olean file(s), {hashed} B hashed \
      in {seconds (phases.hashDone - phases.keyDone) 4} s -> {out} ({body.utf8ByteSize} B)"
    return 0

def ledgerCheckRun (a : LedgerArgs) (path : String) : IO UInt32 := do
  let names ← match a.modules with
    | some list => pure (some (← readModuleList ⟨list⟩))
    | none => pure none
  let external ← resolveExternal a.root a.lake
  let result ← checkLedger
    { ledger := ⟨path⟩, algorithm := a.algorithm.map ({ name := · }), modules := names
      ir := a.ir.map (⟨·⟩), sourceUrl := a.sourceUrl, linkIndex := a.linkIndex.map (⟨·⟩)
      externalLinks := some external.digest
      changedOut := a.changedOut.map (⟨·⟩), removedOut := a.removedOut.map (⟨·⟩)
      renderAllOut := a.renderAllOut.map (⟨·⟩) }
  match result with
  | .error (code, message) => refusedWith code message
  | .ok summary =>
    if let some timings := a.timings then
      writeFile ⟨timings⟩
        (checkTimingsJson a.concurrency summary ((← IO.monoNanosNow) - summary.phases.started))
    sequentialNote a.concurrency
    IO.println s!"check {summary.modules} modules ({summary.algorithm.name}, concurrency 1): \
      {summary.changed.size} changed, {summary.added.size} added, {summary.removed.size} removed"
    if summary.extractInvalidated then
      IO.println s!"  extract key changed ({",".intercalate summary.extractKeyChanged.toList}) \
        -> all {summary.reExtract.size} re-extracted"
    if summary.renderAll then
      IO.println s!"  render key changed ({",".intercalate summary.renderKeyChanged.toList}) \
        -> re-render all, re-extract {summary.reExtract.size}"
    for module in summary.changed do
      IO.println s!"  changed  {module}"
    for module in summary.added do
      IO.println s!"  added    {module}"
    for module in summary.removed do
      IO.println s!"  removed  {module}"
    return 0

def ledgerTouchRun (path module out : String) : IO UInt32 := do
  match readLedger path (← IO.FS.readFile path) >>= touchLedger path module with
  | .error (code, message) => refusedWith code message
  | .ok ledger =>
    let body := ledger.toJson
    writeFile ⟨out⟩ body
    IO.println s!"touched {module} in {out} ({body.utf8ByteSize} B; injected change, the olean is \
      untouched)"
    return 0

def ledgerRun (command : String) (a : LedgerArgs) : IO UInt32 := do
  if command == "build" then
    let missing := "ledger build needs --modules <file>, --target <repo> and --out <ledger.json>"
    let some modules := a.modules | refuse missing
    let some target := a.target | refuse missing
    let some out := a.out | refuse missing
    ledgerBuildRun a modules target out
  else if command == "check" then
    let some path := a.ledger | refuse "ledger check needs --ledger <ledger.json>"
    ledgerCheckRun a path
  else
    let missing := "ledger touch needs --ledger <ledger.json> and --module <Module>"
    let some path := a.ledger | refuse missing
    let some module := a.module | refuse missing
    ledgerTouchRun path module (a.out.getD path)

structure ModulesArgs where
  root : Option String := none
  libs : Array String := #[]
  out : Option String := none
  help : Bool := false
  deriving Inhabited

partial def parseModules : List String → ModulesArgs → Except String ModulesArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    if flag == "--root" then do
      let (v, more) ← value; parseModules more { acc with root := some v }
    else if flag == "--lib" then do
      let (v, more) ← value; parseModules more { acc with libs := acc.libs.push v }
    else if flag == "--out" then do
      let (v, more) ← value; parseModules more { acc with out := some v }
    else if flag == "--help" || flag == "-h" then
      parseModules rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

def modulesRun (a : ModulesArgs) (root : String) : IO UInt32 := do
  let libs ← if !a.libs.isEmpty then pure (Except.ok a.libs) else
    match ← readLibraries ⟨root⟩ with
    | .error message => pure (.error message)
    | .ok declared => do
      -- **On stderr**: this command's stdout is the module list itself when
      -- `--out` is absent, and a caller redirecting it into a file would
      -- otherwise get a diagnostic as its first module.
      IO.eprintln s!"lib     {", ".intercalate declared.names.toList} (from {declared.file})"
      pure (.ok declared.names)
  match libs with
  | .error message => refusedWith 3 message
  | .ok libs =>
    match ← moduleNames ⟨root⟩ libs with
    | .error message => refusedWith 3 message
    | .ok names =>
      match a.out with
      | some path => do
        writeLines ⟨path⟩ names
        IO.println s!"{names.size} modules -> {path}"
        return 0
      | none => do
        for name in names do
          IO.println name
        return 0

def modules (args : List String) : IO UInt32 := do
  match parseModules args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let some root := a.root | refuse "--root <repo> is required"
    try
      modulesRun a root
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

structure BuildArgs where
  root : Option String := none
  out : Option String := none
  libs : Array String := #[]
  sourceUrl : Option String := none
  extractorBin : Option String := none
  lake : Option String := none
  jobs : Nat := 1
  full : Bool := false
  help : Bool := false
  deriving Inhabited

/-- Flags the Rust `build` takes and this one does not. Refused by name rather
than ignored, because every one of them changes what a run *did* rather than
whether it ran: a build that took `--mode importers` and re-rendered everything,
or `--timings` and wrote no record, would look from the outside like the run that
was asked for. `--link-index` is here for the opposite reason — it names a map
somebody else made, and this build always writes its own. -/
def buildUnimplemented : List String :=
  ["--mode", "--max-rounds", "--timings", "--extractor", "--extractor-arg",
   "--deps-docs-url", "--deps-docs-index", "--link-index"]

partial def parseBuild : List String → BuildArgs → Except String BuildArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    if flag == "--root" then do
      let (v, more) ← value; parseBuild more { acc with root := some v }
    else if flag == "--out" then do
      let (v, more) ← value; parseBuild more { acc with out := some v }
    else if flag == "--lib" then do
      let (v, more) ← value; parseBuild more { acc with libs := acc.libs.push v }
    else if flag == "--source-url" then do
      let (v, more) ← value; parseBuild more { acc with sourceUrl := some v }
    else if flag == "--extractor-bin" then do
      let (v, more) ← value; parseBuild more { acc with extractorBin := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseBuild more { acc with lake := some v }
    else if flag == "--jobs" then do
      let (v, more) ← value
      match v.toNat? with
      | some n => if n == 0 then .error "--jobs must be at least 1"
                  else parseBuild more { acc with jobs := n }
      | none => .error s!"--jobs takes a number, not `{v}`"
    else if flag == "--full" then
      parseBuild rest { acc with full := true }
    else if flag == "--help" || flag == "-h" then
      parseBuild rest { acc with help := true }
    else if buildUnimplemented.contains flag then
      .error s!"{flag} is a `build` flag this build does not implement"
    else
      .error s!"unknown argument `{flag}`"

def buildRun (a : BuildArgs) (root out : String) : IO UInt32 := do
  -- Canonicalised **before** anything is compared against it: `--out` under a
  -- symlinked `--root` is still under `--root`.
  let rootPath ← match ← (IO.FS.realPath ⟨root⟩).toBaseIO with
    | .error e => return ← refusedWith 3 s!"--root {root}: {e}"
    | .ok path => pure path
  let outPath ← absolutePath ⟨out⟩
  let resolved ← resolvePath outPath
  if isInside rootPath resolved then
    return ← refusedWith 3 s!"--out {resolved} is inside --root {rootPath}: the package being \
      documented is opened read-only and nothing is ever written into it — `litedoc4 extract` \
      refuses an --ir-dir there for the same reason. Copy <out>/site into the repository \
      afterwards if that is where the pages belong"
  -- Before anything is written, and once: `lake env lean --githash` starts a
  -- process inside the target, and the digest it feeds has to be the same one on
  -- both sides of this run.
  let external ← resolveExternal (some rootPath.toString) a.lake
  let request : BuildRequest :=
    { root := rootPath, layout := layoutOf outPath, libs := a.libs, external
      sourceUrl := a.sourceUrl, extractorBin := a.extractorBin.map (⟨·⟩)
      lake := a.lake.map (⟨·⟩), jobs := a.jobs, full := a.full }
  match ← (runBuild request).run with
  | .ok () => return 0
  | .error (code, message) =>
    if code == 2 then refuse message
    else refusedWith code message

def build (args : List String) : IO UInt32 := do
  match parseBuild args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let some root := a.root | refuse "--root <repo> is required: the Lean package to document"
    let some out := a.out
      | refuse "--out <dir> is required and has no default: it is where the site, the IR, the \
          cache and the ledger go. The obvious default would be <root>/.lake/build/doc, which is \
          doc-gen4's own output tree — a default that overwrites another tool's output is a \
          data-loss bug with a friendly face"
    try
      buildRun a root out
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

structure OwnershipArgs where
  base : Option String := none
  inc : Option String := none
  removed : Option String := none
  exclude : Option String := none
  printSet : Option String := none
  json : Option String := none
  help : Bool := false
  deriving Inhabited

partial def parseOwnership : List String → OwnershipArgs → Except String OwnershipArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    if flag == "--base" then do
      let (v, more) ← value; parseOwnership more { acc with base := some v }
    else if flag == "--inc" then do
      let (v, more) ← value; parseOwnership more { acc with inc := some v }
    else if flag == "--removed" then do
      let (v, more) ← value; parseOwnership more { acc with removed := some v }
    else if flag == "--exclude" then do
      let (v, more) ← value; parseOwnership more { acc with exclude := some v }
    else if flag == "--print-set" then do
      let (v, more) ← value; parseOwnership more { acc with printSet := some v }
    else if flag == "--json" then do
      let (v, more) ← value; parseOwnership more { acc with json := some v }
    else if flag == "--help" || flag == "-h" then
      parseOwnership rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

/-- The rule name in a fixed column, `format!("{:<15}")`. The two rules are 9 and
14 characters, so a column that moved with them would break the module names out
of alignment on the only line a reader scans down. -/
def padTo (width : Nat) (s : String) : String :=
  s ++ String.ofList (List.replicate (width - s.length) ' ')

def ownershipRun (a : OwnershipArgs) (base : String) : IO UInt32 := do
  let summary ← runOwnership
    { base := ⟨base⟩, inc := a.inc.map (⟨·⟩), removed := a.removed.map (⟨·⟩)
      exclude := a.exclude.map (⟨·⟩), printSet := a.printSet.map (⟨·⟩)
      json := a.json.map (⟨·⟩) }
  IO.println s!"ownership: {summary.lostNames} name(s) lost, {summary.gainedNames} gained \
    across {summary.incModules} re-extracted module(s) -> {summary.staleModules.size} \
    module(s) need re-extraction — {seconds summary.totalNanos 4} s"
  for w in summary.witnesses.extract 0 witnessesInLog do
    IO.println s!"  {padTo 15 w.rule} {w.module}  (ref {w.refModule} :: {w.refName})"
  return 0

/-- Which modules point at a name that has moved.

Runs **before** `merge` in a round, and the reason is not a preference: merge
overwrites the base IR's idea of who owns each name. -/
def ownershipCmd (args : List String) : IO UInt32 := do
  match parseOwnership args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    -- Without a tree to diff against and without a deletion list there is no
    -- question to answer.
    let missing := "ownership needs --base <ir> and at least one of --inc <ir> / --removed <file>"
    let some base := a.base | refuse missing
    if a.inc.isNone && a.removed.isNone then return ← refuse missing
    try
      ownershipRun a base
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

structure MergeArgs where
  base : Option String := none
  inc : Option String := none
  out : Option String := none
  modules : Option String := none
  remove : Option String := none
  changedOut : Option String := none
  timings : Option String := none
  verify : Option String := none
  against : Option String := none
  help : Bool := false
  deriving Inhabited

partial def parseMerge : List String → MergeArgs → Except String MergeArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    if flag == "--base" then do
      let (v, more) ← value; parseMerge more { acc with base := some v }
    else if flag == "--inc" then do
      let (v, more) ← value; parseMerge more { acc with inc := some v }
    else if flag == "--out" then do
      let (v, more) ← value; parseMerge more { acc with out := some v }
    else if flag == "--modules" then do
      let (v, more) ← value; parseMerge more { acc with modules := some v }
    else if flag == "--remove" then do
      let (v, more) ← value; parseMerge more { acc with remove := some v }
    else if flag == "--changed-out" then do
      let (v, more) ← value; parseMerge more { acc with changedOut := some v }
    else if flag == "--timings" then do
      let (v, more) ← value; parseMerge more { acc with timings := some v }
    else if flag == "--verify" then do
      let (v, more) ← value; parseMerge more { acc with verify := some v }
    else if flag == "--against" then do
      let (v, more) ← value; parseMerge more { acc with against := some v }
    else if flag == "--help" || flag == "-h" then
      parseMerge rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

def removedNote (removed : Nat) : String :=
  if removed > 0 then s!", removed {removed}" else ""

def irChangedNote (names : Array String) : String :=
  if names.isEmpty then "" else ": " ++ ", ".intercalate names.toList

def mergeVerifyRun (tree against : String) : IO UInt32 := do
  match ← verify ⟨tree⟩ ⟨against⟩ with
  | .error (code, message) => refusedWith code message
  | .ok report =>
    IO.print report.toText
    -- The answer is already on stdout, so nothing goes to stderr: a caller that
    -- printed this as an error message would be reporting a working comparison
    -- as a broken one.
    return (if report.problems == 0 then 0 else 1)

def mergeFoldRun (a : MergeArgs) (base : String) : IO UInt32 := do
  -- The base tree is never written to unless the caller asks for it by name.
  let out := a.out.getD (base ++ ".merged")
  let removed ← match a.remove with
    | some path => readModuleList ⟨path⟩
    | none => pure (#[] : Array String)
  let listed ← match a.modules with
    | some path => do pure (some (← readModuleList ⟨path⟩))
    | none => pure none
  match ← merge { base := ⟨base⟩, inc := a.inc.map (⟨·⟩), out := ⟨out⟩, removed
                  modules := listed, changedOut := a.changedOut.map (⟨·⟩)
                  timings := a.timings.map (⟨·⟩) } with
  | .error (code, message) => refusedWith code message
  | .ok summary =>
    IO.println s!"merged {summary.updated.size} module(s){removedNote summary.removed} into \
      {summary.modules}: modules {seconds summary.copyNanos 4} s, deps+index \
      {seconds summary.depsNanos 4} s, total {seconds summary.totalNanos 4} s -> {out}"
    IO.println s!"IR content hash moved for {summary.irChanged.size} of {summary.updated.size} \
      re-extracted module(s){irChangedNote summary.irChanged}"
    return 0

/-- Folds a partial extraction back into the package IR; `--verify` instead
compares two trees.

**`--modules` is what makes the merged `index.json`'s module order a from-scratch
extraction's**, which is the order of the list the extractor is handed. Left out,
the order is the base index's with new modules appended, for callers that have no
list. -/
def mergeCmd (args : List String) : IO UInt32 := do
  match parseMerge args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    try
      match a.verify with
      | some tree =>
        let some against := a.against | refuse "merge --verify <ir> needs --against <ir>"
        mergeVerifyRun tree against
      | none =>
        let missing := "merge needs --base <ir> and at least one of --inc <ir> / --remove <file>"
        let some base := a.base | refuse missing
        if a.inc.isNone && a.remove.isNone then return ← refuse missing
        mergeFoldRun a base
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      return 1

def ledger (args : List String) : IO UInt32 := do
  match args with
  | [] => refuse "ledger needs a subcommand: build, check or touch"
  | command :: rest =>
    -- Before the subcommand, because that is where a person types it: this is the
    -- only command with a subcommand in front of its flag loop, so without this
    -- arm `litedoc4 ledger --help` is refused as an unknown subcommand *named*
    -- `--help`.
    if command == "--help" || command == "-h" then do
      IO.println usage
      return 0
    else if command != "build" && command != "check" && command != "touch" then
      refuse s!"unknown `ledger` subcommand `{command}`"
    else match parseLedger command rest {} with
      | .error message => refuse message
      | .ok a =>
        if a.help then
          IO.println usage
          return 0
        try
          ledgerRun command a
        catch e =>
          IO.eprintln s!"litedoc4: {e}"
          pure (1 : UInt32)

end Litedoc4

def main (args : List String) : IO UInt32 := do
  match args with
  | "--version" :: _ =>
    IO.println s!"litedoc4 {Litedoc4.version}"
    return 0
  | "build" :: rest => Litedoc4.build rest
  | "modules" :: rest => Litedoc4.modules rest
  | "render" :: rest => Litedoc4.render rest
  | "ledger" :: rest => Litedoc4.ledger rest
  | "site" :: rest => Litedoc4.site rest
  | "ownership" :: rest => Litedoc4.ownershipCmd rest
  | "merge" :: rest => Litedoc4.mergeCmd rest
  | [] | "--help" :: _ | "-h" :: _ =>
    IO.println Litedoc4.usage
    return 0
  | arg :: _ =>
    IO.eprintln s!"litedoc4: unknown subcommand `{arg}`"
    IO.eprintln Litedoc4.usage
    return 2
