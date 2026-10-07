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
#   modulesExtracted == 1        The one edited module, and nothing else. A zero is
#                                not a fast build, it is a build that did not
#                                happen; more than one is an ownership round that
#                                pulled in modules no name of which moved.
#   the version was re-put       versionsExtracted is 1 of 1 and names the
#                                marker's version: what was extracted reached the
#                                store the site is rendered from. The version is
#                                rendered whole on every run, so there is no page
#                                count to bound.
#   the map was reused           Not moving and not being *written* are different
#                                claims and the bytes cannot tell them apart: a
#                                map rewritten to the same content passes a byte
#                                comparison while still costing the walk that
#                                produced it. The extractor says which it did.
#
# **Nothing here is a duration**: this workload's environment load moves 5x with
# the page cache, so a second is not a threshold.
#
# It does **not** check whether the IR the edit left is right. A merge that went
# wrong is silent here, and the caller has to compare the tree against a build
# from nothing of the same sources (`e2e-micro.sh` does). A green here with no
# such comparison beside it is a count, not a verdict.
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
extracted = work["modulesExtracted"]
version = record.get("version")
stored = record.get("versionsExtracted") or {}
problems = []

if extracted != 1:
    problems.append(
        f"work.modulesExtracted is {extracted} — expected exactly the one edited module"
    )
if not version or stored != {"count": 1, "of": 1, "names": [version]}:
    problems.append(
        f"versionsExtracted is {stored} for version {version!r} — the extraction did not "
        "reach the store the site is rendered from"
    )

print(f"onemod-gate   modules {modules}  extracted {extracted}  version {version}  "
      f"versionsExtracted {stored.get('count')} of {stored.get('of')}")
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
