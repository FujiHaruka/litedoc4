#!/usr/bin/env bash
# Does the Lean `render` write the bytes the measurement target's documentation
# is made of?
#
# `purelean-micro-gate.sh` asks the same question over `e2e/micro` and is `ci`.
# This one is `manual` and it is not a bigger version of it: **it is the only
# place the target's 422 modules of Mathlib-depending Lean are rendered at all.**
# `e2e/micro` is eleven modules chosen for the shapes the target does not have
# (`e2e/README.md`), so a defect only the real corpus produces is visible here
# and nowhere else. The converse is measured: six product defects were found
# during the port with `purelean-micro-gate.sh` green through every one of them,
# because the sample cannot produce the shapes they need. A green byte oracle
# over one corpus is not evidence about another.
#
# **The oracle was the Rust binary, and it left with `crates/`.** What it wrote
# is frozen under `tools/purelean-render-expected/`, minted from it while it was
# still there — the binary is `git show rust-frozen:crates/litedoc4/src/main.rs`
# and the tree around it, in that tag and not in HEAD. The 7 items read the
# fixture, the target's IR and the tree, so every one of them goes on being a
# question.
#
# **One arm, and it used to be two.** The second asked whether the frozen data
# was still what the oracle said. It is retired; the summary line names it,
# because a one-armed run that printed nothing about it would read as the whole
# gate.
#
# **A rendered tree is 24 MB and there are three of them. What is frozen is the
# normal form, not the bytes** — `normalise` reduces a tree to one
# `<sha256>  <path>` line per file, sorted by path in code-point order, and that
# is the whole of the fixture's page data: 1,266 lines instead of 74 MB. The
# claim it keeps is "the Lean half writes exactly these bytes"; what it loses is
# **which** bytes differ. That loss is real and is not replaced by something
# weaker: when a page fails, the report names the path and both digests, and the
# tree is left in `--out` for `tools/render-compare.sh --all` to run against a
# tree you trust.
#
# **One `normalise`**, and two things it is careful about, because both would
# make a fixture that cannot travel:
#
#   - **paths are relative to the tree**, so the run's own `--pages` does not
#     reach the digest file
#   - **the sort is Python's, over code points**, not the shell's `sort`, whose
#     order is the caller's locale
#
# **The transcripts are frozen verbatim, and that is a finding rather than an
# omission.** The micro gate learnt the hard way that a value *derived* from
# something machine-specific is machine-specific too — it normalised the
# ledger's olean digests and sizes but not a ledger size a transcript printed,
# and 3489 B on macOS was 3507 B on Linux. Swept for that shape here before
# minting: `render` prints no path, no duration and no clock. Its five kinds of
# number are `declarations`, `module docs`, `bytes`, the three `known …` figures
# and the `deps` per-root counts, and **every one is derived from an input this
# fixture pins by digest** (the IR, the `.lidx`, the frozen dependency map) or
# from the page bytes themselves. `bytes 24546639` is the interesting one: it is
# derived from the pages, and the pages are **pinned, not normalised**, so the
# trap has no instance here. If a page byte ever did become machine-specific,
# `bytes` would move with it and item 7 would fail beside items 4–6 rather than
# instead of them.
#
# **The source URL is part of the fixture, not of the environment.** Every
# `source` link on every page carries it, so a gate that derived it from the
# target's HEAD would rewrite all 422 expected pages every time the target was
# committed to — comparing two checkouts as well as two renderers. `input.txt`
# records the string the fixture was minted with and the items render with that.
#
# **What the fixture cannot outlive, said plainly.** Its pages are the render of
# **one snapshot of the target**, and the target is a repository outside this
# one. Item 2 pins the IR and the `.lidx` by digest, so when the target's Lean
# sources, its toolchain or its Mathlib move, items 2 and 4–7 fail by name and
# stay failed: there is no oracle left to re-mint from, and a fixture minted from
# the Lean half would record what it does today, which is the question rather
# than the answer. Item 3 is what survives that — it needs no
# oracle and no fixture, and it goes on asking of any IR whether the render
# covered every module and wrote nothing else. Commits to the target that do not
# touch its Lean sources cost nothing: the URL is frozen and the IR digest does
# not move.
#
# What a failing item means:
#   1 BUILDS    `lake build litedoc4/litedoc4` in e2e/consumer produced no
#               binary: there is no Lean renderer to ask anything of.
#   2 INPUT     the IR or the `.lidx` at $PURELEAN_WORK is not the one the
#               fixture was minted from. Items 4–7 would then fail 422 pages at
#               a time for a reason that is not the port's, so this is asked
#               first and its message names which of the two moved and by how
#               much.
#   3 RENDERS   one of the three flows exited non-zero, or wrote a page set that
#               is not the IR's module set. **No oracle and no fixture**: one
#               page per module in `index.json` and no other file is a property
#               of the render alone, and it is what re-homes the target-reading
#               claim `reads_every_module_of_the_target_package` used to make
#               from `crates/`. Two empty trees compare identical, so this is
#               also what stops items 4–6 passing on nothing.
#   4 PAGES     with `--link-index`, some page is not its frozen digest.
#   5 NOLIDX    with `--no-link-index`, ditto. A separate item because the map
#               decides most of the links: agreeing with it and disagreeing
#               without it is a different defect from the reverse.
#   6 DEPSDOCS  `--deps-docs-map` folds where each dependency's documentation is
#               published into the links a page draws, and items 4 and 5 never
#               pass it — so a half that took the flag and ignored it writes
#               exactly the bytes they compare. Four claims, two of which need
#               nothing frozen: the flag moved at least one link to the base;
#               **the tree differs from item 4's**; the map the fixture holds is
#               still the one `lib/deps-docs-fixture.py` derives from this IR;
#               and the pages are the frozen digests. The map is built out of the
#               target's own `deps/*.json`, so this needs no network and no real
#               documentation site.
#   7 SUMMARY   a run's stdout differs from the frozen transcript. The failure
#               the digests cannot see: `math spans kept as LaTeX` reports a
#               fallback that renders a *valid* page, so a half that stopped
#               counting is 422 of 422 identical and silent. All three
#               transcripts, whole and not from the first counts line — the
#               `external` and `deps` blocks are printed above the counts.
#
# **There is no `--mint`.** What the fixture was minted against and what each
# mechanism prints when it fails are in
# `benchmarks/results/purelean-render-freeze-2026-08-31.txt`.
#
# usage: purelean-render-gate.sh [--out DIR] [--keep]
#   --out   working directory (default: a temporary one, removed on success)
#   --keep  do not remove a temporary --out
#
#   PURELEAN_WORK  where the target's IR and link index are
#                  (default /private/tmp/lean-doc-relay/purelean).
#                  **Nothing here writes into it.** To produce one:
#                    litedoc4 modules --root <target> --lib InformationTheory \
#                      --out $W/modules.txt
#                    litedoc4 extract --modules $W/modules.txt --ir-dir $W/ir \
#                      --timings $W/extract-timings.json --target <target> \
#                      --extractor-bin extractor/build/extract --jobs 4 \
#                      --link-index $W/link-index.lidx
#                    git -C <target> rev-parse HEAD >$W/rev.txt
#                  Either half writes the same IR and the same link index over
#                  this target (measured 2026-08-31 ->
#                  `benchmarks/results/purelean-target-build-2026-08-31.txt`), so
#                  the Lean one produces the input this gate pins.
#   LAKE           the lake executable (default: ~/.elan/bin/lake)
#   PYTHON         the python3 that normalises and compares (default python3)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
FIXTURE="$ROOT/e2e/consumer"
FROZEN="$ROOT/tools/purelean-render-expected"
LAKE="${LAKE:-$HOME/.elan/bin/lake}"
PYTHON="${PYTHON:-python3}"
LEAN_EXE="$ROOT/.lake/build/bin/litedoc4"
WORK="${PURELEAN_WORK:-/private/tmp/lean-doc-relay/purelean}"
# `diff` is aliased to a colordiff that is not installed here, and its exit 127
# reads as "differences found".
DIFF_CMD=/usr/bin/diff
DOCS_BASE=https://example.invalid/dep_docs

# The three flows, named once. The items render them and compare them against
# the frozen digests; a flow the fixture does not hold is a file no item reads,
# which the summary's reconciliation reports.
FLOWS="render nolidx depsdocs"

# Three trees at ~24 MB each. A run that fills the disk does not cost a
# measurement here: it costs the target repository's oleans and the shell that
# would repair them (CLAUDE.md).
FLOOR_MB=400

OUT=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '/^# usage:/,/^set -/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Hard exits rather than skips: an item that prints "no input" and returns 0 does
# not reach the exit code, which is how a gate goes green having checked nothing.
[ -x "$LAKE" ] || { echo "no lake at $LAKE — set LAKE" >&2; exit 2; }
[ -d "$WORK/ir/modules" ] || { echo "no target IR at $WORK/ir/modules — set PURELEAN_WORK, or produce one with the commands in this file's header" >&2; exit 2; }
[ -f "$FIXTURE/lakefile.toml" ] || { echo "no consumer fixture at $FIXTURE" >&2; exit 2; }

# `link-index.json` is what the prototype's work areas were called and some still
# are; the bytes are the same line-oriented `.lidx` either way. Resolved once,
# here, so no item has to know there are two spellings.
LIDX=""
for candidate in "$WORK/link-index.lidx" "$WORK/link-index.json"; do
  if [ -f "$candidate" ]; then LIDX="$candidate"; break; fi
done
[ -n "$LIDX" ] || { echo "no link index at $WORK/link-index.lidx — set PURELEAN_WORK" >&2; exit 2; }

  [ -d "$FROZEN" ] || { echo "no frozen data at $FROZEN — the items have nothing to compare against" >&2; exit 2; }
  # An empty fixture reconciles 0 against 0 and compares empty manifests against
  # empty trees. Several items would still fail on their own counts, but this is
  # the shape itself, said once.
  [ "$( ( cd "$FROZEN" && find . -type f ) | wc -l | tr -d ' ')" -gt 0 ] ||
    { echo "$FROZEN holds no frozen file — every item below would compare against nothing" >&2; exit 2; }
  for part in input.txt deps-docs.json; do
    [ -f "$FROZEN/$part" ] ||
      { echo "no $FROZEN/$part — the fixture is incomplete; it is complete at tag rust-frozen" >&2; exit 2; }
  done
  for flow in $FLOWS; do
    [ -f "$FROZEN/$flow.sha256" ] && [ -f "$FROZEN/$flow.out" ] ||
      { echo "no $FROZEN/$flow.{sha256,out} — the fixture is incomplete; it is complete at tag rust-frozen" >&2; exit 2; }
  done

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d)"
  TEMPORARY=1
else
  mkdir -p "$OUT"
  TEMPORARY=0
fi

free_mb () { df -Pk "$1" | awk 'NR==2 { print int($4 / 1024) }'; }
FREE_AT_START="$(free_mb "$OUT")"
[ "$FREE_AT_START" -ge "$FLOOR_MB" ] ||
  { echo "only ${FREE_AT_START} MB free at $OUT and this run writes about 150 MB — refusing to start (need ${FLOOR_MB} MB)" >&2; exit 2; }

ITEMS=7
ran=0
failed=0
entries_compared=0
: >"$OUT/frozen-used.txt"

pass () { ran=$((ran + 1)); printf 'ITEM %s ok    %s\n' "$1" "$2"; }
fail () { ran=$((ran + 1)); failed=$((failed + 1)); printf 'ITEM %s FAIL  %s\n' "$1" "$2" >&2; }
say  () { printf '\n=== %s\n' "$1"; }

# Every frozen file an item compared, so the summary can reconcile the fixture
# against what was read. A frozen file no item reads is a fixture nobody is held
# to, and an item that compared nothing is the green-having-checked-nothing shape.
used () { printf '%s\n' "$@" >>"$OUT/frozen-used.txt"; }

# The one normaliser: a rendered tree becomes one `<sha256>  <path>` line per
# file. Relative paths and a code-point sort, so neither the run's own `--pages`
# nor the caller's locale reaches the digest file.
normalise () { # <tree>
  "$PYTHON" - "$1" <<'PY'
import hashlib
import os
import sys

root = sys.argv[1]
rows = []
for dirpath, dirnames, filenames in os.walk(root):
    for name in filenames:
        path = os.path.join(dirpath, name)
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        rows.append((os.path.relpath(path, root), digest))
rows.sort()
for relative, digest in rows:
    print(f"{digest}  {relative}")
PY
}

sha_file () { # <file>
  "$PYTHON" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

field () { awk -v k="$2" '$1 == k { print $2; exit }' "$1"; }

# A gate may not answer "something differs, look in this file". `|| true`:
# `pipefail` is on, and a grep that matches nothing would make the assignment
# fail and, under `set -e`, cut the message short instead of printing an empty one.
line_gist () { grep -E '^[<>]' "$1" | head -2 | cut -c1-90 | tr '\n' ' ' || true; }

# Hold a live tree to a frozen manifest and say which page, not "something
# differs". The counts come out of the comparison itself rather than from a tally
# an item wrote down: `compared` has to reconcile against the frozen file's own
# line count, which is what stops a comparison of two empty things reporting ok.
compare_manifest () { # <frozen.sha256> <live tree> <report>
  local rc=0
  normalise "$2" >"$3.live"
  manifest_report "$1" "$3.live" >"$3" 2>&1 || rc=$?
  echo "$rc"
}

manifest_report () { # <frozen.sha256> <live.sha256>
  "$PYTHON" - "$1" "$2" <<'PY'
import sys


def read(path):
    rows = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            digest, _, relative = line.rstrip("\n").partition("  ")
            if relative:
                rows[relative] = digest
    return rows


frozen, live = read(sys.argv[1]), read(sys.argv[2])
missing = sorted(set(frozen) - set(live))
extra = sorted(set(live) - set(frozen))
differing = sorted(p for p in set(frozen) & set(live) if frozen[p] != live[p])
identical = len(set(frozen) & set(live)) - len(differing)
print(f"compared  {len(frozen)}")
print(f"identical {identical}")
print(f"differing {len(differing)}")
print(f"missing   {len(missing)}")
print(f"extra     {len(extra)}")
for path in differing[:10]:
    print(f"--- differing {path}: frozen {frozen[path][:16]}, got {live[path][:16]}")
for path in missing[:10]:
    print(f"--- missing {path}: frozen {frozen[path][:16]}, not written")
for path in extra[:10]:
    print(f"--- extra {path}: written, not in the fixture")
sys.exit(0 if not (missing or extra or differing) else 1)
PY
}

# Every module in the IR got a page, and nothing else was written. No oracle and
# no fixture: this is what an item can still ask when the target has moved on
# from the snapshot the pages were frozen at.
coverage () { # <tree> <ir index.json>
  "$PYTHON" - "$1" "$2" <<'PY'
import json
import os
import sys

tree, index_path = sys.argv[1], sys.argv[2]
with open(index_path, encoding="utf-8") as handle:
    modules = [entry["module"] for entry in json.load(handle)["modules"]]
want = {module.replace(".", "/") + ".html" for module in modules}
have = set()
for dirpath, dirnames, filenames in os.walk(tree):
    for name in filenames:
        have.add(os.path.relpath(os.path.join(dirpath, name), tree))
missing, extra = sorted(want - have), sorted(have - want)
if not modules:
    print("the IR names no module, so any tree at all would cover it")
elif missing:
    print(f"{len(missing)} of {len(modules)} module(s) got no page, first {missing[0]}")
elif extra:
    print(f"{len(extra)} file(s) no module asked for, first {extra[0]}")
else:
    print(f"{len(want)} page(s), one per module")
    sys.exit(0)
sys.exit(1)
PY
}

# No pipe between the command and the status this gate judges on: through a pipe
# the status read back is the last command's, and `litedoc4` exiting 3 looks
# like 0 (measured 2026-08-18).
#
# Apart, not `2>&1`: item 7 reads the summary out of stdout, and a warning on
# stderr interleaved into it would be compared as though the run had printed it.
render () { # <binary> <flow> <pages> <log prefix> <source url> <deps map|"">
  local exe="$1" flow="$2" pages="$3" log="$4" url="$5" map="$6"
  local rc=0
  case "$flow" in
    render)   set -- --link-index "$LIDX" ;;
    nolidx)   set -- --no-link-index ;;
    depsdocs) set -- --link-index "$LIDX" --deps-docs-map "$map" ;;
    *) echo "render: unknown flow $flow" >&2; return 2 ;;
  esac
  "$exe" render --ir "$WORK/ir" --pages "$pages" --source-url "$url" "$@" \
    >"$log.out" 2>"$log.err" || rc=$?
  echo "$rc"
}

say "1/7 the Lean half builds from a consumer's workspace"
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

# The map both arms render with, and one of item 6's four claims. Taken from the
# fixture rather than from the generator so that the third flow's input is as
# fixed as the other two's; whether the generator still writes it is asked
# separately, in item 6.
FROZEN_MAP="$FROZEN/deps-docs.json"
"$PYTHON" "$HERE/lib/deps-docs-fixture.py" "$WORK/ir" "$OUT/deps-docs.json" "$DOCS_BASE" \
  >"$OUT/deps-docs.log" 2>&1

IR_DIGEST="$(normalise "$WORK/ir" | "$PYTHON" -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
IR_FILES="$(find "$WORK/ir" -type f | wc -l | tr -d ' ')"
IR_BYTES="$(find "$WORK/ir" -type f -exec cat {} + | wc -c | tr -d ' ')"
IR_MODULES="$("$PYTHON" -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["modules"]))' "$WORK/ir/index.json")"
LIDX_SHA="$(sha_file "$LIDX")"
LIDX_BYTES="$(wc -c <"$LIDX" | tr -d ' ')"
# `?` rather than an empty field when the work area carries no rev: an empty
# column is visibly missing where a blank one reads as a value (lib/common.sh).
REV='?'
if [ -s "$WORK/rev.txt" ]; then REV="$(tr -d ' \n' <"$WORK/rev.txt")"; fi

say "2/7 the IR and the link index are the ones the fixture was minted from"
used input.txt
SOURCE_URL="$(field "$FROZEN/input.txt" sourceUrl)"
want_ir="$(field "$FROZEN/input.txt" irDigest)"
want_lidx="$(field "$FROZEN/input.txt" lidxSha256)"
want_modules="$(field "$FROZEN/input.txt" modules)"
want_ir_bytes="$(field "$FROZEN/input.txt" irBytes)"
want_lidx_bytes="$(field "$FROZEN/input.txt" lidxBytes)"
minted_rev="$(field "$FROZEN/input.txt" targetRev)"
input_ok=0
if [ -z "$SOURCE_URL" ] || [ -z "$want_ir" ] || [ -z "$want_lidx" ]; then
  fail 2 "$FROZEN/input.txt names no sourceUrl, irDigest or lidxSha256 — the fixture is damaged; it is whole at tag rust-frozen"
elif [ "$IR_DIGEST" != "$want_ir" ]; then
  fail 2 "the IR at $WORK/ir is not the one the fixture was minted from (frozen $want_modules module(s) / $want_ir_bytes B at $minted_rev, got $IR_MODULES / $IR_BYTES at $REV) — items 4 to 7 cannot be asked of it"
elif [ "$LIDX_SHA" != "$want_lidx" ]; then
  fail 2 "the link index at $LIDX is not the one the fixture was minted from (frozen $want_lidx_bytes B, got $LIDX_BYTES B) — items 4 to 7 cannot be asked of it"
else
  pass 2 "$IR_MODULES modules / $IR_BYTES B of IR and $LIDX_BYTES B of link index, at target $minted_rev"
  input_ok=1
fi

say "3/7 the three flows run, and each writes one page per module and no more"
rendered=0
if [ "$built" -eq 1 ]; then
  flow_problem=""
  flow_note=""
  for flow in $FLOWS; do
    rm -rf "$OUT/lean-$flow"
    rc="$(render "$LEAN_EXE" "$flow" "$OUT/lean-$flow" "$OUT/lean-$flow" "${SOURCE_URL:-https://example.invalid/blob/HEAD}" "$FROZEN_MAP")"
    if [ "$rc" -ne 0 ]; then
      flow_problem="${flow_problem:-$flow exited $rc — see $OUT/lean-$flow.err}"
      continue
    fi
    if note="$(coverage "$OUT/lean-$flow" "$WORK/ir/index.json")"; then
      flow_note="$note"
    else
      flow_problem="${flow_problem:-$flow: $note}"
    fi
  done
  if [ -n "$flow_problem" ]; then
    fail 3 "$flow_problem"
  else
    pass 3 "3 flows, $flow_note; $(find "$OUT/lean-render" -type f -exec cat {} + | wc -c | tr -d ' ') bytes with the link index"
    rendered=1
  fi
else
  fail 3 "no Lean binary to run — item 1 did not build one"
fi

compare_flow () { # <item> <flow> <what>
  local item="$1" flow="$2" what="$3" rc=0
  used "$flow.sha256"
  rc="$(compare_manifest "$FROZEN/$flow.sha256" "$OUT/lean-$flow" "$OUT/compare-$item.txt")"
  local compared frozen_lines
  compared="$(field "$OUT/compare-$item.txt" compared)"
  frozen_lines="$(wc -l <"$FROZEN/$flow.sha256" | tr -d ' ')"
  if [ "${compared:-0}" -ne "$frozen_lines" ]; then
    fail "$item" "$what: the comparison accounted for ${compared:-0} of the fixture's $frozen_lines entr(ies) — see $OUT/compare-$item.txt"
    return 0
  fi
  entries_compared=$((entries_compared + compared))
  if [ "$rc" -ne 0 ]; then
    fail "$item" "$what: $(field "$OUT/compare-$item.txt" differing) differing, $(field "$OUT/compare-$item.txt" missing) missing, $(field "$OUT/compare-$item.txt" extra) extra of $compared; $( { grep -m1 '^--- ' "$OUT/compare-$item.txt" || true; } | sed 's/^--- //') — see $OUT/compare-$item.txt"
  else
    pass "$item" "$what: $compared frozen digest(s), $(find "$OUT/lean-$flow" -type f -exec cat {} + | wc -c | tr -d ' ') bytes"
  fi
}

say "4/7 with --link-index, every page is its frozen digest"
if [ "$rendered" -eq 1 ] && [ "$input_ok" -eq 1 ]; then
  compare_flow 4 render "--link-index"
else
  fail 4 "the render did not run over the pinned input — item 2 or 3 says why"
fi

say "5/7 with --no-link-index, every page is its frozen digest"
if [ "$rendered" -eq 1 ] && [ "$input_ok" -eq 1 ]; then
  compare_flow 5 nolidx "--no-link-index"
else
  fail 5 "the render did not run over the pinned input — item 2 or 3 says why"
fi

say "6/7 --deps-docs-map moves links, changes the tree, and writes the frozen digests"
if [ "$rendered" -eq 1 ]; then
  used deps-docs.json
  # `|| true` inside the substitution, not after it: `grep` finding nothing exits
  # 1, and under `pipefail` that kills the script — which is the state this item
  # exists to *report*, so without it the one failure it is for is the one it
  # cannot say (measured: the first run of this item against a Lean half with the
  # documentation link disabled printed nothing at all).
  hrefs="$( { grep -rl -- "$DOCS_BASE" "$OUT/lean-depsdocs" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  same_as_plain=0
  if $DIFF_CMD -r "$OUT/lean-render" "$OUT/lean-depsdocs" >/dev/null 2>&1; then same_as_plain=1; fi
  map_rc=0
  $DIFF_CMD "$FROZEN_MAP" "$OUT/deps-docs.json" >"$OUT/deps-docs.diff" 2>&1 || map_rc=$?
  if [ "$hrefs" -eq 0 ]; then
    fail 6 "no page links at $DOCS_BASE — the flag was accepted and changed nothing"
  elif [ "$same_as_plain" -eq 1 ]; then
    fail 6 "the --deps-docs-map tree is byte-identical to item 4's — the map was read and not used"
  elif [ "$map_rc" -ne 0 ]; then
    fail 6 "the map lib/deps-docs-fixture.py derives from this IR is no longer the frozen one ($(cat "$OUT/deps-docs.log")) — see $OUT/deps-docs.diff"
  elif [ "$input_ok" -ne 1 ]; then
    fail 6 "the render did not run over the pinned input — item 2 says why"
  else
    compare_flow 6 depsdocs "--deps-docs-map ($hrefs page(s) link at $DOCS_BASE)"
  fi
else
  fail 6 "nothing was rendered — item 3 says why"
fi

say "7/7 the three runs print the frozen transcripts"
# Whole, and not a slice: both halves take `--root`, so the `external` block one
# prints is the other's too, and a comparison that began at the first counts line
# would swallow a difference in the dependency map the run resolved. The `-s`
# test is what keeps two empty files from comparing equal — a run that printed
# nothing at all is exactly when that would happen.
if [ "$rendered" -eq 1 ] && [ "$input_ok" -eq 1 ]; then
  transcript_problem=""
  transcript_lines=0
  for flow in $FLOWS; do
    used "$flow.out"
    if [ ! -s "$OUT/lean-$flow.out" ]; then
      transcript_problem="${transcript_problem:-$flow printed nothing at all}"
    elif [ ! -s "$FROZEN/$flow.out" ]; then
      transcript_problem="${transcript_problem:-the fixture holds an empty $flow.out}"
    elif ! $DIFF_CMD "$FROZEN/$flow.out" "$OUT/lean-$flow.out" >"$OUT/summary-$flow.diff" 2>&1; then
      # Assigned in two steps: bash 3.2 mis-parses a command substitution that
      # carries its own quotes inside a `${var:-…}` default (measured here —
      # `unexpected EOF while looking for matching }`). And `${gist}` in braces,
      # because the em dash after it is multi-byte and bash reads its first byte
      # as part of the name: `$gist—` is `gist\xe2`, which under `set -u` aborts
      # the run with `unbound variable` *while reporting a failure* (measured).
      gist="$(line_gist "$OUT/summary-$flow.diff")"
      transcript_problem="${transcript_problem:-$flow: ${gist}— see $OUT/summary-$flow.diff}"
    else
      transcript_lines=$((transcript_lines + $(wc -l <"$OUT/lean-$flow.out" | tr -d ' ')))
    fi
  done
  if [ -n "$transcript_problem" ]; then
    fail 7 "$transcript_problem"
  else
    pass 7 "$transcript_lines frozen line(s) across 3 transcript(s), normalised in 0 places"
  fi
else
  fail 7 "the render did not run over the pinned input — item 2 or 3 says why"
fi

# The arm that expired with `crates/`. It ran the oracle through the same
# flows and compared what it wrote against the fixture; there is nothing to
# run it against now, and the line below says so rather than leaving a
# one-armed run to read as the whole gate.
say "oracle arm — retired with crates/"
printf 'oracle arm     : retired — the fixture was minted from the Rust litedoc4 at\n'
printf '                 tag rust-frozen, and nothing re-asks it. When the target moves,\n'
printf '                 items 2 and 4-7 fail by name and stay failed; item 3 is what\n'
printf '                 goes on being asked of any IR.\n'

say "summary"
frozen_used="$(sort -u "$OUT/frozen-used.txt" | wc -l | tr -d ' ')"
printf 'items reported : %s of %s\n' "$ran" "$ITEMS"
printf 'frozen files   : %s of %s read\n' "$frozen_used" "$frozen_total"
printf 'manifest       : %s of %s entr(ies) compared\n' "$entries_compared" "$frozen_entries"
printf 'failed         : %s\n' "$failed"
printf 'out            : %s (%s MB free before, %s MB now)\n' "$OUT" "$FREE_AT_START" "$(free_mb "$OUT")"

if [ "$ran" -ne "$ITEMS" ]; then
  echo "PURELEAN RENDER GATE: FAILED — $ran of $ITEMS items reported a result; the rest never ran" >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "PURELEAN RENDER GATE: FAILED ($failed of $ITEMS)" >&2
  exit 1
fi
# Both directions, on files and on entries alike: a frozen line no item reads is
# a fixture nobody is held to, and an item that compared nothing is the
# green-having-checked-nothing shape.
if [ "$frozen_used" -ne "$frozen_total" ]; then
  sort -u "$OUT/frozen-used.txt" >"$OUT/frozen-used-sorted.txt"
  ( cd "$FROZEN" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) >"$OUT/frozen-all.txt"
  unread="$(/usr/bin/comm -23 "$OUT/frozen-all.txt" "$OUT/frozen-used-sorted.txt" | head -1)"
  echo "PURELEAN RENDER GATE: FAILED — $frozen_used of $frozen_total frozen file(s) were read${unread:+; first one no item reads: $unread}" >&2
  exit 1
fi
if [ "$entries_compared" -ne "$frozen_entries" ]; then
  echo "PURELEAN RENDER GATE: FAILED — $entries_compared of $frozen_entries manifest entr(ies) were compared" >&2
  exit 1
fi

# `if`, not `&&`: the last command in this block decides the script's exit code,
# and a `&&` whose left side is false returns 1 while the summary says ok.
if [ "$TEMPORARY" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
  rm -rf "$OUT"
fi
echo
echo "PURELEAN RENDER GATE: ok ($ran/$ITEMS items; the oracle arm is retired)"
