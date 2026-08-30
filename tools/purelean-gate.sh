#!/usr/bin/env bash
# Does the Lean half build and run from a consumer's workspace?
#
# `lean_exe litedoc4` is built from `src/` and linked against the C in
# `vendor/md4c` and `csrc/`. Nothing in `cargo test` sees any of it, and the
# development machine cannot run `lake` beside the root `lakefile.lean` (there is
# deliberately no `lean-toolchain` there), so the only honest way to build it is
# the way a consumer does: from `e2e/consumer`, through `require`.
#
# What a failing item means:
#   1 BUILDS    `lake build litedoc4/litedoc4` in e2e/consumer did not produce a
#               binary: the package does not build from a consumer's workspace.
#   2 VERSION   the Lean binary's `--version` and the Rust binary's differ byte
#               for byte: the two halves would answer the same question two ways.
#   3 LITERAL   `src/Litedoc4/Version.lean` and `Cargo.toml`'s workspace version
#               disagree: item 2 can only compare them, not tell which is stale.
#   4 CLANG     the C was compiled by something other than the toolchain's own
#               clang. The build is green either way — that is the point: a bare
#               `cc` builds here and fails on a consumer with no C toolchain.
#   5 NO LEAN   a module under `src/` imports `Lean`. An executable that does
#               measures 226 MB against 5.3 MB for one that stops at `Std`
#               (measured 2026-08-30 →
#               `benchmarks/results/purelean-ci-probe-2026-08-30.txt`), and a
#               consumer builds this on every checkout.
#
# Item 4 reads `lake build -v`, not the exit code: `LITEDOC4_SYSTEM_CC=1` builds
# with the machine's `cc` and succeeds on any machine that has one, so a green
# build proves nothing about which compiler ran.
#
# Everything written goes under $OUT or `<repo>/.lake/`.
#
# usage: purelean-gate.sh [--out DIR] [--keep]
#   --out   working directory (default: a temporary one, removed on success)
#   --keep  do not remove a temporary --out
#
#   LITEDOC4  the Rust `litedoc4` to compare --version against
#             (default: target/debug/litedoc4, else target/release/litedoc4)
#   LAKE      the lake executable (default: ~/.elan/bin/lake)
#   LEAN_CC   if set, the compiler item 4 expects instead of the toolchain's clang
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIXTURE="$ROOT/e2e/consumer"
LAKE="${LAKE:-$HOME/.elan/bin/lake}"
LEAN_EXE="$ROOT/.lake/build/bin/litedoc4"

if [ -z "${LITEDOC4:-}" ]; then
  if [ -x "$ROOT/target/debug/litedoc4" ]; then
    LITEDOC4="$ROOT/target/debug/litedoc4"
  else
    LITEDOC4="$ROOT/target/release/litedoc4"
  fi
fi

OUT=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '1,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# A hard exit rather than a skip: a missing input that prints and returns 0 does
# not reach the exit code, which is how a gate goes green with nothing to check.
[ -x "$LAKE" ] || { echo "no lake at $LAKE — set LAKE" >&2; exit 2; }
[ -x "$LITEDOC4" ] || { echo "no litedoc4 at $LITEDOC4 — cargo build --bin litedoc4, or set LITEDOC4" >&2; exit 2; }
[ -f "$ROOT/lakefile.lean" ] || { echo "no $ROOT/lakefile.lean — this gate has nothing to check" >&2; exit 2; }
[ -f "$FIXTURE/lakefile.toml" ] || { echo "no consumer fixture at $FIXTURE" >&2; exit 2; }
[ -f "$ROOT/src/Litedoc4/Main.lean" ] || { echo "no $ROOT/src/Litedoc4/Main.lean — there is no Lean half to build" >&2; exit 2; }

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d)"
  TEMPORARY=1
else
  mkdir -p "$OUT"
  TEMPORARY=0
fi

ITEMS=5
ran=0
failed=0

pass () { ran=$((ran + 1)); printf 'ITEM %s ok    %s\n' "$1" "$2"; }
fail () { ran=$((ran + 1)); failed=$((failed + 1)); printf 'ITEM %s FAIL  %s\n' "$1" "$2" >&2; }
say  () { printf '\n=== %s\n' "$1"; }

say "1/5 the Lean half builds from a consumer's workspace"
built=0
# `litedoc4/litedoc4` and not the bare name: the package and the executable share
# a name, and the qualified spelling is the one that cannot become ambiguous.
if (cd "$FIXTURE" && "$LAKE" build litedoc4/litedoc4) >"$OUT/build.log" 2>&1; then
  if [ -x "$LEAN_EXE" ]; then
    pass 1 "$LEAN_EXE ($(wc -c <"$LEAN_EXE" | tr -d ' ') bytes)"
    built=1
  else
    fail 1 "lake build litedoc4/litedoc4 exited 0 but there is no $LEAN_EXE"
  fi
else
  fail 1 "lake build litedoc4/litedoc4 failed in $FIXTURE — see $OUT/build.log"
  tail -20 "$OUT/build.log" >&2
fi

say "2/5 --version agrees with the Rust half, byte for byte"
if [ "$built" -eq 1 ]; then
  lean_rc=0
  "$LEAN_EXE" --version >"$OUT/lean-version.txt" 2>"$OUT/lean-version.err" || lean_rc=$?
  rust_rc=0
  "$LITEDOC4" --version >"$OUT/rust-version.txt" 2>"$OUT/rust-version.err" || rust_rc=$?
  if [ "$lean_rc" -ne 0 ] || [ "$rust_rc" -ne 0 ]; then
    fail 2 "--version exited non-zero (lean=$lean_rc rust=$rust_rc); see $OUT/lean-version.err and $OUT/rust-version.err"
  elif cmp -s "$OUT/lean-version.txt" "$OUT/rust-version.txt"; then
    pass 2 "both print $(tr -d '\n' <"$OUT/lean-version.txt")"
  else
    fail 2 "the Lean half prints [$(tr -d '\n' <"$OUT/lean-version.txt")] and $LITEDOC4 prints [$(tr -d '\n' <"$OUT/rust-version.txt")]"
  fi
else
  fail 2 "no Lean binary to run — item 1 did not build one"
fi

say "3/5 the version literal matches Cargo.toml"
literal_rc=0
python3 - "$ROOT" >"$OUT/literal.txt" 2>"$OUT/literal.err" <<'PY' || literal_rc=$?
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])

source = (root / "src/Litedoc4/Version.lean").read_text(encoding="utf-8")
found = re.search(r'^def\s+version\s*:\s*String\s*:=\s*"([^"]*)"', source, re.M)
if not found:
    sys.exit("src/Litedoc4/Version.lean declares no `def version : String := \"...\"`")
lean = found.group(1)

# Section-aware, for the reason `cargoWorkspaceVersion` in lakefile.lean is:
# `[workspace.dependencies]` is full of `version = "1"`.
cargo = None
section = None
for line in (root / "Cargo.toml").read_text(encoding="utf-8").splitlines():
    text = line.strip()
    if text.startswith("["):
        section = text
    elif section == "[workspace.package]" and text.startswith("version"):
        cargo = text.split('"')[1]
        break
if cargo is None:
    sys.exit("Cargo.toml has no [workspace.package] version to reconcile against")
if lean != cargo:
    sys.exit(f"src/Litedoc4/Version.lean says {lean} and Cargo.toml's workspace version is {cargo}")
print(lean)
PY
if [ "$literal_rc" -eq 0 ]; then
  pass 3 "both say $(tr -d '\n' <"$OUT/literal.txt")"
else
  fail 3 "$(tr -d '\n' <"$OUT/literal.err")"
fi

say "4/5 the C was compiled by the toolchain's own clang"
# Removed so the compile really runs. Lake **replays** an up-to-date target's log
# rather than staying silent, and its trace does not cover the compiler: with the
# objects in place, `LITEDOC4_SYSTEM_CC=1` rebuilds nothing and `-v` reprints the
# clang command from the previous build, so the gate would pass while the
# configuration under test compiles with `cc` (measured 2026-08-30). The parser
# below refuses a replayed line for the same reason.
rm -f "$ROOT/.lake/build/md4c.o" "$ROOT/.lake/build/md_events.o"
prefix_rc=0
(cd "$FIXTURE" && "$LAKE" env lean --print-prefix) >"$OUT/prefix.txt" 2>"$OUT/prefix.err" || prefix_rc=$?
if [ "$prefix_rc" -ne 0 ]; then
  fail 4 "lake env lean --print-prefix failed in $FIXTURE — the toolchain cannot be identified; see $OUT/prefix.err"
else
  PREFIX="$(tr -d '\n' <"$OUT/prefix.txt")"
  EXPECT_CC="${LEAN_CC:-$PREFIX/bin/clang}"
  if (cd "$FIXTURE" && "$LAKE" build -v litedoc4/md4cObj litedoc4/mdEventsObj) \
      >"$OUT/cc.log" 2>&1; then
    cc_rc=0
    python3 - "$OUT/cc.log" "$EXPECT_CC" >"$OUT/cc.txt" 2>"$OUT/cc.err" <<'PY' || cc_rc=$?
import pathlib
import sys

log = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
expected = sys.argv[2]

wanted = {"md4c.o", "md_events.o"}
replayed = sorted(
    target for target in ("litedoc4/md4cObj", "litedoc4/mdEventsObj")
    if f"Replayed {target}" in log
)
if replayed:
    sys.exit(
        f"lake replayed {', '.join(replayed)} instead of compiling — the command line "
        "below is the previous build's, not this configuration's"
    )

seen = {}
for line in log.splitlines():
    marker = ".> "
    if marker not in line:
        continue
    words = line.split(marker, 1)[1].split()
    if not words or "-c" not in words:
        continue
    output = words[words.index("-o") + 1] if "-o" in words else ""
    name = output.rsplit("/", 1)[-1]
    if name in wanted:
        seen[name] = words[0]

missing = sorted(wanted - set(seen))
if missing:
    sys.exit(
        f"lake build -v printed no compile command for {', '.join(missing)} — "
        "nothing was compiled, so nothing was checked"
    )
wrong = sorted(f"{name} by {cc}" for name, cc in seen.items() if cc != expected)
if wrong:
    sys.exit(f"compiled {'; '.join(wrong)}, wanted {expected}")
print(f"{len(seen)} object(s) by {expected}")
PY
    if [ "$cc_rc" -eq 0 ]; then
      pass 4 "$(tr -d '\n' <"$OUT/cc.txt")"
    else
      fail 4 "$(tr -d '\n' <"$OUT/cc.err")"
    fi
  else
    fail 4 "lake build -v of the C targets failed — see $OUT/cc.log"
    tail -20 "$OUT/cc.log" >&2
  fi
fi

say "5/5 nothing under src/ imports Lean"
lean_import_rc=0
python3 - "$ROOT" >"$OUT/imports.txt" 2>"$OUT/imports.err" <<'PY' || lean_import_rc=$?
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
sources = sorted((root / "src").rglob("*.lean"))
if not sources:
    sys.exit("no .lean under src/ — this item would check nothing")

IMPORT = re.compile(r"^\s*import\s+(?:all\s+)?Lean\b")
offenders = [
    f"{path.relative_to(root).as_posix()}:{n}"
    for path in sources
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
    if IMPORT.match(line)
]
if offenders:
    sys.exit("imports Lean: " + ", ".join(offenders))
print(f"{len(sources)} module(s)")
PY
if [ "$lean_import_rc" -eq 0 ]; then
  pass 5 "$(tr -d '\n' <"$OUT/imports.txt")"
else
  fail 5 "$(tr -d '\n' <"$OUT/imports.err")"
fi

say "summary"
printf 'items reported : %s of %s\n' "$ran" "$ITEMS"
printf 'failed         : %s\n' "$failed"
printf 'out            : %s\n' "$OUT"

if [ "$ran" -ne "$ITEMS" ]; then
  echo "PURELEAN GATE: FAILED — $ran of $ITEMS items reported a result; the rest never ran" >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "PURELEAN GATE: FAILED ($failed of $ITEMS)" >&2
  exit 1
fi

if [ "$TEMPORARY" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
  rm -rf "$OUT"
fi
echo
echo "PURELEAN GATE: ok"
