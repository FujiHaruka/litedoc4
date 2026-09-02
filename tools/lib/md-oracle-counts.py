#!/usr/bin/env python3
"""Print `<docgen4 cases> <md4lean cases>`, or say on stderr why it cannot.

Item 1 of `tools/md-oracle-gate.sh`. Its own file because the gate has to read
the answer *and* the exit code, and a heredoc inside a command substitution is
where those two came apart.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent

counts = []
for name in ("docgen4-expected.json", "md4lean-expected.json"):
    path = ROOT / "fixtures" / "md" / name
    if not path.is_file() or path.stat().st_size == 0:
        sys.exit(f"absent or empty: fixtures/md/{name}")
    cases = json.loads(path.read_text(encoding="utf-8")).get("cases")
    if not cases:
        sys.exit(f"fixtures/md/{name} holds no cases; the generator would write an empty corpus")
    counts.append(str(len(cases)))
print(" ".join(counts))
