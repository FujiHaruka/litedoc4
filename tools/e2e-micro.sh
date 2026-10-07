#!/usr/bin/env bash
# End to end, on a machine that has never seen the measurement target.
#
# The unit tests hold their own inputs and never run a Lean toolchain —
# deliberately, because needing one would mean they were never run. The cost is
# that **the contract between the extractor and the rest of the pipeline is
# checked by nothing**: change what `Extract.lean` writes and every one of them
# stays green. This is the place where a real Lean environment produces a real IR
# and `litedoc4 build` turns it into a real site of one version, rendered from the
# store — the site pages.yml publishes. What a page shows once drawn is asked of
# the store-rendered sample S (tools/mv-s-gate.sh, tools/mv-pages-gate.sh); step
# 12 names where each question this script used to ask went.
#
# The sample package is tiny and Mathlib-free so that `lake build` takes about a
# second and this runs on a free CI runner; the measurement target pulls in all of
# Mathlib and can never be what a push is judged by. It holds, on purpose, the
# declaration shapes the target does not contain — `class`, `inductive`, `class
# inductive`, a non-`mk` constructor, an inherited field, an implicit binder on a
# field, an astral identifier (U+1D49C), scoped notation. Nine of the renderer's
# 41 branches never fire over the real package
# (git show rust-frozen:crates/litedoc4-render/tests/page_parts.rs, in that tag
# and not in this tree), and one of them was silently
# rendering nothing — an inductive's constructors missing from their page while
# the search index still linked to them (measured).
#
# **No assertion here is a duration.** The oleans are mmap'ed, so an unchanged
# run's environment load moves 5x with the page cache (2.5 s <-> 13 s (measured)):
# a threshold over seconds is either loose enough to pass a regression or tight
# enough to fail a cold runner. What is decidable is the *work* — deterministic
# integers — and it is read out of `litedoc4-build.json` rather than grepped out
# of the log, because a gate that greps prose stops testing the day the line is
# reworded and says nothing about it.
#
# usage: e2e-micro.sh [--out DIR] [--extractor BIN] [--keep]
#   --out        where to build (default: a temporary directory)
#   --extractor  a prebuilt extractor binary (default: build one into
#                e2e/micro/.lake/e2e-extract, which is gitignored)
#   --keep       do not delete a temporary --out on success
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
answer_required
SAMPLE="$ROOT/e2e/micro"
LAKE="${LAKE:-$HOME/.elan/bin/lake}"
LITEDOC4="${LITEDOC4:-$ROOT/.lake/build/bin/litedoc4}"

OUT=""
EXTRACTOR=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --extractor) EXTRACTOR="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '1,/^set -/p' "$0" | sed '$d'; answer 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

command -v "$LAKE" >/dev/null 2>&1 || { echo "no lake at $LAKE — set LAKE" >&2; exit 2; }
[ -x "$LITEDOC4" ] || {
  echo "no litedoc4 at $LITEDOC4 — tools/build-lean-exe.sh --toolchain-from e2e/micro" >&2; exit 2; }

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d)"
  TEMPORARY=1
else
  mkdir -p "$OUT"
  TEMPORARY=0
fi

say() { printf '\n=== %s\n' "$1"; }

# The one thing that moves between the toolchains this repository claims: Lean
# renamed the reducibility status of a reducible instance. The spelling comes out
# of tools/lean-toolchains.txt rather than out of a version comparison here, so
# that a toolchain nobody has run fails by name instead of failing forty lines
# into GATE 8 as a mismatched attribute.
TOOLCHAIN="$(cat "$SAMPLE/lean-toolchain")"
REDUCIBLE_ATTR="$(awk -v t="$TOOLCHAIN" '$1 == t { print $2 }' "$HERE/lean-toolchains.txt")"
if [ -z "$REDUCIBLE_ATTR" ]; then
  echo "e2e-micro: $TOOLCHAIN has no row in tools/lean-toolchains.txt — every version this repository claims is listed there" >&2
  exit 2
fi
echo "toolchain $TOOLCHAIN, reducible-instance attribute $REDUCIBLE_ATTR"

say "1/13 build the sample package (Lean core only)"
(cd "$SAMPLE" && "$LAKE" build)

say "2/13 build the extractor inside the sample's environment"
# The extractor is `import Lean` and nothing else, which is what lets it be built
# against a package that has no Mathlib.
if [ -z "$EXTRACTOR" ]; then
  EXTRACTOR="$(micro_extractor "$ROOT" "$SAMPLE" "$LAKE" "$OUT/extractor-build.log")"
fi

version_of () { # version_of <out>
  python3 - "$1/litedoc4-build.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("version") or "")
PY
}

say "3/13 GATE 1 — one command writes a site of one version"
rm -rf "$OUT/first"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/first" \
  --extractor-bin "$EXTRACTOR" >"$OUT/first.log"
VERSION="$(version_of "$OUT/first")"
[ -n "$VERSION" ] || { echo "GATE 1: the marker names no version" >&2; exit 1; }
python3 - "$OUT/first/site" "$OUT/first/ir" "$VERSION" "$(git -C "$SAMPLE" rev-parse HEAD)" <<'PY'
import json, pathlib, sys

site, ir, version, head = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
problems = []
listed = [e.get("name") for e in json.loads((site / "versions.json").read_text(encoding="utf-8"))]
if listed != [version]:
    problems.append(f"versions.json lists {listed}, not the one version [{version}]")
if version != head[:12]:
    problems.append(f"the version is {version}, not the first 12 hex digits of HEAD ({head[:12]})")
modules = [m["module"] for m in json.loads((ir / "index.json").read_text(encoding="utf-8"))["modules"]]
if not modules:
    problems.append("the IR holds no module")


def path_of(module):
    out, depth, start = [], 0, 0
    for i, c in enumerate(module):
        if c == "«":
            depth += 1
        elif c == "»":
            depth -= 1
        elif c == "." and depth == 0:
            out.append(module[start:i].strip("«»"))
            start = i + 1
    out.append(module[start:].strip("«»"))
    return "/".join(out)


missing = [m for m in modules if not (site / version / (path_of(m) + ".html")).is_file()]
if missing:
    problems.append(f"{len(missing)} of {len(modules)} module(s) have no page under {version}/: {missing[:4]}")
for name in ("index.html", "404.html", "assets/site.js", "assets/style.css", f"{version}/index.html"):
    if not (site / name).is_file():
        problems.append(f"no {name}")
for problem in problems:
    print(f"GATE 1 FAIL  {problem}", file=sys.stderr)
if problems:
    sys.exit(1)
print(f"site         version {version}: {len(modules)} module page(s), versions.json lists it alone")
PY
# The reader tools/mv-s-gate.sh asks of S, over the site the sample publishes.
mkdir -p "$OUT/builds"
ln -sfn "$OUT/first" "$OUT/builds/$VERSION"
python3 -I "$ROOT/benchmarks/tools/check-store-render.py" --site "$OUT/first/site" \
  --repo "$ROOT" --builds "$OUT/builds" --versions "$VERSION" \
  --only render-closure,render-usedby,render-content-ir >"$OUT/closure.txt" 2>&1 || true
cat "$OUT/closure.txt"
asked="$(grep -cE '^(ok|FAIL) ' "$OUT/closure.txt" || true)"
if [ "$asked" != 3 ] || grep -q '^FAIL ' "$OUT/closure.txt"; then
  echo "GATE 1: check-store-render.py answered ${asked:-0} of 3 items, or one failed" >&2
  exit 1
fi

# Snapshot *before* the second run touches the same directory: comparing the tree
# with a copy taken afterwards compares it with itself and passes whatever
# happens.
rm -rf "$OUT/first-snapshot"
cp -R "$OUT/first/site" "$OUT/first-snapshot"
cp "$OUT/first/litedoc4-build.json" "$OUT/first-build.json"

say "4/13 GATE 2 — the second run changes nothing"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/first" \
  --extractor-bin "$EXTRACTOR" >"$OUT/second.log"
# Bytes only; what the run *did* is GATE 5, out of the marker.
if ! /usr/bin/diff -r "$OUT/first-snapshot" "$OUT/first/site"; then
  echo "the second run changed the site" >&2
  exit 1
fi

say "5/13 GATE 3 — a second build from nothing is byte identical"
rm -rf "$OUT/again"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/again" \
  --extractor-bin "$EXTRACTOR" >"$OUT/again.log"
if ! /usr/bin/diff -r "$OUT/first/site" "$OUT/again/site"; then
  echo "two builds of the same world disagree — determinism is broken" >&2
  exit 1
fi
# The IR too: the site could agree while the tree it came from does not.
if ! /usr/bin/diff -r "$OUT/first/ir" "$OUT/again/ir"; then
  echo "two extractions of the same world disagree" >&2
  exit 1
fi

say "6/13 GATE 4 — --jobs does not change the output"
# The extractor splits declarations across threads inside one environment, and a
# parallel step that reorders its output is exactly the kind of thing that shows
# up as a diff on one machine and not another.
rm -rf "$OUT/jobs4"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/jobs4" \
  --extractor-bin "$EXTRACTOR" --jobs 4 >"$OUT/jobs4.log"
if ! /usr/bin/diff -r "$OUT/first/ir" "$OUT/jobs4/ir"; then
  echo "--jobs 4 extracted a different IR than --jobs 1" >&2
  exit 1
fi

say "7/13 GATE 5 — the work, as integers"
# Four markers: the first build (snapshotted before the second run overwrote it),
# the run over an unchanged world, and the two other builds from nothing.
python3 - \
  "$OUT/first-build.json" \
  "$OUT/first/litedoc4-build.json" \
  "$OUT/again/litedoc4-build.json" \
  "$OUT/jobs4/litedoc4-build.json" <<'PY'
import json
import sys

full_path, incr_path, again_path, jobs4_path = sys.argv[1:5]
problems = []


def load(path):
    with open(path) as handle:
        marker = json.load(handle)
    # `complete: false` writes `work: null` on purpose
    # (src/Litedoc4/Build.lean): a half-finished run's zeros are
    # indistinguishable from a successful incremental run's, so the marker
    # refuses to look like one.
    if marker.get("complete") is not True:
        sys.exit(f"{path}: complete is {marker.get('complete')!r}, not true")
    work = marker.get("work")
    if not isinstance(work, dict):
        sys.exit(f"{path}: no `work` record ({work!r})")
    return marker, work


full_marker, full = load(full_path)
incr_marker, incr = load(incr_path)
again_marker, again = load(again_path)
jobs4_marker, jobs4 = load(jobs4_path)

modules = full_marker["modules"]
if modules < 1:
    sys.exit(f"{full_path}: {modules} module(s) — the sample is empty")


def want(label, record, key, expected):
    got = record.get(key)
    if got != expected:
        problems.append(f"{label}: {key} is {got}, expected {expected}")


version = full_marker["version"]
# An equality and not a floor: a first build that extracted fewer modules than
# the package has left something out, and one that did more counted something
# twice.
want("first", full, "modulesExtracted", modules)
want("first", full, "extractorRequests", 1)
want("first", full_marker, "versionsExtracted", {"count": 1, "of": 1, "names": [version]})

# The second run, over a world that did not move, extracts nothing, and
# `extractorRequests` is the sharpest of the zeros: it says Lean was never
# started. The version is still put and rendered, which is not extraction.
want("incremental", incr, "modulesExtracted", 0)
want("incremental", incr, "extractorRequests", 0)
want("incremental", incr_marker, "versionsExtracted", {"count": 0, "of": 1, "names": []})
want("incremental", incr_marker, "version", version)

# GATE 3 says two builds from nothing produce the same bytes; this says they did
# the same amount of work to get there, which is the half that would otherwise be
# free to double silently.
for label, other in (("again", again), ("--jobs 4", jobs4)):
    if other != full:
        problems.append(
            f"{label}: did different work than the first build\n"
            f"    first: {json.dumps(full, sort_keys=True)}\n"
            f"    {label}: {json.dumps(other, sort_keys=True)}"
        )

for line in ("first", full), ("incremental", incr):
    print(f"{line[0]:12} {json.dumps(line[1], sort_keys=True)}")

if problems:
    for problem in problems:
        print(f"GATE 5 FAIL  {problem}", file=sys.stderr)
    sys.exit(1)
PY

say "8/13 GATE 15 — a one-version build keeps only the version it just built"
# --source-url names a second commit, so the sample needs no second commit of its own.
OTHER=e2e0000000000000000000000000000000000015
store_holds () { # store_holds <label> <store> <version>
  python3 - "$@" <<'PY'
import pathlib, sys
label, store, version = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
held = sorted(p.name for p in store.iterdir() if not p.name.startswith("."))
if held != [version]:
    sys.exit(f"GATE 15 FAIL  after the {label} build the store holds {held}, not [{version!r}] alone")
print(f"store        after the {label} build: {held}")
PY
}
rm -rf "$OUT/prune"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/prune" \
  --extractor-bin "$EXTRACTOR" >"$OUT/prune-first.log"
store_holds first "$OUT/prune/store" "$VERSION"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/prune" \
  --extractor-bin "$EXTRACTOR" \
  --source-url "https://github.com/FujiHaruka/litedoc4/blob/$OTHER/e2e/micro" >"$OUT/prune-second.log"
store_holds second "$OUT/prune/store" "${OTHER:0:12}"
rm -rf "$OUT/prune"

say "9/13 GATE 8 — attributes arrive split into name and value"
# The `[name, value]` split is made in the extractor because that is the only side
# that knows where the boundary is: `deprecated`'s value contains spaces,
# parentheses and quotes, `specialize`'s contains brackets, and a reader given the
# concatenation would have to guess.
#
# `Example/Attrs.lean` holds one declaration per *kind* of attribute the four
# collectors produce. The measurement target has none of the hard shapes — 163
# occurrences over 6 distinct strings, all bare names but one `deprecated`
# (measured 2026-08-21) — so this sample is where they exist at all. Reads the IR.
# Runs before GATE 6, which appends a probe declaration to the sample and rebuilds
# it.
#
# Three things, and the last two are why the first is not enough: the **pairs**
# are positive expectations over named declarations; the **shape** check says
# every attrs entry in the whole IR is two strings, so a collector left writing a
# concatenated string is caught even when it is none of theirs; and the **counts**
# per attribute name are the stray check in the form this field needs — attributes
# are not rare here, so "nobody else claims one" is false, and a collector that
# answered `simp` for everything would sail past two positive expectations. The
# numbers are this sample's, and the gate names which one to update.
python3 - "$OUT/first/ir" "$REDUCIBLE_ATTR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
# tools/lean-toolchains.txt names it; Lean renamed it between v4.32.2 and v4.33.0.
REDUCIBLE_INSTANCE = sys.argv[2]
if REDUCIBLE_INSTANCE == "UNMEASURED":
    # Deliberately here and not at the top of the script: the point of running a
    # toolchain nobody has run is to find out what it spells, and that is only
    # knowable once the IR exists. It still fails — an UNMEASURED row never goes
    # green — but it fails carrying the value to write down.
    seen = sorted(
        {
            attr[0]
            for path in (pathlib.Path(sys.argv[1]) / "modules").glob("*.json")
            for decl in json.loads(path.read_text(encoding="utf-8")).get("declarations", [])
            for attr in decl.get("attrs", [])
            if attr[0].endswith("_reducible")
        }
    )
    sys.exit(
        "GATE 8: this toolchain is UNMEASURED in tools/lean-toolchains.txt. "
        f"Lean spelled the reducible-instance attribute {seen!r} here — "
        "put that in column 2 and run this again."
    )
index = json.loads((root / "index.json").read_text(encoding="utf-8"))
if index.get("schemaVersion") != 5:
    sys.exit(f"{root}/index.json: schemaVersion is {index.get('schemaVersion')!r}, not 5")

# Exact and ordered. Order is doc-gen4's `customs ++ tags ++ enums ++
# parametric`, with the instance attributes appended after all four, and it is
# what the printed `@[a, b]` line looks like — so it is part of the answer.
DEPRECATED_VALUE = 'Example.Attrs.scale (since := "2026-08-21")'
expected = {
    # getCustomAttrs — the simp extension, and the reducibility status
    "Example.Attrs.scale_zero": [["simp", ""]],
    "Example.Attrs.Weight": [["reducible", ""]],
    # getTags — a tag attribute has no value at all
    "Example.Attrs.zero": [["match_pattern", ""]],
    # getEnumValues — the enum's own name *is* the attribute
    "Example.Attrs.scale": [["inline", ""]],
    # getParametricValues — the two that make the split necessary
    "Example.Attrs.applyTwice": [["specialize", "#[]"]],
    "Example.Attrs.scaleOld": [["deprecated", DEPRECATED_VALUE]],
    # InstanceInfo.ofDefinitionInfo — appended after the four collectors
    "Example.Attrs.tinyNat": [[REDUCIBLE_INSTANCE, ""], ["instance", "100"]],
    "Example.Attrs.tinyBool": [[REDUCIBLE_INSTANCE, ""], ["defaultInstance", "1000"]],
}

# A Python dict literal with a duplicate key keeps the last one, silently. The
# reducible-instance spelling below is a *variable*, so a toolchain that ever
# spelled it `reducible` would drop the 19 without a word (verified: the literal
# collapses from three keys to two). Checked rather than assumed.
LITERAL_ATTR_NAMES = {
    "reducible", "inline", "simp", "match_pattern", "specialize", "deprecated",
    "instance", "defaultInstance",
}
if REDUCIBLE_INSTANCE in LITERAL_ATTR_NAMES:
    sys.exit(
        f"GATE 8: this toolchain spells the reducible-instance attribute "
        f"{REDUCIBLE_INSTANCE!r}, which is already one of the names counted below — "
        "the two would silently become one entry. Split them before trusting this gate."
    )

name_counts = {
    # Every structure projection is `@[reducible]`, and `Example/Gen.lean` declares
    # six structures.
    "reducible": 19,
    REDUCIBLE_INSTANCE: 6,
    "inline": 2,
    "simp": 1,
    "match_pattern": 1,
    "specialize": 1,
    "deprecated": 1,
    "instance": 1,
    "defaultInstance": 1,
}
# Attributes that carry a value at all. A writer that put the whole
# concatenation in the name half would still produce well-shaped pairs and would
# still be caught by `name_counts`; this is the same claim said as one number,
# and it is the one that goes to zero if the value half is ever dropped.
VALUED = 4

problems = []
found = {}
malformed = []
counts = {}
valued = 0
for entry in index["modules"]:
    module = json.loads((root / entry["file"]).read_text(encoding="utf-8"))
    for decl in module["declarations"]:
        attrs = decl.get("attrs", [])
        found[decl["name"]] = attrs
        for attr in attrs:
            ok = (
                isinstance(attr, list)
                and len(attr) == 2
                and all(isinstance(part, str) for part in attr)
            )
            if not ok:
                malformed.append((decl["name"], attr))
                continue
            counts[attr[0]] = counts.get(attr[0], 0) + 1
            if attr[1]:
                valued += 1

checked = 0
for name, want in sorted(expected.items()):
    if name not in found:
        problems.append(f"{name} is not in the IR at all — the sample lost a shape")
        continue
    checked += 1
    got = found[name]
    if got != want:
        problems.append(f"{name}: attrs are {json.dumps(got)}, expected {json.dumps(want)}")

if checked != len(expected):
    problems.append(f"{checked} of {len(expected)} declarations were actually compared")

for decl_name, attr in malformed[:5]:
    problems.append(
        f"{decl_name}: attrs entry {json.dumps(attr)} is not a two-element "
        "[name, value] array of strings — a schema-4 string reached a schema-5 IR"
    )
if len(malformed) > 5:
    problems.append(f"... and {len(malformed) - 5} more malformed attrs entries")

for attr_name in sorted(set(counts) | set(name_counts)):
    got = counts.get(attr_name, 0)
    want = name_counts.get(attr_name, 0)
    if got != want:
        problems.append(
            f"{attr_name}: {got} declaration(s) claim it, expected {want}"
        )

if valued != VALUED:
    problems.append(f"{valued} attribute(s) carry a value, expected {VALUED}")

if problems:
    for problem in problems:
        print(f"GATE 8 FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(f"attrs        {checked} declarations compared, {sum(counts.values())} pair(s) over "
      f"{len(counts)} attribute name(s), {valued} with a value")
PY

say "10/13 GATE 6 — one edited module is the one module extracted"
# GATE 2 asks what an *unchanged* world costs; this asks what a one-declaration
# edit costs, which is the shape a user actually produces.
#
# Three assertions. **The map does not move**: `link-index.lidx` is byte-identical
# across the edit, so an extractor that writes the package's own declarations
# into the map fails here. **One module is extracted** (tools/onemod-gate.sh).
# **The tree is a build from nothing** is the *oracle*: a merge that dropped or
# kept the wrong thing is silent in every count, so what the incremental run left
# on disk — the IR and the site rendered from it — has to be what a build from
# nothing over the edited sources writes.
PROBE="$SAMPLE/Example/Basic.lean"
cp "$PROBE" "$OUT/probe.orig"
# `set -e` must not leave the sample edited: everything below this line runs
# under a trap that puts the file back, including the failure paths.
# `if`, not `[ … ] && cp`: an EXIT trap's last command decides the script's exit
# status, and with a temporary --out this function runs *after* `$OUT` has been
# deleted, so the test is false and the `&&` form returned 1 — this script printed
# "E2E MICRO: ok" and exited 1 (measured 2026-08-18). A failing `cp` still fails here.
restore_probe () {
  if [ -f "$OUT/probe.orig" ]; then cp "$OUT/probe.orig" "$PROBE"; fi
}
on_exit restore_probe

cp "$OUT/first/link-index.lidx" "$OUT/lidx-before"
printf '\n/-- A probe appended by GATE 6; removed before this script exits. -/\ndef e2eGate6Probe_ : Nat := 13\n' >> "$PROBE"
(cd "$SAMPLE" && "$LAKE" build)

"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/first" \
  --extractor-bin "$EXTRACTOR" >"$OUT/edited.log"
rm -rf "$OUT/gate6-oracle"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/gate6-oracle" \
  --extractor-bin "$EXTRACTOR" >"$OUT/gate6-oracle.log"

restore_probe
(cd "$SAMPLE" && "$LAKE" build)

if ! cmp -s "$OUT/lidx-before" "$OUT/first/link-index.lidx"; then
  echo "GATE 6: link-index.lidx moved for a one-declaration edit" >&2
  /usr/bin/diff "$OUT/lidx-before" "$OUT/first/link-index.lidx" | head -6 >&2
  exit 1
fi
for tree in ir site; do
  if ! /usr/bin/diff -r -q "$OUT/gate6-oracle/$tree" "$OUT/first/$tree" >"$OUT/gate6-$tree.diff"; then
    echo "GATE 6: the incremental $tree is not what a build from nothing writes" >&2
    head -10 "$OUT/gate6-$tree.diff" >&2
    exit 1
  fi
done

# The same script runs on the Linux runner against the generated package
# (`ci-template.yml`), so what "a one-module edit is allowed to cost" is written
# down once and both callers get the same answer.
"$HERE/onemod-gate.sh" "$OUT/first/litedoc4-build.json" "$OUT/first/work/serve.out"

# `first/site` is what pages.yml publishes, and the probe is not the sample's.
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/first" \
  --extractor-bin "$EXTRACTOR" >"$OUT/restored.log"
if grep -rq e2eGate6Probe_ "$OUT/first/ir"; then
  echo "GATE 6: the probe is still in the IR after the sample was restored" >&2
  exit 1
fi

say "11/13 GATE 13 — every source link names a file that is really in this checkout"
# The sample is a package **inside** a repository, which the measurement target
# is not: the target *is* its repository, so the derived source URL needed no path
# to the package. The published sample site is what showed the gap —
# `blob/<rev>/Example/Basic.lean` where the file is at
# `e2e/micro/Example/Basic.lean` (measured 2026-08-29: 404 and 200 respectively).
# A page links at `<its version's source>/<module path>.lean`, so that is what is
# resolved, against this checkout rather than fetched: the answer must not depend
# on the network, on a rate limit, or on the commit having been pushed.
python3 - "$OUT/first/site" "$VERSION" "$ROOT" <<'LINKS'
import gzip
import json
import pathlib
import re
import subprocess
import sys

site, version, repo = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
remote = subprocess.run(
    ["git", "-C", str(repo), "config", "--get", "remote.origin.url"],
    capture_output=True, text=True,
).stdout.strip()
slug = re.sub(r"^.*github\.com[:/]", "", remote).removesuffix(".git").strip("/")
if not slug:
    sys.exit("GATE 13: no github remote to attribute source links to")


def data(address):
    return json.loads(gzip.decompress((site / "d" / f"{address}.json.gz").read_bytes()))


entry = next(e for e in json.loads((site / "versions.json").read_text(encoding="utf-8"))
             if e["name"] == version)
vf = data(entry["data"])
found = re.fullmatch("https://github\\.com/" + re.escape(slug) + "/blob/[0-9a-f]{40}/?(.*)", vf["source"])
if not found:
    sys.exit(f"GATE 13: the version's source is {vf['source']}, not a blob URL into {slug}")
prefix = found.group(1)
modules = data(vf["modules"])["modules"]
if not modules:
    sys.exit("GATE 13: the module list is empty — nothing was checked")


def lean_path(module):
    out, depth, start = [], 0, 0
    for i, c in enumerate(module):
        if c == "«":
            depth += 1
        elif c == "»":
            depth -= 1
        elif c == "." and depth == 0:
            out.append(module[start:i].strip("«»"))
            start = i + 1
    out.append(module[start:].strip("«»"))
    return "/".join(out) + ".lean"


missing = [lean_path(m["n"]) for m in modules if not (repo / prefix / lean_path(m["n"])).exists()]
for path in missing:
    print(f"GATE 13 FAIL  the site links to {prefix}/{path}, which is not in this checkout",
          file=sys.stderr)
if missing:
    sys.exit(1)
print(f"source links {len(modules)} module path(s) under {slug}/blob/<rev>/{prefix}, all present in the checkout")
LINKS

say "12/13 what moved out of this script"
cat <<'RETIRED'
GATE 7  (three sorry shapes)        -> tools/mv-s-gate.sh render-content-ir; tools/mv-pages-gate.sh path-flags
GATE 9  (origin of a realized decl) -> tools/mv-s-gate.sh render-content-ir; tools/mv-pages-gate.sh path-flags
GATE 10 (docstring math)            -> tools/mv-s-gate.sh render-math; tools/mv-pages-gate.sh mathml
GATE 11 (reverse references)        -> tools/mv-s-gate.sh render-usedby, and GATE 1 here
GATE 12 (litedoc4.toml)             -> tools/mv-s-gate.sh render-front, render-citation, render-references; tools/mv-pages-gate.sh path-titles
GATE 14 (module descriptions)       -> tools/mv-s-gate.sh render-summaries
RETIRED

say "13/13 summary"
printf 'version    : %s\n' "$VERSION"
printf 'site files : %s\n' "$(find "$OUT/first/site" -type f | wc -l | tr -d ' ')"
printf 'ir files   : %s\n' "$(find "$OUT/first/ir" -type f | wc -l | tr -d ' ')"
printf 'out        : %s\n' "$OUT"

if [ "$TEMPORARY" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
  rm -rf "$OUT"
fi
echo
echo "E2E MICRO: ok"
answer 0
