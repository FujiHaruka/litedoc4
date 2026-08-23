#!/usr/bin/env bash
# Shared settings for every benchmark run. Source this, don't execute it.
#
# The measurement target is fixed on purpose: numbers are only comparable when
# they come from the same workload. See CLAUDE.md "ベンチマーク".
set -u

# The Lean project being documented (TARGET_REPO, overridable only to add a
# target), the baseline it defaults to (TARGET_REPO_BASELINE, which nothing can
# override) and this repository's root (LITEDOC4_ROOT). One file decides where
# the measurement target is; everything below is this file's own side effects.
# shellcheck source=../../tools/lib/target.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../tools/lib/target.sh" || exit 1

# Where raw timing logs land. Committed, so keep them small.
RESULTS_DIR="${RESULTS_DIR:-$LITEDOC4_ROOT/benchmarks/results}"

# The instrumented doc-gen4 binary inside the target repo.
DOCGEN_BIN="$TARGET_REPO/.lake/packages/doc-gen4/.lake/build/bin/doc-gen4"

[ -d "$TARGET_REPO" ] || { echo "target repo not found: $TARGET_REPO" >&2; exit 1; }
mkdir -p "$RESULTS_DIR"
