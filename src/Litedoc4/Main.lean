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
                       [--only <Module>]... [--only-from <file>]...
       litedoc4 site --ir <dir> --out <dir> --source-url <url>
                     (--link-index <file> | --no-link-index)
                     [--state <dir>] [--root <dir>] [--lake <path>]
       litedoc4 global --ir <dir> --out <dir> [--root <dir>] [--state <dir>]
                       [--before <name-map.json>] [--print-set <file>]
                       [--delta-json <file>]
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
       litedoc4 impact --ir <dir> [--changed <Module>]... [--changed-file <file>]
                       [--mode self|referrers|importers|all] [--census <file>]
                       [--print-set <file>] [--json <file>]
       litedoc4 prune --pages <dir> [--remove <file>] [--ir <dir>] [--dry-run]
                      [--json <file>]
       litedoc4 extract --modules <file> --ir-dir <dir> --timings <file>
                        [--extractor-bin <path>] [--target <repo>] [--lake <path>]
                        [--events <file>] [--jobs <n>]
                        [--link-index <file> [--link-index-omit <file>]
                         [--link-index-key <token>]]
       litedoc4 incremental --ir <dir> --pages <dir> --ledger <file> --work <dir>
                            --modules <file> --source-url <url> --link-index <file>
                            --state <dir>
                            (--extractor <program> [--extractor-arg <arg>]...
                             | --serve --extractor-bin <path> --target <repo>
                               [--lake <path>] [--jobs <n>] [--make-link-index])
                            [--mode self|referrers|importers|all] [--max-rounds <n>]
                            [--root <dir>] [--timings <file>]
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
  /-- The `--only` names, and the `--only-from` paths, kept apart because one of
  the two costs a file read. Both empty is "no subset asked for"; either
  non-empty is a subset, and `--only-from` naming an empty file is the subset
  that came out empty. -/
  only : Array String := #[]
  onlyFrom : Array String := #[]
  help : Bool := false
  deriving Inhabited

/-- Flags the Rust `render` takes and this one does not. They are refused by
name rather than ignored: a run that silently dropped one would write the same
pages as a run that honoured it, and the output would look like a match. -/
def renderUnimplemented : List String :=
  ["--deps-docs-map"]

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
    else if flag == "--only" then do
      let (v, more) ← value; parseRender more { acc with only := acc.only.push v }
    else if flag == "--only-from" then do
      let (v, more) ← value; parseRender more { acc with onlyFrom := acc.onlyFrom.push v }
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

/-- The two spellings fold into one set, and both empty stays `all`. -/
def resolveOnly (names files : Array String) : IO ModuleSet := do
  if names.isEmpty && files.isEmpty then return .all
  let mut set : Std.HashSet String := Std.HashSet.emptyWithCapacity (names.size + 64)
  for name in names do set := set.insert name
  for file in files do
    for name in moduleSetLines (← IO.FS.readFile ⟨file⟩) do set := set.insert name
  return .these set

def render (args : List String) : IO UInt32 := do
  match parseRender args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    try
      -- Before the required-flag checks because Rust reads `--only-from` in the
      -- flag loop: a file that will not open is exit 1 there even when `--ir` is
      -- missing too, and moving the read down would make that exit 2.
      let only ← resolveOnly a.only a.onlyFrom
      let some ir := a.ir | return ← refuse "--ir is required"
      let some pages := a.pages | return ← refuse "--pages is required"
      let some sourceUrl := a.sourceUrl | return ← refuse "--source-url is required"
      if sourceUrl.isEmpty then return ← refuse "--source-url is required"
      if a.linkIndex.isSome == a.noLinkIndex then return ← refuse linkIndexRequired
      let inputs ← renderInputs a.root a.lake
      let summary ← renderSite
        { ir := ir, pages := pages, sourceUrl := sourceUrl
          linkIndex := a.linkIndex.map (⟨·⟩)
          external := inputs.external, title := inputs.config.title, only }
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
      let derived ← buildGlobal
        { ir := ir, out := out, state := a.state.map (⟨·⟩)
          indexMarkdown := inputs.config.indexMarkdown, title := inputs.config.title }
      -- Labelled per stage: one merged line would lose which half of the tree a
      -- number is about, and the two count different things under the same word
      -- ("modules").
      printRenderSummary "render  " rendered
      printGlobalSummary "global  " derived
      return 0
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      return 1

structure GlobalArgs where
  ir : Option String := none
  out : Option String := none
  root : Option String := none
  state : Option String := none
  before : Option String := none
  printSet : Option String := none
  deltaJson : Option String := none
  help : Bool := false
  deriving Inhabited

/-- Flags the Rust `global` takes and this one does not, refused by name for the
reason `renderUnimplemented` is. -/
def globalUnimplemented : List String :=
  ["--timings"]

partial def parseGlobal : List String → GlobalArgs → Except String GlobalArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    if flag == "--ir" then do
      let (v, more) ← value; parseGlobal more { acc with ir := some v }
    else if flag == "--out" then do
      let (v, more) ← value; parseGlobal more { acc with out := some v }
    else if flag == "--root" then do
      let (v, more) ← value; parseGlobal more { acc with root := some v }
    else if flag == "--state" then do
      let (v, more) ← value; parseGlobal more { acc with state := some v }
    else if flag == "--before" then do
      let (v, more) ← value; parseGlobal more { acc with before := some v }
    else if flag == "--print-set" then do
      let (v, more) ← value; parseGlobal more { acc with printSet := some v }
    else if flag == "--delta-json" then do
      let (v, more) ← value; parseGlobal more { acc with deltaJson := some v }
    else if flag == "--help" || flag == "-h" then
      parseGlobal rest { acc with help := true }
    else if globalUnimplemented.contains flag then
      .error s!"{flag} is a `global` flag this build does not implement"
    else
      .error s!"unknown argument `{flag}`"

/-- The whole-package artifacts, the `contentHash` cache and the map delta.

No `--only`: the derivation is over the whole package by construction, and the
cache makes it cheap rather than partial. No `--source-url` either — none of the
nine artifacts carries a source link. `--root` is here for one reason: this
command writes `index.html`, and `litedoc4.toml` decides what is on it.

`--print-set` / `--delta-json` do nothing without `--before`: the delta is off
unless there is a map to compare against. -/
def globalCmd (args : List String) : IO UInt32 := do
  match parseGlobal args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let some ir := a.ir | refuse "--ir is required"
    let some out := a.out | refuse "--out is required"
    try
      let config ← readSiteConfig (a.root.map (⟨·⟩))
      let summary ← buildGlobal
        { ir := ir, out := out, state := a.state.map (⟨·⟩)
          before := a.before.map (⟨·⟩), printSet := a.printSet.map (⟨·⟩)
          deltaJson := a.deltaJson.map (⟨·⟩)
          indexMarkdown := config.indexMarkdown, title := config.title }
      printGlobalSummary "" summary
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
  match ← (refuseInside rootPath "--root" outPath "--out" " — `litedoc4 extract` refuses an \
      --ir-dir there for the same reason. Copy <out>/site into the repository afterwards if that \
      is where the pages belong").run with
  | .error (code, message) => return ← refusedWith code message
  | .ok () => pure ()
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

structure ImpactArgs where
  ir : Option String := none
  /-- In the order they were given; the flags first, then the file's lines. -/
  changed : Array String := #[]
  changedFile : Option String := none
  mode : Option String := none
  census : Option String := none
  printSet : Option String := none
  json : Option String := none
  help : Bool := false
  deriving Inhabited

partial def parseImpact : List String → ImpactArgs → Except String ImpactArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    if flag == "--ir" then do
      let (v, more) ← value; parseImpact more { acc with ir := some v }
    else if flag == "--changed" then do
      let (v, more) ← value; parseImpact more { acc with changed := acc.changed.push v }
    else if flag == "--changed-file" then do
      let (v, more) ← value; parseImpact more { acc with changedFile := some v }
    else if flag == "--mode" then do
      let (v, more) ← value; parseImpact more { acc with mode := some v }
    else if flag == "--census" then do
      let (v, more) ← value; parseImpact more { acc with census := some v }
    else if flag == "--print-set" then do
      let (v, more) ← value; parseImpact more { acc with printSet := some v }
    else if flag == "--json" then do
      let (v, more) ← value; parseImpact more { acc with json := some v }
    else if flag == "--help" || flag == "-h" then
      parseImpact rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

def impactRun (a : ImpactArgs) (ir : String) : IO UInt32 := do
  -- The order reaches the summary's `changed` array, and repeats are kept rather
  -- than folded.
  let changed ← match a.changedFile with
    | some path => do pure (a.changed ++ (← readModuleList ⟨path⟩))
    | none => pure a.changed
  match ← runImpact { ir := ⟨ir⟩, changed
                      mode := (a.mode.map ImpactMode.parse).getD .importers
                      census := a.census.map (⟨·⟩), printSet := a.printSet.map (⟨·⟩)
                      json := a.json.map (⟨·⟩) } with
  | .error (code, message) => refusedWith code message
  | .ok run =>
    if let (some modules, some path) := (run.censusModules, a.census) then
      IO.println s!"census -> {path} ({modules} modules)"
    if let some summary := run.summary then IO.println (impactJson summary)
    return 0

/-- A changed module set in, the modules to re-render out.

**`global` runs before this** — but not into it: the whole-package map's delta is
the other half of the render set, and it reaches the renderer by being *unioned*
with this stage's `--print-set`, which is the pipeline's job. A delta with no
changes is a **0-byte file, not a blank line**, and this command writes **no
`--print-set` at all** when the changed set is empty and the mode is not `all` —
a missing file is the empty set. -/
def impactCmd (args : List String) : IO UInt32 := do
  match parseImpact args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let some ir := a.ir | refuse "--ir is required"
    try
      impactRun a ir
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

structure PruneArgs where
  pages : Option String := none
  remove : Option String := none
  ir : Option String := none
  json : Option String := none
  dryRun : Bool := false
  help : Bool := false
  deriving Inhabited

partial def parsePrune : List String → PruneArgs → Except String PruneArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    if flag == "--pages" then do
      let (v, more) ← value; parsePrune more { acc with pages := some v }
    else if flag == "--remove" then do
      let (v, more) ← value; parsePrune more { acc with remove := some v }
    else if flag == "--ir" then do
      let (v, more) ← value; parsePrune more { acc with ir := some v }
    else if flag == "--json" then do
      let (v, more) ← value; parsePrune more { acc with json := some v }
    else if flag == "--dry-run" then
      parsePrune rest { acc with dryRun := true }
    else if flag == "--help" || flag == "-h" then
      parsePrune rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

def pruneRunCmd (a : PruneArgs) (pages : String) : IO UInt32 := do
  match ← prune { pages := ⟨pages⟩, remove := a.remove.map (⟨·⟩), ir := a.ir.map (⟨·⟩)
                  dryRun := a.dryRun, json := a.json.map (⟨·⟩) } with
  | .error (code, message) => refusedWith code message
  | .ok s =>
    IO.println s!"prune-pages{if s.dryRun then " (dry run)" else ""}: deleted \
      {s.deleted.size}/{s.requested} requested, {s.orphans.size} orphan(s), \
      {s.emptied.size} empty dir(s) — {seconds s.totalNanos 4} s"
    for orphan in s.orphans.extract 0 orphansInLog do
      IO.println s!"  orphan  {orphan}"
    return 0

/-- **The one subcommand that deletes.** Two guards are in the library
(containment, and paths built by concatenation rather than `FilePath./`); the
third is the shape of the flag — `--dry-run` computes the whole answer and writes
nothing, so "what would this remove" can be asked of a tree nobody is willing to
lose. -/
def pruneCmd (args : List String) : IO UInt32 := do
  match parsePrune args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    -- A page tree with neither a deletion list nor an IR to call orphans against
    -- has nothing to do, and doing nothing quietly is how a deleted module's
    -- page survives.
    let missing := "prune needs --pages <dir> and at least one of --remove <file> / --ir <dir>"
    let some pages := a.pages | refuse missing
    if a.remove.isNone && a.ir.isNone then return ← refuse missing
    try
      pruneRunCmd a pages
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

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

structure IncrementalArgs where
  ir : Option String := none
  pages : Option String := none
  ledger : Option String := none
  work : Option String := none
  modules : Option String := none
  sourceUrl : Option String := none
  linkIndex : Option String := none
  makeLinkIndex : Bool := false
  state : Option String := none
  extractor : Option String := none
  extractorArgs : Array String := #[]
  mode : Option String := none
  maxRounds : Nat := defaultMaxRounds
  timings : Option String := none
  serve : Bool := false
  jobs : Nat := 1
  jobsGiven : Bool := false
  extractorBin : Option String := none
  target : Option String := none
  lake : Option String := none
  root : Option String := none
  help : Bool := false
  deriving Inhabited

/-- Flags the Rust `incremental` refuses by name. Every one is a real flag of
something — an ablation, a measurement tool, a prototype's label — so what a
caller needs to hear is why it is not offered, not that it was misspelled. -/
def incrementalRefusal (flag : String) : Option String :=
  if flag == "--l3-1" then
    some "--l3-1 is not a pipeline flag: `off` was the ablation that measured L3-1's contribution \
      and it produces a wrong site (a referring module keeps an IR naming the module a declaration \
      used to live in). Ownership always runs"
  else if flag == "--global" then
    some "--global is not a pipeline flag: `old` was stage 5's two-process derivation, kept only \
      as the control of stage 7h's A/B. The product is always the cached one, which is why \
      --state is required"
  else if flag == "--serve-dir" then
    some "--serve-dir is not offered: `--serve` starts a server this run owns, and a server it \
      does not own is one whose olean generation it cannot vouch for. Correctness comes from that \
      generation and never from the round number — a server imported before the edit returns the \
      pre-edit owner of every name that moved, and then no round is safe, including round 2 \
      (measured, stage 6a)"
  else if flag == "--serve-from" then
    some "--serve-from is not offered: it chose which rounds a server the caller owns was allowed \
      to answer, and stage 6a measured that the round number is not what makes a round safe. With \
      `--serve` the server is started inside this run, so every round is served and every round \
      is checked against the same olean generation"
  else if flag == "--count-reads" then
    some "--count-reads is a measurement tool, not a product flag: it wraps every stage to count \
      IR reads and makes the timings meaningless"
  else if flag == "--module" then
    some "--module is not a pipeline flag: the prototype's is a label that goes straight into the \
      timings record and is read by nothing. A harness that needs one adds it to the line it \
      appends"
  else if flag == "--no-link-index" then
    some "--no-link-index is not an incremental flag: a round re-renders a subset, so a page \
      rendered without the map is indistinguishable from one that was not re-rendered at all"
  else none

/-- Flags the Rust `incremental` takes and this one does not, refused by name for
the reason `renderUnimplemented` is. -/
def incrementalUnimplemented : List String :=
  ["--deps-docs-map"]

partial def parseIncremental : List String → IncrementalArgs → Except String IncrementalArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    match incrementalRefusal flag with
    | some message => .error message
    | none =>
    if flag == "--ir" then do
      let (v, more) ← value; parseIncremental more { acc with ir := some v }
    else if flag == "--pages" then do
      let (v, more) ← value; parseIncremental more { acc with pages := some v }
    else if flag == "--ledger" then do
      let (v, more) ← value; parseIncremental more { acc with ledger := some v }
    else if flag == "--work" then do
      let (v, more) ← value; parseIncremental more { acc with work := some v }
    else if flag == "--modules" then do
      let (v, more) ← value; parseIncremental more { acc with modules := some v }
    else if flag == "--source-url" then do
      let (v, more) ← value; parseIncremental more { acc with sourceUrl := some v }
    else if flag == "--link-index" then do
      let (v, more) ← value; parseIncremental more { acc with linkIndex := some v }
    else if flag == "--make-link-index" then
      parseIncremental rest { acc with makeLinkIndex := true }
    else if flag == "--state" then do
      let (v, more) ← value; parseIncremental more { acc with state := some v }
    else if flag == "--extractor" then do
      let (v, more) ← value; parseIncremental more { acc with extractor := some v }
    else if flag == "--extractor-arg" then do
      let (v, more) ← value
      parseIncremental more { acc with extractorArgs := acc.extractorArgs.push v }
    else if flag == "--mode" then do
      let (v, more) ← value; parseIncremental more { acc with mode := some v }
    else if flag == "--max-rounds" then do
      let (v, more) ← value
      match v.toNat? with
      | some n => parseIncremental more { acc with maxRounds := n }
      | none => .error s!"--max-rounds takes a number, not `{v}`"
    else if flag == "--timings" then do
      let (v, more) ← value; parseIncremental more { acc with timings := some v }
    else if flag == "--serve" then
      parseIncremental rest { acc with serve := true }
    else if flag == "--extractor-bin" then do
      let (v, more) ← value; parseIncremental more { acc with extractorBin := some v }
    else if flag == "--target" then do
      let (v, more) ← value; parseIncremental more { acc with target := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseIncremental more { acc with lake := some v }
    else if flag == "--root" then do
      let (v, more) ← value; parseIncremental more { acc with root := some v }
    else if flag == "--jobs" then do
      let (v, more) ← value
      match v.toNat? with
      | some n => parseIncremental more { acc with jobs := n, jobsGiven := true }
      | none => .error s!"--jobs takes a number, not `{v}`"
    else if flag == "--help" || flag == "-h" then
      parseIncremental rest { acc with help := true }
    else if incrementalUnimplemented.contains flag then
      .error s!"{flag} is an `incremental` flag this build does not implement"
    else
      .error s!"unknown argument `{flag}`"

/-- The command line's own answers, in the order a caller meets them: what is
missing, then what cannot be combined, then what belongs to the other extraction
path. -/
def incrementalUsage (a : IncrementalArgs) : Option String := Id.run do
  for (flag, given) in [("--ir", a.ir.isSome), ("--pages", a.pages.isSome),
      ("--ledger", a.ledger.isSome), ("--work", a.work.isSome)] do
    if !given then return some s!"{flag} is required"
  if a.modules.isNone then
    return some "--modules is required: without the current module list `check` re-reads the \
      ledger's own and cannot see a module that appeared or vanished. `litedoc4 modules` writes it"
  match a.sourceUrl with
  | none => return some "--source-url is required"
  | some url =>
    if url.isEmpty then return some "--source-url is required"
    if let some message := checkSourceUrl url then return some message
  if a.linkIndex.isNone then
    return some s!"--link-index <file> is required, and there is no --no-link-index here: \
      {linkIndexRequired}"
  if a.state.isNone then
    return some "--state <dir> is required: the whole-package derivation is always the cached one, \
      and the map delta it feeds the renderer needs a cache to compare against. The previous run \
      — full generation with `litedoc4 site --state`, or the last incremental round — is what \
      leaves it behind"
  if a.serve && a.extractor.isSome then
    return some "--serve and --extractor are exclusive: one names a program to run once per \
      round, the other says this run owns a Lean environment for all of them. `--serve` is the \
      resident path and it uses --extractor-bin, not a wrapper"
  if a.makeLinkIndex && !a.serve then
    return some "--make-link-index is a flag of --serve: the dependency map is written by the \
      Lean extractor out of the environment it imported for the extraction, and --serve is the \
      path where this command spells that command line. Behind --extractor, the program is the \
      one that decides — `litedoc4 extract --link-index <file>` writes it — and --link-index here \
      names the file it wrote"
  if !a.serve then
    -- A list and not a chain of `if`s on the name with a fallthrough: adding a
    -- fourth flag and forgetting the arm makes the fallthrough answer for it, so
    -- the refusal names the new flag while the check behind it reads `--lake`.
    for (flag, given) in [("--extractor-bin", a.extractorBin.isSome),
        ("--target", a.target.isSome), ("--lake", a.lake.isSome)] do
      if given then
        return some s!"{flag} is a flag of --serve: without it the extraction is whatever \
          --extractor names, and how that program finds its binary is its own business \
          (`litedoc4 extract` takes {flag} through --extractor-arg)"
    if a.jobs != 1 then
      return some "--jobs is a flag of --serve: parallelism is the extractor's, and a resident \
        one fixes it at start-up. Behind --extractor, pass it through with `--extractor-arg \
        --jobs --extractor-arg <n>`"
  if a.jobs == 0 then return some "--jobs must be at least 1"
  if !a.serve && a.extractor.isNone then
    return some "one of --extractor <program> and --serve is required, and neither has a default: \
      --extractor is called as `<program> [<extractor-arg>…] --modules <list> --ir-dir <dir> \
      --timings <file>`, which is `litedoc4 extract`'s interface; --serve starts one resident \
      Lean environment for the whole run and needs --extractor-bin and --target"
  -- Refused here rather than carried into `impact`, which only looks at the mode
  -- when there is something to select: a misspelled mode with an empty changed
  -- set would otherwise exit 0 having rendered nothing.
  if let some text := a.mode then
    if ImpactMode.parse text matches .unrecognised _ then
      return some s!"--mode takes self|referrers|importers|all, not `{text}`"
  if a.maxRounds == 0 then
    return some "--max-rounds must be at least 1: round 1 is where deletions are folded in"
  return none

def incrementalRun (a : IncrementalArgs) : IO UInt32 := do
  if let some message := incrementalUsage a then return ← refuse message
  let some ir := a.ir | return ← refuse "--ir is required"
  let some pages := a.pages | return ← refuse "--pages is required"
  let some ledgerPath := a.ledger | return ← refuse "--ledger is required"
  let some work := a.work | return ← refuse "--work is required"
  let some modulesFile := a.modules | return ← refuse "--modules is required"
  let some sourceUrl := a.sourceUrl | return ← refuse "--source-url is required"
  let some linkIndex := a.linkIndex | return ← refuse "--link-index is required"
  let some state := a.state | return ← refuse "--state is required"
  let moduleList ← readModuleList ⟨modulesFile⟩
  -- Once, before anything else runs: the same value `detect` hashes into the
  -- render key and the render step draws with.
  let external ← resolveExternal a.root a.lake
  -- **Built before the run starts, so the generation is the world `detect` is
  -- about to look at.** `Resident.new` starts nothing; it records the oleans, and
  -- every later check is against this one reading.
  let opened ← (show BuildM Extractor from do
    match a.extractor with
    | some program =>
      pure (Extractor.oneShot
        { program, args := a.extractorArgs, requestCount := ← IO.mkRef 0 })
    | none =>
      pure (Extractor.resident (← Resident.new (← serveOptions
        { bin := a.extractorBin.map (⟨·⟩), target := a.target.map (⟨·⟩)
          lake := a.lake.map (⟨·⟩), jobs := a.jobs, modulesFile := ⟨modulesFile⟩
          modules := moduleList, work := ⟨work⟩
          linkIndex := if a.makeLinkIndex then some ⟨linkIndex⟩ else none })))).run
  let extractor ← match opened with
    | .error (code, message) => return ← (if code == 2 then refuse message
                                          else refusedWith code message)
    | .ok extractor => pure extractor
  let config ← readSiteConfig (a.root.map (⟨·⟩))
  let outcome ← (runIncremental
    { config, ir := ⟨ir⟩, pages := ⟨pages⟩, ledger := ⟨ledgerPath⟩, work := ⟨work⟩
      modules := moduleList, sourceUrl, linkIndex := ⟨linkIndex⟩, external, state := ⟨state⟩
      mode := (a.mode.map ImpactMode.parse).getD defaultMode
      maxRounds := a.maxRounds } extractor).run
  -- Not a `←` on the call above: the release has to happen on the failing path
  -- too, and doing it here is what puts the stop **before** the error reaches the
  -- caller rather than after.
  extractor.release
  match outcome with
  | .error (code, message) => if code == 2 then refuse message else refusedWith code message
  | .ok run =>
    if let some path := a.timings then
      let ran := match extractor with
        | .resident r => Ran.resident a.jobs r.generation.digest
        | .oneShot _ => Ran.oneShot
      writeTimings ⟨path⟩ ⟨work⟩ run.summary run.timings ran
    return 0

/-- The pipeline: a ledger in, a re-rendered subset of the site out.

**It does not rewrite the ledger** — a stage that answers a question must not
move the state its answer was about. A chain of bare `incremental` runs therefore
needs `litedoc4 ledger build` between them, or the second run re-extracts the
first run's changed set again: wasteful, not wrong. -/
def incremental (args : List String) : IO UInt32 := do
  match parseIncremental args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    try
      incrementalRun a
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

structure ExtractArgs where
  modules : Option String := none
  irDir : Option String := none
  timings : Option String := none
  events : Option String := none
  linkIndex : Option String := none
  linkIndexOmit : Option String := none
  linkIndexKey : Option String := none
  jobs : Nat := 1
  bin : Option String := none
  target : Option String := none
  lake : Option String := none
  help : Bool := false
  deriving Inhabited

/-- Flags of the program behind this one, refused by name rather than as "unknown
argument": each is real, so what a caller needs to hear is why it is not offered
here. -/
def extractRefusal (flag : String) : Option String :=
  if flag == "--serve" || flag == "--serve-dir" || flag == "--serve-from" then
    some s!"{flag} is not an `extract` flag: residency is `litedoc4 incremental --serve`. A server \
      that answers one request and stops is this command with a protocol in front of it — the \
      environment is still imported once per extraction — so the only caller it can pay off for \
      is the round loop, which owns the server for the whole run. `--serve-dir` is not offered \
      anywhere: a server this process did not start is one whose olean generation it cannot vouch \
      for, and that is where correctness comes from (measured)"
  else if fixedFlags.contains flag then
    some s!"{flag} is not a flag here: it is always on. Those four are what \"IR schema 5\" means, \
      and an IR written without one of them parses and renders wrongly rather than failing"
  else if ["--no-attrs", "--no-inst-index", "--no-member-extra"].contains flag then
    some s!"{flag} is an ablation, not a product flag: it subtracts one of three extractor \
      additions so its cost can be measured, and the resulting index.json carries an `ablations` \
      list precisely because the tree is not renderable"
  else if ["--decl-profile", "--pp-breakdown", "--dump", "--dump-modules", "--dump-refs",
      "--dump-tactics", "--only", "--open", "--tag", "--skip-analyze", "--tactics-emulate",
      "--tactics-probe"].contains flag then
    some s!"{flag} is a measurement or inspection flag of the extractor, not a product one. Run \
      `extractor/build/extract` directly for it — the command line is in `Extract.lean`'s header"
  else none

partial def parseExtract : List String → ExtractArgs → Except String ExtractArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    match extractRefusal flag with
    | some message => .error message
    | none =>
    if flag == "--modules" then do
      let (v, more) ← value; parseExtract more { acc with modules := some v }
    else if flag == "--ir-dir" then do
      let (v, more) ← value; parseExtract more { acc with irDir := some v }
    else if flag == "--timings" then do
      let (v, more) ← value; parseExtract more { acc with timings := some v }
    else if flag == "--events" then do
      let (v, more) ← value; parseExtract more { acc with events := some v }
    else if flag == "--link-index" then do
      let (v, more) ← value; parseExtract more { acc with linkIndex := some v }
    else if flag == "--link-index-omit" then do
      let (v, more) ← value; parseExtract more { acc with linkIndexOmit := some v }
    else if flag == "--link-index-key" then do
      let (v, more) ← value; parseExtract more { acc with linkIndexKey := some v }
    else if flag == "--extractor-bin" then do
      let (v, more) ← value; parseExtract more { acc with bin := some v }
    else if flag == "--target" then do
      let (v, more) ← value; parseExtract more { acc with target := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseExtract more { acc with lake := some v }
    else if flag == "--jobs" then do
      let (v, more) ← value
      match v.toNat? with
      | some n => parseExtract more { acc with jobs := n }
      | none => .error s!"--jobs takes a number, not `{v}`"
    else if flag == "--help" || flag == "-h" then
      parseExtract rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

/-- One extractor process over a module list, and its phase timers folded into
one JSON object.

**A subcommand and not a library call**, unlike every other stage: `litedoc4
incremental --extractor` already names a *program*, whose contract is `<program>
[<extractor-arg>…] --modules <list> --ir-dir <dir> --timings <file>`, and this
lets the product be its own extractor without closing that seam. The Lean
extractor cannot be linked in either: it is 171 MB, built against the *target's*
toolchain, and it has to run with that target as its working directory, so a
process boundary exists whatever this command does. -/
def extractRun (a : ExtractArgs) : BuildM Unit := do
  let some modules := a.modules
    | throw (2, "--modules <file> is required: the module list to extract, one name per line")
  let some irDir := a.irDir
    | throw (2, "--ir-dir <dir> is required and has no default: an IR tree written somewhere the \
        caller did not name is worse than none")
  let some timings := a.timings
    | throw (2, "--timings <file> is required: it is the extractor's phase timers folded into one \
        JSON object, and `litedoc4 incremental` merges it into the run's record")
  if a.jobs == 0 then throw (2, "--jobs must be at least 1")
  -- Refused rather than ignored, although the extractor itself tolerates the
  -- combination: a flag that does nothing is the shape of bug this project keeps
  -- finding — the run looks right and the artefact is not the one that was asked
  -- for.
  if a.linkIndexOmit.isSome && a.linkIndex.isNone then
    throw (2, "--link-index-omit without --link-index does nothing: it names the modules whose \
      declaration groups are left out of the map, and no map is being written")
  if a.linkIndexKey.isSome && a.linkIndex.isNone then
    throw (2, "--link-index-key without --link-index does nothing: it is the token that lets the \
      extractor leave an already-correct map alone, and no map is being written or read")
  let some bin ← envOr (a.bin.map (⟨·⟩)) "EXTRACT_BIN"
    | throw (2, "--extractor-bin <path> is required (or EXTRACT_BIN): the Lean extractor built by \
        `extractor/build.sh`, which is 171 MB and is therefore not committed. There is no \
        default — the binary is built against the target's toolchain, so a path baked in here \
        would be right on exactly one machine")
  let some target ← envOr (a.target.map (⟨·⟩)) "TARGET_REPO"
    | throw (2, "--target <repo> is required (or TARGET_REPO): the Lean package being documented. \
        `lake env` runs inside it, which is how the extractor gets the oleans and the search path \
        without litedoc4 owning a toolchain")
  -- `lake` does get a default because it is a name looked up on PATH, not a
  -- path: elan installs a shim under that name, and the shim is what picks the
  -- toolchain the target pins.
  let lake := (← envOr (a.lake.map (⟨·⟩)) "LAKE").getD ⟨"lake"⟩
  let target ← match ← (IO.FS.realPath target).toBaseIO with
    | .error e => throw (3, s!"--target {target}: {e}")
    | .ok path => pure path
  let bin ← absolutePath bin
  refuseInside target "--target" ⟨irDir⟩ "--ir-dir" ""
  if let some path := a.linkIndex then
    refuseInside target "--target" ⟨path⟩ "--link-index" ""
  -- **Every path handed to the child is made absolute first, and the guard above
  -- is why** (measured 2026-08-15). `lake env` runs inside the target, so a
  -- relative path on that command line resolves against the package being
  -- documented: the guard passes (the path resolves against *this* process's
  -- directory) and the extractor then writes the IR tree inside the target.
  let irDir ← absolutePath ⟨irDir⟩
  let modulesPath ← absolutePath ⟨modules⟩
  let events ← absolutePath
    ((a.events.map (⟨·⟩ : String → System.FilePath)).getD (eventsBeside ⟨timings⟩))
  -- Removed rather than truncated on open: the extractor appends, so a stale
  -- file from an earlier round would be folded into this round's timings.
  discard <| (IO.FS.removeFile events).toBaseIO
  IO.FS.createDirAll irDir
  let mut args := #["env", bin.toString, modulesPath.toString, events.toString]
  args := args ++ fixedFlags
  args := args ++ #["--jobs", toString a.jobs, "--ir-dir", irDir.toString]
  if let some path := a.linkIndex then
    let path ← absolutePath ⟨path⟩
    if let some dir := path.parent then
      if !dir.toString.isEmpty then IO.FS.createDirAll dir
    args := args.push "--link-index" |>.push path.toString
    -- Made absolute for the reason above, but **not** guarded against being
    -- inside the target: the difference is the direction of the I/O. The map is
    -- written; this one is read, and a module list that lives inside the package
    -- being documented is an odd place to keep it, not a write into it.
    if let some omitList := a.linkIndexOmit then
      args := args.push "--link-index-omit" |>.push (← absolutePath ⟨omitList⟩).toString
    if let some key := a.linkIndexKey then
      args := args.push "--link-index-key" |>.push key
  -- The extractor's stdout is a human-readable phase report; the
  -- machine-readable copy of the same numbers is the events file, which is what
  -- the timings are folded from. stderr is inherited, so a Lean error still
  -- reaches the caller.
  let child ← match ← (IO.Process.spawn
      { cmd := lake.toString, cwd := some target, args
        stdin := .inherit, stdout := .null, stderr := .inherit }).toBaseIO with
    | .error e => throw (4, s!"{lake} env {bin}: {e}")
    | .ok child => pure child
  let code ← child.wait
  if code != 0 then
    throw (4, s!"the extractor exited {code} for {modulesPath}; the IR tree at {irDir} is \
      incomplete")
  let counted ← foldTimings { events, modules := modulesPath, jobs := a.jobs, out := ⟨timings⟩ }
  IO.println s!"extract {counted} module(s) -> {irDir} (timings {timings})"

def extract (args : List String) : IO UInt32 := do
  match parseExtract args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    try
      match ← (extractRun a).run with
      | .ok () => pure (0 : UInt32)
      | .error (code, message) => if code == 2 then refuse message else refusedWith code message
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
  | "global" :: rest => Litedoc4.globalCmd rest
  | "ownership" :: rest => Litedoc4.ownershipCmd rest
  | "merge" :: rest => Litedoc4.mergeCmd rest
  | "impact" :: rest => Litedoc4.impactCmd rest
  | "prune" :: rest => Litedoc4.pruneCmd rest
  | "incremental" :: rest => Litedoc4.incremental rest
  | "extract" :: rest => Litedoc4.extract rest
  | [] | "--help" :: _ | "-h" :: _ =>
    IO.println Litedoc4.usage
    return 0
  | arg :: _ =>
    IO.eprintln s!"litedoc4: unknown subcommand `{arg}`"
    IO.eprintln Litedoc4.usage
    return 2
