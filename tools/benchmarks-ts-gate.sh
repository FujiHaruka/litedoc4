#!/usr/bin/env bash
# Does the measurement tooling's TypeScript type-check? — the half of
# `benchmarks/tools` and `tools/oracle` nothing else looks at.
#
# node strips types rather than checking them, so these scripts ran for months
# with nobody type-checking them, and `check-site-browser.ts` was carrying a real
# one (measured 2026-08-28).
#
# A gate rather than a test because it needs node and the npm packages
# `benchmarks/tools/package-lock.json` pins, which `tools/lean-test-gate.sh` must
# not.
#
# usage: benchmarks-ts-gate.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOLS="$ROOT/benchmarks/tools"
CONFIG="$TOOLS/tsconfig.json"

command -v npm >/dev/null 2>&1 || {
  echo "no npm on PATH — this gate type-checks the measurement tooling." >&2
  echo "The version this tree pins is in mise.toml; \`mise install\` puts it on PATH." >&2
  exit 2
}

[ -f "$CONFIG" ] || {
  echo "missing $CONFIG — the browser-side callbacks need the dom libs" >&2
  exit 1
}

shopt -s nullglob
FILES=("$TOOLS"/*.ts "$ROOT"/tools/oracle/*.ts)
shopt -u nullglob

# Said out loud rather than assumed: a glob that matched nothing reads exactly
# like a clean run.
if [ "${#FILES[@]}" -lt 1 ]; then
  echo "no *.ts under $TOOLS or tools/oracle. A gate that checked nothing is not green." >&2
  exit 1
fi

if [ ! -d "$TOOLS/node_modules" ]; then
  echo "== install (benchmarks/tools has no node_modules)"
  (cd "$TOOLS" && npm ci --no-audit --no-fund)
fi
TSC="$TOOLS/node_modules/.bin/tsc"

# Reconciled rather than trusted: tsconfig.json's include can drift from the glob above and neither would fail.
ALL="$("$TSC" -p "$CONFIG" --listFilesOnly)" || { printf '%s\n' "$ALL" >&2; echo "tsc could not read $CONFIG" >&2; exit 1; }
LISTED="$(printf '%s\n' "$ALL" | grep -v '/node_modules/' | grep '\.ts$' | sort || true)"
ON_DISK="$(for f in "${FILES[@]}"; do (cd "$(dirname "$f")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$f")"); done | sort)"
if [ "$LISTED" != "$ON_DISK" ]; then
  echo "tsc would check a different set of files than the ones on disk:" >&2
  /usr/bin/diff <(printf '%s\n' "$ON_DISK") <(printf '%s\n' "$LISTED") >&2 || true
  exit 1
fi

echo "== node $(node --version), tsc $("$TSC" --version), ${#FILES[@]} script(s)"
"$TSC" -p "$CONFIG"

echo
echo "BENCHMARKS TS GATE: ok (${#FILES[@]} script(s))"
