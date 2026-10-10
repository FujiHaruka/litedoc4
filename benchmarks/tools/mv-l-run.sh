#!/usr/bin/env bash
# usage (all of Mathlib at four releases through `litedoc4 build --versions`, the older three read
# by the .olean reader into the newest):
#   mv-l-run.sh setup     build litedoc4, clone Mathlib's tags, check out the last
#   mv-l-run.sh session   (a) every tag into an empty <work>/a, one reader session, --reader-check
#   mv-l-run.sh alone     (b) a copy of <work>/a holding only the newest entry, --reader-alone
#   mv-l-run.sh compare   (a)'s and (b)'s entries of the older tags byte for byte, and the counts
#   mv-l-run.sh scratch   (c) every tag into an empty <work>/c, each older one read alone
#   mv-l-run.sh reuse     (d) the newest built natively, then each older tag, newest first, read
#                         twice by `reader extract --lazy-proofs`: alone (a) and with --reuse-from
#                         the newer tag's reader IR (r); the two compared, then deleted
#   mv-l-run.sh report    sizes of the store and site of <work>/a, or of <work>/c when there is no a
#
# Environment: MV_L_WORK (default $RUNNER_TEMP/mv-l or /private/tmp/lean-doc-relay/mv-l),
# MV_L_JOBS (default 4), MV_L_TAGS (default v4.32.2,v4.33.0,v4.33.1,v4.34.1; the last is the newest).
# `reuse` on prepared checkouts instead of the clone (a small local run), all optional:
#   MV_L_NEWEST_WORKSPACE  a built workspace of the newest tag, only read (default: the clone,
#                          whose cache `reuse` fetches and builds)
#   MV_L_NEW_ROOTS         the newest modules imported (default: `litedoc4 modules` of the clone)
#   MV_L_CHECKOUTS         <dir>/<tag>: built packages of the older tags, used in place of worktrees
#   MV_L_NATIVE_ROOT       the package the native step builds (default: the clone)
#   MV_L_MODULES           one module list for the head and every older tag (default: each its own)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../tools/lib/common.sh
source "$ROOT/tools/lib/common.sh" || exit 1
answer_required
on_exit 'pkill -P $$ 2>/dev/null || true'
WORK="${MV_L_WORK:-${RUNNER_TEMP:-/private/tmp/lean-doc-relay}/mv-l}"
LOGS="$WORK/logs"
MATHLIB="$WORK/mathlib"
OUT_A="$WORK/a"
OUT_B="$WORK/b"
JOBS="${MV_L_JOBS:-4}"
IFS=, read -r -a TAGS <<<"${MV_L_TAGS:-v4.32.2,v4.33.0,v4.33.1,v4.34.1}"
NEWEST="${TAGS[${#TAGS[@]}-1]}"
OLDER=("${TAGS[@]:0:${#TAGS[@]}-1}")
LITEDOC4="$ROOT/.lake/build/bin/litedoc4"
mkdir -p "$LOGS"

list () { (IFS=,; echo "$*"); }
names () { local s; s="$(printf '%s, ' "$@")"; echo "${s%, }"; }

time_cmd() {
  if [ -x /usr/bin/time ] && /usr/bin/time -v true >/dev/null 2>&1; then
    echo /usr/bin/time -v
  else
    echo /usr/bin/time -l
  fi
}

sample() {
  while true; do
    printf '%s %s %s %s\n' "$(date -u +%H:%M:%S)" \
      "$(df -k "$WORK" | awk 'NR == 2 { print int($4 / 1048576) "GiB-free" }')" \
      "$( (awk '/MemAvailable/ { print int($2 / 1024) "MiB-avail" }' /proc/meminfo 2>/dev/null) || echo -)" \
      "$( (awk '/SwapTotal/ { t = $2 } /SwapFree/ { f = $2 } END { print int((t - f) / 1024) "MiB-swap" }' /proc/meminfo 2>/dev/null) || echo -)"
    sleep 15
  done
}

rss_timeline() {
  local timer="$1" out="$2" main="" pid kind t0
  t0="$(date +%s)"
  echo "# seconds process pid anon-MiB file-MiB swap-MiB"
  while kill -0 "$timer" 2>/dev/null; do
    [ -n "$main" ] || main="$(pgrep -P "$timer" || true)"
    for pid in $main $(pgrep -f "$out/extractors/reader-[^ ]*/reader (session|extract) " || true); do
      if [ "$pid" = "$main" ]; then kind=litedoc4; else kind="reader-$(ps -o args= -p "$pid" 2>/dev/null | awk '{ print $2 }' || true)"; fi
      awk -v t="$(($(date +%s) - t0))" -v k="$kind" -v p="$pid" '
        /^(RssAnon|RssFile|VmSwap):/ { v[$1] = int($2 / 1024); n++ }
        END { if (n) print t, k, p, v["RssAnon:"], v["RssFile:"], v["VmSwap:"] }' "/proc/$pid/status" 2>/dev/null || true
    done
    sleep 1
  done
}

live() {
  local label="$1"
  tail -n +1 -F "$LOGS/$label.out" 2>/dev/null |
    grep --line-buffered -E '^(phase|versions |version |ready |round |ok |err |phases |patch |check-patch |check-keys |reuse |carry |rss |render )' &
  (sudo -n dmesg -w 2>/dev/null | grep --line-buffered -iE 'out of memory|oom|killed process') &
  while true; do
    sleep 30
    echo "live $(tail -n 1 "$LOGS/$label-sampler.txt" 2>/dev/null)" \
      "$(tail -n 4 "$LOGS/$label.rss" 2>/dev/null | awk '{ printf "%s anon=%s file=%s swap=%s; ", $2, $4, $5, $6 }')"
  done
}

run() {
  local label="$1" out="$2" status=0 timer sampler timeline watcher
  shift 2
  sample >"$LOGS/$label-sampler.txt" &
  sampler=$!
  # shellcheck disable=SC2046  # the time command is two words on purpose
  $(time_cmd) "$LITEDOC4" build --root "$MATHLIB" --lib Mathlib --out "$out" \
    --versions "$(list "${TAGS[@]}")" --jobs "$JOBS" "$@" >"$LOGS/$label.out" 2>"$LOGS/$label.err" &
  timer=$!
  rss_timeline "$timer" "$out" >"$LOGS/$label.rss" &
  timeline=$!
  live "$label" &
  watcher=$!
  wait "$timer" || status=$?
  kill "$sampler" "$timeline" 2>/dev/null || true
  pkill -P "$watcher" 2>/dev/null || true
  kill "$watcher" 2>/dev/null || true
  pkill -f "tail -n \\+1 -F $LOGS/$label.out" 2>/dev/null || true
  wait "$sampler" "$timeline" "$watcher" 2>/dev/null || true
  echo "exit $status" >>"$LOGS/$label.out"
  grep -E '^(phase|versions |version |put |identity |reader |newest |session |ready |round |ok |err |phases |patch |check-patch |check-keys |reuse |carry |rss |render |build |exit )' \
    "$LOGS/$label.out" || true
  echo "--- peak per process (MiB, 1-s samples of /proc/<pid>/status)"
  awk '!/^#/ { if ($4 > a[$2]) a[$2] = $4; if ($5 > f[$2]) f[$2] = $5; if ($6 > s[$2]) s[$2] = $6 }
       END { for (k in a) print k, "anon", a[k], "file", f[k], "swap", s[k] }' "$LOGS/$label.rss" | sort
  echo "--- minimum free disk / MemAvailable, maximum swap used (15-s samples)"
  awk '{ d = $2 + 0; m = $3 + 0; w = $4 + 0
         if (NR == 1 || d < dm) dm = d; if (NR == 1 || m < mm) mm = m; if (w > wm) wm = w }
       END { print dm "GiB-free", mm "MiB-avail", wm "MiB-swap" }' "$LOGS/$label-sampler.txt"
  echo "--- GNU time (the largest process in the tree, not the session alone)"
  grep -E 'Elapsed|Maximum resident|User time|System time' "$LOGS/$label.err" || true
  tail -n 25 "$LOGS/$label.err"
  answer "$status"
}

same_entries () {
  local a="$1" b="$2" v f out=""
  shift 2
  for v in "$@"; do
    for f in record.json entry.pack.gz; do
      if ! cmp -s "$a/$v/$f" "$b/$v/$f"; then out="$out $v/$f"; fi
    done
  done
  echo "${out# }"
}

LAKE="${LAKE:-$(command -v lake || echo "$HOME/.elan/bin/lake")}"
ELAN="${ELAN:-$(command -v elan || echo "$HOME/.elan/bin/elan")}"
OUTPUT_FLAGS=(--equations --refs --write-ir --tagged-code --no-equations-under Mathlib.Tactic,Mathlib.Meta)
NEWEST_WS="${MV_L_NEWEST_WORKSPACE:-$MATHLIB}"
NATIVE_ROOT="${MV_L_NATIVE_ROOT:-$MATHLIB}"
REUSE_DECLARED=0
REUSE_OK=0
PROC_STATUS=0

reuse_fail () { echo "MV-L REUSE: $*" >&2; exit 1; }

tick () {
  REUSE_DECLARED=$((REUSE_DECLARED + 1))
  if [ "$2" = yes ]; then REUSE_OK=$((REUSE_OK + 1)); echo "ok   $1: $3"; else echo "FAIL $1: $3"; fi
}

proc_peaks () {
  local timer="$1" label="$2" t0 n=0 child pid
  t0="$(date +%s)"
  echo "# seconds process pid anon-MiB file-MiB swap-MiB"
  while kill -0 "$timer" 2>/dev/null; do
    child="$(pgrep -P "$timer" || true)"
    for pid in $child $(if [ -n "$child" ]; then pgrep -P "$child" || true; fi); do
      awk -v t="$(($(date +%s) - t0))" -v k="$(basename "$(ps -o comm= -p "$pid" 2>/dev/null || echo '?')")" -v p="$pid" '
        /^(RssAnon|RssFile|VmSwap):/ { v[$1] = int($2 / 1024); n++ }
        END { if (n) print t, k, p, v["RssAnon:"], v["RssFile:"], v["VmSwap:"] }' "/proc/$pid/status" 2>/dev/null || true
    done
    n=$((n + 1))
    if [ $((n % 60)) = 0 ]; then
      echo "  ... $label $(($(date +%s) - t0)) s; $(tail -n 1 "$LOGS/$label-sampler.txt" 2>/dev/null)" >&2
    fi
    sleep 1
  done
}

proc_summary () {
  python3 - "$LOGS/$1.time" "$LOGS/$1.rss" "$LOGS/$1-sampler.txt" "$1" "$2" "$LOGS/$1.kv" <<'PY'
import os
import re
import sys

timef, rssf, sampf, label, status, kvf = sys.argv[1:7]
t = open(timef, encoding="utf-8", errors="replace").read() if os.path.exists(timef) else ""


def grab(*patterns):
    for p in patterns:
        m = re.search(p, t)
        if m:
            return m.group(1)
    return None


kv = {"exit": status}
el = grab(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): (\S+)")
if el:
    s = 0.0
    for part in el.split(":"):
        s = s * 60 + float(part)
    kv["wall"] = "%.2f" % s
else:
    kv["wall"] = grab(r"([\d.]+) real") or "?"
kv["user"] = grab(r"User time \(seconds\): ([\d.]+)", r"([\d.]+) user") or "?"
kv["sys"] = grab(r"System time \(seconds\): ([\d.]+)", r"([\d.]+) sys") or "?"
k = grab(r"Maximum resident set size \(kbytes\): (\d+)")
b = grab(r"(\d+)\s+maximum resident set size")
kv["maxRssMiB"] = str(int(k) // 1024) if k else (str(int(b) // 2**20) if b else "?")
peaks = {}
if os.path.exists(rssf):
    for line in open(rssf, encoding="utf-8"):
        f = line.split()
        if line.startswith("#") or len(f) < 6:
            continue
        a, fi, sw = (int(x) if x.isdigit() else 0 for x in f[3:6])
        p = peaks.setdefault(f[1], [0, 0, 0])
        peaks[f[1]] = [max(p[0], a), max(p[1], fi), max(p[2], sw)]
kv["peaks"] = ";".join("%s:anon=%d,file=%d,swap=%d" % (n, *v) for n, v in sorted(peaks.items())) or "-"
free = avail = swap = None
if os.path.exists(sampf):
    for line in open(sampf, encoding="utf-8"):
        f = line.split()
        if len(f) < 4:
            continue
        d, m, w = (int(re.match(r"\d+", x).group()) if re.match(r"\d+", x) else None for x in f[1:4])
        free = d if free is None or (d is not None and d < free) else free
        avail = m if avail is None or (m is not None and m < avail) else avail
        swap = w if swap is None or (w is not None and w > swap) else swap
kv["minFreeGiB"] = "-" if free is None else str(free)
kv["minAvailMiB"] = "-" if avail is None else str(avail)
kv["maxSwapMiB"] = "-" if swap is None else str(swap)
with open(kvf, "w", encoding="utf-8") as out:
    for key, value in kv.items():
        out.write("%s=%s\n" % (key, value))
print("proc %s: exit %s; wall %s s, cpu %s user + %s sys s; max RSS %s MiB; per process peaks (MiB) %s; "
      "host: swap used up to %s MiB, MemAvailable down to %s MiB, free disk down to %s GiB" % (
          label, status, kv["wall"], kv["user"], kv["sys"], kv["maxRssMiB"], kv["peaks"],
          kv["maxSwapMiB"], kv["minAvailMiB"], kv["minFreeGiB"]))
PY
}

proc () {
  local label="$1" timer sampler peaks
  shift
  PROC_STATUS=0
  echo "start $label $(date -u +%H:%M:%S)"
  sample >"$LOGS/$label-sampler.txt" &
  sampler=$!
  # shellcheck disable=SC2046  # the time command is two words on purpose
  $(time_cmd) -o "$LOGS/$label.time" "$@" >"$LOGS/$label.out" 2>"$LOGS/$label.err" &
  timer=$!
  proc_peaks "$timer" "$label" >"$LOGS/$label.rss" &
  peaks=$!
  wait "$timer" || PROC_STATUS=$?
  wait "$peaks" 2>/dev/null || true
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  proc_summary "$label" "$PROC_STATUS"
  grep -E '^(reader|phases|proofs|reuse-from|rss-at-extract|manual root|  manual-root-cache) ' "$LOGS/$label.out" || true
  if [ "$PROC_STATUS" != 0 ]; then
    echo "--- the end of $LOGS/$label.err"
    tail -c 3000 "$LOGS/$label.err" || true
    sudo -n dmesg 2>/dev/null | grep -iE 'out of memory|killed process' | tail -n 3 || true
  fi
}

kv () { sed -n "s/^$1=//p" "$2"; }

step () {
  local label="$1" dir="$2" started=$SECONDS rc=0
  shift 2
  (cd "$dir" && "$@") >"$LOGS/$label.log" 2>&1 || rc=$?
  echo "step $label: $((SECONDS - started)) s, exit $rc"
  if [ "$rc" != 0 ]; then
    tail -c 2000 "$LOGS/$label.log" >&2 || true
    reuse_fail "$label exited $rc"
  fi
}

three_attempts () {
  local n
  for n in 1 2 3; do
    if "$@"; then return 0; fi
    echo "attempt $n of 3 failed; removing .lake/packages and retrying in 30 s" >&2
    rm -rf .lake/packages
    sleep 30
  done
  return 1
}

fetch_and_build () {
  local label="$1" dir="$2" tc
  tc="$(tr -d '[:space:]' <"$dir/lean-toolchain")"
  if ! "$ELAN" toolchain list | awk -v t="$tc" '$1 == t { found = 1 } END { exit !found }'; then
    step "$label-toolchain" "$dir" "$ELAN" toolchain install "$tc"
  fi
  rm -rf "$WORK/mathlib-cache"
  mkdir -p "$WORK/mathlib-cache"
  step "$label-cache" "$dir" three_attempts env MATHLIB_CACHE_DIR="$WORK/mathlib-cache" "$LAKE" exe cache get
  rm -rf "$WORK/mathlib-cache"
  step "$label-lake" "$dir" "$LAKE" build Mathlib
}

search_of () {
  (cd "$1" && "$LAKE" env printenv LEAN_PATH) >"$2.raw"
  tr ':' '\n' <"$2.raw" | sed '/^$/d' >"$2"
  rm -f "$2.raw"
}

READ_ARGV=()
read_args () {
  local out="$1" modules="$2" old="$3" d
  shift 3
  READ_ARGV=(extract)
  while IFS= read -r d; do READ_ARGV+=(--old "$d"); done <"$old"
  while IFS= read -r d; do READ_ARGV+=(--new "$d"); done <"$LOGS/newest-search.txt"
  READ_ARGV+=(--new-roots "$NEW_ROOTS" "$@" "$modules" "$out/events.jsonl" "${OUTPUT_FLAGS[@]}"
    --jobs "$JOBS" --ir-dir "$out/ir" --link-index "$out/link-index.lidx" --link-index-omit "$modules")
}

ir_diff () {
  python3 - "$1" "$2" "$3" <<'PY'
import collections
import json
import os
import sys

a, r, listing = sys.argv[1:4]


def files(root):
    out = {}
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            out[os.path.relpath(p, root)] = p
    return out


def count(root):
    return json.load(open(os.path.join(root, "index.json"), encoding="utf-8")).get("declarationCount", "?")


fa, fr = files(a), files(r)
one_side = sorted(set(fa) ^ set(fr))
differ, fields, names, rows = [], collections.Counter(), [], []
decl_differ = decl_one_side = module_fields = 0
for k in sorted(set(fa) & set(fr)):
    ba, br = open(fa[k], "rb").read(), open(fr[k], "rb").read()
    if ba == br:
        continue
    differ.append(k)
    ja, jr = json.loads(ba), json.loads(br)
    if not (isinstance(ja, dict) and isinstance(jr, dict)):
        fields[os.path.basename(k)] += 1
        continue
    if not all(isinstance(d, dict) and "name" in d for j in (ja, jr) for d in j.get("declarations") or [None]):
        fields.update("%s:%s" % (os.path.basename(k), x) for x in set(ja) | set(jr) if ja.get(x) != jr.get(x))
        continue
    module_fields += sum(1 for x in set(ja) | set(jr) if x != "declarations" and ja.get(x) != jr.get(x))
    da = {d["name"]: d for d in ja["declarations"]}
    dr = {d["name"]: d for d in jr["declarations"]}
    for n in sorted(set(da) | set(dr)):
        if n not in da or n not in dr:
            decl_one_side += 1
            names.append(n)
            rows.append("%s\t%s\tonly in %s" % (k, n, "(a)" if n in da else "(r)"))
        elif da[n] != dr[n]:
            decl_differ += 1
            names.append(n)
            changed = sorted(x for x in set(da[n]) | set(dr[n]) if da[n].get(x) != dr[n].get(x))
            fields.update(changed)
            rows.append("%s\t%s\t%s" % (k, n, ",".join(changed)))
with open(listing, "w", encoding="utf-8") as out:
    out.write("# IR file, declaration, the fields that differ between (a) and (r)\n")
    out.writelines(row + "\n" for row in rows)
print("irFiles=%d" % len(fa))
print("irFilesR=%d" % len(fr))
print("filesDiffer=%d" % len(differ))
print("filesOneSide=%d" % len(one_side))
print("declarations=%s" % count(a))
print("declarationsR=%s" % count(r))
print("declarationsDiffer=%d" % decl_differ)
print("declarationsOneSide=%d" % decl_one_side)
print("moduleFieldsDiffer=%d" % module_fields)
print("fields=%s" % (",".join("%s:%d" % kc for kc in sorted(fields.items())) or "-"))
print("files=%s" % (",".join(differ[:6] + one_side[:6]) or "-"))
print("names=%s" % (",".join(names[:8]) or "-"))
PY
}

reuse_arm () {
  local v tag dir out modules i k arm order prev same ratio c
  [ "${#OLDER[@]}" -gt 0 ] || reuse_fail "MV_L_TAGS names only the newest"
  mkdir -p "$WORK/ir"
  {
    echo "run of $(git -C "$ROOT" rev-parse HEAD) ($(git -C "$ROOT" status --porcelain | wc -l | tr -d ' ') uncommitted path(s))"
    record_host
    echo "tags     $(list "${TAGS[@]}") (newest $NEWEST)"
    echo "jobs     $JOBS"
    echo "flags    ${OUTPUT_FLAGS[*]}"
    echo "newest   $NEWEST_WS; native step on $NATIVE_ROOT"
    echo "modules  ${MV_L_MODULES:-each version its own (litedoc4 modules --lib Mathlib)}"
    if [ -f "$LOGS/litedoc4.sha256" ]; then echo "litedoc4 $(cat "$LOGS/litedoc4.sha256")"; fi
  } | tee "$LOGS/reuse-conditions.txt"

  echo
  echo "=== $NEWEST, the newest"
  if [ -z "${MV_L_NEWEST_WORKSPACE:-}" ]; then fetch_and_build "$NEWEST" "$NEWEST_WS"; fi
  reader_tc="$(awk '{ sub(/#.*/, "") } NF { tc = $1 } END { print tc }' "$ROOT/tools/lean-toolchains.txt")"
  [ "$(tr -d '[:space:]' <"$NEWEST_WS/lean-toolchain")" = "$reader_tc" ] ||
    reuse_fail "$NEWEST_WS pins $(cat "$NEWEST_WS/lean-toolchain"), and the reader runs on $reader_tc"
  search_of "$NEWEST_WS" "$LOGS/newest-search.txt"
  sysroot="$(cd "$NEWEST_WS" && "$LAKE" env printenv LEAN_SYSROOT)"
  outside="$(awk -v n="$NEWEST_WS/" -v s="$sysroot/" 'index($0 "/", n) != 1 && index($0 "/", s) != 1' "$LOGS/newest-search.txt")"
  [ -z "$outside" ] || reuse_fail "the newest search path leaves $NEWEST_WS: $outside (the product copies such a directory; this arm does not)"
  NEW_ROOTS="${MV_L_NEW_ROOTS:-$LOGS/newest-modules.txt}"
  if [ -z "${MV_L_NEW_ROOTS:-}" ]; then
    "$LITEDOC4" modules --root "$NEWEST_WS" --lib Mathlib --out "$NEW_ROOTS" >/dev/null
  fi
  echo "newest   $(wc -l <"$NEW_ROOTS" | tr -d ' ') modules imported, $(wc -l <"$LOGS/newest-search.txt" | tr -d ' ') search directories"

  rm -rf "$WORK/native"
  proc native "$LITEDOC4" build --root "$NATIVE_ROOT" --lib Mathlib --out "$WORK/native" \
    --jobs "$JOBS" --lake "$LAKE" --timings "$LOGS/native.timings.json"
  grep -E '^(phase|put |build )' "$LOGS/native.out" || true
  if [ -f "$LOGS/native.timings.json" ]; then
    tail -n 1 "$LOGS/native.timings.json" | python3 -c 'import json, sys
r = json.loads(sys.stdin.read())
print("native   " + ", ".join("%s %s" % (k, r[k]) for k in ("modules", "extractSeconds", "renderSeconds", "totalSeconds") if k in r))'
  fi
  tick native "$([ "$PROC_STATUS" = 0 ] && echo yes)" "litedoc4 build of $NATIVE_ROOT exited $PROC_STATUS (native extraction as today, rendering one version)"
  rm -rf "$WORK/native"

  started=$SECONDS
  "$LITEDOC4" reader build --out "$WORK/extractors" --lake "$LAKE" >"$LOGS/reader-build.log" 2>&1 ||
    reuse_fail "litedoc4 reader build failed: $(tail -c 1500 "$LOGS/reader-build.log")"
  READER="$(tail -n 1 "$LOGS/reader-build.log")"
  [ -x "$READER" ] || reuse_fail "no reader at $READER"
  echo "reader   $READER ($((SECONDS - started)) s)"

  head_modules="${MV_L_MODULES:-$NEW_ROOTS}"
  prev="$WORK/ir/head"
  rm -rf "$prev"
  mkdir -p "$prev"
  echo "head     $NEWEST read through the reader with --write-reuse-keys: a measurement crutch, because the"
  echo "         native extractor writes no reuse keys; not counted per extra version"
  read_args "$prev" "$head_modules" "$LOGS/newest-search.txt" --lazy-proofs --write-reuse-keys
  proc head "$READER" "${READ_ARGV[@]}"
  tick head "$([ "$PROC_STATUS" = 0 ] && [ -s "$prev/ir.reuse-keys" ] && echo yes)" \
    "exit $PROC_STATUS, $(wc -c 2>/dev/null <"$prev/ir.reuse-keys" | tr -d ' ' || true) bytes of reuse keys"
  if [ "$PROC_STATUS" != 0 ]; then prev=""; fi

  i=0
  for ((k = ${#OLDER[@]} - 1; k >= 0; k--)); do
    v="${OLDER[k]}"
    echo
    echo "=== $v"
    echo "disk     $(df -k "$WORK" | awk 'NR == 2 { print int($4 / 1048576) }') GiB free"
    if [ -n "${MV_L_CHECKOUTS:-}" ]; then
      dir="$MV_L_CHECKOUTS/$v"
      [ -d "$dir" ] || reuse_fail "no $dir"
    else
      dir="$WORK/co/$v"
      git -C "$MATHLIB" worktree remove --force "$dir" >/dev/null 2>&1 || true
      rm -rf "$dir"
      mkdir -p "$WORK/co"
      git -C "$MATHLIB" worktree add --detach "$dir" "refs/tags/$v" >"$LOGS/$v-worktree.log" 2>&1 ||
        reuse_fail "git worktree add $v: $(cat "$LOGS/$v-worktree.log")"
      fetch_and_build "$v" "$dir"
    fi
    echo "$v $(git -C "$dir" rev-parse HEAD) $(tr -d '[:space:]' <"$dir/lean-toolchain")"
    modules="${MV_L_MODULES:-$LOGS/$v-modules.txt}"
    if [ -z "${MV_L_MODULES:-}" ]; then
      "$LITEDOC4" modules --root "$dir" --lib Mathlib --out "$modules" >/dev/null
    fi
    search_of "$dir" "$LOGS/$v-search.txt"
    echo "targets  $(wc -l <"$modules" | tr -d ' ') modules; $(wc -l <"$LOGS/$v-search.txt" | tr -d ' ') old search directories"

    if [ $((i % 2)) = 0 ]; then order="a r"; else order="r a"; fi
    echo "order    $order"
    for arm in $order; do
      out="$WORK/ir/$v-$arm"
      rm -rf "$out"
      mkdir -p "$out"
      if [ "$arm" = a ]; then
        read_args "$out" "$modules" "$LOGS/$v-search.txt" --lazy-proofs
      elif [ -n "$prev" ]; then
        read_args "$out" "$modules" "$LOGS/$v-search.txt" --lazy-proofs --reuse-from "$prev/ir"
      else
        echo "proc $v-r: not run, the newer version left no reader IR to reuse from"
        echo "exit=not-run" >"$LOGS/$v-r.kv"
        continue
      fi
      proc "$v-$arm" "$READER" "${READ_ARGV[@]}"
    done
    for arm in a r; do
      tick "$v-$arm" "$([ "$(kv exit "$LOGS/$v-$arm.kv")" = 0 ] && echo yes)" "exit $(kv exit "$LOGS/$v-$arm.kv")"
    done

    if [ "$(kv exit "$LOGS/$v-a.kv")" = 0 ] && [ "$(kv exit "$LOGS/$v-r.kv")" = 0 ]; then
      same=no
      if cmp -s "$WORK/ir/$v-a/link-index.lidx" "$WORK/ir/$v-r/link-index.lidx"; then same=yes; fi
      ir_diff "$WORK/ir/$v-a/ir" "$WORK/ir/$v-r/ir" "$LOGS/$v-differing.txt" >"$LOGS/$v-diff.kv"
      echo "linkIndexEqual=$same" >>"$LOGS/$v-diff.kv"
      c="$LOGS/$v-diff.kv"
      ratio="$(python3 -c 'import sys; a, r = sys.argv[1:3]; print("%.2fx" % (float(a) / float(r)))' \
        "$(kv wall "$LOGS/$v-a.kv")" "$(kv wall "$LOGS/$v-r.kv")" 2>/dev/null || echo '?')"
      echo "version  $v: (a) $(kv wall "$LOGS/$v-a.kv") s, (r) $(kv wall "$LOGS/$v-r.kv") s, (a)/(r) $ratio;" \
        "IR files differing $(kv filesDiffer "$c") of $(kv irFiles "$c") (one side only $(kv filesOneSide "$c"));" \
        "declarations differing $(kv declarationsDiffer "$c") of $(kv declarations "$c")" \
        "(one side only $(kv declarationsOneSide "$c"), fields $(kv fields "$c"), e.g. $(kv names "$c"))"
      tick "$v-link-index" "$same" "(a) and (r) link index byte-equal: $same"
    else
      echo "linkIndexEqual=not-compared" >"$LOGS/$v-diff.kv"
      tick "$v-link-index" no "not compared: an arm did not finish"
    fi
    rm -rf "$WORK/ir/$v-a"
    if [ -n "$prev" ]; then rm -rf "$prev"; fi
    prev=""
    if [ "$(kv exit "$LOGS/$v-r.kv")" = 0 ]; then prev="$WORK/ir/$v-r"; else rm -rf "$WORK/ir/$v-r"; fi
    if [ -z "${MV_L_CHECKOUTS:-}" ]; then
      git -C "$MATHLIB" worktree remove --force "$dir" >/dev/null 2>&1 || true
      rm -rf "$dir"
    fi
    i=$((i + 1))
  done
  if [ -n "$prev" ]; then rm -rf "$prev"; fi

  echo
  echo "=== summary (per extra version: (a) read-alone with --lazy-proofs, (r) the same with --reuse-from)"
  printf '%-9s %9s %9s %7s %10s %10s %26s %9s %s\n' version "(a) s" "(r) s" "a/r" "(a) RSS" "(r) RSS" "(r) reused / printed" "lidx" "decls differing"
  for ((k = ${#OLDER[@]} - 1; k >= 0; k--)); do
    v="${OLDER[k]}"
    reused="$(sed -nE 's/^reuse-from +[^:]+: ([0-9]+) of ([0-9]+) declarations reused, ([0-9]+) printed.*/\1 of \2 \/ \3/p' "$LOGS/$v-r.out" 2>/dev/null || true)"
    printf '%-9s %9s %9s %7s %10s %10s %26s %9s %s\n' "$v" \
      "$(kv wall "$LOGS/$v-a.kv")" "$(kv wall "$LOGS/$v-r.kv")" \
      "$(python3 -c 'import sys; print("%.2f" % (float(sys.argv[1]) / float(sys.argv[2])))' "$(kv wall "$LOGS/$v-a.kv")" "$(kv wall "$LOGS/$v-r.kv")" 2>/dev/null || echo '?')" \
      "$(kv maxRssMiB "$LOGS/$v-a.kv")" "$(kv maxRssMiB "$LOGS/$v-r.kv")" "${reused:--}" \
      "$(kv linkIndexEqual "$LOGS/$v-diff.kv")" "$(kv declarationsDiffer "$LOGS/$v-diff.kv") of $(kv declarations "$LOGS/$v-diff.kv")"
  done
  echo "head (crutch) $(kv wall "$LOGS/head.kv") s; native $NEWEST $(kv wall "$LOGS/native.kv") s"
  echo "MV-L REUSE: $REUSE_OK of $REUSE_DECLARED"
  [ "$REUSE_OK" = "$REUSE_DECLARED" ] || exit 1
}

case "${1:-}" in
  setup)
    "$ROOT/tools/build-lean-exe.sh" --toolchain-from "$ROOT/e2e/micro" >"$LOGS/litedoc4-build.log" 2>&1
    [ -x "$LITEDOC4" ] || { echo "no $LITEDOC4" >&2; exit 1; }
    sha256sum "$LITEDOC4" | tee "$LOGS/litedoc4.sha256"
    rm -rf "$MATHLIB"
    mkdir -p "$MATHLIB"
    git -C "$MATHLIB" init -q
    git -C "$MATHLIB" remote add origin https://github.com/leanprover-community/mathlib4
    refspecs=()
    for tag in "${TAGS[@]}"; do refspecs+=("refs/tags/$tag:refs/tags/$tag"); done
    git -C "$MATHLIB" -c maintenance.auto=false -c gc.auto=0 fetch -q --depth 1 origin "${refspecs[@]}"
    git -C "$MATHLIB" -c advice.detachedHead=false checkout -q "refs/tags/$NEWEST"
    printf 'no_equations_under = ["Mathlib.Tactic", "Mathlib.Meta"]\n' >"$MATHLIB/litedoc4.toml"
    for tag in "${TAGS[@]}"; do
      echo "$tag $(git -C "$MATHLIB" rev-parse "refs/tags/${tag}^{commit}") $(git -C "$MATHLIB" show "refs/tags/${tag}:lean-toolchain")"
    done | tee "$LOGS/tags.txt"
    ;;
  session)
    rm -rf "$OUT_A"
    run a "$OUT_A" --reader-check
    ;;
  alone)
    if pkill -KILL -f "$OUT_A/extractors/reader-[^ ]*/reader session "; then
      echo "killed a reader session (a) left running" >&2
    fi
    if [ ! -f "$OUT_A/store/$NEWEST/entry.pack.gz" ]; then
      echo "(a) left no $NEWEST entry in $OUT_A/store: nothing to read the older tags into" >&2
      exit 1
    fi
    rm -rf "$OUT_B"
    cp -a "$OUT_A" "$OUT_B"
    for v in "${OLDER[@]}"; do
      if [ -d "$OUT_B/store/$v" ]; then
        "$LITEDOC4" store remove --store "$OUT_B/store" --version "$v"
      fi
    done
    ls "$OUT_B/store"
    run b "$OUT_B" --reader-alone
    ;;
  scratch)
    rm -rf "$WORK/c"
    run c "$WORK/c" --reader-alone
    ;;
  reuse)
    reuse_arm
    ;;
  compare)
    older="$(names "${OLDER[@]}")"
    declared=6
    passed=0
    check () {
      if [ "$2" = yes ]; then passed=$((passed + 1)); echo "ok   $1: $3"; else echo "FAIL $1: $3"; fi
    }
    equal=0
    for v in "${OLDER[@]}"; do
      differs="$(same_entries "$OUT_A/store" "$OUT_B/store" "$v")"
      if [ -z "$differs" ]; then equal=$((equal + 1)); else echo "differs: $differs"; fi
    done
    echo "entries equal: $equal of ${#OLDER[@]} (record.json and entry.pack.gz, session (a) against read-alone (b))"
    check entries "$([ "$equal" = "${#OLDER[@]}" ] && echo yes)" "$equal of ${#OLDER[@]}"

    said_a="$(sed -n 's/^versions extracted: //p' "$LOGS/a.out" 2>/dev/null || true)"
    want_a="${#TAGS[@]} of ${#TAGS[@]} ($(names "${TAGS[@]}")), through the reader: ${#OLDER[@]} ($older)"
    check a-extracted "$([ "$said_a" = "$want_a" ] && echo yes)" "(a) said \`${said_a:-<no line>}\`, expected \`$want_a\`"

    rounds="$(grep -E '^version v[0-9.]+: reading [0-9a-f]+ on .* in the reader session, ' "$LOGS/a.out" | sed 's/.* in the reader session, //' | tr '\n' ';' || true)"
    want_rounds="built whole;"
    for ((i = 1; i < ${#OLDER[@]}; i++)); do want_rounds="${want_rounds}patched from ${OLDER[i-1]};"; done
    stopped="$(grep -cE "^session stopped after ${#OLDER[@]} request\\(s\\)$" "$LOGS/a.out" || true)"
    check a-rounds "$([ "$rounds" = "$want_rounds" ] && [ "$stopped" = 1 ] && echo yes)" \
      "(a) rounds \`$rounds\`, expected \`$want_rounds\`; $stopped line(s) \`session stopped after ${#OLDER[@]} request(s)\`"

    patch_zero="$(grep -cE '^check-patch +0 modules differ from rewriteMerge.s state, pointer by pointer; 0 other differences$' "$LOGS/a.out" || true)"
    patch_all="$(grep -cE '^check-patch ' "$LOGS/a.out" || true)"
    keys_zero="$(grep -cE '^check-keys +0 keys differ from a fresh pass ' "$LOGS/a.out" || true)"
    keys_all="$(grep -cE '^check-keys ' "$LOGS/a.out" || true)"
    check a-check "$([ "$patch_zero" = "${#OLDER[@]}" ] && [ "$patch_all" = "${#OLDER[@]}" ] && [ "$keys_zero" = "${#OLDER[@]}" ] && [ "$keys_all" = "${#OLDER[@]}" ] && echo yes)" \
      "check-patch 0 on $patch_zero of $patch_all round(s), check-keys 0 on $keys_zero of $keys_all, expected ${#OLDER[@]} of ${#OLDER[@]} each"

    said_b="$(sed -n 's/^versions extracted: //p' "$LOGS/b.out" 2>/dev/null || true)"
    want_b="${#OLDER[@]} of ${#TAGS[@]} ($older), through the reader: ${#OLDER[@]} ($older)"
    alone_lines="$(grep -cE '^version v[0-9.]+: reading [0-9a-f]+ on .* through the reader alone$' "$LOGS/b.out" || true)"
    sessions="$(grep -cE '^session ' "$LOGS/b.out" || true)"
    check b-extracted "$([ "$said_b" = "$want_b" ] && [ "$alone_lines" = "${#OLDER[@]}" ] && [ "$sessions" = 0 ] && echo yes)" \
      "(b) said \`${said_b:-<no line>}\`, expected \`$want_b\`; $alone_lines of ${#OLDER[@]} read alone, $sessions session line(s)"

    rendered_b="$(sed -n 's/^versions rendered: //p' "$LOGS/b.out" 2>/dev/null || true)"
    check b-rendered "$([ "$rendered_b" = "0 of ${#TAGS[@]} ()" ] && echo yes)" \
      "(b) rendered \`${rendered_b:-<no line>}\`, expected \`0 of ${#TAGS[@]} ()\`: (a)'s render ledger keys each version by its entry's bytes"

    echo "MV-L COMPARE: $passed of $declared"
    [ "$passed" = "$declared" ]
    ;;
  report)
    if [ ! -d "$OUT_A/store" ]; then OUT_A="$WORK/c"; fi
    {
      echo "store entries (bytes):"
      find "$OUT_A/store" -type f -exec ls -l {} + | awk '{ print $5, $9 }' | sed "s#$OUT_A/##"
      echo "site: $(find "$OUT_A/site" -type f | wc -l | tr -d ' ') files, $(du -sk "$OUT_A/site" | awk '{ print $1 }') KiB"
      for d in "$OUT_A/site"/*/; do
        echo "  $(basename "$d"): $(find "$d" -type f | wc -l | tr -d ' ') files, $(du -sk "$d" | awk '{ print $1 }') KiB"
      done
      df -h "$WORK"
    } | tee "$LOGS/report.txt"
    ;;
  *)
    sed -n '2,/^set -/p' "$0" | sed '$d' >&2
    exit 2
    ;;
esac
answer 0
