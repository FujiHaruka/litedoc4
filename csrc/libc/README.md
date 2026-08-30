# Hand-written libc declarations

Lean's toolchain ships compiler headers (`stddef.h`, `stdint.h`, `limits.h`,
`stdbool.h`, `stdatomic.h`, `stdnoreturn.h`, …) and libc **link stubs**
(`lib/libc/libSystem.tbd`), but no libc **headers**. So `#include <stdlib.h>`
fails while the symbols it would have declared link fine.

These three headers close that gap for exactly the functions this package's C
calls, so that Lean's own compiler is enough and **no system C toolchain is
required of a consumer**. That matters because Lean asks for none either: elan's
toolchain compiles against its own sysroot and links with its own lld. MD4Lean
solves the same problem the same way; its shims are reached only on Windows,
these on every platform.

**The list is the closure of what is called, not a subset of libc.** Eleven
functions: `malloc` `realloc` `free` `qsort` `bsearch` from `stdlib.h`,
`memcpy` `memmove` `memset` `memcmp` `strchr` `strcspn` from `string.h`, and
nothing from `stdio.h` — md4c includes it but calls nothing from it. Its `exit`
sits under `#ifdef DEBUG` and its `sprintf` under `#if 0`; `strchr` arrives as
`#define md_strchr strchr`, which is why reading the source for call sites is
not enough on its own.

`-Werror=implicit-function-declaration` in `lakefile.lean` is what makes a
missing one fail rather than compile. It is not decoration: `strcspn` was
missed at first, and **macOS built and rendered all 422 pages correctly anyway**
because its clang knows `strcspn` as a builtin and used the right prototype
without being told. Linux's clang refused. A compiler that does neither would
have called it as an implicit `int strcspn()` — which is the case the flag
exists for.

## The risk, and what actually checks it

A declaration that disagrees with the platform's real one is undefined
behaviour that no build error announces.

**The 422-page output comparison does not find it.** That was tried:
declaring `memset` as `(void *, size_t, int)` — second and third parameters
swapped — compiles, renders, and produces all 422 pages byte-identical, because
the call sites pass 0 and the length in the same two registers either way
(measured 2026-08-30 on arm64 macOS →
`benchmarks/results/purelean-md4c-shim-2026-08-30.txt`). A declaration can be
wrong in a way no output reveals, so the output cannot be what guards it.
The missing `strcspn` is the same lesson from the other side: 422 correct pages
on one platform, a build failure on another
(→ `benchmarks/results/purelean-bare-2026-08-30.txt`).

**`../libc-conformance.c`, run by `tools/libc-shim-gate.sh`, is what guards it.**
It includes the platform's real headers and then these, and lets the compiler
compare them: a disagreement is `error: conflicting types for 'memset'` naming
the function. It needs the system compiler and its real headers, so it is a
gate and not part of the build.
