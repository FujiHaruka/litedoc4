#!/usr/bin/env bash
# Step 2 of docs/multiversion/implementation.md on a store mv-m-run.sh filled:
# every version rendered --runs times, each alone once, the output laid out by kind.
#
# usage: benchmarks/tools/mv-m-render.sh --store DIR --versions T,T [--work DIR]
#          [--runs N]
#   --store     a store whose entries are at the current record schema
#   --versions  the entries, oldest first (default: v4.32.2,v4.33.0,v4.33.1)
#   --work      absent or empty (default: /private/tmp/lean-doc-relay/mv-m-render)
#   --runs      full renders, timed (default: 5; the first two are the identity)
#   LITEDOC4    the binary (default: .lake/build/bin/litedoc4)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../../tools/lib/common.sh
source "$ROOT/tools/lib/common.sh" || exit 1
answer_required

LITEDOC4="${LITEDOC4:-$ROOT/.lake/build/bin/litedoc4}"
STORE=""
VERSIONS=v4.32.2,v4.33.0,v4.33.1
WORK=/private/tmp/lean-doc-relay/mv-m-render
RUNS=5
while [ $# -gt 0 ]; do
  case "$1" in
    --store) STORE="$2"; shift 2 ;;
    --versions) VERSIONS="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d'; answer 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -n "$STORE" ] && [ -d "$STORE" ] || { echo "--store names no directory" >&2; exit 2; }
[ "$RUNS" -ge 2 ] || { echo "--runs is below 2: the identity needs two renders" >&2; exit 2; }
[ -x "$LITEDOC4" ] || { echo "no litedoc4 at $LITEDOC4" >&2; exit 2; }
if [ -e "$WORK" ] && [ -n "$(ls -A "$WORK")" ]; then
  echo "$WORK is not empty; move it away or delete it first" >&2; exit 2
fi
IFS=, read -r -a TAGS <<<"$VERSIONS"
mkdir -p "$WORK/logs"
LOGS="$WORK/logs"

fail () { echo "MV-M RENDER: $*" >&2; exit 1; }

render () {
  local name="$1" list="$2" rc=0
  /usr/bin/time -l -o "$LOGS/$name.time" "$LITEDOC4" store render --store "$STORE" \
    --versions "$list" --out "$WORK/$name" >"$LOGS/$name.json" 2>"$LOGS/$name.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "store render $name exited $rc: $(tail -c 1000 "$LOGS/$name.err")"
}

{
  echo "run of $(git -C "$ROOT" rev-parse HEAD) ($(git -C "$ROOT" status --porcelain | wc -l | tr -d ' ') uncommitted path(s))"
  record_host
  echo "swap              $(sysctl -n vm.swapusage 2>/dev/null || echo '?')"
  echo "store             $STORE"
  echo "versions          $VERSIONS"
  echo "runs              $RUNS"
} | tee "$LOGS/conditions.txt"

for k in $(seq 1 "$RUNS"); do
  render "all-$k" "$VERSIONS"
  if [ "$k" -gt 1 ]; then
    same=yes
    /usr/bin/diff -r "$WORK/all-1" "$WORK/all-$k" >"$LOGS/all-$k.diff" 2>&1 || same=no
    cmp -s "$LOGS/all-1.json" "$LOGS/all-$k.json" || same=no
    echo "all-$k identical to all-1: $same" | tee -a "$LOGS/identity.txt"
    rm -rf "${WORK:?}/all-$k"
  fi
done

for v in "${TAGS[@]}"; do
  render "alone-$v" "$v"
  same=yes
  /usr/bin/diff -r "$WORK/alone-$v/$v" "$WORK/all-1/$v" >"$LOGS/alone-$v.diff" 2>&1 || same=no
  missing=0
  for f in "$WORK/alone-$v"/d/*; do
    cmp -s "$f" "$WORK/all-1/d/$(basename "$f")" || missing=$((missing + 1))
  done
  echo "alone-$v: shells identical to all-1's: $same; data files absent or other bytes in all-1/d: $missing of $(find "$WORK/alone-$v/d" -type f | wc -l | tr -d ' ')" |
    tee -a "$LOGS/identity.txt"
  rm -rf "${WORK:?}/alone-$v"
done

python3 - "$WORK/all-1" "$LOGS" "$VERSIONS" "$RUNS" >"$LOGS/summary.txt" 2>"$LOGS/summary.err" <<'PY2' || {
import gzip
import json
import os
import re
import statistics
import sys

site, logs, versions, runs = sys.argv[1], sys.argv[2], sys.argv[3].split(","), int(sys.argv[4])
d = os.path.join(site, "d")
on_disk = {f: os.path.getsize(os.path.join(d, f)) for f in os.listdir(d)}


def load(name):
    return gzip.decompress(open(os.path.join(d, name), "rb").read())


listed = json.load(open(os.path.join(site, "versions.json"), encoding="utf-8"))
if [e["name"] for e in listed] != versions:
    sys.exit("versions.json lists %s, not %s" % ([e["name"] for e in listed], versions))
ATTR = re.compile(r' data-([a-z-]+)="([^"]*)"')
KINDS = ("content", "page", "usedBy", "modules", "search", "instances", "references", "front", "version")
seen, out, view_lines = set(), [], []
for e in listed:
    v = e["name"]
    kinds = {}

    def add(kind, path):
        if path not in on_disk:
            sys.exit("%s: %s %s is not in d/" % (v, kind, path))
        kinds.setdefault(path, kind)

    vfile = e["data"] + ".json.gz"
    add("version", vfile)
    vj = json.loads(load(vfile))
    add("modules", vj["modules"] + ".json.gz")
    add("search", vj["search"] + ".bin.gz")
    add("instances", vj["instances"] + ".json.gz")
    add("references", vj["references"] + ".json.gz")
    if vj["front"] is not None:
        add("front", vj["front"] + ".json.gz")
    shells = shell_bytes = 0
    views = []
    for dirpath, _, files in os.walk(os.path.join(site, v)):
        for fn in files:
            p = os.path.join(dirpath, fn)
            shells += 1
            shell_bytes += os.path.getsize(p)
            attrs = dict(ATTR.findall(open(p, encoding="utf-8").read()))
            if "page" in attrs:
                page = attrs["page"] + ".json.gz"
                used = attrs["used-by"] + ".json.gz"
                add("page", page)
                add("usedBy", used)
                c = json.loads(load(page))["content"]
                fetched = [vfile, page, used]
                if c is not None:
                    add("content", c + ".json.gz")
                    fetched.append(c + ".json.gz")
                views.append(sum(on_disk[f] for f in fetched))
    ref = {k: [0, 0, 0] for k in KINDS}
    new = {k: [0, 0, 0] for k in KINDS}
    for path, kind in kinds.items():
        size, raw = on_disk[path], len(load(path))
        for t, cond in ((ref, True), (new, path not in seen)):
            if cond:
                t[kind][0] += 1
                t[kind][1] += raw
                t[kind][2] += size
    seen |= set(kinds)
    out.append((v, shells, shell_bytes, ref, new))
    modules_bytes = on_disk[vj["modules"] + ".json.gz"]
    view_lines.append("%s: a module page fetches its version, page, Used-by and content files: %d pages, %d B in all, max %d, median %.0f (the module list, if a page also fetches it: +%d B each)" % (
        v, len(views), sum(views), max(views), statistics.median(views), modules_bytes))

counts = json.load(open(os.path.join(logs, "all-1.json"), encoding="utf-8"))
bad = []
for (v, shells, shell_bytes, ref, new), c in zip(out, counts["versions"]):
    if c["shells"]["files"] != shells or c["shells"]["storedBytes"] != shell_bytes:
        bad.append("%s shells %s vs counted %d/%d" % (v, c["shells"], shells, shell_bytes))
    files = sum(t[0] for t in new.values())
    stored = sum(t[2] for t in new.values())
    if c["dataAdded"]["files"] != files or c["dataAdded"]["storedBytes"] != stored:
        bad.append("%s dataAdded %s vs counted %d/%d" % (v, c["dataAdded"], files, stored))
    if c["dataReferenced"] != sum(t[0] for t in ref.values()):
        bad.append("%s dataReferenced %d vs %d" % (v, c["dataReferenced"], sum(t[0] for t in ref.values())))
if seen != set(on_disk):
    bad.append("d/ holds %d file(s) no version references" % len(set(on_disk) - seen))
assets_dir = os.path.join(site, "assets")
assets = [os.path.join(dp, fn) for dp, _, fns in os.walk(assets_dir) for fn in fns]
assets_bytes = sum(os.path.getsize(p) for p in assets)
if counts["total"]["assets"]["files"] != len(assets) or counts["total"]["assets"]["storedBytes"] != assets_bytes:
    bad.append("assets %s vs counted %d/%d" % (counts["total"]["assets"], len(assets), assets_bytes))
top = sorted(os.listdir(site))
if top != sorted(["assets", "d", "index.html", "versions.json"] + versions):
    bad.append("the site root holds %s, not assets/, d/, index.html, versions.json and one directory per version" % top)
if counts["total"]["files"] != sum(len(fns) for _, _, fns in os.walk(site)):
    bad.append("total files %d vs %d on disk" % (counts["total"]["files"], sum(len(fns) for _, _, fns in os.walk(site))))
if bad:
    sys.exit("the renderer's counts and the tree disagree: " + "; ".join(bad))

t = counts["total"]
print("hosted (all %d versions): %d files, %d B stored (%d B raw)" % (len(versions), t["files"], t["storedBytes"], t["rawBytes"]))
print("  shells %d files %d B; data %d files %d B stored (%d B raw); assets %d files %d B; root %d files %d B" % (
    t["shells"]["files"], t["shells"]["storedBytes"], t["data"]["files"], t["data"]["storedBytes"],
    t["data"]["rawBytes"], t["assets"]["files"], t["assets"]["storedBytes"], t["root"]["files"],
    t["root"]["storedBytes"]))
print("reconciled with the renderer's counts: shells, data referenced and added per version, every d/ file referenced, assets/, every file of the site")
for v, shells, shell_bytes, ref, new in out:
    print()
    print("%s: %d shells (%d B)" % (v, shells, shell_bytes))
    print("  %-11s %22s %30s" % ("kind", "referenced files/stored", "added files/raw/stored"))
    for k in KINDS:
        print("  %-11s %8d %13d %8d %10d %10d" % (k, ref[k][0], ref[k][2], new[k][0], new[k][1], new[k][2]))
    print("  %-11s %8d %13d %8d %10d %10d" % ("total", sum(x[0] for x in ref.values()), sum(x[2] for x in ref.values()),
          sum(x[0] for x in new.values()), sum(x[1] for x in new.values()), sum(x[2] for x in new.values())))

print()
for line in view_lines:
    print(line)
print()
TIME = re.compile(r"([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys")
rows = []
for name in ["all-%d" % k for k in range(1, runs + 1)] + ["alone-%s" % v for v in versions]:
    text = open(os.path.join(logs, name + ".time"), encoding="utf-8").read()
    m = TIME.search(text)
    rss = int(re.search(r"(\d+)\s+maximum resident set size", text).group(1))
    pf = int(re.search(r"(\d+)\s+page faults", text).group(1))
    real, user, sys_ = float(m.group(1)), float(m.group(2)), float(m.group(3))
    rows.append((name, real, user + sys_, rss, pf))
    print("%-16s wall %6.2f s  cpu %6.2f s  peak RSS %6.0f MiB  page faults %d" % (name, real, user + sys_, rss / 2**20, pf))
full = [r for r in rows if r[0].startswith("all-")]
print("all versions, %d runs: median wall %.2f s, median cpu %.2f s, max peak RSS %.0f MiB" % (
    len(full), statistics.median(r[1] for r in full), statistics.median(r[2] for r in full),
    max(r[3] for r in full) / 2**20))
PY2
  tail -c 2000 "$LOGS/summary.err" >&2; fail "the layout by kind stopped"; }
cat "$LOGS/summary.txt"
if rg -q ': (no|[1-9][0-9]* of)' "$LOGS/identity.txt" || rg -q 'identical to all-1: no' "$LOGS/identity.txt"; then
  echo "MV-M RENDER: an identity does not hold ($LOGS/identity.txt)"
  answer 1
fi
answer 0
