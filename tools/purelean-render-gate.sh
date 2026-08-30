#!/usr/bin/env bash
# Does the Lean `render` write the same bytes as the Rust one, on the target?
#
# The oracle is the **Rust binary**, not a frozen tree: both are run here, in one
# session, against the same IR and the same `--source-url`, and the two page
# trees are compared. A stored reference would carry the source URL it was made
# with, and a gate that has to guess that string reports a URL difference as a
# renderer difference — which is what a first run of this comparison did.
#
# It needs the measurement target's IR and its `.lidx`, which a free runner does
# not have, so this is `manual` in `tools/gates.txt` and nothing in
# `.github/workflows/` calls it.
#
# What a failing item means:
#   1 BUILDS    `lake build litedoc4/litedoc4` in e2e/consumer produced no
#               binary: there is no Lean renderer to compare.
#   2 RENDER    one of the two renderers exited non-zero, or wrote no page.
#   3 PAGES     the two trees differ with a link index: the transcription and
#               the Rust renderer disagree about some page's bytes.
#   4 NOLIDX    they differ with `--no-link-index`. A separate item because the
#               map decides most of the links: agreeing with it and disagreeing
#               without it is a different defect from the reverse.
#   5 REFUSED   `render` accepted a flag it does not implement. The flag is
#               `--deps-docs-map`, which folds where each dependency's
#               documentation is published into the links a page draws: items 3
#               and 4 never pass it, so a half that took it and ignored it
#               writes exactly the bytes they compare. This is the one failure
#               the byte comparison cannot see. **When the Lean half implements
#               it, this item does not go away** — it moves to whatever `render`
#               flag is still missing, and if none is, it becomes the positive
#               check: both binaries take the flag, both write the same bytes,
#               and the result is not what a run without it writes.
#   6 SUMMARY   the two runs' stdout differs. The other failure the byte
#               comparison cannot see, from the other end: `math spans kept as
#               LaTeX` reports a fallback that renders a *valid* page, so a half
#               that stopped counting is 422 of 422 identical and silent.
#
# usage: purelean-render-gate.sh [--out DIR] [--keep]
#   --out   working directory (default: a temporary one, removed on success)
#   --keep  do not remove a temporary --out
#
#   PURELEAN_WORK  where the target's IR and .lidx are
#                  (default /private/tmp/lean-doc-relay/purelean).
#                  **Nothing here writes into it.**
#   LITEDOC4       the Rust litedoc4 to compare against
#                  (default target/release/litedoc4, else target/debug/litedoc4)
#   LAKE           the lake executable (default: ~/.elan/bin/lake)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIXTURE="$ROOT/e2e/consumer"
LAKE="${LAKE:-$HOME/.elan/bin/lake}"
LEAN_EXE="$ROOT/.lake/build/bin/litedoc4"
WORK="${PURELEAN_WORK:-/private/tmp/lean-doc-relay/purelean}"

if [ -z "${LITEDOC4:-}" ]; then
  if [ -x "$ROOT/target/release/litedoc4" ]; then
    LITEDOC4="$ROOT/target/release/litedoc4"
  else
    LITEDOC4="$ROOT/target/debug/litedoc4"
  fi
fi

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
[ -x "$LITEDOC4" ] || { echo "no litedoc4 at $LITEDOC4 — cargo build --release --bin litedoc4, or set LITEDOC4" >&2; exit 2; }
[ -d "$WORK/ir/modules" ] || { echo "no target IR at $WORK/ir/modules — set PURELEAN_WORK" >&2; exit 2; }
[ -f "$WORK/link-index.json" ] || { echo "no $WORK/link-index.json — set PURELEAN_WORK" >&2; exit 2; }
[ -f "$WORK/rev.txt" ] || { echo "no $WORK/rev.txt — the source URL is built from it" >&2; exit 2; }
[ -f "$FIXTURE/lakefile.toml" ] || { echo "no consumer fixture at $FIXTURE" >&2; exit 2; }

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d)"
  TEMPORARY=1
else
  mkdir -p "$OUT"
  TEMPORARY=0
fi

REV="$(tr -d '\n' <"$WORK/rev.txt")"
SOURCE_URL="https://github.com/FujiHaruka/lean-projects/blob/$REV"

ITEMS=6
ran=0
failed=0

pass () { ran=$((ran + 1)); printf 'ITEM %s ok    %s\n' "$1" "$2"; }
fail () { ran=$((ran + 1)); failed=$((failed + 1)); printf 'ITEM %s FAIL  %s\n' "$1" "$2" >&2; }
say  () { printf '\n=== %s\n' "$1"; }

# No pipe between the command and the status this gate judges on: through a pipe
# the status read back is the last command's, and `litedoc4` exiting 3 looks
# like 0 (measured 2026-08-18).
render () {
  local exe="$1" pages="$2" log="$3"; shift 3
  local rc=0
  # Apart, not `2>&1`: item 6 reads the summary out of stdout, and a warning on
  # stderr interleaved into it would be compared as though the run had printed it.
  "$exe" render --ir "$WORK/ir" --pages "$pages" --source-url "$SOURCE_URL" "$@" \
    >"$log" 2>"${log%.log}.err" || rc=$?
  return $rc
}

html_count () { find "$1" -type f -name '*.html' 2>/dev/null | wc -l | tr -d ' '; }

say "1/6 the Lean half builds from a consumer's workspace"
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

say "2/6 both renderers run over $WORK/ir"
rendered=0
if [ "$built" -eq 1 ]; then
  lean_rc=0
  rust_rc=0
  lean_nolidx_rc=0
  rust_nolidx_rc=0
  render "$LEAN_EXE" "$OUT/lean" "$OUT/lean.log" --link-index "$WORK/link-index.json" || lean_rc=$?
  render "$LITEDOC4" "$OUT/rust" "$OUT/rust.log" --link-index "$WORK/link-index.json" || rust_rc=$?
  render "$LEAN_EXE" "$OUT/lean-nolidx" "$OUT/lean-nolidx.log" --no-link-index || lean_nolidx_rc=$?
  render "$LITEDOC4" "$OUT/rust-nolidx" "$OUT/rust-nolidx.log" --no-link-index || rust_nolidx_rc=$?
  n_lean="$(html_count "$OUT/lean")"
  n_rust="$(html_count "$OUT/rust")"
  if [ "$lean_rc" -ne 0 ] || [ "$rust_rc" -ne 0 ] \
     || [ "$lean_nolidx_rc" -ne 0 ] || [ "$rust_nolidx_rc" -ne 0 ]; then
    fail 2 "a render exited non-zero (lean=$lean_rc rust=$rust_rc lean-nolidx=$lean_nolidx_rc rust-nolidx=$rust_nolidx_rc); see $OUT/*.log and $OUT/*.err"
  elif [ "$n_lean" -eq 0 ] || [ "$n_rust" -eq 0 ]; then
    # Two empty trees compare identical, so the count is what stops items 3 and
    # 4 from passing on nothing.
    fail 2 "a render wrote no page (lean $n_lean, rust $n_rust) — items 3 and 4 would compare two empty trees"
  else
    pass 2 "$n_lean Lean pages and $n_rust Rust pages"
    rendered=1
  fi
else
  fail 2 "no Lean binary to run — item 1 did not build one"
fi

compare_trees () {
  local item="$1" what="$2" ref="$3" cand="$4"
  local rc=0
  "$HERE/render-compare.sh" "$ref" "$cand" >"$OUT/compare-$item.txt" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$item" "$what: $(html_count "$cand") pages identical, $(find "$cand" -type f -name '*.html' -exec cat {} + | wc -c | tr -d ' ') bytes"
  else
    local counts
    counts="$(awk '/^(differing|missing|extra) /{printf "%s %s, ", $3, $1}' \
                "$OUT/compare-$item.txt")"
    fail "$item" "$what: ${counts}first name in $OUT/compare-$item.txt"
  fi
}

say "3/6 with --link-index, the two trees are the same bytes"
if [ "$rendered" -eq 1 ]; then
  compare_trees 3 "--link-index" "$OUT/rust" "$OUT/lean"
else
  fail 3 "nothing was rendered — item 2 did not produce two trees"
fi

say "4/6 with --no-link-index, the two trees are the same bytes"
if [ "$rendered" -eq 1 ]; then
  compare_trees 4 "--no-link-index" "$OUT/rust-nolidx" "$OUT/lean-nolidx"
else
  fail 4 "nothing was rendered — item 2 did not produce two trees"
fi

say "5/6 a flag render does not implement is refused by name"
UNIMPLEMENTED=--deps-docs-map
if [ "$built" -eq 1 ]; then
  refused_rc=0
  "$LEAN_EXE" render --ir "$WORK/ir" --pages "$OUT/refused" --source-url "$SOURCE_URL" \
    --no-link-index "$UNIMPLEMENTED" "$OUT/deps-docs.json" \
    >"$OUT/refused.out" 2>"$OUT/refused.err" || refused_rc=$?
  if [ "$refused_rc" -eq 0 ]; then
    fail 5 "render accepted $UNIMPLEMENTED and exited 0 — a flag that is ignored writes the bytes items 3 and 4 already compare, so nothing else here can see it"
  elif ! grep -qF -- "$UNIMPLEMENTED" "$OUT/refused.err"; then
    fail 5 "render refused $UNIMPLEMENTED with exit $refused_rc but the message does not name it — see $OUT/refused.err"
  else
    pass 5 "exit $refused_rc, naming $UNIMPLEMENTED"
  fi
else
  fail 5 "no Lean binary to run — item 1 did not build one"
fi

say "6/6 the two runs print the same stdout"
# The whole of stdout and not a slice of it: both halves take `--root`, so the
# `external ` block one prints is the other's too, and a comparison that began
# at the first counts line would swallow a difference in the dependency map the
# two resolved. The `-s` tests are what keeps two empty files from comparing
# equal — a run that printed nothing at all is exactly when that would happen.
if [ "$rendered" -eq 1 ] && [ -s "$OUT/rust.log" ] && [ -s "$OUT/lean.log" ]; then
  if ! /usr/bin/diff "$OUT/rust.log" "$OUT/lean.log" >"$OUT/summary.diff" 2>&1; then
    fail 6 "stdout differs — see $OUT/summary.diff"
    cat "$OUT/summary.diff" >&2
  else
    pass 6 "$(wc -l <"$OUT/lean.log" | tr -d ' ') identical line(s)"
  fi
else
  fail 6 "nothing was rendered — item 2 did not produce two runs' stdout"
fi

say "summary"
printf 'items reported : %s of %s\n' "$ran" "$ITEMS"
printf 'failed         : %s\n' "$failed"
printf 'out            : %s\n' "$OUT"

if [ "$ran" -ne "$ITEMS" ]; then
  echo "PURELEAN RENDER GATE: FAILED — $ran of $ITEMS items reported a result; the rest never ran" >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "PURELEAN RENDER GATE: FAILED ($failed of $ITEMS)" >&2
  exit 1
fi

# `if`, not `&&`: the last command in this block decides the script's exit code,
# and a `&&` whose left side is false returns 1 while the summary says ok.
if [ "$TEMPORARY" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
  rm -rf "$OUT"
fi
echo
echo "PURELEAN RENDER GATE: ok"
