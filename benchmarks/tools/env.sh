#!/usr/bin/env bash
# Shared settings for every benchmark run. Source this, don't execute it.
#
# The measurement target is fixed on purpose: numbers are only comparable when
# they come from the same workload.
set -u

# Override TARGET_REPO only to ADD a target, never to replace the baseline one.
# shellcheck source=../../tools/lib/target.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../tools/lib/target.sh" || exit 1

# Committed, so keep them small.
RESULTS_DIR="${RESULTS_DIR:-$LITEDOC4_ROOT/benchmarks/results}"

DOCGEN_BIN="$TARGET_REPO/.lake/packages/doc-gen4/.lake/build/bin/doc-gen4"

[ -d "$TARGET_REPO" ] || { echo "target repo not found: $TARGET_REPO" >&2; exit 1; }
mkdir -p "$RESULTS_DIR"
