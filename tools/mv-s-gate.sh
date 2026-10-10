#!/usr/bin/env bash
# The S loop of the multi-version plan (docs/multiversion/implementation.md,
# "Measurement loop") from nothing: tools/mv-s/ generated as five versions, the
# first four each built and put into a store, then read back, judged fresh, stale
# or needing a re-put, laid out by the three storage candidates, and rendered as a
# site by `store render` — answered by counters, names and bytes against
# tools/mv-s/expected.txt, never by a duration. Then `build --versions` over all
# five (v5 is v4 on another toolchain) into a store of its own, which has to agree
# with the hand-driven one, re-extract exactly what is missing or stale, and
# render only the versions its site does not hold, into the site rendered from nothing.
#
# Each check prints `ok|FAIL <item>: <what>`; every declared item has to report
# exactly once, so one that never ran fails the gate as surely as one that did.
# The flow runs twice, the second time in another directory, and the two stores
# have to be byte-identical. Per-phase wall and CPU time are printed, not judged.
#
# The work directory is this gate's: it deletes it before it starts and after a
# run that passed (unless --keep); after a failure it is left for reading.
#
# usage: tools/mv-s-gate.sh [--out DIR] [--extractor BIN] [--keep]
#   --out        the work directory (default: /private/tmp/lean-doc-relay/mv-s-gate),
#                absent, empty, or one this gate made
#   --extractor  a prebuilt extractor (default: built into e2e/micro/.lake/e2e-extract,
#                the one tools/e2e-micro.sh builds and reuses)
#   --keep       keep the work directory after a run that passed; its
#                run1/render/all-1 and run1/render/hash-1 are what
#                tools/mv-pages-gate.sh --from reads
#   LITEDOC4 / LAKE  the binaries (default: .lake/build/bin/litedoc4, ~/.elan/bin/lake)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
answer_required

LAKE="${LAKE:-$HOME/.elan/bin/lake}"
LITEDOC4="${LITEDOC4:-$ROOT/.lake/build/bin/litedoc4}"
EXPECTED="$HERE/mv-s/expected.txt"
VERSIONS=(v1 v2 v3 v4)
CANDIDATES=(a b c)
WORK=/private/tmp/lean-doc-relay/mv-s-gate
EXTRACTOR=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) WORK="$2"; shift 2 ;;
    --extractor) EXTRACTOR="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d'; answer 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
case "$WORK" in /*) ;; *) WORK="$PWD/$WORK" ;; esac

command -v "$LAKE" >/dev/null 2>&1 || { echo "no lake at $LAKE; set LAKE" >&2; exit 2; }
[ -x "$LITEDOC4" ] || {
  echo "no litedoc4 at $LITEDOC4; tools/build-lean-exe.sh --toolchain-from e2e/micro" >&2; exit 2; }

MARK=.mv-s-gate
if [ -e "$WORK" ] && [ ! -f "$WORK/$MARK" ] && [ -n "$(ls -A "$WORK")" ]; then
  echo "$WORK is not empty and is not a work directory of this gate; refusing to delete it" >&2
  exit 2
fi
rm -rf "$WORK"
mkdir -p "$WORK/logs"
touch "$WORK/$MARK"
PASSED=0
on_exit 'if [ "$PASSED" -eq 0 ]; then echo "work directory left for reading at $WORK" >&2; elif [ "$KEEP" -eq 1 ]; then echo "work directory kept at $WORK"; else rm -rf "$WORK"; fi'

LOGS="$WORK/logs"
TIMES="$WORK/times.txt"
R1="$WORK/run1"
R2="$WORK/run2"
STARTED=$SECONDS
TIMEFORMAT='%R %U %S'

say () { printf '\n=== %s\n' "$1"; }

timed () {
  local label="$1" out="$2" rc=0
  shift 2
  { time "$@" >"$out" 2>"$out.err"; } 2>"$WORK/.time" || rc=$?
  printf '%-26s %s\n' "$label" "$(tail -n 1 "$WORK/.time")" >>"$TIMES"
  if [ "$rc" -ne 0 ]; then
    echo "$label: exited $rc; the end of $out.err and $out:" >&2
    tail -n 15 "$out.err" "$out" >&2
  fi
  return "$rc"
}

in_dir () {
  local dir="$1"
  shift
  ( cd "$dir" && "$@" )
}

flow () {
  local run="$1" dir="$2" again="$3" v
  timed "$run generate" "$LOGS/$run-generate.log" "$HERE/mv-s/generate.sh" --out "$dir/repo"
  for v in "${VERSIONS[@]}"; do
    git -C "$dir/repo" -c advice.detachedHead=false checkout -q "$v"
    timed "$run $v lake build" "$LOGS/$run-lake-$v.log" in_dir "$dir/repo" "$LAKE" build
    timed "$run $v litedoc4 build" "$LOGS/$run-build-$v.log" \
      "$LITEDOC4" build --root "$dir/repo" --lib Example --out "$dir/build/$v" \
      --extractor-bin "$EXTRACTOR"
    timed "$run $v store put" "$LOGS/$run-put-$v.log" \
      "$LITEDOC4" store put --store "$dir/store" --version "$v" --from "$dir/build/$v"
    if [ "$again" -eq 1 ]; then
      timed "$run $v store put again" "$LOGS/$run-put-again-$v.log" \
        "$LITEDOC4" store put --store "$dir/store-again" --version "$v" --from "$dir/build/$v"
    fi
  done
}

PAIRS=()
for i in $(seq 1 $((${#VERSIONS[@]} - 1))); do
  PAIRS+=("${VERSIONS[$((i - 1))]}..${VERSIONS[$i]}")
done
DECLARED=(oracle-v1 oracle-rows source-map fresh stale needs-re-put agree second-run)
for v in "${VERSIONS[@]}"; do DECLARED+=("round-trip-$v" "re-put-$v"); done
for c in "${CANDIDATES[@]}"; do DECLARED+=("measure-repeat-$c" "new-addresses-$c"); done
for p in "${PAIRS[@]}"; do DECLARED+=("new-items-$p" "a-files-$p" "b-segments-$p"); done
DECLARED+=(render-twice render-sharing render-counts render-citation render-front)
DECLARED+=(render-hash-twice render-hash-counts)
DECLARED+=(render-usedby render-closure render-content-ir render-summaries render-math render-references render-sources)
DECLARED+=(loop-empty loop-render-same loop-again loop-toolchain loop-remove-one loop-identity)
DECLARED+=(loop-render-drop loop-render-add loop-render-hash loop-render-missing)
for v in "${VERSIONS[@]}"; do DECLARED+=("render-alone-$v" "render-hash-alone-$v"); done

RAN=()
FAILED=0
item () {
  printf '%s %s: %s\n' "$1" "$2" "$3"
  RAN+=("$2")
  if [ "$1" != ok ]; then FAILED=$((FAILED + 1)); fi
}

say "1/8 the extractor (built once, in e2e/micro's environment)"
if [ -z "$EXTRACTOR" ]; then
  EXTRACTOR="$(micro_extractor "$ROOT" "$ROOT/e2e/micro" "$LAKE" "$LOGS/extractor-build.log")"
fi
[ -x "$EXTRACTOR" ] || { echo "no extractor at $EXTRACTOR" >&2; exit 1; }
echo "$EXTRACTOR"

say "2/8 run 1: generate S, then build and put each version (twice)"
flow run1 "$R1" 1
"$LITEDOC4" store list --store "$R1/store"

say "3/8 the store: oracle, read-back, re-put, staleness"
want_v1="$(sed -n 's/.*Derived against v1 = \([0-9a-f]\{40\}\).*/\1/p' "$EXPECTED")"
have_v1="$(git -C "$R1/repo" rev-parse v1)"
if [ -z "$want_v1" ]; then
  item FAIL oracle-v1 "expected.txt names no v1 commit"
elif [ "$want_v1" != "$have_v1" ]; then
  item FAIL oracle-v1 "expected.txt was derived against v1 = $want_v1 and S's v1 is $have_v1: the sample changed, every expected row is unchecked against it"
else
  item ok oracle-v1 "S's v1 is $have_v1, the commit expected.txt was derived against"
fi

mkdir -p "$R1/read"
for v in "${VERSIONS[@]}"; do
  got="$R1/read/$v"
  if ! timed "read $v" "$LOGS/read-$v.log" \
      "$LITEDOC4" store read --store "$R1/store" --version "$v" --out "$got"; then
    item FAIL "round-trip-$v" "store read refused: $(tail -n 1 "$LOGS/read-$v.log.err")"
  elif ! /usr/bin/diff -r "$R1/build/$v/ir" "$got/ir" >"$LOGS/round-trip-$v.diff" 2>&1; then
    item FAIL "round-trip-$v" "ir/ read back differs from the build's ($LOGS/round-trip-$v.diff)"
  elif ! cmp -s "$R1/build/$v/link-index.lidx" "$got/link-index.lidx"; then
    item FAIL "round-trip-$v" "link-index.lidx read back differs from the build's"
  else
    item ok "round-trip-$v" "ir/ ($(find "$got/ir" -type f | wc -l | tr -d ' ') files) and link-index.lidx byte-identical to the build"
  fi
done

for v in "${VERSIONS[@]}"; do
  differs=""
  for f in entry.pack.gz record.json; do
    if ! cmp -s "$R1/store/$v/$f" "$R1/store-again/$v/$f"; then differs="$differs $f"; fi
  done
  if [ -n "$differs" ]; then
    item FAIL "re-put-$v" "putting the same build twice gave different$differs"
  else
    item ok "re-put-$v" "putting the same build twice gave identical entry.pack.gz and record.json"
  fi
done

sources="$(python3 - "$R1/store" "${VERSIONS[@]}" 2>&1 <<'PY'
import json
import pathlib
import sys

store = pathlib.Path(sys.argv[1])
bad = []
for v in sys.argv[2:]:
    r = json.loads((store / v / "record.json").read_text(encoding="utf-8"))
    core = "https://github.com/leanprover/lean4/blob/%s/" % r["leanGithash"]
    want = [["Dep-Aux", None], ["Init", core + "src"], ["Lake", core + "src/lake"],
            ["Lean", core + "src"], ["Std", core + "src"]]
    if (r.get("recordSchema") != 5 or r.get("sources") != want or r.get("title") != "litedoc4 sample"
            or "reusedFrom" not in r or r["reusedFrom"] is not None):
        bad.append("%s: schema %s, sources %s, title %r, reusedFrom %r" % (
            v, r.get("recordSchema"), r.get("sources"), r.get("title"), r.get("reusedFrom", "<absent>")))
print("; ".join(bad) if bad else "ok")
PY
)" || true
if [ "$sources" = ok ]; then
  item ok source-map "all ${#VERSIONS[@]} records (schema 5) map core's four roots to lean4 at their leanGithash and micro-dep's Dep-Aux to no URL, carry litedoc4.toml's title, and say no prints were reused"
else
  item FAIL source-map "${sources:-the record check printed nothing}"
fi

N=${#VERSIONS[@]}
stale_summary () {
  local root="$1" log="$2"
  if ! timed "check-stale $(basename "$root")" "$log" \
      "$LITEDOC4" store check-stale --store "$R1/store" --extractor-bin "$EXTRACTOR" --root "$root"; then
    echo "exited non-zero"
    return 0
  fi
  sed -n 's/^\(check-stale .*\) (.*)$/\1/p' "$log"
}
summary="$(stale_summary "$R1/repo" "$LOGS/fresh.log")"
if [ "$summary" = "check-stale $N entries: $N fresh, 0 stale, 0 needs re-put, 0 unreadable" ]; then
  item ok fresh "$summary, with the configuration the entries were built under"
else
  item FAIL fresh "with the configuration the entries were built under: ${summary:-no summary line}"
fi
mkdir -p "$R1/config-changed"
cp "$R1/repo/litedoc4.toml" "$R1/config-changed/litedoc4.toml"
printf 'no_equations_under = ["Example"]\n' >>"$R1/config-changed/litedoc4.toml"
summary="$(stale_summary "$R1/config-changed" "$LOGS/stale.log")"
if [ "$summary" = "check-stale $N entries: 0 fresh, $N stale, 0 needs re-put, 0 unreadable" ]; then
  item ok stale "$summary, with no_equations_under added to a copy of the configuration"
else
  item FAIL stale "with no_equations_under added to a copy of the configuration: ${summary:-no summary line}"
fi

OLD="$R1/store-older"
cp -R "$R1/store" "$OLD"
python3 - "$OLD" <<'PY'
import json
import pathlib
import sys

store = pathlib.Path(sys.argv[1])
for version, schema, dropped in (("v2", 2, ("sources", "title")), ("v3", 3, ("title",))):
    path = store / version / "record.json"
    record = json.loads(path.read_text(encoding="utf-8"))
    for key in dropped:
        del record[key]
    record["recordSchema"] = schema
    path.write_text(json.dumps(record) + "\n", encoding="utf-8")
PY
check_old () {
  local log="$1" rc=0
  "$LITEDOC4" store check-stale --store "$OLD" --extractor-bin "$EXTRACTOR" --root "$R1/repo" \
    >"$log" 2>"$log.err" || rc=$?
  echo "$rc $(sed -n 's/^\(check-stale .*\) (.*)$/\1/p' "$log")"
}
old_said="$(check_old "$LOGS/needs-re-put.log")"
refused=""
for v in v2 v3; do
  rc=0
  "$LITEDOC4" store measure --store "$OLD" --versions "v1,$v" --candidate a \
    >"$LOGS/needs-re-put-measure-$v.log" 2>&1 || rc=$?
  if [ "$rc" -ne 3 ] || ! grep -q "store entry $v: .*litedoc4 store put --version $v" "$LOGS/needs-re-put-measure-$v.log"; then
    refused="$refused; store measure over $v exited $rc without refusing it by name"
  fi
  rc=0
  "$LITEDOC4" store render --store "$OLD" --versions "v1,$v" --out "$R1/render-older-$v" \
    >"$LOGS/needs-re-put-render-$v.log" 2>&1 || rc=$?
  if [ "$rc" -ne 3 ] || ! grep -q "store entry $v: .*litedoc4 store put --version $v" "$LOGS/needs-re-put-render-$v.log"; then
    refused="$refused; store render over $v exited $rc without refusing it by name"
  elif [ -e "$R1/render-older-$v" ] && [ -n "$(ls -A "$R1/render-older-$v")" ]; then
    refused="$refused; store render refused $v after writing into its --out (v1 comes first)"
  fi
done
put_rc=0
for v in v2 v3; do
  git -C "$R1/repo" -c advice.detachedHead=false checkout -q "$v"
  "$LITEDOC4" store put --store "$OLD" --version "$v" --from "$R1/build/$v" \
    >"$LOGS/needs-re-put-put-$v.log" 2>&1 || put_rc=$?
done
git -C "$R1/repo" -c advice.detachedHead=false checkout -q "${VERSIONS[$((N - 1))]}"
reput_said="$(check_old "$LOGS/needs-re-put-after.log")"
restored=1
for v in v2 v3; do
  if ! cmp -s "$OLD/$v/record.json" "$R1/store/$v/record.json" || ! cmp -s "$OLD/$v/entry.pack.gz" "$R1/store/$v/entry.pack.gz"; then
    restored=0
  fi
done
if [ "$old_said" != "3 check-stale $N entries: $((N - 2)) fresh, 0 stale, 2 needs re-put, 0 unreadable" ]; then
  item FAIL needs-re-put "with v2's record downgraded to schema 2 and v3's to schema 3, check-stale answered (exit, summary): $old_said"
elif ! grep -q '^v2 needs re-put: .*source map.*litedoc4 store put --version v2' "$LOGS/needs-re-put.log" ||
     ! grep -q '^v3 needs re-put: .*site configuration.*litedoc4 store put --version v3' "$LOGS/needs-re-put.log"; then
  item FAIL needs-re-put "check-stale counted two entries as needing a re-put and its lines for v2 and v3 do not name what each lacks and store put"
elif [ -n "$refused" ]; then
  item FAIL needs-re-put "${refused#; } (logs in $LOGS/needs-re-put-*)"
elif [ "$put_rc" -ne 0 ]; then
  item FAIL needs-re-put "re-putting v2 and v3 from their builds exited $put_rc ($LOGS/needs-re-put-put-*.log)"
elif [ "$restored" -ne 1 ]; then
  item FAIL needs-re-put "re-putting v2 and v3 from their builds did not give back the entries they were first put as"
elif [ "$reput_said" != "0 check-stale $N entries: $N fresh, 0 stale, 0 needs re-put, 0 unreadable" ]; then
  item FAIL needs-re-put "after the re-puts, check-stale answered (exit, summary): $reput_said"
else
  item ok needs-re-put "a schema-2 record (no source map) and a schema-3 one (no site configuration) are counted apart, each named with what it lacks, and exit 3; measure and render refuse each naming store put (render before writing anything); re-putting both from their builds restores the entries byte for byte"
fi

say "4/8 the data format: three candidates, each laid out twice"
LIST="$(IFS=,; echo "${VERSIONS[*]}")"
mkdir -p "$R1/measure"
for c in "${CANDIDATES[@]}"; do
  ok=1
  for k in 1 2; do
    if ! timed "measure $c ($k)" "$R1/measure/$c-$k.json" \
        "$LITEDOC4" store measure --store "$R1/store" --versions "$LIST" --candidate "$c" \
        --out "$R1/measure/$c-$k"; then
      ok=0
    fi
  done
  if [ "$ok" -eq 0 ]; then
    item FAIL "measure-repeat-$c" "store measure refused (logs in $R1/measure)"
  elif ! /usr/bin/diff -r "$R1/measure/$c-1" "$R1/measure/$c-2" >"$LOGS/measure-$c.diff" 2>&1 ||
       ! cmp -s "$R1/measure/$c-1.json" "$R1/measure/$c-2.json"; then
    item FAIL "measure-repeat-$c" "two layouts of the same store differ ($LOGS/measure-$c.diff)"
  else
    item ok "measure-repeat-$c" "two layouts gave byte-identical trees ($(find "$R1/measure/$c-1" -type f | wc -l | tr -d ' ') files) and counters"
  fi
done

set +e
python3 - "$EXPECTED" "$R1/measure" "$LIST" "$WORK/table.txt" >"$WORK/format-items.txt" 2>"$LOGS/format-items.err" <<'PY'
import gzip
import json
import pathlib
import sys

expected_path, measure, versions, table_path = sys.argv[1:5]
measure = pathlib.Path(measure)
versions = versions.split(",")
pairs = ["%s..%s" % (versions[i - 1], versions[i]) for i in range(1, len(versions))]


def say(ok, name, what):
    print("%s %s: %s" % ("ok" if ok else "FAIL", name, what))


def check(name, body):
    try:
        ok, what = body()
    except Exception as e:
        ok, what = False, "could not be asked: %r" % (e,)
    say(ok, name, what)


entering = {p: set() for p in pairs}
pages = {p: [] for p in pairs}
members = {p: set() for p in pairs}
for number, line in enumerate(pathlib.Path(expected_path).read_text(encoding="utf-8").splitlines(), 1):
    f = line.split()
    if not f or f[0].startswith("#"):
        continue
    pair, cls = f[0], f[1]
    if pair not in entering:
        sys.exit("expected.txt:%d names pair %s, which this run has not" % (number, pair))
    if cls in ("changed", "added"):
        entering[pair].add(f[2])
    elif cls == "renamed":
        if len(f) < 5 or f[3] != "->":
            sys.exit("expected.txt:%d: a renamed row is `<old> -> <new>`" % number)
        entering[pair].add(f[4])
    elif cls == "member":
        members[pair].add(f[2])
    elif cls == "page":
        if len(f) < 6 or f[3] not in ("new", "-") or f[4] not in ("new", "-"):
            sys.exit("expected.txt:%d: a page row is `<module> new|- new|- <names>|-`" % number)
        names = [] if f[5:] == ["-"] else f[5:]
        pages[pair].append({"module": f[2], "a": f[3] == "new", "b": f[4] == "new", "names": names})


def oracle_rows():
    bad = []
    for p in pairs:
        covered = set(members[p])
        for row in pages[p]:
            covered |= {n for n in row["names"] if n != "moddoc"}
        for n in sorted(entering[p] - covered):
            bad.append("%s: %s enters and no page or member row carries it" % (p, n))
        for n in sorted(covered - entering[p]):
            bad.append("%s: %s is in a page or member row and no changed/added/renamed row" % (p, n))
    if bad:
        return False, "; ".join(bad)
    return True, "the page and member rows of %d pairs carry exactly the changed, added and renamed declarations" % len(pairs)


check("oracle-rows", oracle_rows)


def gunzip_json(path):
    return json.loads(gzip.decompress(path.read_bytes()).decode("utf-8"))


def page_files(tree, version):
    if not (tree / version / "m").is_dir():
        raise RuntimeError("%s has no page files for %s" % (tree, version))
    out = []
    for path in sorted((tree / version / "m").rglob("*.json")):
        out.append(gunzip_json(path))
    return out


def item_name(item):
    if "moddoc" in item:
        return "moddoc"
    return item["n"]


def item_identity(item):
    return json.dumps(item, sort_keys=True, ensure_ascii=False)


counters = {}
for c in ("a", "b", "c"):
    try:
        counters[c] = json.loads((measure / ("%s-1.json" % c)).read_text(encoding="utf-8"))
    except Exception as e:
        counters[c] = None


def versions_of(c):
    if counters[c] is None:
        raise RuntimeError("candidate %s printed no counters" % c)
    got = [v["version"] for v in counters[c]["versions"]]
    if got != versions:
        raise RuntimeError("candidate %s counted versions %s" % (c, got))
    return counters[c]["versions"]


def expected_new(p):
    return sum(len(row["names"]) for row in pages[p])


for c in ("a", "b", "c"):
    def new_addresses(c=c):
        vs = versions_of(c)
        bad = []
        if vs[0]["newAddresses"] != vs[0]["addresses"]:
            bad.append("%s: %d new of %d" % (versions[0], vs[0]["newAddresses"], vs[0]["addresses"]))
        for k, p in enumerate(pairs, 1):
            if vs[k]["newAddresses"] != expected_new(p):
                bad.append("%s: %d, expected %d" % (p, vs[k]["newAddresses"], expected_new(p)))
        said = ", ".join("%s %d" % (v["version"], v["newAddresses"]) for v in vs)
        return (not bad), ("; ".join(bad) if bad else said)
    check("new-addresses-" + c, new_addresses)


def agree():
    keys = ("pages", "items", "addresses", "newAddresses")
    rows = {c: versions_of(c) for c in ("a", "b", "c")}
    bad = []
    for k, v in enumerate(versions):
        for key in keys:
            seen = {c: rows[c][k][key] for c in rows}
            if len(set(seen.values())) != 1:
                bad.append("%s %s %s" % (v, key, seen))
        if rows["c"][k]["added"]["contentItems"] != rows["c"][k]["newAddresses"]:
            bad.append("%s: (c) packed %d items for %d new addresses"
                       % (v, rows["c"][k]["added"]["contentItems"], rows["c"][k]["newAddresses"]))
    if bad:
        return False, "; ".join(bad)
    return True, "pages, items, addresses and newAddresses equal in all %d versions; (c) packs exactly the new ones" % len(versions)


check("agree", agree)


def a_view():
    tree = measure / "a-1"
    seen_items, seen_files = set(), set()
    per_version = []
    for v in versions:
        new_items, new_files = {}, {}
        items, files = set(), set()
        for m in page_files(tree, v):
            if m["content"] is None:
                if m["lines"]:
                    raise RuntimeError("%s %s: items and no content file" % (v, m["module"]))
                continue
            content = gunzip_json(tree / m["content"])
            if len(content) != len(m["lines"]):
                raise RuntimeError("%s %s: %d items, %d in the content file"
                                   % (v, m["module"], len(m["lines"]), len(content)))
            for item in content:
                identity = item_identity(item)
                if identity not in seen_items:
                    new_items.setdefault(m["module"], set()).add(item_name(item))
                items.add(identity)
            if m["content"] not in seen_files:
                new_files[m["module"]] = m["content"]
            files.add(m["content"])
        per_version.append((new_items, new_files))
        seen_items |= items
        seen_files |= files
    return per_version


def b_view():
    tree = measure / "b-1"
    seen = set()
    per_version = []
    for v in versions:
        new_segments = {}
        files = set()
        for m in page_files(tree, v):
            for s in m["content"]["s"]:
                files.add(s)
                if s not in seen:
                    names = [item_name(i) for i in gunzip_json(tree / s)]
                    new_segments.setdefault(m["module"], []).append(names)
        per_version.append(new_segments)
        seen |= files
    return per_version


def show(d):
    return "; ".join("%s: %s" % (k, " ".join(sorted(v))) for k, v in sorted(d.items())) or "none"


a_cache, b_cache = [], []


def cached(cache, make):
    if not cache:
        cache.append(make())
    return cache[0]


for k, p in enumerate(pairs, 1):
    def new_items(k=k, p=p):
        got = cached(a_cache, a_view)[k][0]
        want = {row["module"]: set(row["names"]) for row in pages[p] if row["names"]}
        if got != want:
            return False, "got {%s}, expected {%s}" % (show(got), show(want))
        return True, "%d new item(s) by name: %s" % (sum(len(v) for v in got.values()), show(got))

    def a_files(k=k, p=p):
        got = set(cached(a_cache, a_view)[k][1])
        want = {row["module"] for row in pages[p] if row["a"]}
        counted = versions_of("a")[k]["added"]["contentFiles"]
        if got != want or counted != len(want):
            return False, "new content files for {%s} (counter %d), expected {%s}" % (
                ", ".join(sorted(got)), counted, ", ".join(sorted(want)))
        return True, "%d new content file(s): %s" % (len(got), ", ".join(sorted(got)))

    def b_segments(k=k, p=p):
        got = cached(b_cache, b_view)[k]
        want = {row["module"]: sorted(row["names"]) for row in pages[p] if row["b"]}
        flat = {m: sorted(n for seg in segs for n in seg) for m, segs in got.items()}
        one_each = all(len(segs) == 1 for segs in got.values())
        added = versions_of("b")[k]["added"]
        n_items = sum(len(v) for v in want.values())
        if flat != want or not one_each or added["contentFiles"] != len(want) or added["contentItems"] != n_items:
            return False, "new segments {%s} (counters %d files, %d items), expected {%s}" % (
                show(flat), added["contentFiles"], added["contentItems"], show(want))
        return True, "%d new segment(s), %d item(s): %s" % (len(want), n_items, show(flat))

    check("new-items-" + p, new_items)
    check("a-files-" + p, a_files)
    check("b-segments-" + p, b_segments)

lines = []
for c in ("a", "b", "c"):
    if counters[c] is None:
        lines.append("candidate %s: no counters" % c)
        continue
    h = counters[c]["hosted"]
    chunk = counters[c].get("chunkBytes")
    lines.append("candidate %s: hosted files=%d raw=%d stored=%d%s" % (
        c, h["files"], h["rawBytes"], h["storedBytes"], "" if chunk is None else " chunkBytes=%d" % chunk))
    lines.append(" ver pages items  addr   new links | +files   +raw +stored +cfiles +citems |"
                 " fetch tot/max   bytes tot/max | cfetch tot/max  cbytes tot/max itemsFetched")
    for v in counters[c]["versions"]:
        a, w = v["added"], v["view"]
        lines.append(" %-3s %5d %5d %5d %5d %5d | %6d %6d %7d %7d %7d | %6d/%-3d %8d/%-5d | %6d/%-3d %8d/%-5d %d" % (
            v["version"], v["pages"], v["items"], v["addresses"], v["newAddresses"], v["linkNames"],
            a["files"], a["rawBytes"], a["storedBytes"], a["contentFiles"], a["contentItems"],
            w["fetches"]["total"], w["fetches"]["max"], w["bytes"]["total"], w["bytes"]["max"],
            w["contentFetches"]["total"], w["contentFetches"]["max"],
            w["contentBytes"]["total"], w["contentBytes"]["max"], w["itemsFetched"]))
pathlib.Path(table_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
FORMAT_RC=$?
set -e
while IFS= read -r line; do
  status="${line%% *}"
  rest="${line#* }"
  item "$status" "${rest%%: *}" "${rest#*: }"
done <"$WORK/format-items.txt"
if [ "$FORMAT_RC" -ne 0 ]; then
  echo "the format checks stopped (exit $FORMAT_RC):" >&2
  tail -n 15 "$LOGS/format-items.err" >&2
fi

say "5/8 the site: store render, twice, each version alone, and all but the newest"
RD="$R1/render"
mkdir -p "$RD"
render () {
  local name="$1" list="$2"
  shift 2
  timed "render $name" "$RD/$name.json" "$LITEDOC4" store render --store "$R1/store" --versions "$list" --out "$RD/$name" "$@"
}
ALL_OK=1
for k in 1 2; do render "all-$k" "$LIST" || ALL_OK=0; done
if [ "$ALL_OK" -eq 0 ]; then
  item FAIL render-twice "store render refused ($RD/all-*.json.err)"
elif ! /usr/bin/diff -r "$RD/all-1" "$RD/all-2" >"$LOGS/render-twice.diff" 2>&1 ||
     ! cmp -s "$RD/all-1.json" "$RD/all-2.json"; then
  item FAIL render-twice "two renders of the same store differ ($LOGS/render-twice.diff: $(head -n 1 "$LOGS/render-twice.diff"))"
else
  item ok render-twice "two renders of all ${#VERSIONS[@]} versions gave byte-identical trees ($(find "$RD/all-1" -type f | wc -l | tr -d ' ') files) and counts"
fi

for v in "${VERSIONS[@]}"; do
  alone="$RD/alone-$v"
  if ! render "alone-$v" "$v"; then
    item FAIL "render-alone-$v" "store render of $v alone refused ($RD/alone-$v.json.err)"
    continue
  fi
  if ! /usr/bin/diff -r "$alone/$v" "$RD/all-1/$v" >"$LOGS/render-alone-$v.diff" 2>&1; then
    item FAIL "render-alone-$v" "$v/ rendered alone differs from $v/ rendered with the others ($LOGS/render-alone-$v.diff: $(head -n 1 "$LOGS/render-alone-$v.diff"))"
    continue
  fi
  n=0
  differs=""
  for f in "$alone"/d/*; do
    n=$((n + 1))
    if ! cmp -s "$f" "$RD/all-1/d/$(basename "$f")"; then differs="$differs $(basename "$f")"; fi
  done
  if [ -n "$differs" ]; then
    item FAIL "render-alone-$v" "of $n data files $v alone wrote, these are absent or other bytes in the four-version d/:$differs"
  else
    item ok "render-alone-$v" "$v/ ($(find "$alone/$v" -type f | wc -l | tr -d ' ') shells) byte-identical to the four-version run's, and all $n data files it wrote are in that run's d/ byte for byte"
  fi
done

FIRST="$(IFS=,; echo "${VERSIONS[*]:0:$((N - 1))}")"
render first "$FIRST" || true

HASH_OK=1
for k in 1 2; do render "hash-$k" "$LIST" --hash-urls || HASH_OK=0; done
if [ "$HASH_OK" -eq 0 ]; then
  item FAIL render-hash-twice "store render --hash-urls refused ($RD/hash-*.json.err)"
elif ! /usr/bin/diff -r "$RD/hash-1" "$RD/hash-2" >"$LOGS/render-hash-twice.diff" 2>&1 ||
     ! cmp -s "$RD/hash-1.json" "$RD/hash-2.json"; then
  item FAIL render-hash-twice "two hash-URL renders of the same store differ ($LOGS/render-hash-twice.diff: $(head -n 1 "$LOGS/render-hash-twice.diff"))"
else
  item ok render-hash-twice "two hash-URL renders of all ${#VERSIONS[@]} versions gave byte-identical trees ($(find "$RD/hash-1" -type f | wc -l | tr -d ' ') files) and counts"
fi

for v in "${VERSIONS[@]}"; do
  alone="$RD/hash-alone-$v"
  if ! render "hash-alone-$v" "$v" --hash-urls; then
    item FAIL "render-hash-alone-$v" "store render --hash-urls of $v alone refused ($RD/hash-alone-$v.json.err)"
    continue
  fi
  said="$(python3 - "$alone" "$RD/hash-1" "$v" 2>&1 <<'PY'
import json
import pathlib
import sys

alone, full, v = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
mine = json.loads((alone / "versions.json").read_text(encoding="utf-8"))
theirs = [e for e in json.loads((full / "versions.json").read_text(encoding="utf-8")) if e["name"] == v]
if mine != theirs or "routes" not in mine[0]:
    print("versions.json alone lists %s, the four-version run %s" % (mine, theirs))
    sys.exit()
dirs = sorted(p.name for p in alone.iterdir() if p.is_dir() and p.name not in ("d", "assets"))
if dirs:
    print("a version directory was written: %s" % dirs)
    sys.exit()
files = sorted((alone / "d").iterdir())
bad = [p.name for p in files if not (full / "d" / p.name).is_file() or (full / "d" / p.name).read_bytes() != p.read_bytes()]
if bad:
    print("of %d data files, these are absent or other bytes in the four-version d/: %s" % (len(files), " ".join(bad)))
    sys.exit()
print("ok %d" % len(files))
PY
)" || true
  case "$said" in
    "ok "*) item ok "render-hash-alone-$v" "no version directory, the same versions.json entry (routes included) as the four-version run, and all ${said#ok } data files it wrote are in that run's d/ byte for byte" ;;
    *) item FAIL "render-hash-alone-$v" "${said:-the check printed nothing}" ;;
  esac
done

set +e
python3 - "$EXPECTED" "$RD" "${VERSIONS[$((N - 2))]}" "${VERSIONS[$((N - 1))]}" "$ROOT/e2e/micro" >"$WORK/render-items.txt" 2>"$LOGS/render-items.err" <<'PY'
import gzip
import json
import pathlib
import re
import sys

expected_path, rd, older, newest, sample = sys.argv[1:6]
rd = pathlib.Path(rd)
sample = pathlib.Path(sample)
pair = "%s..%s" % (older, newest)


def say(ok, name, what):
    print("%s %s: %s" % ("ok" if ok else "FAIL", name, what))


def check(name, body):
    try:
        ok, what = body()
    except Exception as e:
        ok, what = False, "could not be asked: %r" % (e,)
    say(ok, name, what)


def attr(html, key):
    m = re.search(r' data-%s="([0-9a-f]+)"' % key, html)
    if not m:
        raise RuntimeError("no data-%s" % key)
    return m.group(1)


def sharing():
    rows = []
    for line in pathlib.Path(expected_path).read_text(encoding="utf-8").splitlines():
        f = line.split()
        if f and not f[0].startswith("#") and f[0] == pair:
            rows.append(f)
    if not rows:
        return False, "expected.txt has no row for %s" % pair
    for f in rows:
        fields = []
        for word in f[3:]:
            if word.startswith("("):
                break
            fields.append(word.rstrip(","))
        if f[1] == "changed" and fields and set(fields) <= {"equations", "doc"}:
            continue
        if f[1] in ("page", "totals"):
            continue
        return False, "the derivation covers a pair of equation and docstring changes only; %s has `%s`" % (pair, " ".join(f))
    modules = [f[2] for f in rows if f[1] == "page" and f[3] == "new"]
    want_n = 1 + 2 * len(modules)
    all_d = {p.name for p in (rd / "all-1" / "d").iterdir()}
    first_d = {p.name for p in (rd / "first" / "d").iterdir()}
    new = all_d - first_d
    counts = json.loads((rd / "all-1.json").read_text(encoding="utf-8"))
    counted = counts["versions"][-1]["dataAdded"]["files"]
    versions = json.loads((rd / "all-1" / "versions.json").read_text(encoding="utf-8"))
    want = {versions[-1]["data"] + ".json.gz": "the version file of %s" % newest}
    for m in modules:
        shell = (rd / "all-1" / newest / (m.replace(".", "/") + ".html")).read_text(encoding="utf-8")
        page = attr(shell, "page")
        want[page + ".json.gz"] = "the page file of %s" % m
        content = json.loads(gzip.decompress((rd / "all-1" / "d" / (page + ".json.gz")).read_bytes()))["content"]
        want[content + ".json.gz"] = "the content file of %s" % m
    if len(new) != want_n or counted != want_n or new != set(want):
        return False, "%s adds %d data files over %s (counter %d: %s), expected %d: %s" % (
            newest, len(new), older, counted, " ".join(sorted(new)), want_n,
            "; ".join("%s %s" % (v, k) for k, v in sorted(want.items())))
    return True, "%s adds %d data files over %s, as derived from %s's rows (1 version file + 2 per changed page: %s), and the counter agrees: %s" % (
        newest, want_n, older, pair, " ".join(modules), "; ".join(v for _, v in sorted(want.items())))


def tree(root):
    files = [p for p in sorted(root.rglob("*")) if p.is_file()]
    first = lambda p: p.relative_to(root).parts[0]
    shells = [p for p in files if p.parent != root and first(p) not in ("d", "assets")]
    data = [p for p in files if p.parent != root and first(p) == "d"]
    assets = [p for p in files if p.parent != root and first(p) == "assets"]
    top = [p for p in files if p.parent == root]
    return files, shells, data, assets, top


def reconcile():
    root = rd / "all-1"
    counts = json.loads((rd / "all-1.json").read_text(encoding="utf-8"))
    files, shells, data, assets, top = tree(root)
    if len(shells) + len(data) + len(assets) + len(top) != len(files):
        raise RuntimeError("a file is in none or two of shells, d/, assets/ and the root")
    named = sorted(p.relative_to(root / "assets").as_posix() for p in assets)
    if named != ["favicon.svg", "site.js", "style.css"]:
        raise RuntimeError("assets/ holds %s, not the stylesheet, the icon and site.js" % named)

    def tally(ps, raw):
        return {"files": len(ps), "rawBytes": sum(raw(p) for p in ps),
                "storedBytes": sum(p.stat().st_size for p in ps)}

    size = lambda p: p.stat().st_size
    unzipped = lambda p: len(gzip.decompress(p.read_bytes()))
    on_disk = {"shells": tally(shells, size), "data": tally(data, unzipped),
               "assets": tally(assets, size), "root": tally(top, size)}
    total = {k: sum(on_disk[part][k] for part in on_disk) for k in ("files", "rawBytes", "storedBytes")}
    printed = counts["total"]
    bad = []
    for k in total:
        if printed[k] != total[k]:
            bad.append("total %s printed %d, on disk %d" % (k, printed[k], total[k]))
    for part, t in on_disk.items():
        if printed[part] != t:
            bad.append("%s printed %s, on disk %s" % (part, printed[part], t))
    if sorted(p.name for p in top) != ["404.html", "index.html", "versions.json"]:
        bad.append("the root holds %s, not 404.html, index.html and versions.json" % sorted(p.name for p in top))
    listed = {e["name"]: e["data"] for e in json.loads((root / "versions.json").read_text(encoding="utf-8"))}
    for v in counts["versions"]:
        name = v["version"]
        mine = {p.relative_to(root / name).as_posix() for p in shells if p.relative_to(root).parts[0] == name}
        if v["shells"]["files"] != len(mine):
            bad.append("%s: %d shells printed, %d on disk" % (name, v["shells"]["files"], len(mine)))
        modules = gzip.decompress((root / "d" / (data_json_at(root, listed[name])["modules"] + ".json.gz")).read_bytes())
        want = {m["p"] for m in json.loads(modules)["modules"]} | set(VERSION_PAGES)
        if mine != want or v["modules"] + len(VERSION_PAGES) != len(want):
            bad.append("%s: shells beyond its module list's pages and the version pages %s, absent %s (modules printed %d)" % (
                name, sorted(mine - want), sorted(want - mine), v["modules"]))
    if bad:
        return False, "; ".join(bad)
    return True, "printed totals = the tree on disk: %d files, %d raw bytes, %d stored (shells %d, data %d, assets %d, root %d: 404.html, index.html, versions.json), and each version's shells are exactly its module list's pages plus %s" % (
        total["files"], total["rawBytes"], total["storedBytes"], on_disk["shells"]["files"],
        on_disk["data"]["files"], on_disk["assets"]["files"], on_disk["root"]["files"],
        ", ".join(VERSION_PAGES))


VERSION_PAGES = ("index.html", "references.html", "search.html", "foundational_types.html")


def data_json_at(root, address):
    return json.loads(gzip.decompress((root / "d" / (address + ".json.gz")).read_bytes()))


def data_json(address):
    return json.loads(gzip.decompress((rd / "all-1" / "d" / (address + ".json.gz")).read_bytes()))


def version_file():
    versions = json.loads((rd / "all-1" / "versions.json").read_text(encoding="utf-8"))
    return data_json(versions[-1]["data"])


def module_docs(module):
    shell = (rd / "all-1" / newest / (module.replace(".", "/") + ".html")).read_text(encoding="utf-8")
    content = data_json(attr(shell, "page"))["content"]
    out = {}
    for item in data_json(content):
        out["moddoc" if "moddoc" in item else item["n"]] = item.get("moddoc", item.get("doc", ""))
    return out


CITATIONS = (("deMoura2021", "Example", "moddoc", ""),
             ("TPIL4", "Example.Basic", "moddoc", ""),
             ("Graham1994", "Example.Math", "Example.Math.displaySpan", "Example.Math.displaySpan"))


def citation():
    bad = []
    v = version_file()
    references = data_json(v["references"])
    by = {r["key"]: r["by"] for r in references}
    for key, module, item, fun in CITATIONS:
        doc = module_docs(module).get(item, "")
        anchors = re.findall(r'<a href="references\.html#ref_%s" title="[^"]*" data-cite>' % key, doc)
        if len(anchors) != 1 or doc.count("data-cite") != 1 or "_backref" in doc:
            bad.append("%s's %s holds %d data-cite anchor(s) to ref_%s and %d in all" % (
                module, item, len(anchors), key, doc.count("data-cite")))
        if by.get(key) != [[module, 0, fun]]:
            bad.append("the references data gives %s the citations %s" % (key, by.get(key)))
    keys = sorted(by)
    if keys != sorted(k for k, _, _, _ in CITATIONS):
        bad.append("the references data holds %s" % keys)
    shell = (rd / "all-1" / newest / "references.html").read_text(encoding="utf-8")
    if attr(shell, "references") != v["references"]:
        bad.append("%s/references.html names %s, the version file %s" % (
            newest, attr(shell, "references"), v["references"]))
    if bad:
        return False, "; ".join(bad)
    return True, "in %s each of the sample's 3 citations is one data-cite link to references.html#ref_<key> with no root prefix or id, the references data (named by the version file and by %s/references.html) lists exactly those 3 keys, each cited once at index 0 by the module whose docstring cites it" % (
        newest, newest)


def front():
    v = version_file()
    toml = (sample / "litedoc4.toml").read_text(encoding="utf-8")
    title = re.search(r'^title = "([^"]*)"', toml, re.M).group(1)
    index = re.search(r'^index = "([^"]*)"', toml, re.M).group(1)
    heading = (sample / index).read_text(encoding="utf-8").splitlines()[0]
    if not heading.startswith("# "):
        return False, "%s does not open with a level-1 heading" % index
    want_id = "-".join(re.findall(r"[A-Za-z0-9]+", heading[2:]))
    if v.get("title") != title:
        return False, "the version file's title is %r, litedoc4.toml's %r" % (v.get("title"), title)
    if not v.get("front"):
        return False, "the version file names no front page"
    page = data_json(v["front"])
    want = '<h1 id="%s" class="markdown-heading">' % want_id
    if not page.get("html", "").startswith(want):
        return False, "the front page file %s does not open with %s: %r" % (v["front"], want, page.get("html", "")[:80])
    return True, "the version file carries litedoc4.toml's title %r and names a front page file that opens with %s's heading as %s" % (
        title, index, want)


def reconcile_hash():
    root = rd / "hash-1"
    paths = rd / "all-1"
    counts = json.loads((rd / "hash-1.json").read_text(encoding="utf-8"))
    files, shells, data, assets, top = tree(root)
    bad = []
    if len(shells) + len(data) + len(assets) + len(top) != len(files):
        raise RuntimeError("a file is in none or two of shells, d/, assets/ and the root")
    if shells:
        bad.append("%d shells written: %s" % (len(shells), [p.relative_to(root).as_posix() for p in shells[:3]]))
    if sorted(p.name for p in top) != ["404.html", "index.html", "versions.json"]:
        bad.append("the root holds %s" % sorted(p.name for p in top))
    for name in ("index.html", "404.html"):
        if "data-mode=\"hash\"" not in (root / name).read_text(encoding="utf-8"):
            bad.append("%s says nothing of hash URLs" % name)
    size = lambda p: p.stat().st_size
    unzipped = lambda p: len(gzip.decompress(p.read_bytes()))

    def tally(ps, raw):
        return {"files": len(ps), "rawBytes": sum(raw(p) for p in ps), "storedBytes": sum(size(p) for p in ps)}

    on_disk = {"shells": tally(shells, size), "data": tally(data, unzipped), "assets": tally(assets, size), "root": tally(top, size)}
    for part, t in on_disk.items():
        if counts["total"][part] != t:
            bad.append("%s printed %s, on disk %s" % (part, counts["total"][part], t))
    if counts["total"]["files"] != len(files):
        bad.append("total files printed %d, on disk %d" % (counts["total"]["files"], len(files)))
    listed = json.loads((root / "versions.json").read_text(encoding="utf-8"))
    path_listed = {e["name"]: e["data"] for e in json.loads((paths / "versions.json").read_text(encoding="utf-8"))}
    routes_files = set()
    sizes = []
    path_counts = {v["version"]: v for v in json.loads((rd / "all-1.json").read_text(encoding="utf-8"))["versions"]}
    for e, v in zip(listed, counts["versions"]):
        name = e["name"]
        if e["data"] != path_listed.get(name):
            bad.append("%s: version file %s, with path URLs %s" % (name, e["data"], path_listed.get(name)))
        f = root / "d" / (e["routes"] + ".json.gz")
        routes_files.add(f.name)
        table = json.loads(gzip.decompress(f.read_bytes()))
        sizes.append("%s %d B raw, %d B gzip, %d modules" % (name, len(gzip.decompress(f.read_bytes())), size(f), len(table)))
        modules = json.loads(gzip.decompress((root / "d" / (data_json_at(root, e["data"])["modules"] + ".json.gz")).read_bytes()))["modules"]
        want = {}
        for m in modules:
            shell = (paths / name / m["p"]).read_text(encoding="utf-8")
            want[m["p"][:-len(".html")]] = [attr(shell, "page"), attr(shell, "used-by")]
        if table != want:
            bad.append("%s: the routes table is not the path-URL shells' page and Used-by addresses by page path (%d entries, %d shells)" % (name, len(table), len(want)))
        p = path_counts[name]
        if v["shells"]["files"] != 0 or v["dataReferenced"] != p["dataReferenced"] + 1:
            bad.append("%s: %d shells and %d data files referenced, path URLs %d referenced" % (
                name, v["shells"]["files"], v["dataReferenced"], p["dataReferenced"]))
    hash_d = {p.name for p in (root / "d").iterdir()}
    path_d = {p.name for p in (paths / "d").iterdir()}
    if hash_d != path_d | routes_files or path_d & routes_files:
        bad.append("d/ with hash URLs is not d/ with path URLs plus the %d routes files: beyond %s, absent %s" % (
            len(routes_files), sorted(hash_d - path_d - routes_files)[:3], sorted(path_d - hash_d)[:3]))
    differ = [n for n in path_d & hash_d if (root / "d" / n).read_bytes() != (paths / "d" / n).read_bytes()]
    if differ:
        bad.append("%d data files differ between the two renders: %s" % (len(differ), differ[:3]))
    if bad:
        return False, "; ".join(bad)
    return True, "printed totals = the tree on disk (%d files: no shells, data %d, assets %d, root %d: index.html, 404.html, versions.json); d/ is path-URL d/ byte for byte plus one routes file per version, each the path-URL shells' page and Used-by addresses by page path (%s), and every version file is the path-URL one" % (
        len(files), on_disk["data"]["files"], on_disk["assets"]["files"], on_disk["root"]["files"], "; ".join(sizes))


check("render-sharing", sharing)
check("render-counts", reconcile)
check("render-hash-counts", reconcile_hash)
check("render-citation", citation)
check("render-front", front)
PY
RENDER_RC=$?
set -e
while IFS= read -r line; do
  status="${line%% *}"
  rest="${line#* }"
  item "$status" "${rest%%: *}" "${rest#*: }"
done <"$WORK/render-items.txt"
if [ "$RENDER_RC" -ne 0 ]; then
  echo "the render checks stopped (exit $RENDER_RC):" >&2
  tail -n 15 "$LOGS/render-items.err" >&2
fi

set +e
python3 -I "$ROOT/benchmarks/tools/check-store-render.py" --site "$RD/all-1" --repo "$R1/repo" \
  --builds "$R1/build" --versions "$LIST" >"$WORK/store-items.txt" 2>"$LOGS/store-items.err"
STORE_RC=$?
set -e
while IFS= read -r line; do
  status="${line%% *}"
  rest="${line#* }"
  item "$status" "${rest%%: *}" "${rest#*: }"
done <"$WORK/store-items.txt"
if [ "$STORE_RC" -ne 0 ]; then
  echo "the site checks stopped (exit $STORE_RC):" >&2
  tail -n 15 "$LOGS/store-items.err" >&2
fi
echo "counts (store render, all ${#VERSIONS[@]} versions):"
cat "$RD/all-1.json" 2>/dev/null || true
echo

say "6/8 run 2: the whole flow again, in another directory"
flow run2 "$R2" 0
if /usr/bin/diff -r "$R1/store" "$R2/store" >"$LOGS/second-run.diff" 2>&1; then
  item ok second-run "both runs put byte-identical entries for all ${#VERSIONS[@]} versions"
else
  item FAIL second-run "the second run's store differs from the first's ($LOGS/second-run.diff: $(head -n 1 "$LOGS/second-run.diff"))"
fi

say "7/8 the loop: build --versions over v1..v5, again, and with an entry gone or stale"
LOOP="$WORK/loop"
LOOP_VERSIONS=(v1 v2 v3 v4 v5)
LOOP_LIST="$(IFS=,; echo "${LOOP_VERSIONS[*]}")"
LOOP_ALL="$(printf '%s, ' "${LOOP_VERSIONS[@]}")"
LOOP_ALL="${#LOOP_VERSIONS[@]} of ${#LOOP_VERSIONS[@]} (${LOOP_ALL%, })"
LOOP_NONE="0 of ${#LOOP_VERSIONS[@]} ()"
mkdir -p "$LOOP"
# The sample requires `../micro-dep`, and the loop checks every version out at <out>/checkout.
cp -R "$R1/micro-dep" "$LOOP/micro-dep"
loop () { # loop <name> [<version list>] [hash]
  local name="$1" list="${2:-$LOOP_LIST}"
  if [ "${3:-}" = hash ]; then set -- --hash-urls; else set --; fi
  timed "loop $name" "$LOGS/loop-$name.log" \
    "$LITEDOC4" build --root "$R1/repo" --out "$LOOP" --versions "$list" --lake "$LAKE" ${1+"$@"} || true
  sed -n 's/^versions extracted: //p' "$LOGS/loop-$name.log"
}
rendered () { sed -n 's/^versions rendered: //p' "$LOGS/loop-$1.log"; }
record_field () {
  python3 - "$LOOP/store" "$1" "${@:2}" <<'PY'
import json
import pathlib
import sys

store, key = pathlib.Path(sys.argv[1]), sys.argv[2]
print(" ".join(str(json.loads((store / v / "record.json").read_text(encoding="utf-8"))[key]) for v in sys.argv[3:]))
PY
}

said="$(loop empty)"
differs=""
for v in "${VERSIONS[@]}"; do
  for f in record.json entry.pack.gz; do
    if ! cmp -s "$R1/store/$v/$f" "$LOOP/store/$v/$f"; then differs="$differs $v/$f"; fi
  done
done
marked="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); e=m["versionsExtracted"]; print(m["complete"], e["count"], e["of"])' "$LOOP/litedoc4-build.json" 2>&1 || true)"
if [ "$said" != "$LOOP_ALL" ]; then
  item FAIL loop-empty "over an empty store the loop said \`versions extracted: ${said:-<no line>}\`, expected \`$LOOP_ALL\` ($LOGS/loop-empty.log)"
elif [ -n "$differs" ]; then
  item FAIL loop-empty "the loop's entries differ from the hand-driven flow's:$differs"
elif [ "$marked" != "True ${#LOOP_VERSIONS[@]} ${#LOOP_VERSIONS[@]}" ]; then
  item FAIL loop-empty "the build marker records (complete, count, of) = $marked"
else
  item ok loop-empty "over an empty store: versions extracted $said, recorded in the marker too; the ${#VERSIONS[@]} versions the hand-driven flow also built have byte-identical record.json and entry.pack.gz"
fi

cp -R "$LOOP/site" "$WORK/loop-site-1"
differs=""
for d in "${VERSIONS[@]}" assets; do
  if ! /usr/bin/diff -r "$RD/all-1/$d" "$WORK/loop-site-1/$d" >"$LOGS/loop-render-same-$d.diff" 2>&1; then
    differs="$differs $d/"
  fi
done
n=0
for f in "$RD/all-1"/d/*; do
  n=$((n + 1))
  if ! cmp -s "$f" "$WORK/loop-site-1/d/$(basename "$f")"; then differs="$differs d/$(basename "$f")"; fi
done
if [ "$n" -eq 0 ] || [ -n "$differs" ]; then
  item FAIL loop-render-same "of ${VERSIONS[*]}, assets/ and the $n data files store render wrote, build --versions' site lacks or differs in:${differs:- (no data file to compare)} ($LOGS/loop-render-same-*.diff)"
else
  item ok loop-render-same "build --versions' site holds ${VERSIONS[*]}'s shells, assets/ and all $n data files of the store render the site items above read, byte for byte"
fi
said="$(loop again)"
said_rendered="$(rendered again)"
if [ "$said" != "$LOOP_NONE" ]; then
  item FAIL loop-again "the same command again said \`versions extracted: ${said:-<no line>}\`, expected \`$LOOP_NONE\`"
elif [ "$said_rendered" != "$LOOP_NONE" ]; then
  item FAIL loop-again "the same command again said \`versions rendered: ${said_rendered:-<no line>}\`, expected \`$LOOP_NONE\`"
elif ! /usr/bin/diff -r "$WORK/loop-site-1" "$LOOP/site" >"$LOGS/loop-again.diff" 2>&1; then
  item FAIL loop-again "the second site differs from the first ($LOGS/loop-again.diff: $(head -n 1 "$LOGS/loop-again.diff"))"
else
  item ok loop-again "the same command again: versions extracted $said, rendered $said_rendered, and the site is byte-identical to the first ($(find "$LOOP/site" -type f | wc -l | tr -d ' ') files)"
fi

leans="$(record_field leanVersion v1 v5 2>&1 || true)"
if [ "$leans" != "4.31.0 4.32.2" ]; then
  item FAIL loop-toolchain "the records of v1 and v5 say lean $leans, expected 4.31.0 4.32.2"
elif ! grep -q '^version v5: fresh$' "$LOGS/loop-again.log" || ! grep -q '^version v1: fresh$' "$LOGS/loop-again.log"; then
  item FAIL loop-toolchain "the second run did not judge both v1 (lean 4.31.0) and v5 (lean 4.32.2) fresh"
elif ! grep -q '^identity .* lean=4.32.2 ' "$LOGS/loop-again.log"; then
  item FAIL loop-toolchain "the second run's identity was not asked of the lean 4.32.2 extractor: $(grep '^identity' "$LOGS/loop-again.log" | cut -c1-120)"
elif grep -Eq '^extractor .*: built|^toolchain .*: not installed' "$LOGS/loop-again.log"; then
  item FAIL loop-toolchain "with nothing stale the second run built an extractor or installed a toolchain"
else
  item ok loop-toolchain "v5's record says lean 4.32.2 and v1's 4.31.0; the second run asked one cached extractor (lean 4.32.2) for the identity, judged both fresh, and built and installed nothing"
fi

RENDER_LEDGER=render-ledger.json
FOUR_LIST="$(IFS=,; echo "${VERSIONS[*]}")"
FOUR_ALL="$(printf '%s, ' "${VERSIONS[@]}")"
FOUR_ALL="${#VERSIONS[@]} of ${#VERSIONS[@]} (${FOUR_ALL%, })"
same_site () { # same_site <reference> <item> -> empty, or what differs
  if [ -e "$LOOP/site/$RENDER_LEDGER" ]; then echo "the render ledger is inside the site"; return; fi
  if ! /usr/bin/diff -r "$1" "$LOOP/site" >"$LOGS/$2.diff" 2>&1; then
    echo "the site differs from the one rendered from nothing ($LOGS/$2.diff: $(head -n 1 "$LOGS/$2.diff"))"
  fi
}

said="$(loop render-drop "$FOUR_LIST")"
said_rendered="$(rendered render-drop)"
differs="$(same_site "$RD/all-1" loop-render-drop)"
if [ "$said" != "0 of ${#VERSIONS[@]} ()" ] || [ "$said_rendered" != "$FOUR_ALL" ]; then
  item FAIL loop-render-drop "with v5 dropped from the list the loop said extracted \`${said:-<no line>}\`, rendered \`${said_rendered:-<no line>}\`, expected \`0 of ${#VERSIONS[@]} ()\` and \`$FOUR_ALL\`"
elif [ -n "$differs" ]; then
  item FAIL loop-render-drop "with v5 dropped from the list: $differs"
else
  item ok loop-render-drop "with v5 dropped from the list: rendered $said_rendered, and the site is byte-identical to store render's of the four ($(find "$LOOP/site" -type f | wc -l | tr -d ' ') files)"
fi

said="$(loop render-add)"
said_rendered="$(rendered render-add)"
differs="$(same_site "$WORK/loop-site-1" loop-render-add)"
marked="$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["versionsRendered"]; print(e["count"], e["of"], ",".join(e["names"]))' "$LOOP/litedoc4-build.json" 2>&1 || true)"
if [ "$said" != "$LOOP_NONE" ] || [ "$said_rendered" != "1 of ${#LOOP_VERSIONS[@]} (v5)" ]; then
  item FAIL loop-render-add "with v5 added back the loop said extracted \`${said:-<no line>}\`, rendered \`${said_rendered:-<no line>}\`, expected \`$LOOP_NONE\` and \`1 of ${#LOOP_VERSIONS[@]} (v5)\`"
elif [ "$marked" != "1 ${#LOOP_VERSIONS[@]} v5" ]; then
  item FAIL loop-render-add "the build marker's versionsRendered records (count, of, names) = $marked"
elif [ -n "$differs" ]; then
  item FAIL loop-render-add "with v5 added to a site of four: $differs"
else
  item ok loop-render-add "with v5 added to a site of four: rendered $said_rendered, recorded in the marker too, and the site is byte-identical to the five rendered from nothing"
fi

said_hash="$(loop render-hash "" hash >/dev/null; rendered render-hash)"
said_back="$(loop render-hash-back >/dev/null; rendered render-hash-back)"
differs="$(same_site "$WORK/loop-site-1" loop-render-hash)"
if [ "$said_hash" != "$LOOP_ALL" ] || [ "$said_back" != "$LOOP_ALL" ]; then
  item FAIL loop-render-hash "flipping --hash-urls on and off rendered \`${said_hash:-<no line>}\` and \`${said_back:-<no line>}\`, expected \`$LOOP_ALL\` both times"
elif [ -n "$differs" ]; then
  item FAIL loop-render-hash "after --hash-urls on and off: $differs"
else
  item ok loop-render-hash "flipping --hash-urls on and off rendered $said_hash both times, and the site is byte-identical to the one rendered from nothing"
fi

gone="$(python3 -c 'import json,sys; l=json.load(open(sys.argv[1])); print(next(p for r in l["versions"] if r["name"] == "v3" for p in r["paths"] if p.startswith("d/")))' "$LOOP/$RENDER_LEDGER" 2>&1 || true)"
if [ -f "$LOOP/site/$gone" ]; then rm "$LOOP/site/$gone"; fi
said_rendered="$(loop render-missing >/dev/null; rendered render-missing)"
differs="$(same_site "$WORK/loop-site-1" loop-render-missing)"
if [ "${gone#d/}" = "$gone" ]; then
  item FAIL loop-render-missing "the render ledger named no data file of v3: $gone"
elif [ "$said_rendered" != "$LOOP_ALL" ]; then
  item FAIL loop-render-missing "with $gone deleted from the site the loop said rendered \`${said_rendered:-<no line>}\`, expected \`$LOOP_ALL\`"
elif [ -n "$differs" ]; then
  item FAIL loop-render-missing "with $gone deleted from the site: $differs"
else
  item ok loop-render-missing "with $gone (one of v3's files the render ledger lists) deleted from the site: rendered $said_rendered, and the site is byte-identical to the one rendered from nothing"
fi

cp -R "$LOOP/store/v3" "$WORK/loop-v3-before"
"$LITEDOC4" store remove --store "$LOOP/store" --version v3 >"$LOGS/loop-remove.log" 2>&1 || true
said="$(loop remove-one)"
said_rendered="$(rendered remove-one)"
if [ "$said" != "1 of ${#LOOP_VERSIONS[@]} (v3)" ]; then
  item FAIL loop-remove-one "with v3's entry removed the loop said \`versions extracted: ${said:-<no line>}\`, expected \`1 of ${#LOOP_VERSIONS[@]} (v3)\`"
elif ! /usr/bin/diff -r "$WORK/loop-v3-before" "$LOOP/store/v3" >"$LOGS/loop-remove-one.diff" 2>&1; then
  item FAIL loop-remove-one "v3 re-extracted differs from the entry that was removed ($LOGS/loop-remove-one.diff)"
elif [ "$said_rendered" != "$LOOP_NONE" ]; then
  item FAIL loop-remove-one "v3 re-extracted into the same bytes, and the loop said \`versions rendered: ${said_rendered:-<no line>}\`, expected \`$LOOP_NONE\`"
else
  item ok loop-remove-one "with v3's entry removed: versions extracted $said, the new entry is byte-identical to the removed one, and rendered $said_rendered"
fi

python3 - "$LOOP/store/v2/record.json" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
record = json.loads(path.read_text(encoding="utf-8"))
record["extractorIdentity"] = re.sub(r"\bsource=\S+", "source=fnv1a64:0000000000000000", record["extractorIdentity"])
path.write_text(json.dumps(record) + "\n", encoding="utf-8")
PY
said_source="$(loop identity-source)"
printf 'no_equations_under = ["Example"]\n' >>"$R1/repo/litedoc4.toml"
said_config="$(loop identity-config)"
git -C "$R1/repo" restore litedoc4.toml
flags="$(record_field extractorIdentity "${LOOP_VERSIONS[@]}" 2>&1 | grep -o 'noEquationsUnder=[^ ]*' | sort -u | tr '\n' ' ' || true)"
if [ "$said_source" != "1 of ${#LOOP_VERSIONS[@]} (v2)" ]; then
  item FAIL loop-identity "with v2's recorded source= altered the loop said \`versions extracted: ${said_source:-<no line>}\`, expected \`1 of ${#LOOP_VERSIONS[@]} (v2)\`"
elif [ "$said_config" != "$LOOP_ALL" ]; then
  item FAIL loop-identity "with no_equations_under added to the root's litedoc4.toml the loop said \`versions extracted: ${said_config:-<no line>}\`, expected \`$LOOP_ALL\`"
elif [ "$flags" != "noEquationsUnder=Example " ]; then
  item FAIL loop-identity "after that run the records carry ${flags:-no noEquationsUnder}: the root's flags did not reach every version's extraction"
else
  item ok loop-identity "an altered source= in v2's record re-extracted exactly v2 ($said_source); no_equations_under added to the root's litedoc4.toml re-extracted all ($said_config), and every record now carries noEquationsUnder=Example"
fi

say "8/8 report"
echo "counters per version (store measure, run 1):"
if [ -f "$WORK/table.txt" ]; then cat "$WORK/table.txt"; fi
echo
echo "times per phase (bash time: wall, user, sys in s; printed, never judged):"
cat "$TIMES"
record_host
echo "total             $((SECONDS - STARTED)) s"
echo

printf '%s\n' "${DECLARED[@]}" | sort >"$WORK/declared.txt"
printf '%s\n' ${RAN[@]+"${RAN[@]}"} | sort >"$WORK/ran.txt"
if ! /usr/bin/diff "$WORK/declared.txt" "$WORK/ran.txt" >"$LOGS/items.diff"; then
  echo "MV-S GATE: the items that reported are not the items declared (< never reported, > not declared or twice):" >&2
  cat "$LOGS/items.diff" >&2
  echo "MV-S GATE FAIL: ${#RAN[@]} of ${#DECLARED[@]} reported, $FAILED failed" >&2
  exit 1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "MV-S GATE FAIL: $FAILED of ${#DECLARED[@]} failed (${#RAN[@]} of ${#DECLARED[@]} ran)" >&2
  exit 1
fi
echo "MV-S GATE: ok, ${#RAN[@]} of ${#DECLARED[@]} items ran and passed"
PASSED=1
answer 0
