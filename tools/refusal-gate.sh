#!/usr/bin/env bash
# Does the binary still refuse a bad run the way it always has?
#
# `tools/refusals.txt` holds one row per case: a name, the argv, the exit code
# and the whole of stderr. The rows were minted from the **Rust** `litedoc4`,
# which is the oracle for the Lean port and which M10 deletes together with
# `crates/`. Refusal behaviour is the one class that needs no oracle once its
# answer is written down, so it is written down here while there is still
# something to write it down from.
#
# **Two files, one script.** `tools/refusals.txt` is every refusal made before
# anything on disk is read. `tools/refusals-on-disk.txt` is every refusal that
# needs something there, and each of its rows carries the fixture that puts it
# there. They are read by one script because "does the binary still refuse the
# same way" is one question: a second script would be a second normaliser, a
# second count reconciliation, and only one of the two would get fixed.
#
# **Two arms, and they are not the same claim.**
#
#   LEAN   the Lean `litedoc4` gives the frozen answer. This is the gate. It
#          reads the two data files and nothing else, so it goes on being a
#          question after `crates/` is gone.
#   RUST   the frozen answer is still what the Rust binary says. This one
#          **expires at M10** — it is the check that the files did not rot while
#          the oracle was still around to ask. A missing Rust binary is
#          reported as a skip with the case count, never as a pass: `cargo
#          build --bin litedoc4` is all it takes while `crates/` exists.
#
# Both arms count how many cases reported a result and fail if that is not the
# number of rows in the two files. A run that matched nothing and exited 0 is
# the shape this repository keeps being bitten by, and it is exactly the shape a
# gate driven by a data file can take.
#
# **The usage block is a row too.** Every exit-2 refusal ends with the whole of
# `--help-all`, so the frozen stderr says `<usage>` where that block goes and
# the block itself is stored once, under `@usage` in `tools/refusals.txt`. It is
# checked against the binary before the cases run — if it moved, the
# substitution would fail on every case at once and the output would say nothing
# about what broke. `tools/refusals-on-disk.txt` is refused an `@usage` of its
# own for the same reason two scripts are refused.
#
# **One normaliser, used by both arms and by `--mint`.** A refusal that names a
# path may name an absolute one, and the directory it is under differs per run
# and per machine; `normalise` replaces it (and its realpath — `/var` is a
# symlink on macOS and `/tmp` is one too) with `<dir>`. Two normalisers would
# let the two arms compare two different things.
#
# **Only stderr is frozen, and a row that prints first has to say so.** An
# entrance refusal writes nothing to stdout, so any byte there is news and the
# gate fails on it. A refusal that got as far as reading disk has usually
# reported progress already — `render` prints how the external links resolved
# before it opens the map — and such a row carries `stdout-not-frozen <why>`.
# Freezing that stdout instead was the obvious alternative and is not taken:
# `build`'s progress names the toolchain elan happens to have, so the number of
# lines is the machine's, and a frozen body that has to absorb that would be
# absorbing the stderr rows too. This holds while progress output stays
# environment-dependent; a run whose stdout is a fixed number of fixed lines
# could be frozen outright.
#
# **A fixture is rebuilt before every run of its case**, in a directory of its
# own, by both arms and by `--mint`. Sharing one directory would be cheaper by
# one `mkdir`, and it is not done because a case that writes into its own cwd —
# `build` does — would hand the second arm a tree the first arm left behind, and
# the two arms would then be answering different questions.
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
#   --mint  rewrite tools/refusals.txt and tools/refusals-on-disk.txt from --from
#   --from  the binary --mint reads (default: the same as --rust)
#   --out   working directory (default: a temporary one, removed on success)
#   --keep  do not remove a temporary --out
#
#   LAKE    the lake executable tools/build-lean-exe.sh uses (default: lake)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
EXPECT="$ROOT/tools/refusals.txt"
ON_DISK="$ROOT/tools/refusals-on-disk.txt"
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
[ -f "$ON_DISK" ] || { echo "refusal-gate: no $ON_DISK" >&2; exit 2; }

if [ -z "$OUT" ]; then
  OUT="$(mktemp -d)"
  TEMPORARY=1
else
  mkdir -p "$OUT"
  TEMPORARY=0
fi

rc=0
python3 - "$EXPECT" "$ON_DISK" "$OUT" "$MINT" "$LEAN" "$RUST" "$FROM" <<'PY' || rc=$?
import os
import pathlib
import shlex
import shutil
import subprocess
import sys

expect_path = pathlib.Path(sys.argv[1])
on_disk_path = pathlib.Path(sys.argv[2])
out = pathlib.Path(sys.argv[3])
minting = sys.argv[4] == "1"
lean, rust, mint_from = sys.argv[5], sys.argv[6], sys.argv[7]

work = out / "cwd"
for name in ("root", "out"):
    (work / name).mkdir(parents=True, exist_ok=True)
cases_root = out / "case"
cases_root.mkdir(parents=True, exist_ok=True)


def spellings(directory):
    # Both spellings: the child's cwd is the kernel's, which has resolved every
    # symlink, while the string this process holds may still contain /var or
    # /tmp.
    return {str(directory.resolve()), str(directory)}


WORK_PATHS = spellings(work)

# EXTRACT_BIN and TARGET_REPO stand in for `--extractor-bin` and `--target`, so
# a machine that has them exported answers four cases differently from one that
# does not.
ENV = {k: v for k, v in os.environ.items() if k not in ("EXTRACT_BIN", "TARGET_REPO")}

FIXTURE = ("dir", "file", "exec", "git")
DECLARATION = ("rust-differs", "stdout-not-frozen")
VARIES = "<varies>"


def normalise(text, usage, paths):
    if usage:
        text = text.replace(usage, "<usage>")
    for path in sorted(paths, key=len, reverse=True):
        text = text.replace(path, "<dir>")
    return text


def encode(text, marker="|"):
    lines = []
    for line in text.split("\n"):
        stripped = line.rstrip(" ")
        content = stripped + "\\s" * (len(line) - len(stripped))
        # A bare `|` for an empty line, rather than `| `: this file is the
        # expectation, and an editor or a hook that trims trailing whitespace
        # would otherwise rewrite it without anything saying so.
        lines.append(marker + " " + content if content else marker)
    return lines


def decode(lines, marker="|"):
    out = []
    for line in lines:
        body = line[2:] if line.startswith(marker + " ") else line[1:]
        spaces = 0
        while body.endswith("\\s"):
            body, spaces = body[:-2], spaces + 1
        out.append(body + " " * spaces)
    return "\n".join(out)


def line_matches(frozen, got):
    """`<varies>` in a frozen line matches any text, possibly empty, there."""
    if VARIES not in frozen:
        return frozen == got
    head, *rest = frozen.split(VARIES)
    tail = rest.pop()
    if not got.startswith(head) or not got.endswith(tail):
        return False
    at = len(head)
    stop = len(got) - len(tail)
    if stop < at:
        return False
    for segment in rest:
        found = got.find(segment, at, stop)
        if found < 0:
            return False
        at = found + len(segment)
    return True


def body_matches(frozen, got):
    frozen_lines, got_lines = frozen.split("\n"), got.split("\n")
    return len(frozen_lines) == len(got_lines) and all(
        line_matches(a, b) for a, b in zip(frozen_lines, got_lines)
    )


def relative(path, written_at):
    if not path or path.startswith("/") or ".." in pathlib.PurePosixPath(path).parts:
        sys.exit(f"refusal-gate: {written_at} names `{path}`, which is not a path inside the case "
                 "directory; a fixture that can reach outside it writes into the repository")
    return path


def parse(path, cases, names, usage_lines, fresh):
    current = None
    body = None
    file_body = None
    lead = []
    # Everything before the first record is the file's header, which `--mint`
    # copies over wholesale. So the first record's `lead` is dropped rather than
    # carried: carrying it would write the header's last comment block twice.
    started = False
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if raw.startswith("|"):
            if body is None:
                sys.exit(f"refusal-gate: {path}:{number} is a body line outside any record")
            body.append(raw)
            continue
        if raw.startswith(">"):
            if file_body is None:
                sys.exit(f"refusal-gate: {path}:{number} is a `>` line outside any `file`")
            file_body.append(raw)
            continue
        line = raw.strip()
        if not line or line.startswith("#"):
            lead.append(raw)
            continue
        if line == "@usage":
            if usage_lines is None:
                sys.exit(f"refusal-gate: {path}:{number} opens an @usage block; there is one "
                         "already, in tools/refusals.txt, and two would be two normalisers")
            current, body, file_body, lead, started = None, usage_lines, None, [], True
            continue
        if line.startswith("@case "):
            if not started:
                lead = []
            started = True
            while lead and not lead[0].strip():
                lead.pop(0)
            while lead and not lead[-1].strip():
                lead.pop()
            current = {
                "name": line[len("@case "):].strip(),
                "line": number,
                "path": path,
                "fresh": fresh,
                "lead": lead,
                "ops": [],
                "rust-differs": None,
                "stdout-not-frozen": None,
                "stderr": [],
            }
            cases.append(current)
            names.setdefault(current["name"], []).append(f"{path.name}:{number}")
            body, file_body, lead = current["stderr"], None, []
            continue
        if current is None:
            sys.exit(f"refusal-gate: {path}:{number} is a field outside any @case: {raw!r}")
        lead = []
        key, _, value = line.partition(" ")
        if key in ("argv", "exit"):
            current[key] = value
            file_body = None
            continue
        if key in FIXTURE or key in DECLARATION:
            if "argv" in current:
                sys.exit(f"refusal-gate: {path}:{number} writes `{key}` after `argv`; a fixture "
                         "is what the command line is run against, so it is written first")
            if not value:
                sys.exit(f"refusal-gate: {path}:{number} writes `{key}` with nothing after it"
                         + (" — the reason a row is let off is the whole point of letting it off"
                            if key in DECLARATION else ""))
            if key in DECLARATION:
                if current[key] is not None:
                    sys.exit(f"refusal-gate: {path}:{number} gives `{current['name']}` a second "
                             f"`{key}` reason")
                current[key] = value
            elif key != "git":
                relative(value, f"{path}:{number}'s `{key}`")
            op = {"kind": key, "value": value, "body": []}
            current["ops"].append(op)
            file_body = op["body"] if key == "file" else None
            continue
        sys.exit(f"refusal-gate: {path}:{number} names no field of a case: {raw!r}")
    for case in cases:
        if case["path"] != path:
            continue
        for key in ("argv", "exit"):
            if key not in case:
                sys.exit(f"refusal-gate: the case `{case['name']}` has no `{key}` line")
        # A row that expects success is not a refusal, and one that got in here
        # would be a case this gate reports as having run while asking nothing.
        if case["exit"] == "0":
            sys.exit(f"refusal-gate: the case `{case['name']}` expects exit 0; these files are "
                     "refusals, and a run that is accepted belongs elsewhere")
        if case["ops"] and not case["fresh"]:
            sys.exit(f"refusal-gate: the case `{case['name']}` carries a fixture, and "
                     f"{path.name} is the file for rows refused before anything on disk is read")


def read_both():
    usage_lines = []
    cases = []
    names = {}
    parse(expect_path, cases, names, usage_lines, fresh=False)
    parse(on_disk_path, cases, names, None, fresh=True)
    repeated = sorted(n for n, where in names.items() if len(where) > 1)
    if repeated:
        detail = "; ".join(f"{n} at {', '.join(names[n])}" for n in repeated)
        sys.exit(f"refusal-gate: a case name is used twice: {detail}")
    return decode(usage_lines), cases


def materialise(case):
    directory = cases_root / case["name"]
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    for op in case["ops"]:
        kind, value = op["kind"], op["value"]
        if kind == "dir":
            (directory / value).mkdir(parents=True, exist_ok=True)
        elif kind == "file":
            target = directory / value
            target.parent.mkdir(parents=True, exist_ok=True)
            text = decode(op["body"], ">")
            target.write_text(text + "\n" if op["body"] else "", encoding="utf-8")
        elif kind == "exec":
            target = directory / value
            if not target.is_file():
                sys.exit(f"refusal-gate: `{case['name']}`'s `exec {value}` names no file this "
                         "case wrote")
            target.chmod(target.stat().st_mode | 0o111)
        elif kind == "git":
            done = subprocess.run(["git"] + shlex.split(value), cwd=str(directory),
                                  capture_output=True, text=True, env=ENV, check=False)
            if done.returncode != 0:
                sys.exit(f"refusal-gate: `{case['name']}`'s `git {value}` failed: "
                         f"{done.stderr.strip() or done.stdout.strip()}")
    return directory


def where(case):
    return materialise(case) if case["fresh"] else work


def run(binary, argv, cwd):
    result = subprocess.run(
        [binary] + argv,
        capture_output=True,
        text=True,
        cwd=str(cwd),
        env=ENV,
        check=False,
    )
    return result.returncode, result.stderr, result.stdout


def header_of(text):
    kept = []
    for line in text.split("\n"):
        if line.startswith("@"):
            break
        kept.append(line)
    return "\n".join(kept).rstrip("\n")


def minted_body(case, got):
    frozen = decode(case["stderr"]).split("\n") if case["stderr"] else []
    fresh = got.split("\n")
    if not any(VARIES in line for line in frozen):
        return fresh
    if len(frozen) != len(fresh):
        sys.exit(f"refusal-gate: `{case['name']}` holds {VARIES} and the binary now says "
                 f"{len(fresh)} line(s) where the frozen body has {len(frozen)}; a wildcard "
                 "cannot be carried across a body that changed shape — read the row by hand")
    kept = []
    for number, (old, new) in enumerate(zip(frozen, fresh), 1):
        if VARIES not in old:
            kept.append(new)
        elif line_matches(old, new):
            kept.append(old)
        else:
            sys.exit(f"refusal-gate: `{case['name']}` line {number}: the text around {VARIES} "
                     f"moved — frozen {old!r}, got {new!r}. {VARIES} is written by hand and "
                     "mint will not replace a wildcard with today's text")
    return kept


def emit(case, exit_code, body_lines):
    lines = list(case["lead"])
    lines.append(f"@case {case['name']}")
    for op in case["ops"]:
        lines.append(f"{op['kind']} {op['value']}")
        lines += op["body"]
    lines += [f"argv {case['argv']}", f"exit {exit_code}"]
    return lines + body_lines + [""]


def mint():
    usage = run(mint_from, ["--help-all"], work)[2]
    if not usage.strip():
        sys.exit("refusal-gate: --help-all printed nothing — there is no usage block to freeze")
    _, cases = read_both()
    changed = 0
    left = []
    for path in (expect_path, on_disk_path):
        head = header_of(path.read_text(encoding="utf-8"))
        parts = [head, ""]
        if path == expect_path:
            parts += ["@usage"] + encode(usage) + [""]
        for case in (c for c in cases if c["path"] == path):
            # Minted from Rust, and these rows are the ones Rust words
            # differently: overwriting them would replace the answer the Lean
            # arm is checking with the answer nobody is checking.
            if case["rust-differs"]:
                left.append(case["name"])
                parts += emit(case, case["exit"], case["stderr"])
                continue
            cwd = where(case)
            code, stderr, stdout = run(mint_from, shlex.split(case["argv"]), cwd)
            if stdout and not case["stdout-not-frozen"]:
                sys.exit(f"refusal-gate: `{case['name']}` wrote {len(stdout)} byte(s) to stdout; "
                         "these files freeze stderr, so a row that prints before it refuses has "
                         "to say so with `stdout-not-frozen <why>`")
            if code == 0:
                sys.exit(f"refusal-gate: `{case['name']}` exited 0 — it is not a refusal")
            frozen = normalise(stderr, usage, spellings(cwd) | WORK_PATHS)
            body = minted_body(case, frozen)
            if not body_matches(decode(case["stderr"]), "\n".join(body)) \
                    or case["exit"] != str(code):
                changed += 1
            parts += emit(case, code, encode("\n".join(body)))
        path.write_text("\n".join(parts).rstrip("\n") + "\n", encoding="utf-8")
    print(f"REFUSAL GATE: minted {len(cases) - len(left)} case(s) from {mint_from}, "
          f"{changed} changed; {len(left)} left to the lean arm"
          + (f" (rust-differs: {', '.join(left)})" if left else ""))
    return 0


def arm(label, binary, usage, cases, skip_differs):
    problems = []
    said = run(binary, ["--help-all"], work)[2]
    if said != usage:
        first = next(
            (n for n, (a, b) in enumerate(zip(said.split("\n"), usage.split("\n")), 1) if a != b),
            min(len(said.split("\n")), len(usage.split("\n"))) + 1,
        )
        problems.append(
            f"{label} usage-block: `--help-all` differs from the frozen block at line {first}"
        )
    reported = []
    skipped = []
    diffs = []
    for case in cases:
        if skip_differs and case["rust-differs"]:
            skipped.append(case["name"])
            continue
        cwd = where(case)
        code, stderr, stdout = run(binary, shlex.split(case["argv"]), cwd)
        got = normalise(stderr, usage, spellings(cwd) | WORK_PATHS)
        want = decode(case["stderr"])
        if str(code) != case["exit"]:
            problems.append(f"{label} {case['name']}: exit {code}, frozen {case['exit']}")
        elif not body_matches(want, got):
            got_lines, want_lines = got.split("\n"), want.split("\n")
            n = next(
                (i for i, (a, b) in enumerate(zip(got_lines, want_lines), 1)
                 if not line_matches(b, a)),
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
        if stdout and not case["stdout-not-frozen"]:
            problems.append(f"{label} {case['name']}: wrote {len(stdout)} byte(s) to stdout")
        reported.append(case["name"])
    return reported, skipped, problems, diffs


if minting:
    sys.exit(mint())

usage, cases = read_both()
if not cases:
    sys.exit("refusal-gate: the two data files hold no case — this gate would check nothing")
if not usage.strip():
    sys.exit("refusal-gate: tools/refusals.txt holds no @usage block")

# Counted off the raw text rather than off `cases`, which would be the parser
# grading its own reading. A row the parser silently declines to see — an
# indented `@case`, say — is a case the summary would otherwise report as
# checked because it was never there to check.
declared = sum(
    1
    for path in (expect_path, on_disk_path)
    for line in path.read_text(encoding="utf-8").splitlines()
    if line.startswith("@case ")
)

problems = []
counts = []

lean_reported, lean_skipped, lean_problems, lean_diffs = arm(
    "lean", lean, usage, cases, skip_differs=False)
problems += lean_problems
counts.append(("lean", lean_reported, lean_skipped))
if lean_diffs:
    (out / "lean-diff.txt").write_text("\n".join(lean_diffs), encoding="utf-8")

# The arm that expires at M10. Absent is a skip **with the number it did not
# check** — a line that says nothing is how "green having checked nothing"
# reads to whoever runs this next.
if rust and os.access(rust, os.X_OK):
    rust_reported, rust_skipped, rust_problems, rust_diffs = arm(
        "rust", rust, usage, cases, skip_differs=True)
    problems += rust_problems
    counts.append(("rust", rust_reported, rust_skipped))
    if rust_diffs:
        (out / "rust-diff.txt").write_text("\n".join(rust_diffs), encoding="utf-8")
else:
    print(f"REFUSAL GATE: the rust arm did not run — {declared} case(s) unchecked against the "
          "oracle. Expected once crates/ is gone; before that, cargo build --bin litedoc4")

for label, reported, skipped in counts:
    if len(reported) + len(skipped) != declared:
        missing = sorted(set(case["name"] for case in cases) - set(reported) - set(skipped))
        problems.insert(0, (
            f"{label} arm reported {len(reported)} result(s) and skipped {len(skipped)} for "
            f"{declared} `@case` row(s)"
            + (f"; first unaccounted: {missing[0]}" if missing else
               " — the parser and the files disagree about how many rows there are")
        ))

shown = problems[:8]
for problem in shown:
    print(f"REFUSAL GATE FAIL  {problem}", file=sys.stderr)
if len(problems) > len(shown):
    print(f"REFUSAL GATE FAIL  and {len(problems) - len(shown)} more; the whole of every "
          f"difference is in {out}/<arm>-diff.txt", file=sys.stderr)
if problems:
    sys.exit(1)

printing = sum(1 for case in cases if case["stdout-not-frozen"])
print("REFUSAL GATE: "
      + ", ".join(
          f"{label} {len(reported)}/{declared}"
          + (f" ({len(skipped)} differ by design: {', '.join(sorted(skipped))})" if skipped else "")
          for label, reported, skipped in counts)
      + f"; usage block {len(usage.splitlines())} line(s) each"
      + (f"; {printing} row(s) print before refusing and freeze stderr only" if printing else ""))
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
