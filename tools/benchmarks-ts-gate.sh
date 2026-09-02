#!/usr/bin/env bash
# Does the measurement tooling's TypeScript type-check? — the half of
# `benchmarks/tools` nothing else looks at.
#
# `deno run` strips types rather than checking them, so these scripts ran for
# months with nobody type-checking them, and `check-site-browser.ts` was
# carrying a real one (measured 2026-08-28).
#
# A gate rather than a test because it needs deno, which `tools/lean-test-gate.sh`
# must not.
#
# usage: benchmarks-ts-gate.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOLS="$ROOT/benchmarks/tools"
CONFIG="$TOOLS/deno.json"

command -v deno >/dev/null 2>&1 || {
  echo "no deno on PATH — this gate type-checks the measurement tooling." >&2
  exit 2
}

# `--config` rather than letting deno discover it: discovery walks up from the
# working directory, and these scripts are run from `benchmarks/` and from a
# runner's workspace root. Drop the flag only if every caller starts here.
[ -f "$CONFIG" ] || {
  echo "missing $CONFIG — the browser-side callbacks need the dom libs" >&2
  exit 1
}

shopt -s nullglob
FILES=("$TOOLS"/*.ts)
shopt -u nullglob

# Said out loud rather than assumed: a glob that matched nothing reads exactly
# like a clean run.
if [ "${#FILES[@]}" -lt 1 ]; then
  echo "no *.ts under $TOOLS. A gate that checked nothing is not green." >&2
  exit 1
fi

echo "== $(deno --version | head -1), ${#FILES[@]} script(s)"
deno check --config "$CONFIG" "${FILES[@]}"

echo
echo "BENCHMARKS TS GATE: ok (${#FILES[@]} script(s))"
