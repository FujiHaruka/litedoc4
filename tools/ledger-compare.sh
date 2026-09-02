#!/usr/bin/env bash
# Compare two trees written by tools/ledger-reference.sh and say what differs.
#
# usage: tools/ledger-compare.sh REFERENCE_DIR CANDIDATE_DIR
#
#   tools/build-lean-exe.sh --toolchain-from e2e/micro
#   tools/ledger-reference.sh --out /private/tmp/lean-doc-relay/m3/before
#   ...change something...
#   tools/ledger-reference.sh --out /private/tmp/lean-doc-relay/m3/after
#   tools/ledger-compare.sh /private/tmp/lean-doc-relay/m3/before \
#                           /private/tmp/lean-doc-relay/m3/after
#
# This is the only thing that makes this comparison, and it always was: the Rust
# suite replayed the twelve scenarios on a fake repository instead, which needed
# no target. That half left with `crates/` and has no successor.
#
# Three classes of file, compared three ways:
#
#   ledger-*.json   byte for byte, after substituting the two key strings a
#                   ledger written by another implementation holds. The
#                   substitution is anchored on the key name because
#                   `extractKey.irGenerator` holds the same string and must
#                   **not** move: it names whatever wrote the IR on disk. **A
#                   no-op between two recordings of the same implementation**,
#                   kept so an older tree stays readable — and the two literals
#                   below are values inside such a ledger, not paths this script
#                   opens.
#   *timings*.json  keys and counts, ignoring every `*Seconds`: durations are
#                   wall clock and differ between runs by construction.
#   *.txt           byte for byte. These are the answers the pipeline consumes.
#
# `*-stdout.txt` is skipped: log wording belongs to the implementation, and every
# number in it is also in the timings record, which is compared.

set -uo pipefail

REF="${1-}"
CAND="${2-}"

[ -n "$REF" ] && [ -n "$CAND" ] || { echo "usage: $0 REFERENCE_DIR CANDIDATE_DIR" >&2; exit 2; }
[ -d "$REF" ] || { echo "no such directory: $REF" >&2; exit 1; }
[ -d "$CAND" ] || { echo "no such directory: $CAND" >&2; exit 1; }

# Read out of the source, so this script cannot drift from it.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER_LEAN="$REPO/src/Litedoc4/Ledger.lean"
NEW_EXTRACTOR=$(sed -n 's/^def extractorId : String := "\(.*\)"$/\1/p' "$LEDGER_LEAN")
NEW_RENDERER=$(sed -n 's/^def rendererId : String := "\(.*\)"$/\1/p' "$LEDGER_LEAN")
[ -n "$NEW_EXTRACTOR" ] && [ -n "$NEW_RENDERER" ] || {
  echo "could not read extractorId / rendererId from $LEDGER_LEAN" >&2; exit 1;
}

status=0

substituted_ledger () { # substituted_ledger <reference file> -> stdout
  python3 - "$1" "$NEW_EXTRACTOR" "$NEW_RENDERER" <<'PY'
import sys
raw = open(sys.argv[1], 'rb').read()
for key, new in (b'extractor', sys.argv[2]), (b'renderer', sys.argv[3]):
    for old in (b'lean-doc/experiments/stage4b', b'lean-doc/experiments/stage4c'):
        raw = raw.replace(b'"' + key + b'":"' + old + b'"',
                          b'"' + key + b'":"' + new.encode() + b'"')
sys.stdout.buffer.write(raw)
PY
}

compare_timings () { # compare_timings <ref> <cand> -> prints differences
  python3 - "$1" "$2" <<'PY'
import json, sys
def load(path):
    with open(path) as f:
        record = json.loads(f.read().strip())
    return {k: v for k, v in record.items() if not k.endswith('Seconds')}
a, b = load(sys.argv[1]), load(sys.argv[2])
for key in sorted(set(a) | set(b)):
    if a.get(key, '<absent>') != b.get(key, '<absent>'):
        print(f"    {key}: reference {a.get(key, '<absent>')!r}, candidate {b.get(key, '<absent>')!r}")
PY
}

for path in $( (cd "$REF" && find . -type f | sed 's|^\./||' | sort) ); do
  case "$path" in *-stdout.txt) continue ;; esac
  if [ ! -f "$CAND/$path" ]; then
    printf '%-34s MISSING in candidate\n' "$path"; status=1; continue
  fi
  a=$(wc -c < "$REF/$path" | tr -d ' ')
  b=$(wc -c < "$CAND/$path" | tr -d ' ')
  case "$path" in
    *timings*.json)
      out=$(compare_timings "$REF/$path" "$CAND/$path")
      if [ -z "$out" ]; then
        printf '%-34s same counts (durations ignored)\n' "$path"
      else
        printf '%-34s DIFFERS\n%s\n' "$path" "$out"; status=1
      fi
      ;;
    ledger-*.json)
      if substituted_ledger "$REF/$path" | cmp -s - "$CAND/$path"; then
        printf '%-34s identical  %s B (reference %s B before the two key strings)\n' "$path" "$b" "$a"
      else
        printf '%-34s DIFFERS    reference %s B, candidate %s B\n' "$path" "$a" "$b"
        printf '    %s\n' "$(substituted_ledger "$REF/$path" | cmp - "$CAND/$path" 2>&1 | head -1)"
        status=1
      fi
      ;;
    *)
      if cmp -s "$REF/$path" "$CAND/$path"; then
        printf '%-34s identical  %s B%s\n' "$path" "$a" \
          "$([ "$a" -eq 0 ] && echo '  (empty: no lines, not a blank line)')"
      else
        # `diff` is aliased to a colordiff that is not installed here.
        printf '%-34s DIFFERS    reference %s B, candidate %s B\n' "$path" "$a" "$b"
        printf '    %s\n' "$(cmp "$REF/$path" "$CAND/$path" 2>&1 | head -1)"
        /usr/bin/diff "$REF/$path" "$CAND/$path" | head -6 | sed 's/^/    /'
        status=1
      fi
      ;;
  esac
done

extra=$( (cd "$CAND" && find . -type f | sed 's|^\./||' | sort) \
  | grep -vxF -f <( (cd "$REF" && find . -type f | sed 's|^\./||' | sort) ) || true )
if [ -n "$extra" ]; then
  echo
  echo "--- files the candidate wrote that the reference did not"
  printf '%s\n' "$extra"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then echo "IDENTICAL"; else echo "DIFFERENT"; fi
exit "$status"
