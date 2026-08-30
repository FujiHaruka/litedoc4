#!/usr/bin/env bash
# Run seven end-to-end incremental scenarios against the measurement target and
# record what each one *computed* — not what it printed.
#
# **`--extractor` selects what runs behind `litedoc4 incremental`'s `--extractor`
# flag.** Both spellings drive the same Lean extraction; what differs is who
# spells the command line and who folds the events into the timings:
#
#   --extractor product   `litedoc4 extract` + extractor/build/extract (default)
#   --extractor resident  **no `--extractor` at all**: `litedoc4 incremental
#                         --serve` starts one Lean environment per run and asks
#                         it every round. The same seven scenarios through a
#                         server instead of a process per round have to produce
#                         the same answers, byte for byte.
#
# It is a flag rather than a replacement so that the gates are *comparisons*:
# record with one spelling, record with another, and run
# tools/incremental-compare.sh over the two.
#
# usage: tools/incremental-reference.sh [--extractor product|resident]
#                                       [--out DIR] [--target REPO] [--lib NAME]
#                                       [--lidx FILE] [--base-ir DIR] [--ref-site DIR]
#                                       [--only SCENARIO]...
#
#   LITEDOC4  the binary to record (default target/release/litedoc4). The
#             recording is the implementation's answer, so a second one taken
#             with another binary is what the matching *-compare.sh compares.
#   --lib  the library whose modules are the module list; defaults to
#          `InformationTheory`, which is the measurement target's. A different
#          `--target` needs this too.
#
# **Page bytes are not recorded.** What is recorded is which pages exist (a
# sorted listing and a count), plus the six whole-package artifacts, which
# `build_global` derives from the IR alone and which therefore are comparable
# across recordings. The page-byte check is not given up, it is moved: every run
# also rebuilds a whole site from the IR each scenario left behind and diffs it
# against the page tree the incremental run produced (`<s>-sitecheck.txt`), which
# is the stronger question anyway — "did the round leave the tree a full run
# would have written".
#
# **The module list is built here, once, under `LC_ALL=C`**, and checked against
# `litedoc4 modules`, **refusing to run if they differ**. `litedoc4 modules`
# sorts in UTF-16 code-unit order; a `find … | sort` sorts in the caller's locale,
# and on `en_US.UTF-8` **163 of the 432 lines land in a different position** —
# same set, same count (measured). That order makes bytes: it is the order of the
# ledger's `modules` array and of the merged `index.json`'s.
#
# **The ledger and the global-derivation cache are seeded by the run itself.**
# `extractKey.extractor` is *designed* to differ between implementations: a
# ledger written by one must invalidate under the other. A borrowed ledger would
# report all 432 modules as changed and the run would be measuring the key
# mismatch, not the pipeline. The six whole-package artifacts of the seed's own
# `base-site/` are recorded into the compared tree, which turns the seeding into
# an oracle instead of a setup step nobody looked at.
#
# **Nothing outside $OUT and $OUT.work is ever written to.** The pipeline deletes
# pages (`prune`) and rewrites an IR tree in place (`merge`), so every scenario
# runs against copies under `$OUT.work` and `guard_writable` refuses a scenario
# whose live tree is not under it. The measurement target is opened **read-only**.
#
#   $OUT       the compared tree — records only, all of them implementation-neutral
#   $OUT.work  fixtures, live copies, work directories, from-scratch sites
#
# What each scenario leaves in $OUT — the denominator of the comparison:
#   <s>-status.txt       the exit code
#   <s>-stdout.txt       recorded, **not compared**: only the timings record in it
#                        is an answer, and <s>-counts.json is that, distilled
#   <s>-stderr.txt       recorded, **not compared** (wording is the
#                        implementation's); <s>-complained.txt carries the fact
#   <s>-counts.json      **the core**: the eight answers, lifted out of the run's
#                        timings JSON by this script so that two recordings are
#                        read the same way. No `*Seconds` — a duration is not an
#                        answer.
#   <s>-work/            the diagnostics the run left in `--work`
#   <s>-work-present.txt which of them exist. `impact-set.txt` is absent exactly
#                        when the changed set is empty and the mode is not `all`,
#                        and that absence is an answer, not a gap in the recording.
#   <s>-ir/              the whole IR tree the run left behind, byte for byte
#   <s>-global/          the six whole-package artifacts, byte for byte
#   <s>-pages.txt        which pages exist; <s>-pages-count.txt
#   <s>-sitecheck.txt    the within-run page-byte oracle, skipped by the comparator

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_EXTRACT_BIN="$REPO/extractor/build/extract"
LITEDOC4="${LITEDOC4:-$REPO/target/release/litedoc4}"
# shellcheck source=lib/target.sh
. "$REPO/tools/lib/target.sh" || exit 1
# shellcheck source=lib/common.sh
. "$REPO/tools/lib/common.sh" || exit 1

EXTRACTOR_IMPL=product
OUT=
TARGET="$TARGET_REPO"
LIB=InformationTheory
LIDX=/private/tmp/lean-doc-relay/w7c/linkindex/link-index.lidx
BASE_IR_SRC=/private/tmp/lean-doc-relay/w7h/base-ir
REF_SITE=/private/tmp/lean-doc-relay/m2/gate/ref-site
JOBS=4

# 40 lower-case hex digits, because `litedoc4 incremental` refuses anything else.
URL="https://github.com/FujiHaruka/information-theory/blob/573793b243fb1343636088eb62d1789ab2b14cec"
# A *different* 40-hex revision, for the one scenario whose whole point is that
# the render key moved. Not a real commit: nothing reads it back, and the only
# property under test is "these two strings differ".
URL_NEXT="https://github.com/FujiHaruka/information-theory/blob/00112233445566778899aabbccddeeff00112233"

# The module the deletion / addition scenarios turn on. **Not a leaf**: 1
# declaration, imports nothing itself, imported directly by 281 of the 432
# modules (measured 2026-08-15, `litedoc4 impact --census`). Chosen because its
# single declaration is an `initialize`, so removing it moves one entry of the
# global name map and no other module's `refs`; with `--mode self` none of the
# 281 importers is walked, so the scenario stays cheap.
ONE=InformationTheory.Meta.EntryPoint
HUB=InformationTheory.Shannon.Bridge
OTHER=InformationTheory.Polymatroid.Basic

ALL_SCENARIOS="nochange self-one importers-hub referrers-two renderall removed-one added-one"
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --extractor) EXTRACTOR_IMPL="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --lib) LIB="$2"; shift 2 ;;
    --lidx) LIDX="$2"; shift 2 ;;
    --base-ir) BASE_IR_SRC="$2"; shift 2 ;;
    --ref-site) REF_SITE="$2"; shift 2 ;;
    --only) ONLY="$ONLY $2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

OUT="${OUT:-/private/tmp/lean-doc-relay/m3d3/rust}"
WORKROOT="$OUT.work"

# Neither spelling has a default output directory of its own, on purpose: the
# point of the gate is to compare one *recorded* run with another, so the caller
# names where the new recording goes.
case "$EXTRACTOR_IMPL" in
  product|resident)
    # `resident` passes no --extractor at all; the binary is named by
    # --extractor-bin instead, so it is what the executability check is about.
    [ "$EXTRACTOR_IMPL" = product ] && EXTRACTOR="$LITEDOC4" || EXTRACTOR="$PRODUCT_EXTRACT_BIN"
    [ -x "$PRODUCT_EXTRACT_BIN" ] || {
      echo "missing extractor binary: $PRODUCT_EXTRACT_BIN — run: extractor/build.sh" >&2; exit 1; }
    ;;
  *) echo "--extractor wants product or resident, not $EXTRACTOR_IMPL" >&2; exit 2 ;;
esac

[ -d "$TARGET" ] || { echo "missing target repository: $TARGET" >&2; exit 1; }
[ -d "$BASE_IR_SRC" ] || { echo "missing base IR: $BASE_IR_SRC" >&2; exit 1; }
[ -f "$LIDX" ] || { echo "missing link index: $LIDX" >&2; exit 1; }
[ -x "$EXTRACTOR" ] || { echo "missing extractor: $EXTRACTOR" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
# Needed by both spellings: the module-list check below is stated against
# `litedoc4 modules`, whose order the run depends on.
[ -x "$LITEDOC4" ] || {
  echo "missing: $LITEDOC4 — run: cargo build --release -p litedoc4, or set LITEDOC4" >&2; exit 1; }

# `added-one` starts from what `removed-one` left behind, so selecting it
# selects that too.
case " $ONLY " in
  *" added-one "*) case " $ONLY " in *" removed-one "*) ;; *) ONLY="$ONLY removed-one" ;; esac ;;
esac
selected () { # selected <scenario>
  [ -z "${ONLY// /}" ] && return 0
  case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

ledger_build () { # ledger_build <modules> <ir> <out>
  "$LITEDOC4" ledger build --modules "$1" --target "$TARGET" --ir "$2" \
    --source-url "$URL" --out "$3"
}
ledger_touch () { "$LITEDOC4" ledger touch --ledger "$1" --module "$2"; }
base_site () { # one command: `site` writes the pages, the six artifacts and the cache
  "$LITEDOC4" site --ir "$1" --out "$2" --source-url "$URL" \
    --link-index "$LIDX" --state "$3"
}
# `product` is `--extractor <program>` with `--extractor-arg` values in the order
# the program sees them, before the three flags `pipeline.rs` appends (`--modules
# --ir-dir --timings`). `resident` is not a program at all: `--serve` makes the
# pipeline own one resident Lean environment for the whole run, so the binary,
# the target and the job count are its own flags.
case "$EXTRACTOR_IMPL" in
  product)
    HOW=(--extractor "$LITEDOC4"
         --extractor-arg extract
         --extractor-arg --extractor-bin --extractor-arg "$PRODUCT_EXTRACT_BIN"
         --extractor-arg --target --extractor-arg "$TARGET"
         --extractor-arg --jobs --extractor-arg "$JOBS") ;;
  resident)
    HOW=(--serve
         --extractor-bin "$PRODUCT_EXTRACT_BIN"
         --target "$TARGET"
         --jobs "$JOBS") ;;
esac
pipeline () {
  "$LITEDOC4" incremental --ir "$1" --pages "$2" --ledger "$3" --work "$4" \
    --state "$5" --modules "$6" --mode "$7" --source-url "$8" \
    --link-index "$LIDX" --timings "$9" "${HOW[@]}"
}

# Nothing is copied over, deleted or rewritten outside the two roots this script
# owns. Every scenario passes its live tree through here first.
guard_writable () { # guard_writable <path>
  case "$1" in
    "$WORKROOT"/*|"$OUT"/*) ;;
    *) echo "refusing to write outside $WORKROOT: $1" >&2; exit 1 ;;
  esac
}

GLOBAL_ARTIFACTS="declarations/declaration-data.bmp declarations/name-map.json \
navbar.html tactics.html references.html references.bib"

# Files a run does not produce are recorded as absent rather than skipped.
WORK_FILES="changed.txt removed.txt render-all.txt seen.txt ir-changed.txt \
global-set.txt impact-set.txt render-set.txt name-map-before.json \
global-delta.json prune.json"

record () { # record <name> <status>
  local name="$1" status="$2"
  printf '%s\n' "$status" > "$OUT/$name-status.txt"
  if [ -s "$OUT/$name-stderr.txt" ]; then
    printf 'yes\n' > "$OUT/$name-complained.txt"
  else
    printf 'no\n' > "$OUT/$name-complained.txt"
  fi
}

# The eight answers, taken out of the timings record the run wrote — the same
# contract `benchmarks/tools/analyze.ts` reads.
counts () { # counts <name> <timings json>
  python3 - "$2" "$OUT/$1-counts.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
keys = ["changed", "globalStale", "irChanged", "mode",
        "pagesRendered", "removed", "rounds", "staleFound"]
if os.path.isfile(src):
    with open(src, encoding="utf-8") as f:
        record = json.loads(f.read().strip())
    out = {key: record.get(key, "<absent>") for key in keys}
else:
    # A run that failed before writing its record. Recorded as a fact: an
    # implementation that produced no answers has to differ from one that did.
    out = {"timings": "absent"}
with open(dst, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

copy_work () { # copy_work <name> <work dir>
  local name="$1" work="$2" f
  rm -rf "$OUT/$name-work"
  mkdir -p "$OUT/$name-work"
  : > "$OUT/$name-work-present.txt"
  for f in $WORK_FILES; do
    if [ -f "$work/$f" ]; then
      cp "$work/$f" "$OUT/$name-work/$f"
      printf '%s\n' "$f" >> "$OUT/$name-work-present.txt"
    fi
  done
  LC_ALL=C sort "$OUT/$name-work-present.txt" -o "$OUT/$name-work-present.txt"
}

copy_globals () { # copy_globals <dest dir> <page tree>
  local dest="$1" pages="$2" f
  rm -rf "$dest"
  for f in $GLOBAL_ARTIFACTS; do
    mkdir -p "$dest/$(dirname "$f")"
    if [ -f "$pages/$f" ]; then
      cp "$pages/$f" "$dest/$f"
    else
      printf 'absent\n' > "$dest/$f.absent"
    fi
  done
}

page_list () { # page_list <name> <page tree>
  local name="$1" pages="$2"
  if [ -d "$pages" ]; then
    # LC_ALL=C: byte order, so the listing is a property of the tree and not of
    # the machine's locale.
    ( cd "$pages" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) > "$OUT/$name-pages.txt"
  else
    : > "$OUT/$name-pages.txt"
  fi
  printf 'files %s\n' "$(grep -c . "$OUT/$name-pages.txt" || true)" \
    > "$OUT/$name-pages-count.txt"
}

# Rebuild a whole site from the IR the round left behind and diff it against the
# pages the round left behind: one renderer on both sides of the diff.
sitecheck () { # sitecheck <name> <live dir> <url>
  local name="$1" d="$2" url="$3" status=0
  rm -rf "$d/sitecheck-site" "$d/sitecheck-state"
  "$LITEDOC4" site --ir "$d/ir" --out "$d/sitecheck-site" --source-url "$url" \
    --link-index "$LIDX" --state "$d/sitecheck-state" > "$d/sitecheck.log" 2>&1 || status=$?
  {
    printf 'site status       %s\n' "$status"
    printf 'incremental files %s\n' "$(find "$d/pages" -type f | wc -l | tr -d ' ')"
    printf 'from-scratch      %s\n' "$(find "$d/sitecheck-site" -type f | wc -l | tr -d ' ')"
    # /usr/bin/diff: `diff` is aliased to colordiff in this shell and colordiff
    # is not installed.
    if /usr/bin/diff -r -q "$d/pages" "$d/sitecheck-site" > "$d/sitecheck.diff" 2>&1; then
      printf 'diff              identical\n'
    else
      printf 'diff              %s line(s)\n' "$(grep -c . "$d/sitecheck.diff" || true)"
      sed 's/^/  /' "$d/sitecheck.diff"
    fi
  } > "$OUT/$name-sitecheck.txt"
}

mkdir -p "$OUT" "$WORKROOT"
FIX="$WORKROOT/fixtures"
mkdir -p "$FIX"

( cd "$TARGET" && LC_ALL=C find "$LIB.lean" "$LIB" -name '*.lean' | LC_ALL=C sort ) \
  | sed 's/\.lean$//; s#/#.#g' > "$OUT/modules-432.txt"
"$LITEDOC4" modules --root "$TARGET" --lib "$LIB" > "$WORKROOT/modules-from-cli.txt"
if ! /usr/bin/diff -q "$OUT/modules-432.txt" "$WORKROOT/modules-from-cli.txt" > /dev/null; then
  echo "the LC_ALL=C source glob and \`litedoc4 modules\` disagree — the run would" >&2
  echo "compare two different module orders, which makes two different ledgers and" >&2
  echo "two different index.json files. Refusing." >&2
  /usr/bin/diff "$OUT/modules-432.txt" "$WORKROOT/modules-from-cli.txt" | head -20 >&2
  exit 4
fi
NMODULES=$(grep -c . "$OUT/modules-432.txt" || true)
grep -vx "$ONE" "$OUT/modules-432.txt" > "$OUT/modules-431.txt"
NMODULES_LESS=$(grep -c . "$OUT/modules-431.txt" || true)
[ "$NMODULES_LESS" -eq $((NMODULES - 1)) ] || {
  echo "$ONE is not in the module list" >&2; exit 4; }

# Copied so that a scenario's in-place merge cannot reach the shared fixture.
rm -rf "$FIX/base-ir"
cp -R "$BASE_IR_SRC" "$FIX/base-ir"

# The base site and the cache, built by **this** run rather than borrowed.
rm -rf "$FIX/base-site" "$FIX/base-state"
mkdir -p "$FIX/base-site" "$FIX/base-state"
base_site "$FIX/base-ir" "$FIX/base-site" "$FIX/base-state" > "$WORKROOT/base-site.log" 2>&1
copy_globals "$OUT/base-global" "$FIX/base-site"
page_list base "$FIX/base-site"

# The two ledgers, also this run's and for the same reason.
ledger_build "$OUT/modules-432.txt" "$FIX/base-ir" "$FIX/base-ledger.json" \
  > "$WORKROOT/base-ledger.log" 2>&1
ledger_build "$OUT/modules-431.txt" "$FIX/base-ir" "$FIX/base-ledger-431.json" \
  > "$WORKROOT/base-ledger-431.log" 2>&1

# The base every scenario starts from, checked against the reference site the
# gate already accepted. Recorded, and skipped by the comparator.
if [ -d "$REF_SITE" ]; then
  {
    printf 'reference site    %s\n' "$REF_SITE"
    printf 'reference files   %s\n' "$(find "$REF_SITE" -type f | wc -l | tr -d ' ')"
    printf 'base files        %s\n' "$(find "$FIX/base-site" -type f | wc -l | tr -d ' ')"
    if /usr/bin/diff -r -q "$REF_SITE" "$FIX/base-site" > "$WORKROOT/base-sitecheck.diff" 2>&1; then
      printf 'diff              identical\n'
    else
      printf 'diff              %s line(s)\n' \
        "$(grep -c . "$WORKROOT/base-sitecheck.diff" || true)"
      sed 's/^/  /' "$WORKROOT/base-sitecheck.diff"
    fi
  } > "$OUT/base-sitecheck.txt"
fi

setup_live () { # setup_live <name> <ir src> <pages src> <ledger src> <state src>
  local d="$WORKROOT/$1"
  guard_writable "$d"
  rm -rf "$d"
  mkdir -p "$d/work"
  cp -R "$2" "$d/ir"
  cp -R "$3" "$d/pages"
  cp "$4" "$d/ledger.json"
  cp -R "$5" "$d/state"
}

run_scenario () { # run_scenario <name> <mode> <modules file> <url>
  local name="$1" mode="$2" modules="$3" url="$4"
  local d="$WORKROOT/$name" status=0
  guard_writable "$d"
  echo "### $name (mode $mode)"
  pipeline "$d/ir" "$d/pages" "$d/ledger.json" "$d/work" "$d/state" \
    "$modules" "$mode" "$url" "$d/timings.json" \
    > "$OUT/$name-stdout.txt" 2> "$OUT/$name-stderr.txt" || status=$?
  record "$name" "$status"
  counts "$name" "$d/timings.json"
  copy_work "$name" "$d/work"
  rm -rf "$OUT/$name-ir"
  cp -R "$d/ir" "$OUT/$name-ir"
  copy_globals "$OUT/$name-global" "$d/pages"
  page_list "$name" "$d/pages"
  sitecheck "$name" "$d" "$url"
  printf '  exit %s, %s page(s) in the tree\n' \
    "$status" "$(grep -c . "$OUT/$name-pages.txt" || true)"
}

# Nothing changed — the answer the pipeline sees most: 0 changed, an empty
# regeneration set, and the renderer never called.
if selected nochange; then
  setup_live nochange "$FIX/base-ir" "$FIX/base-site" "$FIX/base-ledger.json" "$FIX/base-state"
  run_scenario nochange self "$OUT/modules-432.txt" "$URL"
fi

# The minimal edit. `ledger touch` is the honest fake the whole experiment rests
# on — the measurement target must not be modified, so "M changed" is injected by
# invalidating M's ledger entry and everything downstream is real.
if selected self-one; then
  setup_live self-one "$FIX/base-ir" "$FIX/base-site" "$FIX/base-ledger.json" "$FIX/base-state"
  ledger_touch "$WORKROOT/self-one/ledger.json" "$ONE" > "$WORKROOT/self-one/touch.log"
  run_scenario self-one self "$OUT/modules-432.txt" "$URL"
fi

# The wide blast radius: `--mode importers` over a module 15 others import
# directly and 261 transitively (measured census).
if selected importers-hub; then
  setup_live importers-hub "$FIX/base-ir" "$FIX/base-site" "$FIX/base-ledger.json" "$FIX/base-state"
  ledger_touch "$WORKROOT/importers-hub/ledger.json" "$HUB" > "$WORKROOT/importers-hub/touch.log"
  run_scenario importers-hub importers "$OUT/modules-432.txt" "$URL"
fi

# Two modules and the other closure: `--mode referrers` is the direct one, and
# the hub has 49 direct referrers (measured census).
if selected referrers-two; then
  setup_live referrers-two "$FIX/base-ir" "$FIX/base-site" "$FIX/base-ledger.json" "$FIX/base-state"
  ledger_touch "$WORKROOT/referrers-two/ledger.json" "$HUB" > "$WORKROOT/referrers-two/touch.log"
  ledger_touch "$WORKROOT/referrers-two/ledger.json" "$OTHER" >> "$WORKROOT/referrers-two/touch.log"
  run_scenario referrers-two referrers "$OUT/modules-432.txt" "$URL"
fi

# Nothing touched, a different revision in `--source-url`: the render key moves,
# nothing is re-extracted, and `--mode self` is overridden with `all` — 432 pages.
if selected renderall; then
  setup_live renderall "$FIX/base-ir" "$FIX/base-site" "$FIX/base-ledger.json" "$FIX/base-state"
  run_scenario renderall self "$OUT/modules-432.txt" "$URL_NEXT"
fi

# The deletion path, end to end: the module list has one entry fewer, so `detect`
# reports it removed, `merge` drops it from the index and `prune` deletes its
# page. Nothing is re-extracted — round 1 runs for the deletion alone.
if selected removed-one; then
  setup_live removed-one "$FIX/base-ir" "$FIX/base-site" "$FIX/base-ledger.json" "$FIX/base-state"
  run_scenario removed-one self "$OUT/modules-431.txt" "$URL"
fi

# The addition path, on the trees the deletion left behind: a 431-entry ledger and
# a 432-entry module list, so the module comes back. The merged index is ordered
# by `--modules`, so the module returns to its sorted position rather than to the
# end — a difference no page byte says anything about.
if selected added-one; then
  setup_live added-one "$WORKROOT/removed-one/ir" "$WORKROOT/removed-one/pages" \
    "$FIX/base-ledger-431.json" "$WORKROOT/removed-one/state"
  run_scenario added-one self "$OUT/modules-432.txt" "$URL"
fi

# A number without its conditions cannot be read. Recorded and **not compared** —
# it differs between two recordings by construction (it names the clock and the
# extractor).
{
  record_host
  printf 'target            %s (%s modules)\n' "$TARGET" "$NMODULES"
  printf 'lean-toolchain    %s\n' "$(tr -d '\n' < "$TARGET/lean-toolchain" 2>/dev/null || echo '?')"
  printf 'extractor         %s (%s)\n' "$EXTRACTOR_IMPL" "$EXTRACTOR"
  printf 'extractor binary  %s (IR schema 5)\n' "$PRODUCT_EXTRACT_BIN"
  printf 'jobs              %s\n' "$JOBS"
  printf 'link index        %s (%s B)\n' "$LIDX" "$(wc -c < "$LIDX" | tr -d ' ')"
  printf 'base IR           %s\n' "$BASE_IR_SRC"
  printf 'source url        %s\n' "$URL"
  printf 'rustc             %s\n' "$(rustc --version 2>/dev/null || echo '?')"
  printf 'scenarios         %s\n' "${ONLY:-$ALL_SCENARIOS}"
} > "$OUT/conditions.txt"

# A manifest makes the tree verifiable later without rerunning anything, and
# makes an accidental edit loud.
( cd "$OUT" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 ) > "$OUT.sha256"

printf 'extractor: %s\n' "$EXTRACTOR_IMPL"
printf 'out: %s\n' "$OUT"
printf 'work: %s\n' "$WORKROOT"
printf 'files: %s\n' "$(find "$OUT" -type f | wc -l | tr -d ' ')"
printf 'manifest: %s\n' "$OUT.sha256"
