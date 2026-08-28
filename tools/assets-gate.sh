#!/usr/bin/env bash
# Is the site's TypeScript sound? — the half of `app.js` that `cargo` cannot see.
#
# `crates/litedoc4-render/build.rs` bundles `web/src` into cargo's `OUT_DIR` on
# every build, so a **syntax** error already fails `cargo build`. Everything else
# about that code is invisible to Rust: types, lint, format, and the tests over
# the index reader, the ranking and the theme.
#
# A gate rather than a test because it needs node, which `cargo test --workspace`
# must not. **Each stage has to be able to fail on its own** — a gate whose stages
# all fail the same way is one stage wearing four hats — and the counts are
# printed rather than assumed, because "vitest ran" and "vitest ran something"
# are different claims.
#
# usage: assets-gate.sh [--json FILE]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB="$(cd "$HERE/../crates/litedoc4-render/web" && pwd)"
JSON=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON="${2:?--json needs a path}"; shift 2 ;;
    *) echo "usage: assets-gate.sh [--json FILE]" >&2; exit 2 ;;
  esac
done

command -v npm >/dev/null 2>&1 || {
  echo "no npm on PATH — this gate builds and tests the site's TypeScript." >&2
  echo "The version this tree pins is in mise.toml; \`mise install\` puts it on PATH." >&2
  exit 2
}

cd "$WEB"

# `mise.toml` is what a developer's shell reads and `node-version:` is what the
# runners read, and nothing else makes them agree. Checked here rather than in a
# workflow: a check that only runs on a runner cannot say the runner is wrong.
ROOT="$(cd "$HERE/.." && pwd)"
PINNED="$(sed -n 's/^node[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/mise.toml")"
[ -n "$PINNED" ] || { echo "mise.toml names no node version" >&2; exit 1; }
#
# What is checked is that `mise.toml` is the *only* place the version is
# written: `.github/actions/setup-node` and `action.yml` both read it out of
# that file at run time. Reconciling copies was the earlier shape, and it holds
# only while whoever adds the next copy knows this gate exists.
WRITTEN="$(grep -rn 'node-version:' "$ROOT/.github" "$ROOT/action.yml" | grep -vF '${{' || true)"
if [ -n "$WRITTEN" ]; then
  echo "mise.toml pins node $PINNED; these write a version of their own:" >&2
  echo "$WRITTEN" >&2
  exit 1
fi
READERS="$(grep -rl 'mise.toml' "$ROOT/.github/actions" "$ROOT/action.yml" | wc -l | tr -d ' ')"
[ "$READERS" -ge 2 ] || {
  echo "the composite action and action.yml should both read mise.toml; $READERS do" >&2
  exit 1; }
USES="$(grep -rc 'actions/setup-node' "$ROOT/.github" "$ROOT/action.yml" | awk -F: '{n+=$2} END{print n}')"
echo "== node $PINNED, written once in mise.toml, read by $READERS action(s), used at $USES site(s)"

# `assets.rs` checks that every class the scripts assign is styled, and it names
# the scripts one by one because `include_str!` takes a literal. A sixth file
# that assigns a class would be scanned by nobody and the test would stay green.
# Checked here rather than there for the same reason: Rust cannot glob at test
# time. Drop this if that list ever stops being hand-written.
ASSETS_RS="$ROOT/crates/litedoc4-render/src/assets.rs"
LISTED="$(grep -o '"web/src/[a-z0-9-]*\.ts"' "$ASSETS_RS" | tr -d '"' | sed 's|web/src/||' | LC_ALL=C sort -u)"
ASSIGNING="$(grep -l '\.className = "' "$WEB"/src/*.ts | xargs -n1 basename | LC_ALL=C sort -u)"
if [ "$LISTED" != "$ASSIGNING" ]; then
  echo "assets.rs scans a different set of scripts than the ones that assign a class:" >&2
  echo "  < listed in assets.rs   > assigning a class" >&2
  /usr/bin/diff <(printf '%s\n' "$LISTED") <(printf '%s\n' "$ASSIGNING") >&2 || true
  exit 1
fi
echo "== $(printf '%s\n' "$LISTED" | wc -l | tr -d ' ') script(s) assign a class, and assets.rs scans exactly those"


# `npm ci` and not `npm install`: the lockfile is the version everything here was
# tested against.
if [ ! -d node_modules ]; then
  echo "== install"
  npm ci --no-audit --no-fund
fi

echo "== lint and format (biome)"
npx biome ci .

echo "== types (tsc, two projects: the page's code and node's)"
npx tsc -p tsconfig.json
npx tsc -p tsconfig.node.json

echo "== tests (vitest)"
# A full template, not `mktemp -t <prefix>`: BSD mktemp appends the random part to
# a prefix, GNU mktemp demands the X's and fails with "too few X's" (measured 2026-08-19).
REPORT="$(mktemp "${TMPDIR:-/tmp}/assets-gate-vitest.XXXXXX")"
# `--outputFile` and not a pipe: through a pipe the exit code would be the last
# command's, not vitest's.
npx vitest run --reporter=json --outputFile="$REPORT" >/dev/null
TESTS="$(python3 -c "
import json,sys
with open(sys.argv[1]) as f: r = json.load(f)
print(r.get('numTotalTests', 0), r.get('numPassedTests', 0), r.get('numFailedTests', 0))
" "$REPORT")"
rm -f "$REPORT"
read -r TOTAL PASSED FAILED <<<"$TESTS"

# vitest already fails on zero test files; this says the number out loud anyway,
# because a suite that shrank to nothing reads exactly like one that passed.
if [ "$TOTAL" -lt 1 ]; then
  echo "vitest reported $TOTAL tests. A green suite that ran nothing is not green." >&2
  exit 1
fi
echo "   $PASSED/$TOTAL passed, $FAILED failed"

echo "== bundle (vite)"
rm -rf dist
npm run build >/dev/null
[ -f dist/app.js ] || { echo "vite wrote no dist/app.js" >&2; exit 1; }
[ -f dist/theme-boot.js ] || { echo "vite wrote no dist/theme-boot.js" >&2; exit 1; }
BYTES="$(wc -c < dist/app.js | tr -d ' ')"
GZIP="$(gzip -c dist/app.js | wc -c | tr -d ' ')"
BOOT="$(wc -c < dist/theme-boot.js | tr -d ' ')"
# theme-boot is per *page*: `frame.rs` inlines it into every `<head>`.
echo "   dist/app.js $BYTES B, gzip $GZIP B; dist/theme-boot.js $BOOT B (inlined per page)"

# `dist/` is the by-hand output path; the one that reaches the binary is cargo's
# OUT_DIR, written by build.rs from these same sources.
rm -rf dist

if [ -n "$JSON" ]; then
  printf '{"tests":%s,"passed":%s,"failed":%s,"bundleBytes":%s,"bundleGzip":%s,"bootBytes":%s}\n' \
    "$TOTAL" "$PASSED" "$FAILED" "$BYTES" "$GZIP" "$BOOT" > "$JSON"
fi

echo
echo "ASSETS GATE: ok"
