#!/usr/bin/env bash
# Does a deployed multi-version site work for a reader, as served by its real
# host? A smoke over one URL, in a browser, reading nothing but what the host
# answers — no build directory, no store, no render. Meant to run after a deploy,
# against the address the deploy published to.
#
# Five items, each printed `ok|FAIL <item>: <what>`, declared before anything
# runs; the summary is `<ran> of <declared>`:
#   live-root    the site root lands on <newest>/index.html, drawn, where <newest>
#                is the last entry of the served versions.json
#   live-module  one module page of the newest version draws, with at least one
#                declaration section: of the first 40 modules in that version's
#                module list, the one whose page file places the most declarations
#   live-search  typing the last component of a declaration on that page into the
#                top search box lists it in the dropdown, and clicking the row
#                lands on its page with that declaration :target
#   console      no console error and no page error on any page loaded
#   requests     no request failed or was answered >= 400
# Path-URL sites only: a versions.json naming a routes file (a hash-URL site)
# fails live-root by saying so.
#
# The driver is benchmarks/tools/check-mv-pages.ts --url, the same one
# tools/mv-pages-gate.sh drives over the sample's renders.
#
# Needs node, benchmarks/tools' npm packages (installed with `npm ci` when
# absent) and a Chrome; no node or no Chrome is exit 2, never a skip.
#
# usage: tools/live-smoke-gate.sh --url <site root URL> [--chrome PATH]
#   NODE      the node to run the driver with (default: node on PATH)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
NODE="${NODE:-node}"

URL=""
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --chrome) PASS+=("$1" "${2:-}"); shift 2 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -n "$URL" ] || { echo "--url is required (--help)" >&2; exit 2; }

command -v "$NODE" >/dev/null 2>&1 || {
  echo "no node on PATH; set NODE or install the one mise.toml pins (this gate drives a browser)" >&2
  exit 2
}
TOOLS="$ROOT/benchmarks/tools"
if [ ! -d "$TOOLS/node_modules/puppeteer-core" ]; then
  echo "== install (benchmarks/tools has no puppeteer-core)"
  (cd "$TOOLS" && npm ci --no-audit --no-fund) || {
    echo "npm ci in $TOOLS failed; the driver cannot load puppeteer-core" >&2
    exit 2
  }
fi

record_host
printf 'commit            %s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo '?')"
printf 'url               %s\n' "$URL"

exec "$NODE" "$TOOLS/check-mv-pages.ts" --url "$URL" ${PASS[@]+"${PASS[@]}"}
