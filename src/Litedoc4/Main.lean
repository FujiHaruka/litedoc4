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
                             [--root <dir>] [--lake <path>]
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
  ir : Option String := none
  sourceUrl : String := ""
  linkIndex : Option String := none
  root : Option String := none
  lake : Option String := none
  help : Bool := false
  deriving Inhabited

/-- Flags the Rust `ledger build` takes and this one does not. `--algorithm` and
`--concurrency` are refused rather than accepted-and-ignored: this build offers
one algorithm and one thread, and a run that took `--concurrency 8` would look
like it had done what was asked. -/
def ledgerUnimplemented : List String :=
  ["--algorithm", "--concurrency", "--deps-docs-map", "--timings"]

partial def parseLedger : List String → LedgerArgs → Except String LedgerArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} wants a value"
    if flag == "--modules" then do
      let (v, more) ← value; parseLedger more { acc with modules := some v }
    else if flag == "--target" then do
      let (v, more) ← value; parseLedger more { acc with target := some v }
    else if flag == "--out" then do
      let (v, more) ← value; parseLedger more { acc with out := some v }
    else if flag == "--ir" then do
      let (v, more) ← value; parseLedger more { acc with ir := some v }
    else if flag == "--source-url" then do
      let (v, more) ← value; parseLedger more { acc with sourceUrl := v }
    else if flag == "--link-index" then do
      let (v, more) ← value; parseLedger more { acc with linkIndex := some v }
    else if flag == "--root" then do
      let (v, more) ← value; parseLedger more { acc with root := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseLedger more { acc with lake := some v }
    else if flag == "--help" || flag == "-h" then
      parseLedger rest { acc with help := true }
    else if ledgerUnimplemented.contains flag then
      .error s!"{flag} is a `ledger build` flag this build does not implement"
    else
      .error s!"unknown argument `{flag}`"

def ledgerBuildRun (a : LedgerArgs) (modules target out : String) : IO UInt32 := do
  let names ← readModuleList ⟨modules⟩
  let external ← resolveExternal a.root a.lake
  let result ← buildLedger
    { modules := names, target := target, ir := a.ir.map (⟨·⟩), sourceUrl := a.sourceUrl
      linkIndex := a.linkIndex.map (⟨·⟩), externalLinks := some external.digest }
  match result with
  | .error message =>
    IO.eprintln s!"litedoc4: {message}"
    return 3
  | .ok ledger =>
    let body := ledger.toJson
    if let some dir := (⟨out⟩ : System.FilePath).parent then
      if !dir.toString.isEmpty then IO.FS.createDirAll dir
    IO.FS.writeFile out body
    let files := ledger.modules.foldl (fun n m => n + m.files.size) 0
    let hashed := ledger.modules.foldl (fun n m => m.files.foldl (fun k f => k + f.bytes) n) 0
    IO.println s!"build {ledger.modules.size} modules, {files} olean file(s), {hashed} B hashed \
      -> {out} ({body.utf8ByteSize} B)"
    return 0

def ledgerBuild (args : List String) : IO UInt32 := do
  match parseLedger args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let missing := "ledger build needs --modules <file>, --target <repo> and --out <ledger.json>"
    let some modules := a.modules | refuse missing
    let some target := a.target | refuse missing
    let some out := a.out | refuse missing
    try
      return ← ledgerBuildRun a modules target out
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      return 1

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
        -- **No line at all** when there are no names: an empty set has to be an
        -- empty file rather than one blank line.
        writeFile ⟨path⟩ (if names.isEmpty then "" else "\n".intercalate names.toList ++ "\n")
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

/-- `check` and `touch` are refused by name rather than as a misspelling: they
are the incremental half, and a caller needs to hear that this build stops at
the ledger the first round writes. -/
def ledger (args : List String) : IO UInt32 := do
  match args with
  | [] => refuse "ledger needs a subcommand: build"
  | command :: rest =>
    if command == "build" then ledgerBuild rest
    else if command == "check" || command == "touch" then
      refuse s!"`ledger {command}` is not implemented by this build"
    else if command == "--help" || command == "-h" then do
      IO.println usage
      return 0
    else refuse s!"unknown `ledger` subcommand `{command}`"

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
  | [] | "--help" :: _ | "-h" :: _ =>
    IO.println Litedoc4.usage
    return 0
  | arg :: _ =>
    IO.eprintln s!"litedoc4: unknown subcommand `{arg}`"
    IO.eprintln Litedoc4.usage
    return 2
