#!/usr/bin/env bash
# Is src/Litedoc4/Md/GcTable.lean still what UnicodeBasic answers?
#
# Two arms, because only one of them can run anywhere.
#
#   1  the emitter, from the ranges the file already holds. Needs deno and
#      nothing else. It says the generator still writes what is committed; it
#      says nothing at all about whether the ranges are still UnicodeBasic's.
#   2  the oracle. `lake env lean --load-dynlib=<UnicodeBasic>` in the target,
#      which is the only thing that can answer arm 1's question.
#
# Arm 2 is why this gate is `manual` in tools/gates.txt. UnicodeBasic reaches the
# target only as a dependency of doc-gen4, and neither is in its manifest today
# (measured 2026-08-31 →
# benchmarks/results/unicode-table-regenerators-2026-08-31.txt §3); installing
# them is a `lake update` on a Mathlib project. Arm 2 missing exits 2 rather than
# 0: a gate that reports "could not ask" as success is the shape CLAUDE.md calls
# green by skipping, and this one would wear it for months at a time.
#
# usage: gc-table-gate.sh [--target DIR]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GEN="$ROOT/tools/oracle/gen-gc-table.ts"
TABLE="$ROOT/src/Litedoc4/Md/GcTable.lean"
TARGET="/Users/haruka/dev/lean-projects"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) echo "usage: gc-table-gate.sh [--target DIR]" >&2; exit 2 ;;
  esac
done

command -v deno >/dev/null 2>&1 || {
  echo "no deno on PATH — this gate runs the table's generator." >&2
  exit 2
}
[ -f "$GEN" ] || {
  echo "missing $GEN — the tables have no generator to be checked against" >&2
  exit 1
}
[ -f "$TABLE" ] || {
  echo "missing $TABLE — the generated tables are gone, not stale" >&2
  exit 1
}

echo "== $(deno --version | head -1)"
echo "== 1/2 the emitter, over the ranges the file already holds"
deno run --allow-read "$GEN" --self-check

echo
echo "== 2/2 UnicodeBasic, through $TARGET"
UNICODE_LIB="$TARGET/.lake/packages/UnicodeBasic"
if [ ! -d "$UNICODE_LIB" ]; then
  echo "no $UNICODE_LIB — UnicodeBasic reaches a Lean package only as a" >&2
  echo "dependency of doc-gen4, and the ranges cannot be re-asked without it." >&2
  echo "Arm 1 passed, so the emitter is intact; the tables are unverified." >&2
  exit 2
fi
deno run --allow-read --allow-run --allow-env "$GEN" --check --target "$TARGET"

echo
echo "GC TABLE GATE: ok (the emitter, and UnicodeBasic agrees with both tables)"
