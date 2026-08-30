#!/usr/bin/env bash
# Does `csrc/libc` agree with the platform's real libc?
#
# `csrc/libc` hand-declares the eleven libc functions md4c and `md_events.c`
# call, so that Lean's own clang — which ships no libc headers — can compile them
# and no system C toolchain is required of a consumer. A declaration that
# disagrees with the platform's real one is undefined behaviour, and the
# 422-page output comparison does not find it: a `memset` with its second and
# third parameters swapped renders every page byte-identically (measured
# 2026-08-30 → `benchmarks/results/purelean-md4c-shim-2026-08-30.txt`). So the
# check is the compiler's, not the output's.
#
# This is the inverse of the build. `tools/purelean-gate.sh` asserts the package
# is compiled by the toolchain's clang and *not* by the machine's; this one needs
# the machine's compiler and its real headers, which is the whole point — they
# are the reference `csrc/libc` is compared against.
#
# usage: libc-shim-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || {
  echo "libc-shim-gate: no system compiler ($CC) — this check needs the real headers" >&2
  exit 2
}

OUT="$(mktemp -d)"
cleanup () {
  # `if`, not `&&`: the exit code of the last command in an EXIT trap becomes
  # the script's, and `[ -d ... ] && rm` returns 1 when the directory is gone.
  if [ -d "$OUT" ]; then
    rm -rf "$OUT"
  fi
}
trap cleanup EXIT

# _FORTIFY_SOURCE rewrites mem* into macros on macOS, and a macro cannot be
# compared against a declaration. Turning it off is what makes the redeclaration
# visible to the compiler at all.
if ! "$CC" -D_FORTIFY_SOURCE=0 -c -o "$OUT/conformance.o" \
      "$ROOT/csrc/libc-conformance.c" 2> "$OUT/err"; then
  echo "libc-shim-gate: csrc/libc disagrees with the platform's libc" >&2
  sed -n '1,20p' "$OUT/err" >&2
  exit 1
fi

echo "libc-shim-gate: ok — csrc/libc agrees with $($CC --version | head -1)"
