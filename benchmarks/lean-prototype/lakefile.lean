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
WHICH COMPILER BUILDS THE C, AND WHY IT IS LEAN'S OWN
  `compileO`'s default is bare `cc`, the machine's system compiler. Taking it
  would require every consumer to have a C toolchain — and a Lean consumer is
  not guaranteed to: elan's toolchain compiles with its own clang against its
  own sysroot and links with its own lld against its own `lib/libc` stubs, so
  Lean itself asks for no system compiler at all
  (measured 2026-08-30 → `benchmarks/results/purelean-md4c-shim-2026-08-30.txt`).
  Windows is where that bites first, which is why MD4Lean carries the same
  shims for that platform alone.

  The one thing the toolchain does not ship is libc *headers* — the link stubs
  are there, so the symbols resolve; only the declarations are missing. That is
  what `csrc/libc` supplies, for the ten functions md4c calls and no more.
  What would falsify this: a declaration in `csrc/libc` that disagrees with the
  platform's real one is undefined behaviour no build error announces, so the
  system-compiler build is kept working and the two are compared on 422
  rendered pages.
-/
/- `-Werror=implicit-function-declaration` is the load-bearing flag, not a
tidiness one. Without it a function `csrc/libc` forgot to declare is not an
error but an implicit `int f()`, and the build is green while the call goes out
with a guessed signature. That is what happened: `strcspn` was missed, macOS
compiled it implicitly and rendered all 422 pages correctly, and only a
stricter clang on Linux said so (measured 2026-08-30 →
`benchmarks/results/purelean-bare-2026-08-30.txt`). The conformance check
cannot see this one — it compares declarations that exist and a missing
declaration is not there to compare — so the compiler has to be the one that
refuses. -/
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
