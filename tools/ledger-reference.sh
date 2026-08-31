#!/usr/bin/env bash
# Run the `detect` stage over the measurement target and record everything it
# writes: the ledgers, a touched ledger, and the check outputs of twelve
# scenarios.
#
# The target is only ever read: `touch` is what injects "module M changed".
#
# usage: tools/ledger-reference.sh [--out DIR] [--target REPO] [--ir DIR]
#
#   LITEDOC4  the binary to record (default .lake/build/bin/litedoc4). The
#             recording is the implementation's answer, so a second one taken
#             with another binary is what tools/ledger-compare.sh compares.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LITEDOC4="${LITEDOC4:-$REPO/.lake/build/bin/litedoc4}"
# shellcheck source=lib/target.sh
. "$REPO/tools/lib/target.sh" || exit 1

OUT=
TARGET="$TARGET_REPO"
IR=/private/tmp/lean-doc-relay/w7h/base-ir
MODULES="$REPO/benchmarks/results/it-modules.txt"

# The package's own 432 modules have one `.olean` each; the three-file form of the
# module system only appears in dependencies, so the three-olean case is measured
# on eight of Mathlib's real ones rather than on a synthetic tree.
MATHLIB_MODULES="Mathlib.Init
Mathlib.Logic.Basic
Mathlib.Logic.Denumerable
Mathlib.Order.Basic
Mathlib.Data.Set.Defs
Mathlib.Algebra.Group.Defs
Mathlib.Tactic.Ring.Basic
Mathlib.Topology.Basic"

# Configuration, not a fact about the target: 40 hex digits, and URL2 only has to
# differ from URL.
URL=https://github.com/FujiHaruka/information-theory/blob/573793b243fb1343636088eb62d1789ab2b14cec
URL2=https://github.com/FujiHaruka/information-theory/blob/0000000000000000000000000000000000000000

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --ir) IR="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

OUT="${OUT:-/private/tmp/lean-doc-relay/m3/rust}"

MATHLIB_TARGET="$TARGET/.lake/packages/mathlib"

for p in "$TARGET" "$IR" "$MODULES" "$MATHLIB_TARGET"; do
  [ -e "$p" ] || { echo "missing: $p" >&2; exit 1; }
done

[ -x "$LITEDOC4" ] || {
  echo "missing: $LITEDOC4 — run: tools/build-lean-exe.sh --toolchain-from e2e/micro, or set LITEDOC4" >&2; exit 1;
}
ledger () { "$LITEDOC4" ledger "$@"; }

rm -rf "$OUT"
mkdir -p "$OUT"

# Deterministic slices of the committed list, written out so the comparator can
# check that two recordings really used the same lists.
sed -n '3,432p' "$MODULES" > "$OUT/list-minus-ab.txt"
A=$(sed -n '1p' "$MODULES"); B=$(sed -n '2p' "$MODULES"); C=$(sed -n '3p' "$MODULES")
{ sed -n '1,2p' "$MODULES"; sed -n '4,432p' "$MODULES"; echo "InformationTheory.NotAModule.Ghost"; } \
  > "$OUT/list-minus-c-plus-ghost.txt"

build () { # build <name> <module list> [extra args...]
  local name="$1" list="$2"; shift 2
  ledger build --modules "$list" --out "$OUT/ledger-$name.json" \
    --timings "$OUT/ledger-$name.json.timings.json" "$@"
}
build sha256   "$MODULES"               --target "$TARGET" --ir "$IR" --source-url "$URL" --algorithm sha256
build lake     "$MODULES"               --target "$TARGET" --ir "$IR" --source-url "$URL" --algorithm lake
build minus-ab "$OUT/list-minus-ab.txt" --target "$TARGET" --ir "$IR" --source-url "$URL" --algorithm sha256
# Eight reads in flight: the ledger's bytes must not depend on the scheduling, so
# this is compared with ledger-sha256.json as well as across recordings.
build conc8    "$MODULES"               --target "$TARGET" --ir "$IR" --source-url "$URL" \
                                        --algorithm sha256 --concurrency 8
# No --ir: two keys fewer, so a later check *with* --ir exercises the other
# direction of the union rule.
build noir     "$MODULES"               --target "$TARGET"            --source-url "$URL" --algorithm sha256

printf '%s\n' "$MATHLIB_MODULES" > "$OUT/list-mathlib.txt"
build mathlib-sha256 "$OUT/list-mathlib.txt" --target "$MATHLIB_TARGET" --ir "$IR" --source-url "$URL" --algorithm sha256
build mathlib-lake   "$OUT/list-mathlib.txt" --target "$MATHLIB_TARGET" --ir "$IR" --source-url "$URL" --algorithm lake

# Applied one after the other to the same file: `touch` has to be idempotent in
# shape, not just work once.
ledger touch --ledger "$OUT/ledger-sha256.json" --module "$A" --out "$OUT/ledger-touched.json"
ledger touch --ledger "$OUT/ledger-touched.json" --module "$B" --out "$OUT/ledger-touched.json"

check () { # check <name> <ledger> [extra args...]
  local name="$1" led="$2"; shift 2
  ledger check --ledger "$led" \
    --changed-out "$OUT/$name-changed.txt" \
    --removed-out "$OUT/$name-removed.txt" \
    --render-all-out "$OUT/$name-render-all.txt" \
    --timings "$OUT/$name-timings.json" "$@" > "$OUT/$name-stdout.txt"
}

# Nothing changed at all: the answer the pipeline sees most often.
check clean       "$OUT/ledger-sha256.json"  --modules "$MODULES" --ir "$IR" --source-url "$URL"
check touched     "$OUT/ledger-touched.json" --modules "$MODULES" --ir "$IR" --source-url "$URL"
# Two modules appeared, one left the list, one is in the list with no olean.
check drift       "$OUT/ledger-minus-ab.json" --modules "$OUT/list-minus-c-plus-ghost.txt" \
                                              --ir "$IR" --source-url "$URL"
# The extract key lost two keys (no --ir): everything is re-extracted.
check extractkey  "$OUT/ledger-sha256.json"  --modules "$MODULES" --source-url "$URL"
# The render key changed value: re-render everything, re-extract nothing.
check rendervalue "$OUT/ledger-sha256.json"  --modules "$MODULES" --ir "$IR" --source-url "$URL2"
# The render key lost a key (no --source-url): the union rule, not the
# intersection one, is what makes this a change.
check renderless  "$OUT/ledger-sha256.json"  --modules "$MODULES" --ir "$IR"
# The lake algorithm reads Lake's hash instead of the olean bytes.
check lake        "$OUT/ledger-lake.json"    --modules "$MODULES" --ir "$IR" --source-url "$URL"
# No --modules: the list comes from the ledger, and nothing can be added.
check fromledger  "$OUT/ledger-sha256.json"                       --ir "$IR" --source-url "$URL"
# Modules with all three olean files, on both algorithms.
check mathlib     "$OUT/ledger-mathlib-sha256.json" --modules "$OUT/list-mathlib.txt" \
                                              --ir "$IR" --source-url "$URL"
check mathliblake "$OUT/ledger-mathlib-lake.json" --modules "$OUT/list-mathlib.txt" \
                                              --ir "$IR" --source-url "$URL"
# The extract key gained two keys (built without --ir, checked with one): the
# union rule from the other side.
check intoir      "$OUT/ledger-noir.json"    --modules "$MODULES" --ir "$IR" --source-url "$URL"
# A --source-url with a trailing slash is the same render key: the strip happens
# and nothing is re-rendered.
check slash       "$OUT/ledger-sha256.json"  --modules "$MODULES" --ir "$IR" --source-url "$URL/"

# Makes an accidental edit to the recorded tree loud.
( cd "$OUT" && find . -type f | sort | xargs shasum -a 256 ) > "$OUT.sha256"

printf 'dropped for the drift scenario: %s / %s (added), %s (removed)\n' "$A" "$B" "$C"
printf 'files: %s\n' "$(find "$OUT" -type f | wc -l | tr -d ' ')"
printf 'manifest: %s\n' "$OUT.sha256"
