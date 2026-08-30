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
"usage: litedoc4 render --ir <dir> --pages <dir> --source-url <url>
                       (--link-index <file> | --no-link-index)
       litedoc4 site --ir <dir> --out <dir> --source-url <url>
                     (--link-index <file> | --no-link-index)
       litedoc4 --version
       litedoc4 --help"

structure RenderArgs where
  ir : Option String := none
  pages : Option String := none
  sourceUrl : Option String := none
  linkIndex : Option String := none
  noLinkIndex : Bool := false
  help : Bool := false
  deriving Inhabited

/-- Flags the Rust `render` takes and this one does not. They are refused by
name rather than ignored: a run that silently dropped `--only` would write every
page and a run that silently dropped `--root` would write different links, and
in both the output looks like a match. -/
def renderUnimplemented : List String :=
  ["--root", "--lake", "--deps-docs-map", "--only", "--only-from"]

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

/-- The cost is why the choice is not a default: the map is what turns a name in
a signature into a link, and a site built without one is a site of dead names. -/
def linkIndexRequired : String :=
  "pass --link-index <file>, or --no-link-index to say so on purpose"

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
      let summary ← renderSite
        { ir := ir, pages := pages, sourceUrl := sourceUrl
          linkIndex := a.linkIndex.map (⟨·⟩) }
      IO.println s!"modules {summary.pagesWritten}/{summary.modulesInIr}  \
        declarations {summary.declarationsRendered}/{summary.declarationsInIr} \
        ({summary.declarationsSuppressed} suppressed)  module docs {summary.moduleDocs}  \
        bytes {summary.bytes}"
      IO.println s!"known {summary.known}  link index {summary.linkIndexEntries}  \
        known modules {summary.knownModules}"
      -- Printed at zero too: the fallback it reports is silent, so a line that
      -- appeared only above zero could not be told from one that had stopped
      -- being printed. What would falsify that: a fallback the page itself
      -- shows, which the reader could see without being told.
      IO.println s!"math spans kept as LaTeX {summary.mathFailures}"
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
  help : Bool := false
  deriving Inhabited

/-- Flags the Rust `site` takes and this one does not, refused by name for the
reason `renderUnimplemented` is. -/
def siteUnimplemented : List String :=
  ["--root", "--lake", "--deps-docs-map", "--state", "--timings"]

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
      let rendered ← renderSite
        { ir := ir, pages := out, sourceUrl := sourceUrl
          linkIndex := a.linkIndex.map (⟨·⟩) }
      let derived ← buildGlobal ir out
      -- Labelled per stage: one merged line would lose which half of the tree a
      -- number is about, and the two count different things under the same word
      -- ("modules").
      IO.println s!"render  modules {rendered.pagesWritten}/{rendered.modulesInIr}  \
        declarations {rendered.declarationsRendered}/{rendered.declarationsInIr} \
        ({rendered.declarationsSuppressed} suppressed)  module docs {rendered.moduleDocs}  \
        bytes {rendered.bytes}"
      IO.println s!"render  known {rendered.known}  link index {rendered.linkIndexEntries}  \
        known modules {rendered.knownModules}"
      IO.println s!"render  math spans kept as LaTeX {rendered.mathFailures}"
      IO.println s!"global  modules {derived.modules}  declarations {derived.declarations} + \
        {derived.dependencyNames} dependency names  instance classes \
        {derived.instanceClasses}  instance types {derived.instanceTypes}  \
        tactic docs {derived.tacticDocs}"
      IO.println s!"global  name map {derived.nameMapBytes} B  \
        module index {derived.modulesJsonBytes} B  \
        search index {derived.searchIndexBytes} B"
      IO.println s!"global  module descriptions {derived.summariesRendered} of \
        {derived.modules} ({derived.summariesEchoingTheName} repeat the module name)"
      IO.println s!"global  cache {derived.cacheHits} hit / {derived.cacheMisses} miss  \
        state {derived.stateBytes} B"
      return 0
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      return 1

end Litedoc4

def main (args : List String) : IO UInt32 := do
  match args with
  | "--version" :: _ =>
    IO.println s!"litedoc4 {Litedoc4.version}"
    return 0
  | "render" :: rest => Litedoc4.render rest
  | "site" :: rest => Litedoc4.site rest
  | [] | "--help" :: _ | "-h" :: _ =>
    IO.println Litedoc4.usage
    return 0
  | arg :: _ =>
    IO.eprintln s!"litedoc4: unknown subcommand `{arg}`"
    IO.eprintln Litedoc4.usage
    return 2
