#!/usr/bin/env bash
# Are the Markdown oracles still in the tree, and is the module the invariants
# read still what they say?
#
# `fixtures/md/md4lean-expected.json` and `fixtures/md/docgen4-expected.json` are
# the only answers in this repository that were minted by something other than
# this repository. Lean has no `include_str!`, so `tools/gen-md-oracle-cases.py`
# writes them into `test/Litedoc4Test/MdOracleCases.lean` and the invariants in
# `test/Litedoc4Test/MdOracle.lean` read that. A generated copy is a second
# answer to "what does MD4Lean say" for as long as nobody checks it: edit a
# fixture, forget to regenerate, and the suite stays green having asked the old
# question.
#
# The invariants themselves are not here. They need the linked C and are run by
# `tools/lean-test-gate.sh`; this gate reads files and nothing else, so it can
# sit in the job that has no toolchain.
#
# What carrying 860 cases as literals costs, and what asking them found
# (measured 2026-09-02): `benchmarks/results/md-oracle-invariants-2026-09-02.txt`.
#
# What a failing item means:
#   1 FIXTURES   a fixture is gone or holds no cases. The generator would then
#                write an empty corpus, and 0 of 0 cases agreeing is a pass.
#   2 GENERATED  `test/Litedoc4Test/MdOracleCases.lean` is not what
#                `fixtures/md/` generates. Run `tools/gen-md-oracle-cases.py`.
#   3 SIZES      the sizes `test/Litedoc4Test/MdOracle.lean` writes down are not
#                the fixtures' case counts. That file is hand-written on purpose
#                — a count generated beside the cases shrinks with them — so
#                when a fixture legitimately grows, this is the line that says
#                the number has to move with it.
#
# Reads the tree. No binary, no toolchain, no node, no target.
#
# usage: md-oracle-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

failed=0
pass() { printf 'ITEM %s ok    %s\n' "$1" "$2"; }
fail() { printf 'ITEM %s FAIL  %s\n' "$1" "$2" >&2; failed=$((failed + 1)); }

COUNTS="$(mktemp "${TMPDIR:-/tmp}/md-oracle-counts.XXXXXX")"
trap 'rm -f "$COUNTS"' EXIT

echo "=== 1/3 both oracle fixtures are there and hold cases"
# Redirected to a file rather than read through `$( … )` with a trailing
# `2>&1`: after a heredoc terminator that redirection is a *separate* command
# whose status is 0, so a failing item would print its reason and be counted as
# nothing at all (stepped on while writing this gate).
set +e
python3 tools/lib/md-oracle-counts.py >"$COUNTS" 2>&1
counts_rc=$?
set -e
DOCGEN4_CASES=""
MD4LEAN_CASES=""
if [ "$counts_rc" -ne 0 ]; then
  fail 1 "$(tr '\n' ' ' <"$COUNTS")"
else
  read -r DOCGEN4_CASES MD4LEAN_CASES <"$COUNTS"
  pass 1 "docgen4-expected.json $DOCGEN4_CASES cases, md4lean-expected.json $MD4LEAN_CASES cases"
fi

echo
echo "=== 2/3 test/Litedoc4Test/MdOracleCases.lean is what fixtures/md/ generates"
if check_out="$(tools/gen-md-oracle-cases.py --check 2>&1)"; then
  pass 2 "$check_out"
else
  fail 2 "$(printf '%s' "$check_out" | tr '\n' ' ')"
fi

echo
echo "=== 3/3 the sizes the invariants assert are the fixtures' case counts"
if [ -z "$DOCGEN4_CASES" ]; then
  fail 3 "item 1 could not read the fixtures, so there is nothing to compare against"
else
  # The invariant's name carries the numbers because `#guard` prints the name
  # and nothing else; that is also what makes them greppable from here.
  GUARD="$(grep -o 'theDocGen4CorpusIsStill[0-9]*CasesAndTheMd4LeanCorpusStill[0-9]*' \
    test/Litedoc4Test/MdOracle.lean | head -1 || true)"
  WANT="theDocGen4CorpusIsStill${DOCGEN4_CASES}CasesAndTheMd4LeanCorpusStill${MD4LEAN_CASES}"
  if [ -z "$GUARD" ]; then
    fail 3 "test/Litedoc4Test/MdOracle.lean no longer names a corpus-size invariant"
  elif [ "$GUARD" != "$WANT" ]; then
    fail 3 "the invariant is named $GUARD and the fixtures hold $DOCGEN4_CASES and $MD4LEAN_CASES cases; rename it $WANT"
  else
    pass 3 "$GUARD"
  fi
fi

echo
echo "=== summary"
echo "items reported : 3 of 3"
echo "failed         : $failed"
if [ "$failed" -ne 0 ]; then
  echo
  echo "MD ORACLE GATE: $failed item(s) failed" >&2
  exit 1
fi
echo
echo "MD ORACLE GATE: ok"
