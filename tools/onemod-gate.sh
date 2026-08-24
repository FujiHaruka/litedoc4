#!/usr/bin/env bash
# What a one-module edit is allowed to cost, as integers.
#
# usage: tools/onemod-gate.sh <litedoc4-build.json> <serve.out>
#
# One claim, one file: `tools/e2e-micro.sh`'s GATE 6 and
# `.github/workflows/ci-template.yml` ask it in two places, and a second spelling
# of a gate is how two callers stop agreeing about what passing means — the one
# that is easier to run gets loosened.
#
# What it checks:
#
#   modulesExtracted >= 1        The edit was noticed at all. A zero is not a fast
#                                build, it is a build that did not happen, and
#                                every other number would then be trivially green.
#   1 <= pagesRendered < modules The upper bound catches a dependency map that
#                                moves on every edit: its digest is a `renderKey`
#                                input, so one added declaration re-renders the
#                                whole package. An inequality, not a number: how
#                                many pages a *referrer* pulls in is allowed to grow.
#   the map was reused           Not moving and not being *written* are different
#                                claims and the bytes cannot tell them apart: a
#                                map rewritten to the same content passes a byte
#                                comparison while still costing the walk that
#                                produced it. The extractor says which it did.
#
# **Nothing here is a duration**: this workload's environment load moves 5x with
# the page cache, so a second is not a threshold.
#
# It does **not** check whether the pages that were rendered are right.
# Under-rendering is silent here, and the caller has to compare the tree against
# a whole render of the same IR (`e2e-micro.sh` does). A green here with no such
# comparison beside it is a count, not a verdict.
set -uo pipefail

BUILD_JSON="${1-}"
SERVE_OUT="${2-}"

[ -n "$BUILD_JSON" ] && [ -n "$SERVE_OUT" ] || {
  echo "usage: $0 <litedoc4-build.json> <serve.out>" >&2
  exit 2
}
[ -f "$BUILD_JSON" ] || { echo "onemod-gate: no such file: $BUILD_JSON" >&2; exit 1; }
[ -f "$SERVE_OUT" ] || { echo "onemod-gate: no such file: $SERVE_OUT" >&2; exit 1; }

status=0

python3 - "$BUILD_JSON" <<'PY' || status=1
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
modules = record["modules"]
work = record["work"]
rendered = work["pagesRendered"]
extracted = work["modulesExtracted"]
problems = []

if extracted < 1:
    problems.append(
        f"work.modulesExtracted is {extracted} — the edited module was not re-extracted, "
        "so nothing below means anything"
    )
if not 1 <= rendered < modules:
    problems.append(
        f"work.pagesRendered is {rendered} for {modules} module(s) — expected at least one "
        "and fewer than all"
    )

print(f"onemod-gate   modules {modules}  extracted {extracted}  rendered {rendered}  "
      f"irReads.module {work['irReads']['module']}")
for problem in problems:
    print(f"onemod-gate FAIL  {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY

# `grep -E` rather than a JSON field: this log is what a person reads when the
# gate goes red, and the line it matches is the line they will be looking at.
if grep -qE '^linkIndex .* reused ' "$SERVE_OUT"; then
  echo "onemod-gate   the dependency map was reused, not rewritten"
else
  echo "onemod-gate FAIL  the extractor rewrote the dependency map instead of reusing it" >&2
  grep -E '^linkIndex ' "$SERVE_OUT" >&2 || echo "  (no linkIndex line in $SERVE_OUT)" >&2
  status=1
fi

exit "$status"
