#!/usr/bin/env bash
# Compare two rendered page trees byte for byte and say what differs.
#
# **Against a doc-gen4-era reference, dependency links differ by design**: every
# link into a dependency is that package's version-pinned GitHub blob URL
# whenever the run resolves a package root (`build` always does; `site` and
# `render` do when given `--root`).
#
# It fails loudly and specifically — which files are missing, which are extra,
# and where the first differing byte is. A percentage is not useful; a path and
# an offset are.
#
# usage: tools/render-compare.sh REFERENCE_DIR CANDIDATE_DIR [--show N] [--all]
#
#   --all  compare every file, not only `*.html`. A whole site carries JSON and
#          one binary index alongside its pages, and a comparison that saw only
#          the pages would call two sites identical while their search indexes
#          disagreed.
#
# Both trees are arguments and neither's provenance is checked, so point
# REFERENCE_DIR at whatever tree you want to hold the candidate to — and say
# which one it was.
#
# The candidate comes from `litedoc4 render`:
#   tools/build-lean-exe.sh --toolchain-from e2e/micro && \
#   ./.lake/build/bin/litedoc4 render \
#     --ir /private/tmp/lean-doc-relay/w7h/base-ir --pages /tmp/lean-pages \
#     --source-url "$URL" --link-index /private/tmp/lean-doc-relay/w7c/linkindex/link-index.lidx
#
# `cargo test -p litedoc4-render --test pages` makes the same comparison in
# process against a committed fixture, and pins the one page where md4c disagrees
# so that a second divergence fails.

set -uo pipefail

SHOW=10
ALL=0
REF=""
CAND=""

while [ $# -gt 0 ]; do
  case "$1" in
    --show) SHOW="$2"; shift 2 ;;
    --all) ALL=1; shift ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) if [ -z "$REF" ]; then REF="$1"; elif [ -z "$CAND" ]; then CAND="$1"; else
         echo "too many arguments" >&2; exit 2; fi; shift ;;
  esac
done

[ -n "$REF" ] && [ -n "$CAND" ] || { echo "usage: $0 REFERENCE_DIR CANDIDATE_DIR [--show N] [--all]" >&2; exit 2; }
[ -d "$REF" ] || { echo "no such directory: $REF" >&2; exit 1; }
[ -d "$CAND" ] || { echo "no such directory: $CAND" >&2; exit 1; }

list() {
  if [ "$ALL" -eq 1 ]; then ( cd "$1" && find . -type f | sort )
  else ( cd "$1" && find . -type f -name '*.html' | sort ); fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
list "$REF" > "$tmp/ref.txt"
list "$CAND" > "$tmp/cand.txt"

# Absolute paths: `diff` is aliased to a colordiff that is not installed here.
/usr/bin/comm -23 "$tmp/ref.txt" "$tmp/cand.txt" > "$tmp/missing.txt"
/usr/bin/comm -13 "$tmp/ref.txt" "$tmp/cand.txt" > "$tmp/extra.txt"
/usr/bin/comm -12 "$tmp/ref.txt" "$tmp/cand.txt" > "$tmp/common.txt"

: > "$tmp/differ.txt"
while IFS= read -r f; do
  cmp -s "$REF/$f" "$CAND/$f" || printf '%s\n' "$f" >> "$tmp/differ.txt"
done < "$tmp/common.txt"

n_ref=$(wc -l < "$tmp/ref.txt" | tr -d ' ')
n_cand=$(wc -l < "$tmp/cand.txt" | tr -d ' ')
n_missing=$(wc -l < "$tmp/missing.txt" | tr -d ' ')
n_extra=$(wc -l < "$tmp/extra.txt" | tr -d ' ')
n_common=$(wc -l < "$tmp/common.txt" | tr -d ' ')
n_differ=$(wc -l < "$tmp/differ.txt" | tr -d ' ')
n_same=$(( n_common - n_differ ))

echo "reference : $n_ref files ($REF)"
echo "candidate : $n_cand files ($CAND)"
echo "identical : $n_same"
echo "differing : $n_differ"
echo "missing   : $n_missing (in reference, not in candidate)"
echo "extra     : $n_extra (in candidate, not in reference)"

show_list() {
  local title="$1" file="$2"
  [ -s "$file" ] || return 0
  echo
  echo "--- $title (first $SHOW)"
  head -n "$SHOW" "$file"
}

show_list "missing" "$tmp/missing.txt"
show_list "extra" "$tmp/extra.txt"

if [ -s "$tmp/differ.txt" ]; then
  echo
  echo "--- differing (first $SHOW, with size delta and first differing byte)"
  head -n "$SHOW" "$tmp/differ.txt" | while IFS= read -r f; do
    a=$(wc -c < "$REF/$f" | tr -d ' ')
    b=$(wc -c < "$CAND/$f" | tr -d ' ')
    where=$(cmp "$REF/$f" "$CAND/$f" 2>&1 | head -1)
    printf '%s\n    reference %s B, candidate %s B\n    %s\n' "$f" "$a" "$b" "$where"
  done
fi

if [ "$n_differ" -eq 0 ] && [ "$n_missing" -eq 0 ] && [ "$n_extra" -eq 0 ]; then
  echo
  echo "IDENTICAL"
  exit 0
fi
exit 1
