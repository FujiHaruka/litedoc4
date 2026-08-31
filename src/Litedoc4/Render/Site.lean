/- `crates/litedoc4-render/src/site.rs`: the whole of `litedoc4 render`.

Every module file is read even when only one page is being rendered. The name
map and the suppressed set are site-wide, and a page rendered against a partial
map differs in the links it draws rather than failing — a byte difference no
error message announces. That is why `ModuleSet` filters *pages*, not *reads*. -/
import Litedoc4.Render.Page

open System

namespace Litedoc4

/-- Which modules get a page written.

**`these` over an empty set writes nothing.** The constructor exists so that
"the caller computed a set and it came out empty" cannot be spelled the same way
as "the caller did not ask for a subset". -/
inductive ModuleSet where
  | all
  | these (names : Std.HashSet String)
  deriving Inhabited

def ModuleSet.contains : ModuleSet → String → Bool
  | .all, _ => true
  | .these names, module => names.contains module

/-- One module name per line, as the incremental pipeline's render set is
written. Blank lines are dropped; **an empty file is an empty set**.

Split on `\n` rather than through Rust's `str::lines`, which also drops a `\r`
before it: the trim below removes that `\r` and the empty last element of a text
ending in a newline, so the two spellings cannot differ. What would falsify
this: a trim that stops being over Unicode `White_Space`. -/
def moduleSetLines (text : String) : Std.HashSet String := Id.run do
  let mut names : Std.HashSet String := Std.HashSet.emptyWithCapacity 64
  for line in text.splitOn "\n" do
    let line := trimWs line
    if !line.isEmpty then names := names.insert line
  return names

def ModuleSet.fromLines (text : String) : ModuleSet := .these (moduleSetLines text)

def writePage (outDir : FilePath) (module html : String) : IO Unit := do
  let p := pagePath outDir module
  match p.parent with
  | some d => IO.FS.createDirAll d
  | none => pure ()
  IO.FS.writeFile p html

structure Options where
  ir : FilePath
  pages : FilePath
  sourceUrl : String
  /-- `none` is `--no-link-index`, which is a different answer from a map that
  came out empty: the flag is required precisely so that neither can be reached
  by forgetting the other. -/
  linkIndex : Option FilePath
  /-- Empty is the answer for a run with no `--root`: no manifest, no revisions,
  and nothing to link a dependency at. -/
  external : ExternalLinks := {}
  /-- `litedoc4.toml`'s `title`; `none` takes the one `siteTitle` derives from
  the module names. -/
  title : Option String := none
  only : ModuleSet := .all
  deriving Inhabited

structure Summary where
  pagesWritten : Nat := 0
  modulesInIr : Nat := 0
  declarationsRendered : Nat := 0
  declarationsInIr : Nat := 0
  declarationsSuppressed : Nat := 0
  moduleDocs : Nat := 0
  bytes : Nat := 0
  known : Nat := 0
  linkIndexEntries : Nat := 0
  knownModules : Nat := 0
  mathFailures : Nat := 0
  deriving Inhabited

def renderSite (o : Options) : IO Summary := do
  -- `render` and `site` accept any non-empty `--source-url`, so a caller may
  -- hand one a trailing slash and every page would carry `…/e2e/micro//Mod.lean`
  -- (measured 2026-08-31). `build` cannot reach it — it demands 40 hex and
  -- builds the base itself — which is why every gate missed this.
  let sourceUrl := trimTrailingSlash o.sourceUrl
  let tree ← openIrTree o.ir
  let deps ← tree.loadDepMaps
  let mods ← tree.loadModules
  let lidx ← match o.linkIndex with
    | some p => do pure (parseLidx (← readIrFile p))
    | none => pure emptyLidx
  let ix := buildIndex deps mods lidx o.external
  let sup := suppressedOf mods
  -- Over **every** module of the IR, not the subset being rendered: an
  -- incremental round that re-renders one page must not retitle the site.
  let title := o.title.getD (siteTitle (mods.map (·.name)))
  let mut pagesWritten := 0
  let mut declarationsRendered := 0
  let mut moduleDocs := 0
  let mut bytes := 0
  let mut mathFailures := 0
  for m in mods do
    if !o.only.contains m.name then continue
    let (html, pageMathFailures) ← match (pageHtml ix m sup sourceUrl title).run 0 with
      | .ok r => pure r
      | .error message => throw (IO.userError s!"rendering {m.name}: {message}")
    mathFailures := mathFailures + pageMathFailures
    writePage o.pages m.name html
    pagesWritten := pagesWritten + 1
    bytes := bytes + html.utf8ByteSize
    moduleDocs := moduleDocs + m.moduleDocs.size
    declarationsRendered :=
      declarationsRendered + (m.decls.filter (fun d => !sup.contains d.name)).size
  return {
    pagesWritten
    modulesInIr := mods.size
    declarationsRendered
    declarationsInIr := mods.foldl (fun a m => a + m.decls.size) 0
    declarationsSuppressed := sup.size
    moduleDocs
    bytes
    known := ix.known.size
    linkIndexEntries := ix.lidx.names.size
    knownModules := ix.knownModules.size
    mathFailures }

end Litedoc4
