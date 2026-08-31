"""A resolved documentation map of the shape `litedoc4 build --deps-docs-url`
writes, built out of an IR tree's own `deps/*.json`.

**Half of each root's names, never all of them**: a map that documents every name
a page can refer to leaves no witness for the other branch of the rule, and the
gate reading this would then compare two trees in which nothing fell back to the
version-pinned source.

The base is a host nobody serves. Nothing here fetches, and the resulting links
are checked as bytes and never followed — the gate that follows real ones is
`tools/deps-docs-gate.sh`.

usage: deps-docs-fixture.py <ir-dir> <out.json> <base-url>
"""

import json
import os
import sys

if len(sys.argv) != 4:
    sys.exit(__doc__)

ir, out, base = sys.argv[1:4]
index = json.load(open(os.path.join(ir, "index.json"), encoding="utf-8"))

by_root: dict[str, dict[str, str]] = {}
for entry in index.get("dependencyMaps", []):
    slice_ = json.load(open(os.path.join(ir, entry["file"]), encoding="utf-8"))
    for name, module in slice_.get("declarations", {}).items():
        by_root.setdefault(module.split(".", 1)[0], {})[name] = module

roots = []
for root in sorted(by_root):
    names = dict(sorted(by_root[root].items()))
    half = dict(list(names.items())[: max(1, len(names) // 2)])
    roots.append(
        {
            "root": root,
            "base": base,
            "requestedNames": len(names),
            "declarations": {
                name: "./%s.html#%s" % (module.replace(".", "/"), name)
                for name, module in half.items()
            },
            "modules": {
                module: "./%s.html" % module.replace(".", "/")
                for module in sorted(set(half.values()))
            },
        }
    )

with open(out, "w", encoding="utf-8") as handle:
    json.dump({"tool": "litedoc4 deps-docs", "version": 1, "roots": roots}, handle)
    handle.write("\n")

print(
    "%d root(s), %d of %d name(s) documented"
    % (
        len(roots),
        sum(len(entry["declarations"]) for entry in roots),
        sum(entry["requestedNames"] for entry in roots),
    )
)
