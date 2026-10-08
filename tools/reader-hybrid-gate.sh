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
#                     function
#
# The sample in e2e/micro is not changed: Example.ReaderProbe is written into
# each row's copy only.
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
declared=$(( 2 * ${#ROWS[@]} + 1 + ${#REFUSED[@]} + 5 + 2 ))

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

probe_module () {
  local override=""
  if [ "$1" = "$NEWEST" ]; then override=$' where\n  depth := 1'; fi
  cat <<EOF
namespace Example.ReaderProbe

/-- The manual's [macro section](lean-manual://section/tactic-macro-extension). -/
def manualLinked : Nat := 0

structure Base where
  depth : Nat := 0

structure Cheap extends Base$override

def withDefault (c : Cheap := { }) : Nat := c.depth

end Example.ReaderProbe
EOF
}

native () {
  local v="$1" dir="$WORK/v$1" exe
  mkdir -p "$dir/native"
  cp -R "$ROOT/e2e/micro" "$ROOT/e2e/micro-dep" "$dir/"
  rm -rf "$dir/micro/.lake" "$dir/micro-dep/.lake"
  probe_module "$v" >"$dir/micro/Example/ReaderProbe.lean"
  { echo "import Example.ReaderProbe"; cat "$ROOT/e2e/micro/Example.lean"; } >"$dir/micro/Example.lean"
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

# usage: read_through <version> <out> [--shadow <dir>] [extractor flags...]
#   --shadow  a search directory put before the version's own, for a corrupted copy
read_through () {
  local v="$1" out="$2" args=()
  shift 2
  if [ "${1:-}" = --shadow ]; then args+=(--old "$2"); shift 2; fi
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
  elif why="$(native "$v")"; then
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

probe () {
  python3 - "$1" "$2" "$WORK/v$2/native/ir" "$WORK/v$2/read/ir" "$WORK/v$2/read/stdout.txt" <<'PY'
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
    print(f"v{v} links {own}")
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
    if result="$(probe "$kind" "$v" 2>&1)"; then lines+=("$result"); else fails+=("$result"); fi
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
