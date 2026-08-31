/-
# litedoc4 as a Lake package

A consumer requires this package and gets a `docs` script:

```lean
require «litedoc4» from git "https://github.com/FujiHaruka/litedoc4" @ "v1.3.0"
```

Pin `v1.3.0` or later: it is the first tag a machine with only elan on it can
use, and 1.x does not move the names your own files contain. If your package
sits below its repository root, `v1.0.1` is the oldest whose source links point
at it. `@ "main"` also works and moves.

```
lake run docs -- --out ../mypkg-docs
```

Two things that are otherwise the consumer's problem are structurally solved by
being a dependency rather than a checkout:

* the **extractor** (`extractor/Extract.lean`, 171 MB when built) is built by
  Lake against the *root* package's toolchain, so it cannot be built against the
  wrong Lean and nobody has to pass `--extractor-bin`;
* **`--lib`** is read out of the elaborated workspace.
  `crates/litedoc4/src/lakefile.rs` refuses a `lakefile.lean` by name — reading
  one honestly means elaborating it with Lake — and this script *is* that
  elaboration. Mathlib and doc-gen4 are both `lakefile.lean` packages.

Everything a consumer runs is built by Lake from this tree: `lean_exe extract`
against the root package's toolchain, and `lean_exe litedoc4` from `src/`, linked
against the C in `vendor/md4c` and `csrc/`. There is nothing to download and no
second toolchain to install — the `require` above is the whole installation.

## There is deliberately no `lean-toolchain` next to this file

**Not an oversight. Do not add one** (measured 2026-08-18,
`benchmarks/results/lake-package-probe-2026-08-18.txt` §1).

`lake update` in the *consumer* compares every dependency's `lean-toolchain`
against the root's and **rewrites the root's** when a dependency names a higher
version — *before* elan tries to fetch that version, so the consumer's file is
rewritten whether or not the version exists. A dependency naming a *lower*
version is ignored with **no warning at all**, so a stale toolchain here would be
invisible to everyone. With no file at all, `Workspace.updateToolchain` skips
litedoc4 entirely (`ToolchainVer.ofDir?` returns `none`) and the root's toolchain
builds the extractor, which is what is wanted.

The price is that `lake` cannot run in *this* directory (elan has no toolchain
to pick here), so the `lake-manifest.json` beside this file is written by hand
and this package is only ever built from a consumer's workspace.
-/
import Lake
open Lake DSL

open System (FilePath)

package «litedoc4»

/-- The LaTeX-to-MathML converter the renderer's math spans go through. A
dependency and not a vendored copy: it is a library with a corpus and a gate of
its own, and a copy here would be a second place to fix a symbol table.

Pinned to a tag, and to one whose `lean-toolchain` is the *lowest* it claims:
`lake update` in a consumer rewrites the consumer's `lean-toolchain` when a
dependency names a higher version (`benchmarks/results/lake-package-probe-2026-08-18.txt`
§1), so a dependency that moved ahead would move the consumer with it. -/
require «MathML4Lean» from git
  "https://github.com/FujiHaruka/MathML4Lean" @ "v0.1.1"

/--
`supportInterpreter := true` is how Lake spells the `-rdynamic` that
`extractor/build.sh` passes to `leanc`: `importModules (loadExts := true)` runs
module initializers through the Lean interpreter, which resolves symbols in the
running executable.

The two builds do **not** produce the same bytes (Lake adds a package symbol
prefix and compiles the generated C with `-O3 -DNDEBUG`; +308,032 B (measured)) but
they write **byte-identical IR**, which is what `tools/lake-package-gate.sh`
re-checks on every run.
-/
lean_exe extract where
  root := `Extract
  srcDir := "extractor"
  supportInterpreter := true

def md4cDir : FilePath := "vendor" / "md4c"
def csrcDir : FilePath := "csrc"

/--
`compileO`'s default compiler is a bare `cc`, the machine's own. Taking it would
require every consumer to have a C toolchain, and a Lean consumer is not
guaranteed to: elan's toolchain compiles with its own clang against its own
sysroot and links with its own lld against its own `lib/libc` stubs, so Lean
itself asks for no system compiler at all (measured 2026-08-30 →
`benchmarks/results/purelean-md4c-shim-2026-08-30.txt`). What the toolchain does
not ship is libc *headers* — the link stubs are there, so the symbols resolve;
only the declarations are missing, and `csrc/libc` supplies them for the eleven
functions this C calls and no more.

`-Werror=implicit-function-declaration` is load-bearing and not tidiness.
Without it a function `csrc/libc` forgot to declare is an implicit `int f()`
rather than an error, and the build is green while the call goes out with a
guessed signature. That is what happened: `strcspn` was missed, macOS compiled
it implicitly and rendered all 422 pages correctly, and only a stricter clang on
Linux said so (measured 2026-08-30 →
`benchmarks/results/purelean-bare-2026-08-30.txt`). `tools/libc-shim-gate.sh`
cannot see that one — it compares declarations that exist, and a missing
declaration is not there to compare — so the compiler has to be what refuses.
-/
def ccFlags (pkg : Package) (shim : Bool) : FetchM (Array String) := do
  let base := #["-I", (← getLeanIncludeDir).toString,
                "-I", (pkg.dir / md4cDir).toString, "-fPIC",
                "-Werror=implicit-function-declaration"]
  if shim then
    return base ++ #["-I", ((← getLeanIncludeDir) / "clang").toString,
                     "-I", (pkg.dir / csrcDir / "libc").toString]
  else
    return base

/-- `LITEDOC4_SYSTEM_CC=1` builds the C with the machine's compiler and its real
libc headers instead. It exists so the two can be compared: it is the control
arm for `csrc/libc`, not a fallback, and nothing selects it automatically. -/
def useSystemCc : IO Bool := do
  return (← IO.getEnv "LITEDOC4_SYSTEM_CC").isSome

def compileC (pkg : Package) (oName srcPath : FilePath) : FetchM (Job FilePath) := do
  let oFile := pkg.buildDir / oName
  let src ← inputTextFile <| pkg.dir / srcPath
  let system ← useSystemCc
  let flags ← ccFlags pkg (shim := !system)
  let cc : FilePath ← if system then pure ⟨"cc"⟩ else getLeanCc
  buildFileAfterDep oFile src fun srcFile => do
    compileO oFile srcFile flags cc

target md4cObj pkg : FilePath :=
  compileC pkg "md4c.o" (md4cDir / "md4c.c")

target mdEventsObj pkg : FilePath :=
  compileC pkg "md_events.o" (csrcDir / "md_events.c")

lean_lib Litedoc4 where
  srcDir := "src"

/-- Deliberately **not** `supportInterpreter`, and deliberately importing no
`Lean`: an executable that imports `Lean` measures 226 MB against 5.3 MB for one
that stops at `Std` (measured 2026-08-30 →
`benchmarks/results/purelean-ci-probe-2026-08-30.txt`), and this is the half a
consumer builds on every checkout. `extract` above pays that cost because it
reads oleans; nothing here does. -/
lean_exe litedoc4 where
  root := `Litedoc4.Main
  srcDir := "src"
  moreLinkObjs := #[md4cObj, mdEventsObj]

/-- The tests, and a target a consumer never reaches: `require «litedoc4»`
builds `lean_lib Litedoc4` and `lean_exe litedoc4`, and nothing under either
imports `Litedoc4Test`. Building this executable elaborates the `#guard`s in the
modules it imports and running it answers the invariants that need the linked C,
so one target is both halves.

Not `@[test_driver]`, which would be inert: `lake test` runs the **root**
package's driver (`Lake/CLI/Main.lean`, `ws.root.test`) and this package can
never be a root — there is no `lean-toolchain` beside this file. A workspace that
requires litedoc4 can name a dependency's driver, but **only the library**:
`testDriver = "litedoc4/Litedoc4Test"` resolves and `"litedoc4/litedoc4-test"`
does not, because Lake resolves the part after the slash with `String.toName`,
and `"litedoc4-test".toName` is `[anonymous]` — a hyphen is not an identifier
character, so the name is discarded rather than rejected (measured 2026-08-31
-> benchmarks/results/lean-test-scaffolding-2026-08-31.txt). Naming the library
would elaborate the `#guard`s and never run the
executable, which is the other half of the suite, so `tools/lean-test-gate.sh`
builds and runs the executable instead.
-/
lean_lib Litedoc4Test where
  srcDir := "test"

lean_exe «litedoc4-test» where
  root := `Litedoc4Test.Main
  srcDir := "test"
  moreLinkObjs := #[md4cObj, mdEventsObj]

/-- Everything else `litedoc4 build` offers is deliberately not plumbed through:
this script fills in the three flags a consumer cannot know. -/
structure DocsOptions where
  out : Option String := none
  jobs : Option String := none
  sourceUrl : Option String := none
  help : Bool := false
  deriving Inhabited

def docsUsage : String :=
"usage: lake run docs -- --out <dir> [--jobs <n>] [--source-url <url>]

  --out         where the documentation goes. Required, with no default: `litedoc4
                build` refuses an --out inside the package it documents, so no
                path inside this workspace would be right. A relative path is
                resolved against the package directory — `lake` only runs where
                the lakefile is — so `--out docs` is refused and `--out ../docs`
                is the shortest spelling that works.
  --jobs        extractor threads (default 1)
  --source-url  https://host/owner/repo/blob/<40-hex-rev>; read from the
                package's git HEAD when left out"

/-- An unknown flag is an error rather than something skipped: a `docs` run that
quietly ignored `--source-url` would link a site to the wrong revision. -/
def parseDocsArgs : List String → DocsOptions → Except String DocsOptions
  | [], acc => .ok acc
  | "--help" :: _, acc => .ok {acc with help := true}
  | "-h" :: _, acc => .ok {acc with help := true}
  | "--out" :: value :: rest, acc => parseDocsArgs rest {acc with out := some value}
  | "--jobs" :: value :: rest, acc => parseDocsArgs rest {acc with jobs := some value}
  | "--source-url" :: value :: rest, acc => parseDocsArgs rest {acc with sourceUrl := some value}
  -- Spelled out one by one rather than as a catch-all `[flag]`: a trailing
  -- `--nope` matches any one-element pattern, so it would be told to pass a value.
  | ["--out"], _ => .error "--out needs a value"
  | ["--jobs"], _ => .error "--jobs needs a value"
  | ["--source-url"], _ => .error "--source-url needs a value"
  | flag :: _, _ => .error s!"unknown argument `{flag}`"

/--
Generate this package's documentation.

Fills in the three flags of `litedoc4 build` a consumer cannot supply by hand —
`--root`, `--lib` (out of the elaborated workspace) and `--extractor-bin` (the
executable Lake just built) — and passes the rest through.
-/
script docs (args) do
  -- `lake run docs -- --out X` hands the `--` to the script as an argument; Lake
  -- does not strip it (measured 2026-08-18). Both spellings have to work.
  let args := match args with
    | "--" :: rest => rest
    | other => other
  let opts ← match parseDocsArgs args {} with
    | .ok opts => pure opts
    | .error message =>
      IO.eprintln s!"lake run docs: {message}"
      IO.eprintln docsUsage
      return 2
  if opts.help then
    IO.println docsUsage
    return 0
  let some outRaw := opts.out
    | IO.eprintln "lake run docs: --out <dir> is required and has no default: `litedoc4 build` \
        refuses an --out inside the package it documents (crates/litedoc4/src/build.rs), so no \
        path inside this workspace would be right."
      IO.eprintln docsUsage
      return 2

  let ws ← getWorkspace
  let root := ws.root

  -- `--lib` names a *library root* (`<Name>.lean` and `<Name>/`), i.e.
  -- `LeanLib.roots` rather than the library's name: they differ whenever a lakefile
  -- sets `roots` explicitly. Every library of the root package is documented;
  -- `defaultTargets` answers a different question and may name executables.
  let libs := root.leanLibs.foldl (fun acc lib => acc ++ lib.roots) #[]
  if libs.isEmpty then
    IO.eprintln s!"lake run docs: {root.prettyName} declares no `lean_lib`, so there is nothing to \
      document. This script fills in `litedoc4 build --lib` from the workspace, and the \
      workspace has no library root to name."
    return 3

  -- The package being documented has to be built first: the `runBuild` below
  -- builds the *extractor* and nothing else, and an extractor run against an
  -- unbuilt package dies with "No directory 'Example' … in the search path" (measured).
  for lib in root.leanLibs do
    let _ ← runBuild lib.fetch

  -- Build both executables **without running them**: `Lake.exe`'s first half
  -- (`Lake/CLI/Actions.lean:23-29`) with the `env` call dropped. A `lake build`
  -- subprocess would re-read the workspace this script already holds and report
  -- failures as a shell exit code instead of as Lake's own build log.
  let extractBin ← runBuild extract.fetch
  let litedoc4Bin ← runBuild litedoc4.fetch

  -- Resolved here rather than handed over relative: `litedoc4 build` refuses an
  -- `--out` under `--root` and resolves a relative path against *its own* working
  -- directory. Printing the absolute path below makes a surprise visible.
  let cwd ← IO.currentDir
  let outDir : FilePath := if (FilePath.mk outRaw).isAbsolute then outRaw else cwd / outRaw

  -- The toolchain's own `lake`, not the name `lake` on PATH: `litedoc4` looks for
  -- the `lean` that answers `--githash` as its **sibling**.
  let lake := (← getLakeEnv).lake.lake

  let mut cmdArgs := #[
    "build",
    "--root", root.dir.toString,
    "--out", outDir.toString,
    "--extractor-bin", extractBin.toString,
    "--lake", lake.toString]
  for lib in libs do
    cmdArgs := cmdArgs ++ #["--lib", lib.toString]
  if let some jobs := opts.jobs then
    cmdArgs := cmdArgs ++ #["--jobs", jobs]
  if let some url := opts.sourceUrl then
    cmdArgs := cmdArgs ++ #["--source-url", url]

  IO.println s!"litedoc4: {litedoc4Bin} {String.intercalate " " cmdArgs.toList}"
  -- No augmented environment: `lake run` does not put `LEAN_PATH` in the script's
  -- environment (measured) and `litedoc4 build` does not want one — it runs `lake env`
  -- inside `--root` itself for every extraction. That is what `--lake` is for.
  let child ← IO.Process.spawn {cmd := litedoc4Bin.toString, args := cmdArgs}
  child.wait
