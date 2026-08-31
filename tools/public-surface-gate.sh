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
#   build / watch    each half's own synopsis, one direction. A synopsis is text,
#                    so on its own a flag reachable here is only a flag the
#                    command line *documents*. What makes it a flag some parser
#                    *accepts* is a second gate: `tools/flag-tie-gate.sh` hands
#                    every documented flag to both binaries and fails on
#                    `unknown argument`. What neither can see is a flag that
#                    stopped doing anything while keeping its name
#   litedoc4.toml    the fields of `struct File` in litedoc4-render's config.rs,
#                    which serde reads with `deny_unknown_fields`, and the names
#                    `parseConfig` tests for in src/Litedoc4/Config.lean, which
#                    refuses every other key — so each *is* that half's accepted
#                    key set
#
# BOTH HALVES ARE ASKED, AND THAT IS THE POINT WHILE BOTH SHIP
#   The same promise has two implementations today: the Rust binary a release
#   publishes and `action.yml` resolves, and the Lean `lean_exe` a consumer gets
#   from `require «litedoc4»`. A check that read only one of them would leave the
#   other free to drop a promised name — and which one is "the product" depends on
#   how the consumer installed it, not on which tree is newer. So every flag and
#   config-key check runs twice and the failure says which half is missing the
#   name. The Lean readings are `usage` in src/Litedoc4/Main.lean and
#   `parseConfig` in src/Litedoc4/Config.lean, which refuses a key it does not
#   name and is therefore the `deny_unknown_fields` of that half. When the Rust
#   tree is deleted, its half of this gate goes with it and the question survives.
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


halves = {
    # Each half is cut at its own closing quote: the Rust literal opens with a
    # line continuation and ends at `";`, the Lean one is a plain string whose
    # last line is the `--help` line.
    "rust": between(
        (root / "crates/litedoc4/src/lib.rs").read_text(encoding="utf-8"),
        'pub const USAGE: &str = "\\\n',
        '\n";',
        "crates/litedoc4/src/lib.rs",
    ),
    "lean": between(
        (root / "src/Litedoc4/Main.lean").read_text(encoding="utf-8"),
        'def usage : String :=\n"',
        '"\n',
        "src/Litedoc4/Main.lean",
    ),
}

for half, usage in halves.items():
    synopsis = synopsis_of(usage)
    for name in ("build", "watch"):
        text = "\n".join(synopsis.get(name, []))
        if not text:
            problems.append(f"the {half} `litedoc4 {name}` has no synopsis at all")
            continue
        for flag in sections[name]:
            if not re.search(rf"{re.escape(flag)}\b", text):
                problems.append(
                    f"the {half} `litedoc4 {name}` no longer offers `{flag}`, and 1.x promised it"
                )

# --- litedoc4.toml keys, against what each half accepts ---------------------
config = (root / "crates/litedoc4-render/src/config.rs").read_text(encoding="utf-8")
if "deny_unknown_fields" not in config:
    problems.append(
        "config.rs no longer says deny_unknown_fields — the fields of `File` stop "
        "being the accepted key set, and this check stops meaning anything"
    )
block = config.split("struct File {", 1)[1].split("\n}", 1)[0]
accepted = {"rust": set(re.findall(r"^\s{4}(\w+):", block, re.M))}

# `parseConfig` refuses a key it does not name, which is that half's
# deny_unknown_fields; without the refusal the names below stop being the key set.
lean_config = (root / "src/Litedoc4/Config.lean").read_text(encoding="utf-8")
lean_parse = between(
    lean_config, "def parseConfig", "\n\n", "src/Litedoc4/Config.lean"
)
if "unknown key" not in lean_parse:
    problems.append(
        "parseConfig no longer refuses an unknown key — the names it tests for stop "
        "being the accepted key set, and this check stops meaning anything"
    )
accepted["lean"] = set(re.findall(r'key == "(\w+)"', lean_parse))

for half, fields in accepted.items():
    for key in sections["litedoc4.toml"]:
        if key not in fields:
            problems.append(
                f"the {half} half does not accept the litedoc4.toml key `{key}`, and 1.x "
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
    f"{len(sections['litedoc4.toml'])} config keys — all present in both halves"
)
PY
