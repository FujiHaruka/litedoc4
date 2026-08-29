#!/usr/bin/env bash
# Do the workflows do what this repository says they do?
#
# Three questions, all of them about the distance between a claim and the YAML:
#
#   1  every tools/*-gate.sh is in tools/gates.txt, and every row names a script
#      that exists — the shape tools/corpus-gate.sh --verify-list already gives
#      the `#[ignore]`d tests, for the same reason
#   2  a row marked `ci` is really invoked by a workflow, and a row marked
#      `manual` is really not. A label nobody checks is worse than no label:
#      `build-gate.sh` sat there for months as a gate nobody ran
#   3  every workflow that runs `cargo` installs node. `crates/litedoc4-render`'s
#      build.rs runs vite, so a job without it fails inside a build script — and
#      on the development machine the failure is exit 137 with no output at all
#
# Question 3 replaces a sentence in CLAUDE.md that counted the workflows. The
# count was wrong twice in one day (8 -> 7 -> 9, measured 2026-08-29): a number in
# prose has no way to notice the file someone just added.
#
# Reads the tree. No binary, no toolchain, no target.
#
# usage: workflow-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
problems = []

# A backslash cannot live inside an f-string on the Python this machine runs, and
# this pattern is used in two places besides.
CARGO = r"\bcargo \w"
# The path prefix varies: ci-placement.yml checks litedoc4 out into a
# subdirectory, so it says `./litedoc4/.github/actions/setup-node`. Anchor on the
# tail, and on `@` for the upstream action, so that `setup-nodeX` still fails.
NODE = r"(\.github/actions/setup-node(\s|$)|actions/setup-node@)"

rows = {}
for line in (root / "tools/gates.txt").read_text(encoding="utf-8").splitlines():
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    parts = line.split(None, 2)
    if len(parts) < 2 or parts[1] not in ("ci", "manual"):
        sys.exit(f"workflow-gate: tools/gates.txt row is not `<script> ci|manual <needs>`: {line!r}")
    rows[parts[0]] = parts[1]

on_disk = {p.name for p in sorted((root / "tools").glob("*-gate.sh"))}
if not on_disk:
    sys.exit("workflow-gate: no tools/*-gate.sh found at all — this gate would check nothing")

for name in sorted(on_disk - set(rows)):
    problems.append(f"{name} exists and is in no row of tools/gates.txt")
for name in sorted(set(rows) - on_disk):
    problems.append(f"tools/gates.txt names {name}, which is not in tools/")

# A basename inside a `#` comment is a mention, not a call.
workflows = {}
for path in sorted((root / ".github").rglob("*.yml")):
    body = "\n".join(
        line for line in path.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("#")
    )
    workflows[path] = body
if not workflows:
    sys.exit("workflow-gate: no workflow files found — this gate would check nothing")

# Reachability, not "named in a workflow": `config-gate.sh` and `usedby-gate.sh`
# are run by `tools/e2e-micro.sh`, which a workflow runs. Stopping at the YAML
# would call those two uninvoked and be wrong about it, which is how a gate
# teaches people to ignore it.
def uncommented(path):
    return "\n".join(
        line for line in path.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("#")
    )


scripts = {p.name: uncommented(p) for p in sorted((root / "tools").glob("*.sh"))}
reached = {name for name in scripts if any(name in body for body in workflows.values())}
while True:
    grown = {
        name
        for name in scripts
        if name not in reached and any(name in scripts[seed] for seed in reached)
    }
    if not grown:
        break
    reached |= grown

for name, who in sorted(rows.items()):
    called = name in reached
    if who == "ci" and not called:
        problems.append(
            f"{name} is marked `ci` and nothing a workflow runs reaches it — "
            "either wire it in or mark it manual"
        )
    if who == "manual" and called:
        problems.append(
            f"{name} is marked `manual` and something a workflow runs reaches it — "
            "the label is wrong, not the workflow"
        )

# `cargo` anywhere in a job means the render crate's build.rs may run vite.
missing_node = []
for path, body in workflows.items():
    if path.parent.name != "workflows":
        continue
    # The reference, not the substring: `setup-nodeX` contains `setup-node`, and
    # a check that accepts it accepts a typo that installs nothing (found while
    # trying to make this very check fail, 2026-08-29).
    if re.search(CARGO, body) and not re.search(NODE, body):
        missing_node.append(path.name)
for name in sorted(missing_node):
    problems.append(f"{name} runs cargo and never installs node — build.rs runs vite")

if problems:
    for problem in problems:
        print(f"WORKFLOW GATE FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

ci = sum(1 for w in rows.values() if w == "ci")
cargo_jobs = sum(
    1
    for path, body in workflows.items()
    if path.parent.name == "workflows" and re.search(CARGO, body)
)
print(
    f"WORKFLOW GATE: {len(rows)} gate(s) inventoried, {ci} run by a workflow, "
    f"{len(rows) - ci} manual; {cargo_jobs} workflow(s) run cargo and all install node"
)
PY
