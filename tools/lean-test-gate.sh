#!/usr/bin/env bash
# Do the Lean half's invariants hold?
#
# This is the definition of green. There are two halves and one target, because a
# `#guard` is checked by *elaborating* the module and an `Invariant` is checked
# by *running* the executable:
#
#   compile time   `#guard <name>` in test/**. A broken one fails the build, so
#                  the build succeeding is the whole check. They cost a consumer
#                  nothing and cannot be skipped
#   run time       `Invariant`s, gathered in test/Litedoc4Test/Main.lean. These
#                  are the ones a `#guard` cannot answer: it evaluates in the
#                  interpreter, which has no `Md.events` — that symbol is
#                  `@[extern]` C linked only into the executable — and it cannot
#                  print the value that differed
#
# What a failing item means:
#   1 BUILD     `lean_exe litedoc4-test` did not build. If the error names a
#               `#guard`, that is a compile-time invariant failing, and the
#               message names it.
#   2 DEFINED   an `Invariant` is defined in test/ and the runner never ran it.
#               Writing one and forgetting to add it to `Main.lean`'s list is
#               silent otherwise: the suite stays green having asked less.
#   3 RAN       the executable reported a failure. Its own line names which.
#   4 GUARDS    test/ holds no `#guard` at all. Half the suite would then be
#               absent while the other half still reported a number.
#
# usage: lean-test-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

failed=0
pass() { printf 'ITEM %s ok    %s\n' "$1" "$2"; }
fail() { printf 'ITEM %s FAIL  %s\n' "$1" "$2" >&2; failed=$((failed + 1)); }

echo "=== 1/4 the test executable builds (and every #guard in it elaborates)"
# Not a second copy of the host-workspace logic: `build-lean-exe.sh` is the one
# place that knows how to run Lake beside a lakefile with no lean-toolchain.
BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/lean-test-build.XXXXXX")"
if EXE="$("$HERE/build-lean-exe.sh" --toolchain-from e2e/micro --exe litedoc4-test 2>"$BUILD_LOG")"; then
  pass 1 "$EXE"
else
  fail 1 "the build failed; a #guard that did not hold is named here:"
  sed -n '1,40p' "$BUILD_LOG" >&2
  rm -f "$BUILD_LOG"
  echo
  echo "LEAN TEST GATE: FAILED" >&2
  exit 1
fi
rm -f "$BUILD_LOG"

echo "=== 2/4 every Invariant defined is one the runner runs"
# The inventory is the definitions themselves rather than a list file: a list
# beside the code is a second thing to forget. Counted from `test/`, reconciled
# against what the binary says it ran.
# `|| true` because grep exits 1 when nothing matched and `pipefail` is on, which
# would abort here instead of letting item 2 report the zero.
DEFINED="$(grep -rEc ': Invariant (where|:=)' "$ROOT/test" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}' || true)"
OUT="$(mktemp "${TMPDIR:-/tmp}/lean-test-run.XXXXXX")"
# No pipe: the exit code has to be the executable's.
set +e
"$EXE" >"$OUT" 2>"$OUT.err"
run_rc=$?
set -e
RAN="$(sed -n 's/^litedoc4-test: \([0-9][0-9]*\) invariants ran.*/\1/p' "$OUT")"
[ -n "$RAN" ] || RAN=0
if [ "$DEFINED" -eq 0 ]; then
  fail 2 "test/ defines no Invariant at all"
elif [ "$RAN" != "$DEFINED" ]; then
  fail 2 "test/ defines $DEFINED Invariant(s), the runner ran $RAN — one is defined and never listed in Main.lean"
else
  pass 2 "$DEFINED defined, $RAN ran"
fi

echo "=== 3/4 the invariants hold"
if [ "$run_rc" -eq 0 ]; then
  pass 3 "$(cat "$OUT")"
else
  fail 3 "the executable exited $run_rc:"
  cat "$OUT.err" >&2
fi

echo "=== 4/4 the compile-time half is not empty"
GUARDS="$(grep -rc '^#guard ' "$ROOT/test" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}' || true)"
if [ "$GUARDS" -eq 0 ]; then
  fail 4 "test/ holds no #guard — the compile-time half is absent and item 1 would still pass"
else
  pass 4 "$GUARDS #guard(s) elaborated by item 1"
fi

rm -f "$OUT" "$OUT.err"

echo
echo "=== summary"
echo "items reported : 4 of 4"
echo "failed         : $failed"
if [ "$failed" -ne 0 ]; then
  echo
  echo "LEAN TEST GATE: FAILED" >&2
  exit 1
fi
echo
echo "LEAN TEST GATE: ok — $GUARDS compile-time, $DEFINED run-time"
