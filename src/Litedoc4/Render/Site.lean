/- `crates/litedoc4-render/src/site.rs`: the whole of `litedoc4 render`. -/
import Litedoc4.Render.Page

open System

namespace Litedoc4

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
  let tree ← openIrTree o.ir
  let deps ← tree.loadDepMaps
  let mods ← tree.loadModules
  let lidx ← match o.linkIndex with
    | some p => do parseLidx (← readIrFile p)
    | none => pure emptyLidx
  let ix ← buildIndex deps mods lidx
  let sup ← suppressedOf mods
  let title := siteTitle (mods.map (·.name))
  IO.FS.createDirAll o.pages
  let mut bytes := 0
  let mut mathFailures := 0
  for m in mods do
    let (html, pageMathFailures) ← match (pageHtml ix m sup o.sourceUrl title).run 0 with
      | .ok r => pure r
      | .error message => throw (IO.userError s!"rendering {m.name}: {message}")
    bytes := bytes + html.utf8ByteSize
    mathFailures := mathFailures + pageMathFailures
    writePage o.pages m.name html
  return {
    pagesWritten := mods.size
    modulesInIr := mods.size
    declarationsRendered :=
      mods.foldl (fun a m => a + (m.decls.filter (fun d => !sup.contains d.name)).size) 0
    declarationsInIr := mods.foldl (fun a m => a + m.decls.size) 0
    declarationsSuppressed := sup.size
    moduleDocs := mods.foldl (fun a m => a + m.moduleDocs.size) 0
    bytes
    known := ix.known.size
    linkIndexEntries := ix.lidx.names.size
    knownModules := ix.knownModules.size
    mathFailures }

end Litedoc4
