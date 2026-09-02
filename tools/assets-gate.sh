#!/usr/bin/env bash
# Is the site's TypeScript sound?
#
# **Nothing else in the tree compiles `web/src` at all.** The executable carries
# the *bundle* (`assets/app.js`, read into `src/Litedoc4/Assets.lean` by
# `tools/gen-assets.py`), never the sources, so a syntax error in `web/src`
# reaches nobody until a reader loads a page whose script does not run. This gate
# is where that code is type-checked, linted, tested and bundled — all of it, or
# none of it.
#
# A gate rather than part of the Lean test suite because it needs node, and
# `tools/lean-test-gate.sh` must not. **Each stage has to be able to fail on its
# own** — a gate whose stages all fail the same way is one stage wearing five
# hats — and the counts are printed rather than assumed, because "vitest ran" and
# "vitest ran something" are different claims.
#
# The last stage answers a different question from the rest: not "is this code
# sound" but "is `assets/` what it builds". That is the first link of the chain
# `tools/assets-embed-gate.sh` documents, and it is here because it is the only
# gate that has already run vite.
#
# usage: assets-gate.sh [--json FILE]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB="$(cd "$HERE/../web" && pwd)"
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
# Derived, not counted: **whatever installs node has to read the version from
# mise.toml**, and which files those are is not this gate's business to know. A
# count was the earlier shape and it said "2" — which went stale the moment
# `action.yml` stopped installing node at all (2026-08-31), failing on a file
# that had become right.
INSTALLERS="$(grep -rl 'actions/setup-node@' "$ROOT/.github" "$ROOT/action.yml" || true)"
[ -n "$INSTALLERS" ] || {
  echo "nothing in the tree installs node — this check would pass having read nothing" >&2
  exit 1; }
BLIND=""
for f in $INSTALLERS; do
  grep -qF 'mise.toml' "$f" || BLIND="$BLIND$f"$'\n'
done
if [ -n "$BLIND" ]; then
  echo "mise.toml pins node $PINNED; these install node without reading it:" >&2
  printf '%s' "$BLIND" >&2
  exit 1
fi
READERS="$(printf '%s\n' "$INSTALLERS" | grep -c . )"
USES="$(grep -rc './.github/actions/setup-node' "$ROOT/.github" "$ROOT/action.yml" | awk -F: '{n+=$2} END{print n}')"
echo "== node $PINNED, written once in mise.toml, read by $READERS installer(s), used at $USES site(s)"

# Every class the scripts assign has a rule in `style.css`. The failure is
# silent: a class renamed in `web/src` still renders and simply has no styling.
#
# Here and not beside the renderer's own version of this check, which is
# `Litedoc4Test.RenderAssets` read off built pages: `Litedoc4.Assets` carries the
# *bundle*, not the sources, so nothing on that side can see a `.className =` at
# all.
#
# The scripts are **globbed**, not listed. A hand-written list of the files that
# assign a class was the earlier shape and it needed a second check to reconcile
# it; a glob cannot go stale when a sixth file arrives.
#
# Only the "assigned but not styled" direction. A class that stops being assigned
# leaves an unused rule and breaks nothing, and recording the names to catch it
# would put a hand-written list back.
STYLE="$ROOT/assets/style.css"
SCRIPTED="$(grep -ho '\.className = "[^"]*"' "$WEB"/src/*.ts \
  | sed 's/^\.className = "//; s/"$//' | tr ' ' '\n' | grep . | LC_ALL=C sort -u)"
[ -n "$SCRIPTED" ] || { echo "no class assignment found — the scan broke" >&2; exit 1; }
UNSTYLED=""
while IFS= read -r cls; do
  grep -qF ".$cls" "$STYLE" || UNSTYLED="$UNSTYLED  .$cls"$'\n'
done <<EOF
$SCRIPTED
EOF
if [ -n "$UNSTYLED" ]; then
  echo "the site's scripts assign classes style.css says nothing about:" >&2
  printf '%s' "$UNSTYLED" >&2
  exit 1
fi
echo "== $(printf '%s\n' "$SCRIPTED" | wc -l | tr -d ' ') class(es) the scripts assign, all styled"


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
# theme-boot is per *page*: `Litedoc4.Render.Frame` inlines it into every `<head>`.
echo "   dist/app.js $BYTES B, gzip $GZIP B; dist/theme-boot.js $BOOT B (inlined per page)"

echo "== assets/ is this bundle"
# The first link of the chain `assets-embed-gate.sh` documents: vite -> assets/.
# `assets/app.js` and `assets/theme-boot.js` are committed, because the Lean half
# cannot `include_str!` and `tools/gen-assets.py` writes their bytes into
# `src/Litedoc4/Assets.lean`. A committed build output has no way of announcing
# that it went stale — the site still loads, with the JS of whatever commit last
# remembered to rebuild.
#
# Compared here and not in `assets-embed-gate.sh`, which reads the tree and must
# stay free of node; and byte for byte rather than by mtime, because the question
# is whether these are the same bundle, not which is newer.
STALE=""
for f in app.js theme-boot.js; do
  cmp -s "dist/$f" "$ROOT/assets/$f" || STALE="$STALE  $f"$'\n'
done
if [ -n "$STALE" ]; then
  echo "assets/ is not what these sources build. Stale:" >&2
  printf '%s' "$STALE" >&2
  echo "  cd $WEB && LITEDOC4_ASSET_OUT_DIR=$ROOT/assets npm run build" >&2
  echo "  then re-run tools/gen-assets.py, or Assets.lean keeps the old bytes." >&2
  exit 1
fi
echo "   assets/app.js and assets/theme-boot.js are byte for byte this build"

# `dist/` is scratch: what reaches the executable is `assets/`, compared against
# it just above.
rm -rf dist

if [ -n "$JSON" ]; then
  printf '{"tests":%s,"passed":%s,"failed":%s,"bundleBytes":%s,"bundleGzip":%s,"bootBytes":%s}\n' \
    "$TOTAL" "$PASSED" "$FAILED" "$BYTES" "$GZIP" "$BOOT" > "$JSON"
fi

echo
echo "ASSETS GATE: ok"
