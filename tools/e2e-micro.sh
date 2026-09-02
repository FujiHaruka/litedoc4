#!/usr/bin/env bash
# End to end, on a machine that has never seen the measurement target.
#
# The unit tests hold their own inputs and never run a Lean toolchain —
# deliberately, because needing one would mean they were never run. The cost is
# that **the contract between the extractor and the rest of the pipeline is
# checked by nothing**: change what `Extract.lean` writes and every one of them
# stays green. This is the one place
# where a real Lean environment produces a real IR and the real pipeline turns it
# into a real site.
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
    -h|--help) sed -n '1,/^set -/p' "$0" | sed '$d'; exit 0 ;;
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

say "1/17 build the sample package (Lean core only)"
(cd "$SAMPLE" && "$LAKE" build)

say "2/17 build the extractor inside the sample's environment"
# The extractor is `import Lean` and nothing else, which is what lets it be built
# against a package that has no Mathlib. `-rdynamic` is load-bearing:
# `importModules (loadExts := true)` resolves symbols in the running executable
# through the Lean interpreter.
if [ -z "$EXTRACTOR" ]; then
  EXTRACTOR="$(micro_extractor "$ROOT" "$SAMPLE" "$LAKE" "$OUT/extractor-build.log")"
fi

say "3/17 GATE 1 — one command"
rm -rf "$OUT/first"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/first" \
  --extractor-bin "$EXTRACTOR" | tee "$OUT/first.log"
[ -f "$OUT/first/site/index.html" ] || { echo "no site was written" >&2; exit 1; }

"$HERE/site-gate.sh" "$OUT/first/site"

# Snapshot *before* the second run touches the same directory: comparing the tree
# with a copy taken afterwards compares it with itself and passes whatever
# happens.
rm -rf "$OUT/first-snapshot"
cp -R "$OUT/first/site" "$OUT/first-snapshot"
# The marker too — the second run overwrites it in place, and its `work` record is
# half of GATE 5.
cp "$OUT/first/litedoc4-build.json" "$OUT/first-build.json"

say "4/17 GATE 2 — the second run changes nothing"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/first" \
  --extractor-bin "$EXTRACTOR" | tee "$OUT/second.log"

# Bytes only; what the run *did* is GATE 5, out of the marker.
if ! diff -r "$OUT/first-snapshot" "$OUT/first/site"; then
  echo "the second run changed the site" >&2
  exit 1
fi
if ! grep -qE 'incremental|0 module\(s\)|nothing to' "$OUT/second.log"; then
  echo "note: the second run's log does not name an incremental path:" >&2
  sed -n '1,20p' "$OUT/second.log" >&2
fi

say "5/17 GATE 3 — a second full build is byte identical"
rm -rf "$OUT/again"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/again" \
  --extractor-bin "$EXTRACTOR" >"$OUT/again.log"
if ! diff -r "$OUT/first/site" "$OUT/again/site"; then
  echo "two full builds of the same world disagree — determinism is broken" >&2
  exit 1
fi
# The IR too: the site could agree while the tree it came from does not.
if ! diff -r "$OUT/first/ir" "$OUT/again/ir"; then
  echo "two extractions of the same world disagree" >&2
  exit 1
fi

say "6/17 GATE 4 — --jobs does not change the output"
# The extractor splits declarations across threads inside one environment, and a
# parallel step that reorders its output is exactly the kind of thing that shows
# up as a diff on one machine and not another.
rm -rf "$OUT/jobs4"
"$LITEDOC4" build --root "$SAMPLE" --lib Example --out "$OUT/jobs4" \
  --extractor-bin "$EXTRACTOR" --jobs 4 >"$OUT/jobs4.log"
if ! diff -r "$OUT/first/ir" "$OUT/jobs4/ir"; then
  echo "--jobs 4 extracted a different IR than --jobs 1" >&2
  exit 1
fi
if ! diff -r "$OUT/first/site" "$OUT/jobs4/site"; then
  echo "--jobs 4 rendered a different site than --jobs 1" >&2
  exit 1
fi

say "7/17 GATE 5 — the work, as integers"
# Four markers: the first full build (snapshotted before the second run
# overwrote it), the incremental run over an unchanged world, and the two other
# full builds.
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
    got = record
    for part in key.split("."):
        got = got[part]
    if got != expected:
        problems.append(f"{label}: work.{key} is {got}, expected {expected}")


# An equality and not a floor: a full generation that extracted or rendered fewer
# modules than the package has left something out, and one that did more counted
# something twice.
want("full", full, "modulesExtracted", modules)
want("full", full, "pagesRendered", modules)
want("full", full, "extractorRequests", 1)
# From-scratch, so nothing can be cached yet — and a cache that suddenly hits on
# a run with no previous state is a cache reading somebody else's state.
want("full", full, "globalCacheHits", 0)
want("full", full, "globalCacheMisses", modules)

# The second run, over a world that did not move, does nothing. Each of these
# three zeros is the incremental path's whole reason to exist, and
# `extractorRequests` is the sharpest: its zero says Lean was never started.
want("incremental", incr, "modulesExtracted", 0)
want("incremental", incr, "pagesRendered", 0)
want("incremental", incr, "extractorRequests", 0)
want("incremental", incr, "globalCacheHits", modules)
want("incremental", incr, "globalCacheMisses", 0)

# The direction and not the exact count: pinning a number would make this script
# the place a deliberate change has to be argued, while no correct change reverses
# the direction.
full_reads = full["irReads"]["module"]
incr_reads = incr["irReads"]["module"]
if full_reads < modules:
    problems.append(
        f"full: work.irReads.module is {full_reads} for {modules} module(s) — "
        "a full build reads every module at least once"
    )
if incr_reads >= full_reads:
    problems.append(
        f"incremental: work.irReads.module is {incr_reads}, not fewer than the "
        f"full build's {full_reads} — the incremental path stopped saving IR reads"
    )

# GATE 3 says two full builds produce the same bytes; this says they did the same
# amount of work to get there, which is the half that would otherwise be free to
# double silently.
for label, other in (("again", again), ("--jobs 4", jobs4)):
    if other != full:
        problems.append(
            f"{label}: did different work than the first full build\n"
            f"    first: {json.dumps(full, sort_keys=True)}\n"
            f"    {label}: {json.dumps(other, sort_keys=True)}"
        )

for line in ("full", full), ("incremental", incr):
    print(f"{line[0]:12} {json.dumps(line[1], sort_keys=True)}")
passes = full["irReads"]["module"] / modules
print(f"{'ir passes':12} full {passes:.2f}  incremental {incr_reads / modules:.2f}")

if problems:
    for problem in problems:
        print(f"GATE 5 FAIL  {problem}", file=sys.stderr)
    sys.exit(1)
PY

say "8/17 GATE 7 — the three sorry shapes are three different answers"
# doc-gen4 #270 asks for two claims and not one: a declaration that uses `sorry`
# itself, and a declaration that merely depends on such a one. `Example/Sorry.lean`
# holds one of each plus a control, and **this is the only place the extractor's
# answer meets a real Lean environment**: `sorry` is a property of the elaborated
# term, so a hand-written IR fixture can check what the renderer does with the key
# but never that the extractor put the right value there. Reads the IR **and** the
# pages: a value the extractor gets right and no page prints is, to a reader, the
# same as no answer at all.
python3 - "$OUT/first/ir" "$OUT/first/site" <<'PY'
import html
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
index = json.loads((root / "index.json").read_text(encoding="utf-8"))

# `sorry` absent means "no sorry" **because the file says schema 5**. In a
# schema-4 file the key could not exist at all, so the same absence would mean
# "nobody was asked" — reading one as the other is the whole reason
# `Litedoc4.Ir`'s minimum schema version moved with the writer.
if index.get("schemaVersion") != 5:
    sys.exit(f"{root}/index.json: schemaVersion is {index.get('schemaVersion')!r}, not 5")

expected = {
    "Example.Sorry.sorryHole": "direct",
    "Example.Sorry.usesHole": "transitive",
    "Example.Sorry.noHole": None,
}
found = {}
for entry in index["modules"]:
    module = json.loads((root / entry["file"]).read_text(encoding="utf-8"))
    if module.get("schemaVersion") != 5:
        sys.exit(f"{entry['file']}: schemaVersion is {module.get('schemaVersion')!r}, not 5")
    for decl in module["declarations"]:
        found[decl["name"]] = decl.get("sorry")

problems = []
checked = 0
for name, want in sorted(expected.items()):
    if name not in found:
        problems.append(f"{name} is not in the IR at all — the sample lost a shape")
        continue
    checked += 1
    got = found[name]
    if got != want:
        problems.append(f"{name}: sorry is {got!r}, expected {want!r}")

# The count, not the absence of complaints: an expectation that never ran reports
# nothing.
if checked != len(expected):
    problems.append(f"{checked} of {len(expected)} shapes were actually compared")

# `noHole` shows the key can be absent for one declaration; this shows it is not
# being sprayed over the package. A classifier that answers "transitive" to
# everything passes the two positive expectations above and fails here.
strays = sorted(name for name, value in found.items() if value is not None and name not in expected)
if strays:
    problems.append(f"{len(strays)} other declaration(s) claim a sorry: {', '.join(strays[:5])}")

# The same three expectations again, against the bytes a reader gets. Keyed by
# `data-flag` and not by the pill's words, so this fails on a flag that stops
# being drawn rather than on one that is reworded.
site = pathlib.Path(sys.argv[2])
pill = {"direct": ["sorry-direct"], "transitive": ["sorry-transitive"], None: []}
blocks = {}
for page in sorted(site.rglob("*.html")):
    for chunk in re.split(r'(?=<section class="decl" id=")', page.read_text(encoding="utf-8")):
        head = re.match(r'<section class="decl" id="([^"]+)"', chunk)
        if head is None:
            continue
        blocks[html.unescape(head.group(1))] = re.findall(r'data-flag="(sorry-[a-z]+)"', chunk)

if not blocks:
    problems.append("no declaration block on any page — the site half checked nothing")
on_page = 0
for name, want in sorted(expected.items()):
    if name not in blocks:
        problems.append(f"{name} is in the IR and has no block on any page")
        continue
    on_page += 1
    if blocks[name] != pill[want]:
        problems.append(f"{name}: the page carries {blocks[name]}, the IR says {want!r}")
page_strays = sorted(name for name, flags in blocks.items() if flags and name not in expected)
if page_strays:
    problems.append(
        f"{len(page_strays)} other block(s) carry a sorry pill: {', '.join(page_strays[:5])}")

if problems:
    for problem in problems:
        print(f"GATE 7 FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(f"sorry        {checked} shapes compared over {len(found)} declarations, "
      f"{on_page} of them again over {len(blocks)} blocks on the site: " +
      ", ".join(f"{name.rpartition('.')[2]}={found[name]}" for name in sorted(expected)))
PY

say "9/17 GATE 8 — attributes arrive split into name and value"
# The `[name, value]` split is made in the extractor because that is the only side
# that knows where the boundary is: `deprecated`'s value contains spaces,
# parentheses and quotes, `specialize`'s contains brackets, and a reader given the
# concatenation would have to guess.
#
# `Example/Attrs.lean` holds one declaration per *kind* of attribute the four
# collectors produce. The measurement target has none of the hard shapes — 163
# occurrences over 6 distinct strings, all bare names but one `deprecated`
# (measured 2026-08-21) — so this sample is where they exist at all. Reads the IR,
# not the site: the page still prints the rejoined string. Runs before GATE 6,
# which appends a probe declaration to the sample and rebuilds it.
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

say "10/17 GATE 9 — the origin of a realized declaration, and the three ways of not having one"
# Lean gives a declaration it realizes from an attribute the position of **the
# attribute token**, and no rule over `(line, col)` gets from there to the parent:
# in a 144-group Mathlib sample the parent was in the group 0 times and 47 groups
# spanned two or more namespaces (measured). So the extractor names the origin
# itself, from core's `extExtension` plus `selectionRange`. Reads the IR and then
# the pages, which carry the same pair as a pill.
#
# Five things, and the last three are why the first is not enough. The
# **origins** are compared whole, positives *and* negatives — `Example.Gen.Solo.ext`
# is the sharp one, hand written and sitting in the same environment extension as
# the realized theorems, so a rule that only asked the extension would claim it.
# The **count** says how many expectations actually ran. The **strays** number is
# asserted rather than the absence of surprises, because a rule that answered
# "realized by ext" for everything passes every positive expectation. The **trap**
# is that `selectionRange == range` holds for **42** declarations here and only 9
# of them are realized by `@[ext]` — the other 33 are projections, constructors
# and a `scoped notation` — so a rule reading range equality as "generated" claims
# 42 and fails here (measured 2026-08-21, same shape over 2,786 Mathlib declarations
# → benchmarks/results/generated-decls-2026-08-21.txt). The **falsifier** is that
# every origin named is a declaration this IR has and none of the realized ones
# sorts before it — a property of one Lean version's `declRange` rather than a
# law, so it is counted rather than assumed.
python3 - "$OUT/first/ir" "$OUT/first/site" <<'PY'
import html
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
index = json.loads((root / "index.json").read_text(encoding="utf-8"))
if index.get("schemaVersion") != 5:
    sys.exit(f"{root}/index.json: schemaVersion is {index.get('schemaVersion')!r}, not 5")

# Negatives are expectations too: each `None` below is a *different* way of not
# being realized by `@[ext]`.
expected = {
    # `@[ext]` written on the structure: both theorems land inside its range.
    "Example.Gen.Pair.ext": ["ext", "Example.Gen.Pair"],
    "Example.Gen.Pair.ext_iff": ["ext", "Example.Gen.Pair.ext"],
    # `attribute [ext] Trip` on a later line: both land outside its range.
    "Example.Gen.Trip.ext": ["ext", "Example.Gen.Trip"],
    "Example.Gen.Trip.ext_iff": ["ext", "Example.Gen.Trip.ext"],
    # `attribute [ext] Quad Quint`: one position, two parents, four theorems.
    # No rule over positions splits this group; each still names its own.
    "Example.Gen.Quad.ext": ["ext", "Example.Gen.Quad"],
    "Example.Gen.Quad.ext_iff": ["ext", "Example.Gen.Quad.ext"],
    "Example.Gen.Quint.ext": ["ext", "Example.Gen.Quint"],
    "Example.Gen.Quint.ext_iff": ["ext", "Example.Gen.Quint.ext"],
    # Realized from a *hand-written* ext theorem, so it names the theorem.
    "Example.Gen.Solo.ext_iff": ["ext", "Example.Gen.Solo.ext"],
    # Hand written, and in `extExtension` exactly like the realized ones.
    "Example.Gen.Solo.ext": None,
    # Realized, but by `extends` rather than by `@[ext]`.
    "Example.Gen.PairPlus.toPair": None,
    # A projection: `selectionRange == range`, and not realized by `@[ext]`.
    "Example.Gen.Pair.fst": None,
    # The parent itself.
    "Example.Gen.Pair": None,
}

GENERATED = 9        # declarations with an origin, over the whole sample
SELECTION_EQ_RANGE = 42   # declarations whose two ranges are equal

found = {}
positions = {}
malformed = []
selection_eq = []
for entry in index["modules"]:
    module = json.loads((root / entry["file"]).read_text(encoding="utf-8"))
    if module.get("schemaVersion") != 5:
        sys.exit(f"{entry['file']}: schemaVersion is {module.get('schemaVersion')!r}, not 5")
    for decl in module["declarations"]:
        found[decl["name"]] = decl.get("generated")
        positions[decl["name"]] = (module["module"], decl["line"], decl["col"])
        sel = decl.get("selectionRange")
        ok = (
            isinstance(sel, list)
            and len(sel) == 4
            and all(isinstance(part, int) for part in sel)
        )
        if not ok:
            malformed.append((decl["name"], "selectionRange", sel))
            continue
        if sel == [decl["line"], decl["col"], decl["endLine"], decl["endCol"]]:
            selection_eq.append(decl["name"])
        gen = decl.get("generated")
        if gen is not None and not (
            isinstance(gen, list)
            and len(gen) == 2
            and all(isinstance(part, str) for part in gen)
        ):
            malformed.append((decl["name"], "generated", gen))

problems = []
checked = 0
for name, want in sorted(expected.items()):
    if name not in found:
        problems.append(f"{name} is not in the IR at all — the sample lost a shape")
        continue
    checked += 1
    got = found[name]
    if got != want:
        problems.append(
            f"{name}: generated is {json.dumps(got)}, expected {json.dumps(want)}"
        )

if checked != len(expected):
    problems.append(f"{checked} of {len(expected)} declarations were actually compared")

for decl_name, key, value in malformed[:5]:
    problems.append(f"{decl_name}: {key} is {json.dumps(value)}, not the shape the writer emits")
if len(malformed) > 5:
    problems.append(f"... and {len(malformed) - 5} more malformed keys")

claimed = sorted(name for name, value in found.items() if value is not None)
if len(claimed) != GENERATED:
    problems.append(
        f"{len(claimed)} declaration(s) claim an origin, expected {GENERATED}: "
        + ", ".join(claimed[:8])
    )
strays = [name for name in claimed if expected.get(name) is None]
if strays:
    problems.append(f"{len(strays)} unexpected declaration(s) claim an origin: {', '.join(strays[:5])}")

if len(selection_eq) != SELECTION_EQ_RANGE:
    problems.append(
        f"{len(selection_eq)} declaration(s) have selectionRange == range, "
        f"expected {SELECTION_EQ_RANGE}"
    )
equal_and_claimed = [name for name in selection_eq if found.get(name) is not None]
if len(equal_and_claimed) != GENERATED:
    problems.append(
        f"{len(equal_and_claimed)} of the {len(selection_eq)} declarations with "
        f"selectionRange == range claim an origin, expected {GENERATED}"
    )
if len(selection_eq) == len(equal_and_claimed):
    problems.append(
        "every declaration whose two ranges are equal claims an origin — the "
        "rule has collapsed into range equality, which is not what it means"
    )

# The falsifier, on this sample. The three-toolchain form of the same count is
# in benchmarks/results/generated-decls-2026-08-21.txt.
before = []
for name in claimed:
    origin = found[name][1]
    if origin not in positions:
        problems.append(f"{name} names {origin} as its origin, which is not in this IR")
        continue
    seen = set()
    while found.get(origin) is not None and origin not in seen:
        seen.add(origin)
        origin = found[origin][1]
        if origin not in positions:
            break
    if origin not in positions:
        problems.append(f"{name}'s origin chain leaves this IR at {origin}")
        continue
    if positions[name][0] == positions[origin][0] and positions[name][1:] < positions[origin][1:]:
        before.append(f"{name} at {positions[name][1:]} sorts before {origin} at {positions[origin][1:]}")
if before:
    problems.append(
        "a realized declaration sorts before its origin, which was measured "
        "as 0 on both samples: " + "; ".join(before[:3])
    )

# The pages carry the same pair, and the set is compared rather than each pill:
# a renderer that drew the pill on every declaration would satisfy all nine
# positive expectations. Every claimed declaration is a theorem here, so every
# one of them has a block of its own — a name that reaches this with no block is
# a page that lost it.
PILL = re.compile(r'<span class="flag" data-flag="generated">(.*?)</span>')
ORIGIN = re.compile(r'realized by <code>@\[([^\]]*)\]</code> from (?:<a [^>]*>)?<code>([^<]*)</code>')
site = pathlib.Path(sys.argv[2])
blocks = {}
for page in sorted(site.rglob("*.html")):
    for chunk in re.split(r'(?=<section class="decl" id=")', page.read_text(encoding="utf-8")):
        head = re.match(r'<section class="decl" id="([^"]+)"', chunk)
        if head is None:
            continue
        blocks[html.unescape(head.group(1))] = PILL.findall(chunk)

if not blocks:
    problems.append("no declaration block on any page — the site half checked nothing")
pilled = sorted(name for name, pills in blocks.items() if pills)
if pilled != claimed:
    only_page = [name for name in pilled if name not in found or found[name] is None]
    only_ir = [name for name in claimed if name not in pilled]
    problems.append(
        f"{len(pilled)} block(s) carry an origin pill and {len(claimed)} declaration(s) "
        f"claim one in the IR; on the page only: {', '.join(only_page[:3])}; "
        f"in the IR only: {', '.join(only_ir[:3])}"
    )
on_page = 0
for name in claimed:
    pills = blocks.get(name, [])
    if len(pills) != 1:
        problems.append(f"{name}: {len(pills)} origin pill(s) in its block, expected 1")
        continue
    said = ORIGIN.search(pills[0])
    if said is None:
        problems.append(f"{name}: the pill does not name an attribute and an origin: {pills[0]}")
        continue
    on_page += 1
    # Unescaped after the match and not before it: a declaration name may contain
    # `<`, and unescaping first would put a tag boundary inside the name.
    say = [html.unescape(part) for part in said.groups()]
    if say != found[name]:
        problems.append(
            f"{name}: the page says {json.dumps(say)}, the IR says {json.dumps(found[name])}"
        )

if problems:
    for problem in problems:
        print(f"GATE 9 FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(f"generated    {checked} declarations compared, {len(claimed)} realized by @[ext] over "
      f"{len(found)} declarations, {on_page} of them again as a pill over {len(blocks)} "
      f"blocks on the site; {len(selection_eq)} have selectionRange == range and "
      f"{len(selection_eq) - len(claimed)} of those are not realized; "
      f"{len(before)} sort before their origin")
PY

say "11/17 GATE 10 — docstring math becomes MathML, and unreadable math does not"
# Five assertions over `Example/Math.html` plus one over the run's marker, and that
# last one is what the others cannot make: **a fallback leaves a valid page** — no
# byte count, no page count and no exit code moves when a formula fails — so
# without `work.mathFallbacks` a run that converted nothing would look exactly
# like a run that converted everything.
#
# The `<math>` counts are exact and not lower bounds, because a renderer emitting
# one per character would pass a floor. `$\colim_k F(k)$` has to be on the page
# with its dollars, which is what doc-gen4 emits for every span. Nothing inside a
# `<math>` element may be half-escaped — no `<` that opens no tag, no `&` that
# opens no entity: this is the defect that decided the crate, `pulldown-latex`
# writing `<mo><</mo>` for `$a < b$` (61 of Mathlib's 2,123 spans) where
# `math-core` does not. And `$a &lt; b$` must **not** be on the page, because
# finding the fallback's escape spelling would mean conversion silently stopped
# while `mathFallbacks` stayed at 1.
python3 - "$OUT/first/site/Example/Math.html" "$OUT/first-build.json" <<'MATHPY'
import json
import re
import sys

page_path, marker_path = sys.argv[1:3]
page = open(page_path, encoding="utf-8").read()
with open(marker_path) as handle:
    work = json.load(handle)["work"]
problems = []


def want(label, got, expected):
    if got != expected:
        problems.append(f"{label}: {got}, expected {expected}")


# A missing key exits here rather than defaulting to a number that would pass: a
# gate looking for a key that is not there checks nothing at all, and one in this
# repository did (measured 2026-08-18).
if "mathFallbacks" not in work:
    sys.exit("GATE 10 FAIL  the marker has no work.mathFallbacks")
want("work.mathFallbacks", work["mathFallbacks"], 1)

want("inline <math>", len(re.findall(r"<math>", page)), 3)
want('<math display="block">', len(re.findall(r'<math display="block">', page)), 1)
want("merror elements", page.count("<merror"), 0)

if "$\\colim_k F(k)$" not in page:
    problems.append("the unconvertible span is not on the page as its own source")
if "$a &lt; b$" in page:
    problems.append("`$a < b$` was written back as LaTeX — it is supposed to convert")

strays = []
for formula in re.findall(r"<math[^>]*>.*?</math>", page, re.S):
    for hit in re.finditer(r"<(?![/a-zA-Z])", formula):
        strays.append(("<", formula[max(0, hit.start() - 20):hit.start() + 20]))
    for hit in re.finditer(r"&(?![a-zA-Z]+;|#[0-9]+;|#x[0-9a-fA-F]+;)", formula):
        strays.append(("&", formula[max(0, hit.start() - 20):hit.start() + 20]))
if strays:
    problems.append(
        f"{len(strays)} character(s) of markup are unescaped inside <math>: "
        + "; ".join(f"{c} near {ctx!r}" for c, ctx in strays[:3])
    )

if problems:
    for problem in problems:
        print(f"GATE 10 FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(f"math         {len(re.findall(r'<math', page))} formula(s) rendered, "
      f"{work['mathFallbacks']} kept as LaTeX, {len(strays)} unescaped character(s)")
MATHPY

say "12/17 GATE 14 — the front page describes each module by the heading its docstring opens with"
# The front page is the only place a reader meets every module at once, and the
# description in each row is the module docstring's opening `# ` heading, taken
# verbatim. Three things have to hold at once and none of them implies the
# others: the rows and the marker have to agree on **how many** there are (a
# renderer that dropped rows and a count derived from anything but the rows both
# show up here); the one module whose docstring opens with prose has to draw **no
# element at all**, because an empty one is a placeholder no reader can tell from
# a module that described itself with a blank line; and a heading's Markdown has
# to have been rendered, which is what `Example.Shapes` — headed with a code span —
# is here to say.
#
# `moduleSummariesEchoingTheName` is 0 and asserted as 0: a heading that only
# repeats the module's own last component renders as `Example.Math — Math`, which
# is a row that costs a line and says nothing. litedoc4 does not suppress it, so
# the sample is where the rule is kept.
python3 - "$OUT/first/site/index.html" "$OUT/first-build.json" <<'INDEXPY'
import json
import re
import sys

page_path, marker_path = sys.argv[1:3]
page = open(page_path, encoding="utf-8").read()
with open(marker_path) as handle:
    marker = json.load(handle)
work = marker["work"]
problems = []

# A missing key exits rather than defaulting to a number that would pass — the
# same failure GATE 10 records, which this repository has actually shipped.
for key in ("moduleSummaries", "moduleSummariesEchoingTheName"):
    if key not in work:
        sys.exit(f"GATE 14 FAIL  the marker has no work.{key}")

listing = re.search(r'<ul class="modlist([^"]*)">(.*?)</ul>', page, re.S)
if not listing:
    sys.exit("GATE 14 FAIL  index.html has no module list")
classes, body = listing.group(1), listing.group(2)
if "modlist-described" not in classes:
    problems.append(
        "the list is not marked modlist-described, so the stylesheet keeps the "
        "columns it uses for bare names and the descriptions land in them"
    )

rows = re.findall(r"<li>(.*?)</li>", body, re.S)
described = {}
listed = []
for row in rows:
    href = re.search(r'<a href="\./([^"]+)"', row)
    if not href:
        problems.append(f"a row with no link: {row[:80]!r}")
        continue
    listed.append(href.group(1))
    # Sliced at the anchor rather than searched for `<a` anywhere, because the
    # description is allowed one of its own — as a *sibling*. Inside the row's
    # link it would be an anchor in an anchor, which no parser reads back.
    anchor = row[row.index("<a ") : row.index("</a>")]
    if "<a " in anchor[3:]:
        problems.append(f"{href.group(1)}: an anchor inside the row's link")
    summary = re.search(r'<span class="modsummary">(.*?)</span>', row, re.S)
    if summary:
        described[href.group(1)] = summary.group(1)

if len(rows) != marker["modules"]:
    problems.append(
        f"{len(rows)} row(s) for {marker['modules']} module(s) — the front page "
        "is not the whole list"
    )

# The reconciliation: the page and the record, over the same run.
if len(described) != work["moduleSummaries"]:
    problems.append(
        f"{len(described)} row(s) carry a description, work.moduleSummaries says "
        f"{work['moduleSummaries']}"
    )
if work["moduleSummaries"] != marker["modules"] - 1:
    problems.append(
        f"work.moduleSummaries is {work['moduleSummaries']} of {marker['modules']} "
        "module(s) — exactly one module of this sample opens its docstring with "
        "prose, and every other one opens with a heading"
    )
if work["moduleSummariesEchoingTheName"] != 0:
    problems.append(
        f"work.moduleSummariesEchoingTheName is "
        f"{work['moduleSummariesEchoingTheName']}, not 0 — a module of the sample "
        "heads its docstring with its own name, which describes nothing"
    )

if "Example/Untitled.html" in described:
    problems.append(
        "Example.Untitled has a description: its docstring opens with prose, and a "
        "module that said nothing about itself must draw no element at all"
    )
shapes = described.get("Example/Shapes.html", "")
if "<code>Example.Basic</code>" not in shapes:
    problems.append(
        f"Example.Shapes' description is {shapes!r} — the heading's code span did "
        "not survive as markup, so the description is not being rendered as "
        "Markdown"
    )

if problems:
    for problem in problems:
        print(f"GATE 14 FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(f"front page   {len(described)} of {len(rows)} module(s) described, "
      f"{work['moduleSummariesEchoingTheName']} repeating their own name")
INDEXPY

say "13/17 GATE 11 — every reverse reference agrees with the IR, both ways"
# See doc-gen4 #77. Its own file because it is worth running against the
# measurement target too, where the numbers are 849 targets over 10,163 edges
# (measured 2026-08-22) rather than the sample's handful.
"$HERE/usedby-gate.sh" --ir "$OUT/first/ir" --site "$OUT/first/site"

say "14/17 GATE 12 — litedoc4.toml reaches every command that writes HTML"
# The sample carries a `litedoc4.toml` on purpose: with no file the four commands
# agree trivially, and a gate that can only pass is not a gate.
"$HERE/config-gate.sh" --root "$SAMPLE" --ir "$OUT/first/ir" --built "$OUT/first/site" \
  --link-index "$OUT/first/link-index.lidx" --out "$OUT/config"

say "15/17 GATE 6 — one edited module does not re-render the package"
# GATE 2 asks what an *unchanged* world costs; this asks what a one-declaration
# edit costs, which is the shape a user actually produces.
#
# Three assertions, and the first is the sharp one. **The map does not move**:
# `link-index.lidx` is byte-identical across the edit, and it is the *cause* —
# its SHA-256 is a `renderKey` input (`Litedoc4.Ledger`) and a moved render key
# overrides --mode to `all` (`Litedoc4.Incr.Impact`), so this
# fails on any extractor that writes the package's own declarations into the map.
# **Fewer pages than modules** is the *effect*, an inequality rather than a
# number, because the sample's import graph is allowed to grow. **The tree is a
# whole render** is the *oracle*: under-rendering is silent, so a page count is
# not evidence — what the incremental run left on disk has to be what a whole
# render of its own IR writes.
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
  --extractor-bin "$EXTRACTOR" | tee "$OUT/edited.log"

restore_probe
(cd "$SAMPLE" && "$LAKE" build)

if ! cmp -s "$OUT/lidx-before" "$OUT/first/link-index.lidx"; then
  echo "GATE 6: link-index.lidx moved for a one-declaration edit" >&2
  /usr/bin/diff "$OUT/lidx-before" "$OUT/first/link-index.lidx" | head -6 >&2
  exit 1
fi

# `site` writes the pages and the global artefacts; the static assets `build`
# copies are not its business, so a name present on one side only is not a
# difference here — a *shared* name whose bytes differ is.
EDITED_URL="$(python3 - "$OUT/edited.log" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
found = re.search(r"^source  (\S+://\S+)$", text, re.M)
print(found.group(1) if found else "")
PY
)"
[ -n "$EDITED_URL" ] || { echo "GATE 6: no source URL in the edited run's log" >&2; exit 1; }
rm -rf "$OUT/gate6-oracle" "$OUT/gate6-state"
"$LITEDOC4" site --ir "$OUT/first/ir" --out "$OUT/gate6-oracle" \
  --source-url "$EDITED_URL" --link-index "$OUT/first/link-index.lidx" \
  --state "$OUT/gate6-state" --root "$SAMPLE" >"$OUT/gate6-oracle.log"
gate6_diff="$(/usr/bin/diff -r -q "$OUT/gate6-oracle" "$OUT/first/site" | grep -v '^Only in' || true)"
if [ -n "$gate6_diff" ]; then
  echo "GATE 6: the incremental tree is not what a whole render of its IR writes" >&2
  printf '%s\n' "$gate6_diff" | head -10 >&2
  exit 1
fi

# The same script runs on the Linux runner against the generated package
# (`ci-template.yml`), so what "a one-module edit is allowed to cost" is written
# down once and both callers get the same answer.
"$HERE/onemod-gate.sh" "$OUT/first/litedoc4-build.json" "$OUT/first/work/serve.out"

say "16/17 GATE 13 — every source link names a file that is really in this checkout"
# The sample is a package **inside** a repository, which the measurement target
# is not: the target *is* its repository, so the derived source URL needed no path
# to the package and every number in benchmarks/ was taken with an empty one. The
# published sample site is what showed the gap — `blob/<rev>/Example/Basic.lean`
# where the file is at `e2e/micro/Example/Basic.lean` (measured 2026-08-29: 404 and
# 200 respectively). Anyone using the action's `root` input had the same site.
#
# Resolved against this checkout rather than fetched: the answer must not depend
# on the network, on a rate limit, or on the commit having been pushed. Links into
# *other* repositories are skipped by owner/repo, since their paths are not here.
python3 - "$OUT/first/site" "$ROOT" <<'LINKS'
import pathlib
import re
import subprocess
import sys

site, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
remote = subprocess.run(
    ["git", "-C", str(repo), "config", "--get", "remote.origin.url"],
    capture_output=True, text=True,
).stdout.strip()
slug = re.sub(r"^.*github\.com[:/]", "", remote).removesuffix(".git").strip("/")
if not slug:
    sys.exit("GATE 13: no github remote to attribute source links to")

own = re.compile("https://github\\.com/" + re.escape(slug) + "/blob/[0-9a-f]+/([^\"#]+)")
seen, missing = set(), set()
for page in sorted(site.rglob("*.html")):
    for path in own.findall(page.read_text(encoding="utf-8")):
        seen.add(path)
        if not (repo / path).exists():
            missing.add(path)

if not seen:
    sys.exit("GATE 13: no source link into " + slug + " on any page — nothing was checked")
for path in sorted(missing):
    print("GATE 13 FAIL  the site links to " + path + ", which is not in this checkout", file=sys.stderr)
if missing:
    sys.exit(1)
print("source links " + str(len(seen)) + " distinct path(s) into " + slug + ", all present in the checkout")
LINKS

say "17/17 summary"
printf 'site files : %s\n' "$(find "$OUT/first/site" -type f | wc -l | tr -d ' ')"
printf 'ir files   : %s\n' "$(find "$OUT/first/ir" -type f | wc -l | tr -d ' ')"
printf 'out        : %s\n' "$OUT"

if [ "$TEMPORARY" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
  rm -rf "$OUT"
fi
echo
echo "E2E MICRO: ok"
