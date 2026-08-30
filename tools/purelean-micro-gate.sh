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
#   3 PAGES     the two trees differ with a link index. Run twice, over the same
#               IR with two spellings of --source-url: bare, and with a trailing
#               slash. `render` and `site` accept any non-empty URL, and the
#               Lean renderer was writing `…/e2e/micro//Mod.lean` for the second
#               one while every gate passed, because they all pass the first
#               (measured 2026-08-31). `build` cannot reach it — it demands 40
#               hex and builds the base itself.
#   4 REFUSAL   the two disagree about the name that cannot be placed.
#               `Example.Preferred` extends `Inhabited`, whose defining module
#               the sample does not declare, so with `--no-link-index` the name
#               is in no map at all and the run must stop rather than invent an
#               `href` (`crates/litedoc4-render/src/decl.rs`, `UnplaceableName`).
#               **Both binaries must refuse**, with the same exit code, the same
#               message, and the same pages written before stopping. If both
#               exit 0 this item fails too: the sample has stopped covering the
#               branch, which is the failure that hides all the others.
#   5 SUMMARY   the two runs' stdout differs. The pages can agree while a
#               silent fallback goes unreported — `math spans kept as LaTeX` is
#               exactly such a line — so the bytes are not the whole answer.
#               Compared whole, not from the first counts line: the dependency
#               link map is reported above them and nowhere else.
#   6 SITE      `litedoc4 site` writes the pages *and* the nine whole-package
#               artifacts, and the two trees differ. Compared with `--all`: four
#               of the artifacts are JSON and one is binary, and a comparison
#               that saw only `*.html` would call two sites identical while
#               their search indexes disagreed.
#   7 SITE SUM  the two `site` runs print different stdout.
#  10 BUILD     the two `build` runs write different bytes. This is the whole
#               pipeline rather than `site` again: it globs the sources, reads
#               `lakefile.toml`, derives nothing (the URL is pinned here, see
#               BUILD_URL), drives the resident extractor, writes the assets
#               and the ledger, and leaves a marker. 23 files, not 20 — the
#               three assets are `build`'s and `site` never writes them.
#  11 SITEGATE  `site-gate.sh` fails on the Lean-built site. It is the
#               dead-link half that item 8 cannot ask: a bare `site` tree has
#               no `style.css`, so the question only becomes answerable once
#               `build` has written them.
#  12 CONFIG    `config-gate.sh` fails on it. `litedoc4.toml`'s title and index
#               prose have to reach the pages the same way from every command
#               that writes HTML. Asked twice over the same built site — once
#               with the Rust half re-deriving the three trees and once with the
#               Lean half, which can since it grew a `global`. Two spellings of
#               one claim, so a failure names which half was deriving.
#  14 BUILD OUT  the two `build` runs print different transcripts. Item 10
#               compares files; nothing compared what the command *said*, and
#               that is where `global … state 0 B` sat for a while against
#               Rust's `state 10499 B` with every item green.
#               Three things are normalised, each of which moves for a reason
#               that is not the port's: a duration, the `ready` timestamp, and
#               the two runs' different `--out`. Nothing else is, and the
#               `serve ready` line's `generation <hex>` is the one that earns
#               the item: it is a digest over Lake's own `<file>.hash` beside
#               every olean of every module, so the two halves agree on it only
#               if they read the same files in the same order — the guard that
#               stops a `lake build` landing mid-run from being extracted from,
#               compared end to end rather than asserted to exist.
#  13 MARKER    the two `litedoc4-build.json` differ. Compared whole, and that
#               includes `work.irReads` — counts of how many times each reader
#               opened the IR. They are a property of the reader's call
#               pattern, not of the output, so a Lean reader that took a
#               different number of passes would show up here and nowhere else.
#   9 LEDGER    the two `ledger build` runs write different bytes. The ledger is
#               what M5's incremental path reads to decide what is stale, so a
#               field that drifts here is a build that later re-extracts
#               everything or, worse, nothing. Compared whole rather than
#               field by field: its key order is insertion order, not sorted,
#               and a comparison that parsed both would stop seeing that.
#  15 ONLY      `--only-from` did not narrow the render. Two claims, because
#               either alone is satisfied by a wrong implementation: the two
#               halves write the **same** subset, and that subset is the size the
#               set named — a `--only-from` that is accepted and ignored writes
#               exactly the tree items 3 and 4 already compare, and one that
#               silently drops everything writes nothing and would agree too.
#               The empty set is checked beside it: an empty file has to mean
#               render nothing, which is what the pipeline hands it when a round
#               finds no page stale. The names come out of the IR, not out of
#               this file, so a growing sample cannot leave a stale spelling here.
#   8 CLOSURE   the Lean site does not close over itself. `check-site-closure.py`
#               asks whether the index, the search index and the pages agree
#               about which declarations exist **in both directions**, and
#               `usedby-gate.sh` asks the same of `used-by.json` against the IR.
#               Both are oracle-free, and neither is a second byte comparison:
#               two renderers can agree byte for byte on a site that contradicts
#               itself. The dead-link half of `site-gate.sh` is deliberately not
#               here — `style.css` and `favicon.svg` are written by `build`, not
#               by `site` (measured 2026-08-31 ->
#               `benchmarks/results/purelean-site-boundary-2026-08-31.txt`), so a
#               bare `site` tree fails it by construction.
#
# usage: purelean-micro-gate.sh [--out DIR] [--keep]
#   --out   working directory (default: a temporary one, removed on success)
#   --keep  do not remove a temporary --out
#
#   LITEDOC4  the Rust litedoc4: the oracle, and what extracts the IR
#             (default target/release/litedoc4, else target/debug/litedoc4)
#   LAKE      the lake executable (default: ~/.elan/bin/lake)
#   PYTHON    the python3 item 8 runs the closure checks with (default python3)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
FIXTURE="$ROOT/e2e/consumer"
MICRO="$ROOT/e2e/micro"
LAKE="${LAKE:-$HOME/.elan/bin/lake}"
PYTHON="${PYTHON:-python3}"
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

ITEMS=15
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

site_run () {
  local exe="$1" out="$2" name="$3"; shift 3
  local rc=0
  "$exe" site --ir "$OUT/build/ir" --out "$out" --source-url "$SOURCE_URL" \
    --link-index "$OUT/build/link-index.lidx" \
    >"$OUT/$name.out" 2>"$OUT/$name.err" || rc=$?
  echo "$rc"
}

say "1/15 the Lean half builds from a consumer's workspace"
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

say "2/15 the sample's IR, extracted here"
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

say "3/15 with --link-index, the two trees are the same bytes"
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ]; then
  rm -rf "$OUT/lean" "$OUT/rust" "$OUT/lean-slash" "$OUT/rust-slash"
  lean_rc="$(render "$LEAN_EXE" "$OUT/lean" lean --link-index "$OUT/build/link-index.lidx")"
  rust_rc="$(render "$LITEDOC4" "$OUT/rust" rust --link-index "$OUT/build/link-index.lidx")"
  n_lean="$(html_count "$OUT/lean")"
  n_rust="$(html_count "$OUT/rust")"
  cmp_rc=0
  "$HERE/render-compare.sh" "$OUT/rust" "$OUT/lean" >"$OUT/compare-3.txt" 2>&1 || cmp_rc=$?
  # The same question with a trailing slash on the URL. Not a separate item: it
  # is the same claim ("the two renderers agree") over an input the first
  # spelling cannot reach, and an item of its own would report the same defect
  # twice.
  lean_s2_rc="$(SOURCE_URL="$SOURCE_URL/" render "$LEAN_EXE" "$OUT/lean-slash" lean-slash --link-index "$OUT/build/link-index.lidx")"
  rust_s2_rc="$(SOURCE_URL="$SOURCE_URL/" render "$LITEDOC4" "$OUT/rust-slash" rust-slash --link-index "$OUT/build/link-index.lidx")"
  cmp_slash_rc=0
  "$HERE/render-compare.sh" "$OUT/rust-slash" "$OUT/lean-slash" >"$OUT/compare-3-slash.txt" 2>&1 || cmp_slash_rc=$?
  if [ "$lean_rc" -ne 0 ] || [ "$rust_rc" -ne 0 ]; then
    fail 3 "a render exited non-zero (lean=$lean_rc rust=$rust_rc) — see $OUT/{lean,rust}.err"
  elif [ "$n_lean" -eq 0 ] || [ "$n_rust" -eq 0 ]; then
    fail 3 "a render wrote no page (lean $n_lean, rust $n_rust)"
  elif [ "$cmp_rc" -ne 0 ]; then
    fail 3 "$(awk '/^(differing|missing|extra) /{printf "%s %s, ", $3, $1}' "$OUT/compare-3.txt")first name in $OUT/compare-3.txt"
  elif [ "$lean_s2_rc" -ne 0 ] || [ "$rust_s2_rc" -ne 0 ]; then
    fail 3 "a render with a trailing slash on --source-url exited non-zero (lean=$lean_s2_rc rust=$rust_s2_rc)"
  elif [ "$cmp_slash_rc" -ne 0 ]; then
    fail 3 "with a trailing slash on --source-url: $(awk '/^(differing|missing|extra) /{printf "%s %s, ", $3, $1}' "$OUT/compare-3-slash.txt")first name in $OUT/compare-3-slash.txt"
  else
    pass 3 "$n_lean pages identical, $(find "$OUT/lean" -type f -name '*.html' -exec cat {} + | wc -c | tr -d ' ') bytes; identical again with a trailing slash on --source-url"
  fi
else
  fail 3 "no binary or no IR — item 1 or 2 did not produce one"
fi

say "4/15 with --no-link-index, both refuse the same unplaceable name"
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

say "5/15 the two runs print the same stdout"
# The whole of stdout and not a slice of it: both halves take `--root`, so the
# `external ` block one prints is the other's too, and a comparison that began
# at the first counts line would swallow a difference in the dependency map the
# two resolved. The `-s` tests are what keeps two empty files from comparing
# equal — a run that printed nothing at all is exactly when that would happen.
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ] && [ -s "$OUT/lean.out" ] && [ -s "$OUT/rust.out" ]; then
  if ! $DIFF_CMD "$OUT/rust.out" "$OUT/lean.out" >"$OUT/summary.diff" 2>&1; then
    fail 5 "stdout differs — see $OUT/summary.diff"
    $DIFF_CMD "$OUT/rust.out" "$OUT/lean.out" >&2 || true
  else
    pass 5 "$(wc -l <"$OUT/lean.out" | tr -d ' ') identical line(s)"
  fi
else
  fail 5 "item 3 did not leave two runs' stdout to compare"
fi

say "6/15 \`site\` writes the same 20 files, bytes and all"
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ]; then
  rm -rf "$OUT/site-lean" "$OUT/site-rust"
  lean_s_rc="$(site_run "$LEAN_EXE" "$OUT/site-lean" site-lean)"
  rust_s_rc="$(site_run "$LITEDOC4" "$OUT/site-rust" site-rust)"
  n_lean_s="$(find "$OUT/site-lean" -type f 2>/dev/null | wc -l | tr -d ' ')"
  n_rust_s="$(find "$OUT/site-rust" -type f 2>/dev/null | wc -l | tr -d ' ')"
  cmp6_rc=0
  "$HERE/render-compare.sh" --all "$OUT/site-rust" "$OUT/site-lean" >"$OUT/compare-6.txt" 2>&1 || cmp6_rc=$?
  if [ "$lean_s_rc" -ne 0 ] || [ "$rust_s_rc" -ne 0 ]; then
    fail 6 "a site run exited non-zero (lean=$lean_s_rc rust=$rust_s_rc) — see $OUT/site-{lean,rust}.err"
  elif [ "$n_rust_s" -eq 0 ]; then
    # Two empty trees compare identical, which is the shape that goes green
    # having checked nothing.
    fail 6 "the Rust site wrote no file"
  elif [ "$cmp6_rc" -ne 0 ]; then
    fail 6 "$(awk '/^(differing|missing|extra) /{printf "%s %s, ", $3, $1}' "$OUT/compare-6.txt")first name in $OUT/compare-6.txt"
  else
    pass 6 "$n_lean_s files identical, $(find "$OUT/site-lean" -type f -exec cat {} + | wc -c | tr -d ' ') bytes"
  fi
else
  fail 6 "no binary or no IR — item 1 or 2 did not produce one"
fi

say "7/15 the two \`site\` runs print the same stdout"
if [ -s "$OUT/site-lean.out" ] && [ -s "$OUT/site-rust.out" ]; then
  if ! $DIFF_CMD "$OUT/site-rust.out" "$OUT/site-lean.out" >"$OUT/site-summary.diff" 2>&1; then
    fail 7 "stdout differs — see $OUT/site-summary.diff"
    $DIFF_CMD "$OUT/site-rust.out" "$OUT/site-lean.out" >&2 || true
  else
    pass 7 "$(wc -l <"$OUT/site-lean.out" | tr -d ' ') identical line(s)"
  fi
else
  fail 7 "item 6 did not leave two runs' stdout to compare"
fi

# Deliberately **not** guarded on item 6. Guarding it there would make it a
# check that only runs when the two trees already agree — which is when it can
# only restate the Rust site's own consistency, so it could never fail on its
# own. This is the only oracle-free question asked of the Lean tree, and it is
# the one that outlives the oracle: after the Rust half is deleted, item 6 has
# nothing to compare against and this is what is left.
say "8/15 the Lean site closes over itself"
if [ "$(find "$OUT/site-lean" -type f 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
  closure_rc=0
  "$PYTHON" "$ROOT/benchmarks/tools/check-site-closure.py" "$OUT/site-lean" \
    >"$OUT/closure.txt" 2>&1 || closure_rc=$?
  usedby_rc=0
  "$HERE/usedby-gate.sh" --ir "$OUT/build/ir" --site "$OUT/site-lean" \
    >"$OUT/usedby.txt" 2>&1 || usedby_rc=$?
  if [ "$closure_rc" -ne 0 ]; then
    first="$(awk '/FAIL/{print; exit}' "$OUT/closure.txt")"
    # A run that died before printing a table has no FAIL line, and a bare
    # "see the log" is exactly the one-line message this gate may not give.
    [ -n "$first" ] || first="$(tail -1 "$OUT/closure.txt")"
    fail 8 "$first — see $OUT/closure.txt"
  elif [ "$usedby_rc" -ne 0 ]; then
    fail 8 "used-by disagrees with the IR — see $OUT/usedby.txt"
  else
    pass 8 "$(grep -c '^  ok' "$OUT/closure.txt" | tr -d ' ') closure check(s), $(tail -1 "$OUT/usedby.txt")"
  fi
else
  fail 8 "the Lean site is empty or was not written — item 6 says why"
fi

say "9/15 the two \`ledger build\` runs write the same bytes"
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ]; then
  mod_rc=0
  "$LITEDOC4" modules --root "$MICRO" --lib Example --out "$OUT/ledger-modules.txt" \
    >"$OUT/ledger-modules.log" 2>&1 || mod_rc=$?
  ledger_run () {
    local exe="$1" out="$2" name="$3"
    local rc=0
    "$exe" ledger build --modules "$OUT/ledger-modules.txt" --target "$MICRO" \
      --out "$out" --ir "$OUT/build/ir" --source-url "$SOURCE_URL" \
      --link-index "$OUT/build/link-index.lidx" --root "$MICRO" \
      >"$OUT/$name.out" 2>"$OUT/$name.err" || rc=$?
    echo "$rc"
  }
  if [ "$mod_rc" -ne 0 ]; then
    fail 9 "litedoc4 modules exited $mod_rc — see $OUT/ledger-modules.log"
  else
    lean_l_rc="$(ledger_run "$LEAN_EXE" "$OUT/ledger-lean.json" ledger-lean)"
    rust_l_rc="$(ledger_run "$LITEDOC4" "$OUT/ledger-rust.json" ledger-rust)"
    if [ "$lean_l_rc" -ne 0 ] || [ "$rust_l_rc" -ne 0 ]; then
      fail 9 "a ledger build exited non-zero (lean=$lean_l_rc rust=$rust_l_rc) — see $OUT/ledger-{lean,rust}.err"
    elif [ ! -s "$OUT/ledger-rust.json" ]; then
      # Two absent files compare equal, which is the shape that goes green
      # having checked nothing.
      fail 9 "the Rust ledger is empty or missing"
    elif ! cmp -s "$OUT/ledger-rust.json" "$OUT/ledger-lean.json"; then
      fail 9 "$(cmp "$OUT/ledger-rust.json" "$OUT/ledger-lean.json" 2>&1 | head -1) — $OUT/ledger-{rust,lean}.json"
    else
      pass 9 "$(wc -c <"$OUT/ledger-lean.json" | tr -d ' ') bytes identical, $(grep -o '"module":' "$OUT/ledger-lean.json" | wc -l | tr -d ' ') module(s)"
    fi
  fi
else
  fail 9 "no binary or no IR — item 1 or 2 did not produce one"
fi

# Pinned rather than derived: `build` demands 40 lower-case hex after `/blob/`
# (`render` and `site` do not), and deriving it from git HEAD makes the pages
# carry a revision that moves under the gate — a concurrent commit changed all
# 11 pages between two runs while this was being written (measured 2026-08-31).
BUILD_URL="https://github.com/FujiHaruka/litedoc4/blob/0000000000000000000000000000000000000000/e2e/micro"

say "10/15 \`build\` writes the same 23 files, bytes and all"
lean_built_site=""
if [ "$built" -eq 1 ] && [ -x "$EXTRACTOR" ]; then
  rm -rf "$OUT/b-lean" "$OUT/b-rust"
  build_run () {
    local exe="$1" out="$2" name="$3"
    local rc=0
    "$exe" build --root "$MICRO" --lib Example --out "$out" \
      --extractor-bin "$EXTRACTOR" --source-url "$BUILD_URL" \
      >"$OUT/$name.out" 2>"$OUT/$name.err" || rc=$?
    echo "$rc"
  }
  lean_b_rc="$(build_run "$LEAN_EXE" "$OUT/b-lean" b-lean)"
  rust_b_rc="$(build_run "$LITEDOC4" "$OUT/b-rust" b-rust)"
  n_lean_b="$(find "$OUT/b-lean/site" -type f 2>/dev/null | wc -l | tr -d ' ')"
  n_rust_b="$(find "$OUT/b-rust/site" -type f 2>/dev/null | wc -l | tr -d ' ')"
  # Set on "the Lean build wrote a site", deliberately not on "the comparison
  # passed": items 11 and 12 ask oracle-free questions of that tree, and gating
  # them on 10 would make them restate 10 rather than fail on their own.
  [ "$lean_b_rc" -eq 0 ] && [ "$n_lean_b" -gt 0 ] && lean_built_site="$OUT/b-lean/site"
  cmp10_rc=0
  "$HERE/render-compare.sh" --all "$OUT/b-rust/site" "$OUT/b-lean/site" \
    >"$OUT/compare-10.txt" 2>&1 || cmp10_rc=$?
  if [ "$lean_b_rc" -ne 0 ] || [ "$rust_b_rc" -ne 0 ]; then
    fail 10 "a build exited non-zero (lean=$lean_b_rc rust=$rust_b_rc) — see $OUT/b-{lean,rust}.err"
  elif [ "$n_rust_b" -eq 0 ]; then
    fail 10 "the Rust build wrote no file"
  elif [ "$n_rust_b" -ne 23 ]; then
    # Not a style check: the count is the denominator this project quotes, and a
    # site that grew or lost a file silently would still compare identical.
    fail 10 "the Rust build wrote $n_rust_b files, not 23 — the site's shape moved"
  elif [ "$cmp10_rc" -ne 0 ]; then
    fail 10 "$(awk '/^(differing|missing|extra) /{printf "%s %s, ", $3, $1}' "$OUT/compare-10.txt")first name in $OUT/compare-10.txt"
  else
    pass 10 "$n_lean_b files identical, $(find "$OUT/b-lean/site" -type f -exec cat {} + | wc -c | tr -d ' ') bytes"
  fi
else
  fail 10 "no binary or no extractor — item 1 or 2 did not produce one"
fi

say "11/15 the Lean-built site passes site-gate"
if [ -n "$lean_built_site" ]; then
  sg_rc=0
  "$HERE/site-gate.sh" "$lean_built_site" >"$OUT/site-gate.txt" 2>&1 || sg_rc=$?
  if [ "$sg_rc" -ne 0 ]; then
    # `== dead links` is the section heading and says nothing; the line that
    # carries the number is the one worth quoting, and a closure failure has no
    # DEAD line at all, so both shapes are looked for before falling back.
    first="$(awk '/DEAD internal links *: *[1-9]|FAIL/{print; exit}' "$OUT/site-gate.txt")"
    [ -n "$first" ] || first="$(tail -1 "$OUT/site-gate.txt")"
    fail 11 "$(printf '%s' "$first" | sed 's/^ *//') — see $OUT/site-gate.txt"
  else
    pass 11 "$(grep -c '^  ok' "$OUT/site-gate.txt" | tr -d ' ') check(s) over the built tree"
  fi
else
  fail 11 "the Lean build wrote no site — item 10 says why"
fi

say "12/15 the Lean-built site passes config-gate, with either half deriving"
# Run twice over the same Lean-built site. `config-gate.sh` re-derives the three
# trees that write HTML and asks whether the configured title reaches all of
# them, so which binary derives them is a second question the same claim can be
# asked of: once against the Rust half (the cross-implementation oracle) and once
# against the Lean one (which now has `global`, so it can). Not two items — the
# same claim over an input the first spelling cannot reach.
#
# `LITEDOC4` is passed rather than left to the gate's own default, which is
# `target/debug/litedoc4` alone: this gate resolves release-then-debug, and the
# item would otherwise depend on which of the two happens to be on the machine.
if [ -n "$lean_built_site" ]; then
  cg_rc=0
  LITEDOC4="$LITEDOC4" "$HERE/config-gate.sh" --root "$MICRO" --ir "$OUT/b-lean/ir" \
    --built "$lean_built_site" --link-index "$OUT/b-lean/link-index.lidx" \
    --out "$OUT/config" >"$OUT/config-gate.txt" 2>&1 || cg_rc=$?
  cg_lean_rc=0
  LITEDOC4="$LEAN_EXE" "$HERE/config-gate.sh" --root "$MICRO" --ir "$OUT/b-lean/ir" \
    --built "$lean_built_site" --link-index "$OUT/b-lean/link-index.lidx" \
    --out "$OUT/config-lean" >"$OUT/config-gate-lean.txt" 2>&1 || cg_lean_rc=$?
  # Truncated: `config-gate.sh`'s own last line carries the whole differing
  # mapping, which is the right thing in its file and not a line here.
  if [ "$cg_rc" -ne 0 ]; then
    fail 12 "with the Rust half deriving: $(tail -1 "$OUT/config-gate.txt" | cut -c1-120) — see $OUT/config-gate.txt"
  elif [ "$cg_lean_rc" -ne 0 ]; then
    fail 12 "with the Lean half deriving: $(tail -1 "$OUT/config-gate-lean.txt" | cut -c1-120) — see $OUT/config-gate-lean.txt"
  else
    pass 12 "$(tail -1 "$OUT/config-gate.txt" | sed 's/^config *//'); the same with the Lean half deriving"
  fi
else
  fail 12 "the Lean build wrote no site — item 10 says why"
fi

say "13/15 the two builds leave the same litedoc4-build.json"
if [ -n "$lean_built_site" ]; then
  if [ ! -s "$OUT/b-rust/litedoc4-build.json" ]; then
    fail 13 "the Rust build left no marker"
  elif ! cmp -s "$OUT/b-rust/litedoc4-build.json" "$OUT/b-lean/litedoc4-build.json"; then
    fail 13 "$(cmp "$OUT/b-rust/litedoc4-build.json" "$OUT/b-lean/litedoc4-build.json" 2>&1 | head -1) — $OUT/b-{rust,lean}/litedoc4-build.json"
  else
    pass 13 "$(wc -c <"$OUT/b-lean/litedoc4-build.json" | tr -d ' ') bytes identical, irReads $(grep -o '"total":[0-9]*' "$OUT/b-lean/litedoc4-build.json" | head -1 | cut -d: -f2)"
  fi
else
  fail 13 "the Lean build wrote no site, so there is no marker — item 10 says why"
fi

say "14/15 the two \`build\` runs print the same transcript"
if [ -n "$lean_built_site" ] && [ -s "$OUT/b-rust.out" ]; then
  # One sed each, so a rule that stops matching shows up as a difference rather
  # than as silence.
  normalise () {
    sed -e 's/[0-9][0-9]*\.[0-9][0-9]* *s/<t>/g' \
        -e 's/ready [0-9][0-9]*/ready <ns>/' \
        -e "s|$OUT/b-rust|<out>|g" -e "s|$OUT/b-lean|<out>|g" "$1"
  }
  normalise "$OUT/b-rust.out" >"$OUT/t-rust.txt"
  normalise "$OUT/b-lean.out" >"$OUT/t-lean.txt"
  if ! diff -q "$OUT/t-rust.txt" "$OUT/t-lean.txt" >/dev/null 2>&1; then
    fail 14 "$(diff "$OUT/t-rust.txt" "$OUT/t-lean.txt" | head -2 | tr '\n' ' ') — $OUT/t-{rust,lean}.txt"
  else
    pass 14 "$(wc -l <"$OUT/t-lean.txt" | tr -d ' ') line(s) identical after normalising 3 values, the \`serve ready\` generation digest included"
  fi
else
  fail 14 "the Lean build wrote no site — item 10 says why"
fi

say "15/15 --only-from renders that set on both halves, and no more"
# The one failure a byte comparison of two whole renders cannot see: a
# `--only-from` that is accepted and ignored writes exactly the tree items 3 and
# 4 already compare. So the claim here is an inequality as well as an equality —
# the subset has to be **smaller than the whole**, and not empty.
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ] && [ "$n_lean" -gt 1 ]; then
  rm -rf "$OUT/lean-only" "$OUT/rust-only" "$OUT/lean-none" "$OUT/rust-none"
  # Read out of the IR rather than written down here: the sample gains modules,
  # and a name spelt in this file would go stale without failing.
  "$PYTHON" - "$OUT/build/ir/index.json" >"$OUT/only-from.txt" <<'ONLY'
import json, sys
index = json.load(open(sys.argv[1]))
for entry in index["modules"][:1]:
    print(entry["module"])
ONLY
  : >"$OUT/only-none.txt"
  lean_o_rc="$(render "$LEAN_EXE" "$OUT/lean-only" lean-only --link-index "$OUT/build/link-index.lidx" --only-from "$OUT/only-from.txt")"
  rust_o_rc="$(render "$LITEDOC4" "$OUT/rust-only" rust-only --link-index "$OUT/build/link-index.lidx" --only-from "$OUT/only-from.txt")"
  lean_e_rc="$(render "$LEAN_EXE" "$OUT/lean-none" lean-none --link-index "$OUT/build/link-index.lidx" --only-from "$OUT/only-none.txt")"
  rust_e_rc="$(render "$LITEDOC4" "$OUT/rust-none" rust-none --link-index "$OUT/build/link-index.lidx" --only-from "$OUT/only-none.txt")"
  n_only_lean="$(html_count "$OUT/lean-only")"
  n_only_rust="$(html_count "$OUT/rust-only")"
  cmp15_rc=0
  "$HERE/render-compare.sh" "$OUT/rust-only" "$OUT/lean-only" >"$OUT/compare-15.txt" 2>&1 || cmp15_rc=$?
  wanted="$(wc -l <"$OUT/only-from.txt" | tr -d ' ')"
  if [ "$lean_o_rc" -ne 0 ] || [ "$rust_o_rc" -ne 0 ]; then
    fail 15 "a --only-from render exited non-zero (lean=$lean_o_rc rust=$rust_o_rc) — see $OUT/{lean,rust}-only.err"
  elif [ "$n_only_lean" -ne "$wanted" ] || [ "$n_only_rust" -ne "$wanted" ]; then
    fail 15 "--only-from named $wanted module(s) and got lean $n_only_lean / rust $n_only_rust page(s) — a set that is ignored renders all $n_lean"
  elif [ "$cmp15_rc" -ne 0 ]; then
    fail 15 "the two subsets differ: $(awk '/^(differing|missing|extra) /{printf "%s %s, ", $3, $1}' "$OUT/compare-15.txt")see $OUT/compare-15.txt"
  elif [ "$lean_e_rc" -ne "$rust_e_rc" ]; then
    fail 15 "an empty --only-from exited differently (lean=$lean_e_rc rust=$rust_e_rc)"
  elif [ "$(html_count "$OUT/lean-none")" -ne 0 ] || [ "$(html_count "$OUT/rust-none")" -ne 0 ]; then
    fail 15 "an empty --only-from wrote pages (lean $(html_count "$OUT/lean-none"), rust $(html_count "$OUT/rust-none")) — it has to mean render nothing, not render everything"
  else
    pass 15 "$wanted of $n_lean page(s) written and identical; an empty set writes none on both"
  fi
else
  fail 15 "item 3 did not leave a whole render of more than one page to compare a subset against"
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
