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
