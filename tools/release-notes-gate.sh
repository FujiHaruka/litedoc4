#!/usr/bin/env bash
# Does .github/release-notes.md still describe the release it will be published on?
#
# `release.yml` publishes that file with `@VERSION@` substituted, instead of
# `--generate-notes`. That removes a hand step and puts the words under review —
# and puts them where they can go stale, which is what this reconciles:
#
#   1  the file names a version at all, i.e. `@VERSION@` survives in it, so the
#      two blocks a reader copies are about the release they are reading
#   2  the archives it lists are exactly the archives `release.yml` asserts the
#      release carries. Both directions: a name only in the notes promises a
#      download that is not there, a name only in the workflow ships a platform
#      the notes tell people to build from source
#   3  the Lean versions it lists are exactly `tools/lean-toolchains.txt`. Both
#      directions again, for the same reason README's copy of that list is
#      checked: the file is where the list lives
#   4  every archive README names is one of those. **One direction only**: a
#      target README does not mention costs a reader a download they could have
#      had, while a name README has and the release has not is a `curl` that
#      404s in the one place people copy commands from
#
# Reads the tree. No binary, no toolchain, no target.
#
# usage: release-notes-gate.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
notes_path = root / ".github/release-notes.md"
if not notes_path.is_file():
    sys.exit(f"release-notes-gate: {notes_path} is not there, and release.yml publishes it")
notes = notes_path.read_text(encoding="utf-8")
release = (root / ".github/workflows/release.yml").read_text(encoding="utf-8")
toolchains_path = root / "tools/lean-toolchains.txt"

problems = []

if "@VERSION@" not in notes:
    problems.append(
        ".github/release-notes.md has no @VERSION@ — the pin instructions would "
        "name no version, and release.yml substitutes nothing"
    )

ASSET = re.compile(r"litedoc4-[a-z0-9_]+-[a-z0-9-]+\.tar\.gz")
# The assertion loop, not the whole file: the matrix spells its targets without
# the `litedoc4-` prefix and the `.tar.gz` suffix, and the download patterns are
# globs. What this compares against is the list the publish job refuses to
# finish without.
loop = re.search(r"for want in (.*?)done", release, re.S)
if not loop:
    sys.exit(
        "release-notes-gate: no `for want in ... done` in release.yml — that loop "
        "is what this gate compares the notes against"
    )
asserted = set(ASSET.findall(loop.group(1)))
if not asserted:
    sys.exit("release-notes-gate: release.yml's assertion loop names no archive")
listed = set(ASSET.findall(notes))
for name in sorted(listed - asserted):
    problems.append(
        f"the notes list {name}, which release.yml does not assert the release carries"
    )
for name in sorted(asserted - listed):
    problems.append(
        f"release.yml asserts {name} is on the release, and the notes do not list it"
    )

for name in sorted(set(ASSET.findall((root / "README.md").read_text(encoding="utf-8"))) - asserted):
    problems.append(
        f"README names {name}, which release.yml does not assert the release carries — "
        "the install instruction would 404"
    )

LEAN = re.compile(r"v4\.\d+\.\d+")
pinned = set(LEAN.findall(toolchains_path.read_text(encoding="utf-8")))
if not pinned:
    sys.exit(f"release-notes-gate: no toolchain rows in {toolchains_path}")
said = set(LEAN.findall(notes))
for version in sorted(said - pinned):
    problems.append(f"the notes claim Lean {version}, which tools/lean-toolchains.txt does not")
for version in sorted(pinned - said):
    problems.append(f"tools/lean-toolchains.txt has Lean {version}, and the notes do not say so")

if problems:
    for problem in problems:
        print(f"RELEASE NOTES GATE FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(
    f"RELEASE NOTES GATE: {len(asserted)} archive(s) and {len(pinned)} Lean version(s), the "
    "notes agreeing with the tree in both directions, and README naming no archive the "
    "release does not carry"
)
PY
