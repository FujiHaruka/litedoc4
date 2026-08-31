#!/usr/bin/env bash
# Does the Lean half write the bytes e2e/micro's documentation is made of?
#
# `purelean-render-gate.sh` asks the same question over the measurement target
# and is therefore `manual`. This one is `ci`, and it is not a smaller version of
# it: **e2e/micro holds the declaration shapes the target does not have**
# (`e2e/README.md`), and the items below fire on shapes 432 modules of
# Mathlib-depending Lean never produce. A comparison over the target alone is
# green over every one of them.
#
# **The oracle was the Rust binary, and M10 deletes it.** What it wrote is frozen
# under `e2e/micro-expected/`, minted from it while it was still there. Two arms,
# and they are not the same claim:
#
#   ITEMS     the Lean half writes the frozen bytes, and its own two paths agree
#             wherever a second implementation was never needed to ask. This is
#             the gate. It reads `e2e/micro-expected/` and the tree and nothing
#             else, so all 16 items go on being questions once `crates/` is gone.
#   RUST ARM  the frozen bytes are still what the Rust binary says, and the two
#             halves still agree on the two things nothing can be frozen from.
#             This one **expires at M10** — it is the check that the fixture did
#             not rot while the oracle was still there to ask. A missing Rust
#             binary is a skip **with the count it did not check**, never a pass:
#             while `crates/` exists, `cargo build --bin litedoc4` is all it takes.
#
# **Counted in both directions.** The items reconcile against 16 as they always
# did, and the frozen files compared reconcile against the files in the fixture.
# A frozen file no item reads and an item that compared nothing are the same bug
# from two ends, and the second is the one a data-driven gate keeps being bitten
# by: a comparison of two empty trees is `IDENTICAL`.
#
# **One normaliser — `normalise` — used by both arms and by `--mint`.** Only the
# six text artefacts go through it; the trees are compared byte for byte. What it
# replaces, and why each moves for a reason that is not the port's:
#
#   <out>   the run's own `--out`, which differs per run
#   <root>  this checkout's path, which differs per machine
#   <t>     a duration
#   <ns>    the `serve ready` monotonic clock reading
#   <gen>   the `serve ready` generation digest
#   <sha>   every sha256 the ledger records
#   <n>     the size the ledger records for each olean
#
# The last three go together, and the reason is not that they are noisy: **all
# three are taken over the target's build products**, not over anything this
# repository holds. Lake's `<file>.hash` and the olean it sits beside are
# architecture-specific, so a value minted on one machine is one another cannot
# reproduce. None of the three is dropped — item 9 recomputes every ledger
# digest and every size here, in Python, from the bytes each one names, and item
# 14 holds the generation digest to the one item 2's build printed.
#
# **What the oracle took with it.** Three claims cannot be carried by a frozen
# file, and are written down here rather than quietly replaced by something that
# passes:
#
#   - that **two independent readers agree on the generation digest**. It is a
#     digest over Lake's own `<file>.hash` beside every olean, and with one
#     reader left nothing can disagree with it. What is asked instead is that two
#     full builds in this run agree — which falsifies a digest taken over a
#     directory in filesystem order, or one with a clock mixed in, and does not
#     falsify a digest taken over the wrong files.
#   - that **the two halves derive `litedoc4.toml` the same way** (item 12's
#     second spelling). It is in the Rust arm and expires with it.
#   - that **the two halves compute `renderKey.externalLinks` the same way**. It
#     is the one ledger digest whose input is not a file on disk, so item 9
#     normalises it and recomputes the twenty-four beside it.
#
# What a failing item means:
#   1 BUILDS    `lake build litedoc4/litedoc4` in e2e/consumer produced no
#               binary: there is no Lean renderer to ask anything of.
#   2 IR        the sample's IR was not extracted, so there is nothing to render.
#               Extracted by the **Lean** half — after M10 there is no other
#               driver, and every frozen artefact below was minted from this
#               same IR, so a `build` that extracted something else fails here
#               rather than as eleven differing pages.
#   3 PAGES     the pages differ from `e2e/micro-expected/render/`. Two claims,
#               because the frozen bytes cannot ask the second: the bytes are
#               the frozen ones, and **rendering the same IR with a trailing
#               slash on `--source-url` writes the same tree again**. `render`
#               and `site` accept any non-empty URL, and the Lean renderer was
#               writing `…/e2e/micro//Mod.lean` for the second spelling while
#               every gate passed, because they all pass the first (measured
#               2026-08-31). `build` cannot reach it — it demands 40 hex and
#               builds the base itself.
#   4 REFUSAL   with `--no-link-index` the run disagrees with the frozen
#               refusal. `Example.Preferred` extends `Inhabited`, whose defining
#               module the sample does not declare, so the name is in no map at
#               all and the run must stop rather than invent an `href`
#               (`UnplaceableName`). The exit code, the whole of stderr and the
#               pages written before stopping are all frozen. If the run exits 0
#               this item fails too: the sample has stopped covering the branch,
#               which is the failure that hides all the others.
#   5 SUMMARY   `render`'s stdout differs from the frozen transcript. The pages
#               can agree while a silent fallback goes unreported — `math spans
#               kept as LaTeX` is exactly such a line — so the bytes are not the
#               whole answer. Frozen whole, not from the first counts line: the
#               dependency link map is reported above them and nowhere else.
#   6 SITE      `litedoc4 site` writes the pages *and* the nine whole-package
#               artifacts, and the tree differs from `render/` + `site/`. The
#               fixture holds the pages once: `site`'s copies are compared
#               against the same frozen bytes item 3 uses, so a page defect is
#               reported by one item rather than two, and what is left here is
#               the artifacts — four of them JSON and one binary, which a
#               comparison seeing only `*.html` would call identical while the
#               search indexes disagreed.
#   7 SITE SUM  `site`'s stdout differs from the frozen transcript.
#   8 CLOSURE   the Lean site does not close over itself. `check-site-closure.py`
#               asks whether the index, the search index and the pages agree
#               about which declarations exist **in both directions**, and
#               `usedby-gate.sh` asks the same of `used-by.json` against the IR.
#               Neither is a byte comparison: a site can match the frozen bytes
#               and still contradict itself, and could before the freeze too.
#               The dead-link half of `site-gate.sh` is deliberately not here —
#               `style.css` and `favicon.svg` are written by `build`, not by
#               `site` (measured 2026-08-31 ->
#               `benchmarks/results/purelean-site-boundary-2026-08-31.txt`), so a
#               bare `site` tree fails it by construction. That half is item 11.
#   9 LEDGER    `ledger build` disagrees with the frozen ledger. Two claims.
#               **Shape**: compared whole against `ledger.json` after
#               normalising the digests — key order is insertion order rather
#               than sorted, and a comparison that parsed both would stop seeing
#               that. **Digests**: every sha256 in it is recomputed here from
#               the bytes it names — each olean, `lake-manifest.json`, the
#               `.lidx` handed to the run, and each module's composition of its
#               files' digests. Normalising a digest and then not recomputing it
#               would leave the ledger's whole reason for existing unchecked:
#               this is what M5's incremental path reads to decide what is
#               stale, so a digest over the wrong bytes is a build that later
#               re-extracts everything or, worse, nothing.
#  10 BUILD     `build` writes 23 files and one of them differs. This is the
#               whole pipeline rather than `site` again: it globs the sources,
#               reads `lakefile.toml`, derives the external link map from the
#               manifest (`site` above is given no `--root` and derives none),
#               drives the resident extractor, writes the assets and the ledger,
#               and leaves a marker. The 23 are assembled from three places, and
#               two of them are claims: 15 files are frozen; 5 whole-package
#               artifacts are taken from the frozen `site/`, so the tree says
#               `build` and `site` write them identically; and the 3 assets are
#               taken from `assets/`, because a second frozen copy of `app.js`
#               is the one duplication `assets-embed-gate.sh` exists to stop.
#  11 SITEGATE  `site-gate.sh` fails on the Lean-built site. It is the dead-link
#               half item 8 cannot ask: a bare `site` tree has no `style.css`,
#               so the question only becomes answerable once `build` has written
#               them. Oracle-free, and it was before the freeze too.
#  12 CONFIG    `config-gate.sh` fails on the built site. `litedoc4.toml`'s title
#               and index prose have to reach the pages the same way from every
#               command that writes HTML, and the gate re-derives the three
#               trees to ask it. Run with the **Lean** half deriving; the same
#               question with the Rust half deriving is in the arm below, and
#               expires with it.
#  13 MARKER    `litedoc4-build.json` differs from the frozen marker. Compared
#               whole, and that includes `work.irReads` — counts of how many
#               times each reader opened the IR. They are a property of the
#               reader's call pattern, not of the output, so a reader that took
#               a different number of passes shows up here and nowhere else.
#  14 BUILD OUT `build`'s transcript differs from the frozen one. Item 10
#               compares files; nothing compared what the command *said*, and
#               that is where `global … state 0 B` sat for a while against
#               Rust's `state 10499 B` with every item green. Five values are
#               normalised (see `normalise` above) and the sixth claim is the
#               `serve ready` generation digest, held against the one item 2's
#               build printed: it is the guard that stops a `lake build` landing
#               mid-run from being extracted from, and two full builds of an
#               unchanged sample have to agree on it.
#  15 ONLY      `--only-from` did not narrow the render. **No oracle at all, and
#               none is needed**: the subset has to be byte-identical to the
#               same pages of the whole render this run already did, and smaller
#               than it. Either claim alone is satisfied by a wrong
#               implementation — a `--only-from` that is accepted and ignored
#               writes exactly the tree item 3 compares, and one that silently
#               drops everything writes nothing and would agree too. The empty
#               set is checked beside it: an empty file has to mean render
#               nothing and exit 0, which is what the pipeline hands it when a
#               round finds no page stale. The names come out of the IR, not out
#               of this file, so a growing sample cannot leave a stale spelling
#               here.
#  16 INCR      the incremental path. Three more runs of the Lean half: a build,
#               `ledger touch` on one module, a second build, and a full build
#               beside it. Two claims — `onemod-gate.sh` (the edit was noticed,
#               fewer pages than modules were rewritten, the dependency map was
#               reused) and, the stronger one, that the incremental site is byte
#               for byte a full build's. `touch` invalidates a ledger entry
#               rather than editing the sample, so the IR is unchanged and the
#               two sites must agree; a round that re-rendered too little writes
#               a site stale in exactly the pages nobody opens, with every count
#               in the marker still plausible. It never had an oracle and does
#               not have one now.
#
# Re-minting is `--mint`, and it takes the binary to mint from. **Mint from the
# Rust half.** After M10 there is nothing to mint from, and minting from the Lean
# half records whatever it does today, which is the question rather than the
# answer — the one case where that is still the right move is an edit to
# `e2e/micro` itself, and then only from a tree that was green immediately
# before the edit. `--mint` refuses unless the two halves extract the same IR
# and build the same link index, so a fixture is never minted on top of an input
# only one of them agrees with.
#
# usage: purelean-micro-gate.sh [--out DIR] [--keep]
#        purelean-micro-gate.sh --mint [--from PATH] [--out DIR] [--keep]
#   --out   working directory (default: a temporary one, removed on success)
#   --keep  do not remove a temporary --out
#   --mint  rewrite e2e/micro-expected/ from --from
#   --from  the binary --mint reads (default: the same as LITEDOC4)
#
#   LITEDOC4  the Rust litedoc4: the arm that expires, and what --mint reads
#             (default target/release/litedoc4, else target/debug/litedoc4;
#             absent is a skip, not a failure)
#   LAKE      the lake executable (default: ~/.elan/bin/lake)
#   PYTHON    the python3 items 8, 9 and 15 run their checks with (default python3)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
FIXTURE="$ROOT/e2e/consumer"
MICRO="$ROOT/e2e/micro"
FROZEN="$ROOT/e2e/micro-expected"
LAKE="${LAKE:-$HOME/.elan/bin/lake}"
PYTHON="${PYTHON:-python3}"
LEAN_EXE="$ROOT/.lake/build/bin/litedoc4"
# `diff` is aliased to a colordiff that is not installed here, and its exit 127
# reads as "differences found".
DIFF_CMD=/usr/bin/diff

# The five whole-package artifacts `build` and `site` write identically, and the
# three assets only `build` writes. Named once: `stage_oracle` checks each one
# really is a copy before leaving it out of the fixture, and item 10 puts it
# back. A name that stops being a copy fails at both ends rather than being
# frozen twice.
BUILD_SHARED="declarations/name-map.json declarations/used-by.json instances.json modules.json search-index.bin"
BUILD_ASSETS="app.js style.css favicon.svg"

if [ -z "${LITEDOC4:-}" ]; then
  if [ -x "$ROOT/target/release/litedoc4" ]; then
    LITEDOC4="$ROOT/target/release/litedoc4"
  elif [ -x "$ROOT/target/debug/litedoc4" ]; then
    LITEDOC4="$ROOT/target/debug/litedoc4"
  else
    LITEDOC4=""
  fi
fi

# Fixed, not derived from git: the URL is baked into every `source` link, and a
# fixture whose expected bytes move with HEAD compares two checkouts as well as
# two renderers. Every run below is handed one of these two strings.
SOURCE_URL="https://github.com/FujiHaruka/litedoc4/blob/HEAD/e2e/micro"
# Pinned rather than derived for the same reason and one more: `build` demands 40
# lower-case hex after `/blob/` (`render` and `site` do not), and a revision from
# git HEAD moves under the gate — a concurrent commit changed all 11 pages
# between two runs while this was being written (measured 2026-08-31).
BUILD_URL="https://github.com/FujiHaruka/litedoc4/blob/0000000000000000000000000000000000000000/e2e/micro"

OUT=""
KEEP=0
MINT=0
FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --mint) MINT=1; shift ;;
    --from) FROM="$2"; shift 2 ;;
    -h|--help) sed -n '/^# usage:/,/^set -/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Hard exits rather than skips: an item that prints "no input" and returns 0 does
# not reach the exit code, which is how a gate goes green having checked nothing.
[ -x "$LAKE" ] || { echo "no lake at $LAKE — set LAKE" >&2; exit 2; }
[ -f "$MICRO/lakefile.toml" ] || [ -f "$MICRO/lakefile.lean" ] || { echo "no sample package at $MICRO" >&2; exit 2; }
[ -f "$FIXTURE/lakefile.toml" ] || { echo "no consumer fixture at $FIXTURE" >&2; exit 2; }
[ -d "$FROZEN" ] || { echo "no frozen output at $FROZEN — the items have nothing to compare against" >&2; exit 2; }

if [ "$MINT" -eq 1 ]; then
  mkdir -p "$FROZEN"
else
  # A missing part of the fixture is an exit, not a failing item: `cp` of a
  # directory that is not there would abort the script somewhere further down,
  # under whichever item happened to reach it first.
  for part in render nolidx site build; do
    [ -d "$FROZEN/$part" ] ||
      { echo "no $FROZEN/$part — the fixture is incomplete; re-mint it with --mint while a Rust litedoc4 exists" >&2; exit 2; }
  done
  # An empty fixture reconciles 0 against 0 and compares empty trees against
  # empty trees. Several items would still fail on their own counts, but this is
  # the shape itself, said once.
  [ "$( ( cd "$FROZEN" && find . -type f ! -name 'README.md' ) | wc -l | tr -d ' ')" -gt 0 ] ||
    { echo "$FROZEN holds no frozen file — every item below would compare against nothing" >&2; exit 2; }
fi

if [ "$MINT" -eq 1 ]; then
  [ -n "$FROM" ] || FROM="$LITEDOC4"
  if [ -z "$FROM" ] || [ ! -x "$FROM" ]; then
    echo "purelean-micro-gate: --mint needs a Rust litedoc4 to mint from (--from <path>, or cargo build --bin litedoc4)" >&2
    exit 2
  fi
fi

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d)"
  TEMPORARY=1
else
  mkdir -p "$OUT"
  TEMPORARY=0
fi

IR="$OUT/build/ir"
LIDX="$OUT/build/link-index.lidx"

ITEMS=16
ran=0
failed=0
: >"$OUT/frozen-used.txt"

pass () { ran=$((ran + 1)); printf 'ITEM %s ok    %s\n' "$1" "$2"; }
fail () { ran=$((ran + 1)); failed=$((failed + 1)); printf 'ITEM %s FAIL  %s\n' "$1" "$2" >&2; }
say  () { printf '\n=== %s\n' "$1"; }

html_count () { find "$1" -type f -name '*.html' 2>/dev/null | wc -l | tr -d ' '; }
file_count () { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

# The one normaliser. `$2` is the directory the run under inspection wrote to,
# which is the only part of a transcript that differs between the two arms; every
# other rule is the same string for both, so a rule that stops matching shows up
# as a difference rather than as silence.
normalise () {
  sed -e "s|$2|<out>|g" \
      -e "s|$ROOT|<root>|g" \
      -e 's/[0-9][0-9]*\.[0-9][0-9]* *s/<t>/g' \
      -e 's/ready [0-9][0-9]*/ready <ns>/' \
      -e 's/generation [0-9a-f][0-9a-f]*/generation <gen>/' \
      -e 's/"hash":"[0-9a-f]\{64\}"/"hash":"<sha>"/g' \
      -e 's/"manifestSha256":"[0-9a-f]\{64\}"/"manifestSha256":"<sha>"/g' \
      -e 's/"linkIndex":"[0-9a-f]\{64\}"/"linkIndex":"<sha>"/g' \
      -e 's/"externalLinks":"[0-9a-f]\{64\}"/"externalLinks":"<sha>"/g' \
      -e 's/"bytes":-\{0,1\}[0-9][0-9]*/"bytes":<n>/g' \
      "$1"
}

# Every frozen file an item compared, so the summary can reconcile the fixture
# against what was read. Counted from the paths themselves rather than from a
# per-item tally: an item that compares a tree does not know how many files were
# in it, and a tally it wrote down would be the item grading its own reading.
used () { printf '%s\n' "$@" >>"$OUT/frozen-used.txt"; }
used_tree () { ( cd "$FROZEN/$1" && find . -type f | sed "s|^\./|$1/|" ) >>"$OUT/frozen-used.txt"; }

# Compare a live tree against frozen bytes, and say which file and where.
compare_frozen_tree () { # <expected-dir> <live-dir> <report>
  local rc=0
  "$HERE/render-compare.sh" --all "$1" "$2" >"$3" 2>&1 || rc=$?
  echo "$rc"
}
# A gate may not answer "something differs, look in this file". These three say
# which name, or where in the line, in the one line the summary gets.
first_difference () { awk '/^(differing|missing|extra) /{printf "%s %s, ", $3, $1}' "$1" || true; }
first_name () { awk '/^--- (differing|missing|extra)/{getline; print; exit}' "$1" || true; }
# `|| true`: `pipefail` is on, and a grep that matches nothing would make an
# assignment fail and, under `set -e`, cut the message short instead of printing
# an empty one.
line_gist () { grep -E '^[<>]' "$1" | head -2 | cut -c1-90 | tr '\n' ' ' || true; }
# Windowed on the first differing byte rather than on the start of the line: the
# ledger and the marker are one line each, and a fixed prefix would print the
# same 90 identical characters for a difference 3 kB in.
byte_gist () { # <frozen> <live>
  local at
  at="$(cmp "$1" "$2" 2>/dev/null | sed -n 's/.*char \([0-9][0-9]*\).*/\1/p' || true)"
  if [ -z "$at" ]; then
    printf 'one is a prefix of the other (%s vs %s bytes)' "$(wc -c <"$1" | tr -d ' ')" "$(wc -c <"$2" | tr -d ' ')"
  else
    printf 'at byte %s: frozen "%s", got "%s"' "$at" \
      "$(tail -c "+$at" "$1" | head -c 60 | tr -d '\n')" \
      "$(tail -c "+$at" "$2" | head -c 60 | tr -d '\n')"
  fi
}

# No pipe between the command and the status this gate judges on: through a pipe
# the status read back is the last command's, and `litedoc4` exiting 1 looks
# like 0 (measured 2026-08-18).
render () {
  local exe="$1" pages="$2" name="$3"; shift 3
  local rc=0
  "$exe" render --ir "$IR" --pages "$pages" --source-url "$SOURCE_URL" "$@" \
    >"$OUT/$name.out" 2>"$OUT/$name.err" || rc=$?
  echo "$rc"
}

say "1/16 the Lean half builds from a consumer's workspace"
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

say "2/16 the sample's IR, extracted here by the Lean half"
extracted=0
(cd "$MICRO" && "$LAKE" build) >"$OUT/micro-build.log" 2>&1
EXTRACTOR="$(micro_extractor "$ROOT" "$MICRO" "$LAKE" "$OUT/extractor-build.log")"
if [ ! -x "$EXTRACTOR" ]; then
  fail 2 "no extractor at $EXTRACTOR — see $OUT/extractor-build.log"
elif [ "$built" -ne 1 ]; then
  fail 2 "no Lean binary to extract with — item 1 says why"
else
  rm -rf "$OUT/build"
  ir_rc=0
  "$LEAN_EXE" build --root "$MICRO" --lib Example --out "$OUT/build" \
    --extractor-bin "$EXTRACTOR" --source-url "$BUILD_URL" >"$OUT/ir.log" 2>&1 || ir_rc=$?
  n_ir="$(find "$IR/modules" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$ir_rc" -ne 0 ]; then
    fail 2 "litedoc4 build exited $ir_rc — see $OUT/ir.log"
    tail -20 "$OUT/ir.log" >&2
  elif [ "$n_ir" -eq 0 ]; then
    # Every frozen tree below was minted from an IR; over an empty one the whole
    # gate compares empty trees against a fixture that is not there either.
    fail 2 "the IR has no module file — there is nothing for items 3 to 15 to render"
  else
    pass 2 "$n_ir module(s) and $(wc -c <"$LIDX" | tr -d ' ') bytes of link index"
    extracted=1
  fi
fi

# Run the Rust binary through every flow the fixture holds and lay the results
# out exactly as `e2e/micro-expected/` is laid out. `--mint` copies the result
# in; the arm compares it. One body, so the two cannot drift — a rule the arm
# applies and the mint does not is a fixture that can never match.
stage_oracle () { # <dest> <work> <binary>
  local dest="$1" work="$2" exe="$3" rc=0 f=""
  rm -rf "$dest" "$work"
  mkdir -p "$dest/render" "$dest/nolidx" "$dest/site" "$dest/build" "$work"

  "$exe" render --ir "$IR" --pages "$dest/render" --source-url "$SOURCE_URL" \
    --link-index "$LIDX" >"$work/render.out" 2>"$work/render.err" || rc=$?
  [ "$rc" -eq 0 ] || { echo "oracle: render exited $rc — see $work/render.err" >&2; return 1; }
  [ "$(html_count "$dest/render")" -gt 0 ] || { echo "oracle: render wrote no page" >&2; return 1; }
  normalise "$work/render.out" "$dest/render" >"$dest/render.out"

  rc=0
  "$exe" render --ir "$IR" --pages "$dest/nolidx" --source-url "$SOURCE_URL" \
    --no-link-index >"$work/nolidx.out" 2>"$work/nolidx.err" || rc=$?
  [ "$rc" -ne 0 ] || { echo "oracle: --no-link-index exited 0 — e2e/micro no longer carries a name in no module, and there is no refusal to freeze" >&2; return 1; }
  printf '%s\n' "$rc" >"$dest/nolidx.exit"
  normalise "$work/nolidx.err" "$dest/nolidx" >"$dest/nolidx.err"

  rc=0
  "$exe" site --ir "$IR" --out "$work/site" --source-url "$SOURCE_URL" \
    --link-index "$LIDX" >"$work/site.out" 2>"$work/site.err" || rc=$?
  [ "$rc" -eq 0 ] || { echo "oracle: site exited $rc — see $work/site.err" >&2; return 1; }
  normalise "$work/site.out" "$work/site" >"$dest/site.out"
  # The pages are render's, and the fixture holds them once. Checked rather than
  # assumed: if `site` ever writes a page `render` does not, leaving it out here
  # would freeze a site that is missing it.
  ( cd "$work/site" && find . -type f | sort ) >"$work/site-list.txt"
  while IFS= read -r f; do
    if [ -f "$dest/render/$f" ]; then
      cmp -s "$work/site/$f" "$dest/render/$f" ||
        { echo "oracle: site's $f is no longer render's — the fixture cannot hold the pages once" >&2; return 1; }
    else
      mkdir -p "$(dirname "$dest/site/$f")"
      cp "$work/site/$f" "$dest/site/$f"
    fi
  done <"$work/site-list.txt"

  rc=0
  "$exe" build --root "$MICRO" --lib Example --out "$work/b" \
    --extractor-bin "$EXTRACTOR" --source-url "$BUILD_URL" \
    >"$work/build.out" 2>"$work/build.err" || rc=$?
  [ "$rc" -eq 0 ] || { echo "oracle: build exited $rc — see $work/build.err" >&2; return 1; }
  normalise "$work/build.out" "$work/b" >"$dest/build.out"
  normalise "$work/b/litedoc4-build.json" "$work/b" >"$dest/marker.json"
  for f in $BUILD_SHARED; do
    cmp -s "$work/b/site/$f" "$dest/site/$f" ||
      { echo "oracle: build's $f is no longer site's — take it out of BUILD_SHARED" >&2; return 1; }
  done
  for f in $BUILD_ASSETS; do
    cmp -s "$work/b/site/$f" "$ROOT/assets/$f" ||
      { echo "oracle: build's $f is no longer assets/$f — take it out of BUILD_ASSETS" >&2; return 1; }
  done
  ( cd "$work/b/site" && find . -type f | sort ) >"$work/build-list.txt"
  while IFS= read -r f; do
    case " $BUILD_SHARED $BUILD_ASSETS " in
      *" ${f#./} "*) continue ;;
    esac
    mkdir -p "$(dirname "$dest/build/$f")"
    cp "$work/b/site/$f" "$dest/build/$f"
  done <"$work/build-list.txt"

  rc=0
  "$exe" ledger build --modules "$OUT/ledger-modules.txt" --target "$MICRO" \
    --out "$work/ledger.json" --ir "$IR" --source-url "$SOURCE_URL" \
    --link-index "$LIDX" --root "$MICRO" >"$work/ledger.out" 2>"$work/ledger.err" || rc=$?
  [ "$rc" -eq 0 ] || { echo "oracle: ledger build exited $rc — see $work/ledger.err" >&2; return 1; }
  normalise "$work/ledger.json" "$work/ledger.json" >"$dest/ledger.json"
  return 0
}

# The module list both halves' `ledger build` is handed. Produced by the Lean
# half for the same reason item 2 is: after M10 there is no other producer, and
# two ledgers built over two different lists would differ for a reason that is
# not the port's.
modules_ok=0
if [ "$extracted" -eq 1 ]; then
  mod_rc=0
  "$LEAN_EXE" modules --root "$MICRO" --lib Example --out "$OUT/ledger-modules.txt" \
    >"$OUT/ledger-modules.log" 2>&1 || mod_rc=$?
  [ "$mod_rc" -eq 0 ] && [ -s "$OUT/ledger-modules.txt" ] && modules_ok=1
fi

if [ "$MINT" -eq 1 ]; then
  say "mint"
  if [ "$extracted" -ne 1 ] || [ "$modules_ok" -ne 1 ]; then
    echo "purelean-micro-gate: --mint needs the sample's IR and module list; items 1 and 2 above say why" >&2
    exit 1
  fi
  # The IR the fixture is minted over is the Lean half's, because that is the
  # one the items will use. Minting on top of an extraction only one half agrees
  # with would freeze the Rust renderer's answer to the wrong question.
  rust_ir_rc=0
  rm -rf "$OUT/mint-ir"
  "$FROM" build --root "$MICRO" --lib Example --out "$OUT/mint-ir" \
    --extractor-bin "$EXTRACTOR" --source-url "$BUILD_URL" >"$OUT/mint-ir.log" 2>&1 || rust_ir_rc=$?
  if [ "$rust_ir_rc" -ne 0 ]; then
    echo "purelean-micro-gate: --mint could not extract with $FROM (exit $rust_ir_rc) — see $OUT/mint-ir.log" >&2
    exit 1
  fi
  if ! $DIFF_CMD -r "$OUT/mint-ir/ir" "$IR" >"$OUT/mint-ir.diff" 2>&1; then
    echo "purelean-micro-gate: --mint refuses — the two halves extract different IR: $(head -1 "$OUT/mint-ir.diff")" >&2
    exit 1
  fi
  if ! cmp -s "$OUT/mint-ir/link-index.lidx" "$LIDX"; then
    echo "purelean-micro-gate: --mint refuses — the two halves build different link indexes: $(cmp "$OUT/mint-ir/link-index.lidx" "$LIDX" 2>&1 | head -1)" >&2
    exit 1
  fi
  if ! stage_oracle "$OUT/mint" "$OUT/mint-work" "$FROM"; then
    echo "purelean-micro-gate: --mint produced nothing; nothing was written" >&2
    exit 1
  fi
  ( cd "$OUT/mint" && find . -type f | sed 's|^\./||' | sort ) >"$OUT/mint-list.txt"
  ( cd "$FROZEN" && find . -type f ! -name 'README.md' | sed 's|^\./||' | sort ) >"$OUT/frozen-list.txt"
  n_minted="$(wc -l <"$OUT/mint-list.txt" | tr -d ' ')"
  [ "$n_minted" -gt 0 ] || { echo "purelean-micro-gate: --mint staged 0 files; nothing was written" >&2; exit 1; }
  changed=0; added=0
  while IFS= read -r f; do
    if [ -f "$FROZEN/$f" ]; then
      cmp -s "$OUT/mint/$f" "$FROZEN/$f" || changed=$((changed + 1))
    else
      added=$((added + 1))
    fi
  done <"$OUT/mint-list.txt"
  /usr/bin/comm -23 "$OUT/frozen-list.txt" "$OUT/mint-list.txt" >"$OUT/mint-removed.txt"
  removed="$(wc -l <"$OUT/mint-removed.txt" | tr -d ' ')"
  find "$FROZEN" -mindepth 1 ! -name 'README.md' -delete
  cp -R "$OUT/mint/." "$FROZEN/"
  printf 'PURELEAN MICRO GATE: minted %s file(s) from %s — %s changed, %s added, %s removed\n' \
    "$n_minted" "$FROM" "$changed" "$added" "$removed"
  if [ "$removed" -gt 0 ]; then
    sed 's/^/  removed /' "$OUT/mint-removed.txt"
  fi
  if [ "$TEMPORARY" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
    rm -rf "$OUT"
  fi
  exit 0
fi

say "3/16 the pages are the frozen bytes, and a trailing slash writes them again"
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ]; then
  rm -rf "$OUT/lean" "$OUT/lean-slash"
  lean_rc="$(render "$LEAN_EXE" "$OUT/lean" lean --link-index "$LIDX")"
  n_lean="$(html_count "$OUT/lean")"
  cmp_rc="$(compare_frozen_tree "$FROZEN/render" "$OUT/lean" "$OUT/compare-3.txt")"
  used_tree render
  # The same claim over an input the first spelling cannot reach, and the one
  # half of this item that never needed an oracle: both URLs name the same file,
  # so the two trees have to be the same bytes.
  lean_s2_rc="$(SOURCE_URL="$SOURCE_URL/" render "$LEAN_EXE" "$OUT/lean-slash" lean-slash --link-index "$LIDX")"
  cmp_slash_rc=0
  $DIFF_CMD -r "$OUT/lean" "$OUT/lean-slash" >"$OUT/compare-3-slash.txt" 2>&1 || cmp_slash_rc=$?
  if [ "$lean_rc" -ne 0 ]; then
    fail 3 "render exited $lean_rc — see $OUT/lean.err"
  elif [ "$n_lean" -eq 0 ]; then
    fail 3 "render wrote no page"
  elif [ "$cmp_rc" -ne 0 ]; then
    fail 3 "$(first_difference "$OUT/compare-3.txt")first is $(first_name "$OUT/compare-3.txt") — see $OUT/compare-3.txt"
  elif [ "$lean_s2_rc" -ne 0 ]; then
    fail 3 "a render with a trailing slash on --source-url exited $lean_s2_rc — see $OUT/lean-slash.err"
  elif [ "$cmp_slash_rc" -ne 0 ]; then
    fail 3 "a trailing slash on --source-url writes a different tree: $(head -1 "$OUT/compare-3-slash.txt")"
  else
    pass 3 "$n_lean frozen page(s), $(find "$OUT/lean" -type f -name '*.html' -exec cat {} + | wc -c | tr -d ' ') bytes; the same tree again with a trailing slash on --source-url"
  fi
else
  fail 3 "no binary or no IR — item 1 or 2 did not produce one"
fi

say "4/16 with --no-link-index it refuses the frozen way"
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ]; then
  rm -rf "$OUT/lean-nolidx"
  lean_n_rc="$(render "$LEAN_EXE" "$OUT/lean-nolidx" lean-nolidx --no-link-index)"
  normalise "$OUT/lean-nolidx.err" "$OUT/lean-nolidx" >"$OUT/lean-nolidx.norm"
  cmp4_rc="$(compare_frozen_tree "$FROZEN/nolidx" "$OUT/lean-nolidx" "$OUT/compare-4.txt")"
  used_tree nolidx
  used nolidx.err nolidx.exit
  want_exit="$(tr -d ' \n' <"$FROZEN/nolidx.exit")"
  if [ "$lean_n_rc" -eq 0 ]; then
    fail 4 "the render exited 0: e2e/micro no longer carries a name in no module, so this item and the refusal it freezes are both untested"
  elif [ "$lean_n_rc" != "$want_exit" ]; then
    fail 4 "exit $lean_n_rc, frozen $want_exit; it said: $(head -1 "$OUT/lean-nolidx.err" 2>/dev/null)"
  elif ! $DIFF_CMD "$FROZEN/nolidx.err" "$OUT/lean-nolidx.norm" >"$OUT/refusal.diff" 2>&1; then
    fail 4 "it exited $lean_n_rc and said something else — see $OUT/refusal.diff"
  elif [ "$cmp4_rc" -ne 0 ]; then
    fail 4 "the pages written before stopping differ: $(first_difference "$OUT/compare-4.txt")first is $(first_name "$OUT/compare-4.txt") — see $OUT/compare-4.txt"
  else
    pass 4 "exit $lean_n_rc after $(html_count "$OUT/lean-nolidx") frozen page(s): $(head -1 "$FROZEN/nolidx.err")"
  fi
else
  fail 4 "no binary or no IR — item 1 or 2 did not produce one"
fi

say "5/16 \`render\` prints the frozen transcript"
# The whole of stdout and not a slice of it: the `external ` block is printed
# above the counts, and a comparison that began at the first counts line would
# swallow a difference in the dependency map the run resolved. The `-s` test is
# what keeps two empty files from comparing equal — a run that printed nothing at
# all is exactly when that would happen.
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ] && [ -s "$OUT/lean.out" ] && [ -s "$FROZEN/render.out" ]; then
  normalise "$OUT/lean.out" "$OUT/lean" >"$OUT/lean-out.norm"
  used render.out
  if ! $DIFF_CMD "$FROZEN/render.out" "$OUT/lean-out.norm" >"$OUT/summary.diff" 2>&1; then
    fail 5 "stdout differs from the frozen transcript: $(line_gist "$OUT/summary.diff")— see $OUT/summary.diff"
    $DIFF_CMD "$FROZEN/render.out" "$OUT/lean-out.norm" >&2 || true
  else
    pass 5 "$(wc -l <"$OUT/lean-out.norm" | tr -d ' ') frozen line(s)"
  fi
else
  fail 5 "item 3 left no stdout to compare, or the fixture has no render.out"
fi

say "6/16 \`site\` writes the frozen 20 files, bytes and all"
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ]; then
  rm -rf "$OUT/site-lean" "$OUT/expect-site"
  site_rc=0
  "$LEAN_EXE" site --ir "$IR" --out "$OUT/site-lean" --source-url "$SOURCE_URL" \
    --link-index "$LIDX" >"$OUT/site-lean.out" 2>"$OUT/site-lean.err" || site_rc=$?
  mkdir -p "$OUT/expect-site"
  cp -R "$FROZEN/render/." "$OUT/expect-site/"
  cp -R "$FROZEN/site/." "$OUT/expect-site/"
  used_tree render
  used_tree site
  n_expect_site="$(file_count "$OUT/expect-site")"
  cmp6_rc="$(compare_frozen_tree "$OUT/expect-site" "$OUT/site-lean" "$OUT/compare-6.txt")"
  if [ "$site_rc" -ne 0 ]; then
    fail 6 "site exited $site_rc — see $OUT/site-lean.err"
  elif [ "$n_expect_site" -eq 0 ]; then
    # Two empty trees compare identical, which is the shape that goes green
    # having checked nothing.
    fail 6 "the fixture's site tree is empty — e2e/micro-expected/{render,site} hold no file"
  elif [ "$cmp6_rc" -ne 0 ]; then
    fail 6 "$(first_difference "$OUT/compare-6.txt")first is $(first_name "$OUT/compare-6.txt") — see $OUT/compare-6.txt"
  else
    pass 6 "$n_expect_site frozen file(s), $(find "$OUT/site-lean" -type f -exec cat {} + | wc -c | tr -d ' ') bytes; the pages are the ones item 3 froze"
  fi
else
  fail 6 "no binary or no IR — item 1 or 2 did not produce one"
fi

say "7/16 \`site\` prints the frozen transcript"
if [ -s "$OUT/site-lean.out" ] && [ -s "$FROZEN/site.out" ]; then
  normalise "$OUT/site-lean.out" "$OUT/site-lean" >"$OUT/site-out.norm"
  used site.out
  if ! $DIFF_CMD "$FROZEN/site.out" "$OUT/site-out.norm" >"$OUT/site-summary.diff" 2>&1; then
    fail 7 "stdout differs from the frozen transcript: $(line_gist "$OUT/site-summary.diff")— see $OUT/site-summary.diff"
    $DIFF_CMD "$FROZEN/site.out" "$OUT/site-out.norm" >&2 || true
  else
    pass 7 "$(wc -l <"$OUT/site-out.norm" | tr -d ' ') frozen line(s)"
  fi
else
  fail 7 "item 6 left no stdout to compare, or the fixture has no site.out"
fi

# Deliberately **not** guarded on item 6. Guarding it there would make it a check
# that only runs when the tree already matches the fixture — which is when it can
# only restate the frozen site's own consistency, so it could never fail on its
# own.
say "8/16 the Lean site closes over itself"
if [ "$(file_count "$OUT/site-lean")" -gt 0 ]; then
  closure_rc=0
  "$PYTHON" "$ROOT/benchmarks/tools/check-site-closure.py" "$OUT/site-lean" \
    >"$OUT/closure.txt" 2>&1 || closure_rc=$?
  usedby_rc=0
  "$HERE/usedby-gate.sh" --ir "$IR" --site "$OUT/site-lean" \
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

say "9/16 \`ledger build\` writes the frozen shape, and its digests are of what it says"
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ] && [ "$modules_ok" -eq 1 ]; then
  ledger_rc=0
  "$LEAN_EXE" ledger build --modules "$OUT/ledger-modules.txt" --target "$MICRO" \
    --out "$OUT/ledger-lean.json" --ir "$IR" --source-url "$SOURCE_URL" \
    --link-index "$LIDX" --root "$MICRO" \
    >"$OUT/ledger-lean.out" 2>"$OUT/ledger-lean.err" || ledger_rc=$?
  used ledger.json
  digest_rc=0
  if [ -s "$OUT/ledger-lean.json" ]; then
    normalise "$OUT/ledger-lean.json" "$OUT/ledger-lean.json" >"$OUT/ledger-lean.norm"
    "$PYTHON" - "$OUT/ledger-lean.json" "$MICRO" "$LIDX" >"$OUT/ledger-digests.txt" 2>&1 <<'PY' || digest_rc=$?
import hashlib
import json
import pathlib
import sys

ledger = json.load(open(sys.argv[1], encoding="utf-8"))
target, lidx = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
problems, checked = [], 0


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


# The one algorithm this check knows how to redo. `lake` records Lake's own
# `<file>.hash` instead of hashing bytes, and grading that here would be reading
# the same file the ledger read and calling it a second opinion.
if ledger.get("algorithm") != "sha256":
    problems.append(f"the ledger says algorithm {ledger.get('algorithm')!r}; this check only knows sha256")
else:
    for module in ledger["modules"]:
        for entry in module["files"]:
            path = target / entry["path"]
            if not path.exists():
                problems.append(f"{module['module']}: {entry['path']} is not in the target")
            elif sha(path) != entry["hash"]:
                problems.append(f"{module['module']}: the recorded hash is not sha256 of {entry['path']}")
            elif path.stat().st_size != entry["bytes"]:
                problems.append(f"{module['module']}: bytes {entry['bytes']} is not the size of {entry['path']}")
            else:
                checked += 1
        # `crates/litedoc4-incr/src/ledger.rs` and `src/Litedoc4/Ledger.lean`
        # both compose it this way; redone here in a third language rather than
        # compared against one of them.
        combined = "\n".join(f"{f['path']} {f['hash']}" for f in module["files"])
        if hashlib.sha256(combined.encode("utf-8")).hexdigest() != module["hash"]:
            problems.append(f"{module['module']}: its hash is not sha256 of its files' `<path> <hash>` lines")
        else:
            checked += 1

pairs = [
    ("extractKey.manifestSha256", ledger["extractKey"]["manifestSha256"], target / "lake-manifest.json"),
    ("renderKey.linkIndex", ledger["renderKey"]["linkIndex"], lidx),
]
for name, recorded, path in pairs:
    if not path.exists():
        problems.append(f"{name}: {path} is not there to hash")
    elif sha(path) != recorded:
        problems.append(f"{name} is not sha256 of {path.name}")
    else:
        checked += 1

toolchain = (target / "lean-toolchain").read_text(encoding="utf-8").strip()
if ledger["extractKey"]["leanToolchain"] != toolchain:
    problems.append(f"extractKey.leanToolchain {ledger['extractKey']['leanToolchain']!r} is not the target's {toolchain!r}")
else:
    checked += 1

if not checked:
    problems.append("no digest was recomputed — this check would pass having asked nothing")

for problem in problems[:3]:
    print(problem)
print(f"{checked} digest(s) recomputed")
sys.exit(1 if problems else 0)
PY
  fi
  if [ "$ledger_rc" -ne 0 ]; then
    fail 9 "ledger build exited $ledger_rc — see $OUT/ledger-lean.err"
  elif [ ! -s "$OUT/ledger-lean.json" ]; then
    fail 9 "the ledger is empty or missing"
  elif [ ! -s "$FROZEN/ledger.json" ]; then
    fail 9 "the fixture has no ledger.json to compare against"
  elif ! $DIFF_CMD "$FROZEN/ledger.json" "$OUT/ledger-lean.norm" >"$OUT/ledger.diff" 2>&1; then
    fail 9 "the ledger's shape moved $(byte_gist "$FROZEN/ledger.json" "$OUT/ledger-lean.norm") — see $OUT/ledger.diff"
  elif [ "$digest_rc" -ne 0 ]; then
    fail 9 "$(head -1 "$OUT/ledger-digests.txt") — see $OUT/ledger-digests.txt"
  else
    pass 9 "$(wc -c <"$OUT/ledger-lean.json" | tr -d ' ') bytes, $(grep -o '"module":' "$OUT/ledger-lean.json" | wc -l | tr -d ' ') module(s), $(tail -1 "$OUT/ledger-digests.txt")"
  fi
else
  fail 9 "no binary, no IR or no module list — item 1 or 2 says why"
fi

say "10/16 \`build\` writes the frozen 23 files, bytes and all"
lean_built_site=""
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ]; then
  rm -rf "$OUT/b-lean" "$OUT/expect-build"
  lean_b_rc=0
  "$LEAN_EXE" build --root "$MICRO" --lib Example --out "$OUT/b-lean" \
    --extractor-bin "$EXTRACTOR" --source-url "$BUILD_URL" \
    >"$OUT/b-lean.out" 2>"$OUT/b-lean.err" || lean_b_rc=$?
  n_lean_b="$(file_count "$OUT/b-lean/site")"
  # Set on "the Lean build wrote a site", deliberately not on "the comparison
  # passed": items 11 and 12 ask oracle-free questions of that tree, and gating
  # them on 10 would make them restate 10 rather than fail on their own.
  [ "$lean_b_rc" -eq 0 ] && [ "$n_lean_b" -gt 0 ] && lean_built_site="$OUT/b-lean/site"
  mkdir -p "$OUT/expect-build"
  cp -R "$FROZEN/build/." "$OUT/expect-build/"
  used_tree build
  missing_part=""
  for f in $BUILD_SHARED; do
    if [ -f "$FROZEN/site/$f" ]; then
      mkdir -p "$(dirname "$OUT/expect-build/$f")"
      cp "$FROZEN/site/$f" "$OUT/expect-build/$f"
      used "site/$f"
    else
      missing_part="$missing_part e2e/micro-expected/site/$f"
    fi
  done
  for f in $BUILD_ASSETS; do
    if [ -f "$ROOT/assets/$f" ]; then
      cp "$ROOT/assets/$f" "$OUT/expect-build/$f"
    else
      missing_part="$missing_part assets/$f"
    fi
  done
  n_expect_build="$(file_count "$OUT/expect-build")"
  cmp10_rc="$(compare_frozen_tree "$OUT/expect-build" "$OUT/b-lean/site" "$OUT/compare-10.txt")"
  if [ "$lean_b_rc" -ne 0 ]; then
    fail 10 "build exited $lean_b_rc — see $OUT/b-lean.err"
  elif [ -n "$missing_part" ]; then
    fail 10 "the expected tree cannot be assembled:$missing_part is not there"
  elif [ "$n_expect_build" -ne 23 ]; then
    # Not a style check: 23 is the count this project quotes, and a fixture that
    # grew or lost a file silently would still compare identical to a build that
    # did the same.
    fail 10 "the expected tree has $n_expect_build files, not 23 — the site's shape moved"
  elif [ "$cmp10_rc" -ne 0 ]; then
    fail 10 "$(first_difference "$OUT/compare-10.txt")first is $(first_name "$OUT/compare-10.txt") — see $OUT/compare-10.txt"
  else
    pass 10 "$n_expect_build files ($(file_count "$FROZEN/build") frozen + 5 from the frozen site + 3 from assets/), $(find "$OUT/b-lean/site" -type f -exec cat {} + | wc -c | tr -d ' ') bytes"
  fi
else
  fail 10 "no binary or no IR — item 1 or 2 did not produce one"
fi

say "11/16 the Lean-built site passes site-gate"
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

say "12/16 the Lean-built site passes config-gate, with the Lean half deriving"
# `config-gate.sh` re-derives the three trees that write HTML and asks whether
# the configured title reaches all of them. `LITEDOC4` is passed rather than left
# to the gate's own default, which is `target/debug/litedoc4` — the binary that
# is about to stop existing.
if [ -n "$lean_built_site" ]; then
  cg_rc=0
  LITEDOC4="$LEAN_EXE" "$HERE/config-gate.sh" --root "$MICRO" --ir "$OUT/b-lean/ir" \
    --built "$lean_built_site" --link-index "$OUT/b-lean/link-index.lidx" \
    --out "$OUT/config-lean" >"$OUT/config-gate-lean.txt" 2>&1 || cg_rc=$?
  # Truncated: `config-gate.sh`'s own last line carries the whole differing
  # mapping, which is the right thing in its file and not a line here.
  if [ "$cg_rc" -ne 0 ]; then
    fail 12 "$(tail -1 "$OUT/config-gate-lean.txt" | cut -c1-120) — see $OUT/config-gate-lean.txt"
  else
    pass 12 "$(tail -1 "$OUT/config-gate-lean.txt" | sed 's/^config *//')"
  fi
else
  fail 12 "the Lean build wrote no site — item 10 says why"
fi

say "13/16 the build leaves the frozen litedoc4-build.json"
if [ -n "$lean_built_site" ]; then
  used marker.json
  normalise "$OUT/b-lean/litedoc4-build.json" "$OUT/b-lean" >"$OUT/marker-lean.norm"
  if [ ! -s "$FROZEN/marker.json" ]; then
    fail 13 "the fixture has no marker.json to compare against"
  elif [ ! -s "$OUT/b-lean/litedoc4-build.json" ]; then
    fail 13 "the build left no marker"
  elif ! $DIFF_CMD "$FROZEN/marker.json" "$OUT/marker-lean.norm" >"$OUT/marker.diff" 2>&1; then
    fail 13 "the marker moved $(byte_gist "$FROZEN/marker.json" "$OUT/marker-lean.norm") — see $OUT/marker.diff"
  else
    pass 13 "$(wc -c <"$OUT/b-lean/litedoc4-build.json" | tr -d ' ') bytes, irReads $(grep -o '"total":[0-9]*' "$OUT/b-lean/litedoc4-build.json" | head -1 | cut -d: -f2)"
  fi
else
  fail 13 "the Lean build wrote no site, so there is no marker — item 10 says why"
fi

say "14/16 the build prints the frozen transcript, generation digest and all"
if [ -n "$lean_built_site" ] && [ -s "$OUT/b-lean.out" ]; then
  used build.out
  normalise "$OUT/b-lean.out" "$OUT/b-lean" >"$OUT/t-lean.txt"
  # The digest the frozen transcript cannot carry, asked of the only second
  # reader there is: item 2's build, over the same unchanged sample.
  gen_build="$(grep -oE 'generation [0-9a-f]+' "$OUT/b-lean.out" | head -1 | awk '{print $2}')"
  gen_ir="$(grep -oE 'generation [0-9a-f]+' "$OUT/ir.log" | head -1 | awk '{print $2}')"
  if [ ! -s "$FROZEN/build.out" ]; then
    fail 14 "the fixture has no build.out to compare against"
  elif ! $DIFF_CMD "$FROZEN/build.out" "$OUT/t-lean.txt" >"$OUT/transcript.diff" 2>&1; then
    fail 14 "the transcript moved: $(line_gist "$OUT/transcript.diff")— see $OUT/transcript.diff"
  elif [ -z "$gen_build" ] || [ -z "$gen_ir" ]; then
    fail 14 "no \`serve ready … generation <hex>\` line in $([ -z "$gen_build" ] && echo "$OUT/b-lean.out" || echo "$OUT/ir.log") — the digest went unprinted, and the frozen transcript normalises it away"
  elif [ "$gen_build" != "$gen_ir" ]; then
    fail 14 "two builds of the same unchanged sample generated $gen_build and $gen_ir — the digest is not a function of the files alone"
  else
    pass 14 "$(wc -l <"$OUT/t-lean.txt" | tr -d ' ') frozen line(s) after normalising 5 values; generation $gen_build twice"
  fi
else
  fail 14 "the Lean build wrote no site — item 10 says why"
fi

say "15/16 --only-from renders that subset of the whole render, and no more"
# No oracle at all: the subset has to be the same bytes as those pages of the
# whole render item 3 already did, and there have to be fewer of them.
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ] && [ "${n_lean:-0}" -gt 1 ]; then
  rm -rf "$OUT/lean-only" "$OUT/lean-none"
  # Read out of the IR rather than written down here: the sample gains modules,
  # and a name spelt in this file would go stale without failing.
  "$PYTHON" - "$IR/index.json" >"$OUT/only-from.txt" <<'ONLY'
import json, sys
index = json.load(open(sys.argv[1]))
for entry in index["modules"][:1]:
    print(entry["module"])
ONLY
  : >"$OUT/only-none.txt"
  lean_o_rc="$(render "$LEAN_EXE" "$OUT/lean-only" lean-only --link-index "$LIDX" --only-from "$OUT/only-from.txt")"
  lean_e_rc="$(render "$LEAN_EXE" "$OUT/lean-none" lean-none --link-index "$LIDX" --only-from "$OUT/only-none.txt")"
  n_only="$(html_count "$OUT/lean-only")"
  wanted="$(wc -l <"$OUT/only-from.txt" | tr -d ' ')"
  # Every page of the subset against the same page of the whole render, and the
  # whole render is the tree item 3 held to the frozen bytes.
  subset_diff=""
  ( cd "$OUT/lean-only" && find . -type f -name '*.html' | sort ) >"$OUT/only-rendered.txt"
  while IFS= read -r f; do
    cmp -s "$OUT/lean-only/$f" "$OUT/lean/$f" || subset_diff="${subset_diff:-$f}"
  done <"$OUT/only-rendered.txt"
  if [ "$lean_o_rc" -ne 0 ]; then
    fail 15 "a --only-from render exited $lean_o_rc — see $OUT/lean-only.err"
  elif [ "$n_only" -ne "$wanted" ]; then
    fail 15 "--only-from named $wanted module(s) and got $n_only page(s) — a set that is ignored renders all $n_lean"
  elif [ "$n_only" -ge "$n_lean" ]; then
    fail 15 "--only-from wrote $n_only of $n_lean page(s) — a subset that is the whole is a subset that was ignored"
  elif [ -n "$subset_diff" ]; then
    fail 15 "$subset_diff differs from the same page of the whole render — a narrowed render is not the same bytes"
  elif [ "$lean_e_rc" -ne 0 ]; then
    fail 15 "an empty --only-from exited $lean_e_rc — it has to mean render nothing, not fail"
  elif [ "$(html_count "$OUT/lean-none")" -ne 0 ]; then
    fail 15 "an empty --only-from wrote $(html_count "$OUT/lean-none") page(s) — it has to mean render nothing, not render everything"
  else
    pass 15 "$wanted of $n_lean page(s), byte for byte the whole render's; an empty set writes none and exits 0"
  fi
else
  fail 15 "item 3 did not leave a whole render of more than one page to compare a subset against"
fi

say "16/16 an incremental build leaves what a full one would have"
# `ledger touch` is the honest fake — it invalidates one module's ledger entry
# rather than editing the sample, so the IR a full build would produce is
# unchanged and the two sites have to be the same bytes. Under-rendering is the
# silent failure this catches: a round that re-rendered nothing writes a site
# that is stale in exactly the pages nobody looks at, and every count in the
# marker still looks reasonable.
if [ "$built" -eq 1 ] && [ "$extracted" -eq 1 ]; then
  rm -rf "$OUT/i-incr" "$OUT/i-full"
  i_rc=0
  "$LEAN_EXE" build --root "$MICRO" --lib Example --out "$OUT/i-incr" \
    --extractor-bin "$EXTRACTOR" --source-url "$BUILD_URL" \
    >"$OUT/i-first.out" 2>"$OUT/i-first.err" || i_rc=$?
  i_touched=""
  if [ "$i_rc" -eq 0 ]; then
    i_touched="$("$PYTHON" -c "import json,sys;print(json.load(open(sys.argv[1]))['modules'][0]['module'])" "$OUT/i-incr/ir/index.json")"
    "$LEAN_EXE" ledger touch --ledger "$OUT/i-incr/ledger.json" --module "$i_touched" \
      >"$OUT/i-touch.out" 2>&1 || i_rc=$?
  fi
  if [ "$i_rc" -eq 0 ]; then
    "$LEAN_EXE" build --root "$MICRO" --lib Example --out "$OUT/i-incr" \
      --extractor-bin "$EXTRACTOR" --source-url "$BUILD_URL" \
      >"$OUT/i-second.out" 2>"$OUT/i-second.err" || i_rc=$?
  fi
  if [ "$i_rc" -eq 0 ]; then
    "$LEAN_EXE" build --root "$MICRO" --lib Example --out "$OUT/i-full" \
      --extractor-bin "$EXTRACTOR" --source-url "$BUILD_URL" \
      >"$OUT/i-fullrun.out" 2>"$OUT/i-fullrun.err" || i_rc=$?
  fi
  om_rc=0
  if [ "$i_rc" -eq 0 ]; then
    "$HERE/onemod-gate.sh" "$OUT/i-incr/litedoc4-build.json" "$OUT/i-incr/work/serve.out" \
      >"$OUT/i-onemod.txt" 2>&1 || om_rc=$?
  fi
  if [ "$i_rc" -ne 0 ]; then
    fail 16 "a build in the sequence exited $i_rc — see $OUT/i-{first,second,fullrun}.err"
  elif [ "$om_rc" -ne 0 ]; then
    fail 16 "$(grep FAIL "$OUT/i-onemod.txt" | head -1 | sed 's/^onemod-gate *FAIL *//') — see $OUT/i-onemod.txt"
  elif ! $DIFF_CMD -r "$OUT/i-full/site" "$OUT/i-incr/site" >"$OUT/i-site.diff" 2>&1; then
    fail 16 "the incremental site differs from a full one over the same sources: $(head -1 "$OUT/i-site.diff")"
  else
    pass 16 "touched $i_touched; $(grep -v FAIL "$OUT/i-onemod.txt" | head -1 | sed 's/^onemod-gate *//'); the site equals a full build's"
  fi
else
  fail 16 "no binary or no IR — item 1 or 2 did not produce one"
fi

# The arm that expires at M10. Absent is a skip **with the number it did not
# check** — a line that says nothing is how "green having checked nothing" reads
# to whoever runs this next.
say "rust arm — the fixture is still what the oracle says"
frozen_total="$( ( cd "$FROZEN" && find . -type f ! -name 'README.md' ) | wc -l | tr -d ' ')"
rust_checked=0
rust_live=0
rust_problems=0
rust_ran=0
if [ -n "$LITEDOC4" ] && [ -x "$LITEDOC4" ] && [ "$extracted" -eq 1 ] && [ "$modules_ok" -eq 1 ]; then
  rust_ran=1
  if ! stage_oracle "$OUT/oracle" "$OUT/oracle-work" "$LITEDOC4"; then
    echo "RUST ARM FAIL  the oracle could not be run through the flows the fixture holds" >&2
    rust_problems=$((rust_problems + 1))
  else
    ( cd "$OUT/oracle" && find . -type f | sed 's|^\./||' | sort ) >"$OUT/oracle-list.txt"
    while IFS= read -r f; do
      if [ ! -f "$FROZEN/$f" ]; then
        echo "RUST ARM FAIL  the oracle writes $f and the fixture does not hold it — re-mint" >&2
        rust_problems=$((rust_problems + 1))
      elif ! cmp -s "$OUT/oracle/$f" "$FROZEN/$f"; then
        echo "RUST ARM FAIL  $f: the fixture is no longer what the oracle writes ($(cmp "$OUT/oracle/$f" "$FROZEN/$f" 2>&1 | head -1)) — re-mint" >&2
        rust_problems=$((rust_problems + 1))
      else
        rust_checked=$((rust_checked + 1))
      fi
    done <"$OUT/oracle-list.txt"
    if [ "$rust_checked" -ne "$frozen_total" ]; then
      echo "RUST ARM FAIL  the oracle accounted for $rust_checked of the fixture's $frozen_total file(s)" >&2
      rust_problems=$((rust_problems + 1))
    fi
  fi
  # The two claims nothing can be frozen from, asked while there is still
  # something to ask them of.
  rm -rf "$OUT/rust-ir"
  ir_rust_rc=0
  "$LITEDOC4" build --root "$MICRO" --lib Example --out "$OUT/rust-ir" \
    --extractor-bin "$EXTRACTOR" --source-url "$BUILD_URL" >"$OUT/rust-ir.log" 2>&1 || ir_rust_rc=$?
  if [ "$ir_rust_rc" -ne 0 ]; then
    echo "RUST ARM FAIL  the oracle's build exited $ir_rust_rc — see $OUT/rust-ir.log" >&2
    rust_problems=$((rust_problems + 1))
  elif ! $DIFF_CMD -r "$OUT/rust-ir/ir" "$IR" >"$OUT/rust-ir.diff" 2>&1; then
    echo "RUST ARM FAIL  the two halves extract different IR: $(head -1 "$OUT/rust-ir.diff")" >&2
    rust_problems=$((rust_problems + 1))
  elif ! cmp -s "$OUT/rust-ir/link-index.lidx" "$LIDX"; then
    # An input to every frozen page, and not under ir/: a link index the two
    # halves disagree on renders two different sites out of one IR.
    echo "RUST ARM FAIL  the two halves build different link indexes: $(cmp "$OUT/rust-ir/link-index.lidx" "$LIDX" 2>&1 | head -1)" >&2
    rust_problems=$((rust_problems + 1))
  else
    rust_live=$((rust_live + 1))
  fi
  if [ -n "$lean_built_site" ]; then
    cgr_rc=0
    LITEDOC4="$LITEDOC4" "$HERE/config-gate.sh" --root "$MICRO" --ir "$OUT/b-lean/ir" \
      --built "$lean_built_site" --link-index "$OUT/b-lean/link-index.lidx" \
      --out "$OUT/config-rust" >"$OUT/config-gate-rust.txt" 2>&1 || cgr_rc=$?
    if [ "$cgr_rc" -ne 0 ]; then
      echo "RUST ARM FAIL  config-gate with the Rust half deriving: $(tail -1 "$OUT/config-gate-rust.txt" | cut -c1-120)" >&2
      rust_problems=$((rust_problems + 1))
    else
      rust_live=$((rust_live + 1))
    fi
  else
    echo "RUST ARM FAIL  there is no built site to run config-gate over — item 10 says why" >&2
    rust_problems=$((rust_problems + 1))
  fi
fi
if [ "$rust_ran" -eq 1 ]; then
  printf 'rust arm       : %s of %s frozen file(s) match the oracle, %s of 2 live cross-check(s)\n' \
    "$rust_checked" "$frozen_total" "$rust_live"
else
  printf 'rust arm       : did not run — %s frozen file(s) and 2 live cross-check(s) unchecked against the oracle.\n' "$frozen_total"
  printf '                 Expected once crates/ is gone; before that, cargo build --bin litedoc4\n'
fi

say "summary"
frozen_used="$(sort -u "$OUT/frozen-used.txt" | wc -l | tr -d ' ')"
printf 'items reported : %s of %s\n' "$ran" "$ITEMS"
printf 'frozen files   : %s of %s compared\n' "$frozen_used" "$frozen_total"
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
if [ "$rust_problems" -ne 0 ]; then
  echo "PURELEAN MICRO GATE: FAILED — $rust_problems problem(s) in the rust arm" >&2
  exit 1
fi
# Both directions: a frozen file no item reads is a fixture nobody is held to,
# and an item that compared nothing is the green-having-checked-nothing shape.
if [ "$frozen_used" -ne "$frozen_total" ]; then
  sort -u "$OUT/frozen-used.txt" >"$OUT/frozen-used-sorted.txt"
  ( cd "$FROZEN" && find . -type f ! -name 'README.md' | sed 's|^\./||' | sort ) >"$OUT/frozen-all.txt"
  unread="$(/usr/bin/comm -23 "$OUT/frozen-all.txt" "$OUT/frozen-used-sorted.txt" | head -1)"
  echo "PURELEAN MICRO GATE: FAILED — $frozen_used of $frozen_total frozen file(s) were compared${unread:+; first one no item reads: $unread}" >&2
  exit 1
fi

# `if`, not `&&`: the last command in this block decides the script's exit code,
# and a `&&` whose left side is false returns 1 while the summary says ok.
if [ "$TEMPORARY" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
  rm -rf "$OUT"
fi
echo
echo "PURELEAN MICRO GATE: ok"
