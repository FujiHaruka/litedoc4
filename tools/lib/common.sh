#!/usr/bin/env bash
# Things every script in tools/ would otherwise write again. Source this, don't
# execute it — and **always with `|| exit 1`**: 11 of the 35 scripts here run
# under `set -uo pipefail`, where a failing `source` only prints and the script
# keeps going. tools/lib/target.sh carries the long form of that reason.
#
# Which `set` line a script in tools/ should have:
#
#   set -euo pipefail   The default. When one command's status is *data*, bracket
#                       it with `set +e` … `CODE=$?` … `set -e`.
#   set -uo pipefail    For a script whose whole job is to keep going and
#                       aggregate — the compare scripts, where `-e` would turn
#                       the first difference into a crash.
#
# `pipefail` is not a preference: with it `( exit 3 ) | tail -1` is 3 rather than
# 0 (measured 2026-08-23). The pipe trap CLAUDE.md records is a trap of the
# *interactive* shell, which is zsh and has neither `pipefail` nor `PIPESTATUS`.

# Run `$1` when the shell exits, without letting it change the exit status.
#
# **Not `trap cleanup EXIT`**: under `set -e` a plain EXIT trap replaces the
# script's answer with 1 (measured 2026-08-23, bash 3.2.57 and 5.3.9 alike):
#
#                       falls off the end   exit 0   exit 7
#   set -uo pipefail            0              0        7
#   set -euo pipefail           1              1        1     <- cleanup's failure wins
#
# A failing command *inside* the trap trips `set -e`, which aborts the trap, so
# ending the cleanup in `return "$rc"` does not help either. tools/e2e-micro.sh
# printed "E2E MICRO: ok" and exited 1 this way (measured 2026-08-18). Here `$1`
# runs in a subshell with `-e` off; a cleanup that fails is still said on stderr,
# it just does not get to answer the question the script was asked.
#
# `$1` is expanded when the trap runs, not when it is installed (measured), so
# `on_exit 'rm -rf "$WORK"'` sees the `$WORK` of the moment it fires. Calling
# `on_exit` twice replaces the action, as a second `trap` would.
#
# **What `rc` cannot recover, and it is a macOS-only hole.** On bash 3.2 an
# abort from `set -u` reaches the EXIT trap with `$?` already **0**, so `rc` is 0
# and `return "$rc"` faithfully answers 0 for a script that died on an unbound
# variable (measured 2026-09-02; bash 5 exits 1 either way, so CI never shows
# it). Nothing inside this function can tell that apart from falling off the end
# -- `$?`, `BASH_COMMAND` and the trap's own view are identical in the two
# (measured 2026-09-02), which is why `answer_required` below is a flag rather
# than something cleverer.
#
# **`set -e` is what makes it a hole**, and that is narrower than it was first
# written down: under `set -uo pipefail` the same abort exits 1 with the trap
# installed (measured 2026-09-02 -> benchmarks/results/bash32-answer-guard-2026-09-02.txt).
# 13 scripts here combine `set -u` with a trap; the 3 that are `set -uo pipefail`
# -- render-compare.sh, site-compare.sh and watch-gate.sh -- are not exposed and
# do not claim anything, and the other 10 all call `answer_required`.
on_exit () {
  # shellcheck disable=SC2064  # $1 is quoted into the trap on purpose: see above
  trap "__on_exit_run $(printf '%q' "$1")" EXIT
}

__on_exit_run () {
  local rc=$?
  if ! ( set +e; eval "$1" ); then
    echo "cleanup failed (the exit status is still $rc): $1" >&2
  fi
  if [ "$rc" -eq 0 ] && [ "$__ANSWER_REQUIRED" -eq 1 ] && [ "$__ANSWER_GIVEN" -eq 0 ]; then
    echo "$__ANSWER_WHO: stopped before any of its own endings, so this 0 is not an answer -- read the error above" >&2
    exit 70
  fi
  return "$rc"
}

# Say that a 0 out of this script only counts if a path claimed it, and claim
# one. Together they close the hole above: `answer_required` up front (before
# anything can exit), `answer <status>` on **every path that exits 0**, and a 0
# nobody claimed comes out as 70 instead. A non-zero status is left alone -- the
# aborts this defends against all arrive as 0.
#
# **`exit 70`, not `return 70`**: under `set -uo pipefail` a trap's return value
# is discarded and the pending status stands, so a `return` here would be a guard
# that does nothing at all the first time a `set -uo pipefail` script opts in --
# silently, since the two spellings agree on every other path (measured
# 2026-09-02, both bash 3.2.57 and 5.3.9).
#
# `answer` inside `$(...)`, a pipeline or any other subshell exits the subshell
# and claims nothing, the same way `exit` would. It is called from the top level.
#
# tools/workflow-gate.sh question 5 is what keeps the pairing honest: a script
# here that combines `set -e` with an EXIT trap and never says `answer_required`
# fails it by name, because the next such script is otherwise written silently.
__ANSWER_REQUIRED=0
__ANSWER_GIVEN=0
__ANSWER_WHO="${0##*/}"

answer_required () { __ANSWER_REQUIRED=1; }
answer () { __ANSWER_GIVEN=1; exit "${1:-0}"; }

# The host and the RAM by name, because this workload is memory-bound and a
# number without them cannot be read.
#
# It answers `?` rather than a number when neither `sysctl` nor /proc does:
# `sysctl -n hw.memsize` off macOS prints nothing, `$(( / 1024 / 1024 / 1024 ))`
# is a syntax error on stderr and the field comes out empty while the script
# exits 0 (measured 2026-08-23) — and a fallback of `0 GB` is worse still, because
# an empty field is visibly missing and `0` reads as a measurement.
record_host () {
  printf 'date              %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host              %s / %s / %s GB\n' \
    "$(uname -srm)" "$(__cpu_brand)" "$(__memory_gb)"
}

__cpu_brand () {
  local brand
  brand="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)" ||
    brand="$(awk -F': *' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)"
  echo "${brand:-?}"
}

__memory_gb () {
  local bytes kb
  if bytes="$(sysctl -n hw.memsize 2>/dev/null)" && [ -n "$bytes" ]; then
    echo "$((bytes / 1024 / 1024 / 1024))"
    return 0
  fi
  kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null)" || kb=""
  if [ -n "$kb" ]; then echo "$((kb / 1024 / 1024))"; else echo '?'; fi
}

# The extractor, built inside e2e/micro's environment, at the path every caller
# already agreed on. Three scripts want it — tools/e2e-micro.sh,
# tools/lake-package-gate.sh and tools/purelean-micro-gate.sh — and the two
# decisions it makes are the ones a second copy gets wrong: **where the binary
# lives** (a gitignored directory inside the sample, so a checkout never carries
# a stale one) and **when to rebuild it** (when the source is newer, not only
# when it is missing — a stale binary lets every check downstream pass against
# an extractor built before the change under test).
#
# `-rdynamic` is load-bearing: `importModules (loadExts := true)` resolves
# symbols in the running executable through the Lean interpreter.
#
# usage: micro_extractor <repo-root> <micro-dir> <lake> <build-log>
# echoes the binary's path; the caller decides whether a missing one is fatal.
micro_extractor () {
  local root="$1" micro="$2" lake="$3" log="$4"
  local exe="$micro/.lake/e2e-extract/extract"
  if [ ! -x "$exe" ] || [ "$root/extractor/Extract.lean" -nt "$exe" ]; then
    mkdir -p "$micro/.lake/e2e-extract"
    ( cd "$micro" && "$lake" env lean --root="$root/extractor" \
        -o "$micro/.lake/e2e-extract/Extract.olean" \
        -c "$micro/.lake/e2e-extract/Extract.c" \
        "$root/extractor/Extract.lean" ) >"$log" 2>&1
    ( cd "$micro" && "$lake" env leanc -rdynamic \
        -o "$exe" "$micro/.lake/e2e-extract/Extract.c" ) >>"$log" 2>&1
  else
    echo "reusing $exe" >&2
  fi
  echo "$exe"
}
