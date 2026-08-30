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

**The list is the closure of what is called, not a subset of libc.** Ten
functions: `malloc` `realloc` `free` `qsort` `bsearch` from `stdlib.h`,
`memcpy` `memmove` `memset` `memcmp` `strchr` from `string.h`, and nothing from
`stdio.h` — md4c includes it but calls nothing from it. Adding a call to
something not declared here fails the build with the name in the message, which
is the intended way to find out.

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

**`../libc-conformance.c`, run by `../libc-shim-gate.sh`, is what guards it.**
It includes the platform's real headers and then these, and lets the compiler
compare them: a disagreement is `error: conflicting types for 'memset'` naming
the function. It needs the system compiler and its real headers, so it is a
gate and not part of the build.
