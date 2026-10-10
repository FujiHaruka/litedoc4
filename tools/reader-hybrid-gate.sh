#!/usr/bin/env bash
# Does the .olean reader's hybrid run write the IR the native extractor writes?
#
# The sample e2e/micro (with e2e/micro-dep) is built natively on every row of
# tools/lean-toolchains.txt and extracted there; each build's .olean files are
# then read by `reader extract`, with the newest row's build of the same sample
# as the newest side, and its IR is compared with that row's native IR.
#
#   self-<newest>     the newest row read through the reader: the printer and
#                     the data are the same Lean, so the IR and the link index
#                     are the native ones byte for byte except the identity
#   read-<version>    an older row read in the newest Lean, equal to its
#                     native IR except where tools/lib/reader-compare.py says
#                     (the reducibility rename of column 2, contentHash, the
#                     identity), which tools/mv-reader-gate.sh shares
#   invariants-<version>
#                     the run's mechanism-3 summary: every constant of the
#                     import closure checked, 0 dangling references; every
#                     module's .ilean compared, at least one declaration
#                     listed and equal, 0 disagreements; the decoded ranges
#                     each exclusion rule leaves out, printed
#   hard-stops        every reader run reports the sample's hard stops:
#                     verso=0 builtin-doc=0 tactic-table=1
#                     autoparam-old-only=0 autoparam-newest=0
#   refuse-<flag>     --dump-tactics, --tactics-emulate, --tactics-probe and
#                     --serve are refused by name, before anything is read
#   refuse-dangling   the newest row with a copy of Example.Dep's .olean whose
#                     import list no longer names «Dep-Aux».Basic: that module
#                     leaves the closure, and Example.usesDep's DepAux.marker
#                     is refused by name before any IR is written
#   refuse-ilean      the newest row with a copy of Example.Basic's .ilean
#                     whose first declaration's end line is one more: refused
#                     by name, with both ranges, before any IR is written
#   accept-ilean-imported
#                     the same copy listing core's Nat at the range
#                     Init/Prelude.ilean gives it: read, ilean-imported 1
#   refuse-ilean-imported
#                     ... with Nat's end line one more: refused by name, with
#                     both ranges, before any IR is written
#   refuse-ilean-unknown
#                     ... listing Example.noSuchDeclaration, which no module of
#                     the closure declares: refused by name
#   probe-manual-root every older row's copy of the sample has the gate's own
#                     module Example.ReaderProbe, whose docstring links
#                     lean-manual://: natively it links that row's own manual,
#                     and the reader's docstring is the same
#   probe-structure-default
#                     ... and a structure Cheap extending Base, whose field
#                     default the newest row's copy overrides: natively the
#                     binder (c : Cheap := { }) prints `{ }`, the reader's is
#                     the same, and its merge dropped the newest-only default
#                     function. Base's default is 2 on the last older row and
#                     0 on every other, so (c : Cheap := { depth := 0 }) of
#                     Example.ReaderProbe.withValue prints `{ }` on every
#                     older row but the last, with the same elaborated type.
#                     The module also declares Example.ReaderProbeTarget.val,
#                     which Example.ReaderProbe.shadowed's type names, and on
#                     every second older row (not the newest)
#                     Example.ReaderProbe.ReaderProbeTarget.val, which shadows
#                     it: natively the type prints `ReaderProbeTarget.val`
#                     where the shadow is absent and the full name where it is
#                     there
#   session-equals-alone
#                     every older row read by one `reader session
#                     --check-patch --check-keys`, oldest first, the newest
#                     imported once, round 1 built whole and every later round
#                     patched from the one before, its print keys carried from
#                     the round before but where an input they read changed,
#                     each reusing the printed part of every
#                     declaration whose print key equals the previous round's:
#                     each round answers `ok 0`, its IR and link index are the
#                     bytes of that row's read-alone run, and its summary
#                     (invariants, merge counts, hard stops, the analysis
#                     counts) is read-alone's but for timings and the
#                     printing-work counts a reuse skips (equation lemmas,
#                     reference occurrences, member fields); each round's peak
#                     RSS, patch, check-patch and reuse lines are printed
#   session-reuse     ... and each round's reuse line, which counts a
#                     declaration reused only when its output holds the
#                     previous round's signature object: round 1 reused 0,
#                     every declaration new; every later round reused at least
#                     one and printed again none whose key was equal; in every
#                     round reused + reprinted is the analysis's produced
#                     count, and the reprinted ones' reasons add up
#   session-check-patch
#                     ... and each round's patch line says how it was built
#                     (whole, or from the row before) and its check-patch
#                     line says 0 modules and 0 other things differ from
#                     rewriteMerge's state built from the same decoded data
#   session-manual-root
#                     ... and each round's Example.ReaderProbe docstring is
#                     its native one, linking that row's own manual root, a
#                     different root in every round
#   session-check-keys
#                     ... and each round's check-keys line says 0 of its keys
#                     differ from a fresh pass with fresh memos; round 1
#                     carried none, every later round says it carried from
#                     the round before, carried + recomputed is the
#                     candidate count, and some round carried at least one
#   no-patch-equals-alone
#                     every older row read by one `reader session --no-patch`:
#                     each round decoded whole and merged as read-alone merges,
#                     every print key computed afresh, and the printed part of
#                     every declaration whose key equals the previous round's
#                     reused: each round answers `ok 0` and prints no patch or
#                     carry line, its IR and link index are the bytes of that
#                     row's read-alone run, its summary is read-alone's as
#                     above, and its reuse line passes session-reuse's checks
#                     (every round after the first reused at least one)
#   lazy-proofs-equals-alone
#                     every older row read again by `reader extract
#                     --lazy-proofs` (a theorem's proof decoded only where
#                     its module stores no axiom list for it or the list holds
#                     sorryAx): its IR and link index are the bytes of the
#                     row's read-alone run, its invariants hold as above, its
#                     proofs line adds up (the proofs decoded are the ones the
#                     rule names, decoded + omitted = theorems), at least one
#                     proof was omitted and at least one decoded for sorryAx
#                     (Example.sorryHole among them)
#   manual-root-cache ... and each of those runs, every older row's second read,
#                     took its manual root from the reader's cache entry
#                     named by its own toolchain's githash, which its first
#                     read asked that toolchain for and kept there (the
#                     second read's IR is the first's, above)
#   reuse-self-equals-alone
#                     every older row read again by `reader extract
#                     --write-reuse-keys`, then by `reader extract
#                     --reuse-from` naming that run's own IR: both IRs and
#                     link indexes are the bytes of the row's read-alone run,
#                     the second run's reuse-from line says the printing
#                     identity is equal and every produced declaration was
#                     reused, none printed, and both runs wrote the same keys
#   carry-presence-flip
#                     the first two older rows, across the shadow's
#                     disappearance, in a session with --check-keys
#                     --carry-without-presence (a name resolution carried
#                     past a looked-up name appearing or disappearing):
#                     natively Example.ReaderProbe.shadowed prints
#                     differently on the two rows, and the second round fails
#                     with check-keys naming it and a presence flip of
#                     Example.ReaderProbe.ReaderProbeTarget.val
#   patch-perturbed   the first two older rows in a session with
#                     --perturb-patch, which leaves the last module a changed
#                     constant dirties unrewritten: check-patch fails the
#                     round, naming that module
#   patch-field-fn-trigger
#                     Example.ReaderProbeField declares `structure Flip` with
#                     a field default on every second older row, and the
#                     newest row declares it private: read-alone drops the
#                     newest's private default function where the old public
#                     Flip exists, which no constant of that newest module
#                     shares a name with. The last two older rows in a session
#                     with --no-field-fn-index: check-patch fails the second
#                     round naming Example.ReaderProbeField; in the session
#                     above the same round is 0 and its patch line rewrote a
#                     module for a field function
#   reuse-scx         the last two older rows, across Base's default change,
#                     in a session with --key-without-scx (the print key
#                     without the field defaults structure-instance notation
#                     reads): the second round answers ok 0 and its IR
#                     differs from read-alone in exactly
#                     Example.ReaderProbe.withValue, reused stale as `{ }`
#                     where read-alone prints `{ depth := 0 }`; the session
#                     above, keyed with them, prints `{ depth := 0 }`
#
# The sample in e2e/micro is not changed: Example.ReaderProbe and
# Example.ReaderProbeField are written into each row's copy only.
#
# A row whose toolchain is not installed is not answered (exit 2): `lake`
# would install it, so the gate checks first.
#
# usage: reader-hybrid-gate.sh [--keep]
#   --keep    leave the work area in place
#
#   READER_HYBRID_WORK  work area (default: /private/tmp/lean-doc-relay/reader-hybrid),
#                       emptied at the start and removed at the end
#   LITEDOC4 / LAKE     the binaries (default: .lake/build/bin/litedoc4, ~/.elan/bin/lake)
#   ELAN_HOME           where elan keeps toolchains (default: ~/.elan)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
answer_required

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '/^# usage:/,/^set -/p' "$0" | sed 's/^# \{0,1\}//;$d'; answer 0 ;;
    *) echo "reader-hybrid-gate: unknown flag: $1" >&2; exit 2 ;;
  esac
done

WORK="${READER_HYBRID_WORK:-/private/tmp/lean-doc-relay/reader-hybrid}"
TOOLCHAINS="${ELAN_HOME:-$HOME/.elan}/toolchains"
LAKE="${LAKE:-$HOME/.elan/bin/lake}"
LITEDOC4="${LITEDOC4:-$ROOT/.lake/build/bin/litedoc4}"
INVENTORY="$ROOT/tools/lean-toolchains.txt"
FLAGS=(--equations --refs --write-ir --tagged-code --jobs 1)
REFUSED=(--dump-tactics --tactics-emulate --tactics-probe --serve)
EXPECTED_STOPS="verso=0 builtin-doc=0 tactic-table=1 autoparam-old-only=0 autoparam-newest=0"

[ -x "$LITEDOC4" ] || {
  echo "reader-hybrid-gate: no litedoc4 at $LITEDOC4; tools/build-lean-exe.sh --toolchain-from e2e/micro" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK"
on_exit 'if [ "$KEEP" -eq 0 ]; then rm -rf "$WORK"; fi'

say () { printf '%s\n' "$*"; }
ran=0
failed=0
ok ()   { ran=$((ran + 1));                        say "ITEM $1 ok    $2"; }
bad ()  { ran=$((ran + 1)); failed=$((failed + 1)); say "ITEM $1 FAIL  $2"; }
gone () {                                           say "ITEM $1 ----  $2"; }
excerpt () { head -c 1500 "$1" | sed 's/^/      /'; }

installed () { [ -x "$TOOLCHAINS/$(printf '%s' "$1" | sed 's|/|--|; s|:|---|')/bin/lean" ]; }

ROWS=()
SPELLINGS=()
while read -r tc attr; do
  ROWS+=("$tc"); SPELLINGS+=("$attr")
done < <(awk '{ sub(/#.*/, "") } NF { print $1, $2 }' "$INVENTORY")
if [ "${#ROWS[@]}" -lt 2 ]; then
  say "reader-hybrid-gate: $INVENTORY lists fewer than two toolchains -- there is no older row to read" >&2
  exit 1
fi
NEWEST_I=$(( ${#ROWS[@]} - 1 ))
NEWEST="${ROWS[$NEWEST_I]##*:v}"
NEWEST_SPELLING="${SPELLINGS[$NEWEST_I]}"
declared=$(( 2 * ${#ROWS[@]} + 1 + ${#REFUSED[@]} + 5 + 2 + 13 ))

record_host
if ! installed "${ROWS[$NEWEST_I]}"; then
  say "reader-hybrid-gate: the reader's toolchain ${ROWS[$NEWEST_I]} is not installed -- nothing was answered" >&2
  answer 2
fi
say "=== the reader, on ${ROWS[$NEWEST_I]}"
if ! "$LITEDOC4" reader build --out "$WORK/reader" --lake "$LAKE" >"$WORK/reader-build.log" 2>&1; then
  say "reader-hybrid-gate: litedoc4 reader build failed:" >&2
  tail -c 1500 "$WORK/reader-build.log" >&2
  exit 1
fi
READER="$(tail -n 1 "$WORK/reader-build.log")"
[ -x "$READER" ] || { say "reader-hybrid-gate: litedoc4 reader build named no executable: $READER" >&2; exit 1; }
"$READER" extract --identity "${FLAGS[@]}" >"$WORK/reader-identity.txt"
say "  $(cat "$WORK/reader-identity.txt")"

# usage: probe_module <version> <row index>
probe_module () {
  local override="" depth=0 shadow=""
  if [ "$1" = "$NEWEST" ]; then override=$' where\n  depth := 1'; fi
  if [ "$2" -eq $(( NEWEST_I - 1 )) ]; then depth=2; fi
  if [ "$2" -ne "$NEWEST_I" ] && [ $(( $2 % 2 )) -eq 0 ]; then
    shadow=$'\nnamespace ReaderProbeTarget\n\ndef val : Nat := 1\n\nend ReaderProbeTarget\n'
  fi
  cat <<EOF
namespace Example.ReaderProbeTarget

def val : Nat := 0

end Example.ReaderProbeTarget

namespace Example.ReaderProbe

/-- The manual's [macro section](lean-manual://section/tactic-macro-extension). -/
def manualLinked : Nat := 0

structure Base where
  depth : Nat := $depth

structure Cheap extends Base$override

def withDefault (c : Cheap := { }) : Nat := c.depth

def withValue (c : Cheap := { depth := 0 }) : Nat := c.depth

theorem shadowed : Example.ReaderProbeTarget.val = 0 := rfl
$shadow
end Example.ReaderProbe
EOF
}

# usage: field_probe_module <row index>
field_probe_module () {
  printf 'namespace Example.ReaderProbeField\n\n'
  if [ "$1" -eq "$NEWEST_I" ]; then
    printf 'private structure Flip where\n  depth : Nat := 0\n\n'
  elif [ $(( $1 % 2 )) -eq 1 ]; then
    printf 'structure Flip where\n  depth : Nat := 0\n\n'
  fi
  printf 'end Example.ReaderProbeField\n'
}

# usage: native <version> <row index>
native () {
  local v="$1" dir="$WORK/v$1" exe
  mkdir -p "$dir/native"
  cp -R "$ROOT/e2e/micro" "$ROOT/e2e/micro-dep" "$dir/"
  rm -rf "$dir/micro/.lake" "$dir/micro-dep/.lake"
  probe_module "$v" "$2" >"$dir/micro/Example/ReaderProbe.lean"
  field_probe_module "$2" >"$dir/micro/Example/ReaderProbeField.lean"
  { printf 'import Example.ReaderProbe\nimport Example.ReaderProbeField\n'; cat "$ROOT/e2e/micro/Example.lean"; } \
    >"$dir/micro/Example.lean"
  echo "leanprover/lean4:v$v" >"$dir/micro/lean-toolchain"
  echo "leanprover/lean4:v$v" >"$dir/micro-dep/lean-toolchain"
  (cd "$dir/micro" && "$LAKE" build) >"$dir/build.log" 2>&1 || { echo "lake build failed"; return 1; }
  "$LITEDOC4" modules --root "$dir/micro" --lib Example --out "$dir/modules.txt" >"$dir/modules.log" 2>&1 ||
    { echo "litedoc4 modules failed"; return 1; }
  exe="$(micro_extractor "$ROOT" "$dir/micro" "$LAKE" "$dir/extractor-build.log")"
  [ -x "$exe" ] || { echo "the native extractor did not build"; return 1; }
  (cd "$dir/micro" && "$LAKE" env "$exe" "$dir/modules.txt" "$dir/native-events.jsonl" "${FLAGS[@]}" \
     --ir-dir "$dir/native/ir" --link-index "$dir/native/links.lidx") >"$dir/native.log" 2>&1 ||
    { echo "the native extractor failed"; return 1; }
  (cd "$dir/micro" && "$LAKE" env printenv LEAN_PATH) >"$dir/search-path.txt"
}

search_args () {
  local d
  tr ':' '\n' <"$WORK/v$2/search-path.txt" | while read -r d; do
    if [ -n "$d" ]; then printf '%s\n%s\n' "$1" "$d"; fi
  done
}

# usage: read_through <version> <out> [--shadow <dir>] [<reader flag>...] [extractor flags...]
#   --shadow       a search directory put before the version's own, for a corrupted copy
#   <reader flag>  --lazy-proofs, --write-reuse-keys or --reuse-from <dir>: the reader's own,
#                  passed before the extractor's command line
read_through () {
  local v="$1" out="$2" args=()
  shift 2
  if [ "${1:-}" = --shadow ]; then args+=(--old "$2"); shift 2; fi
  while :; do
    case "${1:-}" in
      --lazy-proofs|--write-reuse-keys) args+=("$1"); shift ;;
      --reuse-from) args+=("$1" "$2"); shift 2 ;;
      *) break ;;
    esac
  done
  while IFS= read -r a; do args+=("$a"); done < <(search_args --old "$v"; search_args --new "$NEWEST")
  mkdir -p "$out"
  set +e
  "$READER" extract "${args[@]}" --new-roots "$WORK/v$NEWEST/modules.txt" "$WORK/v$v/modules.txt" \
    "$out/events.jsonl" "${FLAGS[@]}" --ir-dir "$out/ir" --link-index "$out/links.lidx" "$@" \
    >"$out/stdout.txt" 2>"$out/stderr.txt"
  local rc=$?
  set -e
  return "$rc"
}

compare () {
  python3 "$HERE/lib/reader-compare.py" "$WORK/v$1/native/ir" "$WORK/v$1/native/links.lidx" \
    "$WORK/v$1/read/ir" "$WORK/v$1/read/links.lidx" "$1" "$2" "$NEWEST_SPELLING" \
    "$ROOT/extractor/Extract.lean" "$(dirname "$READER")/Extract.lean" "$WORK/reader-identity.txt"
}

invariants () {
  python3 - "$1" <<'PY'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()
def grab(pattern):
    m = re.search(pattern, text, re.M)
    if not m:
        print(f"no line matches {pattern!r}")
        sys.exit(1)
    return [int(g) for g in m.groups()]

constants, refs, dangling = grab(r"^invariants +closure: (\d+) constants, (\d+) references checked, (\d+) dangling")
modules, nbytes, equal, disagree = grab(r"^  ilean +(\d+) modules \((\d+) bytes\), (\d+) declarations listed and equal, (\d+) disagree")
no_parent, = grab(r"^  ilean-no-parent +(\d+) decoded ranges")
in_theorem, = grab(r"^  ilean-in-theorem +(\d+) decoded ranges")
read_modules, read_constants = grab(r"^reader +Lean \S+ \(\w+\) read in Lean \S+: (\d+) modules, (\d+) constants")
problems = []
if constants != read_constants:
    problems.append(f"{constants} constants checked of {read_constants} decoded")
if refs == 0:
    problems.append("0 references checked")
if dangling != 0:
    problems.append(f"{dangling} dangling references")
if modules != read_modules:
    problems.append(f"{modules} .ilean files compared of {read_modules} modules read")
if equal == 0:
    problems.append("0 declarations listed and equal")
if disagree != 0:
    problems.append(f"{disagree} .ilean disagreements")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"closure {constants} of {read_constants} constants, {refs} references, 0 dangling; "
      f".ilean {modules} of {read_modules} modules ({nbytes} bytes), {equal} declarations equal, 0 disagree; "
      f"not listed: no-parent {no_parent}, in-theorem {in_theorem}")
PY
}

STOPS_SEEN=()
item_read () {
  local item="$1" v="$2" out="$WORK/v$2/read" result
  if ! read_through "$v" "$out"; then
    bad "$item" "reader extract exited non-zero"
    excerpt "$out/stderr.txt"
    bad "invariants-$v" "reader extract exited non-zero, so there is no summary"
    return
  fi
  if result="$(invariants "$out/stdout.txt" 2>&1)"; then
    ok "invariants-$v" "$result"
  else
    bad "invariants-$v" "$result"
  fi
  STOPS_SEEN+=("$v $(sed -n 's/^hard stops *//p' "$out/stdout.txt")")
  if result="$(compare "$v" "$3" 2>&1)"; then
    ok "$item" "$result"
  else
    bad "$item" "the reader's IR of Lean $v differs from the native one:"
    printf '%s\n' "$result" | head -c 2000 | sed 's/^/      /'
  fi
}

say
say "=== the sample, natively, on each row"
NATIVE_OK=()
for i in "${!ROWS[@]}"; do
  v="${ROWS[$i]##*:v}"
  if ! installed "${ROWS[$i]}"; then
    NATIVE_OK+=("not-installed")
    say "  v$v: ${ROWS[$i]} is not installed"
  elif why="$(native "$v" "$i")"; then
    NATIVE_OK+=("ok")
    say "  v$v: $(wc -l <"$WORK/v$v/modules.txt" | tr -d ' ') modules extracted"
  else
    NATIVE_OK+=("$why")
    say "  v$v: $why"
  fi
done

say
say "=== the reader against each native IR"
for i in "${!ROWS[@]}"; do
  v="${ROWS[$i]##*:v}"
  if [ "$i" -eq "$NEWEST_I" ]; then item="self-$v"; else item="read-$v"; fi
  if [ "${NATIVE_OK[$i]}" = not-installed ]; then
    gone "$item" "${ROWS[$i]} is not installed; this row is not answered"
    gone "invariants-$v" "${ROWS[$i]} is not installed; this row is not answered"
  elif [ "${NATIVE_OK[$NEWEST_I]}" != ok ]; then
    bad "$item" "the newest row's sample did not build (${NATIVE_OK[$NEWEST_I]}), so there is no newest side"
    bad "invariants-$v" "the newest row's sample did not build, so nothing was read"
  elif [ "${NATIVE_OK[$i]}" != ok ]; then
    bad "$item" "the native side did not build: ${NATIVE_OK[$i]}"
    bad "invariants-$v" "the native side did not build, so nothing was read"
  else
    item_read "$item" "$v" "${SPELLINGS[$i]}"
  fi
done

say
say "=== the hard stops each reader run reported"
if [ "${#STOPS_SEEN[@]}" -eq 0 ]; then
  bad hard-stops "no reader run reported its hard stops"
else
  wrong=()
  for s in "${STOPS_SEEN[@]}"; do
    if [ "${s#* }" != "$EXPECTED_STOPS" ]; then wrong+=("$s"); fi
  done
  if [ "${#wrong[@]}" -eq 0 ]; then
    ok hard-stops "${#STOPS_SEEN[@]} run(s), each: $EXPECTED_STOPS"
  else
    bad hard-stops "expected $EXPECTED_STOPS; ${wrong[*]}"
  fi
fi

# usage: probe <manual|default> <version> [<the reader's output directory>]
probe () {
  local read="${3:-$WORK/v$2/read}"
  python3 - "$1" "$2" "$WORK/v$2/native/ir" "$read/ir" "$WORK/v$2/read/stdout.txt" <<'PY'
import json, pathlib, re, sys

kind, v, native, read, stdout = sys.argv[1:]

def decl(root, name):
    f = pathlib.Path(root) / "modules" / "Example.ReaderProbe.json"
    if not f.is_file():
        sys.exit(f"v{v}: no {f}")
    for d in json.loads(f.read_text(encoding="utf-8")).get("declarations", []):
        if d.get("name") == name:
            return d
    sys.exit(f"v{v}: {f} has no {name}")

if kind == "manual":
    name = "Example.ReaderProbe.manualLinked"
    own = f"https://lean-lang.org/doc/reference/{v}/"
    n, r = decl(native, name).get("doc") or "", decl(read, name).get("doc") or ""
    if own not in n:
        sys.exit(f"v{v}: the native docstring of {name} does not link {own}: {n!r}")
    if r != n:
        sys.exit(f"v{v}: the native docstring links {own}, the reader's is {r!r}")
    m = re.search(r"https://lean-lang\.org/doc/reference/[^/]+/", r)
    print(f"v{v} links {own} {m.group(0)}")
else:
    name = "Example.ReaderProbe.withDefault"
    n, r = decl(native, name).get("binders") or [], decl(read, name).get("binders") or []
    if not any(":= { }" in b for b in n):
        sys.exit(f"v{v}: the native binders of {name} print no `{{ }}`: {n}")
    if r != n:
        sys.exit(f"v{v}: native {n}, the reader's {r}")
    m = re.search(r"default and autoParam functions of old structures' fields dropped (\d+)",
                  pathlib.Path(stdout).read_text(encoding="utf-8"))
    if not m or m.group(1) == "0":
        sys.exit(f"v{v}: the binders are equal, but the merge reports no newest-only default function dropped")
    print(f"v{v} {' '.join(n)}, {m.group(1)} dropped")
PY
}

say
say "=== the gate's own module, on each older row the reader read"
for item in probe-manual-root probe-structure-default; do
  if [ "$item" = probe-manual-root ]; then kind=manual; else kind=default; fi
  lines=()
  fails=()
  for i in "${!ROWS[@]}"; do
    v="${ROWS[$i]##*:v}"
    if [ "$i" -eq "$NEWEST_I" ] || [ ! -d "$WORK/v$v/read/ir" ]; then continue; fi
    if result="$(probe "$kind" "$v" 2>&1)"; then
      if [ "$kind" = manual ]; then result="${result% *}"; fi
      lines+=("$result")
    else
      fails+=("$result")
    fi
  done
  if [ "${#fails[@]}" -ne 0 ]; then
    bad "$item" "$(printf '%s; ' "${fails[@]}")"
  elif [ "${#lines[@]}" -eq 0 ]; then
    bad "$item" "no older row was read through the reader"
  else
    ok "$item" "$(printf '%s; ' "${lines[@]}")"
  fi
done

say
say "=== the older rows in one reader session: round 1 built whole, every later round patched"
SESSION="$WORK/session"
SESSION_ROWS=()
session_missing=()
for i in "${!ROWS[@]}"; do
  v="${ROWS[$i]##*:v}"
  if [ "$i" -eq "$NEWEST_I" ] || [ "${NATIVE_OK[$i]}" = not-installed ]; then continue; fi
  if [ "${NATIVE_OK[$i]}" = ok ]; then SESSION_ROWS+=("$v"); else session_missing+=("v$v"); fi
done

# usage: request <version> <session directory>
request () {
  local v="$1" out="$2" a fields=()
  while IFS= read -r a; do fields+=("$a"); done < <(search_args --old "$v")
  fields+=("$WORK/v$v/modules.txt" "$out/v$v/events.jsonl" "${FLAGS[@]}"
           --ir-dir "$out/v$v/ir" --link-index "$out/v$v/links.lidx")
  local IFS=$'\t'
  printf '%s\n' "${fields[*]}"
}

# usage: run_session <session directory> [<session flag>...] -- <version>...
#   leaves requests.txt, stdout.txt, stderr.txt and rc in the directory
run_session () {
  local out="$1" flags=() v a new_args=()
  shift
  while [ "$1" != -- ]; do flags+=("$1"); shift; done
  shift
  mkdir -p "$out"
  for v in "$@"; do mkdir -p "$out/v$v"; request "$v" "$out"; done >"$out/requests.txt"
  while IFS= read -r a; do new_args+=("$a"); done < <(search_args --new "$NEWEST")
  set +e
  "$READER" session "${new_args[@]}" --new-roots "$WORK/v$NEWEST/modules.txt" ${flags[@]+"${flags[@]}"} \
    <"$out/requests.txt" >"$out/stdout.txt" 2>"$out/stderr.txt"
  echo "$?" >"$out/rc"
  set -e
}

# usage: session_check <alone|check-patch|check-keys|reuse|perturbed|field-fn|scx|presence-flip>
#          <session directory> <version>...
#   field-fn takes <disabled session> <enabled session> <module> <version> <version>
#   scx takes <session without SCX> <session with it> <version> <version>
#   presence-flip takes <session without presence flips> <version> <version>
session_check () {
  WORK="$WORK" python3 - "$@" <<'PY'
import json, os, pathlib, re, sys

work = pathlib.Path(os.environ["WORK"])
mode, args = sys.argv[1], sys.argv[2:]

def rounds(directory):
    out, cur = [], None
    for line in (pathlib.Path(directory) / "stdout.txt").read_text(encoding="utf-8").splitlines():
        m = re.match(r"round (\d+)$", line)
        if m:
            cur = {"n": int(m.group(1)), "lines": [], "code": None}
            continue
        m = re.match(r"ok (\d+) \d+$", line)
        if m and cur is not None:
            cur["code"] = int(m.group(1))
            out.append(cur)
            cur = None
        elif cur is not None:
            cur["lines"].append(line)
    return out

def grab(r, pattern):
    for l in r["lines"]:
        m = re.match(pattern, l)
        if m:
            return m
    return None

def check_lines(r):
    m = grab(r, r"check-patch +(\d+) modules differ from rewriteMerge's state, pointer by pointer; (\d+) other differences")
    named = [re.match(r"  check-patch-module (\S+):", l).group(1) for l in r["lines"] if l.startswith("  check-patch-module ")]
    return m, named

SESSION_ONLY = re.compile(r"^(patch|patch-perturbed|check-patch|carry|check-keys|reuse|rss|rss-at-extract|realizations|phases) |^  check-(patch|keys)-|^  dir ")
PRINTING_WORK = re.compile(r"^  (of which equations|of which refs|member extra) ")
CACHE_STATE = re.compile(r"^  manual-root-cache ")
def summary(lines):
    out = []
    for l in lines:
        if SESSION_ONLY.match(l) or CACHE_STATE.match(l):
            continue
        l = re.sub(r"\d+(\.\d+)?s\b|\d+ ms\b", "<t>", l)
        if PRINTING_WORK.match(l):
            l = re.sub(r"\(.*\)", "(<printing work>)", l)
        out.append(l)
    return out

REUSE = (r"reuse +(\d+) of (\d+) declarations reused, (\d+) reprinted \(key differs (\d+), key equal (\d+), "
         r"no previous output (\d+), new (\d+)\); key (.+) of (\d+) candidates: carried (\d+), recomputed (\d+) "
         r"\(stale (\d+), new (\d+)\) in (\d+) ms on (?:one thread|\d+ threads)$")
CHECK_KEYS = r"check-keys +(\d+) keys differ from a fresh pass \((\d+) keys, fresh memos, (\d+) thread\(s\), (\d+) ms\)$"

def module_decls(ir):
    out = {}
    for f in sorted((pathlib.Path(ir) / "modules").glob("*.json")):
        for d in json.loads(f.read_text(encoding="utf-8")).get("declarations", []):
            out[d.get("name")] = d
    return out

def differing_files(a, b):
    a, b = pathlib.Path(a), pathlib.Path(b)
    fa = {p.relative_to(a) for p in a.rglob("*") if p.is_file()}
    fb = {p.relative_to(b) for p in b.rglob("*") if p.is_file()}
    return sorted(str(p) for p in fa | fb if p not in fa or p not in fb or (a / p).read_bytes() != (b / p).read_bytes())

def fail(msg):
    print(msg)
    sys.exit(1)

if mode == "alone":
    directory, versions = args[0], args[1:]
    rs = rounds(directory)
    if len(rs) != len(versions):
        fail(f"{len(rs)} rounds answered for {len(versions)} requests")
    bad = []
    for r, v in zip(rs, versions):
        alone = (work / f"v{v}" / "read" / "stdout.txt").read_text(encoding="utf-8").splitlines()
        a, b = summary(r["lines"]), summary(alone)
        if a != b:
            diff = [f"{x!r} against {y!r}" for x, y in zip(a, b) if x != y][:2] or [f"{len(a)} lines against {len(b)}"]
            bad.append(f"v{v}: the round's summary is not read-alone's: {'; '.join(diff)}")
    if bad:
        fail("; ".join(bad))
    print(f"{len(rs)} summaries equal to read-alone's, timings aside")
elif mode == "check-patch":
    directory, versions = args[0], args[1:]
    rs = rounds(directory)
    if len(rs) != len(versions):
        fail(f"{len(rs)} rounds answered for {len(versions)} requests")
    bad, seen = [], []
    for k, (r, v) in enumerate(zip(rs, versions)):
        p = grab(r, r"patch +(?:built whole: (\d+) newest modules rewritten|from Lean (\S+):.*, rewritten (\d+))")
        m, named = check_lines(r)
        want = "built whole" if k == 0 else f"from Lean {versions[k - 1]}"
        said = None if p is None else ("built whole" if p.group(1) else f"from Lean {p.group(2)}")
        if p is None:
            bad.append(f"v{v}: no patch line")
        elif said != want:
            bad.append(f"v{v}: patch line says '{said}', expected '{want}'")
        elif m is None:
            bad.append(f"v{v}: no check-patch line")
        elif m.group(1) != "0" or m.group(2) != "0" or named:
            bad.append(f"v{v}: check-patch {m.group(1)} modules differ ({' '.join(named)}), {m.group(2)} other")
        elif r["code"] != 0:
            bad.append(f"v{v}: answered ok {r['code']}")
        else:
            seen.append(f"v{v} {said}, {p.group(1) or p.group(3)} rewritten, check-patch 0")
    if bad:
        fail("; ".join(bad))
    print("; ".join(seen))
elif mode == "reuse":
    directory, versions = args[0], args[1:]
    rs = rounds(directory)
    if len(rs) != len(versions):
        fail(f"{len(rs)} rounds answered for {len(versions)} requests")
    bad, seen = [], []
    for k, (r, v) in enumerate(zip(rs, versions)):
        u = grab(r, REUSE)
        a = grab(r, r"analyze +.* produced (\d+),")
        if u is None:
            bad.append(f"v{v}: no reuse line")
            continue
        if a is None:
            bad.append(f"v{v}: no analyze line")
            continue
        reused, produced, reprinted, differs, equal, noprev, new = (int(u.group(i)) for i in range(1, 8))
        analyzed = int(a.group(1))
        if reused + reprinted != analyzed or produced != analyzed:
            bad.append(f"v{v}: reused {reused} + reprinted {reprinted} of {produced}, the analysis produced {analyzed}")
        elif differs + equal + noprev + new != reprinted:
            bad.append(f"v{v}: reprinted {reprinted}, its reasons add up to {differs + equal + noprev + new}")
        elif equal != 0:
            bad.append(f"v{v}: {equal} declaration(s) whose key equals the previous round's were printed again")
        elif k == 0 and (reused != 0 or new != produced):
            bad.append(f"v{v}: round 1 reused {reused}, {new} of {produced} new")
        elif k > 0 and reused == 0:
            bad.append(f"v{v}: read after v{versions[k - 1]} and reused nothing ({reprinted} reprinted: key differs "
                       f"{differs}, no previous output {noprev}, new {new})")
        else:
            seen.append(f"v{v} reused {reused} of {produced}, reprinted {reprinted} (key differs {differs}, "
                        f"no previous output {noprev}, new {new}), key carried {u.group(10)}, recomputed "
                        f"{u.group(11)} in {u.group(14)} ms")
    if bad:
        fail("; ".join(bad))
    print("; ".join(seen))
elif mode == "scx":
    without, keyed, va, vb = args
    decl = "Example.ReaderProbe.withValue"
    rs = rounds(without)
    if len(rs) != 2 or [r["code"] for r in rs] != [0, 0]:
        fail(f"the session without SCX answered {[r['code'] for r in rs]}, expected two rounds ok 0")
    u = grab(rs[1], REUSE)
    if u is None or not u.group(8).startswith("N1 + own"):
        fail(f"the session without SCX printed no reuse line keyed N1 + own for v{vb}")
    alone = work / f"v{vb}" / "read" / "ir"
    stale = pathlib.Path(without) / f"v{vb}" / "ir"
    a, b = module_decls(alone), module_decls(stale)
    names = sorted(n for n in set(a) | set(b) if a.get(n) != b.get(n))
    files = differing_files(alone, stale)
    if names != [decl]:
        fail(f"without SCX, v{vb} patched from v{va} differs from read-alone in {names or 'no declaration'}, "
             f"not exactly {decl} (files: {files or 'none'})")
    sb, ab = b[decl].get("binders") or [], a[decl].get("binders") or []
    if not any(":= { }" in x for x in sb) or not any(":= { depth := 0 }" in x for x in ab):
        fail(f"without SCX {decl} prints {sb}, read-alone {ab}: not the stale default")
    kb = (module_decls(pathlib.Path(keyed) / f"v{vb}" / "ir").get(decl) or {}).get("binders") or []
    if kb != ab:
        fail(f"with SCX, v{vb}'s round prints {decl} {kb}, read-alone {ab}")
    print(f"without SCX v{vb} (patched from v{va}, {u.group(1)} reused) differs from read-alone in {decl} only: "
          f"{' '.join(sb)} against {' '.join(ab)} ({len(files)} file(s): {' '.join(files)}); "
          f"with SCX the round prints {' '.join(kb)}")
elif mode == "perturbed":
    directory = args[0]
    stderr = (pathlib.Path(directory) / "stderr.txt").read_text(encoding="utf-8")
    hits, bad = [], []
    for r in rounds(directory):
        p = grab(r, r"patch-perturbed +(\S+) left unrewritten")
        if p is None:
            continue
        module = p.group(1)
        m, named = check_lines(r)
        if r["code"] == 0:
            bad.append(f"round {r['n']}: {module} left unrewritten, and the round answered ok 0")
        elif module not in named:
            bad.append(f"round {r['n']}: {module} left unrewritten, check-patch names {named}")
        elif f"module {module} differs from rewriteMerge's" not in stderr:
            bad.append(f"round {r['n']}: the refusal does not name {module}")
        else:
            hits.append(f"round {r['n']}: {module} left unrewritten, refused naming it")
    if bad:
        fail("; ".join(bad))
    if not hits:
        fail("no round left a module unrewritten")
    print("; ".join(hits))
elif mode == "field-fn":
    disabled, enabled, module, va, vb = args
    flipped = []
    for v in (va, vb):
        text = (work / f"v{v}" / "read" / "stdout.txt").read_text(encoding="utf-8")
        m = re.search(r"default and autoParam functions of old structures' fields dropped (\d+)", text)
        if not m:
            fail(f"v{v}: read-alone reports no field functions dropped")
        flipped.append(int(m.group(1)))
    if abs(flipped[0] - flipped[1]) != 1:
        fail(f"read-alone drops {flipped[0]} field functions for v{va} and {flipped[1]} for v{vb}: "
             f"the probe structure is not dropped on exactly one of them")
    rs = rounds(disabled)
    if len(rs) != 2 or rs[0]["code"] != 0:
        fail(f"the session without the index answered {[r['code'] for r in rs]}, expected round 1 ok 0 and round 2")
    m, named = check_lines(rs[1])
    if rs[1]["code"] == 0 or module not in named:
        fail(f"without the index, v{vb} patched from v{va} answered ok {rs[1]['code']} and check-patch names "
             f"{named or 'no module'}, not {module}")
    on = rounds(enabled)[-1]
    m2, named2 = check_lines(on)
    p = grab(on, r"patch .* field functions (\d+);")
    if on["code"] != 0 or m2 is None or m2.group(1) != "0" or named2:
        fail(f"with the index, v{vb}'s round answered ok {on['code']}, check-patch names {named2}")
    if p is None or p.group(1) == "0":
        fail(f"with the index, v{vb}'s patch line rewrote no module for a field function")
    print(f"read-alone drops {flipped[0]} / {flipped[1]} field functions (v{va} / v{vb}); without the index "
          f"v{vb} answered ok {rs[1]['code']}, check-patch naming {' '.join(named)}; with it 0 differ, "
          f"{p.group(1)} module(s) rewritten for a field function")
elif mode == "check-keys":
    directory, versions = args[0], args[1:]
    rs = rounds(directory)
    if len(rs) != len(versions):
        fail(f"{len(rs)} rounds answered for {len(versions)} requests")
    bad, seen, carried_any = [], [], 0
    for k, (r, v) in enumerate(zip(rs, versions)):
        c = grab(r, CHECK_KEYS)
        u = grab(r, REUSE)
        f = grab(r, r"carry +(from the previous round|nothing to carry from)")
        named = [l.strip() for l in r["lines"] if l.startswith("  check-keys-differ ")]
        if c is None:
            bad.append(f"v{v}: no check-keys line")
        elif c.group(1) != "0" or named:
            bad.append(f"v{v}: check-keys {c.group(1)} keys differ: {'; '.join(named)[:600]}")
        elif u is None or f is None:
            bad.append(f"v{v}: no {'reuse' if u is None else 'carry'} line")
        else:
            candidates, carried, recomputed = int(u.group(9)), int(u.group(10)), int(u.group(11))
            from_previous = f.group(1) == "from the previous round"
            if carried + recomputed != candidates:
                bad.append(f"v{v}: carried {carried} + recomputed {recomputed} of {candidates} candidates")
            elif k == 0 and (from_previous or carried != 0):
                bad.append(f"v{v}: round 1 carried {carried} keys ({f.group(1)})")
            elif k > 0 and not from_previous:
                bad.append(f"v{v}: patched from v{versions[k - 1]}, and the carry line says '{f.group(1)}'")
            elif r["code"] != 0:
                bad.append(f"v{v}: answered ok {r['code']}")
            else:
                carried_any += carried
                seen.append(f"v{v} check-keys 0 of {c.group(2)} ({c.group(4)} ms), carried {carried}, "
                            f"recomputed {recomputed} ({u.group(14)} ms)")
    if not bad and carried_any == 0:
        bad.append("no round carried a key, so check-keys compared nothing carried")
    if bad:
        fail("; ".join(bad))
    print("; ".join(seen))
elif mode == "presence-flip":
    dropped, va, vb = args
    decl = "Example.ReaderProbe.shadowed"
    shadow = "Example.ReaderProbe.ReaderProbeTarget.val"
    def native_type(v):
        f = work / f"v{v}" / "native" / "ir" / "modules" / "Example.ReaderProbe.json"
        for d in json.loads(f.read_text(encoding="utf-8")).get("declarations", []):
            if d.get("name") == decl:
                return d.get("type")
        fail(f"v{v}: the native IR has no {decl}")
    ta, tb = native_type(va), native_type(vb)
    if ta == tb:
        fail(f"natively {decl} prints `{ta}` on both v{va} and v{vb}: the shadow changes no print")
    rs = rounds(dropped)
    if len(rs) != 2 or rs[0]["code"] != 0:
        fail(f"the session without presence flips answered {[r['code'] for r in rs]}, expected round 1 ok 0 and round 2")
    named = [l.strip()[len("check-keys-differ "):] for l in rs[1]["lines"] if l.startswith("  check-keys-differ ")]
    hit = [l for l in named if l.startswith(f"{decl}: ") and f"presence-flip {shadow} " in l]
    stderr = (pathlib.Path(dropped) / "stderr.txt").read_text(encoding="utf-8")
    if rs[1]["code"] == 0 or not hit:
        fail(f"without presence flips v{vb} answered ok {rs[1]['code']}, check-keys naming "
             f"{'; '.join(named)[:600] or 'nothing'}, not {decl} with a presence flip of {shadow}")
    if "check-keys failed" not in stderr or decl not in stderr:
        fail(f"the refusal does not name {decl}: {stderr[:300]}")
    print(f"natively {decl} prints `{ta}` (v{va}) and `{tb}` (v{vb}); without presence flips v{vb} answered "
          f"ok {rs[1]['code']}, {len(named)} key(s) differ: {hit[0]}"
          + (f"; also {'; '.join(n.split(':')[0] for n in named if n not in hit)}" if len(named) > len(hit) else ""))
else:
    fail(f"session_check: no mode {mode}")
PY
}

session_ready () {
  if [ "${NATIVE_OK[$NEWEST_I]}" != ok ]; then
    echo "the newest row's sample did not build, so there is no newest side"; return 1
  elif [ "${#session_missing[@]}" -ne 0 ]; then
    echo "the native side of ${session_missing[*]} did not build, so the session has no request for it"; return 1
  elif [ "${#SESSION_ROWS[@]}" -eq 0 ]; then
    echo "no older row is installed, so there is no session to run"; return 1
  fi
}

if why="$(session_ready)"; then
  run_session "$SESSION" --check-patch --check-keys -- "${SESSION_ROWS[@]}"
  sed -n 's/^rss  *//p; s/^\(patch \)  */\1/p; s/^check-patch  */check-patch /p; s/^\(carry \)  */\1/p;
          s/^check-keys  */check-keys /p; s/^\(reuse \)  */\1/p' "$SESSION/stdout.txt" | sed 's/^/  /'
fi

item=session-equals-alone
if ! why="$(session_ready)"; then
  bad "$item" "$why"
else
  replies=()
  while IFS= read -r l; do replies+=("$l"); done < <(grep -E '^(ok|err) ' "$SESSION/stdout.txt")
  lines=()
  fails=()
  session_rc="$(cat "$SESSION/rc")"
  if [ "$session_rc" != 0 ]; then fails+=("reader session exited $session_rc: $(head -c 300 "$SESSION/stderr.txt")"); fi
  for k in "${!SESSION_ROWS[@]}"; do
    v="${SESSION_ROWS[$k]}"
    reply="${replies[$k]:-}"
    if [ -z "$reply" ]; then
      fails+=("round $((k + 1)) (v$v) was never answered")
    elif [ "${reply%% *}" != ok ] || [ "$(printf '%s' "$reply" | cut -d' ' -f2)" != 0 ]; then
      fails+=("round $((k + 1)) (v$v) answered '$reply'")
    elif [ ! -d "$WORK/v$v/read/ir" ]; then
      fails+=("v$v has no read-alone IR to equal")
    elif ! /usr/bin/diff -r "$WORK/v$v/read/ir" "$SESSION/v$v/ir" >"$SESSION/v$v/ir.diff" 2>&1; then
      fails+=("v$v: the session's IR differs from read-alone: $(head -c 400 "$SESSION/v$v/ir.diff")")
    elif ! cmp -s "$WORK/v$v/read/links.lidx" "$SESSION/v$v/links.lidx"; then
      fails+=("v$v: the session's link index differs from read-alone")
    else
      lines+=("v$v $(find "$SESSION/v$v/ir" -type f | wc -l | tr -d ' ') files + link index")
    fi
  done
  if [ "${#replies[@]}" -ne "${#SESSION_ROWS[@]}" ]; then
    fails+=("${#replies[@]} replies to ${#SESSION_ROWS[@]} requests")
  fi
  if [ "${#fails[@]}" -eq 0 ] && ! summaries="$(session_check alone "$SESSION" "${SESSION_ROWS[@]}" 2>&1)"; then
    fails+=("$summaries")
  fi
  if [ "${#fails[@]}" -ne 0 ]; then
    bad "$item" "$(printf '%s; ' "${fails[@]}")"
  else
    ok "$item" "${#SESSION_ROWS[@]} rounds in one session, each equal to read-alone: $(printf '%s; ' "${lines[@]}")$summaries"
  fi
fi

item=session-check-patch
if ! why="$(session_ready)"; then
  bad "$item" "$why"
elif result="$(session_check check-patch "$SESSION" "${SESSION_ROWS[@]}" 2>&1)"; then
  ok "$item" "$result"
else
  bad "$item" "$result"
fi

item=session-reuse
if ! why="$(session_ready)"; then
  bad "$item" "$why"
elif result="$(session_check reuse "$SESSION" "${SESSION_ROWS[@]}" 2>&1)"; then
  ok "$item" "$result"
else
  bad "$item" "$result"
fi

item=session-manual-root
if ! why="$(session_ready)"; then
  bad "$item" "$why"
else
  lines=()
  fails=()
  roots=()
  for v in "${SESSION_ROWS[@]}"; do
    if [ ! -d "$SESSION/v$v/ir" ]; then fails+=("v$v: the session wrote no IR"); continue; fi
    if result="$(probe manual "$v" "$SESSION/v$v" 2>&1)"; then
      lines+=("${result% *}"); roots+=("${result##* }")
    else
      fails+=("$result")
    fi
  done
  distinct=$(printf '%s\n' "${roots[@]:-}" | sort -u | grep -c . || true)
  if [ "${#fails[@]}" -ne 0 ]; then
    bad "$item" "$(printf '%s; ' "${fails[@]}")"
  elif [ "$distinct" -ne "${#SESSION_ROWS[@]}" ]; then
    bad "$item" "${#SESSION_ROWS[@]} rounds link $distinct distinct manual roots: ${roots[*]}"
  else
    ok "$item" "$(printf '%s; ' "${lines[@]}")$distinct distinct roots"
  fi
fi

item=session-check-keys
if ! why="$(session_ready)"; then
  bad "$item" "$why"
elif result="$(session_check check-keys "$SESSION" "${SESSION_ROWS[@]}" 2>&1)"; then
  ok "$item" "$result"
else
  bad "$item" "$result"
fi

say
say "=== the older rows in one reader session --no-patch: every round built whole, keys fresh, reuse kept"
item=no-patch-equals-alone
NOPATCH="$WORK/session-no-patch"
if ! why="$(session_ready)"; then
  bad "$item" "$why"
elif [ "${#SESSION_ROWS[@]}" -lt 2 ]; then
  bad "$item" "fewer than two older rows, so no round reuses"
else
  run_session "$NOPATCH" --no-patch -- "${SESSION_ROWS[@]}"
  sed -n 's/^rss  *//p; s/^\(reuse \)  */\1/p' "$NOPATCH/stdout.txt" | sed 's/^/  /'
  replies=()
  while IFS= read -r l; do replies+=("$l"); done < <(grep -E '^(ok|err) ' "$NOPATCH/stdout.txt")
  lines=()
  fails=()
  nopatch_rc="$(cat "$NOPATCH/rc")"
  if [ "$nopatch_rc" != 0 ]; then fails+=("reader session --no-patch exited $nopatch_rc: $(head -c 300 "$NOPATCH/stderr.txt")"); fi
  if grep -qE '^(patch|carry) ' "$NOPATCH/stdout.txt"; then
    fails+=("a round printed a patch or carry line: $(grep -m 1 -E '^(patch|carry) ' "$NOPATCH/stdout.txt" | head -c 200)")
  fi
  for k in "${!SESSION_ROWS[@]}"; do
    v="${SESSION_ROWS[$k]}"
    reply="${replies[$k]:-}"
    if [ -z "$reply" ]; then
      fails+=("round $((k + 1)) (v$v) was never answered")
    elif [ "${reply%% *}" != ok ] || [ "$(printf '%s' "$reply" | cut -d' ' -f2)" != 0 ]; then
      fails+=("round $((k + 1)) (v$v) answered '$reply'")
    elif [ ! -d "$WORK/v$v/read/ir" ]; then
      fails+=("v$v has no read-alone IR to equal")
    elif ! /usr/bin/diff -r "$WORK/v$v/read/ir" "$NOPATCH/v$v/ir" >"$NOPATCH/v$v/ir.diff" 2>&1; then
      fails+=("v$v: the --no-patch round's IR differs from read-alone: $(head -c 400 "$NOPATCH/v$v/ir.diff")")
    elif ! cmp -s "$WORK/v$v/read/links.lidx" "$NOPATCH/v$v/links.lidx"; then
      fails+=("v$v: the --no-patch round's link index differs from read-alone")
    else
      lines+=("v$v $(find "$NOPATCH/v$v/ir" -type f | wc -l | tr -d ' ') files + link index")
    fi
  done
  if [ "${#replies[@]}" -ne "${#SESSION_ROWS[@]}" ]; then
    fails+=("${#replies[@]} replies to ${#SESSION_ROWS[@]} requests")
  fi
  if [ "${#fails[@]}" -eq 0 ] && ! summaries="$(session_check alone "$NOPATCH" "${SESSION_ROWS[@]}" 2>&1)"; then
    fails+=("$summaries")
  fi
  if [ "${#fails[@]}" -eq 0 ] && ! reuse="$(session_check reuse "$NOPATCH" "${SESSION_ROWS[@]}" 2>&1)"; then
    fails+=("$reuse")
  fi
  if [ "${#fails[@]}" -ne 0 ]; then
    bad "$item" "$(printf '%s; ' "${fails[@]}")"
  else
    ok "$item" "${#SESSION_ROWS[@]} rounds, each equal to read-alone: $(printf '%s; ' "${lines[@]}")$summaries; $reuse"
  fi
fi

say
say "=== the older rows read alone again, each theorem's proof decoded only where the run reads it"
item=lazy-proofs-equals-alone
if ! why="$(session_ready)"; then
  bad "$item" "$why"
else
  lines=()
  fails=()
  for v in "${SESSION_ROWS[@]}"; do
    out="$WORK/v$v/lazy"
    if ! read_through "$v" "$out" --lazy-proofs; then
      fails+=("v$v: reader extract --lazy-proofs exited non-zero: $(head -c 300 "$out/stderr.txt")")
    elif [ ! -d "$WORK/v$v/read/ir" ]; then
      fails+=("v$v has no read-alone IR to equal")
    elif ! /usr/bin/diff -r "$WORK/v$v/read/ir" "$out/ir" >"$out/ir.diff" 2>&1; then
      fails+=("v$v: the --lazy-proofs IR differs from read-alone in $({ /usr/bin/diff -rq "$WORK/v$v/read/ir" "$out/ir" || true; } | sed "s|$out/ir/||; s|$WORK/v$v/read/ir/||g" | tr '\n' ' ' | head -c 400)")
    elif ! cmp -s "$WORK/v$v/read/links.lidx" "$out/links.lidx"; then
      fails+=("v$v: the --lazy-proofs link index differs from read-alone")
    elif ! inv="$(invariants "$out/stdout.txt" 2>&1)"; then
      fails+=("v$v: $inv")
    elif ! counts="$(python3 - "$out/stdout.txt" "$WORK/v$v/read/stdout.txt" <<'PY'
import re, sys
lazy, full = (open(p, encoding="utf-8").read() for p in sys.argv[1:])
m = re.search(r"^proofs +decoded (\d+) of (\d+) theorems' proofs; the rule decodes those with no stored "
              r"axiom list \((\d+)\) or one holding sorryAx \((\d+)\); omitted (\d+)$", lazy, re.M)
if not m:
    sys.exit("no proofs line")
decoded, theorems, unlisted, sorry, omitted = (int(g) for g in m.groups())
refs = lambda t: int(re.search(r"^invariants +closure: \d+ constants, (\d+) references checked", t, re.M).group(1))
if decoded != unlisted + sorry or decoded + omitted != theorems:
    sys.exit(f"decoded {decoded} of {theorems} theorems, the rule decodes {unlisted} + {sorry}; omitted {omitted}")
if omitted == 0:
    sys.exit(f"no proof omitted of {theorems} theorems, so nothing lazy was compared")
if sorry == 0:
    sys.exit(f"no proof decoded for sorryAx, so the sample's sorry was not read through the rule")
print(f"decoded {decoded} of {theorems} (no list {unlisted}, sorryAx {sorry}), omitted {omitted}; "
      f"closure references {refs(lazy)} against read-alone's {refs(full)}")
PY
)"; then
      fails+=("v$v: $counts")
    else
      lines+=("v$v $(find "$out/ir" -type f | wc -l | tr -d ' ') files + link index, $counts")
    fi
  done
  if [ "${#fails[@]}" -ne 0 ]; then
    bad "$item" "$(printf '%s; ' "${fails[@]}")"
  else
    ok "$item" "${#SESSION_ROWS[@]} rows, each equal to read-alone: $(printf '%s; ' "${lines[@]}")"
  fi
fi

item=manual-root-cache
if ! why="$(session_ready)"; then
  bad "$item" "$why"
else
  if result="$(python3 - "$(dirname "$READER")/manual-roots" "$WORK" "${SESSION_ROWS[@]}" 2>&1 <<'PY'
import pathlib, re, sys
cache, work, rows = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3:]
def line(path):
    text = path.read_text(encoding="utf-8")
    m = re.search(r"^  manual-root-cache  (.*)$", text, re.M)
    g = re.search(r"^reader +Lean \S+ \((\w+)\)", text, re.M)
    return (m.group(1) if m else "no manual-root-cache line"), (g.group(1) if g else None)
fails = []
for v in rows:
    first, githash = line(work / f"v{v}" / "read" / "stdout.txt")
    second, _ = line(work / f"v{v}" / "lazy" / "stdout.txt")
    if githash is None:
        fails.append(f"v{v}: its first read names no githash")
        continue
    entry = cache / githash
    if not re.fullmatch(rf"asked \S+ in \d+ ms, kept in {re.escape(str(entry))}", first):
        fails.append(f"v{v}: the first read says '{first}', not asked and kept in {entry}")
    elif second != f"read from {entry}":
        fails.append(f"v{v}: the second read says '{second}', not read from {entry}")
if fails:
    sys.exit("; ".join(fails))
print(f"{len(rows)} rows: each asked its toolchain once, kept under manual-roots/<its githash>, "
      f"and its second read took it from there")
PY
)"; then
    ok "$item" "$result"
  else
    bad "$item" "$result"
  fi
fi

say
say "=== the older rows read alone again, each reusing the printed parts of its own earlier output"
item=reuse-self-equals-alone
if ! why="$(session_ready)"; then
  bad "$item" "$why"
else
  lines=()
  fails=()
  for v in "${SESSION_ROWS[@]}"; do
    keys="$WORK/v$v/keys"
    out="$WORK/v$v/reuse"
    if ! read_through "$v" "$keys" --write-reuse-keys; then
      fails+=("v$v: reader extract --write-reuse-keys exited non-zero: $(head -c 300 "$keys/stderr.txt")")
    elif [ ! -d "$WORK/v$v/read/ir" ]; then
      fails+=("v$v has no read-alone IR to equal")
    elif ! /usr/bin/diff -r "$WORK/v$v/read/ir" "$keys/ir" >"$keys/ir.diff" 2>&1 ||
         ! cmp -s "$WORK/v$v/read/links.lidx" "$keys/links.lidx"; then
      fails+=("v$v: writing the reuse keys changed the IR or the link index: $(head -c 300 "$keys/ir.diff")")
    elif [ ! -s "$keys/ir.reuse-keys" ]; then
      fails+=("v$v: --write-reuse-keys wrote no $keys/ir.reuse-keys")
    elif ! read_through "$v" "$out" --reuse-from "$keys/ir"; then
      fails+=("v$v: reader extract --reuse-from exited non-zero: $(head -c 300 "$out/stderr.txt")")
    elif ! /usr/bin/diff -r "$WORK/v$v/read/ir" "$out/ir" >"$out/ir.diff" 2>&1; then
      fails+=("v$v: the --reuse-from IR differs from read-alone in $({ /usr/bin/diff -rq "$WORK/v$v/read/ir" "$out/ir" || true; } | sed "s|$out/ir/||; s|$WORK/v$v/read/ir/||g" | tr '\n' ' ' | head -c 400)")
    elif ! cmp -s "$WORK/v$v/read/links.lidx" "$out/links.lidx"; then
      fails+=("v$v: the --reuse-from link index differs from read-alone")
    elif ! cmp -s "$keys/ir.reuse-keys" "$out/ir.reuse-keys"; then
      fails+=("v$v: the --reuse-from run wrote other keys than the run it reused")
    elif ! counts="$(python3 - "$out/stdout.txt" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^reuse-from +\S+: (\d+) of (\d+) declarations reused, (\d+) printed \((.*)\); "
              r"printing identity (equal|differs)", text, re.M)
if not m:
    sys.exit("no reuse-from line")
reused, produced, printed = (int(g) for g in m.groups()[:3])
if m.group(5) != "equal":
    sys.exit("the printing identity differs from the run's own")
if produced == 0:
    sys.exit("0 declarations produced, so nothing was reused")
if reused != produced or printed != 0:
    sys.exit(f"{reused} of {produced} reused, {printed} printed ({m.group(4)})")
print(f"{reused} of {produced} declarations reused, 0 printed")
PY
)"; then
      fails+=("v$v: $counts")
    else
      lines+=("v$v $(find "$out/ir" -type f | wc -l | tr -d ' ') files + link index, $counts")
    fi
  done
  if [ "${#fails[@]}" -ne 0 ]; then
    bad "$item" "$(printf '%s; ' "${fails[@]}")"
  else
    ok "$item" "${#SESSION_ROWS[@]} rows, each equal to read-alone: $(printf '%s; ' "${lines[@]}")"
  fi
fi

say
say "=== the patch made to fail"
FIRST_PAIR=()
LAST_PAIR=()
if [ "${#SESSION_ROWS[@]}" -ge 2 ]; then
  FIRST_PAIR=("${SESSION_ROWS[@]:0:2}")
  LAST_PAIR=("${SESSION_ROWS[@]: -2}")
fi

item=patch-perturbed
if ! why="$(session_ready)"; then
  bad "$item" "$why"
elif [ "${#FIRST_PAIR[@]}" -ne 2 ]; then
  bad "$item" "fewer than two older rows, so no round is patched"
else
  run_session "$WORK/session-perturbed" --check-patch --perturb-patch -- "${FIRST_PAIR[@]}"
  if result="$(session_check perturbed "$WORK/session-perturbed" 2>&1)"; then
    ok "$item" "--perturb-patch: $result"
  else
    bad "$item" "--perturb-patch: $result"
  fi
fi

item=patch-field-fn-trigger
if ! why="$(session_ready)"; then
  bad "$item" "$why"
elif [ "${#LAST_PAIR[@]}" -ne 2 ]; then
  bad "$item" "fewer than two older rows, so no round is patched"
else
  run_session "$WORK/session-no-field-fn" --check-patch --no-field-fn-index -- "${LAST_PAIR[@]}"
  if result="$(session_check field-fn "$WORK/session-no-field-fn" "$SESSION" Example.ReaderProbeField "${LAST_PAIR[@]}" 2>&1)"; then
    ok "$item" "$result"
  else
    bad "$item" "$result"
  fi
fi

say
say "=== the print key without what structure-instance notation reads of field defaults"
item=reuse-scx
if ! why="$(session_ready)"; then
  bad "$item" "$why"
elif [ "${#LAST_PAIR[@]}" -ne 2 ]; then
  bad "$item" "fewer than two older rows, so no round reuses"
else
  run_session "$WORK/session-n1" --check-patch --key-without-scx -- "${LAST_PAIR[@]}"
  sed -n 's/^\(reuse \)  */\1/p' "$WORK/session-n1/stdout.txt" | sed 's/^/  /'
  if result="$(session_check scx "$WORK/session-n1" "$SESSION" "${LAST_PAIR[@]}" 2>&1)"; then
    ok "$item" "$result"
  else
    bad "$item" "$result"
  fi
fi

say
say "=== the carried key made to fail: a name resolution carried past a presence flip"
item=carry-presence-flip
if ! why="$(session_ready)"; then
  bad "$item" "$why"
elif [ "${#FIRST_PAIR[@]}" -ne 2 ]; then
  bad "$item" "fewer than two older rows, so no key is carried"
else
  run_session "$WORK/session-no-presence" --check-patch --check-keys --carry-without-presence -- "${FIRST_PAIR[@]}"
  if result="$(session_check presence-flip "$WORK/session-no-presence" "${FIRST_PAIR[@]}" 2>&1)"; then
    ok "$item" "$result"
  else
    bad "$item" "$result"
  fi
fi

say
say "=== the flags the hybrid refuses"
for flag in "${REFUSED[@]}"; do
  item="refuse-${flag#--}"
  if [ "${NATIVE_OK[$NEWEST_I]}" != ok ]; then
    bad "$item" "the newest row's sample did not build, so there is no command line to refuse"
    continue
  fi
  out="$WORK/refuse${flag}"
  extra=("$flag")
  if [ "$flag" = --dump-tactics ]; then extra+=("$out/tactics.txt"); fi
  if read_through "$NEWEST" "$out" "${extra[@]}"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 2 ]; then
    bad "$item" "reader extract $flag exited $rc, a refusal exits 2"
  elif ! grep -qF -- "$flag is refused" "$out/stderr.txt"; then
    bad "$item" "the refusal does not name $flag: $(head -c 300 "$out/stderr.txt")"
  elif [ -e "$out/ir" ] || [ -e "$out/events.jsonl" ]; then
    bad "$item" "refused, but it wrote output first"
  else
    ok "$item" "$(head -c 300 "$out/stderr.txt")"
  fi
done

# usage: corrupt <dangling|ilean|ilean-imported|ilean-imported-unequal|ilean-unknown>
#          <pristine lib dir> <shadow dir> <the newest toolchain's lib/lean>
#   prints what it changed, then on a line of its own the refusal it predicts
corrupt () {
  python3 - "$@" <<'PY'
import json, pathlib, shutil, struct, sys

kind, lib, shadow = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
(shadow / "Example").mkdir(parents=True, exist_ok=True)

def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]

def name(b, base, v):
    parts = []
    while v != 1:
        o = v - base
        if b[o + 7] != 1:
            sys.exit(f"a Name component at 0x{v:x} is not a string (tag {b[o + 7]})")
        s = u64(b, o + 16) - base
        parts.append(bytes(b[s + 32:s + 32 + u64(b, s + 8) - 1]).decode())
        v = u64(b, o + 8)
    return list(reversed(parts))

if kind == "dangling":
    src, dst = lib / "Example" / "Dep.olean", shadow / "Example" / "Dep.olean"
    b = bytearray(src.read_bytes())
    base = u64(b, 80)
    imports = u64(b, u64(b, 88) - base + 8) - base
    n = u64(b, imports + 8)
    names = [name(b, base, u64(b, u64(b, imports + 24 + 8 * i) - base + 8)) for i in range(n)]
    hits = [i for i, nm in enumerate(names) if nm == ["Dep-Aux", "Basic"]]
    if len(hits) != 1:
        sys.exit(f"Example.Dep imports {names}; expected exactly one «Dep-Aux».Basic")
    i = hits[0]
    rest = b[imports + 24 + 8 * (i + 1):imports + 24 + 8 * n]
    b[imports + 24 + 8 * i:imports + 24 + 8 * (n - 1)] = rest
    struct.pack_into("<Q", b, imports + 8, n - 1)
    dst.write_bytes(bytes(b))
    shutil.copyfile(lib / "Example" / "Dep.ilean", shadow / "Example" / "Dep.ilean")
    print(f"Example.Dep imports {['.'.join(x) for x in names]}; «Dep-Aux».Basic (entry {i}) removed")
    print("module Example.Dep: Example.usesDep mentions DepAux.marker, which no module of Lean")
else:
    shutil.copyfile(lib / "Example" / "Basic.olean", shadow / "Example" / "Basic.olean")
    j = json.loads((lib / "Example" / "Basic.ilean").read_text(encoding="utf-8"))
    if not j["decls"]:
        sys.exit("Example/Basic.ilean lists no declarations")
    if kind == "ilean":
        first = sorted(j["decls"])[0]
        before = list(j["decls"][first])
        j["decls"][first][2] += 1
        print(f"{first}: {before} -> {j['decls'][first]}")
        print(f"module Example.Basic: {first}'s range is {j['decls'][first]} in Basic.ilean and {before} decoded from its .olean")
    elif kind in ("ilean-imported", "ilean-imported-unequal"):
        if "Nat" in j["decls"]:
            sys.exit("Example/Basic.ilean already lists Nat")
        prelude = json.loads((pathlib.Path(sys.argv[4]) / "Init" / "Prelude.ilean").read_text(encoding="utf-8"))
        nat = list(prelude["decls"]["Nat"])
        j["decls"]["Nat"] = list(nat)
        if kind == "ilean-imported":
            print(f"Nat listed at {nat}, its range in Init/Prelude.ilean")
            print("ilean-imported 1")
        else:
            j["decls"]["Nat"][2] += 1
            print(f"Nat listed at {j['decls']['Nat']}, Init/Prelude.ilean gives {nat}")
            print(f"module Example.Basic: Nat's range is {j['decls']['Nat']} in Basic.ilean and {nat} decoded from the .olean that declares it")
    elif kind == "ilean-unknown":
        bogus = "Example.noSuchDeclaration"
        j["decls"][bogus] = list(next(iter(j["decls"].values())))
        print(f"{bogus} listed at {j['decls'][bogus]}")
        print(f"module Example.Basic: Basic.ilean lists {bogus}, and no .olean of the closure has a declaration range for {bogus}")
    else:
        sys.exit(f"corrupt: no kind {kind}")
    (shadow / "Example" / "Basic.ilean").write_text(json.dumps(j), encoding="utf-8")
PY
}

say
say "=== the invariants refusing a corrupted copy"
LIB="$WORK/v$NEWEST/micro/.lake/build/lib/lean"
CORE="$TOOLCHAINS/$(printf '%s' "${ROWS[$NEWEST_I]}" | sed 's|/|--|; s|:|---|')/lib/lean"
for kind in dangling ilean ilean-imported-unequal ilean-unknown; do
  item="refuse-${kind%-unequal}"
  if [ "${NATIVE_OK[$NEWEST_I]}" != ok ]; then
    bad "$item" "the newest row's sample did not build, so there is nothing to corrupt"
    continue
  fi
  out="$WORK/refuse-$kind"
  if ! made="$(corrupt "$kind" "$LIB" "$out/shadow" "$CORE" 2>&1)"; then
    bad "$item" "the corrupted copy could not be made: $made"
    continue
  fi
  want="reader extract: invariant failed, Lean $NEWEST is not read: $(printf '%s\n' "$made" | sed -n 2p)"
  made="$(printf '%s\n' "$made" | sed -n 1p)"
  if read_through "$NEWEST" "$out" --shadow "$out/shadow"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne 1 ]; then
    bad "$item" "reader extract exited $rc on the copy ($made), an invariant refusal exits 1"
    excerpt "$out/stderr.txt"
  elif ! grep -qF -- "$want" "$out/stderr.txt"; then
    bad "$item" "the refusal is not the one expected ($want): $(head -c 400 "$out/stderr.txt")"
  elif [ -e "$out/ir" ] || [ -e "$out/events.jsonl" ]; then
    bad "$item" "refused, but it wrote output first"
  else
    ok "$item" "$made: $(head -c 400 "$out/stderr.txt")"
  fi
done

item=accept-ilean-imported
out="$WORK/accept-ilean-imported"
if [ "${NATIVE_OK[$NEWEST_I]}" != ok ]; then
  bad "$item" "the newest row's sample did not build, so there is nothing to copy"
elif ! made="$(corrupt ilean-imported "$LIB" "$out/shadow" "$CORE" 2>&1)"; then
  bad "$item" "the copy could not be made: $made"
else
  want="$(printf '%s\n' "$made" | sed -n 2p)"
  made="$(printf '%s\n' "$made" | sed -n 1p)"
  if read_through "$NEWEST" "$out" --shadow "$out/shadow"; then rc=0; else rc=$?; fi
  seen="$(sed -n 's/^  ilean-imported  *\([0-9][0-9]*\) .*/ilean-imported \1/p' "$out/stdout.txt")"
  if [ "$rc" -ne 0 ]; then
    bad "$item" "reader extract exited $rc on the copy ($made): $(head -c 400 "$out/stderr.txt")"
  elif [ "$seen" != "$want" ]; then
    bad "$item" "read, but the summary says '${seen:-no ilean-imported line}', not '$want' ($made)"
  else
    ok "$item" "$made: read, $seen"
  fi
fi

say
say "=== summary"
say "items reported : $ran of $declared"
say "failed         : $failed"
if [ "$failed" -ne 0 ]; then
  say "READER HYBRID GATE: FAILED ($failed of $ran answered items)" >&2
  answer 1
fi
if [ "$ran" -ne "$declared" ]; then
  say "READER HYBRID GATE: $ran of $declared items answered -- the rest were not asked, which is not a pass" >&2
  answer 2
fi
say "READER HYBRID GATE: ok ($ran of $declared)"
answer 0
