#!/usr/bin/env bash
# Does `csrc/libc` agree with the platform's real libc?
#
# `csrc/libc` hand-declares the ten libc functions md4c and `md_events.c` call,
# so that Lean's own clang — which ships no libc headers — can compile them and
# no system C toolchain is required of a consumer. A declaration that disagrees
# with the platform's real one is undefined behaviour, and the 422-page output
# comparison does not find it: a `memset` with its second and third parameters
# swapped renders every page byte-identically (measured 2026-08-30). So the
# check is the compiler's, not the output's.
#
# Needs the system compiler and its real headers, which is why this is a script
# and not part of the package's build. It is not in tools/gates.txt for the same
# reason mathml-gate.sh is not: the product does not depend on the prototype.
#
# usage: libc-shim-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || {
  echo "libc-shim-gate: no system compiler ($CC) — this check needs the real headers" >&2
  exit 2
}

# _FORTIFY_SOURCE rewrites mem* into macros on macOS, and a macro cannot be
# compared against a declaration. Turning it off is what makes the redeclaration
# visible to the compiler at all.
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

if ! "$CC" -D_FORTIFY_SOURCE=0 -c -o "$OUT/conformance.o" \
      "$HERE/csrc/libc-conformance.c" 2> "$OUT/err"; then
  echo "libc-shim-gate: csrc/libc disagrees with the platform's libc" >&2
  sed -n '1,20p' "$OUT/err" >&2
  exit 1
fi

echo "libc-shim-gate: ok — csrc/libc agrees with $($CC --version | head -1)"
