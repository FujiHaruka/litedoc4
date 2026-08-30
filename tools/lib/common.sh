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
on_exit () {
  # shellcheck disable=SC2064  # $1 is quoted into the trap on purpose: see above
  trap "__on_exit_run $(printf '%q' "$1")" EXIT
}

__on_exit_run () {
  local rc=$?
  if ! ( set +e; eval "$1" ); then
    echo "cleanup failed (the exit status is still $rc): $1" >&2
  fi
  return "$rc"
}

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
