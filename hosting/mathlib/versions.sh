#!/usr/bin/env bash
# usage: hosting/mathlib/versions.sh
# Prints Mathlib's version set, comma-separated, in version order (the last is
# the newest, as `build --versions` takes it): every release on
# github.com/leanprover-community/mathlib4/releases that is neither a draft nor
# a prerelease. Needs `gh`, authenticated.
set -euo pipefail

tags="$(gh api --paginate 'repos/leanprover-community/mathlib4/releases?per_page=100' \
  --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
  | sort -V)"
if [ -z "$tags" ]; then
  echo "versions.sh: the GitHub API listed no release of mathlib4" >&2
  exit 1
fi
printf '%s\n' "$tags" | paste -sd, -
