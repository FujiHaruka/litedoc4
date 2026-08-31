#!/usr/bin/env bash
# Is every flag the command line *documents* a flag some parser *accepts*?
#
# `tools/public-surface-gate.sh` reads each half's synopsis and says which
# promised name went missing. On the Rust side that reading means something
# stronger than a string search, because `every_documented_flag_is_parsed` in
# `crates/litedoc4/src/lib.rs` ties `USAGE` to the `match` arms; on the Lean side
# nothing ties them, so a flag reachable there is only a flag the help text
# spells. M10 deletes `crates/`, and with it the only tie either half has. This
# gate is that tie, rebuilt out of the one oracle that survives: the binary's own
# answer to being handed the flag.
#
# THE METHOD
#   For each `(command, flag)` the usage names, run `litedoc4 <command> <flag>`
#   and read stderr. The run is *expected* to fail — a missing value, a missing
#   --root, an --ir that is not there — and that is the point: every outcome
#   except `unknown argument` is a parser that knows the flag. Nothing has to be
#   set up, nothing is compared against a frozen answer, and no second
#   implementation is needed to say what the right answer was.
#
# THREE OUTCOMES, AND ONLY ONE OF THEM IS A FAILURE
#   unknown          `litedoc4: unknown argument `--x`` — no parser of that
#                    command has ever heard of the flag. The usage documents a
#                    flag that does nothing. This is the failure.
#   refused by name  `--x is not a flag of `ledger touch`: it belongs to …`, and
#                    `--x is not a flag here: it is always on`. The parser names
#                    the flag and says where it belongs, so it demonstrably knows
#                    it — which is the whole of what this gate asks. Counted and
#                    printed separately, never as a failure: whether the synopsis
#                    should have listed it under that command is
#                    `tools/public-surface-gate.sh`'s question and
#                    `tools/refusals.txt`'s, not this one.
#   accepted         anything else. The flag got past the parser.
#
# THE CONTROL, BECAUSE THE DETECTOR IS A STRING MATCH
#   "not `unknown argument`" passes for every pair the moment that wording moves
#   — the gate would go green having checked nothing, which is the shape this
#   repository keeps being bitten by. So each command is also handed a flag that
#   exists nowhere, and the answer *must* be the unknown-argument shape. A
#   command whose control does not fire is reported as a broken detector rather
#   than as a clean run.
#
# TWO ARMS, AND THEY ARE NOT THE SAME CLAIM
#   LEAN   the gate. It reads `--help-all` and the binary, so it goes on being a
#          question after `crates/` is gone.
#   RUST   the same inventory against the oracle, while there still is one. A
#          missing Rust binary is a skip carrying the count it did not check,
#          never a pass: `cargo build --release --bin litedoc4` is all it takes
#          while `crates/` exists.
#
# usage: flag-tie-gate.sh [--lean PATH] [--rust PATH]
#   --lean  the Lean litedoc4 (default: .lake/build/bin/litedoc4, built with
#           tools/build-lean-exe.sh if it is not there)
#   --rust  the Rust litedoc4 (default: target/release, else target/debug;
#           absent is a skip)
#
#   LAKE    the lake executable tools/build-lean-exe.sh uses (default: lake)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh" || exit 1

LEAN="${LEAN_LITEDOC4:-}"
RUST="${LITEDOC4:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --lean) LEAN="$2"; shift 2 ;;
    --rust) RUST="$2"; shift 2 ;;
    -h|--help) sed -n '/^# usage:/,/^set -/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Every case runs with its cwd in a scratch directory, so a binary named
# relatively on this command line would be looked for there.
absolute () {
  case "$1" in
    "" | /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}
LEAN="$(absolute "$LEAN")"
RUST="$(absolute "$RUST")"

if [ -z "$RUST" ]; then
  if [ -x "$ROOT/target/release/litedoc4" ]; then
    RUST="$ROOT/target/release/litedoc4"
  elif [ -x "$ROOT/target/debug/litedoc4" ]; then
    RUST="$ROOT/target/debug/litedoc4"
  fi
fi

if [ -z "$LEAN" ]; then
  LEAN="$ROOT/.lake/build/bin/litedoc4"
  # Built rather than demanded: tools/build-lean-exe.sh is the one place that
  # knows how, and a gate that stopped here would be one more caller spelling out
  # `lake build litedoc4/litedoc4` in a workspace of its own.
  if [ ! -x "$LEAN" ]; then
    "$HERE/build-lean-exe.sh" --toolchain-from "$ROOT/e2e/micro" >/dev/null \
      || { echo "flag-tie-gate: no Lean litedoc4 and tools/build-lean-exe.sh failed — pass --lean <path>" >&2; exit 2; }
  fi
fi
[ -x "$LEAN" ] || { echo "flag-tie-gate: no Lean litedoc4 at $LEAN" >&2; exit 2; }

WORK="$(mktemp -d)"
on_exit 'rm -rf "$WORK"'

rc=0
python3 - "$WORK" "$LEAN" "$RUST" <<'PY' || rc=$?
import os
import re
import subprocess
import sys

work, lean, rust = sys.argv[1], sys.argv[2], sys.argv[3]

# A flag no synopsis names and no parser can have: handed to every command to
# prove the unknown-argument detector below still fires.
CONTROL = "--flag-tie-gate-control"

# EXTRACT_BIN and TARGET_REPO stand in for --extractor-bin and --target, so a
# machine that has them exported answers differently from one that does not.
ENV = {k: v for k, v in os.environ.items() if k not in ("EXTRACT_BIN", "TARGET_REPO")}


def run(binary, argv):
    result = subprocess.run(
        [binary] + argv,
        capture_output=True,
        text=True,
        cwd=work,
        env=ENV,
        check=False,
        timeout=60,
    )
    return result.returncode, result.stderr, result.stdout


def help_all(binary, label):
    code, _, text = run(binary, ["--help-all"])
    if code != 0 or not text.strip():
        sys.exit(f"flag-tie-gate: {label} `--help-all` exited {code} with "
                 f"{len(text)} byte(s) of output — there is no inventory to take")
    return text


def inventory(usage):
    """Every (command, flag) the synopsis block pairs, and every flag the
    description block explains.

    The synopsis is the only part that says which command a flag belongs to. The
    description block is read too, but only to check that nothing is explained
    there and named in no synopsis line — a flag documented in prose alone is one
    this gate would otherwise leave unasked while reporting a full count.
    """
    pairs = []
    commands = []
    described = set()
    command = None
    in_synopsis = False
    for raw in usage.split("\n"):
        if not in_synopsis and raw.startswith("usage:"):
            in_synopsis = True
        if not in_synopsis:
            head = re.match(r"^ {2}(--[A-Za-z0-9-]+)", raw)
            if head:
                described.add(head.group(1))
            continue
        if not raw.strip():
            in_synopsis = False
            continue
        named = re.match(r"^(?:usage:)?\s*litedoc4 (.*)$", raw)
        if named:
            rest = named.group(1)
            words = []
            for word in rest.split():
                if word.startswith(("-", "[", "(", "<", "|")):
                    break
                words.append(word)
            command = " ".join(words)
            if command and command not in commands:
                commands.append(command)
            tail = rest
        else:
            tail = raw
        for word in tail.split():
            word = word.strip("[]()|,.")
            if word.startswith("--") and (command, word) not in pairs:
                pairs.append((command, word))
    return pairs, commands, described


def classify(flag, stderr):
    if f"unknown argument `{flag}`" in stderr:
        return "unknown"
    if f"{flag} is not a flag" in stderr:
        return "by-name"
    return "accepted"


def arm(label, binary, pairs, commands):
    problems = []
    reported = []
    by_name = []
    controls = 0
    for command in commands:
        _, stderr, _ = run(binary, command.split() + [CONTROL])
        if classify(CONTROL, stderr) == "unknown":
            controls += 1
        else:
            problems.append(
                f"{label} `{command}`: a flag that exists nowhere was not refused as "
                f"`unknown argument` — this arm cannot detect one, so its {len(pairs)} "
                "pair(s) prove nothing"
            )
    for command, flag in pairs:
        _, stderr, _ = run(binary, command.split() + [flag])
        verdict = classify(flag, stderr)
        if verdict == "unknown":
            problems.append(
                f"{label} `{command} {flag}`: the usage documents it and the parser "
                "refuses it as `unknown argument`"
            )
        elif verdict == "by-name":
            by_name.append(f"{command} {flag}")
        reported.append((command, flag))
    return reported, by_name, controls, problems


usage = help_all(lean, "lean")
pairs, commands, described = inventory(usage)

problems = []
if not pairs:
    sys.exit("flag-tie-gate: the synopsis in `--help-all` names no flag — this gate "
             "would check nothing")
if not commands:
    sys.exit("flag-tie-gate: the synopsis in `--help-all` names no command — this gate "
             "would check nothing")

# The parser grading its own reading, otherwise: a command line whose flags this
# reading silently drops is a command reported as covered while nothing under it
# was asked.
paired = {command for command, _ in pairs}
for command in [c for c in commands if c not in paired]:
    problems.append(f"`litedoc4 {command}` is a synopsis line this reading took no flag "
                    "from — every command has at least one")

flags = {flag for _, flag in pairs}
for flag in sorted(described - flags):
    problems.append(f"{flag} is described in `--help-all` and named in no synopsis line, "
                    "so it cannot be paired with a command and goes unasked")

counts = []
lean_reported, lean_by_name, lean_controls, lean_problems = arm("lean", lean, pairs, commands)
problems += lean_problems
counts.append(("lean", lean_reported, lean_by_name, lean_controls))

# The arm that expires at M10. Absent is a skip **with the number it did not
# check** — a line that says nothing is how "green having checked nothing" reads
# to whoever runs this next.
if rust and os.access(rust, os.X_OK):
    rust_reported, rust_by_name, rust_controls, rust_problems = arm("rust", rust, pairs, commands)
    problems += rust_problems
    counts.append(("rust", rust_reported, rust_by_name, rust_controls))
else:
    print(f"FLAG TIE GATE: the rust arm did not run — {len(pairs)} pair(s) unchecked "
          "against the oracle. Expected once crates/ is gone; before that, "
          "cargo build --release --bin litedoc4")

for label, reported, _, controls in counts:
    if len(reported) != len(pairs):
        problems.insert(0, f"{label} arm reported {len(reported)} result(s) for "
                            f"{len(pairs)} pair(s) taken from the usage")
    if controls != len(commands):
        problems.insert(0, f"{label} arm's control fired for {controls} of "
                            f"{len(commands)} command(s)")

shown = problems[:8]
for problem in shown:
    print(f"FLAG TIE GATE FAIL  {problem}", file=sys.stderr)
if len(problems) > len(shown):
    print(f"FLAG TIE GATE FAIL  and {len(problems) - len(shown)} more", file=sys.stderr)
if problems:
    sys.exit(1)

for label, _, by_name, _ in counts:
    for case in by_name:
        print(f"FLAG TIE GATE: {label} `{case}` is refused by name rather than accepted — "
              "the parser knows the flag, so this is not a failure here")

print("FLAG TIE GATE: "
      + ", ".join(f"{label} {len(reported)}/{len(pairs)} pair(s), {controls} control(s)"
                  for label, reported, _, controls in counts)
      + f"; {len(commands)} command(s), {len(flags)} distinct flag(s), "
      + f"{len(described)} described")
PY

if [ "$rc" -ne 0 ]; then
  echo "FLAG TIE GATE: FAILED" >&2
  exit "$rc"
fi

echo "FLAG TIE GATE: ok"
