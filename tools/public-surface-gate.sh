#!/usr/bin/env bash
# Is everything 1.x promised still there?
#
# The promise is tools/public-surface.txt. This reads the sources it is a promise
# about and says which name went missing — a consumer's workflow, `litedoc4.toml`
# or script names these, and a rename is a broken file in someone else's
# repository rather than a failure here.
#
# WHAT EACH CHECK CAN SEE
#   action.yml       the YAML itself, both directions. Data against data
#   build / watch    the synopsis in `USAGE`, one direction. `USAGE` is tied to
#                    the parsers by litedoc4's own `every_documented_flag_is_parsed`,
#                    so a flag named here and reachable in `USAGE` is a flag some
#                    parser accepts. What this cannot see is a flag that stopped
#                    doing anything while keeping its name
#   litedoc4.toml    the fields of `struct File` in litedoc4-render's config.rs,
#                    which serde reads with `deny_unknown_fields`, so those fields
#                    *are* the accepted keys
#
# Needs no binary, no toolchain and no target: every input is a file in the tree.
#
# usage: public-surface-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])

sections: dict[str, list[str]] = {}
current = None
for line in (root / "tools/public-surface.txt").read_text(encoding="utf-8").splitlines():
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    if line.startswith("[") and line.endswith("]"):
        current = line[1:-1]
        sections[current] = []
    elif current:
        sections[current].append(line)

missing_sections = [
    s for s in ("action-inputs", "action-outputs", "build", "watch", "litedoc4.toml")
    if not sections.get(s)
]
if missing_sections:
    sys.exit(f"public-surface: {missing_sections} are empty — this gate would check nothing")

problems = []

# --- action.yml, both directions -------------------------------------------
action = (root / "action.yml").read_text(encoding="utf-8").splitlines()
found = {"action-inputs": [], "action-outputs": []}
block = None
for line in action:
    if line.startswith("inputs:"):
        block = "action-inputs"
        continue
    if line.startswith("outputs:"):
        block = "action-outputs"
        continue
    if line and not line[0].isspace():
        block = None
        continue
    # Deliberately wider than the names in the file today: a key this pattern
    # cannot see is one the "declares something nobody promised" direction would
    # miss, which is the half that costs nothing and is therefore the half worth
    # keeping honest.
    if block and re.fullmatch(r"  ([A-Za-z0-9_-]+):", line.rstrip()):
        found[block].append(line.strip().rstrip(":"))

for key in ("action-inputs", "action-outputs"):
    promised, actual = set(sections[key]), set(found[key])
    for name in sorted(promised - actual):
        problems.append(f"action.yml has no {key[7:-1]} `{name}`, and 1.x promised it")
    for name in sorted(actual - promised):
        problems.append(
            f"action.yml declares {key[7:-1]} `{name}`, which is in no promise — "
            "add it to tools/public-surface.txt or take it out of action.yml"
        )

# --- build / watch, against USAGE's synopsis --------------------------------
lib = (root / "crates/litedoc4/src/lib.rs").read_text(encoding="utf-8")
MARKER = 'pub const USAGE: &str = "\\\n'
if MARKER not in lib:
    sys.exit(
        "public-surface: `pub const USAGE` is not where this gate looks for it in "
        "crates/litedoc4/src/lib.rs — the flag checks below would read an empty string"
    )
usage = lib.split(MARKER, 1)[1].split('\n";', 1)[0]

synopsis: dict[str, list[str]] = {}
command = None
for line in usage.splitlines():
    started = re.match(r"(?:usage:)?\s*litedoc4 (\w+)", line)
    if started:
        command = started.group(1)
        synopsis.setdefault(command, [])
    elif not line.startswith(" " * 20):
        command = None
    if command:
        synopsis[command].append(line)

for name in ("build", "watch"):
    text = "\n".join(synopsis.get(name, []))
    if not text:
        problems.append(f"`litedoc4 {name}` has no synopsis in USAGE at all")
        continue
    for flag in sections[name]:
        if not re.search(rf"{re.escape(flag)}\b", text):
            problems.append(f"`litedoc4 {name}` no longer offers `{flag}`, and 1.x promised it")

# --- litedoc4.toml keys, against the struct serde reads ---------------------
config = (root / "crates/litedoc4-render/src/config.rs").read_text(encoding="utf-8")
if "deny_unknown_fields" not in config:
    problems.append(
        "config.rs no longer says deny_unknown_fields — the fields of `File` stop "
        "being the accepted key set, and this check stops meaning anything"
    )
block = config.split("struct File {", 1)[1].split("\n}", 1)[0]
fields = set(re.findall(r"^\s{4}(\w+):", block, re.M))
for key in sections["litedoc4.toml"]:
    if key not in fields:
        problems.append(f"litedoc4.toml key `{key}` is not a field of `File`, and 1.x promised it")

if problems:
    for problem in problems:
        print(f"PUBLIC SURFACE FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(
    "PUBLIC SURFACE: "
    f"{len(sections['action-inputs'])} action inputs, {len(sections['action-outputs'])} outputs, "
    f"{len(sections['build'])} build flags, {len(sections['watch'])} watch flags, "
    f"{len(sections['litedoc4.toml'])} config keys — all present"
)
PY
