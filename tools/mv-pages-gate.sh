#!/usr/bin/env bash
# The page-path and anchor promise of a multi-version site, checked as a reader
# meets it (docs/multiversion/plan.md, D9): in a browser, after each page has
# been drawn from data, over the two renders `tools/mv-s-gate.sh --keep` leaves
# of the four-version sample S — path URLs and hash URLs.
#
# It replaces the byte comparison against e2e/micro-expected/, whose pages were
# minted by an implementation that left the tree and must never be re-minted
# from this output. Every item prints `ok|FAIL <item>: <what>`; the items are
# declared before anything runs, and the summary is `<ran> of <declared>`.
#
# The frozen arm (S v1 only), one-directional by necessity:
#   frozen-shells    every page path of e2e/micro-expected/build/ has a shell at
#                    v1/<same path>. 404.html is the exception: a host serves one
#                    404 page for the whole site, so it sits at the site root and
#                    is judged by the old-link items, not here
#   frozen-ids/<p>   every element id of frozen page <p> is on v1/<p> once drawn.
#                    Extra ids are counted and printed, never failed: the frozen
#                    pages can never be re-minted, so a declaration the sample
#                    gains must not turn the gate red. search.html is left out
#                    of this arm by name: build's own script removes its
#                    `search-results` at run time, the frozen site carries no
#                    script to run that rule with, and copying the rule here
#                    would be a second implementation of it. Its shell is still
#                    in frozen-shells and its links in the arms below
# Self-consistency, every version, both URL modes (path-* and hash-*):
#   drawn            every shell (path) or route (hash) draws
#   hrefs / routes   every intra-site href on every drawn page, with every
#                    <details> opened, names a file the render wrote (path) or a
#                    route the draw code accepts and draws (hash)
#   anchors          every href carrying an anchor names an id on its target
#                    page once that page is drawn
#   names            every own name a page file lists names a page of that
#                    version, and an id on it where it names one
#   on-demand        opening the tree, Imports, Used by and instances drew links,
#                    so their links were in the two items above
# Arrival:
#   path-arrival     a #name URL from outside sets :target on that element
#   hash-arrival     a route naming a declaration marks it .targeted
#   path-root / hash-root          the site root draws the newest version
#   path-old-link / hash-old-link  a page path without a version, answered 404
#                                  by the host, lands on the newest version's
#                                  page with the declaration targeted
# Across the run:
#   console          no console error and no page error, except the browser's
#                    own line for each old link's 404, which is that answer
#   requests         no request failed or was answered >= 400, except the two
#                    old links, whose 404 the old-link items require
#
# Needs deno and a Chrome; no Chrome is exit 2, never a skip.
#
# usage: tools/mv-pages-gate.sh [--from DIR] [--site DIR] [--hash DIR] [--frozen DIR]
#                               [--chrome PATH] [--port N]
#   --from    tools/mv-s-gate.sh's kept work directory
#             (default: /private/tmp/lean-doc-relay/mv-s-gate); the renders are
#             its run1/render/all-1 and run1/render/hash-1
#   --site / --hash   the path-URL and hash-URL renders, instead of --from's
#   --frozen  default: e2e/micro-expected/build
#   --port    the path-URL site's port (default 8930); the hash-URL site is the next
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
DENO="${DENO:-deno}"

FROM=/private/tmp/lean-doc-relay/mv-s-gate
SITE=""
HASH=""
FROZEN="$ROOT/e2e/micro-expected/build"
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --site) SITE="$2"; shift 2 ;;
    --hash) HASH="$2"; shift 2 ;;
    --frozen) FROZEN="$2"; shift 2 ;;
    --chrome|--port) PASS+=("$1" "$2"); shift 2 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
SITE="${SITE:-$FROM/run1/render/all-1}"
HASH="${HASH:-$FROM/run1/render/hash-1}"

command -v "$DENO" >/dev/null 2>&1 || {
  echo "no deno on PATH; set DENO or install it (this gate drives a browser)" >&2
  exit 2
}
for dir in "$SITE" "$HASH" "$FROZEN"; do
  [ -f "$dir/index.html" ] || {
    echo "no site at $dir; tools/mv-s-gate.sh --keep leaves the two renders" >&2
    exit 2
  }
done

record_host
printf 'commit            %s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo '?')"
printf 'renders           %s, %s\n' "$SITE" "$HASH"

exec "$DENO" run --allow-read --allow-net --allow-env --allow-run --allow-write \
  "$ROOT/benchmarks/tools/check-mv-pages.ts" \
  --site "$SITE" --hash "$HASH" --frozen "$FROZEN" ${PASS[@]+"${PASS[@]}"}
