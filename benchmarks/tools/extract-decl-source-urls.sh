#!/bin/bash
# Build an offline oracle: (declaration name -> version-pinned source URL)
# straight out of doc-gen4's own reference tree.
#
# doc-gen4 emits the blob URL on each declaration's `gh_link` div, so the whole
# dependency closure can be checked without touching the network.
#
# Usage: benchmarks/tools/extract-decl-source-urls.sh [out.tsv]
# Output: one `<name>\t<url>` per line, sorted.
#
# **What the counts below do and do not say.** They compare `decl` divs that
# carry a source link against `decl` divs in total, so they can only report on
# declarations doc-gen4 wrote a div for. They are silent about declarations it
# rendered inside a parent's div (structure fields and constructors) and about
# declarations it left off a page altogether — both exist【実測】. So this is
# not a coverage number for the oracle; it is a check that no div was mined
# without its link. Do not quote it as "every declaration has a source link".
set -u

TARGET=${TARGET:-/Users/haruka/dev/lean-projects}
TREE=${TREE:-$TARGET/.lake/build/doc}
OUT=${1:-/tmp/decl-source-urls.tsv}

[ -d "$TREE" ] || { echo "no doc-gen4 reference tree at $TREE" >&2; exit 1; }

pages=$(find "$TREE" -name '*.html' | wc -l | tr -d ' ')
echo "pages: $pages"

rg --no-filename -o \
   '<div class="decl" id="[^"]+"><div class="[^"]*"><div class="gh_link"><a href="[^"]+"' \
   "$TREE" -g '*.html' \
  | sed -E 's|<div class="decl" id="([^"]+)"><div class="[^"]*"><div class="gh_link"><a href="([^"]+)"|\1\t\2|' \
  | sort -u > "$OUT"

linked=$(wc -l < "$OUT" | tr -d ' ')
total=$(rg --no-filename -o -c '<div class="decl" id="[^"]+"' "$TREE" -g '*.html' \
        | awk '{s+=$1} END {print s}')

echo "declarations with a source link: $linked"
echo "declaration divs in total       : $total"
echo "out: $OUT"
