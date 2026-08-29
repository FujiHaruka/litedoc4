#!/usr/bin/env bash
# Do the Lean toolchains this repository claims produce the same IR?
#
# One IR tree per toolchain comes in; the answer is a diff over all of them at
# once. The list of toolchains, and the one thing that legitimately moves between
# them, are both in tools/lean-toolchains.txt.
#
# WHY NOT A PLAIN `diff -r`
#   Lean renamed the reducibility status of a reducible instance, so a raw diff
#   is red on every version boundary and stops being read. Normalising exactly the
#   rename the inventory records — and nothing else — keeps the second divergence
#   visible, which an ignore-list would swallow.
#
# WHY `contentHash` IS NOT SIMPLY SKIPPED
#   It is computed by the extractor over the bytes *before* normalisation, so it
#   differs wherever the rename applied. Skipping it would also hide a hash that
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
for line in inventory_path.read_text(encoding="utf-8").splitlines():
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    toolchain, attr = line.split()
    spelling[toolchain] = attr

# The name every leg is normalised *to*. Not "the first argument's": a run whose
# arguments happen to start at v4.33.0 would then normalise the other way and the
# comparison would still be the same one, but the failure text would name a
# spelling that is not in the file.
CANONICAL = "implicit_reducible"

legs = []
for spec in sys.argv[2:]:
    toolchain, _, directory = spec.partition("=")
    if not directory:
        sys.exit(f"lean-versions: `{spec}` is not <toolchain>=<ir-dir>")
    if toolchain not in spelling:
        sys.exit(f"lean-versions: {toolchain} has no row in {inventory_path}")
    if spelling[toolchain] == "UNMEASURED":
        sys.exit(
            f"lean-versions: {inventory_path} says {toolchain} is UNMEASURED — "
            "record the attribute Lean actually spelled before comparing against it"
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


def normalised(path, toolchain):
    raw = path.read_bytes()
    return raw.replace(spelling[toolchain].encode(), CANONICAL.encode())


base_toolchain, base_root = legs[0]
base_files = module_files(base_root)

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
                f"{toolchain} and {base_toolchain} disagree on {name} at byte {at}: "
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

print(
    "LEAN VERSIONS: "
    + ", ".join(t for t, _ in legs)
    + f" agree over {len(base_files)} IR files "
    f"(the recorded rename to `{CANONICAL}` applied, nothing else)"
)
PY
