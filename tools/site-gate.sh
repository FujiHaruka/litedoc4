#!/usr/bin/env bash
# Does a generated site close over itself?
#
# There is no external oracle for these bytes — the UI is ours — so what is left
# is what the tree can be asked about itself. Neither check needs the network,
# the corpus, or doc-gen4.
#
#   check-dead-links.py    every relative href resolves to a file in the tree
#   check-site-closure.py  the module index, the search index and the pages agree
#                          about which declarations exist, in *both* directions,
#                          and nothing loads an external resource
#
# Both directions matter: an index that is a subset of the pages passes one of
# them, pages that are a subset of the index pass the other, and both are exactly
# how a renderer and an index generator drift apart.
#
# usage: site-gate.sh <site dir> [<site dir> ...]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$HERE/../benchmarks/tools"
PYTHON="${PYTHON:-python3}"

if [ $# -eq 0 ]; then
  echo "usage: site-gate.sh <site dir> [<site dir> ...]" >&2
  exit 2
fi

status=0
for site in "$@"; do
  if [ ! -d "$site" ]; then
    echo "not a directory: $site" >&2
    status=1
    continue
  fi

  echo "== dead links"
  "$PYTHON" "$TOOLS/check-dead-links.py" "$site" --paths || status=1
  echo
  echo "== closure"
  "$PYTHON" "$TOOLS/check-site-closure.py" "$site" || status=1
  echo
done

if [ "$status" -ne 0 ]; then
  echo "SITE GATE: FAILED" >&2
else
  echo "SITE GATE: ok"
fi
exit "$status"
