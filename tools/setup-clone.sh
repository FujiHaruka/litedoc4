#!/usr/bin/env bash
# Make an APFS clonefile copy of the measurement target, and move one module's
# body into a new module inside it.
#
# The measurement target must not be modified and this experiment needs `lake
# build` to run over an edited source. `cp -Rc` on APFS is copy-on-write: the
# 12 GB tree costs ~0 real disk and ~34 s, and the original is never written to.
#
# The move: A's body goes to a new module X = A ++ "Core" and A becomes a shim
# that imports X. Full names do not change — a namespace comes from the
# `namespace` command, not the file path — so the only thing that changes is
# *which module defines the names*, which is invisible in a referring module's olean.
#
# **A is a parameter, and choosing it wrong wastes the experiment.** A module
# whose names nobody mentions in a printed signature makes the move unobservable
# by construction: backticks in a *module docstring* of a module with zero
# declarations do not count. Pick A from `litedoc4 impact --census` — it must
# have referrers.
#
# The shim style is a parameter too:
#   minimal       A becomes `import X` and nothing else. The default.
#   keep-imports  A keeps its original imports and adds `import X`, which leaves
#                 imports the now-empty A does not use. That changes what
#                 Mathlib's style linter logs, and that log is an environment
#                 extension serialized into oleans.
#
# usage:
#   setup-clone.sh clone <clone-dir>
#   setup-clone.sh move  <clone-dir> <module> [style]
#   setup-clone.sh reset <clone-dir>
set -euo pipefail

SRC="${TARGET_SRC:-/Users/haruka/dev/lean-projects}"
CMD=${1:?clone|move|reset}
CLONE=${2:?clone dir}
LAKE="${LAKE:-$HOME/.elan/bin/lake}"

case "$CLONE" in
  "$SRC"|"$SRC"/*) echo "refusing to write inside the measurement target" >&2; exit 2 ;;
esac

if [ "$CMD" = clone ]; then
  if [ ! -d "$CLONE" ]; then
    echo "### cloning $SRC -> $CLONE (APFS clonefile)"
    time cp -Rc "$SRC" "$CLONE"
  fi
  # Both gates decide "is this clone a baseline" with `git status --porcelain`,
  # which counts untracked paths, and the measurement target carries one that is
  # no part of the package. Without this the clone is 'unknown' from the moment
  # it is made and every phase refuses; `reset` does not cure it either, because
  # its `clean` is scoped to the library. `-fd` and not `-fdx`: `.lake` is
  # ignored, and taking the build tree out would throw away the oleans the clone
  # exists to carry. On a target with nothing untracked this removes nothing.
  echo "### making the clone git-clean (the target's untracked paths are not the package)"
  git -C "$CLONE" clean -fd
  echo "### verifying the clone is up to date"
  (cd "$CLONE" && "$LAKE" build --no-build 2>&1 | tail -2)
  exit 0
fi

if [ "$CMD" = reset ]; then
  echo "### undoing every edit in the clone's sources"
  git -C "$CLONE" clean -fd -- InformationTheory InformationTheory.lean
  git -C "$CLONE" checkout -- InformationTheory InformationTheory.lean
  (cd "$CLONE" && "$LAKE" build 2>&1 | tail -3)
  exit 0
fi

[ "$CMD" = move ] || { echo "usage: setup-clone.sh clone|move|reset <dir> ..." >&2; exit 2; }
A_MOD=${3:?module to move}
STYLE=${4:-minimal}
X_MOD="${A_MOD}Core"
A_REL="$(echo "$A_MOD" | tr '.' '/').lean"
X_REL="$(echo "$X_MOD" | tr '.' '/').lean"

if [ -f "$CLONE/$X_REL" ]; then
  echo "### the move is already applied"
  exit 0
fi
[ -f "$CLONE/$A_REL" ] || { echo "no such module file: $A_REL" >&2; exit 2; }

echo "### moving $A_MOD -> $X_MOD (shim style: $STYLE)"
python3 - "$CLONE/$A_REL" "$CLONE/$X_REL" "$X_MOD" "$STYLE" <<'PY'
import sys
a_path, x_path, x_mod, style = sys.argv[1:]
src = open(a_path, encoding="utf-8").read()

# X is A verbatim; only the file it lives in differs, which is the change under test.
open(x_path, "w", encoding="utf-8").write(src)

# A must still exist and still be importable: the referring modules import it and
# they are not allowed to change.
if style == "minimal":
    shim = f"import {x_mod}\n"
elif style == "keep-imports":
    imports = [l for l in src.split("\n") if l.startswith("import ")]
    shim = "\n".join(imports + [f"import {x_mod}", ""])
else:
    sys.exit("unknown shim style: " + style)
open(a_path, "w", encoding="utf-8").write(shim)
print(f"A is now a {len(shim.splitlines())}-line shim ({style}); "
      f"X has {len(src.splitlines())} lines")
PY

echo "### building the clone (the lake build a real move would pay)"
(cd "$CLONE" && "$LAKE" build 2>&1 | tail -5)
echo "### done"
