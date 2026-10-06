#!/usr/bin/env bash
# The S input of the multi-version measurement loop: the sample package as a git
# repository with one commit per version, whose differences are known in advance
# (tools/mv-s/expected.txt), so a runner asserts counts instead of predicting them.
#
# v1 is e2e/micro as it is; v<n> is v<n-1> with tools/mv-s/v<n>.patch applied.
# Author, committer and dates are fixed, so every run yields the same hashes.
#
# usage: tools/mv-s/generate.sh [--out DIR]
#   --out DIR   the repository to recreate (default: /private/tmp/lean-doc-relay/mv-s/repo).
#               The sample requires `../micro-dep` by path, so e2e/micro-dep is
#               copied to DIR/../micro-dep as well. The version table is printed
#               and written to DIR/../versions.txt. Each commit is also tagged v<n>.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="/private/tmp/lean-doc-relay/mv-s/repo"
VERSIONS=4
REMOTE="https://github.com/litedoc4-sample/mv-s.git"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
PARENT="$(dirname "$OUT")"

if [ -e "$OUT" ] && ! git -C "$OUT" rev-parse -q --verify refs/tags/v1 >/dev/null 2>&1; then
  echo "$OUT exists and is not a repository this script generated; refusing to delete it" >&2
  exit 2
fi
if [ -e "$PARENT/micro-dep" ] && [ ! -f "$PARENT/micro-dep/Dep-Aux.lean" ]; then
  echo "$PARENT/micro-dep exists and is not a copy of e2e/micro-dep; refusing to delete it" >&2
  exit 2
fi
for n in $(seq 2 "$VERSIONS"); do
  [ -f "$HERE/v$n.patch" ] || { echo "missing $HERE/v$n.patch" >&2; exit 2; }
done

rm -rf "$OUT" "$PARENT/micro-dep"
mkdir -p "$OUT" "$PARENT/micro-dep"
rsync -a --exclude .lake "$ROOT/e2e/micro/" "$OUT/"
rsync -a --exclude .lake "$ROOT/e2e/micro-dep/" "$PARENT/micro-dep/"

g () {
  git -C "$OUT" -c commit.gpgsign=false -c tag.gpgsign=false -c core.autocrlf=false "$@"
}

g init -q -b main
g remote add origin "$REMOTE"
printf '/.lake/\n' >> "$OUT/.git/info/exclude"
g add .

commit () {
  local n="$1" date
  date="2026-01-0${n}T12:00:00+0000"
  GIT_AUTHOR_NAME="mv-s" GIT_AUTHOR_EMAIL="mv-s@example.invalid" GIT_AUTHOR_DATE="$date" \
  GIT_COMMITTER_NAME="mv-s" GIT_COMMITTER_EMAIL="mv-s@example.invalid" GIT_COMMITTER_DATE="$date" \
    g commit -q --no-verify -m "v$n"
  g tag "v$n"
}

commit 1
for n in $(seq 2 "$VERSIONS"); do
  g apply --index "$HERE/v$n.patch"
  commit "$n"
done

if [ -n "$(g status --porcelain)" ]; then
  echo "the working tree is not clean after v$VERSIONS" >&2
  exit 1
fi

TABLE="$PARENT/versions.txt"
: > "$TABLE"
for n in $(seq 1 "$VERSIONS"); do
  printf 'v%s %s\n' "$n" "$(g rev-parse "v$n")" >> "$TABLE"
done
cat "$TABLE"
