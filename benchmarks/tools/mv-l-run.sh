#!/usr/bin/env bash
# usage (all of Mathlib at four releases through `litedoc4 build --versions`, the older three read
# by the .olean reader into the newest):
#   mv-l-run.sh setup     build litedoc4, clone Mathlib's tags, check out the last
#   mv-l-run.sh session   (a) every tag into an empty <work>/a, one reader session, --reader-check
#   mv-l-run.sh alone     (b) a copy of <work>/a holding only the newest entry, --reader-alone
#   mv-l-run.sh compare   (a)'s and (b)'s entries of the older tags byte for byte, and the counts
#   mv-l-run.sh report    sizes of (a)'s store and site
#
# Environment: MV_L_WORK (default $RUNNER_TEMP/mv-l or /private/tmp/lean-doc-relay/mv-l),
# MV_L_JOBS (default 4), MV_L_TAGS (default v4.32.2,v4.33.0,v4.33.1,v4.34.1; the last is the newest).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
  exit "$status"
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

case "${1:-}" in
  setup)
    "$ROOT/tools/build-lean-exe.sh" --toolchain-from "$ROOT/e2e/micro" >"$LOGS/litedoc4-build.log" 2>&1
    [ -x "$LITEDOC4" ] || { echo "no $LITEDOC4" >&2; exit 1; }
    sha256sum "$LITEDOC4" | tee "$LOGS/litedoc4.sha256"
    rm -rf "$MATHLIB"
    mkdir -p "$MATHLIB"
    git -C "$MATHLIB" init -q
    git -C "$MATHLIB" remote add origin https://github.com/leanprover-community/mathlib4
    for tag in "${TAGS[@]}"; do
      git -C "$MATHLIB" fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
    done
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
    sed -n '2,11p' "$0" >&2
    exit 2
    ;;
esac
