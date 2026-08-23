#!/usr/bin/env bash
# Things every script in tools/ would otherwise write again. Source this, don't
# execute it.
#
# HOW TO SOURCE IT: ALWAYS WITH `|| exit 1`
# ----------------------------------------------------------------------------
# The same rule, and for the same measured reason, as tools/lib/target.sh: 11 of
# the 35 scripts here run under `set -uo pipefail`, and in those a failing
# `source` only prints and the script keeps going. The long form of the reason
# is in target.sh; do not repeat it here, and do not drop the suffix.
#
# WHICH `set` LINE A SCRIPT IN tools/ SHOULD HAVE
# ----------------------------------------------------------------------------
# The split is 24 `set -euo pipefail` and 11 `set -uo pipefail`, and until now
# nothing wrote down which to pick.
#
#   set -euo pipefail   The default. Any failure is the end of the run.
#                       When one command's status is *data* — you want to report
#                       it rather than die of it — bracket that command with
#                       `set +e` … `CODE=$?` … `set -e`, as
#                       tools/extractor-mismatch.sh:102-106 does. That is the
#                       only place in the 35 that needs it.
#
#   set -uo pipefail    For a script whose whole job is to keep going and
#                       aggregate: the compare scripts walk a tree, count what
#                       differs, and return a status at the end. There nearly
#                       every command's status is data, so `-e` would turn the
#                       first difference into a crash.
#
# `pipefail` is not optional and is not a preference: all 35 have it, and with
# it `( exit 3 ) | tail -1` is 3 rather than 0 【実測 2026-08-23】. The pipe trap
# CLAUDE.md records is a trap of the *interactive* shell, which is zsh and has
# neither `pipefail` nor `PIPESTATUS`.

# Run `$1` when the shell exits, without letting it change the exit status.
#
# WHY THIS IS NOT `trap cleanup EXIT`
# ----------------------------------------------------------------------------
# Under `set -e` a plain EXIT trap can replace the script's answer with 1. The
# measurement 【2026-08-23, bash 3.2.57 and 5.3.9 alike】:
#
#                       falls off the end   exit 0   exit 7
#   set -uo pipefail            0              0        7
#   set -euo pipefail           1              1        1     <- cleanup's failure wins
#
# The mechanism is that a failing command *inside* the trap trips `set -e`,
# which aborts the trap — so writing the cleanup to end in `return "$rc"` does
# not help either: `set -e` never lets it get there. tools/e2e-micro.sh printed
# "E2E MICRO: ok" and exited 1 this way 【実測 2026-08-18】.
#
# So the caller cannot be made responsible for it. `$1` runs in a subshell with
# `-e` off, and the status the script already had is what it exits with —
# whatever the cleanup does. A cleanup that fails is still *said*, on stderr,
# because a scratch tree that could not be removed is worth knowing about; it
# just does not get to answer the question the script was asked.
#
# `$1` is a function name or a command string, and it is expanded when the trap
# runs rather than when it is installed — the same timing as `trap '…' EXIT`
# 【実測】, so `on_exit 'rm -rf "$WORK"'` sees the `$WORK` of the moment it
# fires. Calling `on_exit` twice replaces the action, as a second `trap` would.
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

# The date and the machine, in the spelling five scripts had already converged
# on. CLAUDE.md 「計測条件を毎回記録する」 asks for the host and the RAM by name,
# because this workload is memory-bound and a number without them cannot be read.
#
# WHY IT ANSWERS `?` RATHER THAN A NUMBER
# ----------------------------------------------------------------------------
# Four of those five asked `sysctl -n hw.memsize` with no fallback. Off macOS
# that prints nothing, `$(( / 1024 / 1024 / 1024 ))` is a shell syntax error on
# stderr, the RAM field comes out empty — and the script exits 0 【実測
# 2026-08-23】. The fifth (watch-gate) had a fallback and wrote `0 GB`, which is
# worse: an empty field is visibly missing, and `0` is a measurement. So this
# reads /proc where sysctl is absent, and says `?` when neither answers.
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
