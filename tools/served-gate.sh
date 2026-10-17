#!/usr/bin/env bash
# Was every version the caller declares built, and is every one of them served?
#
# Two items per declared version and one more, 2n + 1 in all, each printed as
# `ITEM <name> ok|FAIL <one line>`:
#   built-<v>    <out>/litedoc4-build.json is a finished `build --versions` record
#                whose `versions` lists <v>
#   served-<v>   <url>/versions.json lists <v>, and every file its front page is
#                drawn from answers 200: the page itself (<v>/index.html for path
#                URLs, the root index.html for hash URLs, which must embed the same
#                entry), the assets that page links, the version's data file in d/,
#                the module list and front page it names, and under hash URLs its
#                routes file. The URL mode is read from the served root page
#   undeclared   neither the build record nor versions.json names a version
#                outside the declared set
# The site half is tools/lib/served-check.py; every declared item has to report
# exactly once.
#
# usage: tools/served-gate.sh --declared <v>,<v>,... --out <build out dir> --url <site base URL>
#   --declared  the version set that has to be built and served, comma-separated
#   --out       the --out of a `litedoc4 build --versions` run
#   --url       where that run's site is served, e.g. http://127.0.0.1:8941
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DECLARED_LIST=""
OUT=""
URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --declared) DECLARED_LIST="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$DECLARED_LIST" ] || [ -z "$OUT" ] || [ -z "$URL" ]; then
  echo "--declared, --out and --url are all required (--help)" >&2
  exit 2
fi

IFS=, read -r -a VERSIONS <<<"$DECLARED_LIST"
ITEMS=()
for v in "${VERSIONS[@]}"; do
  if [ -z "$v" ]; then echo "--declared has an empty name: $DECLARED_LIST" >&2; exit 2; fi
  for seen in ${ITEMS[@]+"${ITEMS[@]}"}; do
    if [ "$seen" = "built-$v" ]; then echo "--declared names $v twice" >&2; exit 2; fi
  done
  ITEMS+=("built-$v")
done
for v in "${VERSIONS[@]}"; do ITEMS+=("served-$v"); done
ITEMS+=(undeclared)

REPORT="$(mktemp)"
ERRORS="$(mktemp)"
set +e
python3 -I "$HERE/lib/served-check.py" "$DECLARED_LIST" "$OUT" "$URL" >"$REPORT" 2>"$ERRORS"
CHECK_RC=$?
set -e
cat "$REPORT"

ran=0
failed=0
built=0
served=0
missing=""
for name in "${ITEMS[@]}"; do
  lines="$(awk -v n="$name" '$1 == "ITEM" && $2 == n { c++ } END { print c + 0 }' "$REPORT")"
  if [ "$lines" -ne 1 ]; then
    missing="$missing $name($lines)"
    continue
  fi
  ran=$((ran + 1))
  if [ "$(awk -v n="$name" '$1 == "ITEM" && $2 == n { print $3 }' "$REPORT")" = ok ]; then
    case "$name" in built-*) built=$((built + 1)) ;; served-*) served=$((served + 1)) ;; esac
  else
    failed=$((failed + 1))
  fi
done
stray="$(grep -c '^ITEM ' "$REPORT" || true)"

echo "built: $built of ${#VERSIONS[@]}"
echo "served: $served of ${#VERSIONS[@]}"
echo "items reported : $ran of ${#ITEMS[@]}"
rm -f "$REPORT"

if [ "$CHECK_RC" -ne 0 ]; then
  echo "SERVED GATE: FAILED — served-check.py exited $CHECK_RC:" >&2
  tail -n 20 "$ERRORS" >&2
  rm -f "$ERRORS"
  exit 1
fi
rm -f "$ERRORS"
if [ "$ran" -ne "${#ITEMS[@]}" ] || [ "$stray" -ne "${#ITEMS[@]}" ]; then
  echo "SERVED GATE: FAILED — $ran of ${#ITEMS[@]} items reported exactly once (not once:${missing:- none}; ITEM lines: $stray)" >&2
  exit 1
fi
if [ "$failed" -ne 0 ] || [ "$built" -ne "${#VERSIONS[@]}" ] || [ "$served" -ne "${#VERSIONS[@]}" ]; then
  echo "SERVED GATE: FAILED — built $built, served $served of ${#VERSIONS[@]} declared; $failed item(s) failed" >&2
  exit 1
fi
echo "SERVED GATE: ok"
