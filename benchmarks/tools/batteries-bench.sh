#!/bin/bash
# doc-gen4 and litedoc4 documenting Batteries on one runner, in alternating rounds that each
# start from the same state. One subcommand per workflow step (.github/workflows/batteries-bench.yml);
# everything it writes goes to $LOGS.
#   start            timings header, the machine at the start, lake's CLI, the repository's HEAD
#   free-disk        the runner's preinstalled toolchains this run does not use
#   elan             elan with no default toolchain
#   litedoc4-bin     litedoc4 built as tools/mathlib-site.sh setup builds it
#   batteries        Batteries $BATTERIES_TAG (--depth 1), `lake build Batteries`, its
#                             declared libraries and modules
#   docgen-ws        the workaround workspace: doc-gen4 $DOCGEN_REV and ../batteries
#   docgen-build     `lake build doc-gen4`
#   docgen-core      core's docInfo (@doc-gen4/coreDocs) and HTML (Workaround:docs), then
#                             the snapshot of .lake/build every doc-gen4 round is reset to
#   litedoc4-prime   one litedoc4 round that builds the extractor the later rounds reuse
#   rounds-minutes   the rounds step's timeout-minutes into $GITHUB_OUTPUT
#   rounds           cold, warm-up and $ROUNDS warm rounds at $JOBS_HI, then up to $ROUNDS at
#                             $JOBS_LO; arms alternate, and a round starts only with 1.5x the
#                             longest round of its arm left before the deadline
#   summarize        summary.tsv and cells.tsv from rounds.tsv
#   end              the machine at the end
# Environment: JOB_START (epoch seconds, set by the workflow's first step), BENCH_WORK, LOGS,
# BATTERIES_TAG, DOCGEN_REV, ROUNDS, JOBS_HI, JOBS_LO, DOCGEN_JOBS1 (skip | lean-num-threads),
# JOB_MINUTES, RESERVE_MINUTES, STEP_RESERVE_MINUTES, ROUND_TIMEOUT_S, DOCGEN4_FIRST_ESTIMATE_S,
# LITEDOC4_FIRST_ESTIMATE_S, BATTERIES_BUILD_TIMEOUT, LITEDOC4_BIN, GNU_TIME, TIMEOUT_BIN.
set -euo pipefail

P=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$P/../.." && pwd)
W=${BENCH_WORK:-$HOME/batteries-bench}
LOGS=${LOGS:-$W/logs}
BATT=$W/batteries
WS=$W/workaround
SNAP=$W/workaround-build-core
LD4OUT=$W/litedoc4-out
LITEDOC4=${LITEDOC4_BIN:-$ROOT/.lake/build/bin/litedoc4}
TAG=${BATTERIES_TAG:-v4.35.0}
DOCGEN_REV=${DOCGEN_REV:-$TAG}
ROUNDS=${ROUNDS:-5}
JOBS_HI=${JOBS_HI:-4}
JOBS_LO=${JOBS_LO:-1}
DOCGEN_JOBS1=${DOCGEN_JOBS1:-skip}
JOB_MINUTES=${JOB_MINUTES:-360}
RESERVE_MINUTES=${RESERVE_MINUTES:-20}
STEP_RESERVE_MINUTES=${STEP_RESERVE_MINUTES:-12}
ROUND_TIMEOUT_S=${ROUND_TIMEOUT_S:-3600}
DOCGEN4_FIRST_ESTIMATE_S=${DOCGEN4_FIRST_ESTIMATE_S:-1200}
LITEDOC4_FIRST_ESTIMATE_S=${LITEDOC4_FIRST_ESTIMATE_S:-300}
BATTERIES_BUILD_TIMEOUT=${BATTERIES_BUILD_TIMEOUT:-3600}
GNU_TIME=${GNU_TIME:-/usr/bin/time}
TIMEOUT_BIN=${TIMEOUT_BIN:-timeout}
BENCH="python3 -I $P/batteries-bench.py"
ROWS=$LOGS/rounds.tsv
LONGEST=$LOGS/longest.tsv
mkdir -p "$W" "$LOGS"
export PATH="$HOME/.elan/bin:$PATH"

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

timing_line() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" | tee -a "$LOGS/timings.txt"
}

timed() {
  local name=$1; shift
  local s0 t0 t1 rc
  s0=$(utc); t0=$(date +%s.%N)
  if "$@"; then rc=0; else rc=$?; fi
  t1=$(date +%s.%N)
  timing_line "$name" "$s0" "$(utc)" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')" "$rc"
  return "$rc"
}

remaining() {
  : "${JOB_START:?JOB_START comes from the first workflow step}"
  echo $(( JOB_START + (JOB_MINUTES - RESERVE_MINUTES) * 60 - $(date +%s) ))
}

record() {
  {
    echo "## date"; utc
    echo "## image"; echo "ImageOS=${ImageOS:-?} ImageVersion=${ImageVersion:-?} RUNNER_OS=${RUNNER_OS:-?}"
    echo "## kernel"; uname -a
    echo "## nproc"; getconf _NPROCESSORS_ONLN || true
    echo "## lscpu"; lscpu || true
    echo "## meminfo"; cat /proc/meminfo || true
    echo "## swap"; swapon --show || true; free -b || true
    echo "## vmstat"; grep -E '^(pswpin|pswpout|pgmajfault|oom_kill) ' /proc/vmstat || true
    echo "## df"; df -h || true
    echo "## vm sysctl"; sysctl vm.swappiness vm.overcommit_memory 2>/dev/null || true
    echo "## oom"; sudo -n dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' || echo "(none)"
  } > "$LOGS/machine-$1.txt" 2>&1
}

mem_line() {
  awk -v when="$1" '
    /^MemTotal:/ { mt = $2 } /^MemAvailable:/ { ma = $2 }
    /^pswpin / { si = $2 } /^pswpout / { so = $2 } /^pgmajfault / { mf = $2 }
    END { printf "%s\t%s\t%s\t%s\t%s\t%s\n", when, mt, ma, si, so, mf }' \
    /proc/meminfo /proc/vmstat 2>/dev/null || printf '%s\t\t\t\t\t\n' "$1"
}

tree_pids() {
  ps -e -o pid=,ppid= | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      inside[root] = 1
      grew = 1
      while (grew) {
        grew = 0
        for (p in parent) if (!(p in inside) && (parent[p] in inside)) { inside[p] = 1; grew = 1 }
      }
      for (p in inside) print p
    }'
}

sample() {
  local root=$1 out=$2 top=$3 tick=0
  printf 't\tVmRSS\tRssAnon\tRssFile\tVmSwap\tnprocs\tMemTotal\tMemAvailable\tCached\tSwapFree\tpswpin\tpswpout\tpgmajfault\tRootAvailKB\n' > "$out"
  : > "$top"
  while kill -0 "$root" 2>/dev/null; do
    local files tree sys disk
    files=$(tree_pids "$root" | sed 's#.*#/proc/&/status#')
    tree=$({ cat $files 2>/dev/null || true; } | awk '
      /^VmRSS:/ { a += $2 } /^RssAnon:/ { b += $2 } /^RssFile:/ { c += $2 } /^VmSwap:/ { d += $2 }
      /^Pid:/ { n++ }
      END { printf "%d\t%d\t%d\t%d\t%d", a, b, c, d, n }')
    sys=$(awk '
      /^MemTotal:/ { mt = $2 } /^MemAvailable:/ { ma = $2 } /^Cached:/ { ca = $2 } /^SwapFree:/ { sf = $2 }
      /^pswpin / { si = $2 } /^pswpout / { so = $2 } /^pgmajfault / { mf = $2 }
      END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s", mt, ma, ca, sf, si, so, mf }' \
      /proc/meminfo /proc/vmstat 2>/dev/null || printf '\t\t\t\t\t\t')
    disk=$(df -k --output=avail / 2>/dev/null | tail -1 | tr -d ' ' || true)
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$tree" "$sys" "$disk" >> "$out"
    if [ $((tick % 10)) -eq 0 ]; then
      { echo "== $(utc)"; ps -eo pid,ppid,rss,etimes,args --sort=-rss 2>/dev/null | head -8 | cut -c1-240; } >> "$top" || true
    fi
    tick=$((tick + 1))
    sleep 1
  done
}

measure() {
  local name=$1 budget=$2 log=$3; shift 3
  local s0 t0 t1 rc root sp wall outcome progress
  if [ "$budget" -lt 60 ]; then
    timing_line "$name" "$(utc)" "$(utc)" 0 124
    printf 'outcome\tnot started: %s s left before the deadline\nexit\t124\nwall_s\t0\n' "$budget" | tee "$LOGS/$name-outcome.txt"
    return 124
  fi
  record "before-$name"
  printf 'when\tMemTotal\tMemAvailable\tpswpin\tpswpout\tpgmajfault\n' > "$LOGS/$name-mem.tsv"
  mem_line before >> "$LOGS/$name-mem.tsv"
  echo "$name: budget $budget s, $*"
  s0=$(utc); t0=$(date +%s)
  "$GNU_TIME" -v -o "$LOGS/$name.time" "$TIMEOUT_BIN" -k 120 "$budget" "$@" > "$log" 2>&1 &
  root=$!
  sample "$root" "$LOGS/$name-sampler.tsv" "$LOGS/$name-top.txt" &
  sp=$!
  if wait "$root"; then rc=0; else rc=$?; fi
  t1=$(date +%s)
  wait "$sp" || true
  mem_line after >> "$LOGS/$name-mem.tsv"
  wall=$((t1 - t0))
  timing_line "$name" "$s0" "$(utc)" "$wall" "$rc"
  record "after-$name"
  if [ "$rc" -eq 0 ]; then outcome=finished
  elif { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; } && [ "$wall" -ge $((budget - 1)) ]; then outcome=timeout
  else outcome=failed
  fi
  progress=$(grep -oE '\[[0-9]+/[0-9]+\]' "$log" | tail -1 || true)
  {
    printf 'outcome\t%s\n' "$outcome"
    printf 'exit\t%s\n' "$rc"
    printf 'wall_s\t%s\n' "$wall"
    printf 'budget_s\t%s\n' "$budget"
    printf 'command\t%s\n' "$*"
    printf 'last_progress\t%s\n' "${progress:-(none)}"
    printf 'last_line\t%s\n' "$(tail -1 "$log" | cut -c1-400)"
  } | tee "$LOGS/$name-outcome.txt"
  return "$rc"
}

drop_caches() {
  sync
  echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
}

reset_docgen4() {
  rsync -a --delete "$SNAP/" "$WS/.lake/build/"
  printf 'batteries markers after reset\t%s\n' \
    "$(find "$WS/.lake/build/doc-data" -maxdepth 1 -name 'Batteries*' | wc -l | tr -d ' ')"
}

reset_litedoc4() {
  mkdir -p "$LD4OUT"
  find "$LD4OUT" -mindepth 1 -maxdepth 1 ! -name extractors ! -name litedoc4-build.json -exec rm -rf {} +
  printf 'litedoc4 out after reset\t%s\n' "$(ls "$LD4OUT" | tr '\n' ' ')"
}

longest_get() {
  if [ -f "$LONGEST" ]; then
    awk -F'\t' -v k="$1" '$1 == k && $2 > m { m = $2 } END { printf "%d\n", m }' "$LONGEST"
  else
    echo 0
  fi
}

needed_for() {
  local arm=$1 jobs=$2 est any
  est=$(longest_get "$arm-$jobs")
  if [ "$est" -eq 0 ]; then
    any=$(longest_get "$arm-$JOBS_HI")
    if [ "$any" -gt 0 ] && [ "$jobs" -lt "$JOBS_HI" ]; then
      est=$(( any * ((JOBS_HI + jobs - 1) / jobs) ))
    elif [ "$any" -gt 0 ]; then
      est=$any
    elif [ "$arm" = docgen4 ]; then
      est=$DOCGEN4_FIRST_ESTIMATE_S
    else
      est=$LITEDOC4_FIRST_ESTIMATE_S
    fi
  fi
  echo $(( est * 3 / 2 ))
}

SEQ_FILE=$LOGS/round-seq.txt

next_id() {
  local n=0
  if [ -f "$SEQ_FILE" ]; then n=$(cat "$SEQ_FILE"); fi
  n=$((n + 1))
  echo "$n" > "$SEQ_FILE"
  printf 'r%02d-%s-j%s-%s' "$n" "$1" "$2" "$3"
}

docgen4_round() {
  local id=$1 jobs=$2 budget=$3 rc=0 left
  local envs
  if [ "$jobs" = "$JOBS_HI" ]; then envs=(env); else envs=(env "LEAN_NUM_THREADS=$jobs"); fi
  cd "$WS"
  measure "$id-docs" "$budget" "$LOGS/$id-docs.log" "${envs[@]}" lake build Batteries:docs || rc=$?
  if [ "$rc" -eq 0 ]; then
    left=$(remaining)
    if [ "$left" -gt "$ROUND_TIMEOUT_S" ]; then left=$ROUND_TIMEOUT_S; fi
    measure "$id-header" "$left" "$LOGS/$id-header.log" "${envs[@]}" lake build Batteries:docsHeader || rc=$?
  fi
  $BENCH html-count "$WS/.lake/build/doc" 1 > "$LOGS/$id-html.tsv" || true
  cd "$W"
  return "$rc"
}

litedoc4_round() {
  local id=$1 jobs=$2 budget=$3 rc=0
  measure "$id" "$budget" "$LOGS/$id.log" \
    "$LITEDOC4" build --root "$BATT" --lib Batteries --out "$LD4OUT" --jobs "$jobs" \
    --lake "$(command -v lake)" --timings "$LOGS/$id-timings.jsonl" || rc=$?
  $BENCH html-count "$LD4OUT/site" 2 > "$LOGS/$id-html.tsv" || true
  if [ -f "$LD4OUT/litedoc4-build.json" ]; then cp "$LD4OUT/litedoc4-build.json" "$LOGS/$id-build.json"; fi
  if [ -f "$LD4OUT/work/modules.txt" ]; then cp "$LD4OUT/work/modules.txt" "$LOGS/$id-modules.txt"; fi
  return "$rc"
}

round() {
  local arm=$1 jobs=$2 kind=$3 id need rem budget rc=0 parts result wall
  id=$(next_id "$arm" "$jobs" "$kind")
  need=$(needed_for "$arm" "$jobs")
  rem=$(remaining)
  if [ "$rem" -lt "$need" ]; then
    echo "$id: not started, $rem s left and $need s needed (1.5x the longest $arm round)"
    $BENCH skip --rows "$ROWS" --id "$id" --arm "$arm" --jobs "$jobs" --kind "$kind" \
      --reason "deadline: $rem s left, $need s needed"
    return 3
  fi
  budget=$rem
  if [ "$budget" -gt "$ROUND_TIMEOUT_S" ]; then budget=$ROUND_TIMEOUT_S; fi
  echo "== $id: $(utc), $rem s left"
  if ! "reset_$arm" > "$LOGS/$id-reset.txt" 2>&1; then
    cat "$LOGS/$id-reset.txt"
    $BENCH skip --rows "$ROWS" --id "$id" --arm "$arm" --jobs "$jobs" --kind "$kind" \
      --status reset-failed --reason "reset_$arm failed: $(tail -1 "$LOGS/$id-reset.txt" | cut -c1-200)"
    return 3
  fi
  if [ "$kind" = cold ]; then
    if ! drop_caches; then
      $BENCH skip --rows "$ROWS" --id "$id" --arm "$arm" --jobs "$jobs" --kind "$kind" \
        --status reset-failed --reason "drop_caches failed"
      return 3
    fi
    echo "page cache dropped" >> "$LOGS/$id-reset.txt"
  fi
  cat "$LOGS/$id-reset.txt"
  if [ "$arm" = docgen4 ]; then
    docgen4_round "$id" "$jobs" "$budget" || rc=$?
    parts="$id-docs,$id-header"
  else
    litedoc4_round "$id" "$jobs" "$budget" || rc=$?
    parts=$id
  fi
  if ! result=$($BENCH round --logs "$LOGS" --rows "$ROWS" --id "$id" --arm "$arm" --jobs "$jobs" \
      --kind "$kind" --parts "$parts" --declared "$LOGS/declared-closure.txt" \
      --declared-glob "$LOGS/declared-glob.txt"); then
    printf '%s\t%s\t%s\t%s\tbench-failed\n' "$id" "$arm" "$jobs" "$kind" >> "$ROWS"
    result="status bench-failed"
  fi
  printf '%s\n' "$result" | tee "$LOGS/$id-scope.txt"
  wall=$(printf '%s\n' "$result" | awk '$1 == "wall" { printf "%d", $2 }')
  if [ -n "$wall" ] && [ "$wall" -gt 0 ]; then printf '%s\t%s\n' "$arm-$jobs" "$wall" >> "$LONGEST"; fi
  return 0
}

declare_cell() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$LOGS/cells-declared.tsv"
}

case "${1:-}" in
  start)
    printf 'name\tstart_utc\tend_utc\twall_s\texit\n' > "$LOGS/timings.txt"
    record start
    {
      echo "JOB_START=${JOB_START:-unset}"
      echo "litedoc4 HEAD $(git -C "$ROOT" rev-parse HEAD)"
      echo "BATTERIES_TAG=$TAG DOCGEN_REV=$DOCGEN_REV ROUNDS=$ROUNDS JOBS_HI=$JOBS_HI JOBS_LO=$JOBS_LO DOCGEN_JOBS1=$DOCGEN_JOBS1"
      echo "JOB_MINUTES=$JOB_MINUTES RESERVE_MINUTES=$RESERVE_MINUTES STEP_RESERVE_MINUTES=$STEP_RESERVE_MINUTES ROUND_TIMEOUT_S=$ROUND_TIMEOUT_S"
      echo "DOCGEN4_FIRST_ESTIMATE_S=$DOCGEN4_FIRST_ESTIMATE_S LITEDOC4_FIRST_ESTIMATE_S=$LITEDOC4_FIRST_ESTIMATE_S"
      echo "nproc $(getconf _NPROCESSORS_ONLN)"
      if [ "$(getconf _NPROCESSORS_ONLN)" != "$JOBS_HI" ]; then
        echo "WARNING: doc-gen4's lake runs as many jobs as the machine has CPUs, not JOBS_HI=$JOBS_HI"
      fi
      echo "python3 $(python3 --version 2>&1) rsync $(rsync --version | sed -n 1p)"
    } | tee "$LOGS/run.txt"
    exit 0
    ;;
  free-disk)
    df -h / | tee "$LOGS/free-disk.txt"
    timed free-disk sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup
    df -h / | tee -a "$LOGS/free-disk.txt"
    exit 0
    ;;
  elan)
    timed elan-install bash -c 'curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none'
    echo "$HOME/.elan/bin" >> "${GITHUB_PATH:-/dev/null}"
    elan --version | tee -a "$LOGS/run.txt"
    exit 0
    ;;
  litedoc4-bin)
    timed litedoc4-bin "$ROOT/tools/build-lean-exe.sh" --toolchain-from "$ROOT/e2e/micro" > "$LOGS/litedoc4-bin.log" 2>&1
    [ -x "$LITEDOC4" ] || { echo "no $LITEDOC4" >&2; exit 1; }
    sha256sum "$LITEDOC4" | tee -a "$LOGS/run.txt"
    exit 0
    ;;
  batteries)
    rm -rf "$BATT"; mkdir -p "$BATT"
    git -C "$BATT" init -q
    git -C "$BATT" remote add origin https://github.com/leanprover-community/batteries
    timed batteries-fetch git -C "$BATT" -c maintenance.auto=false -c gc.auto=0 fetch -q --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
    git -C "$BATT" -c advice.detachedHead=false checkout -q "refs/tags/$TAG"
    toolchain=$(cat "$BATT/lean-toolchain")
    echo "batteries $TAG $(git -C "$BATT" rev-parse HEAD) $toolchain" | tee -a "$LOGS/run.txt"
    if [ "$toolchain" != "leanprover/lean4:$TAG" ]; then
      echo "batteries $TAG pins $toolchain, not leanprover/lean4:$TAG" | tee -a "$LOGS/run.txt" >&2
      exit 1
    fi
    for f in "$BATT"/lakefile.toml "$BATT"/lakefile.lean; do
      if [ -f "$f" ]; then cp "$f" "$LOGS/batteries-$(basename "$f")"; $BENCH libs "$f" | tee "$LOGS/batteries-libs.txt"; fi
    done
    $BENCH declared "$BATT" Batteries "$LOGS" | tee -a "$LOGS/run.txt"
    timed lean-toolchain-install elan toolchain install "$toolchain" > "$LOGS/toolchain-install.log" 2>&1
    cd "$BATT"
    timed batteries-build env LEAN_ABORT_ON_PANIC=1 "$TIMEOUT_BIN" -k 60 "$BATTERIES_BUILD_TIMEOUT" "$GNU_TIME" -v -o "$LOGS/batteries-build.time" lake build Batteries > "$LOGS/batteries-build.log" 2>&1
    tail -3 "$LOGS/batteries-build.log"
    timed batteries-nobuild lake build --no-build Batteries > "$LOGS/batteries-nobuild.log" 2>&1 || true
    printf 'batteries .lake\t%s KiB\n' "$(du -sk .lake | cut -f1)" | tee -a "$LOGS/run.txt"
    exit 0
    ;;
  docgen-ws)
    rm -rf "$WS"
    cd "$W"
    timed docgen-lake-new lake "+$(cat "$BATT/lean-toolchain")" new workaround lib > "$LOGS/docgen-lake-new.log" 2>&1
    cd "$WS"
    cp -f "$BATT/lean-toolchain" .
    rm -f lakefile.lean
    printf '%s\n' \
      'name = "workaround"' \
      'defaultTargets = ["workaround"]' \
      '' \
      '[[lean_lib]]' \
      'name = "Workaround"' \
      '' \
      '[[require]]' \
      'scope = "leanprover"' \
      'name = "doc-gen4"' \
      "rev = \"$DOCGEN_REV\"" \
      '' \
      '[[require]]' \
      'name = "batteries"' \
      "path = \"../$(basename "$BATT")\"" > lakefile.toml
    cp lakefile.toml "$LOGS/workaround-lakefile.toml"
    find . -path ./.lake -prune -o -type f -print | sort > "$LOGS/workaround-files.txt"
    if [ ! -d .git ]; then git init -q; fi
    git config user.email "batteries-bench@localhost"
    git config user.name "batteries-bench"
    git add .
    git commit -q -m workaround
    git remote add origin "https://github.com/leanprover-community/workaround"
    timed docgen-lake-update lake update > "$LOGS/docgen-lake-update.log" 2>&1
    cp lake-manifest.json "$LOGS/workaround-lake-manifest.json"
    printf 'workaround .lake\t%s KiB\n' "$(du -sk .lake | cut -f1)" | tee -a "$LOGS/run.txt"
    exit 0
    ;;
  docgen-build)
    cd "$WS"
    {
      lake --version
      echo "## lake --help"; lake --help
      echo "## lake build --help"; lake build --help
    } > "$LOGS/lake-help.txt" 2>&1 || true
    if grep -qE -- '--jobs|(^|[ ,])-j[ ,=]' "$LOGS/lake-help.txt"; then
      echo "lake's help names a jobs flag: see lake-help.txt" | tee -a "$LOGS/run.txt"
    else
      echo "lake's help names no jobs flag" | tee -a "$LOGS/run.txt"
    fi
    timed docgen-build lake build doc-gen4 > "$LOGS/docgen-build.log" 2>&1
    tail -3 "$LOGS/docgen-build.log"
    exit 0
    ;;
  docgen-core)
    cd "$WS"
    rc=0
    timed docgen-batteries-nobuild lake build --no-build Batteries > "$LOGS/docgen-batteries-nobuild.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "Batteries is not up to date from the workaround: building it there" | tee -a "$LOGS/run.txt"
      timed docgen-batteries-build lake build Batteries > "$LOGS/docgen-batteries-build.log" 2>&1
    fi
    measure setup-coredocs "$(remaining)" "$LOGS/setup-coredocs.log" lake build @doc-gen4/coreDocs
    measure setup-workaround-docs "$(remaining)" "$LOGS/setup-workaround-docs.log" lake build Workaround:docs
    for f in setup-coredocs setup-workaround-docs; do
      $BENCH lakejobs "$LOGS/$f.log" > "$LOGS/$f-jobs.tsv"
      awk -F'\t' '$4 != "docInfo"' "$LOGS/$f-jobs.tsv"
    done
    rm -rf "$SNAP"
    timed docgen-snapshot cp -a "$WS/.lake/build" "$SNAP"
    {
      printf 'snapshot\t%s KiB\n' "$(du -sk "$SNAP" | cut -f1)"
      ls -la "$SNAP" | sed -n 1,40p; echo "doc-data files: $(find "$SNAP/doc-data" -type f | wc -l)"
      $BENCH html-count "$SNAP/doc" 1
    } | tee "$LOGS/snapshot.txt"
    exit 0
    ;;
  litedoc4-prime)
    rm -rf "$LD4OUT"
    round litedoc4 "$JOBS_HI" prime
    exit 0
    ;;
  rounds-minutes)
    : "${JOB_START:?JOB_START comes from the first workflow step}"
    minutes=$(( (JOB_START + (JOB_MINUTES - STEP_RESERVE_MINUTES) * 60 - $(date +%s)) / 60 ))
    if [ "$minutes" -lt 1 ]; then minutes=1; fi
    echo "minutes=$minutes" | tee -a "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
    ;;
  rounds)
    if [ ! -x "$LITEDOC4" ] || [ ! -d "$SNAP" ]; then
      echo "rounds need $LITEDOC4 and $SNAP" >&2
      exit 1
    fi
    : > "$LOGS/cells-declared.tsv"
    declare_cell docgen4 "$JOBS_HI" cold 1
    declare_cell litedoc4 "$JOBS_HI" cold 1
    declare_cell docgen4 "$JOBS_HI" warmup 1
    declare_cell litedoc4 "$JOBS_HI" warmup 1
    declare_cell docgen4 "$JOBS_HI" warm "$ROUNDS"
    declare_cell litedoc4 "$JOBS_HI" warm "$ROUNDS"
    if [ "$DOCGEN_JOBS1" = lean-num-threads ]; then
      declare_cell docgen4 "$JOBS_LO" warm "$ROUNDS" "LEAN_NUM_THREADS=$JOBS_LO: lake has no jobs flag (lake-help.txt); this also reaches every process lake starts"
    else
      declare_cell docgen4 "$JOBS_LO" warm "$ROUNDS" "not run (DOCGEN_JOBS1=$DOCGEN_JOBS1): lake has no jobs flag (lake-help.txt)"
    fi
    declare_cell litedoc4 "$JOBS_LO" warm "$ROUNDS"
    round docgen4 "$JOBS_HI" cold || true
    round litedoc4 "$JOBS_HI" cold || true
    round docgen4 "$JOBS_HI" warmup || true
    round litedoc4 "$JOBS_HI" warmup || true
    i=1
    while [ "$i" -le "$ROUNDS" ]; do
      round docgen4 "$JOBS_HI" warm || true
      round litedoc4 "$JOBS_HI" warm || true
      i=$((i + 1))
    done
    i=1
    while [ "$i" -le "$ROUNDS" ]; do
      if [ "$DOCGEN_JOBS1" = lean-num-threads ]; then round docgen4 "$JOBS_LO" warm || true; fi
      round litedoc4 "$JOBS_LO" warm || true
      i=$((i + 1))
    done
    $BENCH summarize --rows "$ROWS" --cells "$LOGS/cells-declared.tsv" --out "$LOGS"
    exit 0
    ;;
  summarize)
    $BENCH summarize --rows "$ROWS" --cells "$LOGS/cells-declared.tsv" --out "$LOGS"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      for f in summary cells; do
        echo "### $f.tsv"
        awk -F'\t' -v OFS=' | ' '{ $1 = $1; print "| " $0 " |" } NR == 1 { s = "|"; for (i = 1; i <= NF; i++) s = s " --- |"; print s }' "$LOGS/$f.tsv"
        echo
      done >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
    ;;
  end)
    record end
    df -h / | tee -a "$LOGS/run.txt"
    ls -la "$LOGS" | tail -5
    exit 0
    ;;
  *)
    sed -n '2,/^set -/p' "$0" | sed '$d'
    exit 2
    ;;
esac
