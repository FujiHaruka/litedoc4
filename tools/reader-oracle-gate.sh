#!/usr/bin/env bash
# Is each writer record of the .olean reader (extractor/reader/) what that Lean
# wrote, and does the reader refuse what it has no record for?
#
#   oracle-<version>  that Lean loads its own Init, Std and Lean and writes the
#                     text OleanReader/Serialize.lean defines; the reader decodes
#                     the same files and writes it too; the two are equal byte
#                     for byte
#   refuse-version    a header naming a Lean the table has no record for
#   refuse-githash    a known version whose githash differs in one character
#   refuse-mixed      one read whose modules came from two writers
#   refuse-absent     entries under an extension the record lists as absent
#
# The writer list is `reader --writers`, never a second list. A refusal fixture
# is a copy of real files with the header rewritten, and must read before it is
# broken. A writer whose toolchain is not installed is not answered (exit 2):
# `elan run` would install it, so the gate checks first.
#
# usage: reader-oracle-gate.sh [--sample N|all] [--seed S] [--keep]
#   --sample  declarations whose type, ranges and docstring are compared (default: all)
#   --seed    the sample's seed (default: 1)
#   --keep    leave the work area in place
#
#   READER_ORACLE_WORK  work area (default: /private/tmp/lean-doc-relay/reader-oracle),
#                       emptied at the start and removed at the end
#   ELAN_HOME           where elan keeps toolchains (default: ~/.elan)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
answer_required

SAMPLE=all
SEED=1
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '/^# usage:/,/^set -/p' "$0" | sed 's/^# \{0,1\}//;$d'; answer 0 ;;
    *) echo "reader-oracle-gate: unknown flag: $1" >&2; exit 2 ;;
  esac
done

WORK="${READER_ORACLE_WORK:-/private/tmp/lean-doc-relay/reader-oracle}"
TOOLCHAINS="${ELAN_HOME:-$HOME/.elan}/toolchains"
READER_SRC="$ROOT/extractor/reader"
DUMP_SRC="$ROOT/tools/reader-oracle/Dump.lean"
REFUSALS=(refuse-version refuse-githash refuse-mixed refuse-absent)
ABSENT_PROBE=Init.Grind.Homo.Nat

rm -rf "$WORK"
mkdir -p "$WORK"
on_exit 'if [ "$KEEP" -eq 0 ]; then rm -rf "$WORK"; fi'

say () { printf '%s\n' "$*"; }
ran=0
failed=0
declared=0
ok ()   { ran=$((ran + 1));                        say "ITEM $1 ok    $2"; }
bad ()  { ran=$((ran + 1)); failed=$((failed + 1)); say "ITEM $1 FAIL  $2"; }
gone () {                                           say "ITEM $1 ----  $2"; }
excerpt () { head -c 1500 "$1" | sed 's/^/      /'; }

toolchain_dir () { printf '%s/%s\n' "$TOOLCHAINS" "$(printf '%s' "$1" | sed 's|/|--|; s|:|---|')"; }
lib_of () { printf '%s/lib/lean\n' "$(toolchain_dir "$1")"; }
installed () { [ -x "$(toolchain_dir "$1")/bin/lean" ]; }

githash_of () { awk -v v="$1" '$1 == v { print $2 }' "$WORK/writers.txt"; }

compile () {
  LEAN_PATH="$2" elan run "$1" lean --root="$3" -o "$2/$4.olean" -c "$2/$4.c" "$5"
}

READER_TC="$(awk '!/^#/ && NF { tc = $1 } END { print tc }' "$ROOT/tools/lean-toolchains.txt")"
[ -n "$READER_TC" ] || { say "reader-oracle-gate: tools/lean-toolchains.txt has no row" >&2; exit 1; }
if ! installed "$READER_TC"; then
  say "reader-oracle-gate: the reader's toolchain $READER_TC is not installed -- nothing was answered" >&2
  answer 2
fi

record_host
say "=== the reader, on $READER_TC"
READER="$(build_reader "$ROOT" "$WORK/reader" "$WORK/reader-build.log")" || exit 1

if ! "$READER" --writers >"$WORK/writers.txt" 2>"$WORK/writers.err"; then
  say "reader-oracle-gate: reader --writers failed:" >&2
  excerpt "$WORK/writers.err" >&2
  exit 1
fi
WRITERS=()
while read -r version _; do WRITERS+=("$version"); done <"$WORK/writers.txt"
if [ "${#WRITERS[@]}" -eq 0 ]; then
  say "reader-oracle-gate: the reader lists no writer -- there is nothing to hold it against" >&2
  exit 1
fi
declared=$(( ${#WRITERS[@]} + ${#REFUSALS[@]} ))
"$READER" --registered-extensions >"$WORK/registered.txt"
say "  ${#WRITERS[@]} writer record(s): ${WRITERS[*]}"

READER_VERSION="${READER_TC##*:v}"
if [ -z "$(githash_of "$READER_VERSION")" ]; then
  say "reader-oracle-gate: the reader runs on $READER_TC and has no writer record for Lean $READER_VERSION -- it cannot read its own toolchain's files" >&2
  exit 1
fi
OLDER=""
for v in "${WRITERS[@]}"; do
  if [ "$v" != "$READER_VERSION" ] && installed "leanprover/lean4:v$v"; then OLDER="$v"; fi
done

say
say "=== the oracle: each writer's Lean against the reader, sample $SAMPLE, seed $SEED"
for v in "${WRITERS[@]}"; do
  tc="leanprover/lean4:v$v"
  item="oracle-$v"
  if ! installed "$tc"; then
    gone "$item" "$tc is not installed; this record is not answered"
    continue
  fi
  dir="$WORK/dump-$v"
  mkdir -p "$dir/OleanReader"
  if ! { compile "$tc" "$dir" "$READER_SRC" OleanReader/Serialize "$READER_SRC/OleanReader/Serialize.lean" &&
         compile "$tc" "$dir" "$ROOT/tools/reader-oracle" Dump "$DUMP_SRC" &&
         elan run "$tc" leanc -rdynamic -o "$dir/dump" "$dir/OleanReader/Serialize.c" "$dir/Dump.c"; } \
       >"$dir/build.log" 2>&1; then
    bad "$item" "the dumper did not build on $tc"
    excerpt "$dir/build.log"
    continue
  fi
  started=$(date +%s)
  set +e
  elan run "$tc" "$dir/dump" oracle "$WORK/registered.txt" "$SEED" "$SAMPLE" >"$dir/writer.txt" 2>"$dir/writer.err"
  wrc=$?
  "$READER" oracle "$(lib_of "$tc")" "$SEED" "$SAMPLE" >"$dir/reader.txt" 2>"$dir/reader.err"
  rrc=$?
  set -e
  took=$(( $(date +%s) - started ))
  if [ "$wrc" -ne 0 ]; then
    bad "$item" "the dumper exited $wrc"; excerpt "$dir/writer.err"
  elif [ "$rrc" -ne 0 ]; then
    bad "$item" "the reader exited $rrc"; excerpt "$dir/reader.err"
  elif [ ! -s "$dir/writer.txt" ]; then
    bad "$item" "the dumper wrote nothing"
  elif cmp -s "$dir/writer.txt" "$dir/reader.txt"; then
    ok "$item" "$(wc -l <"$dir/writer.txt" | tr -d ' ') lines equal ($(grep -c '^const ' "$dir/writer.txt") constants, $(grep -c '^decl ' "$dir/writer.txt") sampled, $(grep -c '^status ' "$dir/writer.txt") reducibility values) in ${took}s"
  else
    line="$( (cmp "$dir/writer.txt" "$dir/reader.txt" 2>&1 || true) | sed -n 's/.*line \([0-9][0-9]*\).*/\1/p')"
    if [ -z "$line" ]; then line="$(( $(wc -l <"$dir/reader.txt") + 1 ))"; fi
    bad "$item" "the reader differs from Lean $v at line $line"
    say "      Lean   $(sed -n "${line}p" "$dir/writer.txt" | head -c 300)"
    say "      reader $(sed -n "${line}p" "$dir/reader.txt" | head -c 300)"
  fi
  rm -f "$dir/writer.txt" "$dir/reader.txt" "$dir/dump" "$dir"/*.c "$dir"/OleanReader/*.c
done

relabel () {
  python3 - "$@" <<'PY'
import sys
version, githash, *files = sys.argv[1:]
for f in files:
    with open(f, "r+b") as h:
        head = h.read(80)
        if head[:5] != b"olean":
            sys.exit(f"relabel: {f} is not an .olean")
        h.seek(7)
        h.write(version.encode().ljust(33, b"\0") + githash.encode().ljust(40, b"\0"))
PY
}

copy_module () {
  local src
  src="$(lib_of "$1")"
  mkdir -p "$3/$(dirname "$2")"
  cp "$src/$2".olean* "$3/$(dirname "$2")/"
}

refusal () {
  local item="$1" dir="$2" module="$3"
  shift 3
  set +e
  "$READER" read "$dir" "$module" >"$dir.out" 2>"$dir.err"
  local rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    bad "$item" "reading $module exited $rc, a refusal exits 1"
    excerpt "$dir.err"
    return
  fi
  for word in "$@"; do
    if ! grep -qF -- "$word" "$dir.err"; then
      bad "$item" "the refusal does not name \`$word\`: $(head -c 400 "$dir.err")"
      return
    fi
  done
  ok "$item" "$(head -c 400 "$dir.err")"
}

readable () {
  set +e
  "$READER" read "$2" "$3" >"$2.control" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    bad "$1" "the unmodified fixture does not read (exit $rc), so its refusal would mean nothing"
    excerpt "$2.control"
    return 1
  fi
}

say
say "=== the refusals, on copies of $READER_TC's own files"
READER_HASH="$(githash_of "$READER_VERSION")"

dir="$WORK/fixture-version"
copy_module "$READER_TC" Init/Prelude "$dir"
if readable refuse-version "$dir" Init.Prelude; then
  relabel 4.99.0 "$READER_HASH" "$dir"/Init/Prelude.olean*
  refusal refuse-version "$dir" Init.Prelude "Lean 4.99.0" "no record for Lean 4.99.0"
fi

dir="$WORK/fixture-githash"
copy_module "$READER_TC" Init/Prelude "$dir"
if readable refuse-githash "$dir" Init.Prelude; then
  first="${READER_HASH:0:1}"
  if [ "$first" = "0" ]; then other=1; else other=0; fi
  changed="$other${READER_HASH:1}"
  relabel "$READER_VERSION" "$changed" "$dir"/Init/Prelude.olean*
  refusal refuse-githash "$dir" Init.Prelude "githash $changed" "a different build of $READER_VERSION is refused"
fi

if [ -z "$OLDER" ]; then
  gone refuse-mixed "no second writer's toolchain is installed to mix with"
  gone refuse-absent "no second writer's toolchain is installed to relabel as"
else
  dir="$WORK/fixture-mixed"
  copy_module "$READER_TC" Init/Prelude "$dir"
  copy_module "$READER_TC" Init/Coe "$dir"
  if readable refuse-mixed "$dir" Init.Coe; then
    copy_module "leanprover/lean4:v$OLDER" Init/Prelude "$dir"
    refusal refuse-mixed "$dir" Init.Coe "Lean $OLDER" "Lean $READER_VERSION" "one read takes one writer"
  fi

  dir="$WORK/fixture-absent"
  mkdir -p "$dir"
  "$READER" read "$(lib_of "$READER_TC")" "$ABSENT_PROBE" >"$WORK/absent-closure.txt"
  while read -r tag module; do
    if [ "$tag" = module ]; then copy_module "$READER_TC" "${module//.//}" "$dir"; fi
  done <"$WORK/absent-closure.txt"
  if readable refuse-absent "$dir" "$ABSENT_PROBE"; then
    files=()
    while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$dir" -type f -name '*.olean*' -print0)
    relabel "$OLDER" "$(githash_of "$OLDER")" "${files[@]}"
    refusal refuse-absent "$dir" "$ABSENT_PROBE" "entries under extension" \
      "which the record for Lean $OLDER lists as absent"
  fi
fi

say
say "=== summary"
say "items reported : $ran of $declared"
say "failed         : $failed"
if [ "$failed" -ne 0 ]; then
  say "READER ORACLE GATE: FAILED ($failed of $ran answered items)" >&2
  answer 1
fi
if [ "$ran" -ne "$declared" ]; then
  say "READER ORACLE GATE: $ran of $declared items answered -- the rest were not asked, which is not a pass" >&2
  answer 2
fi
say "READER ORACLE GATE: ok ($ran of $declared)"
answer 0
