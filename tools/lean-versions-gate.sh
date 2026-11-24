#!/usr/bin/env bash
# Do the Lean toolchains this repository claims produce the same IR?
#
# One IR tree per toolchain comes in; the answer is a diff over all of them at
# once. The list of toolchains, and the two things that legitimately move between
# them, are all in tools/lean-toolchains.txt.
#
# WHY NOT A PLAIN `diff -r`
#   Lean renamed the reducibility status of a reducible instance, and stopped
#   keeping the whitespace before a doc comment's `-/`, so a raw diff is red on
#   every version boundary and stops being read. Normalising exactly what the
#   inventory records — and nothing else — keeps the next divergence visible,
#   which an ignore-list would swallow.
#
# WHY `contentHash` IS NOT SIMPLY SKIPPED
#   It is computed by the extractor over the bytes *before* normalisation, so it
#   differs wherever a normalisation applied. Skipping it would also hide a hash that
#   moved with no byte behind it, so instead it is asserted the other way round:
#   the hash differs exactly when the raw module bytes differ.
#
# usage: lean-versions-gate.sh <toolchain>=<ir-dir> <toolchain>=<ir-dir> [...]
#   e.g. lean-versions-gate.sh leanprover/lean4:v4.31.0=/tmp/a leanprover/lean4:v4.33.0=/tmp/b
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ $# -ge 2 ] || { sed -n '1,/^set -/p' "$0" | sed '$d'; exit 2; }

python3 - "$HERE/lean-toolchains.txt" "$@" <<'PY'
import json
import pathlib
import sys

inventory_path = pathlib.Path(sys.argv[1])
spelling = {}
trailing = {}
for line in inventory_path.read_text(encoding="utf-8").splitlines():
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    columns = line.split()
    if len(columns) != 3:
        sys.exit(f"lean-versions: {inventory_path} row `{line}` has {len(columns)} column(s), not 3")
    toolchain, spelling[toolchain], trailing[toolchain] = columns

# The name every leg is normalised *to*. Not "the first argument's": a run whose
# arguments happen to start at v4.33.0 would then normalise the other way and the
# comparison would still be the same one, but the failure text would name a
# spelling that is not in the file.
CANONICAL = "implicit_reducible"
# Only this direction exists: whitespace Lean dropped cannot be put back.
TRAILING_CANONICAL = "dropped"
TRAILING_VALUES = ("kept", "dropped")

legs = []
for spec in sys.argv[2:]:
    toolchain, _, directory = spec.partition("=")
    if not directory:
        sys.exit(f"lean-versions: `{spec}` is not <toolchain>=<ir-dir>")
    if toolchain not in spelling:
        sys.exit(f"lean-versions: {toolchain} has no row in {inventory_path}")
    if "UNMEASURED" in (spelling[toolchain], trailing[toolchain]):
        sys.exit(
            f"lean-versions: {inventory_path} says {toolchain} is UNMEASURED — "
            "record what Lean actually did before comparing against it"
        )
    if trailing[toolchain] not in TRAILING_VALUES:
        sys.exit(
            f"lean-versions: {inventory_path} gives {toolchain} column 3 "
            f"`{trailing[toolchain]}`, which is none of {', '.join(TRAILING_VALUES)}"
        )
    root = pathlib.Path(directory)
    if not (root / "index.json").is_file():
        sys.exit(f"lean-versions: {root}/index.json is not there — this leg produced no IR")
    legs.append((toolchain, root))

problems = []


def module_files(root):
    return {
        p.relative_to(root).as_posix(): p
        for p in sorted(root.rglob("*.json"))
        if p.name != "index.json"
    }


# How many times each normalisation actually rewrote something, per toolchain.
# Printed at the end: a normalisation whose reach is unknown is an ignore-list
# wearing a different hat, and the number is the only way to see it grow.
rewrites: dict[str, int] = {}
stripped: dict[str, int] = {}
seen: dict[tuple, bytes] = {}


def docstring_owner(key, owner):
    return key in ("doc", "docString") or (key == "text" and owner == "moduleDocs")


def without_trailing(body):
    units = []
    i = 0
    while i < len(body):
        step = 6 if body[i:i + 2] == b"\\u" else 2 if body[i:i + 1] == b"\\" else 1
        units.append(body[i:i + step])
        i += step
    end = len(units)
    while end and units[end - 1] in (b" ", b"\\n"):
        end -= 1
    return b"".join(units[:end]), end != len(units)


def strip_docstrings(raw, toolchain):
    out = bytearray()
    stack = []
    key = None
    i = 0
    while i < len(raw):
        c = raw[i:i + 1]
        if c == b'"':
            j = i + 1
            while raw[j:j + 1] != b'"':
                j += 2 if raw[j:j + 1] == b"\\" else 1
            body = raw[i + 1:j]
            frame = stack[-1] if stack else None
            if frame and frame["kind"] == "object" and frame["wants_key"]:
                key = body.decode("utf-8")
                frame["wants_key"] = False
            elif frame and frame["kind"] == "object" and docstring_owner(key, frame["owner"]):
                body, changed = without_trailing(body)
                if changed:
                    stripped[toolchain] = stripped.get(toolchain, 0) + 1
            out += b'"' + body + b'"'
            i = j + 1
            continue
        if c in (b"{", b"["):
            frame = stack[-1] if stack else None
            if frame is None:
                owner = None
            elif frame["kind"] == "object":
                owner = key
            else:
                owner = frame["owner"]
            stack.append({"kind": "object" if c == b"{" else "array", "owner": owner, "wants_key": c == b"{"})
        elif c in (b"}", b"]"):
            stack.pop()
        elif c == b"," and stack and stack[-1]["kind"] == "object":
            stack[-1]["wants_key"] = True
        out += c
        i += 1
    return bytes(out)


def normalised(path, toolchain):
    if (toolchain, path) in seen:
        return seen[(toolchain, path)]
    raw = path.read_bytes()
    want = spelling[toolchain].encode()
    if want != CANONICAL.encode():
        rewrites[toolchain] = rewrites.get(toolchain, 0) + raw.count(want)
        raw = raw.replace(want, CANONICAL.encode())
    if trailing[toolchain] != TRAILING_CANONICAL:
        raw = strip_docstrings(raw, toolchain)
    seen[(toolchain, path)] = raw
    return raw


base_toolchain, base_root = legs[0]
base_files = module_files(base_root)

# Agreement over nothing is not agreement. The sample has eleven modules and two
# dependency slices; anything under that means the artifact did not arrive whole,
# and without this the gate prints "agree over 0 IR files" and exits 0 (measured
# 2026-08-29, on synthetic empty trees).
FLOOR = 11
if len(base_files) < FLOOR:
    sys.exit(
        f"lean-versions: {base_toolchain} has {len(base_files)} IR file(s), fewer than "
        f"the {FLOOR} this sample always writes — comparing these would prove nothing"
    )

for toolchain, root in legs[1:]:
    files = module_files(root)
    for name in sorted(set(base_files) | set(files)):
        if name not in files:
            problems.append(f"{toolchain} does not have {name}, {base_toolchain} does")
            continue
        if name not in base_files:
            problems.append(f"{toolchain} has {name}, {base_toolchain} does not")
            continue
        want = normalised(base_files[name], base_toolchain)
        got = normalised(files[name], toolchain)
        if want != got:
            at = next(
                (i for i, (u, v) in enumerate(zip(want, got)) if u != v), min(len(want), len(got))
            )
            problems.append(
                f"{base_toolchain} and {toolchain} disagree on {name} at byte {at}: "
                f"{want[at:at + 40]!r} vs {got[at:at + 40]!r}"
            )

# `leanVersion` is the one field that must differ, and it is the only evidence in
# the artifact that this leg ran the toolchain it is labelled with. Without it a
# matrix that installed one toolchain four times would compare four identical
# trees and report agreement.
for toolchain, root in legs:
    index = json.loads((root / "index.json").read_text(encoding="utf-8"))
    want = toolchain.rpartition(":v")[2]
    if index.get("leanVersion") != want:
        problems.append(
            f"{toolchain} produced an IR whose leanVersion is "
            f"{index.get('leanVersion')!r}, not {want!r} — this leg did not run the "
            "toolchain it names"
        )

base_index = json.loads((base_root / "index.json").read_text(encoding="utf-8"))
SHARED = ("schemaVersion", "generator", "hashAlgorithm", "moduleCount", "declarationCount")
for toolchain, root in legs[1:]:
    index = json.loads((root / "index.json").read_text(encoding="utf-8"))
    for key in SHARED:
        if index.get(key) != base_index.get(key):
            problems.append(
                f"{toolchain} index.json {key} is {index.get(key)!r}, "
                f"{base_toolchain}'s is {base_index.get(key)!r}"
            )
    base_by_name = {m["module"]: m for m in base_index.get("modules", [])}
    for entry in index.get("modules", []):
        other = base_by_name.get(entry["module"])
        if other is None:
            problems.append(f"{toolchain} index.json names {entry['module']}, {base_toolchain} does not")
            continue
        path = f"modules/{entry['module']}.json"
        raw_equal = (
            path in base_files
            and path in module_files(root)
            and base_files[path].read_bytes() == (root / path).read_bytes()
        )
        hash_equal = entry.get("contentHash") == other.get("contentHash")
        if raw_equal != hash_equal:
            problems.append(
                f"{toolchain} {entry['module']}: raw bytes {'match' if raw_equal else 'differ'} "
                f"but contentHash {'matches' if hash_equal else 'differs'}"
            )

if problems:
    for problem in problems:
        print(f"LEAN VERSIONS FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

reach = ", ".join(f"{t} {n}" for t, n in sorted(rewrites.items())) or "none"
docs_reach = ", ".join(f"{t} {n}" for t, n in sorted(stripped.items())) or "none"
print(
    "LEAN VERSIONS: "
    + ", ".join(t for t, _ in legs)
    + f" agree over {len(base_files)} IR files "
    f"(rename to `{CANONICAL}` applied {reach} time(s); trailing doc-comment whitespace "
    f"dropped from {docs_reach} docstring(s); nothing else normalised)"
)
PY
