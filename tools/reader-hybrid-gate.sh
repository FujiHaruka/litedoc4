#!/usr/bin/env bash
# Does the .olean reader's hybrid run write the IR the native extractor writes?
#
# The sample e2e/micro (with e2e/micro-dep) is built natively on every row of
# tools/lean-toolchains.txt and extracted there; each build's .olean files are
# then read by `reader extract`, with the newest row's build of the same sample
# as the newest side, and its IR is compared with that row's native IR.
#
#   self-<newest>     the newest row read through the reader: the printer and
#                     the data are the same Lean, so the IR and the link index
#                     are the native ones byte for byte except the identity
#   read-<version>    an older row read in the newest Lean. Equal except:
#                       - the reducibility spelling: the native IR spells it
#                         the way its own Lean does (column 2), the reader the
#                         way the running Lean does; exactly that rename is
#                         applied to the native side, and the count printed
#                       - `contentHash`, which differs exactly where the raw
#                         module bytes do
#                       - `extractorIdentity`: `source=` digests the copy of
#                         Extract.lean the reader compiles (without `main`),
#                         and the reader's fields follow; both predicted
#   hard-stops        every reader run reports the sample's hard stops:
#                     verso=0 builtin-doc=0 tactic-table=1
#                     autoparam-old-only=0 autoparam-newest=0
#   refuse-<flag>     --dump-tactics, --tactics-emulate, --tactics-probe and
#                     --serve are refused by name, before anything is read
#
# A row whose toolchain is not installed is not answered (exit 2): `lake`
# would install it, so the gate checks first.
#
# usage: reader-hybrid-gate.sh [--keep]
#   --keep    leave the work area in place
#
#   READER_HYBRID_WORK  work area (default: /private/tmp/lean-doc-relay/reader-hybrid),
#                       emptied at the start and removed at the end
#   LITEDOC4 / LAKE     the binaries (default: .lake/build/bin/litedoc4, ~/.elan/bin/lake)
#   ELAN_HOME           where elan keeps toolchains (default: ~/.elan)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
answer_required

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '/^# usage:/,/^set -/p' "$0" | sed 's/^# \{0,1\}//;$d'; answer 0 ;;
    *) echo "reader-hybrid-gate: unknown flag: $1" >&2; exit 2 ;;
  esac
done

WORK="${READER_HYBRID_WORK:-/private/tmp/lean-doc-relay/reader-hybrid}"
TOOLCHAINS="${ELAN_HOME:-$HOME/.elan}/toolchains"
LAKE="${LAKE:-$HOME/.elan/bin/lake}"
LITEDOC4="${LITEDOC4:-$ROOT/.lake/build/bin/litedoc4}"
INVENTORY="$ROOT/tools/lean-toolchains.txt"
FLAGS=(--equations --refs --write-ir --tagged-code --jobs 1)
REFUSED=(--dump-tactics --tactics-emulate --tactics-probe --serve)
EXPECTED_STOPS="verso=0 builtin-doc=0 tactic-table=1 autoparam-old-only=0 autoparam-newest=0"

[ -x "$LITEDOC4" ] || {
  echo "reader-hybrid-gate: no litedoc4 at $LITEDOC4; tools/build-lean-exe.sh --toolchain-from e2e/micro" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK"
on_exit 'if [ "$KEEP" -eq 0 ]; then rm -rf "$WORK"; fi'

say () { printf '%s\n' "$*"; }
ran=0
failed=0
ok ()   { ran=$((ran + 1));                        say "ITEM $1 ok    $2"; }
bad ()  { ran=$((ran + 1)); failed=$((failed + 1)); say "ITEM $1 FAIL  $2"; }
gone () {                                           say "ITEM $1 ----  $2"; }
excerpt () { head -c 1500 "$1" | sed 's/^/      /'; }

installed () { [ -x "$TOOLCHAINS/$(printf '%s' "$1" | sed 's|/|--|; s|:|---|')/bin/lean" ]; }

ROWS=()
SPELLINGS=()
while read -r tc attr; do
  ROWS+=("$tc"); SPELLINGS+=("$attr")
done < <(awk '{ sub(/#.*/, "") } NF { print $1, $2 }' "$INVENTORY")
if [ "${#ROWS[@]}" -lt 2 ]; then
  say "reader-hybrid-gate: $INVENTORY lists fewer than two toolchains -- there is no older row to read" >&2
  exit 1
fi
NEWEST_I=$(( ${#ROWS[@]} - 1 ))
NEWEST="${ROWS[$NEWEST_I]##*:v}"
NEWEST_SPELLING="${SPELLINGS[$NEWEST_I]}"
declared=$(( ${#ROWS[@]} + 1 + ${#REFUSED[@]} ))

record_host
if ! installed "${ROWS[$NEWEST_I]}"; then
  say "reader-hybrid-gate: the reader's toolchain ${ROWS[$NEWEST_I]} is not installed -- nothing was answered" >&2
  answer 2
fi
say "=== the reader, on ${ROWS[$NEWEST_I]}"
READER="$(build_reader "$ROOT" "$WORK/reader" "$WORK/reader-build.log")" || exit 1
"$READER" extract --identity "${FLAGS[@]}" >"$WORK/reader-identity.txt"
say "  $(cat "$WORK/reader-identity.txt")"

native () {
  local v="$1" dir="$WORK/v$1" exe
  mkdir -p "$dir/native"
  cp -R "$ROOT/e2e/micro" "$ROOT/e2e/micro-dep" "$dir/"
  rm -rf "$dir/micro/.lake" "$dir/micro-dep/.lake"
  echo "leanprover/lean4:v$v" >"$dir/micro/lean-toolchain"
  echo "leanprover/lean4:v$v" >"$dir/micro-dep/lean-toolchain"
  (cd "$dir/micro" && "$LAKE" build) >"$dir/build.log" 2>&1 || { echo "lake build failed"; return 1; }
  "$LITEDOC4" modules --root "$dir/micro" --lib Example --out "$dir/modules.txt" >"$dir/modules.log" 2>&1 ||
    { echo "litedoc4 modules failed"; return 1; }
  exe="$(micro_extractor "$ROOT" "$dir/micro" "$LAKE" "$dir/extractor-build.log")"
  [ -x "$exe" ] || { echo "the native extractor did not build"; return 1; }
  (cd "$dir/micro" && "$LAKE" env "$exe" "$dir/modules.txt" "$dir/native-events.jsonl" "${FLAGS[@]}" \
     --ir-dir "$dir/native/ir" --link-index "$dir/native/links.lidx") >"$dir/native.log" 2>&1 ||
    { echo "the native extractor failed"; return 1; }
  (cd "$dir/micro" && "$LAKE" env printenv LEAN_PATH) >"$dir/search-path.txt"
}

search_args () {
  local d
  tr ':' '\n' <"$WORK/v$2/search-path.txt" | while read -r d; do
    if [ -n "$d" ]; then printf '%s\n%s\n' "$1" "$d"; fi
  done
}

read_through () {
  local v="$1" out="$2" args=()
  shift 2
  while IFS= read -r a; do args+=("$a"); done < <(search_args --old "$v"; search_args --new "$NEWEST")
  mkdir -p "$out"
  set +e
  "$READER" extract "${args[@]}" --new-roots "$WORK/v$NEWEST/modules.txt" "$WORK/v$v/modules.txt" \
    "$out/events.jsonl" "${FLAGS[@]}" --ir-dir "$out/ir" --link-index "$out/links.lidx" "$@" \
    >"$out/stdout.txt" 2>"$out/stderr.txt"
  local rc=$?
  set -e
  return "$rc"
}

compare () {
  python3 - "$WORK/v$1/native" "$WORK/v$1/read" "$1" "$2" "$NEWEST_SPELLING" \
    "$ROOT/extractor/Extract.lean" "$WORK/reader/Extract.lean" "$WORK/reader-identity.txt" <<'PY'
import json, pathlib, sys

native, read = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
version, spelled, running = sys.argv[3], sys.argv[4].encode(), sys.argv[5].encode()
full, cut, reader_identity = (pathlib.Path(p) for p in sys.argv[6:9])
problems = []


def fnv(path):
    h = 0xCBF29CE484222325
    for b in path.read_bytes():
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "fnv1a64:%016x" % h


def files(root):
    return {p.relative_to(root).as_posix(): p for p in sorted(root.rglob("*")) if p.is_file()}


rewrites = 0
n, r = files(native / "ir"), files(read / "ir")
for name in sorted(set(n) | set(r)):
    if name not in r:
        problems.append(f"the reader did not write {name}")
        continue
    if name not in n:
        problems.append(f"the reader wrote {name}, the native extractor did not")
        continue
    if name == "index.json":
        continue
    want = n[name].read_bytes()
    if spelled != running:
        rewrites += want.count(spelled)
        want = want.replace(spelled, running)
    got = r[name].read_bytes()
    if want != got:
        at = next((i for i, (u, v) in enumerate(zip(want, got)) if u != v), min(len(want), len(got)))
        problems.append(f"{name} differs at byte {at}: native {want[at:at + 60]!r} reader {got[at:at + 60]!r}")
if (native / "links.lidx").read_bytes() != (read / "links.lidx").read_bytes():
    problems.append("the link index differs")

ni = json.loads((native / "ir" / "index.json").read_text(encoding="utf-8"))
ri = json.loads((read / "ir" / "index.json").read_text(encoding="utf-8"))
for side, index in (("native", ni), ("reader", ri)):
    if index.get("leanVersion") != version:
        problems.append(f"the {side} index names Lean {index.get('leanVersion')!r}, not {version}")
source_full, source_cut = "source=" + fnv(full), "source=" + fnv(cut)
native_id = ni.get("extractorIdentity", "")
if source_full not in native_id.split(" "):
    problems.append(f"the native identity does not carry {source_full}: {native_id}")
reader_fields = [f for f in reader_identity.read_text(encoding="utf-8").split() if f.startswith("reader")]
want_id = " ".join([source_cut if f == source_full else f for f in native_id.split(" ")] + reader_fields)
if ri.get("extractorIdentity") != want_id:
    problems.append(f"the reader identity is {ri.get('extractorIdentity')!r}, predicted {want_id!r}")
blank = " ".join(f.split("=")[0] + "=" if f.split("=")[0] in ("lean", "leanGithash") else f for f in want_id.split(" "))
if reader_identity.read_text(encoding="utf-8").strip() != blank:
    problems.append("`reader extract --identity` does not print the run's identity with lean= and leanGithash= blank")
hashes = 0
for nm, rm in zip(ni.get("modules", []), ri.get("modules", [])):
    raw_equal = (native / "ir" / nm["file"]).read_bytes() == (read / "ir" / rm["file"]).read_bytes()
    if raw_equal != (nm.get("contentHash") == rm.get("contentHash")):
        problems.append(f"{nm['module']}: raw bytes {'match' if raw_equal else 'differ'} but contentHash does not follow")
    hashes += nm.get("contentHash") != rm.get("contentHash")
strip = lambda ix: {**ix, "extractorIdentity": None,
                    "modules": [{**m, "contentHash": None} for m in ix.get("modules", [])]}
if strip(ni) != strip(ri):
    keys = sorted(k for k in set(ni) | set(ri) if strip(ni).get(k) != strip(ri).get(k))
    problems.append(f"index.json differs beyond the identity and contentHash: {keys}")

if problems:
    for p in problems[:8]:
        print(p)
    sys.exit(1)
print(f"{len(n)} IR files and the link index equal; reducibility spelling "
      f"{spelled.decode()} -> {running.decode()} applied {rewrites} time(s), "
      f"contentHash differs in {hashes} module(s) exactly where the bytes do, identity as predicted")
PY
}

STOPS_SEEN=()
item_read () {
  local item="$1" v="$2" out="$WORK/v$2/read" result
  if ! read_through "$v" "$out"; then
    bad "$item" "reader extract exited non-zero"
    excerpt "$out/stderr.txt"
    return
  fi
  STOPS_SEEN+=("$v $(sed -n 's/^hard stops *//p' "$out/stdout.txt")")
  if result="$(compare "$v" "$3" 2>&1)"; then
    ok "$item" "$result"
  else
    bad "$item" "the reader's IR of Lean $v differs from the native one:"
    printf '%s\n' "$result" | head -c 2000 | sed 's/^/      /'
  fi
}

say
say "=== the sample, natively, on each row"
NATIVE_OK=()
for i in "${!ROWS[@]}"; do
  v="${ROWS[$i]##*:v}"
  if ! installed "${ROWS[$i]}"; then
    NATIVE_OK+=("not-installed")
    say "  v$v: ${ROWS[$i]} is not installed"
  elif why="$(native "$v")"; then
    NATIVE_OK+=("ok")
    say "  v$v: $(wc -l <"$WORK/v$v/modules.txt" | tr -d ' ') modules extracted"
  else
    NATIVE_OK+=("$why")
    say "  v$v: $why"
  fi
done

say
say "=== the reader against each native IR"
for i in "${!ROWS[@]}"; do
  v="${ROWS[$i]##*:v}"
  if [ "$i" -eq "$NEWEST_I" ]; then item="self-$v"; else item="read-$v"; fi
  if [ "${NATIVE_OK[$i]}" = not-installed ]; then
    gone "$item" "${ROWS[$i]} is not installed; this row is not answered"
  elif [ "${NATIVE_OK[$NEWEST_I]}" != ok ]; then
    bad "$item" "the newest row's sample did not build (${NATIVE_OK[$NEWEST_I]}), so there is no newest side"
  elif [ "${NATIVE_OK[$i]}" != ok ]; then
    bad "$item" "the native side did not build: ${NATIVE_OK[$i]}"
  else
    item_read "$item" "$v" "${SPELLINGS[$i]}"
  fi
done

say
say "=== the hard stops each reader run reported"
if [ "${#STOPS_SEEN[@]}" -eq 0 ]; then
  bad hard-stops "no reader run reported its hard stops"
else
  wrong=()
  for s in "${STOPS_SEEN[@]}"; do
    if [ "${s#* }" != "$EXPECTED_STOPS" ]; then wrong+=("$s"); fi
  done
  if [ "${#wrong[@]}" -eq 0 ]; then
    ok hard-stops "${#STOPS_SEEN[@]} run(s), each: $EXPECTED_STOPS"
  else
    bad hard-stops "expected $EXPECTED_STOPS; ${wrong[*]}"
  fi
fi

say
say "=== the flags the hybrid refuses"
for flag in "${REFUSED[@]}"; do
  item="refuse-${flag#--}"
  if [ "${NATIVE_OK[$NEWEST_I]}" != ok ]; then
    bad "$item" "the newest row's sample did not build, so there is no command line to refuse"
    continue
  fi
  out="$WORK/refuse${flag}"
  extra=("$flag")
  if [ "$flag" = --dump-tactics ]; then extra+=("$out/tactics.txt"); fi
  if read_through "$NEWEST" "$out" "${extra[@]}"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 2 ]; then
    bad "$item" "reader extract $flag exited $rc, a refusal exits 2"
  elif ! grep -qF -- "$flag is refused" "$out/stderr.txt"; then
    bad "$item" "the refusal does not name $flag: $(head -c 300 "$out/stderr.txt")"
  elif [ -e "$out/ir" ] || [ -e "$out/events.jsonl" ]; then
    bad "$item" "refused, but it wrote output first"
  else
    ok "$item" "$(head -c 300 "$out/stderr.txt")"
  fi
done

say
say "=== summary"
say "items reported : $ran of $declared"
say "failed         : $failed"
if [ "$failed" -ne 0 ]; then
  say "READER HYBRID GATE: FAILED ($failed of $ran answered items)" >&2
  answer 1
fi
if [ "$ran" -ne "$declared" ]; then
  say "READER HYBRID GATE: $ran of $declared items answered -- the rest were not asked, which is not a pass" >&2
  answer 2
fi
say "READER HYBRID GATE: ok ($ran of $declared)"
answer 0
