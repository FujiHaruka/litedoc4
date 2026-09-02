#!/usr/bin/env bash
# Is there one answer to "what is the site's stylesheet"?
#
# `assets/` holds the site's static files and Lean has no `include_str!`, so
# `tools/gen-assets.py` writes their bytes into `src/Litedoc4/Assets.lean` as
# string literals (measured 2026-08-31 →
# `benchmarks/results/purelean-assets-literal-2026-08-31.txt`). A generated copy
# is a second answer to "what is the stylesheet" for as long as nobody checks it,
# and this is the named place that says the two agree.
#
# The chain has three links and each is checked exactly once:
#
#   vite  ->  assets/         the last stage of `tools/assets-gate.sh`, which has
#                             already built the bundle by then. Not an item here:
#                             this gate must stay runnable with no node.
#                             `assets/` is a committed build output, and one that
#                             goes stale still loads, with the JS of whatever
#                             commit last remembered to rebuild
#   assets/ -> Assets.lean    item 2 below
#   Assets.lean -> the pages  item 3 below
#
# What a failing item means:
#   1 SOURCES   `assets/` does not hold the four files, or one of them is empty.
#               An empty stylesheet is a site that loads and has no styling.
#   2 GENERATED `src/Litedoc4/Assets.lean` is not what `assets/` generates. Run
#               `tools/gen-assets.py`.
#   3 READERS   the renderer stopped going through the generated module: either
#               the one place that uses the theme-boot script no longer does, or
#               a module under `src/` carries asset bytes of its own again. A
#               second copy is the failure this gate exists for, and it does not
#               announce itself — the pages still render.
#
# **Item 3 lost its other half.** It counted the Rust `include_str!` paths too,
# and they left with `crates/` — `git show
# rust-frozen:crates/litedoc4-render/src/assets.rs` is where they were, in that
# tag and not in HEAD. The item is one-sided now and its pass line says so.
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
echo "=== 3/3 the renderer goes through the generated module, and from one place"
# One-sided since `crates/` left: the `include_str!` counts that were the other
# half of this item are in `git show rust-frozen:crates/litedoc4-render/src/assets.rs`.
#
# Every module under `src/` except the generated one. Frame.lean is where a
# theme-boot literal was once actually written, and the same copy one file over
# would be the same defect, so the scan is the directory rather than that file.
# The two needles are bytes only an asset has: `localStorage.getItem` is the boot
# script's and `color-scheme:` is the stylesheet's, and the renderer emits
# neither.
boot="$(grep -cw 'themeBootJs' src/Litedoc4/Render/Frame.lean || true)"
strays="$(grep -rl 'localStorage.getItem\|color-scheme:' src --include='*.lean' \
  | grep -v '^src/Litedoc4/Assets.lean$' || true)"
problems=""
[ "$boot" -eq 1 ] || problems="$problems; Frame.lean names themeBootJs $boot time(s), not once"
[ -z "$strays" ] || problems="$problems; asset bytes outside the generated module: $(printf '%s' "$strays" | tr '\n' ' ')"
if [ -n "$problems" ]; then
  fail 3 "${problems#; }"
else
  pass 3 "Frame.lean uses the generated theme-boot, no other module under src/ carries asset bytes; the include_str! half left with crates/"
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
