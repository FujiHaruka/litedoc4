#!/usr/bin/env bash
# Compare two whole sites byte for byte and say what differs.
#
# **Against a doc-gen4-era reference, dependency links differ by design**: every
# link into a dependency is that package's version-pinned GitHub blob URL
# whenever the run resolves a package root (`build` always does; `site` and
# `render` do when given `--root`), and the reference tree does not move with it.
#
# A "site" is the module pages **and** the whole-package artifacts in one tree.
# `render-compare.sh` looks at `*.html` only and `global-compare.sh` at the
# artifacts only; this compares every file of both kinds.
#
# usage: tools/site-compare.sh REFERENCE_DIR CANDIDATE_DIR [--show N]
#
# **No exception list.** A comparator that carries known divergences swallows the
# second one silently; a registered divergence is pinned in the Rust tests
# instead, where a *set* is asserted rather than skipped.
#
# The candidate comes from `litedoc4 site`:
#   URL=https://github.com/FujiHaruka/information-theory/blob/573793b243fb1343636088eb62d1789ab2b14cec
#   ./.lake/build/bin/litedoc4 site \
#     --ir /private/tmp/lean-doc-relay/w7h/base-ir --out /tmp/lean-site \
#     --source-url $URL \
#     --link-index /private/tmp/lean-doc-relay/w7c/linkindex/link-index.lidx
#   tools/site-compare.sh /private/tmp/lean-doc-relay/m2/gate/ref-site /tmp/lean-site
# Pass $URL unquoted: a `"..."` that keeps its quotes reaches the renderer as part
# of the URL and every page then differs.
#
# Pointed at a tree built with `render` and `global` run separately over one IR,
# it also answers whether composing the two adds or drops anything.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTEFACTS="$HERE/site-artefacts.txt"

SHOW=10
REF=""
CAND=""

while [ $# -gt 0 ]; do
  case "$1" in
    --show) SHOW="$2"; shift 2 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) if [ -z "$REF" ]; then REF="$1"; elif [ -z "$CAND" ]; then CAND="$1"; else
         echo "too many arguments" >&2; exit 2; fi; shift ;;
  esac
done

[ -n "$REF" ] && [ -n "$CAND" ] || { echo "usage: $0 REFERENCE_DIR CANDIDATE_DIR [--show N]" >&2; exit 2; }
[ -d "$REF" ] || { echo "no such directory: $REF" >&2; exit 1; }
[ -d "$CAND" ] || { echo "no such directory: $CAND" >&2; exit 1; }
[ -s "$ARTEFACTS" ] || { echo "no whole-package inventory at $ARTEFACTS" >&2; exit 2; }

# Every file: an extension filter would report a full site while comparing three
# quarters of one.
list() { ( cd "$1" && find . -type f | sort ); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
list "$REF" > "$tmp/ref.txt"
list "$CAND" > "$tmp/cand.txt"

# Absolute paths: `diff` is aliased to a colordiff that is not installed here,
# and its exit 127 reads as "differences found".
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

# Counted apart as well as together: the denominator is dominated by module
# pages, so the whole-package artifacts can fail inside it without moving the
# percentage that gets quoted.
#
# The names come from tools/site-artefacts.txt rather than a list here, because
# a list here is what rotted: the six doc-gen4-era names this file used to carry
# are the same six clone-gate.sh carried, five of which litedoc4 deliberately
# does not write, so the line reported `-4/6` on two identical litedoc4 sites
# (measured 2026-08-31). Absent and present are counted apart: a reference from
# another generator legitimately has none of them, and that is not the same
# answer as having them and disagreeing.
n_artefacts=0
artefacts_same=0
artefacts_bad=0
artefacts_absent=0
while IFS= read -r f; do
  n_artefacts=$(( n_artefacts + 1 ))
  if [ -f "$REF/$f" ] && [ -f "$CAND/$f" ]; then
    if cmp -s "$REF/$f" "$CAND/$f"; then
      artefacts_same=$(( artefacts_same + 1 ))
    else
      artefacts_bad=$(( artefacts_bad + 1 ))
    fi
  else
    artefacts_absent=$(( artefacts_absent + 1 ))
  fi
done < <(grep -v '^[[:space:]]*#' "$ARTEFACTS" | grep .)

echo "reference : $n_ref files ($REF)"
echo "candidate : $n_cand files ($CAND)"
echo "identical : $n_same"
echo "differing : $n_differ"
echo "missing   : $n_missing (in reference, not in candidate)"
echo "extra     : $n_extra (in candidate, not in reference)"
echo "artifacts : $artefacts_same/$n_artefacts named in tools/site-artefacts.txt identical, $artefacts_bad differing, $artefacts_absent absent from one side or both"

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
  echo "--- differing (all $n_differ, with size delta and first differing byte)"
  while IFS= read -r f; do
    a=$(wc -c < "$REF/$f" | tr -d ' ')
    b=$(wc -c < "$CAND/$f" | tr -d ' ')
    where=$(cmp "$REF/$f" "$CAND/$f" 2>&1 | head -1)
    printf '%s\n    reference %s B, candidate %s B\n    %s\n' "$f" "$a" "$b" "$where"
  done < "$tmp/differ.txt"
fi

if [ "$n_differ" -eq 0 ] && [ "$n_missing" -eq 0 ] && [ "$n_extra" -eq 0 ]; then
  echo
  echo "IDENTICAL"
  exit 0
fi
exit 1
