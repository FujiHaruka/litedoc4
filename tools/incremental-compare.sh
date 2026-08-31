#!/usr/bin/env bash
# Compare two trees written by tools/incremental-reference.sh and say what
# differs.
#
# usage: tools/incremental-compare.sh REFERENCE_DIR CANDIDATE_DIR
#
#   tools/build-lean-exe.sh --toolchain-from e2e/micro
#   tools/incremental-reference.sh --extractor product  --out .../m3d3/product
#   tools/incremental-reference.sh --extractor resident --out .../m3d3/resident
#   tools/incremental-compare.sh /private/tmp/lean-doc-relay/m3d3/product \
#                                /private/tmp/lean-doc-relay/m3d3/resident
#
# Not compared — dropping one of these would change the denominator, not just
# the verdict:
#
#   *-stderr.txt    Wording belongs to the implementation. *-complained.txt,
#                   derived from it, *is* compared: whether the run complained
#                   is a fact about the answer.
#   *-stdout.txt    Progress lines as well as the timings JSON, and only the
#                   timings record is an answer — distilled into *-counts.json.
#   *-sitecheck.txt A *within-run* oracle, read by hand.
#   conditions.txt  The clock, the host and the extractor's own name.
#
# **Everything else is compared byte for byte first, including every `.json`** —
# the difference from tools/impact-compare.sh. The order of an array inside
# `index.json` is itself an answer, and a comparator that parses JSON before
# comparing cannot see an ordering difference at all. Only a file whose bytes
# differ is classified further:
#
#   REORDERED        both parse as JSON and are equal as values — the same
#                    mapping written with the keys in another order.
#   (masked)         equal once every `*Seconds` key is dropped (at any depth)
#                    and each side's own output root is masked out of the
#                    strings. Counted as identical, reported separately so the
#                    number is never mistaken for a byte match.
#   ARRAY-REORDERED  the same elements in another sequence, in a JSON array or
#                    in a line-oriented file. **It still fails the run**: whether
#                    a difference was intended is a judgement for a person, and a
#                    comparator that made it would be an exception list with
#                    extra steps.
#   DIFFERS          everything else.
#
# **There is no exception list**: no rule above names a file. The classes are
# decided by suffix and by the shape of the content, so a difference somewhere
# nobody predicted is reported rather than absorbed.

set -uo pipefail

REF="${1-}"
CAND="${2-}"

[ -n "$REF" ] && [ -n "$CAND" ] || { echo "usage: $0 REFERENCE_DIR CANDIDATE_DIR" >&2; exit 2; }
[ -d "$REF" ] || { echo "no such directory: $REF" >&2; exit 1; }
[ -d "$CAND" ] || { echo "no such directory: $CAND" >&2; exit 1; }

identical=0
masked=0
reordered=0
arrayreordered=0
differing=0
missing=0
skipped=0
status=0

# The two roots are the only strings that differ between the sides by
# construction: a run's own output directory reaches `prune.json`'s `pages`
# field. `$REF` is a prefix of `$REF.work`, so masking it masks both.
classify () { # classify <ref> <cand> <ref root> <cand root>
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys

def load(path):
    with open(path, encoding='utf-8') as f:
        return json.loads(f.read())

def mask(value, root):
    """Drop every duration and neutralise the run's own output root, at any depth."""
    if isinstance(value, dict):
        return {k: mask(v, root) for k, v in value.items() if not k.endswith('Seconds')}
    if isinstance(value, list):
        return [mask(v, root) for v in value]
    if isinstance(value, str):
        return value.replace(root, '<OUT>')
    return value

def sorted_arrays(value):
    if isinstance(value, dict):
        return {k: sorted_arrays(v) for k, v in value.items()}
    if isinstance(value, list):
        return sorted((sorted_arrays(v) for v in value),
                      key=lambda item: json.dumps(item, sort_keys=True))
    return value

def text(path, root):
    with open(path, encoding='utf-8', errors='replace') as f:
        return f.read().replace(root, '<OUT>')

try:
    a, b = load(sys.argv[1]), load(sys.argv[2])
except Exception:
    # A file of one name per line **is** an array written with newlines, so it
    # gets the same ladder. The trailing newline is compared rather than
    # normalised away: an empty set is an empty file, not one blank line.
    ta, tb = text(sys.argv[1], sys.argv[3]), text(sys.argv[2], sys.argv[4])
    if ta == tb:
        print('masked')
    elif (sorted(ta.splitlines()) == sorted(tb.splitlines())
          and ta.endswith('\n') == tb.endswith('\n')):
        print('array-reordered')
    else:
        print('differs')
    sys.exit(0)
if a == b:
    print('reordered')
    sys.exit(0)
ma, mb = mask(a, sys.argv[3]), mask(b, sys.argv[4])
if ma == mb:
    print('masked')
    sys.exit(0)
if sorted_arrays(ma) == sorted_arrays(mb):
    print('array-reordered')
    sys.exit(0)
print('differs')
PY
}

for path in $( (cd "$REF" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) ); do
  case "$path" in
    *-stderr.txt|*-stdout.txt|*-sitecheck.txt|conditions.txt)
      skipped=$((skipped + 1)); continue ;;
  esac
  if [ ! -f "$CAND/$path" ]; then
    printf '%-58s MISSING in candidate\n' "$path"
    missing=$((missing + 1)); status=1; continue
  fi
  if cmp -s "$REF/$path" "$CAND/$path"; then
    identical=$((identical + 1))
    continue
  fi
  a=$(wc -c < "$REF/$path" | tr -d ' ')
  b=$(wc -c < "$CAND/$path" | tr -d ' ')
  verdict=$(classify "$REF/$path" "$CAND/$path" "$REF" "$CAND")
  case "$verdict" in
    masked)
      identical=$((identical + 1)); masked=$((masked + 1)) ;;
    reordered)
      printf '%-58s REORDERED        same mapping, reference %s B, candidate %s B\n' \
        "$path" "$a" "$b"
      reordered=$((reordered + 1)); status=1 ;;
    array-reordered)
      printf '%-58s ARRAY-REORDERED  same elements in another sequence, reference %s B, candidate %s B\n' \
        "$path" "$a" "$b"
      arrayreordered=$((arrayreordered + 1)); status=1 ;;
    *)
      printf '%-58s DIFFERS          reference %s B, candidate %s B\n' "$path" "$a" "$b"
      printf '    %s\n' "$(cmp "$REF/$path" "$CAND/$path" 2>&1 | head -1)"
      # /usr/bin/diff: `diff` is aliased to colordiff in this shell and colordiff
      # is not installed.
      /usr/bin/diff "$REF/$path" "$CAND/$path" 2>/dev/null | head -8 | sed 's/^/    /'
      differing=$((differing + 1)); status=1 ;;
  esac
done

# The same four suffixes are dropped here: a file the comparator refuses to read
# on the reference side is not "extra" on the candidate side either.
listing () { # listing <root>
  ( cd "$1" && find . -type f | sed 's|^\./||' \
    | grep -v -e '\-stderr\.txt$' -e '\-stdout\.txt$' -e '\-sitecheck\.txt$' -e '^conditions\.txt$' \
    | LC_ALL=C sort )
}
extra=$( listing "$CAND" | grep -vxF -f <( listing "$REF" ) || true )
if [ -n "$extra" ]; then
  echo
  echo "--- files the candidate wrote that the reference did not"
  printf '%s\n' "$extra"
  status=1
fi

echo
printf 'files compared:  %s\n' "$((identical + reordered + arrayreordered + differing + missing))"
printf '  identical:     %s  (of which %s only after masking the clock and the output root)\n' \
  "$identical" "$masked"
printf '  reordered:     %s  (same JSON mapping, different key order)\n' "$reordered"
printf '  array-reord.:  %s  (same elements, different sequence)\n' "$arrayreordered"
printf '  differing:     %s\n' "$differing"
printf '  missing:       %s\n' "$missing"
printf '  not compared:  %s  (*-stderr.txt, *-stdout.txt, *-sitecheck.txt, conditions.txt)\n' "$skipped"
if [ "$status" -eq 0 ]; then echo "IDENTICAL"; else echo "DIFFERENT"; fi
exit "$status"
