#!/usr/bin/env bash
# Do the workflows do what this repository says they do?
#
# Three questions, all of them about the distance between a claim and the YAML:
#
#   1  every tools/*-gate.sh is in tools/gates.txt, and every row names a script
#      that exists — a gate in no row is one nobody knows to run, and a row with
#      no script is a claim about a check nobody wrote
#   2  a row marked `ci` is really invoked by a workflow, and a row marked
#      `manual` is really not. A label nobody checks is worse than no label:
#      `build-gate.sh` sat there for months as a gate nobody ran
#   3  every workflow that reaches something needing node installs node. The
#      subject used to be `cargo`, because a build script ran vite; that left
#      with `crates/`, and what needs node now is `tools/assets-gate.sh` — npm,
#      npx biome, tsc, vitest and vite. A job without node fails inside one of
#      those, and on the development machine the failure is exit 137 with no
#      output at all. Reached transitively, so a workflow that calls a script
#      that calls the gate counts; and if nothing in the tree needs node the gate
#      stops rather than reporting a rule with no subject as satisfied
#   4  no gate prints a heading that the shell will eat. A backtick inside double
#      quotes is command substitution: `say "6/8 `site` writes ..."` ran `site`,
#      printed `command not found` to stderr, and put an empty string where the
#      word should have been — while the gate itself stayed green and correct
#      (measured 2026-08-31, two headings in purelean-micro-gate.sh)
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
#
# A *command position* — the start of a line or just after `|`, `&&`, `;` or `(`
# — and not a bare word anywhere. A bare word matches this file's own prose and
# its own pattern, so the gate would count itself as needing node and demand it
# of every workflow that runs it. Whatever spelling a future script uses has to
# be added here, which is the cost of the rule being a grep rather than a run.
NEEDS_NODE = r"(?m)(?:^|[|&;(])[ \t]*(?:npm|npx|node)[ \t]"
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


# A basename is a call only where it starts: `gc-table-gate.sh` is a substring of
# `v8-gc-table-gate.sh`, so a plain `in` marks the manual gate as reached the
# moment the CI one is wired in — the label is then read as a lie and the wiring
# as missing, both wrong (measured 2026-09-01). Same failure the NODE pattern
# above already guards against.
def calls(name, body):
    return re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(name) + r"(?![A-Za-z0-9_-])", body)


reached = {name for name in scripts if any(calls(name, body) for body in workflows.values())}
while True:
    grown = {
        name
        for name in scripts
        if name not in reached and any(calls(name, scripts[seed]) for seed in reached)
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

# Which scripts need node, and which workflows reach one. `NODE` itself names
# the action, so a workflow is not counted as needing node merely for installing
# it.
node_scripts = {name for name, body in scripts.items() if re.search(NEEDS_NODE, body)}
if not node_scripts:
    sys.exit(
        "workflow-gate: no script under tools/ runs npm, npx or node — question 3 "
        "has no subject left, and a rule that cannot fail is worse than no rule"
    )


def reaches(body):
    seen = {name for name in scripts if calls(name, body)}
    while True:
        grown = {
            name
            for name in scripts
            if name not in seen and any(calls(name, scripts[seed]) for seed in seen)
        }
        if not grown:
            return seen
        seen |= grown


needs_node = {}
for path, body in workflows.items():
    if path.parent.name != "workflows":
        continue
    wanted = sorted(reaches(body) & node_scripts)
    if re.search(NEEDS_NODE, re.sub(NODE, "", body)):
        wanted.append(path.name)
    if wanted:
        needs_node[path.name] = wanted
for name, wanted in sorted(needs_node.items()):
    # The reference, not the substring: `setup-nodeX` contains `setup-node`, and
    # a check that accepts it accepts a typo that installs nothing (found while
    # trying to make this very check fail, 2026-08-29).
    if not re.search(NODE, workflows[[p for p in workflows if p.name == name][0]]):
        problems.append(
            f"{name} reaches {', '.join(wanted)}, which needs node, and never installs it"
        )
if not needs_node:
    sys.exit(
        "workflow-gate: no workflow reaches anything needing node — question 3 would "
        "report a rule it never applied"
    )

# Question 4. Deliberately narrow: only the lines that *print* — `say`, `echo`,
# `printf`, and the `fail`/`pass`/`die` helpers — and only the span between the
# first and last double quote on the line. A general shell parser here would be
# a second implementation of bash; this one has no false positive over the whole
# tree (measured 2026-08-31) because a backtick meant literally is already
# written as an escaped one everywhere else.
PRINTS = re.compile(r"^\s*(say|echo|printf|fail|pass|die)\b")
HEREDOC = re.compile(r"<<-?'([A-Za-z_][A-Za-z0-9_]*)'")
scripts = sorted(root.glob("tools/**/*.sh"))
for path in scripts:
    inside = None
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if inside is not None:
            if line.strip() == inside:
                inside = None
            continue
        opened = HEREDOC.search(line)
        if opened:
            inside = opened.group(1)
            continue
        if not PRINTS.match(line):
            continue
        first, last = line.find('"'), line.rfind('"')
        if first < 0 or last <= first:
            continue
        span = line[first + 1:last]
        bare = sum(
            1
            for i, char in enumerate(span)
            if char == "`" and (i == 0 or span[i - 1] != "\\")
        )
        if bare:
            name = path.relative_to(root)
            problems.append(
                f"{name}:{number} prints {bare} unescaped backtick(s) inside double "
                "quotes — the shell runs what is between them and drops the word"
            )

if problems:
    for problem in problems:
        print(f"WORKFLOW GATE FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

ci = sum(1 for w in rows.values() if w == "ci")
print(
    f"WORKFLOW GATE: {len(rows)} gate(s) inventoried, {ci} run by a workflow, "
    f"{len(rows) - ci} manual; {len(needs_node)} workflow(s) reach node "
    f"({len(node_scripts)} script(s) need it) and all install it; "
    f"{len(scripts)} script(s) print no backtick the shell would eat"
)
PY
