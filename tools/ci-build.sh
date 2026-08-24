#!/usr/bin/env bash
# Build a Lean package **and its documentation** in one job.
#
# The commands live here rather than inline in the workflow so that the
# interesting half can be run on a laptop against a real package; the workflow
# shrinks to checkout + caches + one `run:` line.
#
# `lake build` and the docs are in the same job because the extractor's floor is
# loading the Lean environment, and that cost is page cache, not Lean: same
# runner, cache dropped, 13.5-22.3 s against 2.4-2.6 s resident — **5.2-11.9x**
# 【実測 2026-08-16, n=5】. A split "docs" job is not reliably cold (it writes
# the oleans itself), so the split's cost depends on the runner's RAM against
# the package's working set; one job does not have to ask.
#
# `lake exe cache get` is behind `--cache-get` rather than unconditional because
# it needs the network: on a developer machine the dependencies are already
# there and an unconditional download would make a local run of "the CI command"
# not the same command. A run without it says so, with the reason — a silent
# skip is the failure mode where CI passes on the last run's leftovers.
#
# The extractor is built by `extractor/build.sh` against **the package's own
# toolchain** (`lake env` borrows it; litedoc4 has no toolchain and no Mathlib of
# its own), so it cannot be shipped as a binary and cannot be built before the
# package's toolchain exists. It does not change between commits of the package,
# so in CI it belongs in a cache keyed on `lean-toolchain` + the hash of
# `Extract.lean`. Cost **14.90 s wall / 10.07 s user, peak RSS 1.52 GB** on an
# Apple M1, warm 【実測 2026-08-15】.
#
# usage:
#   ci-build.sh --root <lean package> --out <dir> [options] [-- <build args>...]
#
#   --root <dir>            the Lean package to build and document (required)
#   --out <dir>             where the documentation state goes (required).
#                           <out>/site is the site; the rest is cache.
#   --cache-get             run `lake exe cache get` in --root first (network)
#   --no-lake-build         skip `lake build` — only for a caller that has
#                           already built the package **in the same job**
#   --jobs <n>              extractor threads (default 4)
#   --lake <path>           the lake executable (default: $LAKE, else `lake`)
#   --extractor-bin <path>  the Lean extractor (default: <repo>/extractor/build/
#                           extract, built by extractor/build.sh if missing)
#   --litedoc4-bin <path>   the litedoc4 binary (default: <repo>/target/release/
#                           litedoc4, built with cargo if missing)
#   --timings <file>        phase timings as one JSON object
#                           (default: <out>/ci-timings.json)
#   -- <args>...            passed through to `litedoc4 build` (e.g. --lib,
#                           --source-url, --full)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT=""
OUT=""
JOBS=4
LAKE="${LAKE:-lake}"
CACHE_GET=0
LAKE_BUILD=1
EXTRACTOR_BIN="${EXTRACT_BIN:-$REPO/extractor/build/extract}"
LITEDOC4_BIN="${LITEDOC4_BIN:-$REPO/target/release/litedoc4}"
TIMINGS=""
BUILD_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --cache-get) CACHE_GET=1; shift ;;
    --no-lake-build) LAKE_BUILD=0; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --lake) LAKE="$2"; shift 2 ;;
    --extractor-bin) EXTRACTOR_BIN="$2"; shift 2 ;;
    --litedoc4-bin) LITEDOC4_BIN="$2"; shift 2 ;;
    --timings) TIMINGS="$2"; shift 2 ;;
    --) shift; BUILD_ARGS=("$@"); break ;;
    -h|--help) sed -n '/^# usage:/,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

[ -n "$ROOT" ] || { echo "--root is required" >&2; exit 2; }
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "no such package: $ROOT" >&2; exit 1; }

ROOT="$(cd "$ROOT" && pwd)"

# Checked here as well as in `litedoc4 build`, which by then has already spent
# `lake build` — and **before `mkdir`, and twice**: creating the directory is
# itself a write into the package, so the lexical form is checked while --out is
# still a string, and again after it resolves, because a symlink can land inside
# --root.
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
refuse_out_inside_root () {
  case "$1" in
    "$ROOT"|"$ROOT"/*) echo "--out may not be inside --root ($ROOT)" >&2; exit 2 ;;
  esac
}
refuse_out_inside_root "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
refuse_out_inside_root "$OUT"
[ -n "$TIMINGS" ] || TIMINGS="$OUT/ci-timings.json"

# `date` on BSD has no sub-second format, so the clock is bash 5's
# $EPOCHREALTIME with a perl fallback.
now () {
  if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s' "${EPOCHREALTIME/,/.}"
  else perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()'; fi
}
elapsed () { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b-a}'; }

PHASE_NAME=()
PHASE_SECS=()
PHASE_NOTE=()
record () { PHASE_NAME+=("$1"); PHASE_SECS+=("$2"); PHASE_NOTE+=("$3"); }

step () { echo; echo "=== $* ==="; }

T0="$(now)"

step "environment"
echo "package     $ROOT"
echo "output      $OUT"
echo "litedoc4    $REPO"
if [ -f "$ROOT/lean-toolchain" ]; then
  echo "toolchain   $(tr -d '\n' < "$ROOT/lean-toolchain")"
fi
# Asked from inside the package: `lake` is an elan shim that picks the toolchain
# from the nearest `lean-toolchain`, and litedoc4 has none of its own, so the
# same command run from this repository answers "not found".
echo "lake        $( (cd "$ROOT" && "$LAKE" --version 2>&1 | head -1) || echo 'not found')"
echo "uname       $(uname -srm)"
if command -v git > /dev/null && git -C "$ROOT" rev-parse HEAD > /dev/null 2>&1; then
  echo "HEAD        $(git -C "$ROOT" rev-parse HEAD)"
fi

step "1/5  lake exe cache get"
t="$(now)"
if [ "$CACHE_GET" = 1 ]; then
  (cd "$ROOT" && "$LAKE" exe cache get)
  record cache-get "$(elapsed "$t" "$(now)")" "ran"
else
  echo "skipped: --cache-get was not given, so the dependencies' oleans are"
  echo "         whatever is already in $ROOT/.lake/packages."
  record cache-get "$(elapsed "$t" "$(now)")" "skipped (no --cache-get)"
fi

step "2/5  lake build"
t="$(now)"
if [ "$LAKE_BUILD" = 1 ]; then
  (cd "$ROOT" && "$LAKE" build)
  record lake-build "$(elapsed "$t" "$(now)")" "ran"
else
  echo "skipped: --no-lake-build. This is only correct if the package was built"
  echo "         earlier in THIS job; from another job the page cache is cold."
  record lake-build "$(elapsed "$t" "$(now)")" "skipped (--no-lake-build)"
fi

step "3/5  the extractor (Lean)"
t="$(now)"
# "It exists" is not "it is the one this checkout describes": run by hand,
# nothing hashes `Extract.lean` into the path, and the failure is silent — every
# number below would describe an extractor nobody is looking at. So the source
# decides, not the presence of a file; `-nt` rather than an unconditional
# rebuild because `extractor/build.sh` is ~16 s.
if [ -x "$EXTRACTOR_BIN" ] && [ ! "$REPO/extractor/Extract.lean" -nt "$EXTRACTOR_BIN" ]; then
  echo "cached: $EXTRACTOR_BIN"
  record extractor "$(elapsed "$t" "$(now)")" "cached"
elif [ "$EXTRACTOR_BIN" = "$REPO/extractor/build/extract" ]; then
  echo "building with extractor/build.sh (borrowing $ROOT's toolchain)"
  TARGET_REPO="$ROOT" LAKE="$LAKE" "$REPO/extractor/build.sh"
  record extractor "$(elapsed "$t" "$(now)")" "built"
else
  echo "no extractor at $EXTRACTOR_BIN, and it is not the path extractor/build.sh" >&2
  echo "writes — build it there, or drop --extractor-bin." >&2
  exit 1
fi

step "4/5  the litedoc4 binary (Rust)"
t="$(now)"
# **Always ask cargo**, rather than skipping because the file is there: the
# workflow's cache key for `target/` is `hashFiles('litedoc4/Cargo.lock')`, which
# does not move when litedoc4's *sources* do, so "the binary exists" was true of
# a binary built from a different commit and the run measured code nobody had
# written yet 【実測 2026-08-17, runs 31963079828 / 31963305864】. Cargo knows
# whether the binary matches the sources; a shell `-x` test does not, and a fresh
# tree costs ~0.2 s here.
#
# An explicit --litedoc4-bin is taken as given: the caller named a file outside
# this checkout and this script has no standing to rebuild it.
if [ "$LITEDOC4_BIN" = "$REPO/target/release/litedoc4" ]; then
  (cd "$REPO" && cargo build --release -p litedoc4)
  record cargo "$(elapsed "$t" "$(now)")" "built"
elif [ -x "$LITEDOC4_BIN" ]; then
  echo "given: $LITEDOC4_BIN (--litedoc4-bin, taken as it is)"
  record cargo "$(elapsed "$t" "$(now)")" "given"
else
  echo "no litedoc4 binary at $LITEDOC4_BIN" >&2
  exit 1
fi

step "5/5  litedoc4 build"
t="$(now)"
"$LITEDOC4_BIN" build \
  --root "$ROOT" \
  --out "$OUT" \
  --extractor-bin "$EXTRACTOR_BIN" \
  --lake "$LAKE" \
  --jobs "$JOBS" \
  --timings "$OUT/litedoc4-timings.json" \
  "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}"
record docs "$(elapsed "$t" "$(now)")" "ran"

TOTAL="$(elapsed "$T0" "$(now)")"

step "summary"
printf '%-12s %10s  %s\n' phase seconds note
for i in "${!PHASE_NAME[@]}"; do
  printf '%-12s %10s  %s\n' "${PHASE_NAME[$i]}" "${PHASE_SECS[$i]}" "${PHASE_NOTE[$i]}"
done
printf '%-12s %10s\n' total "$TOTAL"
echo
echo "site        $OUT/site  ($(find "$OUT/site" -type f | wc -l | tr -d ' ') files)"

{
  printf '{"root":"%s","out":"%s","totalSeconds":%s,"phases":{' "$ROOT" "$OUT" "$TOTAL"
  for i in "${!PHASE_NAME[@]}"; do
    [ "$i" = 0 ] || printf ','
    printf '"%s":{"seconds":%s,"note":"%s"}' \
      "${PHASE_NAME[$i]}" "${PHASE_SECS[$i]}" "${PHASE_NOTE[$i]}"
  done
  printf '},"siteFiles":%s}\n' "$(find "$OUT/site" -type f | wc -l | tr -d ' ')"
} > "$TIMINGS"
echo "timings     $TIMINGS"
