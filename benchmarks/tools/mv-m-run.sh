#!/usr/bin/env bash
# The M run of the multi-version plan (docs/multiversion/implementation.md,
# "Measurement loop"): the import closure of a few Mathlib roots at the real
# release tags, one version at a time — fetched, built from the cache, extracted,
# put into a store and read back — then laid out by the three storage candidates.
# A measurement, not a gate: per phase it logs wall and CPU time, peak RSS, page
# faults, free disk before and after, the work directory's size, and the counts
# that phase scales with. It refuses only on its own preconditions (disk, the
# closure, the checkout's commit) and on a slice that is not the closure.
#
# Per version, in the order given, and the checkout deleted before the next:
#   fetch      shallow fetch of the tag into <work>/checkout/<tag>
#   toolchain  elan toolchain install of the tag's lean-toolchain
#   closure    the roots' Mathlib import closure, read from the import lines
#   deps       lake resolves the manifest's packages
#   cache      lake exe cache get <roots>: the slice only, into <work>/cache/<tag>
#   lake       lake build --no-build <roots>; a plain lake build only if that fails
#   extractor  the extractor, built inside that workspace (micro_extractor)
#   prune      every Mathlib source outside the closure deleted, and litedoc4.toml
#              written, so that `build --lib Mathlib` globs exactly the closure
#   build      litedoc4 build; the link index's module list is checked against
#              the closure (Lean's own environment: nothing more, nothing less)
#   put        litedoc4 store put --version <tag>
#   read       litedoc4 store read, compared byte for byte with the build
# then `store measure` for a, b and c over all versions.
#
# Output: <work>/logs/phases.jsonl (one JSON record per version and phase, plus
# one for the run's conditions), each phase's raw output beside it, <work>/store,
# <work>/measure, and a summary on stdout. Nothing is written to benchmarks/results/.
#
# usage: benchmarks/tools/mv-m-run.sh [--roots M,M] [--versions T,T] [--work DIR]
#          [--keep-checkouts] [--limit-modules N] [--need-gb N] [--jobs N]
#   --roots           Mathlib modules (default: the plan's first M candidate,
#                     Mathlib.Algebra.BigOperators.Group.Finset.Basic,Mathlib.Order.Filter.Basic)
#   --versions        Mathlib release tags, in release order (default: v4.32.2,v4.33.0,v4.33.1)
#   --work            absent, empty, or one this script made (default:
#                     /private/tmp/lean-doc-relay/mv-m)
#   --keep-checkouts  keep each version's checkout, cache and build directory
#   --limit-modules   refuse a closure larger than N modules, before any download
#   --need-gb         free space required before each version (default: 4)
#   --jobs            litedoc4 build --jobs (default: 1)
#   LITEDOC4 / LAKE   the binaries (default: .lake/build/bin/litedoc4, ~/.elan/bin/lake)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../../tools/lib/common.sh
source "$ROOT/tools/lib/common.sh" || exit 1
answer_required

LAKE="${LAKE:-$HOME/.elan/bin/lake}"
ELAN="${ELAN:-$HOME/.elan/bin/elan}"
LITEDOC4="${LITEDOC4:-$ROOT/.lake/build/bin/litedoc4}"
REPO=https://github.com/leanprover-community/mathlib4
ROOTS=Mathlib.Algebra.BigOperators.Group.Finset.Basic,Mathlib.Order.Filter.Basic
VERSIONS=v4.32.2,v4.33.0,v4.33.1
WORK=/private/tmp/lean-doc-relay/mv-m
KEEP=0
LIMIT=0
NEED_GB=4
JOBS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --roots) ROOTS="$2"; shift 2 ;;
    --versions) VERSIONS="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --keep-checkouts) KEEP=1; shift ;;
    --limit-modules) LIMIT="$2"; shift 2 ;;
    --need-gb) NEED_GB="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d'; answer 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
case "$WORK" in /*) ;; *) WORK="$PWD/$WORK" ;; esac
IFS=, read -r -a ROOT_LIST <<<"$ROOTS"
IFS=, read -r -a TAGS <<<"$VERSIONS"
[ "${#ROOT_LIST[@]}" -gt 0 ] && [ "${#TAGS[@]}" -gt 0 ] || { echo "--roots and --versions must name something" >&2; exit 2; }

command -v "$LAKE" >/dev/null 2>&1 || { echo "no lake at $LAKE; set LAKE" >&2; exit 2; }
command -v "$ELAN" >/dev/null 2>&1 || { echo "no elan at $ELAN; set ELAN" >&2; exit 2; }
[ -x "$LITEDOC4" ] || {
  echo "no litedoc4 at $LITEDOC4; tools/build-lean-exe.sh --toolchain-from e2e/micro" >&2; exit 2; }

MARK=.mv-m-run
if [ -e "$WORK" ] && [ ! -f "$WORK/$MARK" ] && [ -n "$(ls -A "$WORK")" ]; then
  echo "$WORK is not empty and is not a work directory of this script; refusing to touch it" >&2
  exit 2
fi
if [ -e "$WORK/store" ] || [ -e "$WORK/logs" ]; then
  echo "$WORK holds a previous run (store/ or logs/); move it away or delete it first" >&2
  exit 2
fi
mkdir -p "$WORK/logs"
touch "$WORK/$MARK"
LOGS="$WORK/logs"
JSONL="$LOGS/phases.jsonl"
STORE="$WORK/store"
CURRENT=""
on_exit 'if [ -n "$CURRENT" ] && [ "$KEEP" -eq 0 ]; then rm -rf "$WORK/checkout/$CURRENT" "$WORK/cache/$CURRENT" "$WORK/build/$CURRENT"; fi'

avail_kb () { df -k "$WORK" | awk 'NR == 2 { print $4 }'; }
work_kb () { du -sk "$WORK" 2>/dev/null | awk '{ print $1 }'; }

PH_BEFORE=0
PH_RC=0
phase () {
  local tag="$1" name="$2" dir="$3"
  shift 3
  local base="$LOGS/$tag-$name"
  PH_BEFORE="$(avail_kb)"
  PH_RC=0
  ( cd "$dir" && exec /usr/bin/time -l -o "$base.time" "$@" ) >"$base.out" 2>"$base.err" || PH_RC=$?
  if [ "$PH_RC" -ne 0 ]; then
    echo "$tag $name: exited $PH_RC; the end of $base.err and $base.out:" >&2
    tail -c 2000 "$base.err" >&2 || true
    tail -c 2000 "$base.out" >&2 || true
  fi
}

record () {
  local tag="$1" name="$2"
  shift 2
  python3 - "$JSONL" "$LOGS/$tag-$name.time" "$tag" "$name" \
    "exit=$PH_RC" "freeBeforeKiB=$PH_BEFORE" "freeAfterKiB=$(avail_kb)" "workKiB=$(work_kb)" \
    "$@" <<'PY'
import json
import os
import re
import sys

jsonl, timefile, tag, name = sys.argv[1:5]
rec = {"version": tag, "phase": name}
if os.path.exists(timefile):
    text = open(timefile, encoding="utf-8", errors="replace").read()
    m = re.search(r"([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys", text)
    if m:
        rec["wallSeconds"] = float(m.group(1))
        rec["userSeconds"] = float(m.group(2))
        rec["sysSeconds"] = float(m.group(3))
        rec["cpuSeconds"] = round(float(m.group(2)) + float(m.group(3)), 2)
    for key, label in (("maxRssBytes", "maximum resident set size"),
                       ("pageReclaims", "page reclaims"),
                       ("pageFaults", "page faults"),
                       ("peakFootprintBytes", "peak memory footprint")):
        m = re.search(r"(\d+)\s+%s" % re.escape(label), text)
        if m:
            rec[key] = int(m.group(1))
counts = {}
for kv in sys.argv[5:]:
    k, _, v = kv.partition("=")
    try:
        val = int(v)
    except ValueError:
        val = v
    if k in ("exit", "freeBeforeKiB", "freeAfterKiB", "workKiB"):
        rec[k] = val
    else:
        counts[k] = val
rec["counts"] = counts
with open(jsonl, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, sort_keys=True) + "\n")
PY
}

fail () { echo "MV-M RUN: $*" >&2; exit 1; }

closure_of () {
  python3 - "$1" "${ROOT_LIST[@]}" <<'PY'
import os
import sys

root, roots = sys.argv[1], sys.argv[2:]
KW = {"public", "meta", "private", "all", "import"}


def imports(path):
    out, depth = [], 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if depth:
                depth += s.count("/-") - s.count("-/")
                continue
            if s.startswith("/-"):
                depth = s.count("/-") - s.count("-/")
                continue
            if s == "" or s.startswith("--"):
                continue
            toks = s.split("--")[0].split()
            if toks and toks[0] in ("module", "prelude"):
                continue
            if toks and toks[0] in KW and "import" in toks:
                out += [t for t in toks if t not in KW]
                continue
            break
    return out


def source(m):
    return os.path.join(root, *m.split(".")) + ".lean"


for r in roots:
    if not os.path.isfile(source(r)):
        sys.stderr.write("root %s has no source %s\n" % (r, source(r)))
        sys.exit(3)
seen, stack = set(), list(roots)
while stack:
    m = stack.pop()
    if m in seen:
        continue
    seen.add(m)
    for i in imports(source(m)):
        if i == "Mathlib" or i.startswith("Mathlib."):
            if not os.path.isfile(source(i)):
                sys.stderr.write("%s imports %s, which has no source\n" % (m, i))
                sys.exit(3)
            stack.append(i)
print("\n".join(sorted(seen)))
PY
}

oleans_of () {
  python3 - "$1/.lake/build/lib/lean" <<'PY'
import os
import sys

base = sys.argv[1]
out = []
if os.path.isfile(os.path.join(base, "Mathlib.olean")):
    out.append("Mathlib")
for d, _, files in os.walk(os.path.join(base, "Mathlib")):
    for fn in files:
        if fn.endswith(".olean"):
            rel = os.path.relpath(os.path.join(d, fn), base)[: -len(".olean")]
            out.append(rel.replace(os.sep, "."))
print("\n".join(sorted(out)))
PY
}

prune () {
  python3 - "$1" "$2" <<'PY'
import os
import sys

root, listed = sys.argv[1], sys.argv[2]
keep = set(open(listed, encoding="utf-8").read().split())
gone = 0
top = os.path.join(root, "Mathlib.lean")
if "Mathlib" not in keep and os.path.isfile(top):
    os.remove(top)
    gone += 1
for d, _, files in os.walk(os.path.join(root, "Mathlib")):
    for fn in files:
        if fn.endswith(".lean"):
            p = os.path.join(d, fn)
            m = os.path.relpath(p, root)[: -len(".lean")].replace(os.sep, ".")
            if m not in keep:
                os.remove(p)
                gone += 1
print(gone)
PY
}

build_counts () {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import os
import sys

out, timings, closure = sys.argv[1:4]
closure = set(open(closure, encoding="utf-8").read().split())


def tree(path):
    files = size = 0
    for d, _, fs in os.walk(path):
        for f in fs:
            files += 1
            size += os.path.getsize(os.path.join(d, f))
    return files, size


def decls(node):
    if isinstance(node, dict):
        if "module" in node and isinstance(node.get("declarations"), int):
            return node["declarations"]
        return sum(decls(v) for v in node.values())
    if isinstance(node, list):
        return sum(decls(v) for v in node)
    return 0


r = json.loads(open(timings, encoding="utf-8").read().splitlines()[-1])
ir_files, ir_bytes = tree(os.path.join(out, "ir"))
site_files, site_bytes = tree(os.path.join(out, "site"))
lidx = os.path.join(out, "link-index.lidx")
known, groups = set(), []
with open(lidx, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("@"):
            known.add(line[1:])
        elif line and not line.startswith("#") and not line.startswith("\t"):
            groups.append(line)
mathlib_known = {m for m in known if m == "Mathlib" or m.startswith("Mathlib.")}
mathlib_groups = [g for g in groups if g == "Mathlib" or g.startswith("Mathlib.")]
print("modules=%s" % r.get("modules"))
print("declarations=%d" % decls(json.load(open(os.path.join(out, "ir", "index.json"), encoding="utf-8"))))
print("irFiles=%d" % ir_files)
print("irBytes=%d" % ir_bytes)
print("linkIndexBytes=%d" % os.path.getsize(lidx))
print("linkIndexModules=%d" % len(known))
print("linkIndexGroups=%d" % len(groups))
print("siteFiles=%d" % site_files)
print("siteBytes=%d" % site_bytes)
for k in ("extractSeconds", "renderSeconds", "globalSeconds", "totalSeconds", "pagesRendered"):
    if k in r:
        print("%s=%s" % (k, r[k]))
print("mathlibInEnvNotInClosure=%d" % len(mathlib_known - closure))
print("closureNotInEnv=%d" % len(closure - mathlib_known))
print("mathlibGroupsInLinkIndex=%d" % len(mathlib_groups))
PY
}

kv () { sed -n "s/^$1=//p" "$2"; }

{
  echo "run of $(git -C "$ROOT" rev-parse HEAD) ($(git -C "$ROOT" status --porcelain | wc -l | tr -d ' ') uncommitted path(s))"
  record_host
  echo "roots    $ROOTS"
  echo "versions $VERSIONS"
  echo "jobs     $JOBS"
} | tee "$LOGS/conditions.txt"
PH_RC=0; PH_BEFORE="$(avail_kb)"
record run conditions "litedoc4Commit=$(git -C "$ROOT" rev-parse HEAD)" "roots=$ROOTS" \
  "versions=$VERSIONS" "jobs=$JOBS" "host=$(uname -srm) / $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?') / $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"

STARTED=$SECONDS
for tag in "${TAGS[@]}"; do
  echo
  echo "=== $tag"
  free_kb="$(avail_kb)"
  need_kb=$((NEED_GB * 1024 * 1024))
  if [ "$free_kb" -lt "$need_kb" ]; then
    fail "$((free_kb / 1024)) MiB free on $WORK, and one version needs --need-gb $NEED_GB ($((need_kb / 1024)) MiB) before it starts"
  fi
  CURRENT="$tag"
  CO="$WORK/checkout/$tag"
  CACHE="$WORK/cache/$tag"
  OUT="$WORK/build/$tag"
  rm -rf "$CO" "$CACHE" "$OUT"
  mkdir -p "$CO" "$CACHE" "$WORK/build"
  export MATHLIB_CACHE_DIR="$CACHE"

  phase "$tag" fetch "$CO" bash -c 'git init -q && git remote add origin "$1" &&
    git fetch -q --depth 1 origin "refs/tags/$2:refs/tags/$2" &&
    git -c advice.detachedHead=false checkout -q "refs/tags/$2"' _ "$REPO" "$tag"
  [ "$PH_RC" -eq 0 ] || fail "$tag: the fetch failed"
  commit="$(git -C "$CO" rev-parse HEAD)"
  tagged="$(git -C "$CO" rev-parse "refs/tags/${tag}^{commit}")"
  [ "$commit" = "$tagged" ] || fail "$tag: HEAD is $commit and the tag is $tagged"
  toolchain="$(tr -d '[:space:]' <"$CO/lean-toolchain")"
  record "$tag" fetch "commit=$commit" "toolchain=$toolchain" \
    "sourceFiles=$(git -C "$CO" ls-files | wc -l | tr -d ' ')"
  echo "$tag $commit $toolchain"

  if "$ELAN" toolchain list | awk -v t="$toolchain" '$1 == t { found = 1 } END { exit !found }'; then
    installed=already
    PH_BEFORE="$(avail_kb)"; PH_RC=0
  else
    installed=now
    phase "$tag" toolchain "$CO" "$ELAN" toolchain install "$toolchain"
    [ "$PH_RC" -eq 0 ] || fail "$tag: elan could not install $toolchain"
  fi
  record "$tag" toolchain "toolchain=$toolchain" "installed=$installed"

  PH_BEFORE="$(avail_kb)"
  set +e
  closure_of "$CO" >"$LOGS/$tag-closure.txt" 2>"$LOGS/$tag-closure.err"
  PH_RC=$?
  set -e
  [ "$PH_RC" -eq 0 ] || fail "$tag: the closure could not be read: $(tail -n 1 "$LOGS/$tag-closure.err")"
  closure_n="$(wc -l <"$LOGS/$tag-closure.txt" | tr -d ' ')"
  record "$tag" closure "modules=$closure_n"
  echo "closure  $closure_n Mathlib module(s) from the import lines"
  if [ "$LIMIT" -gt 0 ] && [ "$closure_n" -gt "$LIMIT" ]; then
    fail "$tag: the closure of $ROOTS is $closure_n modules, above --limit-modules $LIMIT"
  fi

  phase "$tag" deps "$CO" "$LAKE" env true
  [ "$PH_RC" -eq 0 ] || fail "$tag: lake could not resolve the packages"
  record "$tag" deps "packages=$(find "$CO/.lake/packages" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"

  phase "$tag" cache "$CO" "$LAKE" exe cache get "${ROOT_LIST[@]}"
  [ "$PH_RC" -eq 0 ] || fail "$tag: lake exe cache get failed"
  oleans_of "$CO" >"$LOGS/$tag-oleans.txt"
  olean_n="$(wc -l <"$LOGS/$tag-oleans.txt" | tr -d ' ')"
  attempted="$(tr '\r' '\n' <"$LOGS/$tag-cache.out" | sed -n 's/^Attempting to download \([0-9]*\) file.*/\1/p' | tail -n 1)"
  decompressed="$(tr '\r' '\n' <"$LOGS/$tag-cache.out" | sed -n 's/^Decompressed \([0-9]*\) file.*/\1/p' | tail -n 1)"
  record "$tag" cache "mathlibOleans=$olean_n" "attempted=${attempted:-?}" \
    "decompressed=${decompressed:-?}" "cacheKiB=$(du -sk "$CACHE" | awk '{ print $1 }')" \
    "lakeKiB=$(du -sk "$CO/.lake" | awk '{ print $1 }')"
  if ! /usr/bin/diff "$LOGS/$tag-closure.txt" "$LOGS/$tag-oleans.txt" >"$LOGS/$tag-closure-vs-oleans.diff"; then
    fail "$tag: the import-line closure ($closure_n) and the oleans the cache unpacked ($olean_n) differ: $LOGS/$tag-closure-vs-oleans.diff"
  fi
  echo "cache    $olean_n Mathlib olean(s), equal to the closure; ${decompressed:-?} file(s) decompressed"

  phase "$tag" lake "$CO" "$LAKE" build --no-build "${ROOT_LIST[@]}"
  compiled=0
  if [ "$PH_RC" -ne 0 ]; then
    record "$tag" lake "noBuild=refused"
    phase "$tag" lake-build "$CO" "$LAKE" build "${ROOT_LIST[@]}"
    [ "$PH_RC" -eq 0 ] || fail "$tag: lake build failed"
    compiled="$(rg -c '\] Built ' "$LOGS/$tag-lake-build.out" || true)"
    record "$tag" lake-build "compiled=${compiled:-0}"
  else
    record "$tag" lake "noBuild=ok" "compiled=0"
  fi
  echo "lake     ${compiled:-0} module(s) compiled"

  phase "$tag" extractor "$CO" bash -c 'source "$1/tools/lib/common.sh" && micro_extractor "$1" "$2" "$3" "$4"' \
    _ "$ROOT" "$CO" "$LAKE" "$LOGS/$tag-extractor-build.log"
  [ "$PH_RC" -eq 0 ] || fail "$tag: the extractor did not build ($LOGS/$tag-extractor-build.log)"
  EXE="$(tail -n 1 "$LOGS/$tag-extractor.out")"
  [ -x "$EXE" ] || fail "$tag: no extractor at $EXE"
  record "$tag" extractor "binaryBytes=$(wc -c <"$EXE" | tr -d ' ')"

  PH_BEFORE="$(avail_kb)"; PH_RC=0
  gone="$(prune "$CO" "$LOGS/$tag-closure.txt")"
  printf 'title = "Mathlib %s (M slice)"\nno_equations_under = ["Mathlib.Tactic", "Mathlib.Meta"]\n' "$tag" >"$CO/litedoc4.toml"
  left="$(find "$CO/Mathlib" -name '*.lean' | wc -l | tr -d ' ')"
  if [ -f "$CO/Mathlib.lean" ]; then left=$((left + 1)); fi
  record "$tag" prune "deleted=$gone" "left=$left"
  [ "$left" -eq "$closure_n" ] || fail "$tag: $left Mathlib source(s) left after pruning, and the closure is $closure_n"

  phase "$tag" build "$WORK" "$LITEDOC4" build --root "$CO" --lib Mathlib --out "$OUT" \
    --extractor-bin "$EXE" --lake "$LAKE" --jobs "$JOBS" --timings "$LOGS/$tag-build.timings.json"
  [ "$PH_RC" -eq 0 ] || fail "$tag: litedoc4 build failed"
  build_counts "$OUT" "$LOGS/$tag-build.timings.json" "$LOGS/$tag-closure.txt" >"$LOGS/$tag-build.counts"
  # shellcheck disable=SC2046  # one key=value per line, none with a space
  record "$tag" build $(cat "$LOGS/$tag-build.counts")
  [ "$(kv modules "$LOGS/$tag-build.counts")" = "$closure_n" ] ||
    fail "$tag: build globbed $(kv modules "$LOGS/$tag-build.counts") module(s), the closure is $closure_n"
  for k in mathlibInEnvNotInClosure closureNotInEnv mathlibGroupsInLinkIndex; do
    [ "$(kv "$k" "$LOGS/$tag-build.counts")" = 0 ] ||
      fail "$tag: $k is $(kv "$k" "$LOGS/$tag-build.counts") ($LOGS/$tag-build.counts): the extraction is not exactly the closure"
  done
  echo "build    $(kv modules "$LOGS/$tag-build.counts") module(s), $(kv declarations "$LOGS/$tag-build.counts") declaration(s); Lean's environment holds exactly the closure"

  phase "$tag" put "$WORK" "$LITEDOC4" store put --store "$STORE" --version "$tag" --from "$OUT" --lake "$LAKE"
  [ "$PH_RC" -eq 0 ] || fail "$tag: store put failed"
  put_json="$(rg '^\{"command":"store put"' "$LOGS/$tag-put.out" || true)"
  # shellcheck disable=SC2046
  record "$tag" put $(printf '%s' "$put_json" | python3 -c 'import json,sys
d = json.loads(sys.stdin.read() or "{}")
print(" ".join("%s=%s" % (k, d[k]) for k in ("files", "rawBytes", "linkIndexBytes", "packedBytes", "compressedBytes") if k in d))')

  phase "$tag" read "$WORK" "$LITEDOC4" store read --store "$STORE" --version "$tag" --out "$WORK/read-$tag"
  [ "$PH_RC" -eq 0 ] || fail "$tag: store read failed"
  same=yes
  /usr/bin/diff -r "$OUT/ir" "$WORK/read-$tag/ir" >"$LOGS/$tag-round-trip.diff" 2>&1 || same=no
  cmp -s "$OUT/link-index.lidx" "$WORK/read-$tag/link-index.lidx" || same=no
  record "$tag" read "identical=$same"
  rm -rf "$WORK/read-$tag"
  [ "$same" = yes ] || fail "$tag: what the store gives back differs from the build ($LOGS/$tag-round-trip.diff)"
  echo "store    put and read back byte-identical"

  if [ "$KEEP" -eq 0 ]; then rm -rf "$CO" "$CACHE" "$OUT"; fi
  CURRENT=""
done

echo
echo "=== store measure over $VERSIONS"
mkdir -p "$WORK/measure"
for c in a b c; do
  phase measure "$c" "$WORK" "$LITEDOC4" store measure --store "$STORE" --versions "$VERSIONS" \
    --candidate "$c" --out "$WORK/measure/$c"
  [ "$PH_RC" -eq 0 ] || fail "store measure --candidate $c failed"
  cp "$LOGS/measure-$c.out" "$WORK/measure/$c.json"
  record measure "$c"
done

echo
echo "=== summary"
python3 - "$JSONL" "$WORK/measure" <<'PY'
import json
import pathlib
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
print("per phase (wall/cpu s, peak RSS MiB, page faults, work dir after GiB, free after GiB):")
for r in rows:
    if r["phase"] == "conditions":
        continue
    c = r.get("counts", {})
    shown = " ".join("%s=%s" % (k, v) for k, v in sorted(c.items()) if k not in ("commit",))
    print(" %-8s %-10s %7s %7s %7s %6s %6.2f %6.2f  %s" % (
        r["version"], r["phase"],
        r.get("wallSeconds", "-"), r.get("cpuSeconds", "-"),
        "%.0f" % (r["maxRssBytes"] / 2**20) if "maxRssBytes" in r else "-",
        r.get("pageFaults", "-"),
        r.get("workKiB", 0) / 2**20, r.get("freeAfterKiB", 0) / 2**20, shown))
peak = {}
for r in rows:
    if r["version"] not in ("run", "measure"):
        peak[r["version"]] = max(peak.get(r["version"], 0), r.get("workKiB", 0))
for v, k in peak.items():
    print("peak work dir during %s: %.2f GiB" % (v, k / 2**20))
measure = pathlib.Path(sys.argv[2])
for c in ("a", "b", "c"):
    p = measure / ("%s.json" % c)
    if not p.exists():
        continue
    d = json.loads(p.read_text(encoding="utf-8"))
    h = d["hosted"]
    chunk = d.get("chunkBytes")
    print("candidate %s: hosted files=%d raw=%d stored=%d%s" % (
        c, h["files"], h["rawBytes"], h["storedBytes"], "" if chunk is None else " chunkBytes=%d" % chunk))
    print(" %-8s %5s %6s %6s %6s %6s | %6s %8s %8s %7s %7s | %13s %17s" % (
        "ver", "pages", "items", "addr", "new", "links", "+files", "+raw", "+stored", "+cfiles", "+citems",
        "fetch tot/max", "bytes tot/max"))
    for v in d["versions"]:
        a, w = v["added"], v["view"]
        print(" %-8s %5d %6d %6d %6d %6d | %6d %8d %8d %7d %7d | %6d/%-6d %9d/%-7d" % (
            v["version"], v["pages"], v["items"], v["addresses"], v["newAddresses"], v["linkNames"],
            a["files"], a["rawBytes"], a["storedBytes"], a["contentFiles"], a["contentItems"],
            w["fetches"]["total"], w["fetches"]["max"], w["bytes"]["total"], w["bytes"]["max"]))
PY
echo "total $((SECONDS - STARTED)) s; logs in $LOGS"
answer 0
