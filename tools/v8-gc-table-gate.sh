#!/usr/bin/env bash
# Is src/Litedoc4/Global/V8GcTable.lean still what V8 answers?
#
# The table is the only one of the five enumerated Unicode tables in src/ whose
# oracle survives the removal of crates/: deno's own /[\p{Z}\p{C}]/u re-derives
# it with no target, no Mathlib and no Rust (measured 2026-08-31 →
# benchmarks/results/unicode-table-regenerators-2026-08-31.txt §1). The other
# four cannot be asked here — UnicodeBasic is not installed, and lowerTable /
# sigmaTable have no live oracle at all — so this gate deliberately watches one
# table rather than the category.
#
# It exists because the generator's --check was already red and had been for a
# week without anyone noticing: nothing ran it (§2 of the same log). A generator
# with a --check nobody runs is a generator whose output has no oracle.
#
# A gate rather than a test because it needs deno, which `cargo test --workspace`
# must not.
#
# usage: v8-gc-table-gate.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GEN="$ROOT/tools/oracle/gen-v8-gc-table.ts"
TABLE="$ROOT/src/Litedoc4/Global/V8GcTable.lean"

command -v deno >/dev/null 2>&1 || {
  echo "no deno on PATH — this gate re-derives the table from V8." >&2
  exit 2
}

[ -f "$GEN" ] || {
  echo "missing $GEN — the table has no generator to be checked against" >&2
  exit 1
}
# Said out loud rather than assumed: --check reports a missing file too, but a
# gate whose subject has been deleted should not be reporting it as a table that
# moved.
[ -f "$TABLE" ] || {
  echo "missing $TABLE — the generated table is gone, not stale" >&2
  exit 1
}

echo "== $(deno --version | head -1)"
deno run --allow-read "$GEN" --check

echo
echo "V8 GC TABLE GATE: ok ($(basename "$TABLE") is what this deno's V8 answers)"
