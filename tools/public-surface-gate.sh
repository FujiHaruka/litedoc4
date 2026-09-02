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
#   build / watch    the synopsis in src/Litedoc4/Main.lean, one direction. A
#                    synopsis is text, so **on its own this says only that the
#                    promised flag is spelled somewhere** — which is not what 1.x
#                    promised. What raises it to *accepted* is the second half of
#                    the pair: `tools/flag-tie-gate.sh` hands every flag the
#                    synopsis names to the binary and fails on `unknown argument`,
#                    and it checks that every name promised here is one of them, so
#                    the two compose into promised -> documented -> accepted.
#                    **Do not weaken either end without the other.** What neither
#                    can see is a flag that stopped doing anything while keeping
#                    its name
#   litedoc4.toml    the names `parseConfig` tests for in src/Litedoc4/Config.lean,
#                    which refuses every other key — so that *is* the accepted key
#                    set
#
# ONE HALF, BECAUSE THERE IS ONE PRODUCT
#   This used to ask the same questions of `crates/litedoc4/src/lib.rs` and
#   `crates/litedoc4-render/src/config.rs` too, because a release published a Rust
#   binary and `action.yml` resolved it. Nothing is distributed in Object form any
#   more: a consumer writes `require «litedoc4»` and Lake builds `lean_exe
#   litedoc4` out of the ref they pinned, and the action does the same. So the
#   promise has exactly one implementation, and it is the one read here.
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

# --- build / watch, against each half's synopsis ----------------------------
def synopsis_of(usage: str) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    command = None
    for line in usage.splitlines():
        started = re.match(r"(?:usage:)?\s*litedoc4 (\w+)", line)
        if started:
            command = started.group(1)
            found.setdefault(command, [])
        elif not line.startswith(" " * 20):
            command = None
        if command:
            found[command].append(line)
    return found


def between(text: str, opening: str, closing: str, where: str) -> str:
    if opening not in text:
        sys.exit(
            f"public-surface: the synopsis is not where this gate looks for it in {where} — "
            "the flag checks below would read an empty string"
        )
    return text.split(opening, 1)[1].split(closing, 1)[0]


# Cut at the closing quote of a plain Lean string whose last line is `--help`.
usage = between(
    (root / "src/Litedoc4/Main.lean").read_text(encoding="utf-8"),
    'def usage : String :=\n"',
    '"\n',
    "src/Litedoc4/Main.lean",
)

synopsis = synopsis_of(usage)
for name in ("build", "watch"):
    text = "\n".join(synopsis.get(name, []))
    if not text:
        problems.append(f"`litedoc4 {name}` has no synopsis at all")
        continue
    for flag in sections[name]:
        if not re.search(rf"{re.escape(flag)}\b", text):
            problems.append(
                f"`litedoc4 {name}` no longer offers `{flag}`, and 1.x promised it"
            )

# --- litedoc4.toml keys, against what the parser accepts ---------------------
# `parseConfig` refuses a key it does not name, so the names it tests for *are*
# the accepted key set; without the refusal they stop being that.
lean_config = (root / "src/Litedoc4/Config.lean").read_text(encoding="utf-8")
lean_parse = between(
    lean_config, "def parseConfig", "\n\n", "src/Litedoc4/Config.lean"
)
if "unknown key" not in lean_parse:
    problems.append(
        "parseConfig no longer refuses an unknown key — the names it tests for stop "
        "being the accepted key set, and this check stops meaning anything"
    )
accepted = set(re.findall(r'key == "(\w+)"', lean_parse))

for key in sections["litedoc4.toml"]:
    if key not in accepted:
        problems.append(
            f"`parseConfig` does not accept the litedoc4.toml key `{key}`, and 1.x "
            "promised it"
        )

if problems:
    for problem in problems:
        print(f"PUBLIC SURFACE FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(
    "PUBLIC SURFACE: "
    f"{len(sections['action-inputs'])} action inputs, {len(sections['action-outputs'])} outputs, "
    f"{len(sections['build'])} build flags, {len(sections['watch'])} watch flags, "
    f"{len(sections['litedoc4.toml'])} config keys — all present; the "
    f"{len(sections['build']) + len(sections['watch'])} flags are *spelled* here and "
    "*accepted* by tools/flag-tie-gate.sh"
)
PY
