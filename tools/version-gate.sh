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

# --- item 3: no published version is shipped twice
#
# **The question is about the tags, not about HEAD.** This item used to ask
# whether Version.lean named a tag that is not this commit, and fail if it did —
# which is the state main is in from the moment a release is tagged until the
# next one, because every `tracks` site is a *pin instruction* a user follows
# (`uses: FujiHaruka/litedoc4@v1.4.0`). Bumping the literal to clear it would
# make README tell people to pin a tag that does not exist. So the old item asked
# for the one thing that must not be done, and it turned main red on every
# ordinary commit after a release (measured 2026-09-02: CI on `9bc8c8f` failed
# for exactly this, and `3a62874` before it).
#
# What is always true, and catches the double-ship where it actually happens:
#
#   a  every published tag whose commit carries Version.lean names its own
#      version. Tagging v1.5.0 without moving the literal fails here on the next
#      run, naming both — which is "you shipped 1.4.0 twice" said at the moment
#      it becomes true.
#   b  HEAD's literal is not *below* the greatest published tag. Equal is the
#      normal state between releases; below is a downgrade.
#
# Tags older than the literal are counted rather than skipped in silence: the
# file arrived at v1.3.0, so ten of the twelve tags cannot answer (a) at all.
echo "=== 3/3 no published version is shipped twice"
tagged=0
untagged=0
unreadable=()
mismatched=()
for tag in $TAGS; do
  # A tag whose tree is not in this clone answers nothing, and the empty answer
  # below is indistinguishable from "this tag predates the file". Told apart
  # here, because otherwise a checkout that stopped fetching the trees would
  # report `0 of 12 … and each names its own version` and pass. Measured
  # 2026-09-02: `actions/checkout@v7` with `fetch-tags: true` and the default
  # depth does bring them, and the job answered `2 of 12` — so this refuses on a
  # state that is not the current one, which is the point of writing it down.
  if ! git cat-file -e "${tag}^{tree}" 2>/dev/null; then
    unreadable+=("$tag")
    continue
  fi
  # `|| true` because a tag older than the file makes `git show` exit 128, and
  # under `pipefail` that becomes the assignment's status, which `set -e` reads
  # as the script failing. The empty answer *is* the answer here.
  at_tag="$(git show "${tag}:src/Litedoc4/Version.lean" 2>/dev/null \
    | sed -n 's/^def version : String := "\(.*\)"$/\1/p' || true)"
  if [ -z "$at_tag" ]; then
    untagged=$((untagged + 1))
  else
    tagged=$((tagged + 1))
    [ "v$at_tag" = "$tag" ] || mismatched+=("$tag names $at_tag")
  fi
done
newest="$(printf '%s\n' $TAGS | head -1)"
behind=""
if [ "v$VERSION" != "$newest" ]; then
  # `sort -V` puts the greater last, so the literal is below the newest tag
  # exactly when the newest tag sorts after it.
  [ "$(printf '%s\nv%s\n' "$newest" "$VERSION" | sort -V | tail -1)" = "$newest" ] \
    && behind="v$VERSION is below the newest published tag $newest"
fi
if [ ${#mismatched[@]} -eq 0 ] && [ -z "$behind" ] && [ ${#unreadable[@]} -eq 0 ]; then
  pass 3 "$tagged of $((tagged + untagged)) tag(s) carry Version.lean and each names its own version; \
v$VERSION is $([ "v$VERSION" = "$newest" ] && echo "the newest tag" || echo "above $newest")"
else
  if [ ${#unreadable[@]} -ne 0 ]; then
    fail 3 "${#unreadable[@]} tag(s) have no tree in this clone, so this item could not be asked of them"
    printf '  %s\n' "${unreadable[@]}" >&2
  else
    fail 3 "a published version would be shipped twice"
  fi
  [ ${#mismatched[@]} -eq 0 ] || printf '  %s\n' "${mismatched[@]}" >&2
  [ -z "$behind" ] || printf '  %s\n' "$behind" >&2
fi

echo
echo "=== summary"
echo "items reported : 3 of 3"
echo "failed         : $failed"
if [ "$failed" -ne 0 ]; then echo "VERSION GATE: FAILED" >&2; exit 1; fi
echo "VERSION GATE: ok — $VERSION"
