#!/usr/bin/env bash
# Does every place that names litedoc4's version still name the right one?
#
# `src/Litedoc4/Version.lean` decides the version. Until `Cargo.toml` left the
# tree, `tools/purelean-gate.sh` reconciled the two literals; after it left,
# nothing read either. A release then moves one literal and leaves six copies
# saying the release before it, and the only reader who notices is a user
# filing a bug against a version they are not running.
#
# What a failing item means:
#   1 SITES     a site the inventory names is gone, or an occurrence of one of
#               this repository's tag names is not in the inventory at all
#   2 TRACKS    a `tracks` site does not carry Version.lean's literal. The
#               message names the file and both versions
#   3 TAG       Version.lean's literal is a tag that already exists and is not
#               this commit — the version would be shipped twice
#
# The scope is `tools/version-sites.txt`'s file column, plus a sweep of the whole
# tree for the *current* version, which is what a new site would carry.
#
# usage: version-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

INVENTORY="tools/version-sites.txt"
failed=0
pass() { printf 'ITEM %s ok    %s\n' "$1" "$2"; }
fail() { printf 'ITEM %s FAIL  %s\n' "$1" "$2" >&2; failed=$((failed + 1)); }

VERSION="$(sed -n 's/^def version : String := "\(.*\)"$/\1/p' src/Litedoc4/Version.lean)"
if [ -z "$VERSION" ]; then
  echo 'src/Litedoc4/Version.lean has no `def version` literal to read' >&2
  echo "VERSION GATE: FAILED" >&2
  exit 1
fi
echo "Litedoc4.version = $VERSION"

# Every tag this repository has ever published, longest first so that a line
# holding v1.0.1 is not matched by a v1.0 prefix.
# On stdout as well as stderr: this is a refusal before any item runs, and a log
# that shows only the exit code is the shape where the output and the exit code
# disagree. A checkout with no tags is the way it happens (`actions/checkout`
# fetches none by default).
TAGS="$(git tag | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV || true)"
if [ -z "$TAGS" ]; then
  msg="no v* tags here, so nothing can be reconciled against them — fetch tags (actions/checkout wants fetch-tags: true)"
  echo "$msg"; echo "$msg" >&2
  echo "VERSION GATE: FAILED" >&2
  exit 1
fi

# --- item 1: the inventory and the tree agree about where the versions are
echo "=== 1/3 every site the inventory names is there, and nothing else names a tag"
missing=()
declare -a FILES=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  file="$(awk '{print $1}' <<<"$line")"
  kind="$(awk '{print $2}' <<<"$line")"
  anchor="$(sed -E 's/^[^ ]+ +[^ ]+ +//' <<<"$line")"
  FILES+=("$file")
  if [ ! -f "$file" ]; then missing+=("$file (the file itself is gone)"); continue; fi
  if ! grep -qF -- "$anchor" "$file"; then
    missing+=("$file: no line holds \"$anchor\" ($kind)")
  fi
done < "$INVENTORY"

# Anything naming one of our tags that no row claims.
unclaimed=()
for file in $(printf '%s\n' "${FILES[@]}" | sort -u); do
  [ -f "$file" ] || continue
  while IFS= read -r hit; do
    n="${hit%%:*}"; body="${hit#*:}"
    claimed=no
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue;; esac
      [ "$(awk '{print $1}' <<<"$line")" = "$file" ] || continue
      anchor="$(sed -E 's/^[^ ]+ +[^ ]+ +//' <<<"$line")"
      case "$body" in *"$anchor"*) claimed=yes; break;; esac
    done < "$INVENTORY"
    [ "$claimed" = yes ] || unclaimed+=("$file:$n: $body")
  done < <(grep -nE "($(paste -sd'|' - <<<"$TAGS"))([^0-9]|\$)" "$file" || true)
done

# The inventory can only police the files it lists, so the current version is
# swept for across everything tracked: that is the spelling a *new* site would
# carry, and a new site is the failure this file exists to make impossible.
# `benchmarks/results/**` is never rewritten and `docs/`/`.claude/` are history,
# so a version in them is a record of a past state rather than a copy to keep.
outside=()
while IFS= read -r hit; do
  f="${hit%%:*}"
  # A lockfile records *other* packages' versions, and one of them equalling
  # ours is a coincidence rather than a site (`once@1.4.0`, `expect-type@1.4.0`).
  # litedoc4 is not published to npm or to a deno registry, so it can never be
  # the subject of a line in one -- that is the premise, and it is what would
  # have to break for these to be worth reading.
  case "$f" in
    benchmarks/results/*|docs/*|.claude/*|"$INVENTORY"|tools/version-gate.sh) continue;;
    *.lock|*package-lock.json) continue;;
  esac
  printf '%s\n' "${FILES[@]}" | grep -qxF "$f" && continue
  outside+=("$hit")
done < <(git grep -nF -- "$VERSION" -- . || true)

if [ ${#missing[@]} -eq 0 ] && [ ${#unclaimed[@]} -eq 0 ] && [ ${#outside[@]} -eq 0 ]; then
  pass 1 "$(grep -cvE '^#|^$' "$INVENTORY") site(s) inventoried, all present, none unclaimed, and no file outside them names $VERSION"
else
  fail 1 "the inventory and the tree disagree"
  [ ${#missing[@]} -eq 0 ] || printf '  gone:      %s\n' "${missing[@]}" >&2
  [ ${#unclaimed[@]} -eq 0 ] || printf '  unclaimed: %s\n' "${unclaimed[@]}" >&2
  [ ${#outside[@]} -eq 0 ] || printf '  outside the inventory: %s\n' "${outside[@]}" >&2
fi

# --- item 2: every `tracks` site carries the current version
echo "=== 2/3 every tracks site carries $VERSION"
stale=()
tracks=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  [ "$(awk '{print $2}' <<<"$line")" = tracks ] || continue
  file="$(awk '{print $1}' <<<"$line")"
  anchor="$(sed -E 's/^[^ ]+ +[^ ]+ +//' <<<"$line")"
  [ -f "$file" ] || continue
  tracks=$((tracks + 1))
  while IFS= read -r body; do
    # `|| true` twice over: grep exits 1 on a line with no tag on it, and with
    # `pipefail` on that would end the gate here rather than in its summary --
    # the shape where the exit code and the output disagree, which this
    # repository keeps being bitten by.
    got="$( { grep -oE "($(paste -sd'|' - <<<"$TAGS"))([^0-9]|\$)" <<<"$body" || true; } | head -1 | sed -E 's/[^0-9]$//' || true)"
    [ -n "$got" ] || continue
    if [ "$got" != "v$VERSION" ]; then
      stale+=("$file: \"$anchor\" says $got, Version.lean says $VERSION")
    fi
  done < <(grep -F -- "$anchor" "$file")
done < "$INVENTORY"

# The two sites that write the version with no leading `v`, so the tag-shaped
# walk above cannot see them: the issue template's placeholder and the literal
# itself. Checked as a plain prefix.
bare_site() {
  local file="$1" anchor="$2"
  [ -f "$file" ] || return 0
  grep -qF -- "${anchor}${VERSION}" "$file" ||
    stale+=("$file: the line starting \"${anchor}\" does not say $VERSION")
}
bare_site ".github/ISSUE_TEMPLATE/bug.yml" 'placeholder: "litedoc4 '
bare_site "src/Litedoc4/Version.lean" 'def version : String := "'

if [ ${#stale[@]} -eq 0 ]; then
  pass 2 "$tracks tracks site(s) all say v$VERSION"
else
  fail 2 "a release moved Version.lean and left these behind"
  [ ${#stale[@]} -eq 0 ] || printf '  %s\n' "${stale[@]}" >&2
fi

# --- item 3: the version is not one already published
echo "=== 3/3 v$VERSION is unpublished, or is this very commit"
if ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  pass 3 "v$VERSION is not tagged yet"
elif [ "$(git rev-parse "v$VERSION^{commit}")" = "$(git rev-parse HEAD)" ]; then
  pass 3 "v$VERSION is this commit"
else
  fail 3 "v$VERSION already points at $(git rev-parse --short "v$VERSION^{commit}") — bump Version.lean or you ship it twice"
fi

echo
echo "=== summary"
echo "items reported : 3 of 3"
echo "failed         : $failed"
if [ "$failed" -ne 0 ]; then echo "VERSION GATE: FAILED" >&2; exit 1; fi
echo "VERSION GATE: ok — $VERSION"
