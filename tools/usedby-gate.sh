#!/usr/bin/env bash
# "Used by", checked against the IR it was derived from — **in both directions**.
#
# For declarations A and B of the same package:
#
#     A's IR mentions B   ⟺   B's entry in declarations/used-by.json holds A
#
# Both halves, because each catches a failure the other cannot: a used-by that
# dropped every second entry passes the forward half on whatever it kept, and one
# that invented users passes the backward half on whatever it invented. The pair
# needs no external oracle — the IR is the site's own input.
#
# It does **not** assert that a name in the file has a page:
# `benchmarks/tools/check-site-closure.py` does that for the other maps, and two
# gates checking one property is how the second stops being read.
#
# The expected side is built here from `refs` in the module IR by code that shares
# nothing with `litedoc4-global` — a Python dict of sets against a Rust
# `HashMap<&str, Vec<&str>>` filled from a per-module `BTreeMap`. An oracle
# written in the same language with the same design makes the same mistake.
#
# usage: usedby-gate.sh --ir <dir> --site <dir> [--drop <name>]
#          --drop  remove one entry from the artifact before comparing, to see
#                  the gate fail. Never in CI; it is how the gate was falsified.
set -uo pipefail

IR=""
SITE=""
DROP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ir) IR="$2"; shift 2 ;;
    --site) SITE="$2"; shift 2 ;;
    --drop) DROP="$2"; shift 2 ;;
    -h|--help) sed -n '1,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -n "$IR" ] && [ -n "$SITE" ] || { echo "usage: usedby-gate.sh --ir <dir> --site <dir>" >&2; exit 2; }
[ -d "$IR/modules" ] || { echo "no IR modules at $IR/modules" >&2; exit 2; }
[ -f "$SITE/declarations/used-by.json" ] || {
  echo "no $SITE/declarations/used-by.json — the site predates this artifact" >&2; exit 2; }

python3 - "$IR" "$SITE" "$DROP" <<'PY'
import json
import os
import sys

ir, site, drop = sys.argv[1:4]
problems = []

own_modules = set()
declares = {}          # name -> module
forward = []           # (user name, target name)
modules_dir = os.path.join(ir, "modules")
files = sorted(f for f in os.listdir(modules_dir) if f.endswith(".json"))
for name in files:
    with open(os.path.join(modules_dir, name), encoding="utf-8") as handle:
        module = json.load(handle)
    own_modules.add(module["module"])
    for decl in module["declarations"]:
        declares[decl["name"]] = module["module"]
for name in files:
    with open(os.path.join(modules_dir, name), encoding="utf-8") as handle:
        module = json.load(handle)
    for decl in module["declarations"]:
        for reference in decl.get("refs", []):
            # `refs` is `[defining module, name]` on the wire.
            forward.append((decl["name"], reference[1]))

# The filter is "does this package declare the target", not "is the defining
# module ours": they agree today, and the first is what the artifact's keys mean.
want = {}
for user, target in forward:
    if target in declares:
        want.setdefault(target, set()).add(user)

with open(os.path.join(site, "declarations", "used-by.json"), encoding="utf-8") as handle:
    got_raw = json.load(handle)
if drop:
    if drop not in got_raw:
        sys.exit(f"--drop {drop}: the artifact has no such key")
    del got_raw[drop]
got = {key: set(value) for key, value in got_raw.items()}

missing = []       # in the IR, not in the artifact
invented = []      # in the artifact, not in the IR
for target, users in want.items():
    for user in users - got.get(target, set()):
        missing.append(f"{user} -> {target}")
for target, users in got.items():
    for user in users - want.get(target, set()):
        invented.append(f"{user} -> {target}")

if missing:
    problems.append(
        f"{len(missing)} reference(s) the IR has and used-by.json does not: "
        + "; ".join(sorted(missing)[:5])
    )
if invented:
    problems.append(
        f"{len(invented)} entry/entries in used-by.json that no IR reference supports: "
        + "; ".join(sorted(invented)[:5])
    )

# What was actually compared, not the absence of complaints: a gate over an empty
# expected set reports "ok" having checked nothing.
edges = sum(len(users) for users in want.values())
if not files:
    problems.append("no module IR was read")
if edges == 0:
    problems.append(
        "the IR holds no reference between two declarations of this package — "
        "nothing was compared, so a green here would mean nothing"
    )

if problems:
    for problem in problems:
        print(f"USEDBY GATE FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(
    f"usedby       {len(files)} module(s), {len(declares)} declaration(s); "
    f"{len(want)} target(s) / {edges} edge(s) agree in both directions"
)
PY
