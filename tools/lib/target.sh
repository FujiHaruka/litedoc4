#!/usr/bin/env bash
# Where the measurement target is. Source this, don't execute it.
#
# The measurement target is fixed on purpose: numbers are only comparable when
# they come from the same workload. See CLAUDE.md "ベンチマーク".
#
# TWO NAMES FOR ONE PATH, AND THEY ARE NOT INTERCHANGEABLE
# ----------------------------------------------------------------------------
#   TARGET_REPO_BASELINE  The baseline measurement target. Nothing can override
#                         it. Read it where the path is the SUBJECT of a check
#                         — "is the caller about to write inside the
#                         measurement target?" (tools/build-gate.sh,
#                         tools/clone-gate.sh, tools/target2-gate.sh).
#
#                         A guard whose subject the caller can move is not a
#                         guard. If those `case` arms read the overridable name
#                         instead, exporting it to a harmless path would re-open
#                         writing into the real target — and a full disk there
#                         does not cost a measurement, it costs the target's
#                         state and the shell you would need to repair it
#                         (CLAUDE.md 「ベンチマーク」, 2026-08-17).
#
#   TARGET_REPO           The target this run reads. Overridable, because
#                         pointing a run at another package is a legitimate
#                         thing to do. Override only to ADD a target, never to
#                         replace the baseline one.
#
# Scripts that take a `--target` flag use TARGET_REPO as the flag's default, so
# the precedence stays: flag > environment > baseline.
#
# HOW TO SOURCE IT: ALWAYS WITH `|| exit 1`
# ----------------------------------------------------------------------------
# 11 of the 35 scripts in tools/ run under `set -uo pipefail`, without `-e`. In
# those a failing `source` prints its error and the script KEEPS GOING, with
# whatever this file had already assigned still in place — so the run looks
# entirely normal. Measured 2026-08-23: with a syntax error appended to this
# file, tools/watch-gate.sh ran the whole gate and printed
# "WATCH GATE: ok — 12 check(s), 0 failed" with exit 0. That is the shape
# CLAUDE.md names, "出力と終了コードが食い違う形はゲートを嘘にする", and here it
# would be told by every script at once. `|| exit 1` is what makes it loud; the
# `.` and `source` spellings behave identically, and under `set -e` the shell
# aborts on its own (exit 2), so the suffix costs those scripts nothing.
#
# OBSERVATION, NOT A CHANGE
# ----------------------------------------------------------------------------
# A guard that checks only the baseline does not protect a second target someone
# points TARGET_REPO at: `--clone $OTHER_TARGET` is refused only when
# $OTHER_TARGET happens to be the baseline. Widening the three guards to cover
# both names would change what they refuse, and the shell tree has no test that
# would catch a mistake there. Left alone deliberately.
TARGET_REPO_BASELINE=/Users/haruka/dev/lean-projects
TARGET_REPO="${TARGET_REPO:-$TARGET_REPO_BASELINE}"

# This repository (litedoc4), resolved from the script location.
LITEDOC4_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
