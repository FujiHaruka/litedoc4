#!/usr/bin/env bash
# Does the Lean `render` write the same bytes as the Rust one, on e2e/micro?
#
# `purelean-render-gate.sh` asks the same question over the measurement target
# and is therefore `manual`. This one is `ci`, and it is not a smaller version of
# it: **e2e/micro holds the declaration shapes the target does not have**
# (`e2e/README.md`), and the two arms below fire on shapes 432 modules of
# Mathlib-depending Lean never produce. A comparison over the target alone is
# green over every one of them.
#
# The oracle is the **Rust binary**, run here, in one session, against the same
# IR and the same `--source-url` — never a stored tree, which carries the source
# URL it was made with and reports a URL difference as a renderer difference.
#
# What a failing item means:
#   1 BUILDS    `lake build litedoc4/litedoc4` in e2e/consumer produced no
#               binary: there is no Lean renderer to compare.
#   2 IR        the sample's IR was not extracted, so there is nothing to render.
#   3 PAGES     the two trees differ with a link index.
#   4 REFUSAL   the two disagree about the name that cannot be placed.
#               `Example.Preferred` extends `Inhabited`, whose defining module
#               the sample does not declare, so with `--no-link-index` the name
#               is in no map at all and the run must stop rather than invent an
#               `href` (`crates/litedoc4-render/src/decl.rs`, `UnplaceableName`).
#               **Both binaries must refuse**, with the same exit code, the same
#               message, and the same pages written before stopping. If both
#               exit 0 this item fails too: the sample has stopped covering the
#               branch, which is the failure that hides all the others.
#   5 SUMMARY   the counts the run prints differ. The pages can agree while a
#               silent fallback goes unreported — `math spans kept as LaTeX` is
#               exactly such a line — so the bytes are not the whole answer.
#
# usage: purelean-micro-gate.sh [--out DIR] [--keep]
#   --out   working directory (default: a temporary one, removed on success)
#   --keep  do not remove a temporary --out
#
#   LITEDOC4  the Rust litedoc4: the oracle, and what extracts the IR
#             (default target/release/litedoc4, else target/debug/litedoc4)
#   LAKE      the lake executable (default: ~/.elan/bin/lake)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
FIXTURE="$ROOT/e2e/consumer"
MICRO="$ROOT/e2e/micro"
LAKE="${LAKE:-$HOME/.elan/bin/lake}"
LEAN_EXE="$ROOT/.lake/build/bin/litedoc4"
# `diff` is aliased to a colordiff that is not installed here, and its exit 127
# reads as "differences found".
DIFF_CMD=/usr/bin/diff

if [ -z "${LITEDOC4:-}" ]; then
  if [ -x "$ROOT/target/release/litedoc4" ]; then
    LITEDOC4="$ROOT/target/release/litedoc4"
  else
    LITEDOC4="$ROOT/target/debug/litedoc4"
  fi
fi

# Fixed, not derived from git: the URL is baked into every `source` link, and a
# gate whose expected bytes move with HEAD compares two renderers *and* two
# checkouts. Both binaries are handed this same string.
SOURCE_URL="https://github.com/FujiHaruka/litedoc4/blob/HEAD/e2e/micro"

OUT=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '1,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Hard exits rather than skips: an item that prints "no input" and returns 0 does
# not reach the exit code, which is how a gate goes green having checked nothing.
[ -x "$LAKE" ] || { echo "no lake at $LAKE — set LAKE" >&2; exit 2; }
[ -x "$LITEDOC4" ] || { echo "no litedoc4 at $LITEDOC4 — cargo build --bin litedoc4, or set LITEDOC4" >&2; exit 2; }
[ -f "$MICRO/lakefile.toml" ] || [ -f "$MICRO/lakefile.lean" ] || { echo "no sample package at $MICRO" >&2; exit 2; }
[ -f "$FIXTURE/lakefile.toml" ] || { echo "no consumer fixture at $FIXTURE" >&2; exit 2; }

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d)"
  TEMPORARY=1
else
  mkdir -p "$OUT"
  TEMPORARY=0
fi

ITEMS=5
ran=0
failed=0

pass () { ran=$((ran + 1)); printf 'ITEM %s ok    %s\n' "$1" "$2"; }
fail () { ran=$((ran + 1)); failed=$((failed + 1)); printf 'ITEM %s FAIL  %s\n' "$1" "$2" >&2; }
say  () { printf '\n=== %s\n' "$1"; }

html_count () { find "$1" -type f -name '*.html' 2>/dev/null | wc -l | tr -d ' '; }

# No pipe between the command and the status this gate judges on: through a pipe
# the status read back is the last command's, and `litedoc4` exiting 1 looks
# like 0 (measured 2026-08-18).
render () {
  local exe="$1" pages="$2" name="$3"; shift 3
  local rc=0
  "$exe" render --ir "$OUT/build/ir" --pages "$pages" --source-url "$SOURCE_URL" "$@" \
    >"$OUT/$name.out" 2>"$OUT/$name.err" || rc=$?
  echo "$rc"
}

# The block `print_render_summary` writes, wherever it starts: `render` prints an
# external-links line before it that the Lean half cannot print, because it
# refuses `--root` by name. Taking the tail from `modules ` rather than dropping
# named lines means a *new* summary line is a difference rather than something
# an exception list swallows. When the Lean `render` grows `--root` (M3), this
# slice stops being needed and the whole stdout should be compared.
summary_of () { sed -n '/^modules /,$p' "$1"; }

say "1/5 the Lean half builds from a consumer's workspace"
built=0
build_rc=0
(cd "$FIXTURE" && "$LAKE" build litedoc4/litedoc4) >"$OUT/build.log" 2>&1 || build_rc=$?
if [ "$build_rc" -eq 0 ] && [ -x "$LEAN_EXE" ]; then
  pass 1 "$LEAN_EXE ($(wc -c <"$LEAN_EXE" | tr -d ' ') bytes)"
  built=1
elif [ "$build_rc" -eq 0 ]; then
  fail 1 "lake build litedoc4/litedoc4 exited 0 but there is no $LEAN_EXE"
else
  fail 1 "lake build litedoc4/litedoc4 failed in $FIXTURE — see $OUT/build.log"
  tail -20 "$OUT/build.log" >&2
fi

say "2/5 the sample's IR, extracted here"
extracted=0
(cd "$MICRO" && "$LAKE" build) >"$OUT/micro-build.log" 2>&1
EXTRACTOR="$(micro_extractor "$ROOT" "$MICRO" "$LAKE" "$OUT/extractor-build.log")"
if [ ! -x "$EXTRACTOR" ]; then
  fail 2 "no extractor at $EXTRACTOR — see $OUT/extractor-build.log"
else
  rm -rf "$OUT/build"
  ir_rc=0
  "$LITEDOC4" build --root "$MICRO" --lib Example --out "$OUT/build" \
    --extractor-bin "$EXTRACTOR" >"$OUT/ir.log" 2>&1 || ir_rc=$?
  n_ir="$(find "$OUT/build/ir/modules" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$ir_rc" -ne 0 ]; then
    fail 2 "litedoc4 build exited $ir_rc — see $OUT/ir.log"
    tail -20 "$OUT/ir.log" >&2
  elif [ "$n_ir" -eq 0 ]; then
    # Two renderers over an empty IR write two empty trees and compare identical.
    fail 2 "the IR has no module file — items 3 to 5 would compare two empty trees"
  else
    pass 2 "$n_ir module(s) and $(wc -c <"$OUT/build/link-index.lidx" | tr -d ' ') bytes of link index"
    extracted=1
  fi
fi

say "3/5 with --link-index, the two trees are the same bytes"
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ]; then
  rm -rf "$OUT/lean" "$OUT/rust"
  lean_rc="$(render "$LEAN_EXE" "$OUT/lean" lean --link-index "$OUT/build/link-index.lidx")"
  rust_rc="$(render "$LITEDOC4" "$OUT/rust" rust --link-index "$OUT/build/link-index.lidx")"
  n_lean="$(html_count "$OUT/lean")"
  n_rust="$(html_count "$OUT/rust")"
  cmp_rc=0
  "$HERE/render-compare.sh" "$OUT/rust" "$OUT/lean" >"$OUT/compare-3.txt" 2>&1 || cmp_rc=$?
  if [ "$lean_rc" -ne 0 ] || [ "$rust_rc" -ne 0 ]; then
    fail 3 "a render exited non-zero (lean=$lean_rc rust=$rust_rc) — see $OUT/{lean,rust}.err"
  elif [ "$n_lean" -eq 0 ] || [ "$n_rust" -eq 0 ]; then
    fail 3 "a render wrote no page (lean $n_lean, rust $n_rust)"
  elif [ "$cmp_rc" -ne 0 ]; then
    fail 3 "$(awk '/^(differing|missing|extra) /{printf "%s %s, ", $3, $1}' "$OUT/compare-3.txt")first name in $OUT/compare-3.txt"
  else
    pass 3 "$n_lean pages identical, $(find "$OUT/lean" -type f -name '*.html' -exec cat {} + | wc -c | tr -d ' ') bytes"
  fi
else
  fail 3 "no binary or no IR — item 1 or 2 did not produce one"
fi

say "4/5 with --no-link-index, both refuse the same unplaceable name"
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ]; then
  rm -rf "$OUT/lean-nolidx" "$OUT/rust-nolidx"
  lean_n_rc="$(render "$LEAN_EXE" "$OUT/lean-nolidx" lean-nolidx --no-link-index)"
  rust_n_rc="$(render "$LITEDOC4" "$OUT/rust-nolidx" rust-nolidx --no-link-index)"
  cmp4_rc=0
  "$HERE/render-compare.sh" "$OUT/rust-nolidx" "$OUT/lean-nolidx" >"$OUT/compare-4.txt" 2>&1 || cmp4_rc=$?
  if [ "$rust_n_rc" -eq 0 ]; then
    fail 4 "the Rust render exited 0: e2e/micro no longer carries a name in no module, so this item and the Lean side's refusal are both untested"
  elif [ "$lean_n_rc" -ne "$rust_n_rc" ]; then
    fail 4 "exit codes differ (lean=$lean_n_rc rust=$rust_n_rc); Lean said: $(head -1 "$OUT/lean-nolidx.err" 2>/dev/null)"
  elif ! $DIFF_CMD "$OUT/rust-nolidx.err" "$OUT/lean-nolidx.err" >"$OUT/refusal.diff" 2>&1; then
    fail 4 "both exited $rust_n_rc but said different things — see $OUT/refusal.diff"
  elif [ "$cmp4_rc" -ne 0 ]; then
    fail 4 "the pages written before stopping differ: $(awk '/^(differing|missing|extra) /{printf "%s %s, ", $3, $1}' "$OUT/compare-4.txt")see $OUT/compare-4.txt"
  else
    pass 4 "both exited $rust_n_rc after $(html_count "$OUT/lean-nolidx") page(s): $(head -1 "$OUT/rust-nolidx.err")"
  fi
else
  fail 4 "no binary or no IR — item 1 or 2 did not produce one"
fi

say "5/5 the two runs report the same counts"
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ] && [ -s "$OUT/lean.out" ] && [ -s "$OUT/rust.out" ]; then
  summary_of "$OUT/rust.out" >"$OUT/rust.summary"
  summary_of "$OUT/lean.out" >"$OUT/lean.summary"
  if [ ! -s "$OUT/rust.summary" ] || [ ! -s "$OUT/lean.summary" ]; then
    # Two empty slices compare equal, and a run that printed no summary at all is
    # exactly when that would happen.
    fail 5 "a run printed no summary block (rust $(wc -l <"$OUT/rust.summary" | tr -d ' ') line(s), lean $(wc -l <"$OUT/lean.summary" | tr -d ' '))"
  elif ! $DIFF_CMD "$OUT/rust.summary" "$OUT/lean.summary" >"$OUT/summary.diff" 2>&1; then
    fail 5 "the summaries differ — see $OUT/summary.diff"
    $DIFF_CMD "$OUT/rust.summary" "$OUT/lean.summary" >&2 || true
  else
    pass 5 "$(wc -l <"$OUT/lean.summary" | tr -d ' ') identical line(s)"
  fi
else
  fail 5 "item 3 did not leave two summaries to compare"
fi

say "summary"
printf 'items reported : %s of %s\n' "$ran" "$ITEMS"
printf 'failed         : %s\n' "$failed"
printf 'out            : %s\n' "$OUT"

if [ "$ran" -ne "$ITEMS" ]; then
  echo "PURELEAN MICRO GATE: FAILED — $ran of $ITEMS items reported a result; the rest never ran" >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "PURELEAN MICRO GATE: FAILED ($failed of $ITEMS)" >&2
  exit 1
fi

# `if`, not `&&`: the last command in this block decides the script's exit code,
# and a `&&` whose left side is false returns 1 while the summary says ok.
if [ "$TEMPORARY" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
  rm -rf "$OUT"
fi
echo
echo "PURELEAN MICRO GATE: ok"
