#!/usr/bin/env bash
# Compare two trees of whole-package artifacts byte for byte and say what differs.
#
# A `global --out` tree is a handful of files, not 432, so every one is printed
# with its size: a path and a byte offset are useful where a percentage is not.
#
# usage: tools/global-compare.sh REFERENCE_DIR CANDIDATE_DIR
#
# Both trees are arguments and neither's provenance is checked, so point
# REFERENCE_DIR at whatever tree you want to hold the candidate to — and say which
# one it was.
#
#   ./target/release/litedoc4 global --ir <ir> --out /tmp/rust-global
#   .lake/build/bin/litedoc4  global --ir <ir> --out /tmp/lean-global
#   tools/global-compare.sh /tmp/rust-global /tmp/lean-global
#
# `cargo test -p litedoc4-global --test global` makes the same comparison in
# process against a committed fixture.
#
# **The union of both trees, never a list of names.** Until 2026-08-31 this
# script carried its own list of six artifacts, five of which were doc-gen4's
# (`declaration-data.bmp`, `navbar.html`, `tactics.html`, `references.bib`,
# `references.html`) and none of which litedoc4 writes — so it reported two
# **byte-identical** trees as DIFFERENT, and every real artifact as a file it did
# not recognise. It was the third copy of that list; the other two were collected
# into `tools/site-artefacts.txt` on 2026-08-29 and this one was missed. Reading
# that inventory instead would only move the rot: `global` writes a subset of it
# (the three assets are `build`'s), so its other entries would be absent on both
# sides and that half of the comparison would agree with itself.
set -uo pipefail

REF="${1-}"
CAND="${2-}"

[ -n "$REF" ] && [ -n "$CAND" ] || { echo "usage: $0 REFERENCE_DIR CANDIDATE_DIR" >&2; exit 2; }
[ -d "$REF" ] || { echo "no such directory: $REF" >&2; exit 1; }
[ -d "$CAND" ] || { echo "no such directory: $CAND" >&2; exit 1; }

listing () { (cd "$1" && find . -type f | sed 's|^\./||' | sort); }

status=0
compared=0
files=$( { listing "$REF"; listing "$CAND"; } | sort -u )

# An empty union is not agreement: two empty trees mean the runs that were
# supposed to write them wrote nothing.
if [ -z "$files" ]; then
  echo "neither tree holds a file — there is nothing to compare" >&2
  exit 1
fi

for f in $files; do
  compared=$((compared + 1))
  if [ ! -f "$REF/$f" ]; then
    printf '%-36s MISSING in reference   %s B in candidate\n' "$f" \
      "$(wc -c < "$CAND/$f" | tr -d ' ')"; status=1; continue
  fi
  if [ ! -f "$CAND/$f" ]; then
    printf '%-36s MISSING in candidate   %s B in reference\n' "$f" \
      "$(wc -c < "$REF/$f" | tr -d ' ')"; status=1; continue
  fi
  a=$(wc -c < "$REF/$f" | tr -d ' ')
  b=$(wc -c < "$CAND/$f" | tr -d ' ')
  if cmp -s "$REF/$f" "$CAND/$f"; then
    printf '%-36s identical  %s B\n' "$f" "$a"
  else
    printf '%-36s DIFFERS    reference %s B, candidate %s B\n' "$f" "$a" "$b"
    printf '    %s\n' "$(cmp "$REF/$f" "$CAND/$f" 2>&1 | head -1)"
    status=1
  fi
done

echo
printf 'files compared: %s\n' "$compared"
if [ "$status" -eq 0 ]; then echo "IDENTICAL"; else echo "DIFFERENT"; fi
exit "$status"
