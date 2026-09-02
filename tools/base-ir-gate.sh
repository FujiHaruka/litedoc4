#!/usr/bin/env bash
# Does the target's IR agree with itself, and does the Lean reader agree with it?
#
# The measurement target's IR used to be read by two `#[ignore]`d Rust tests,
# `base_ir::reads_every_module_of_the_target_package` and
# `base_ir::astral_binders_slice_correctly`. They leave with `crates/`, and of the
# 21 corpus tests they were two of the 7 that nothing surviving asks (measured
# 2026-09-02 — see `docs/verification-log.md`, "M10 step E", which also names the
# five that are still unasked). So this is where these two live now. They are not
# tests: they read a tree that is not in the repository, which is the line
# CLAUDE.md draws between a test and a gate.
#
# WHERE THE EXPECTED VALUES COME FROM, WHICH IS THE WHOLE POINT
#   `git show rust-frozen:crates/litedoc4-ir/tests/base_ir.rs` (in that tag, not in
#   HEAD) recorded it in its header: every count it asserted was taken from
#   the fixture by enumerating the JSON, never from a previous run of the reader,
#   because the claim is that **the reader agrees with the writer**. A gate that
#   re-derived its expectations from the Lean reader would assert nothing at all.
#   So neither arm below has a frozen number in it:
#
#     WRITER  the extractor's index against the extractor's own module files.
#             `index.json` says how many modules, how many declarations each has,
#             how many bytes each file is and what its content hash looks like;
#             the files say what they actually hold. Python enumerates the files
#             and the two are compared. Both sides are the writer's, and the
#             enumeration is a third implementation that shares code with neither.
#     READER  `litedoc4 global --ir` reads every module of the same tree and
#             prints what it found. Its numbers are compared against the
#             enumeration, so the reader is graded by the writer.
#
#   The Rust test additionally pinned exact counts (432 modules, 4,750
#   declarations) behind a guard that only fired for one generation of the tree.
#   **That guard has not fired since the target moved to 422 modules**, so those
#   assertions were already dead when they were carried across (measured
#   2026-09-02) — there is nothing here to restore and nothing here to freeze.
#   What is asserted instead is that the corpus still *exercises* the two
#   properties the counts were standing in for: some span's UTF-16 offset differs
#   from its byte offset, and some span inside an astral fragment slices
#   differently under the two. Both are reported as numbers.
#
# WHY THESE INVARIANTS HAVE NO OTHER HOME
#   `tools/purelean-render-gate.sh` item 3 re-homed one half of the first test —
#   one page per module in `index.json` and no other file — and the rest of that
#   gate compares rendered bytes against a frozen answer. Both are a different
#   question from this one: they say the pages have not changed, not that the
#   index agrees with the files it summarises. **Nothing a renderer does consults
#   `index.bytes`, a `contentHash`, a dependency slice's entry count or the
#   parallel-array widths**, so a defect in any of them is invisible to every byte
#   comparison in the tree — a page renders identically whether or not the index
#   agrees about how long its module file is.
#
#   Runs on any IR tree, so `--ir` can point it at a small one. It is `manual`
#   rather than `ci` because the corpus is the point: the astral and shifted-offset
#   checks below assert that the tree *exercises* UTF-16 translation at all, and
#   `e2e/micro` is eleven modules chosen for other shapes.
#
# usage: base-ir-gate.sh [--ir DIR] [--lean PATH]
#   --ir    the IR tree (default: $PURELEAN_WORK/ir, the tree
#           tools/purelean-render-gate.sh reads, so one extraction serves both)
#   --lean  the Lean litedoc4 (default: .lake/build/bin/litedoc4, built with
#           tools/build-lean-exe.sh if it is not there)
#
#   PURELEAN_WORK  where the target's IR is (default
#                  /private/tmp/lean-doc-relay/purelean). **Nothing here writes
#                  into it.** To produce one, see the header of
#                  tools/purelean-render-gate.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1

WORK="${PURELEAN_WORK:-/private/tmp/lean-doc-relay/purelean}"
IR=""
LEAN="${LEAN_LITEDOC4:-}"
PYTHON="${PYTHON:-python3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ir) IR="$2"; shift 2 ;;
    --lean) LEAN="$2"; shift 2 ;;
    -h|--help) sed -n '/^# usage:/,/^set -/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

[ -n "$IR" ] || IR="$WORK/ir"
if [ ! -f "$IR/index.json" ]; then
  echo "base-ir-gate: no IR tree at $IR — set PURELEAN_WORK or pass --ir; the header of tools/purelean-render-gate.sh has the three commands that produce one" >&2
  exit 2
fi

if [ -z "$LEAN" ]; then
  LEAN="$ROOT/.lake/build/bin/litedoc4"
  # Built rather than demanded: tools/build-lean-exe.sh is the one place that
  # knows how to build beside a lakefile with no lean-toolchain of its own.
  if [ ! -x "$LEAN" ]; then
    "$HERE/build-lean-exe.sh" --toolchain-from "$ROOT/e2e/micro" >/dev/null \
      || { echo "base-ir-gate: no Lean litedoc4 and tools/build-lean-exe.sh failed — pass --lean <path>" >&2; exit 2; }
  fi
fi
[ -x "$LEAN" ] || { echo "base-ir-gate: no Lean litedoc4 at $LEAN" >&2; exit 2; }

OUT="$(mktemp -d)"
on_exit 'rm -rf "$OUT"'

# The reader arm, run before the enumeration so that a reader that cannot open
# the tree at all is reported as that rather than as a disagreement about counts.
set +e
"$LEAN" global --ir "$IR" --out "$OUT/global" >"$OUT/global.txt" 2>&1
GLOBAL_RC=$?
set -e
if [ "$GLOBAL_RC" -ne 0 ]; then
  echo "BASE IR GATE FAIL  the Lean reader exited $GLOBAL_RC over $IR, so it read nothing to agree about:" >&2
  sed 's/^/  /' "$OUT/global.txt" >&2
  exit 1
fi

"$PYTHON" - "$IR" "$OUT/global.txt" <<'PY'
import json
import pathlib
import re
import sys

ir = pathlib.Path(sys.argv[1])
reader_said = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")

# Unicode White_Space, written out rather than taken from `str.isspace()`: Python
# and Rust disagree about U+001C-U+001F, and the claim being checked is the one
# the extractor makes, not the one this script's standard library happens to hold.
WHITE_SPACE = {0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680,
               0x2028, 0x2029, 0x202F, 0x205F, 0x3000} | set(range(0x2000, 0x200B))
HEX = re.compile(r"\A[0-9a-fA-F]{16}\Z")
LABELS = {"field", "ctor", "parent"}
FIELD_ONLY = ("binders", "implicits", "binderCode", "doc", "isDirect")

problems = []
checks = 0


def check(ok, said):
    global checks
    checks += 1
    if not ok:
        problems.append(said)


def offsets(text):
    """UTF-16 offset -> (UTF-8 byte offset, code point index), for the offsets that
    are scalar boundaries. An offset that is not a key is one inside a surrogate
    pair, which is exactly the state a span must never name."""
    table = {}
    unit = byte = 0
    for cp, ch in enumerate(text):
        table[unit] = (byte, cp)
        unit += 2 if ord(ch) > 0xFFFF else 1
        byte += len(ch.encode("utf-8"))
    table[unit] = (byte, len(text))
    return table, unit


def tagged(decl):
    out = []
    binder_code = decl.get("binderCode") or []
    for i, text in enumerate(decl.get("binders") or []):
        out.append((text, binder_code[i] if i < len(binder_code) else []))
    out.append((decl.get("type") or "", decl.get("typeCode") or []))
    equation_code = decl.get("equationCode") or []
    for i, text in enumerate(decl.get("equations") or []):
        out.append((text, equation_code[i] if i < len(equation_code) else []))
    for member in decl.get("members") or []:
        out.append((member.get("text") or "", member.get("code") or []))
        member_binder_code = member.get("binderCode") or []
        for i, text in enumerate(member.get("binders") or []):
            out.append((text, member_binder_code[i] if i < len(member_binder_code) else []))
    return out


index = json.loads((ir / "index.json").read_text(encoding="utf-8"))

check(index.get("schemaVersion", 0) >= 5,
      f"index.json is schema {index.get('schemaVersion', 0)}, below the 5 the reader needs")
check(not index.get("ablations"),
      "index.json carries ablations, so this tree is a deliberately damaged one and every "
      "count below would be measuring the damage")
entries = index["modules"]
check(len(entries) == index["moduleCount"],
      f"index.json lists {len(entries)} module(s) and says moduleCount is {index['moduleCount']}")

modules = declarations = module_docs = tactics = 0
members = fields = fields_is_direct = fields_inherited = ctors = parents = 0
with_attrs = with_inst_class = refs = 0
fragments = fragments_non_ascii = fragments_astral = 0
spans_offset_shifted = astral_spans_that_differ = 0
spans_by_kind = [0, 0, 0]
spans_by_arity = [0, 0, 0]

for entry in entries:
    path = ir / entry["file"]
    check(path.is_file(), f"index.json names {entry['file']}, which is not a file")
    if not path.is_file():
        continue
    raw = path.read_bytes()
    check(len(raw) == entry["bytes"],
          f"{entry['module']}: index.json says {entry['bytes']} B and the file is {len(raw)} B")
    check(bool(HEX.match(entry["contentHash"])),
          f"{entry['module']}: contentHash {entry['contentHash']!r} is not 16 hex digits")
    module = json.loads(raw.decode("utf-8"))
    check(module["module"] == entry["module"],
          f"{entry['file']} holds module {module['module']!r} and index.json calls it "
          f"{entry['module']!r}")
    decls = module.get("declarations") or []
    check(len(decls) == entry["declarations"],
          f"{entry['module']}: index.json says {entry['declarations']} declaration(s) and the "
          f"file holds {len(decls)}")

    modules += 1
    module_docs += len(module.get("moduleDocs") or [])
    tactics += len(module.get("tactics") or [])
    for decl in decls:
        declarations += 1
        refs += len(decl.get("refs") or [])
        if decl.get("attrs"):
            with_attrs += 1
        if decl.get("instClass") is not None:
            with_inst_class += 1
        binders = decl.get("binders") or []
        check(len(binders) == len(decl.get("implicits") or [])
              and len(binders) == len(decl.get("binderCode") or [])
              and len(decl.get("equations") or []) == len(decl.get("equationCode") or []),
              f"{entry['module']}::{decl['name']}: the parallel arrays are ragged "
              "(binders/implicits/binderCode, equations/equationCode)")
        for member in decl.get("members") or []:
            members += 1
            label = member.get("label")
            check(label in LABELS,
                  f"{entry['module']}::{decl['name']}: member {member.get('name')!r} has label "
                  f"{label!r}, which is not one of {sorted(LABELS)}")
            if label == "field":
                fields += 1
                if member.get("isDirect") is not None:
                    fields_is_direct += 1
                if member.get("isDirect") is False:
                    fields_inherited += 1
            elif label == "ctor":
                ctors += 1
            elif label == "parent":
                parents += 1
            if label != "field":
                extra = [k for k in FIELD_ONLY if member.get(k)]
                check(not extra,
                      f"{entry['module']}::{decl['name']}: member {member.get('name')!r} is a "
                      f"{label!r} and carries the field-only key(s) {extra}")
            mb = member.get("binders") or []
            check(len(mb) == len(member.get("implicits") or [])
                  and len(mb) == len(member.get("binderCode") or []),
                  f"{entry['module']}::{decl['name']}: member {member.get('name')!r} has ragged "
                  "parallel arrays")

        for text, spans in tagged(decl):
            fragments += 1
            if not text.isascii():
                fragments_non_ascii += 1
            astral = any(ord(c) > 0xFFFF for c in text)
            if astral:
                fragments_astral += 1
            if not spans:
                continue
            table, total_units = offsets(text)
            raw8 = text.encode("utf-8")
            where = f"{entry['module']}::{decl['name']} fragment {text!r}"
            for span in spans:
                start, stop, kind = span[0], span[1], span[2]
                name = span[3] if len(span) > 3 else ""
                front = span[4] if len(span) > 4 else 0
                back = span[5] if len(span) > 5 else 0
                check(kind in (0, 1, 2), f"span kind {kind} in {where}")
                if kind in (0, 1, 2):
                    spans_by_kind[kind] += 1
                check(bool(name) == (kind == 1),
                      f"a name and kind 1 must imply each other, in {where}")
                spans_by_arity[0 if not name else (1 if front == 0 and back == 0 else 2)] += 1
                check(stop <= total_units,
                      f"span {start}..{stop} past the {total_units} unit(s) of {where}")
                boundary = start in table and stop in table
                check(boundary, f"span {start}..{stop} is not a slice boundary of {where}")
                widths = []
                if front:
                    widths.append((start - front, start))
                if back:
                    widths.append((stop, stop + back))
                for lo, hi in widths:
                    check(hi <= total_units,
                          f"whitespace width {lo}..{hi} past the end of {where}")
                    if hi > total_units:
                        continue
                    for at in range(max(lo, 0), hi):
                        if at not in table:
                            continue
                        unit = ord(text[table[at][1]])
                        check(unit in WHITE_SPACE,
                              f"whitespace width covers U+{unit:04X} in {where}")
                if not boundary:
                    continue
                # A UTF-16 offset that is not the byte offset of the same place is
                # what this schema exists to get right. Counted, never frozen: how
                # many there are belongs to the corpus, not to the reader.
                if table[start][0] != start:
                    spans_offset_shifted += 1
                if astral:
                    proper = text[table[start][1]:table[stop][1]]
                    try:
                        naive = raw8[start:stop].decode("utf-8")
                    except UnicodeDecodeError:
                        naive = None
                    if naive != proper:
                        astral_spans_that_differ += 1

check(declarations == index["declarationCount"],
      f"the module files hold {declarations} declaration(s) and index.json says "
      f"{index['declarationCount']}")

dep_entries = index.get("dependencyMaps") or []
dep_declarations = 0
for entry in dep_entries:
    path = ir / entry["file"]
    check(path.is_file(), f"index.json names dependency map {entry['file']}, which is not a file")
    if not path.is_file():
        continue
    dep = json.loads(path.read_text(encoding="utf-8"))
    check(dep.get("package") == entry["package"],
          f"{entry['file']} is package {dep.get('package')!r} and index.json calls it "
          f"{entry['package']!r}")
    held = len(dep.get("declarations") or {})
    check(held == entry["entries"],
          f"{entry['package']}: index.json says {entry['entries']} entry(ies) and the file holds "
          f"{held}")
    check(dep.get("schemaVersion") == index["schemaVersion"],
          f"{entry['package']}: the slice is schema {dep.get('schemaVersion')} and the index is "
          f"schema {index['schemaVersion']}")
    dep_declarations += held

check(spans_offset_shifted > 0,
      "no span in this corpus has a UTF-16 offset different from its byte offset, so the "
      "translation the schema exists for is not exercised by this tree at all")
check(fragments_astral > 0,
      "this corpus holds no fragment with a scalar above U+FFFF, so a slice landing inside a "
      "surrogate pair could not be detected here")
check(astral_spans_that_differ > 0,
      f"{fragments_astral} astral fragment(s) and not one span in them slices differently under "
      "UTF-16 than under byte offsets — a byte-indexed reader would pass this tree")

said = {}
matched = re.search(
    r"modules (\d+)\s+declarations (\d+) \+ (\d+) dependency names.*?tactic docs (\d+)",
    reader_said, re.S)
check(matched is not None,
      "the Lean reader did not print the line this gate reads its counts from; its output was "
      + repr(reader_said[:200]))
if matched:
    keys = ("modules", "declarations", "deps", "tactics")
    said = dict(zip(keys, (int(g) for g in matched.groups())))
    check(said["modules"] == modules,
          f"the Lean reader read {said['modules']} module(s) and the tree holds {modules}")
    check(said["declarations"] == declarations,
          f"the Lean reader read {said['declarations']} declaration(s) and the tree holds "
          f"{declarations}")
    check(said["deps"] == dep_declarations,
          f"the Lean reader read {said['deps']} dependency name(s) and the slices hold "
          f"{dep_declarations}")
    check(said["tactics"] == tactics,
          f"the Lean reader read {said['tactics']} tactic doc(s) and the tree holds {tactics}")

for problem in problems[:8]:
    print(f"BASE IR GATE FAIL  {problem}", file=sys.stderr)
if len(problems) > 8:
    print(f"BASE IR GATE FAIL  and {len(problems) - 8} more", file=sys.stderr)

print(f"  tree      {modules} modules, {declarations} declarations, {module_docs} module docs, "
      f"{tactics} tactic docs, {len(dep_entries)} dependency slice(s) holding {dep_declarations}")
print(f"  members   {members} ({fields} field, {ctors} ctor, {parents} parent); "
      f"{fields_is_direct} field(s) carry isDirect, {fields_inherited} inherited")
print(f"  decls     {with_attrs} with attributes, {with_inst_class} with an instance class, "
      f"{refs} refs")
print(f"  fragments {fragments} ({fragments_non_ascii} non-ASCII, {fragments_astral} astral)")
print(f"  spans     by kind {spans_by_kind}, by arity {spans_by_arity}; {spans_offset_shifted} "
      f"at a shifted offset, {astral_spans_that_differ} astral span(s) that a byte-indexed "
      "reader would get wrong")
if said:
    print(f"  reader    litedoc4 global read {said['modules']} modules, {said['declarations']} "
          f"declarations, {said['deps']} dependency names, {said['tactics']} tactic docs")

if problems:
    print(f"BASE IR GATE: {len(problems)} of {checks} check(s) failed", file=sys.stderr)
    sys.exit(1)
print(f"BASE IR GATE: ok ({checks} checks)")
PY
