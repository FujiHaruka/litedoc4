#!/usr/bin/env bash
# Two rules CLAUDE.md states and nothing enforced.
#
#   1  "**(measured)** — there is a log | the path to the log must be followable".
#      Every benchmarks/results/<file> named anywhere outside that directory has
#      to exist. A number whose log has been renamed away is a number with no
#      provenance, and it reads exactly like one that still has it.
#
#   2  "Between docs too, do not point at a document expected to be completed and
#      disappear as a SoT. Pointers rot." Nineteen planning documents were deleted
#      on 2026-08-24 and five references to them survived (measured 2026-08-29).
#      A reference to a deleted document is allowed — this repository keeps them
#      on purpose — but only when the line says so, so that a reader is sent to
#      git instead of to a 404.
#
# WHAT IS SKIPPED, AND WHY IT HAD TO BE
#   Rule 1 skips a citation containing `*`, `{` or `<`, and one ending in `-` or
#   `_`. Those are globs, `<label>` templates, and paths a comment wrapped across
#   two lines — all three exist in this tree. Rule 2 looks only at this
#   repository's planning documents, not at every `docs/*.md` string: the
#   `litedoc4.toml` example names `docs/index.md` in the *user's* package, which
#   is not a file this repository has or should have.
#   The first cut of this gate reported 39 findings and every one of them was its
#   own fault. A gate that noisy is one people learn to skip, which is worse than
#   not having it.
#
# Reads the tree. No binary, no toolchain, no target.
#
# usage: docs-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
problems = []

LOG = re.compile(r"benchmarks/results/[A-Za-z0-9._*{}<>,-]+")
# A document that lives inside benchmarks/ writes the path it would type in a
# shell there. Reading only the repository-root spelling left every citation in
# `benchmarks/purelean-report.md` unchecked — twelve of them, and a citation
# naming a file that does not exist passed (measured 2026-08-31). The lookbehind
# is what keeps this from matching the tail of the absolute spelling twice, and
# the base is only benchmarks/ because `results/` outside it means something else
# (`.github/workflows/ci-placement.yml` names a runner's own output directory).
LOG_REL = re.compile(r"(?<![A-Za-z0-9._/-])results/[A-Za-z0-9._*{}<>,-]+")
# This repository's own planning documents, which is what the rule is about.
DOC = re.compile(
    r"(?:docs/)?plans/[A-Za-z0-9._-]+\.md"
    r"|docs/(?:implementation-plan|milestone-log)\.md"
)
FORGIVEN = ("git", "削除")

# The repository's own files, from git rather than from a walk: `target/` alone
# is hundreds of thousands of entries, and rglob pays for them before the filter
# sees them (31 s against 1 s, measured).
tracked = subprocess.run(
    ["git", "-C", str(root), "ls-files", "-z"], capture_output=True, text=True, check=True
).stdout.split("\0")
files = [
    root / name
    for name in tracked
    if name
    and not name.startswith("benchmarks/results/")
    and pathlib.Path(name).suffix in {".md", ".rs", ".sh", ".ts", ".py", ".yml", ".lean", ".toml", ".txt"}
]
if not files:
    sys.exit("docs-gate: no files to read — this gate would check nothing")

logs_seen = 0
for path in files:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    rel = path.relative_to(root).as_posix()
    bases = [(LOG, root)]
    if rel.startswith("benchmarks/"):
        bases.append((LOG_REL, root / "benchmarks"))
    for line_no, line in enumerate(text.splitlines(), 1):
        for pattern, base in bases:
          for match in pattern.findall(line):
            cited = match.rstrip(".,)}\"'")
            if any(c in cited for c in "*{<") or cited.endswith(("-", "_", "/")):
                continue
            logs_seen += 1
            if not (base / cited).exists():
                problems.append(f"{rel}:{line_no} cites {cited}, which is not there")
        for match in DOC.findall(line):
            cited = match.rstrip(".,)")
            if (root / cited).exists() or (root / "docs" / cited).exists():
                continue
            if any(word in line for word in FORGIVEN):
                continue
            problems.append(
                f"{rel}:{line_no} points at {cited}, which was deleted, and does not say so"
            )

if logs_seen == 0:
    sys.exit("docs-gate: no benchmarks/results citation found at all — rule 1 checked nothing")

if problems:
    for problem in problems:
        print(f"DOCS GATE FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(f"DOCS GATE: {logs_seen} measurement-log citation(s) all resolve; no dead document pointer")
PY
