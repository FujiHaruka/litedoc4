#!/usr/bin/env bash
# Does the site *work*? — the half of M8 the static checks cannot see.
#
# `tools/site-gate.sh` reads the bytes and can prove they are consistent. It
# cannot tell whether the module tree draws, whether search returns anything,
# whether Instances For fills in, or whether the layout survives a 375 px
# viewport — and since M8-c all of those are decided at runtime, from
# `modules.json`, `search-index.bin` and `instances.json`, by `app.js`.
#
# This also closes gate UI-3: the CSS was written for a 375 px mobile width,
# but nobody had looked at a real browser to confirm it renders that way.
#
# Needs deno and a Chrome (or Chromium) on the machine. `benchmarks/tools/
# check-site-browser.ts` explains why puppeteer-core and a local HTTP server
# rather than puppeteer and file://.
#
# usage: browser-gate.sh <site dir> [--chrome PATH] [--port N] [--json FILE]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../benchmarks/tools/check-site-browser.ts"
DENO="${DENO:-deno}"

if [ $# -eq 0 ]; then
  echo "usage: browser-gate.sh <site dir> [--chrome PATH] [--port N] [--json FILE]" >&2
  exit 2
fi

command -v "$DENO" >/dev/null 2>&1 || {
  echo "no deno on PATH — set DENO or install it (this gate drives a browser)" >&2
  exit 2
}

exec "$DENO" run \
  --allow-read --allow-net --allow-env --allow-run --allow-write \
  "$CHECK" "$@"
