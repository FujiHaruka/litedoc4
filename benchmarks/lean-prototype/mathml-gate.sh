#!/usr/bin/env bash
#
# Converts the measurement target's math spans twice — once with the Rust half
# (math-core, reached through MathML4Lean's consumer-spans) and once with
# MathML4Lean in Lean — and fails unless the two answers agree byte for byte.
#
# This is a GATE, not a test. It needs the measurement target, a Rust toolchain,
# elan and a MathML4Lean checkout, so CI never runs it.
#
# WHY IT IS NOT IN tools/ AND NOT IN tools/gates.txt
#   That inventory covers litedoc4's own gates, and nothing litedoc4 ships
#   depends on MathML4Lean: this checks the pure-Lean replacement study beside
#   the rest of it. The day the product extractor bakes MathML, this moves to
#   tools/ and gains a row.
#
# Usage:
#     benchmarks/lean-prototype/mathml-gate.sh [target-checkout]
#
# Prerequisites:
#
#   1. The measurement target — a Lean package holding an `InformationTheory/`
#      directory. Defaults to /Users/haruka/dev/lean-projects. Read only.
#
#   2. A Rust toolchain, for consumer-spans and the math-core oracle inside it.
#
#   3. A MathML4Lean checkout as a SIBLING of this repository:
#
#          <parent>/lean-doc       <- this repository
#          <parent>/MathML4Lean    <- https://github.com/FujiHaruka/MathML4Lean
#
#      Its tools/corpus crate holds consumer-spans, which finds the spans with
#      the same md4c walk litedoc4 itself uses. Nothing in it is written to.
#
# It writes benchmarks/lean-prototype/target-spans.jsonl, which is regenerated
# on every run.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
mathml4lean=$(cd "$repo/.." && pwd)/MathML4Lean
out="$here/target-spans.jsonl"

die() {
    echo "mathml-gate: $1" >&2
    exit 1
}

given=${1:-/Users/haruka/dev/lean-projects}
target=$(cd "$given" 2>/dev/null && pwd) || die "no such directory: $given"
sources="$target/InformationTheory"
[ -d "$sources" ] || die "$target holds no InformationTheory/ directory"
[ -f "$mathml4lean/tools/corpus/Cargo.toml" ] || die "expected a MathML4Lean checkout at $mathml4lean (see the prerequisites at the top of this script)"
command -v cargo >/dev/null || die "cargo is not on PATH"
command -v lake >/dev/null || die "lake is not on PATH"

cargo build --release --manifest-path "$mathml4lean/tools/corpus/Cargo.toml"

oracle=$(awk '/^name = "math-core"$/ { getline; gsub(/[",]/, "", $3); print $3; exit }' \
    "$mathml4lean/tools/corpus/Cargo.lock")
[ -n "$oracle" ] || die "no math-core version in $mathml4lean/tools/corpus/Cargo.lock"
revision=$(git -C "$target" rev-parse HEAD 2>/dev/null || echo unrecorded)

# WHY NOT `git remote get-url origin | sed ... || echo unrecorded`
#   The `||` would bind to sed, which succeeds on empty input, so a target with
#   no origin would silently label the file with an empty string rather than
#   fall back. Capture first, then decide.
origin=$(git -C "$target" remote get-url origin 2>/dev/null || true)
if [ -n "$origin" ]; then
    label=$(printf '%s' "$origin" |
        sed -e 's#^git@github\.com:#https://github.com/#' -e 's#\.git$##')
else
    label=unrecorded
fi

"$mathml4lean/tools/corpus/target/release/consumer-spans" \
    --source "$sources" \
    --out "$out" \
    --label "$label" \
    --rev "$revision" \
    --oracle-version "$oracle" \
    --date "$(date -u +%Y-%m-%d)"

cd "$here"
lake build mathml
lake exe mathml "$out" --check

echo "mathml-gate: ok"
