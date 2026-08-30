#!/usr/bin/env bash
# Is there one answer to "what is the site's stylesheet"?
#
# For as long as both halves exist there are two consumers of `assets/`: Rust
# reaches it with `include_str!`, and Lean cannot, so `tools/gen-assets.py`
# writes the bytes into `src/Litedoc4/Assets.lean` as string literals (measured
# 2026-08-31 → `benchmarks/results/purelean-assets-literal-2026-08-31.txt`).
# Two copies of a file is the shape where only one of them ever gets fixed, and
# this is the named place that says they agree.
#
# The chain has three links and each is checked exactly once:
#
#   vite  ->  assets/         `the_committed_bundles_match_what_build_rs_bundled`
#                             in crates/litedoc4-render/src/assets.rs. A test and
#                             not an item here: build.rs has already run vite by
#                             the time it compiles, so it costs nothing that was
#                             not paid, and it leaves with the Rust tree — after
#                             M9 there is one bundle and nothing to reconcile
#   assets/ -> Assets.lean    item 2 below
#   assets/ -> assets.rs      item 3 below
#
# What a failing item means:
#   1 SOURCES   `assets/` does not hold the four files, or one of them is empty.
#               An empty stylesheet is a site that loads and has no styling.
#   2 GENERATED `src/Litedoc4/Assets.lean` is not what `assets/` generates. Run
#               `tools/gen-assets.py`.
#   3 READERS   something stopped reading `assets/`: the Rust `include_str!`
#               paths, or the one place in the Lean renderer that uses the
#               generated theme-boot script. A second copy of any of these is
#               the failure this gate exists for, and it does not announce
#               itself — the pages still render.
#
# Reads the tree. No binary, no toolchain, no node, no target.
#
# usage: assets-embed-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

failed=0
pass() { printf 'ITEM %s ok    %s\n' "$1" "$2"; }
fail() { printf 'ITEM %s FAIL  %s\n' "$1" "$2" >&2; failed=$((failed + 1)); }

echo "=== 1/3 assets/ holds the four files and none is empty"
missing=""
for name in style.css app.js favicon.svg theme-boot.js; do
  if [ ! -s "assets/$name" ]; then
    missing="$missing assets/$name"
  fi
done
if [ -n "$missing" ]; then
  fail 1 "absent or empty:$missing"
else
  pass 1 "$(wc -c assets/style.css assets/app.js assets/favicon.svg assets/theme-boot.js \
    | awk 'END{print $1}') bytes over 4 files"
fi

echo
echo "=== 2/3 src/Litedoc4/Assets.lean is what assets/ generates"
if check_out="$(tools/gen-assets.py --check 2>&1)"; then
  pass 2 "$check_out"
else
  fail 2 "$(printf '%s' "$check_out" | tr '\n' ' ')"
fi

echo
echo "=== 3/3 both halves still read assets/, and each from one place"
# Counted rather than grepped for presence: a second `include_str!` of a
# stylesheet somewhere else is exactly the divergence this gate is about, and it
# would satisfy a check that only asked whether the first one is still there.
css="$(grep -c 'include_str!("../../../assets/style.css")' crates/litedoc4-render/src/assets.rs || true)"
svg="$(grep -c 'include_str!("../../../assets/favicon.svg")' crates/litedoc4-render/src/assets.rs || true)"
strays="$(grep -rn 'include_str!("[^"]*assets/' crates --include='*.rs' \
  | grep -v '"\.\./\.\./\.\./assets/' || true)"
boot="$(grep -c 'themeBootJs' src/Litedoc4/Render/Frame.lean || true)"
literal="$(grep -c 'localStorage.getItem' src/Litedoc4/Render/Frame.lean || true)"
problems=""
[ "$css" -eq 1 ] || problems="$problems; assets.rs reads assets/style.css $css time(s), not once"
[ "$svg" -eq 1 ] || problems="$problems; assets.rs reads assets/favicon.svg $svg time(s), not once"
[ -z "$strays" ] || problems="$problems; another include_str! of an assets/ path: $(printf '%s' "$strays" | head -1)"
[ "$boot" -eq 1 ] || problems="$problems; Frame.lean names themeBootJs $boot time(s), not once"
[ "$literal" -eq 0 ] || problems="$problems; Frame.lean carries a theme-boot literal again ($literal line(s))"
if [ -n "$problems" ]; then
  fail 3 "${problems#; }"
else
  pass 3 "assets.rs reads 2 files from assets/, Frame.lean uses the generated theme-boot"
fi

echo
echo "=== summary"
echo "items reported : 3 of 3"
echo "failed         : $failed"
if [ "$failed" -ne 0 ]; then
  echo
  echo "ASSETS EMBED GATE: $failed item(s) failed" >&2
  exit 1
fi
echo
echo "ASSETS EMBED GATE: ok"
