import Lake
open System Lake DSL

/-
WHY THIS IS `lakefile.lean` AND NOT `lakefile.toml`
  It was toml until the Markdown parser stopped being a git dependency. The C
  that md4c needs is a custom `target`, and toml has no way to spell one.
-/

package leanproto

def md4cDir : FilePath := "vendor" / "md4c"
def csrcDir : FilePath := "csrc"

/-
WHICH COMPILER BUILDS THE C, AND WHY IT IS THE MACHINE'S
  `compileO`'s default is bare `cc`, the system compiler on PATH, and that is
  what this keeps. Passing `(← getLeanCc)` instead was tried and does not
  build: Lean's bundled clang ships no libc headers, so md4c stops at
  `'stdio.h' file not found` — and so does `leanc`
  (measured 2026-08-30 → `benchmarks/results/purelean-md4c-2026-08-30.txt`).
  MD4Lean does the same thing on this platform for the same reason; its
  `adhoc_include/` shims, which declare the dozen libc functions md4c calls by
  hand, are reached only on Windows.

  So **vendoring md4c does not remove the C compiler from what a consumer
  needs.** It removes the git dependency, not the toolchain. What would
  falsify that: shims like MD4Lean's on every platform, at which point Lean's
  own clang is enough and the requirement really does go.
-/
def ccFlags (pkg : Package) : FetchM (Array String) := do
  return #["-I", (← getLeanIncludeDir).toString,
           "-I", (pkg.dir / md4cDir).toString, "-fPIC"]

target md4cObj pkg : FilePath := do
  let oFile := pkg.buildDir / "md4c.o"
  let src ← inputTextFile <| pkg.dir / md4cDir / "md4c.c"
  let flags ← ccFlags pkg
  buildFileAfterDep oFile src fun srcFile => do
    compileO oFile srcFile flags

target mdEventsObj pkg : FilePath := do
  let oFile := pkg.buildDir / "md_events.o"
  let src ← inputTextFile <| pkg.dir / csrcDir / "md_events.c"
  let flags ← ccFlags pkg
  buildFileAfterDep oFile src fun srcFile => do
    compileO oFile srcFile flags

require «MathML4Lean» from git
  "https://github.com/FujiHaruka/MathML4Lean" @ "v0.1.0"

/- A `lean_exe` root does not drag its imports in on its own, so the parser has
to be a target of its own for Lake to build it at all. -/
lean_lib Md

@[default_target]
lean_exe bench where
  root := `Main

lean_exe render where
  root := `Render
  moreLinkObjs := #[md4cObj, mdEventsObj]

lean_exe incr where
  root := `Incr

lean_exe mathml where
  root := `Mathml
