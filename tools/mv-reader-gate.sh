#!/usr/bin/env bash
# `build --versions` filling the store through the .olean reader, on S with a
# sixth version: tools/mv-s/ generated as v1..v6, v6 being v5 on the last row of
# tools/lean-toolchains.txt, the reader's toolchain. tools/mv-s-gate.sh asks
# nothing of v6 and keeps its five versions; this gate has its own work area.
#
#   native-add            a store filled natively: v1..v5 (the newest is not on
#                         the reader's toolchain) extract 5 of 5, then v1..v6
#                         over that store adds v6 alone; every record says `own`.
#                         It is the oracle the items below compare against
#   reader-empty          an empty store and v1..v6 with --reader-session: v6
#                         extracted, v1..v5 read through the reader, counted on
#                         stdout and in the marker, `fill` in each record; v6
#                         first, then each older version, a disk line after every
#                         phase; one reader session for the five, v1 built whole
#                         and each later one patched from the one before, stopped
#                         after 5 requests; the
#                         sample's ../micro-dep, which every checkout's lake
#                         build rewrites, read on the newest side from its
#                         copy; nothing left checked out; v6's entry is
#                         native-add's byte for byte; the site renders all six
#   reader-equals-native-<v>
#                         each reader-filled entry's IR and link index against
#                         the same version's native entry, through
#                         tools/lib/reader-compare.py (the comparator
#                         tools/reader-hybrid-gate.sh uses)
#   patched-equals-alone  an empty store and v1..v6 with --reader-alone, each of
#                         v1..v5 read by a reader process of its own: the five
#                         entries equal reader-empty's (the session's) byte for
#                         byte, record.json and entry.pack.gz, 5 of 5
#   check-keys            an empty store and v1..v6 with --reader-session
#                         --reader-check: the session builds every round's
#                         environment from scratch
#                         too and computes every print key afresh; each of the 5
#                         rounds reports 0 modules and 0 keys differing, and the
#                         five entries equal reader-empty's byte for byte
#   reuse-from-native     an empty store and v1..v6 with no reader flag, the
#                         chain: v6 extracted natively with reuse keys, then v5
#                         down to v1, each in a reader process of its own; v5
#                         reuses prints from v6's IR, its `reuse-from` line
#                         saying "printing identity equal" and at least one
#                         declaration reused
#   chain                 the same build: v4, v3, v2 and v1 each reuse from the
#                         version above it, identity equal and at least one
#                         reused; each of v1..v5's record names the version its
#                         prints were reused from, and v6's names none; the
#                         reads ran newest first; nothing is left under <out>
#                         but the store, the site and the extractors
#   chain-link-index-equals-alone
#                         each of v1..v5's link index in that store is byte-equal
#                         to the --reader-alone store's (patched-equals-alone's
#                         own --out); the IR is not compared, reuse being inexact
#                         by design
#   chain-no-neighbour    a store holding only v6, copied from the chain's, and
#                         v5,v6: v5 is read through the reader and its line says
#                         without reuse, because v6 is kept from the store; no
#                         `reuse-from` line, exit 0, and the entry equals the
#                         --reader-alone store's v5 byte for byte
#   exact-refills-reused  a copy of the chain's store and v1..v6 with
#                         --reader-alone: v1..v5, their prints reused, are each
#                         judged so and read again, into the --reader-alone
#                         store's entries byte for byte; v6 is kept
#   chain-keeps-exact     a copy of the --reader-alone store and v1..v6 with no
#                         reader flag extracts 0 of 6: an exact entry serves the
#                         chain
#   reader-again          the same command again extracts 0 of 6 and changes
#                         no entry; this item and the four below pass
#                         --reader-session, so that store stays the session's
#   reader-remove-one     v3 removed from the store: the store still holds older
#                         versions, so v3 is extracted natively, into native-add's
#                         v3 byte for byte
#   reader-force          --through-reader v3 over that store refills v3 through
#                         the reader, into reader-empty's v3 byte for byte
#   reader-identity       the recorded reader= digest altered in every
#                         reader-filled record refills exactly those five,
#                         through the reader, into the same bytes; then
#                         no_equations_under added to the root's litedoc4.toml
#                         refills all six, and every record carries it
#   reader-refuse-newest  --through-reader with v1..v5, whose newest is not on
#                         the reader's toolchain: exit 3, refused by name before
#                         --out is created
#
# Each check prints `ok|FAIL <item>: <what>`; the items that reported are
# reconciled against the items declared.
#
# usage: tools/mv-reader-gate.sh [--out DIR] [--keep]
#   --out   the work directory (default: /private/tmp/lean-doc-relay/mv-reader),
#           absent, empty, or one this gate made
#   --keep  keep the work directory after a run that passed
#   LITEDOC4 / LAKE  the binaries (default: .lake/build/bin/litedoc4, ~/.elan/bin/lake)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
answer_required

LAKE="${LAKE:-$HOME/.elan/bin/lake}"
LITEDOC4="${LITEDOC4:-$ROOT/.lake/build/bin/litedoc4}"
INVENTORY="$ROOT/tools/lean-toolchains.txt"
WORK=/private/tmp/lean-doc-relay/mv-reader
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) WORK="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d'; answer 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
case "$WORK" in /*) ;; *) WORK="$PWD/$WORK" ;; esac

command -v "$LAKE" >/dev/null 2>&1 || { echo "no lake at $LAKE; set LAKE" >&2; exit 2; }
[ -x "$LITEDOC4" ] || {
  echo "no litedoc4 at $LITEDOC4; tools/build-lean-exe.sh --toolchain-from e2e/micro" >&2; exit 2; }

MARK=.mv-reader-gate
if [ -e "$WORK" ] && [ ! -f "$WORK/$MARK" ] && [ -n "$(ls -A "$WORK")" ]; then
  echo "$WORK is not empty and is not a work directory of this gate; refusing to delete it" >&2
  exit 2
fi
rm -rf "$WORK"
mkdir -p "$WORK/logs"
touch "$WORK/$MARK"
PASSED=0
on_exit 'if [ "$PASSED" -eq 0 ]; then echo "work directory left for reading at $WORK" >&2; elif [ "$KEEP" -eq 1 ]; then echo "work directory kept at $WORK"; else rm -rf "$WORK"; fi'

LOGS="$WORK/logs"
REPO="$WORK/repo"
NAT="$WORK/native"
RD="$WORK/reader"
ALONE="$WORK/alone"
CHECK="$WORK/check"
CHAIN="$WORK/chain"
NONB="$WORK/no-neighbour"
EXACT="$WORK/exact-over-chain"
KEEPS="$WORK/chain-over-exact"
FIRST="$WORK/reader-first"
OLDER=(v1 v2 v3 v4 v5)
ALL=(v1 v2 v3 v4 v5 v6)
FLAGS=(--equations --refs --write-ir --tagged-code)
list () { (IFS=,; echo "$*"); }
names () { local s; s="$(printf '%s, ' "$@")"; echo "${s%, }"; }
ALL_LIST="$(list "${ALL[@]}")"
OLDER_LIST="$(list "${OLDER[@]}")"
STARTED=$SECONDS

DECLARED=(native-add reader-empty)
for v in "${OLDER[@]}"; do DECLARED+=("reader-equals-native-$v"); done
DECLARED+=(patched-equals-alone check-keys)
DECLARED+=(reuse-from-native chain chain-link-index-equals-alone chain-no-neighbour)
DECLARED+=(exact-refills-reused chain-keeps-exact)
DECLARED+=(reader-again reader-remove-one reader-force reader-identity reader-refuse-newest)

RAN=()
FAILED=0
item () {
  printf '%s %s: %s\n' "$1" "$2" "$3"
  RAN+=("$2")
  if [ "$1" != ok ]; then FAILED=$((FAILED + 1)); fi
}
say () { printf '\n=== %s\n' "$1"; }

# usage: build <log name> <out> <version list> [flags...]; prints what `versions extracted:` said
build () {
  local name="$1" out="$2" versions="$3" t0=$SECONDS
  shift 3
  "$LITEDOC4" build --root "$REPO" --out "$out" --versions "$versions" --lake "$LAKE" ${1+"$@"} \
    >"$LOGS/$name.log" 2>&1 || true
  printf '%-22s %s s\n' "$name" "$((SECONDS - t0))" >>"$WORK/times.txt"
  sed -n 's/^versions extracted: //p' "$LOGS/$name.log"
}
rendered () { sed -n 's/^versions rendered: //p' "$LOGS/$1.log"; }
fills () {
  python3 - "$1" "${@:2}" <<'PY'
import json, pathlib, sys
store = pathlib.Path(sys.argv[1])
print(" ".join(json.loads((store / v / "record.json").read_text(encoding="utf-8"))["fill"] for v in sys.argv[2:]))
PY
}
same_entries () { # same_entries <store a> <store b> <version>...; prints the entries that differ
  local a="$1" b="$2" v f out=""
  shift 2
  for v in "$@"; do
    for f in record.json entry.pack.gz; do
      if ! cmp -s "$a/$v/$f" "$b/$v/$f"; then out="$out $v/$f"; fi
    done
  done
  echo "${out# }"
}
spelling_of () {
  awk -v tc="$1" '{ sub(/#.*/, "") } NF && $1 == tc { print $2 }' "$INVENTORY"
}

say "1/14 S as six versions"
"$HERE/mv-s/generate.sh" --out "$REPO" --versions 6 >"$LOGS/generate.log" 2>&1
cat "$LOGS/generate.log"
READER_TC="$(awk '{ sub(/#.*/, "") } NF { tc = $1 } END { print tc }' "$INVENTORY")"
V6_TC="$(git -C "$REPO" show v6:lean-toolchain)"
V5_TC="$(git -C "$REPO" show v5:lean-toolchain)"
if [ "$V6_TC" != "$READER_TC" ]; then
  echo "S's v6 pins $V6_TC and the reader's toolchain is $READER_TC: tools/mv-s/v6.patch has to follow the last row of $INVENTORY" >&2
  exit 1
fi
for out in "$NAT" "$RD" "$ALONE" "$CHECK" "$CHAIN" "$NONB" "$EXACT" "$KEEPS"; do mkdir -p "$out"; cp -R "$WORK/micro-dep" "$out/micro-dep"; done

say "2/14 native-add: the oracle, filled natively"
said_five="$(build native-five "$NAT" "$OLDER_LIST")"
said_six="$(build native-six "$NAT" "$ALL_LIST")"
native_fills="$(fills "$NAT/store" "${ALL[@]}" 2>&1 || true)"
if [ "$said_five" != "5 of 5 ($(names "${OLDER[@]}"))" ]; then
  item FAIL native-add "v1..v5 said \`versions extracted: ${said_five:-<no line>}\` ($LOGS/native-five.log)"
elif [ "$said_six" != "1 of 6 (v6)" ]; then
  item FAIL native-add "v1..v6 over that store said \`versions extracted: ${said_six:-<no line>}\`, expected \`1 of 6 (v6)\` ($LOGS/native-six.log)"
elif [ "$native_fills" != "own own own own own own" ]; then
  item FAIL native-add "the records' fill is $native_fills"
else
  item ok native-add "v1..v5: $said_five; v1..v6 over that store: $said_six; every record fill=own"
fi

say "3/14 reader-empty: an empty store and v1..v6"
said="$(build reader-empty "$RD" "$ALL_LIST" --reader-session)"
want="6 of 6 ($(names "${ALL[@]}")), through the reader: 5 ($(names "${OLDER[@]}"))"
reader_fills="$(fills "$RD/store" "${ALL[@]}" 2>&1 || true)"
marked="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); e=m["versionsThroughReader"]; print(m["complete"], e["count"], e["of"], ",".join(e["names"]))' "$RD/litedoc4-build.json" 2>&1 || true)"
order="$(grep -E '^phase +(v6 extract|v[1-5] read) ' "$LOGS/reader-empty.log" | awk '{ print $2 }' | tr '\n' ' ' || true)"
disk_reads="$(grep -cE '^disk +v[1-5] read [0-9.]+ GiB free$' "$LOGS/reader-empty.log" || true)"
v6_differs="$(same_entries "$NAT/store" "$RD/store" v6)"
copied="$(grep -cE "^newest  $RD/micro-dep/\.lake/build/lib/lean -> $RD/newest-search/0: " "$LOGS/reader-empty.log" || true)"
left="$(ls -d "$RD/checkout" "$RD/checkout-read" "$RD/newest-search" "$RD/scratch" 2>/dev/null | tr '\n' ' ' || true)"
session_lines="$(grep -E '^version v[1-5]: reading [0-9a-f]+ on .* in the reader session, ' "$LOGS/reader-empty.log" | sed 's/.* in the reader session, //' | tr '\n' ';' || true)"
want_session="built whole;patched from v1;patched from v2;patched from v3;patched from v4;"
stopped="$(grep -cE '^session stopped after 5 request\(s\)$' "$LOGS/reader-empty.log" || true)"
site_versions="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d if isinstance(d, list) else d.get("versions", [])))' "$RD/site/versions.json" 2>&1 || true)"
if [ "$said" != "$want" ]; then
  item FAIL reader-empty "said \`versions extracted: ${said:-<no line>}\`, expected \`$want\` ($LOGS/reader-empty.log)"
elif [ "$reader_fills" != "reader reader reader reader reader own" ]; then
  item FAIL reader-empty "the records' fill is $reader_fills, expected reader for v1..v5 and own for v6"
elif [ "$marked" != "True 5 6 $OLDER_LIST" ]; then
  item FAIL reader-empty "the marker records (complete, count, of, names) through the reader = $marked"
elif [ "$order" != "v6 v1 v2 v3 v4 v5 " ]; then
  item FAIL reader-empty "the phases ran in the order $order, expected v6's extraction first, then each read"
elif [ "$session_lines" != "$want_session" ]; then
  item FAIL reader-empty "the versions read said \`$session_lines\`, expected \`$want_session\`"
elif [ "$stopped" != 1 ]; then
  item FAIL reader-empty "$stopped line(s) \`session stopped after 5 request(s)\`, expected one"
elif [ "$disk_reads" != 5 ]; then
  item FAIL reader-empty "$disk_reads of 5 read phases were followed by a disk line"
elif [ "$copied" != 1 ]; then
  item FAIL reader-empty "the newest side's micro-dep (outside its checkout, rebuilt by every older checkout) was copied $copied time(s), expected once to $RD/newest-search/0"
elif [ -n "$left" ]; then
  item FAIL reader-empty "left behind: $left"
elif [ -n "$v6_differs" ]; then
  item FAIL reader-empty "v6, filled natively in both stores, differs: $v6_differs"
elif [ "$(rendered reader-empty)" != "6 of 6 ($(names "${ALL[@]}"))" ] || [ ! -f "$RD/site/index.html" ] || [ "$site_versions" != 6 ]; then
  item FAIL reader-empty "the site: rendered $(rendered reader-empty), index.html $([ -f "$RD/site/index.html" ] && echo present || echo absent), versions.json lists $site_versions"
else
  item ok reader-empty "versions extracted $said; fill reader for v1..v5 and own for v6, in the records and the marker; v6 extracted before each read, a disk line after every read; one session, v1 built whole and v2..v5 each patched from the one before, stopped after 5 requests; the newest side's micro-dep read from its copy, no checkout or copy left; v6 is native-add's byte for byte; the site holds all 6"
fi
cp -R "$RD/store" "$FIRST"

say "4/14 reader-equals-native: each reader-filled entry against its native one"
READER="$(ls "$RD"/extractors/reader-*/reader 2>/dev/null | head -n 1 || true)"
if [ -z "$READER" ] || [ ! -x "$READER" ]; then
  for v in "${OLDER[@]}"; do item FAIL "reader-equals-native-$v" "there is no reader under $RD/extractors"; done
else
  "$READER" extract --identity "${FLAGS[@]}" >"$WORK/reader-identity.txt"
  running="$(spelling_of "$READER_TC")"
  for v in "${OLDER[@]}"; do
    dir="$WORK/compare/$v"
    if ! "$LITEDOC4" store read --store "$NAT/store" --version "$v" --out "$dir/native" >"$LOGS/read-native-$v.log" 2>&1 ||
       ! "$LITEDOC4" store read --store "$RD/store" --version "$v" --out "$dir/read" >"$LOGS/read-reader-$v.log" 2>&1; then
      item FAIL "reader-equals-native-$v" "store read failed ($LOGS/read-*-$v.log)"
      continue
    fi
    spelled="$(spelling_of "$(git -C "$REPO" show "$v:lean-toolchain")")"
    lean="$(git -C "$REPO" show "$v:lean-toolchain")"
    if result="$(python3 "$HERE/lib/reader-compare.py" "$dir/native/ir" "$dir/native/link-index.lidx" \
        "$dir/read/ir" "$dir/read/link-index.lidx" "${lean##*:v}" "$spelled" "$running" \
        "$ROOT/extractor/Extract.lean" "$(dirname "$READER")/Extract.lean" "$WORK/reader-identity.txt" 2>&1)"; then
      item ok "reader-equals-native-$v" "$result"
    else
      item FAIL "reader-equals-native-$v" "$(printf '%s' "$result" | head -c 1500)"
    fi
  done
fi

say "5/14 patched-equals-alone: the same five read alone"
said="$(build reader-alone "$ALONE" "$ALL_LIST" --reader-alone)"
want="6 of 6 ($(names "${ALL[@]}")), through the reader: 5 ($(names "${OLDER[@]}"))"
alone_lines="$(grep -cE '^version v[1-5]: reading [0-9a-f]+ on .* through the reader alone$' "$LOGS/reader-alone.log" || true)"
alone_sessions="$(grep -cE '^session ' "$LOGS/reader-alone.log" || true)"
differs="$(same_entries "$FIRST" "$ALONE/store" "${OLDER[@]}")"
if [ "$said" != "$want" ]; then
  item FAIL patched-equals-alone "--reader-alone said \`versions extracted: ${said:-<no line>}\`, expected \`$want\` ($LOGS/reader-alone.log)"
elif [ "$alone_lines" != 5 ] || [ "$alone_sessions" != 0 ]; then
  item FAIL patched-equals-alone "--reader-alone: $alone_lines of 5 versions said they were read alone, $alone_sessions session line(s)"
elif [ -n "$differs" ]; then
  item FAIL patched-equals-alone "$(echo "$differs" | wc -w | tr -d ' ') of 10 files differ from the session's: $differs"
else
  item ok patched-equals-alone "--reader-alone: $said; 5 of 5 entries equal the session's, record.json and entry.pack.gz byte for byte"
fi

say "6/14 check-keys: the session's patch and carried keys checked on every round"
said="$(build reader-check "$CHECK" "$ALL_LIST" --reader-session --reader-check)"
patch_zero="$(grep -cE '^check-patch +0 modules differ from rewriteMerge.s state, pointer by pointer; 0 other differences$' "$LOGS/reader-check.log" || true)"
keys_zero="$(grep -cE '^check-keys +0 keys differ from a fresh pass ' "$LOGS/reader-check.log" || true)"
patch_all="$(grep -cE '^check-patch ' "$LOGS/reader-check.log" || true)"
keys_all="$(grep -cE '^check-keys ' "$LOGS/reader-check.log" || true)"
differs="$(same_entries "$FIRST" "$CHECK/store" "${OLDER[@]}")"
if [ "$said" != "$want" ]; then
  item FAIL check-keys "--reader-check said \`versions extracted: ${said:-<no line>}\`, expected \`$want\` ($LOGS/reader-check.log)"
elif [ "$patch_zero" != 5 ] || [ "$patch_all" != 5 ]; then
  item FAIL check-keys "$patch_zero of 5 rounds report 0 modules differing ($patch_all check-patch line(s)): $(grep -E '^ *check-patch' "$LOGS/reader-check.log" | head -c 600)"
elif [ "$keys_zero" != 5 ] || [ "$keys_all" != 5 ]; then
  item FAIL check-keys "$keys_zero of 5 rounds report 0 keys differing ($keys_all check-keys line(s)): $(grep -E '^ *check-keys' "$LOGS/reader-check.log" | head -c 600)"
elif [ -n "$differs" ]; then
  item FAIL check-keys "checked, the entries differ from the session's: $differs"
else
  item ok check-keys "--reader-check: $said; check-patch 0 modules and check-keys 0 keys on 5 of 5 rounds; 5 of 5 entries equal the session's"
fi

say "7/14 the chain: no reader flag, newest first, each version reusing from the one above"
said="$(build chain "$CHAIN" "$ALL_LIST")"
want="6 of 6 ($(names "${ALL[@]}")), through the reader: 5 ($(names "${OLDER[@]}"))"
chain_fills="$(fills "$CHAIN/store" "${ALL[@]}" 2>&1 || true)"
chain_reused="$(python3 - "$CHAIN/store" "${ALL[@]}" <<'PY' 2>&1 || true
import json, pathlib, sys
store = pathlib.Path(sys.argv[1])
print(" ".join(str(json.loads((store / v / "record.json").read_text(encoding="utf-8")).get("reusedFrom", "absent")) for v in sys.argv[2:]))
PY
)"
chain_order="$(grep -E '^phase +(v6 extract|v[1-5] read) ' "$LOGS/chain.log" | awk '{ print $2 }' | tr '\n' ' ' || true)"
chain_left="$(ls -d "$CHAIN/checkout" "$CHAIN/checkout-read" "$CHAIN/newest-search" "$CHAIN/scratch" "$CHAIN/reuse-neighbour" 2>/dev/null | tr '\n' ' ' || true)"
python3 - "$LOGS/chain.log" >"$WORK/chain-reuse.txt" <<'PY'
import re, sys
current = None
said = {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    m = re.match(r"^version (v\d+): reading \S+ on \S+ (.*)$", line)
    if m:
        current = m.group(1)
        said[current] = m.group(2)
        continue
    m = re.match(r"^reuse-from +\S*/reuse-neighbour/(v\d+)/ir: (\d+) of (\d+) declarations reused.*; printing identity (equal|differs)", line)
    if m and current:
        print(current, m.group(1), m.group(2), m.group(3), m.group(4), said.get(current, "-").replace(" ", "_"))
PY
row () { awk -v v="$1" '$1 == v' "$WORK/chain-reuse.txt"; }
reuses () { # reuses <version> <the version above>: prints why it did not reuse from it, or nothing
  local r n
  r="$(row "$1")"
  n="$(printf '%s' "$r" | grep -c . || true)"
  if [ "$n" != 1 ]; then echo "$1 has $n reuse-from line(s), expected one"; return; fi
  set -- "$1" "$2" $r
  if [ "$4" != "$2" ]; then echo "$1 reused from $4, expected $2"
  elif [ "$7" != equal ]; then echo "$1 reused from $2 with the printing identity $7"
  elif [ "$5" -lt 1 ]; then echo "$1 reused $5 of $6 declarations from $2"
  elif [ "$8" != "through_the_reader,_reusing_prints_from_$2" ]; then echo "$1's line said \`$(echo "$8" | tr _ ' ')\`"
  fi
}
v5_why="$(reuses v5 v6)"
if [ "$said" != "$want" ]; then
  item FAIL reuse-from-native "said \`versions extracted: ${said:-<no line>}\`, expected \`$want\` ($LOGS/chain.log)"
elif [ -n "$v5_why" ]; then
  item FAIL reuse-from-native "$v5_why; $(grep -E '^version v5: reading ' "$LOGS/chain.log" | head -c 300) ($LOGS/chain.log)"
else
  item ok reuse-from-native "v5 read with --reuse-from v6's native IR: $(row v5 | awk '{ print $3 " of " $4 " declarations reused, printing identity " $5 }')"
fi
chain_why=""
for pair in "v4 v5" "v3 v4" "v2 v3" "v1 v2"; do
  # shellcheck disable=SC2086
  why="$(reuses $pair)"
  if [ -n "$why" ]; then chain_why="$chain_why${chain_why:+; }$why"; fi
done
if [ "$said" != "$want" ]; then
  item FAIL chain "said \`versions extracted: ${said:-<no line>}\`, expected \`$want\` ($LOGS/chain.log)"
elif [ "$chain_fills" != "reader reader reader reader reader own" ]; then
  item FAIL chain "the records' fill is $chain_fills, expected reader for v1..v5 and own for v6"
elif [ "$chain_reused" != "v2 v3 v4 v5 v6 None" ]; then
  item FAIL chain "the records' reusedFrom is $chain_reused, expected v2 v3 v4 v5 v6 for v1..v5 and None for v6"
elif [ "$chain_order" != "v6 v5 v4 v3 v2 v1 " ]; then
  item FAIL chain "the phases ran in the order $chain_order, expected v6's extraction, then the reads newest first"
elif [ -n "$chain_why" ]; then
  item FAIL chain "$chain_why ($LOGS/chain.log)"
elif [ -n "$chain_left" ]; then
  item FAIL chain "left behind: $chain_left"
else
  item ok chain "$(awk '$1 != "v5" { printf "%s from %s %s of %s; ", $1, $2, $3, $4 }' "$WORK/chain-reuse.txt")printing identity equal throughout; each record names the version above it as reusedFrom; read newest first; nothing left behind"
fi
lidx_differs=""
for v in "${OLDER[@]}"; do
  dir="$WORK/chain-compare/$v"
  if ! "$LITEDOC4" store read --store "$CHAIN/store" --version "$v" --out "$dir/chain" >"$LOGS/read-chain-$v.log" 2>&1 ||
     ! "$LITEDOC4" store read --store "$ALONE/store" --version "$v" --out "$dir/alone" >"$LOGS/read-alone-$v.log" 2>&1; then
    lidx_differs="$lidx_differs $v (store read failed: $LOGS/read-*-$v.log)"
  elif ! cmp -s "$dir/chain/link-index.lidx" "$dir/alone/link-index.lidx"; then
    lidx_differs="$lidx_differs $v"
  fi
done
if [ -n "$lidx_differs" ]; then
  item FAIL chain-link-index-equals-alone "the chain's link index differs from --reader-alone's for:$lidx_differs"
else
  item ok chain-link-index-equals-alone "5 of 5 link indexes (v1..v5) equal to the --reader-alone store's, byte for byte"
fi

say "8/14 chain-no-neighbour: the newest kept from the store, one older version to fill"
mkdir -p "$NONB/store"
cp -R "$CHAIN/store/v6" "$NONB/store/v6"
set +e
"$LITEDOC4" build --root "$REPO" --out "$NONB" --versions v5,v6 --lake "$LAKE" >"$LOGS/no-neighbour.log" 2>&1
rc=$?
set -e
said="$(sed -n 's/^versions extracted: //p' "$LOGS/no-neighbour.log")"
want_line="version v5: reading $(git -C "$REPO" rev-parse v5) on $V5_TC through the reader without reuse: v6, the version above it, is kept from the store and was not built in this run"
reuse_lines="$(grep -cE '^reuse-from ' "$LOGS/no-neighbour.log" || true)"
differs="$(same_entries "$ALONE/store" "$NONB/store" v5)"
if [ "$rc" -ne 0 ]; then
  item FAIL chain-no-neighbour "exited $rc: $(tail -c 400 "$LOGS/no-neighbour.log")"
elif [ "$said" != "1 of 2 (v5), through the reader: 1 (v5)" ]; then
  item FAIL chain-no-neighbour "said \`versions extracted: ${said:-<no line>}\`, expected \`1 of 2 (v5), through the reader: 1 (v5)\`"
elif ! grep -qxF -- "$want_line" "$LOGS/no-neighbour.log"; then
  item FAIL chain-no-neighbour "no line \`$want_line\`: $(grep -E '^version v5: reading ' "$LOGS/no-neighbour.log" | head -c 400)"
elif [ "$reuse_lines" != 0 ]; then
  item FAIL chain-no-neighbour "$reuse_lines reuse-from line(s), expected none"
elif [ -n "$differs" ]; then
  item FAIL chain-no-neighbour "v5, read without reuse, differs from --reader-alone's: $differs"
else
  item ok chain-no-neighbour "exit 0; $said; v5's line says without reuse, v6 kept from the store; no reuse-from line; --reader-alone's v5 byte for byte"
fi

say "9/14 exact-refills-reused and chain-keeps-exact: what each way of reading accepts from the store"

cp -R "$CHAIN/store" "$EXACT/store"
cp -R "$ALONE/store" "$KEEPS/store"
said="$(build exact-over-chain "$EXACT" "$ALL_LIST" --reader-alone)"
want="5 of 6 ($(names "${OLDER[@]}")), through the reader: 5 ($(names "${OLDER[@]}"))"
judged=0
for pair in "v1 v2" "v2 v3" "v3 v4" "v4 v5" "v5 v6"; do
  read -r v above <<<"$pair"
  if grep -qxF "version $v: prints reused from $above, asked exact prints, to be filled through the reader" "$LOGS/exact-over-chain.log"; then
    judged=$((judged + 1))
  fi
done
differs="$(same_entries "$ALONE/store" "$EXACT/store" "${ALL[@]}")"
if [ "$said" != "$want" ]; then
  item FAIL exact-refills-reused "--reader-alone over the chain's store said \`versions extracted: ${said:-<no line>}\`, expected \`$want\` ($LOGS/exact-over-chain.log)"
elif [ "$judged" != 5 ]; then
  item FAIL exact-refills-reused "$judged of 5 versions were judged \`prints reused from <the version above>, asked exact prints\`: $(grep -E '^version v[1-5]: ' "$LOGS/exact-over-chain.log" | head -c 600)"
elif [ -n "$differs" ]; then
  item FAIL exact-refills-reused "the entries differ from the --reader-alone store's: $differs"
else
  item ok exact-refills-reused "--reader-alone over the chain's store: $said; 5 of 5 judged reused and read exactly; 6 of 6 entries equal the --reader-alone store's byte for byte"
fi
said="$(build chain-over-exact "$KEEPS" "$ALL_LIST")"
if [ "$said" != "0 of 6 ()" ]; then
  item FAIL chain-keeps-exact "the chain over the --reader-alone store said \`versions extracted: ${said:-<no line>}\`, expected \`0 of 6 ()\` ($LOGS/chain-over-exact.log)"
else
  item ok chain-keeps-exact "the chain over the --reader-alone store: versions extracted $said"
fi

say "10/14 reader-again"
said="$(build reader-again "$RD" "$ALL_LIST" --reader-session)"
differs="$(same_entries "$FIRST" "$RD/store" "${ALL[@]}")"
if [ "$said" != "0 of 6 ()" ]; then
  item FAIL reader-again "the same command again said \`versions extracted: ${said:-<no line>}\`, expected \`0 of 6 ()\`"
elif [ -n "$differs" ]; then
  item FAIL reader-again "entries changed: $differs"
else
  item ok reader-again "versions extracted $said, rendered $(rendered reader-again); no entry changed"
fi

say "11/14 reader-remove-one"
"$LITEDOC4" store remove --store "$RD/store" --version v3 >"$LOGS/remove-v3.log" 2>&1
said="$(build reader-remove-one "$RD" "$ALL_LIST" --reader-session)"
fill="$(fills "$RD/store" v3 2>&1 || true)"
differs="$(same_entries "$NAT/store" "$RD/store" v3)"
if [ "$said" != "1 of 6 (v3)" ]; then
  item FAIL reader-remove-one "with v3 removed the build said \`versions extracted: ${said:-<no line>}\`, expected \`1 of 6 (v3)\`"
elif [ "$fill" != own ]; then
  item FAIL reader-remove-one "v3 was filled $fill, expected own: the store holds older versions"
elif [ -n "$differs" ]; then
  item FAIL reader-remove-one "v3 differs from native-add's: $differs"
else
  item ok reader-remove-one "with v3 removed: versions extracted $said, fill=own, native-add's v3 byte for byte"
fi

say "12/14 reader-force"
said="$(build reader-force "$RD" "$ALL_LIST" --reader-session --through-reader v3)"
fill="$(fills "$RD/store" v3 2>&1 || true)"
differs="$(same_entries "$FIRST" "$RD/store" v3)"
if [ "$said" != "1 of 6 (v3), through the reader: 1 (v3)" ]; then
  item FAIL reader-force "--through-reader v3 said \`versions extracted: ${said:-<no line>}\`, expected \`1 of 6 (v3), through the reader: 1 (v3)\`"
elif [ "$fill" != reader ]; then
  item FAIL reader-force "v3 was filled $fill"
elif [ -n "$differs" ]; then
  item FAIL reader-force "v3 differs from reader-empty's: $differs"
else
  item ok reader-force "--through-reader v3: versions extracted $said, reader-empty's v3 byte for byte"
fi

say "13/14 reader-identity"
python3 - "$RD/store" "${OLDER[@]}" <<'PY'
import json, pathlib, re, sys
for v in sys.argv[2:]:
    path = pathlib.Path(sys.argv[1]) / v / "record.json"
    record = json.loads(path.read_text(encoding="utf-8"))
    record["extractorIdentity"] = re.sub(r"\breader=\S+", "reader=fnv1a64:0000000000000000", record["extractorIdentity"])
    path.write_text(json.dumps(record) + "\n", encoding="utf-8")
PY
said_reader="$(build reader-identity-reader "$RD" "$ALL_LIST" --reader-session)"
differs="$(same_entries "$FIRST" "$RD/store" "${ALL[@]}")"
printf 'no_equations_under = ["Example"]\n' >>"$REPO/litedoc4.toml"
said_config="$(build reader-identity-config "$RD" "$ALL_LIST" --reader-session)"
git -C "$REPO" restore litedoc4.toml
carried="$(python3 - "$RD/store" "${ALL[@]}" <<'PY'
import json, pathlib, sys
ids = [json.loads((pathlib.Path(sys.argv[1]) / v / "record.json").read_text(encoding="utf-8"))["extractorIdentity"] for v in sys.argv[2:]]
print(sum("noEquationsUnder=Example" in i.split(" ") for i in ids))
PY
)"
want_reader="5 of 6 ($(names "${OLDER[@]}")), through the reader: 5 ($(names "${OLDER[@]}"))"
want_config="6 of 6 ($(names "${ALL[@]}")), through the reader: 5 ($(names "${OLDER[@]}"))"
if [ "$said_reader" != "$want_reader" ]; then
  item FAIL reader-identity "with reader= altered in v1..v5's records the build said \`versions extracted: ${said_reader:-<no line>}\`, expected \`$want_reader\`"
elif [ -n "$differs" ]; then
  item FAIL reader-identity "the refilled entries differ from reader-empty's: $differs"
elif [ "$said_config" != "$want_config" ]; then
  item FAIL reader-identity "with no_equations_under added the build said \`versions extracted: ${said_config:-<no line>}\`, expected \`$want_config\`"
elif [ "$carried" != 6 ]; then
  item FAIL reader-identity "$carried of 6 records carry noEquationsUnder=Example"
else
  item ok reader-identity "reader= altered: $said_reader, into the same bytes; no_equations_under added: $said_config, and all 6 records carry it"
fi

say "14/14 reader-refuse-newest"
set +e
"$LITEDOC4" build --root "$REPO" --out "$WORK/refused" --versions "$OLDER_LIST" --lake "$LAKE" \
  --through-reader v1 >"$LOGS/refuse.log" 2>&1
rc=$?
set -e
want="litedoc4: --through-reader: the newest version v5 ($(git -C "$REPO" rev-parse v5)) pins \`$V5_TC\`, and the reader runs on \`$READER_TC\`"
if [ "$rc" -ne 3 ]; then
  item FAIL reader-refuse-newest "exited $rc, expected 3: $(head -c 400 "$LOGS/refuse.log")"
elif ! grep -qF -- "$want" "$LOGS/refuse.log"; then
  item FAIL reader-refuse-newest "the refusal does not start \`$want\`: $(head -c 400 "$LOGS/refuse.log")"
elif [ -e "$WORK/refused" ]; then
  item FAIL reader-refuse-newest "refused, but $WORK/refused was created"
else
  item ok reader-refuse-newest "exit 3: $(head -c 300 "$LOGS/refuse.log")"
fi

say "report"
echo "wall time per build (printed, never judged):"
cat "$WORK/times.txt"
echo "the reader-filled run's phases:"
grep -E '^(phase|disk) ' "$LOGS/reader-empty.log" || true
record_host
echo "total             $((SECONDS - STARTED)) s"
echo

printf '%s\n' "${DECLARED[@]}" | sort >"$WORK/declared.txt"
printf '%s\n' ${RAN[@]+"${RAN[@]}"} | sort >"$WORK/ran.txt"
if ! /usr/bin/diff "$WORK/declared.txt" "$WORK/ran.txt" >"$LOGS/items.diff"; then
  echo "MV READER GATE: the items that reported are not the items declared (< never reported, > not declared or twice):" >&2
  cat "$LOGS/items.diff" >&2
  echo "MV READER GATE FAIL: ${#RAN[@]} of ${#DECLARED[@]} reported, $FAILED failed" >&2
  exit 1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "MV READER GATE FAIL: $FAILED of ${#DECLARED[@]} failed (${#RAN[@]} of ${#DECLARED[@]} ran)" >&2
  exit 1
fi
echo "MV READER GATE: ok, ${#RAN[@]} of ${#DECLARED[@]} items ran and passed"
PASSED=1
answer 0
