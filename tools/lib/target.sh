#!/usr/bin/env bash
# Where the measurement target is. Source this, don't execute it — and **always
# with `|| exit 1`**. 11 of the 35 scripts in tools/ run under `set -uo pipefail`,
# without `-e`, and there a failing `source` prints its error and the script keeps
# going with whatever was already assigned: with a syntax error appended to this
# file, tools/watch-gate.sh ran the whole gate and printed
# "WATCH GATE: ok — 12 check(s), 0 failed" with exit 0 【実測 2026-08-23】. Under
# `set -e` the shell aborts on its own, so the suffix costs those scripts nothing.
#
# The target is fixed on purpose: numbers are only comparable when they come from
# the same workload.
#
# **Two names for one path, and they are not interchangeable:**
#
#   TARGET_REPO_BASELINE  Nothing can override it. Read it where the path is the
#                         SUBJECT of a check — "is the caller about to write
#                         inside the measurement target?". A guard whose subject
#                         the caller can move is not a guard: reading the
#                         overridable name there would let an export re-open
#                         writing into the real target, and a full disk there
#                         costs the target's state and the shell you would need
#                         to repair it.
#   TARGET_REPO           The target this run reads. Overridable, because
#                         pointing a run at another package is legitimate.
#                         Override only to ADD a target, never to replace the
#                         baseline one.
#
# Scripts with a `--target` flag use TARGET_REPO as its default, so the
# precedence stays: flag > environment > baseline.
#
# Known and left alone: a guard that checks only the baseline does not protect a
# second target someone points TARGET_REPO at. Widening the three guards would
# change what they refuse, and no test in the shell tree would catch a mistake there.
TARGET_REPO_BASELINE=/Users/haruka/dev/lean-projects
TARGET_REPO="${TARGET_REPO:-$TARGET_REPO_BASELINE}"

LITEDOC4_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
