/- The static files a page needs to look like a page, carried in the executable
rather than shipped beside it so that they cannot be a version behind the
renderer that names their classes.

The two that are about the table itself are closed. The two that are about what
happens to the files — whether every class a page emits is styled, and whether
writing them twice leaves the same bytes — run: the first renders pages, which
means Markdown, and the second writes a tree.

**The scripted half is not here, and cannot be.** Every class `web/src/*.ts`
assigns must be styled too, and Lean has no `include_str!` — `Litedoc4.Assets`
carries the *bundle*, not the sources. `tools/assets-gate.sh` holds that half:
it globs the scripts and checks each class it finds against `style.css`.

Two more questions are elsewhere on purpose: whether the frame only names assets
something writes is the site gate's, and whether `assets/` is what `web/src`
bundles to is `tools/assets-gate.sh`'s. -/
import Litedoc4.Build
import Litedoc4Test.Basis
import Litedoc4Test.RenderPage

namespace Litedoc4Test
open Litedoc4 System

/-- An asset that was moved or emptied still compiles into the executable, and a
zero-byte `style.css` is a site that loads and has no styling. The paths are flat
and relative because they are URLs a page asks for: one that could climb out of
the site root would be written outside the tree the build owns. -/
def everyAssetHasADistinctPathAndABody : Bool :=
  (assets.map (·.1)).toList.eraseDups.length == assets.size
    && assets.all fun (path, body) => !body.isEmpty && !emits path ".." && !emits path "/"

#guard everyAssetHasADistinctPathAndABody

/-- The assets ship inside the executable and land on every generated site, so
their size is a property of this project rather than of the package being
documented.

The limits are **round numbers above the current size, not the current size**: a
budget pinned to today's bytes fails on every edit, which teaches people to raise
it without looking. Raising a limit is allowed; raising it *without reading what
grew* is what this is here to make awkward — the answer to a large stylesheet is
to delete from it, not to adopt a framework. -/
def theAssetsStayWithinTheirBudget : Bool :=
  [("style.css", 32 * 1024), ("app.js", 20 * 1024), ("favicon.svg", 4 * 1024)].all
    fun (path, limit) => match assets.find? (·.1 == path) with
      | some (_, body) => body.utf8ByteSize ≤ limit
      | none => false

#guard theAssetsStayWithinTheirBudget

/-! ## What a rendered page emits -/

/-- Every class name in a `class="…"` attribute of a built page. -/
def classesIn (page : String) : Array String := Id.run do
  let mut out : Array String := #[]
  for chunk in (page.splitOn "class=\"").drop 1 do
    for name in ((chunk.splitOn "\"").headD "").splitOn " " do
      if !name.isEmpty then out := out.push name
  return out

/-- One module reaching every branch of the page that carries a class of its own:
an import list with links, a docstring, a definition with attributes and
equations, a structure with a parent, a direct field with a docstring, an
inherited field and a named constructor, and an inductive whose constructors
carry one. -/
def richModule : Module :=
  { name := "Pkg.M", schemaVersion := 5, imports := #["B.C", "A"],
    moduleDocs := #[{ line := 1, col := 0, text := "module prose" }],
    decls := #[
      { name := "Pkg.M.f", kind := "definition", modifiers := #["abbrev"],
        binders := #["(n : Nat)", "{m : Nat}"], implicits := #[false, true],
        binderCode := #[#[codeConst 5 8 "Nat"], #[]],
        ty := "Nat", typeCode := #[codeConst 0 3 "Nat"],
        line := 3, col := 0, endLine := 3, endCol := 1, index := 0,
        attrs := #[("simp", "")], equations := #["f 0 = 0"], equationCode := #[#[]],
        doc := "the definition" },
      { name := "Pkg.M.S", kind := "structure", ty := "T",
        line := 5, col := 0, endLine := 9, endCol := 0, index := 1,
        members := #[
          { label := "parent", name := "Pkg.M.S.toP", text := "P" },
          { label := "field", name := "Pkg.M.S.x", text := "Nat", doc := "a field" },
          { label := "field", name := "P.y", text := "Nat", inherited := true },
          { label := "ctor", name := "Pkg.M.S.make" }] },
      { name := "Pkg.M.C", kind := "inductive", ty := "T",
        line := 11, col := 0, endLine := 13, endCol := 0, index := 2,
        members := #[
          { label := "ctor", name := "Pkg.M.C.red", text := "C", doc := "the first one" },
          { label := "ctor", name := "Pkg.M.C.green", text := "C" }] }] }

/-- The two facts a signature cannot print, which are read through fields private
to `Litedoc4.Ir` and so arrive on the wire. -/
def flaggedModule : Module :=
  moduleFromWire 5 [declWireJson "Pkg.M.hole" "theorem" ",\"sorry\":\"direct\"",
    declWireJson "Pkg.M.ext" "theorem" ",\"generated\":[\"ext\",\"Pkg.M.S\"]"]

def renderPageOf (m : Module) : Except String String :=
  let ix := declIndex [("P.y", "Pkg.Parent"), ("Pkg.M.S", "Pkg.M")] m
  ((pageHtml ix m (suppressedOf #[m]) "https://h/o/r/blob/dead" "Pkg").run 0).map (·.1)

/-- `Litedoc4Test.GlobalEntry`'s version of this reads the four entry pages and
cannot see the renderer; this one reads a module page and cannot see those. The
classes are read off **built pages** rather than off the literals, because that
is where a class on only one branch shows up — which is why the fixture carries
an inherited field, a named constructor and a `sorry` flag.

The docstrings are plain prose on purpose. A heading or a fenced block makes
`Litedoc4.Md` emit classes of its own (`markdown-heading`, `hover-link`,
`language-…`), and those are that half's to style, not this one's. What would
falsify the choice: the stylesheet taking those names over. -/
def everyClassTheRendererEmitsIsStyled : Invariant where
  name := "every class a module page emits has a rule in style.css"
  check := do
    let mut seen := 0
    let mut missing : Array String := #[]
    for page in [renderPageOf richModule, renderPageOf flaggedModule] do
      match page with
      | .error message => return some s!"the page was refused: {message}"
      | .ok html =>
        for cls in classesIn html do
          seen := seen + 1
          if !emits styleCss ("." ++ cls) then missing := missing.push cls
    return first [
      eq missing #[],
      -- A scan that finds nothing would pass silently, checking that the empty
      -- set is a subset of anything.
      if seen > 60 then none else some s!"only {seen} class name(s) found — the scan broke"]

/-! ## Writing them -/

/-- **Unconditional and idempotent**: it overwrites whatever is at each path
rather than asking whether it differs, because a build that skips an asset
because "it was already there" leaves an *edited* or truncated file in place and
nothing downstream would notice. The edit between the two runs is what a
hand-patched deployment leaves.

The work area carries the process id: two runs of `litedoc4-test` sharing a
directory would delete each other's tree, and the failure would then read as this
invariant being false. -/
def writingTwiceLeavesTheSameBytes : Invariant where
  name := "writing the assets over an edited tree leaves the bytes the executable carries"
  check := do
    let base : FilePath := ⟨(← IO.getEnv "TMPDIR").getD "/tmp"⟩
    let dir := base / s!"litedoc4-lean-test-assets-{← IO.Process.getPID}"
    if ← dir.pathExists then IO.FS.removeDirAll dir
    writeAssets dir
    IO.FS.writeFile (dir / "style.css") "/* hand-edited */"
    writeAssets dir
    let mut wrong : Array String := #[]
    for (name, body) in assets do
      if (← IO.FS.readFile (dir / name)) != body then wrong := wrong.push name
    let written := (← dir.readDir).size
    IO.FS.removeDirAll dir
    return first [
      eq wrong #[],
      eq written assets.size]

end Litedoc4Test
