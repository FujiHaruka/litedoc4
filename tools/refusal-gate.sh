#!/usr/bin/env bash
# Does the binary still refuse a bad command line the way it always has?
#
# `tools/refusals.txt` holds one row per case: a name, the argv, the exit code
# and the whole of stderr. The rows were minted from the **Rust** `litedoc4`,
# which is the oracle for the Lean port and which M10 deletes together with
# `crates/`. Refusal behaviour is the one class that needs no oracle once its
# answer is written down, so it is written down here while there is still
# something to write it down from.
#
# **Two arms, and they are not the same claim.**
#
#   LEAN   the Lean `litedoc4` gives the frozen answer. This is the gate. It
#          reads `tools/refusals.txt` and nothing else, so it goes on being a
#          question after `crates/` is gone.
#   RUST   the frozen answer is still what the Rust binary says. This one
#          **expires at M10** — it is the check that the file did not rot while
#          the oracle was still around to ask. A missing Rust binary is
#          reported as a skip with the case count, never as a pass: `cargo
#          build --bin litedoc4` is all it takes while `crates/` exists.
#
# Both arms count how many cases reported a result and fail if that is not the
# number of rows in the file. A run that matched nothing and exited 0 is the
# shape this repository keeps being bitten by, and it is exactly the shape a
# gate driven by a data file can take.
#
# **The usage block is a row too.** Every exit-2 refusal ends with the whole of
# `--help-all`, so the frozen stderr says `<usage>` where that block goes and
# the block itself is stored once, under `@usage`. It is checked
# against the binary before the cases run — if it moved, the substitution would
# fail on every case at once and the output would say nothing about what broke.
#
# **One normaliser, used by both arms and by `--mint`.** A refusal that names a
# path names an absolute one, and the work directory differs per run and per
# machine; `normalise` replaces it (and its realpath — `/var` is a symlink on
# macOS and `/tmp` is one too) with `<dir>`. Two normalisers would let the two
# arms compare two different things.
#
# Scope: **command lines only**. Every case here is refused before anything on
# disk is read, apart from two that compare `--out` against `--root` and one
# that looks for a lakefile — those get an empty `root/` and `out/` in the work
# directory and nothing else. The second tranche, not here, is everything that
# needs a tree: a crafted IR, a ledger, a `litedoc4.toml`, an on-disk
# `--only-from` list. `impact --mode <nonsense>` belongs to that tranche and is
# deliberately not here: the mode is consulted only when there is something to
# select, so with no IR tree the run fails on the tree instead (see
# `Mode::Unrecognised`'s comment).
#
# Re-minting is `--mint`, and it takes the binary to mint from. **Mint from the
# Rust half.** After M10 there is nothing to mint from and minting from the Lean
# half would only record whatever it does today, which is the question, not the
# answer.
#
# usage: refusal-gate.sh [--lean PATH] [--rust PATH] [--out DIR] [--keep]
#        refusal-gate.sh --mint [--from PATH] [--out DIR] [--keep]
#   --lean  the Lean litedoc4 (default: .lake/build/bin/litedoc4, built with
#           tools/build-lean-exe.sh if it is not there)
#   --rust  the Rust litedoc4 (default: target/release, else target/debug;
#           absent is a skip)
#   --mint  rewrite tools/refusals.txt from --from
#   --from  the binary --mint reads (default: the same as --rust)
#   --out   working directory (default: a temporary one, removed on success)
#   --keep  do not remove a temporary --out
#
#   LAKE    the lake executable tools/build-lean-exe.sh uses (default: lake)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
EXPECT="$ROOT/tools/refusals.txt"
LEAN="${LEAN_LITEDOC4:-}"
RUST="${LITEDOC4:-}"
MINT=0
FROM=""
OUT=""
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --lean) LEAN="$2"; shift 2 ;;
    --rust) RUST="$2"; shift 2 ;;
    --mint) MINT=1; shift ;;
    --from) FROM="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '/^# usage:/,/^set -/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Every case runs with its cwd inside the work directory, so a binary named
# relatively on this command line would be looked for there.
absolute () {
  case "$1" in
    "" | /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}
LEAN="$(absolute "$LEAN")"
RUST="$(absolute "$RUST")"
FROM="$(absolute "$FROM")"

if [ -z "$RUST" ]; then
  if [ -x "$ROOT/target/release/litedoc4" ]; then
    RUST="$ROOT/target/release/litedoc4"
  elif [ -x "$ROOT/target/debug/litedoc4" ]; then
    RUST="$ROOT/target/debug/litedoc4"
  fi
fi

if [ "$MINT" -eq 1 ]; then
  [ -n "$FROM" ] || FROM="$RUST"
  if [ -z "$FROM" ] || [ ! -x "$FROM" ]; then
    echo "refusal-gate: --mint needs a binary to mint from (--from <path>, or cargo build --bin litedoc4)" >&2
    exit 2
  fi
else
  if [ -z "$LEAN" ]; then
    LEAN="$ROOT/.lake/build/bin/litedoc4"
    # Built rather than demanded: `tools/build-lean-exe.sh` is the one place
    # that knows how, and a gate that stopped here would be one more caller
    # spelling out `lake build litedoc4/litedoc4` in a workspace of its own.
    if [ ! -x "$LEAN" ]; then
      "$HERE/build-lean-exe.sh" --toolchain-from "$ROOT/e2e/micro" >/dev/null \
        || { echo "refusal-gate: no Lean litedoc4 and tools/build-lean-exe.sh failed — pass --lean <path>" >&2; exit 2; }
    fi
  fi
  [ -x "$LEAN" ] || { echo "refusal-gate: no Lean litedoc4 at $LEAN" >&2; exit 2; }
fi

[ -f "$EXPECT" ] || { echo "refusal-gate: no $EXPECT" >&2; exit 2; }

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d)"
  TEMPORARY=1
else
  mkdir -p "$OUT"
  TEMPORARY=0
fi

rc=0
python3 - "$EXPECT" "$OUT" "$MINT" "$LEAN" "$RUST" "$FROM" <<'PY' || rc=$?
import os
import pathlib
import shlex
import subprocess
import sys

expect_path = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
minting = sys.argv[3] == "1"
lean, rust, mint_from = sys.argv[4], sys.argv[5], sys.argv[6]

work = out / "cwd"
for name in ("root", "out"):
    (work / name).mkdir(parents=True, exist_ok=True)
# Both spellings: the child's cwd is the kernel's, which has resolved every
# symlink, while the string this process holds may still contain /var or /tmp.
WORK_PATHS = sorted({str(work.resolve()), str(work)}, key=len, reverse=True)

# EXTRACT_BIN and TARGET_REPO stand in for `--extractor-bin` and `--target`, so
# a machine that has them exported answers four cases differently from one that
# does not.
ENV = {k: v for k, v in os.environ.items() if k not in ("EXTRACT_BIN", "TARGET_REPO")}


def normalise(text, usage):
    if usage:
        text = text.replace(usage, "<usage>")
    for path in WORK_PATHS:
        text = text.replace(path, "<dir>")
    return text


def encode(text):
    lines = []
    for line in text.split("\n"):
        stripped = line.rstrip(" ")
        content = stripped + "\\s" * (len(line) - len(stripped))
        # A bare `|` for an empty line, rather than `| `: this file is the
        # expectation, and an editor or a hook that trims trailing whitespace
        # would otherwise rewrite it without anything saying so.
        lines.append("| " + content if content else "|")
    return lines


def decode(lines):
    out = []
    for line in lines:
        body = line[2:] if line.startswith("| ") else line[1:]
        spaces = 0
        while body.endswith("\\s"):
            body, spaces = body[:-2], spaces + 1
        out.append(body + " " * spaces)
    return "\n".join(out)


def parse(path):
    usage_lines = []
    cases = []
    current = None
    body = None
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if raw.startswith("|"):
            if body is None:
                sys.exit(f"refusal-gate: {path}:{number} is a body line outside any record")
            body.append(raw)
            continue
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line == "@usage":
            current, body = None, usage_lines
            continue
        if line.startswith("@case "):
            current = {"name": line[len("@case "):].strip(), "line": number}
            cases.append(current)
            body = current.setdefault("stderr", [])
            continue
        if current is None:
            sys.exit(f"refusal-gate: {path}:{number} is a field outside any @case: {raw!r}")
        key, _, value = line.partition(" ")
        if key not in ("argv", "exit"):
            sys.exit(f"refusal-gate: {path}:{number} names no field of a case: {raw!r}")
        current[key] = value
    for case in cases:
        for key in ("argv", "exit"):
            if key not in case:
                sys.exit(f"refusal-gate: the case `{case['name']}` has no `{key}` line")
        # A row that expects success is not a refusal, and one that got in here
        # would be a case this gate reports as having run while asking nothing.
        if case["exit"] == "0":
            sys.exit(f"refusal-gate: the case `{case['name']}` expects exit 0; this file is "
                     "refusals, and a command line that is accepted belongs elsewhere")
    names = [case["name"] for case in cases]
    if len(set(names)) != len(names):
        repeated = sorted({n for n in names if names.count(n) > 1})
        sys.exit(f"refusal-gate: {path} repeats a case name: {', '.join(repeated)}")
    return decode(usage_lines), cases


def run(binary, argv):
    result = subprocess.run(
        [binary] + argv,
        capture_output=True,
        text=True,
        cwd=str(work),
        env=ENV,
        check=False,
    )
    return result.returncode, result.stderr, result.stdout


def mint():
    usage = run(mint_from, ["--help-all"])[2]
    if not usage.strip():
        sys.exit("refusal-gate: --help-all printed nothing — there is no usage block to freeze")
    _, cases = parse(expect_path)
    text = expect_path.read_text(encoding="utf-8")
    head = text.split("\n@usage", 1)[0].rstrip("\n")
    parts = [head, "", "@usage"] + encode(usage) + [""]
    changed = 0
    for case in cases:
        argv = shlex.split(case["argv"])
        code, stderr, stdout = run(mint_from, argv)
        if stdout:
            sys.exit(f"refusal-gate: `{case['name']}` wrote {len(stdout)} byte(s) to stdout; "
                     "this file freezes stderr, so that case does not belong here")
        frozen = normalise(stderr, usage)
        if code == 0:
            sys.exit(f"refusal-gate: `{case['name']}` exited 0 — it is not a refusal")
        if decode(case["stderr"]) != frozen or case["exit"] != str(code):
            changed += 1
        parts += [f"@case {case['name']}", f"argv {case['argv']}", f"exit {code}"]
        parts += encode(frozen) + [""]
    expect_path.write_text("\n".join(parts).rstrip("\n") + "\n", encoding="utf-8")
    print(f"REFUSAL GATE: minted {len(cases)} case(s) from {mint_from}, {changed} changed")
    return 0


def arm(label, binary, usage, cases):
    problems = []
    said = run(binary, ["--help-all"])[2]
    if said != usage:
        first = next(
            (n for n, (a, b) in enumerate(zip(said.split("\n"), usage.split("\n")), 1) if a != b),
            min(len(said.split("\n")), len(usage.split("\n"))) + 1,
        )
        problems.append(
            f"{label} usage-block: `--help-all` differs from the frozen block at line {first}"
        )
    reported = []
    diffs = []
    for case in cases:
        code, stderr, stdout = run(binary, shlex.split(case["argv"]))
        got = normalise(stderr, usage)
        want = decode(case["stderr"])
        if str(code) != case["exit"]:
            problems.append(f"{label} {case['name']}: exit {code}, frozen {case['exit']}")
        elif got != want:
            got_lines, want_lines = got.split("\n"), want.split("\n")
            n = next(
                (i for i, (a, b) in enumerate(zip(got_lines, want_lines), 1) if a != b),
                min(len(got_lines), len(want_lines)) + 1,
            )
            frozen_line = want_lines[n - 1] if n <= len(want_lines) else "<no line>"
            got_line = got_lines[n - 1] if n <= len(got_lines) else "<no line>"
            # Windowed on the first differing character, not on the start of the
            # line: these messages are paragraphs, and a fixed prefix would
            # report two identical-looking strings for a difference 200
            # characters in.
            at = next(
                (i for i, (a, b) in enumerate(zip(frozen_line, got_line)) if a != b),
                min(len(frozen_line), len(got_line)),
            )
            start = max(0, at - 20)
            problems.append(
                f"{label} {case['name']}: stderr line {n} at character {at} — frozen "
                f"{frozen_line[start:at + 70]!r}, got {got_line[start:at + 70]!r}"
            )
            diffs.append(f"=== {case['name']}\n--- frozen\n{want}\n--- got\n{got}\n")
        if stdout:
            problems.append(f"{label} {case['name']}: wrote {len(stdout)} byte(s) to stdout")
        reported.append(case["name"])
    return reported, problems, diffs


if minting:
    sys.exit(mint())

usage, cases = parse(expect_path)
if not cases:
    sys.exit("refusal-gate: tools/refusals.txt holds no case — this gate would check nothing")
if not usage.strip():
    sys.exit("refusal-gate: tools/refusals.txt holds no @usage block")

# Counted off the raw text rather than off `cases`, which would be the parser
# grading its own reading. A row the parser silently declines to see — an
# indented `@case`, say — is a case the summary would otherwise report as
# checked because it was never there to check.
declared = sum(1 for line in expect_path.read_text(encoding="utf-8").splitlines()
               if line.startswith("@case "))

problems = []
counts = []

lean_reported, lean_problems, lean_diffs = arm("lean", lean, usage, cases)
problems += lean_problems
counts.append(("lean", lean_reported))
if lean_diffs:
    (out / "lean-diff.txt").write_text("\n".join(lean_diffs), encoding="utf-8")

# The arm that expires at M10. Absent is a skip **with the number it did not
# check** — a line that says nothing is how "green having checked nothing"
# reads to whoever runs this next.
if rust and os.access(rust, os.X_OK):
    rust_reported, rust_problems, rust_diffs = arm("rust", rust, usage, cases)
    problems += rust_problems
    counts.append(("rust", rust_reported))
    if rust_diffs:
        (out / "rust-diff.txt").write_text("\n".join(rust_diffs), encoding="utf-8")
else:
    print(f"REFUSAL GATE: the rust arm did not run — {declared} case(s) unchecked against the "
          "oracle. Expected once crates/ is gone; before that, cargo build --bin litedoc4")

for label, reported in counts:
    if len(reported) != declared:
        missing = sorted(set(case["name"] for case in cases) - set(reported))
        problems.insert(0, (
            f"{label} arm reported {len(reported)} result(s) for {declared} `@case` row(s)"
            + (f"; first unreported: {missing[0]}" if missing else
               " — the parser and the file disagree about how many rows there are")
        ))

shown = problems[:8]
for problem in shown:
    print(f"REFUSAL GATE FAIL  {problem}", file=sys.stderr)
if len(problems) > len(shown):
    print(f"REFUSAL GATE FAIL  and {len(problems) - len(shown)} more; the whole of every "
          f"difference is in {out}/<arm>-diff.txt", file=sys.stderr)
if problems:
    sys.exit(1)

print("REFUSAL GATE: "
      + ", ".join(f"{label} {len(reported)}/{declared}" for label, reported in counts)
      + f"; usage block {len(usage.splitlines())} line(s) each")
PY

if [ "$rc" -ne 0 ]; then
  echo "REFUSAL GATE: FAILED — see $OUT" >&2
  exit "$rc"
fi

# `if`, not `&&`: the last command of this script decides its exit code, and a
# `&&` whose left side is false returns 1 under a summary that says ok.
if [ "$TEMPORARY" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
  rm -rf "$OUT"
fi
echo "REFUSAL GATE: ok"
