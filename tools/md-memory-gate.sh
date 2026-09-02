#!/usr/bin/env bash
# Is the C that Lake links into every litedoc4 executable memory-safe over the
# corpus that was found by fuzzing it?
#
# The subject is two files and nothing else: `vendor/md4c/md4c.c`, the vendored
# parser, and `csrc/md_events.c`, the 350 lines of buffer arithmetic that
# flattens md4c's callbacks. Lake compiles both into `lean_exe litedoc4` and
# `lean_exe litedoc4-test`. `test/Litedoc4Test/MdParse.lean` already runs the
# same twelve shapes and asserts that control comes back; what it cannot see is
# a read or a write one byte outside a buffer, because nothing on that path is
# watching the allocations. This gate is the thing that watches them.
#
# WHY A STANDALONE HARNESS AND NOT THE LEAN TEST EXECUTABLE BUILT WITH THE FLAGS
#   The straightforward alternative is to push `-fsanitize=address` through
#   `leanc` and `compileO` and run `litedoc4-test`. It would be closer to
#   production, and it was rejected for one reason: LeakSanitizer would then be
#   looking at Lean's own allocator, whose arenas and interned objects are alive
#   at exit by design, so every leak report would have to be triaged against the
#   runtime rather than read. `csrc/memcheck/lean/lean.h` stands in for the four
#   runtime functions `md_events.c` calls, and with those in place the only
#   allocations in the process are md4c's, `md_events.c`'s and the harness's.
#   What would falsify the choice: a defect that needs Lean's allocator to
#   appear. `md_events.c` calls no other part of the runtime and holds no Lean
#   object across a call, so there is nowhere for one to sit.
#
# THIS IS NOT THE PRODUCT BUILD, AND WHAT IS LEFT OF THE DIFFERENCE IS DELIBERATE
#   Lake compiles this C with elan's own clang against `csrc/libc`'s shim
#   headers; this gate compiles it with the machine's `cc` against the real libc
#   headers, because AddressSanitizer needs a runtime elan's toolchain does not
#   ship. `LITEDOC4_SYSTEM_CC=1` is the tree's existing control arm for that swap
#   and `tools/libc-shim-gate.sh` is what holds the shim to the real headers, so
#   it is a compared quantity.
#
#   **The optimisation level is not a difference any more.** It is read out of
#   lakefile.lean's `ccFlags` below, so the gate compiles at whatever the product
#   compiles at and a change to one moves the other. It used to be a written-down
#   `-O1` against a product built with no `-O` at all, which is a level nothing
#   ships (measured 2026-09-02). `-O1` was not kept as a
#   second arm: every item here is a statement about the bytes Lake links in, and
#   a second level would answer about a neighbour of them.
#
# SIX ITEMS, AND FOUR OF THEM EXIST TO MAKE THE OTHER TWO MEAN SOMETHING
#   A sanitizer that reports nothing looks identical whether the subject is
#   clean or the instrumentation never reached it. That is not a hypothetical
#   here: the fuzzing this replaces spent its first run watching none of md4c,
#   because `-Zsanitizer=address` went through RUSTFLAGS and the C was compiled
#   beside it (coverage 1023 -> 2487 when CFLAGS was added, measured 2026-08-17).
#   So each of the two files gets a defect injected into a copy of itself, and
#   each injected defect is run twice: once with that file instrumented, once
#   with that one file built without the flag and everything else unchanged. The
#   pair is the evidence. If the second run also reported, the report would be
#   the runtime's or the harness's and would say nothing about the file named.
#
#     1  a volatile read past the input, injected into md4c.c         reports
#     2  the same copy, with md4c.c built without the flag            silent
#     3  a write past the event buffer, injected into md_events.c     reports
#     4  the same copy, with md_events.c built without the flag       silent
#     5  a buffer md_events.c allocates and never frees               reports
#     6  the committed corpus, against the tree's own C               quiet
#
#   The corpus is `fixtures/md/fuzz/`, unchanged: those twelve files are what
#   the retired fuzzing kept, and re-minting them from a fresh exploration would
#   replace the question with a different one.
#
# WHAT THIS DOES NOT ANSWER
#   Item 5 needs LeakSanitizer, which runs on Linux and not on Darwin. On a
#   platform without it the gate answers five of six and exits 2, because a
#   check that could not run has to be visible as not run. The whole gate exits
#   2 the same way when a program built with `-fsanitize=address` cannot reach
#   its own `main` on this platform at all -- that is a real state, not a
#   hypothetical, and reading a hang or a crash there as "no defect found" is
#   the shape this gate exists to refuse.
#
# THE RUN THAT ANSWERED ALL SIX, AND WHAT IT COST
#   `benchmarks/results/md-memory-gate-2026-09-02.txt` -- ubuntu-latest, gcc
#   13.3.0, 6 of 6 in 6.6 s for 8 compiles, 6 links and 6 runs. That file is also
#   where the evidence lives that items 2 and 4 are not decoration, and what the
#   first, wrong shape of item 1's injection was.
#
# usage: md-memory-gate.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
answer_required

CC="${CC:-cc}"
DECLARED=6
CORPUS_DIR="$ROOT/fixtures/md/fuzz"

PROBE_LIMIT="${MD_MEMORY_PROBE_LIMIT:-30}"
CANARY_LIMIT="${MD_MEMORY_CANARY_LIMIT:-120}"
CORPUS_LIMIT="${MD_MEMORY_CORPUS_LIMIT:-600}"

say () { printf '%s\n' "$*"; }

ran=0
failed=0

ok ()   { ran=$((ran + 1));                        say "  $1 of $DECLARED  ok    $2"; }
bad ()  { ran=$((ran + 1)); failed=$((failed + 1)); say "  $1 of $DECLARED  FAIL  $2"; }
gone () {                                           say "  $1 of $DECLARED  ----  $2"; }

command -v "$CC" >/dev/null 2>&1 || {
  say "md-memory-gate: no C compiler ($CC) -- this check has nothing to build with" >&2
  answer 2
}
command -v python3 >/dev/null 2>&1 || {
  say "md-memory-gate: no python3 -- the md4c flag word is read out of the Lean sources with it" >&2
  answer 2
}
[ -d "$CORPUS_DIR" ] || {
  say "md-memory-gate: $CORPUS_DIR is gone -- the corpus is the input, so there is nothing to run" >&2
  answer 2
}

WORK="$(mktemp -d)"
on_exit 'rm -rf "$WORK"'

# --------------------------------------------------------- optimisation level --
# Taken from lakefile.lean's `ccFlags`, not written down here, for the same
# reason the md4c flag word below is: a gate compiled at a level the product does
# not ship would be watching code nobody runs. It watched -O1 against a product
# built with no `-O` at all until this was read from the file (measured
# 2026-09-02), and writing the level down here again would only move the day the
# two drift.
#
# `-g` is not part of this and is added on top: it emits debug info and changes
# no code, and without it a report names no line.
PRODUCT_OPT="$(python3 - "$ROOT" <<'LAKEOPT'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
text = (root / "lakefile.lean").read_text(encoding="utf-8")

body = re.search(r"(?ms)^def ccFlags\b.*?(?=^(?:def |/--|@\[|end )|\Z)", text)
if not body:
    sys.exit(
        "md-memory-gate: lakefile.lean no longer defines ccFlags -- that function is "
        "what the product's C is compiled with, and this gate cannot guess the level"
    )
levels = re.findall(r'"(-O[^"]*)"', body.group(0))
if len(levels) > 1:
    sys.exit(
        "md-memory-gate: ccFlags names %d optimisation levels (%s) -- which one reaches "
        "md4c.c depends on a branch this gate does not read" % (len(levels), ", ".join(levels))
    )
sys.stdout.write(levels[0] if levels else "")
LAKEOPT
)" || answer 2

CFLAGS_COMMON=(-g -Werror=implicit-function-declaration
               -I "$ROOT/csrc/memcheck" -I "$ROOT/vendor/md4c")
[ -z "$PRODUCT_OPT" ] || CFLAGS_COMMON+=("$PRODUCT_OPT")
ASAN=(-fsanitize=address -fno-omit-frame-pointer)

compile () {  # compile <out.o> <src.c> asan|plain
  if [ "$3" = "asan" ]; then
    "$CC" "${CFLAGS_COMMON[@]}" "${ASAN[@]}" -c -o "$1" "$2"
  else
    "$CC" "${CFLAGS_COMMON[@]}" -c -o "$1" "$2"
  fi
}

link () {  # link <out> <obj>...
  local out="$1"
  shift
  "$CC" -g "${ASAN[@]}" -o "$out" "$@"
}

# A watchdog and not a `timeout`: macOS ships no `timeout`, and this gate has to
# be able to say "the sanitizer runtime never came up" on the machine where that
# actually happens rather than hang there.
run_bounded () {  # run_bounded <seconds> <log> <cmd>...
  local limit="$1" log="$2"
  shift 2
  "$@" >"$log" 2>&1 &
  local pid=$!
  ( sleep "$limit"; kill -9 "$pid" ) >/dev/null 2>&1 &
  local dog=$!
  local rc=0
  # stderr dropped on both waits: the shell announces a killed child as
  # `Killed: 9` on its own stderr, which would be the loudest line in the report
  # of a watchdog firing exactly as designed.
  wait "$pid" 2>/dev/null || rc=$?
  kill "$dog" >/dev/null 2>&1 || true
  wait "$dog" >/dev/null 2>&1 || true
  return "$rc"
}

excerpt () {
  sed -n '1,20p' "$1" | sed 's/^/      /'
}

# ---------------------------------------------------------------- flag word --
# Read out of the Lean sources rather than written down here. `docstringFlags`
# is what `src/Litedoc4/Md/Html.lean` hands `Md.parse` for every docstring on
# every page, and a gate that ran md4c in a different dialect would be watching
# code paths the product does not take.
FLAGS="$(python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
DEF = re.compile(r"^def ([A-Za-z_][A-Za-z0-9_']*) : UInt32 :=(.*)$")

def collect(path, into):
    lines = path.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines):
        m = DEF.match(line)
        if not m:
            continue
        name, rest = m.group(1), m.group(2)
        j = i + 1
        while not rest.strip() or rest.rstrip().endswith("|||"):
            if j >= len(lines):
                sys.exit("md-memory-gate: the definition of %s in %s does not end" % (name, path))
            rest = rest + " " + lines[j]
            j += 1
        into[name] = rest.strip()

exprs = {}
collect(root / "src/Litedoc4/Md.lean", exprs)
collect(root / "src/Litedoc4/Md/Html.lean", exprs)

if "docstringFlags" not in exprs:
    sys.exit(
        "md-memory-gate: src/Litedoc4/Md/Html.lean no longer defines docstringFlags "
        "as a UInt32 -- the dialect the product parses in has moved and this gate "
        "cannot guess it"
    )

def value(name, seen):
    if name in seen:
        sys.exit("md-memory-gate: %s is defined in terms of itself" % name)
    total = 0
    for token in exprs[name].split("|||"):
        token = token.strip()
        if re.fullmatch(r"0[xX][0-9A-Fa-f]+", token):
            total |= int(token, 16)
        elif token in exprs:
            total |= value(token, seen | {name})
        else:
            sys.exit(
                "md-memory-gate: cannot read %r in the definition of %s -- this gate "
                "understands hex literals and names joined by |||, nothing else"
                % (token, name)
            )
    return total

flags = value("docstringFlags", frozenset())
if flags == 0:
    sys.exit("md-memory-gate: docstringFlags came out 0, which no dialect is")
print(flags)
PY
)"

# ------------------------------------------------------------- injected copies --
python3 - "$ROOT" "$WORK" <<'PY'
import pathlib
import sys

root, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

# The md4c canary is a `volatile` load and not a longer input. Lengthening the
# input is the obvious way to make md4c read past the end and it does -- but
# md4c hands those bytes on to the text callback, `md_events.c` copies them out
# with `memcpy`, and a sanitizer intercepts `memcpy` in every translation unit
# including the ones built without the flag (measured 2026-09-02: the bytes come
# back inside the event stream). The report would then be the interceptor's and
# item 2 would be red with nothing wrong. A volatile load is checked only where
# the flag reached. What would falsify this: an injected access whose value
# never reaches a copy, which is what this one is.
INJECTIONS = [
    ("md4c", "vendor/md4c/md4c.c",
     "    MD_CTX ctx;\n    int i;\n    int ret;\n",
     "    MD_CTX ctx;\n    int i;\n    int ret;\n"
     "    volatile MD_CHAR litedoc4_canary = text[size + 1];\n"
     "    (void)litedoc4_canary;\n"),
    ("overwrite", "csrc/md_events.c",
     "    lean_obj_res out = lean_alloc_sarray(1, b.len, b.len);\n",
     "    lean_obj_res out = lean_alloc_sarray(1, b.len, b.len);\n"
     "    lean_sarray_cptr(out)[b.len] = 0;\n"),
    # `b.data = NULL;` and not just dropping the free: a pointer left in the
    # dead frame is what a conservative leak scanner reads back as reachable,
    # and the canary would then be green while leaking.
    ("leak", "csrc/md_events.c",
     "    free(b.data);\n    return out;\n",
     "    b.data = NULL;\n    return out;\n"),
]

for name, path, old, new in INJECTIONS:
    src = (root / path).read_text(encoding="utf-8")
    seen = src.count(old)
    if seen != 1:
        sys.exit(
            "md-memory-gate: the %s canary looks for a passage that appears %d times in "
            "%s, not once -- the file has moved and this gate would be compiling an "
            "unmodified copy and calling the sanitizer quiet\n  wanted: %r"
            % (name, seen, path, old)
        )
    (work / ("inj_" + name + ".c")).write_text(src.replace(old, new), encoding="utf-8")
PY

# --------------------------------------------------------------------- probe --
# Before any of it: can a program built with this flag reach its own main on
# this platform? On macOS 26 with the Command Line Tools' clang 17 runtime it
# cannot -- it spins in AddressSanitizer's own initializer -- and six hanging
# items would say nothing about the C.
cat > "$WORK/probe.c" <<'C'
int main(void) { return 0; }
C
"$CC" "${ASAN[@]}" -g -o "$WORK/probe" "$WORK/probe.c"
probe_rc=0
run_bounded "$PROBE_LIMIT" "$WORK/probe.log" "$WORK/probe" || probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
  say "MD MEMORY GATE: 0 of $DECLARED items answered"
  say
  if [ "$probe_rc" -eq 137 ]; then
    say "  A three-line program built with -fsanitize=address did not reach its own"
    say "  main within ${PROBE_LIMIT}s using $($CC --version | head -1)."
  else
    say "  A three-line program built with -fsanitize=address exited $probe_rc using"
    say "  $($CC --version | head -1)."
  fi
  excerpt "$WORK/probe.log"
  say
  say "  The AddressSanitizer runtime does not start on this platform, so nothing"
  say "  below would be watching the C. This is not a pass: the memory question is"
  say "  answered by the CI job on ubuntu-latest, which has a runtime that starts."
  answer 2
fi

# -------------------------------------------------------------------- builds --
compile "$WORK/harness.o"           "$ROOT/csrc/memcheck/harness.c" asan
compile "$WORK/md4c.o"              "$ROOT/vendor/md4c/md4c.c"      asan
compile "$WORK/md4c-canary.o"       "$WORK/inj_md4c.c"              asan
compile "$WORK/md4c-canary-blind.o" "$WORK/inj_md4c.c"              plain
compile "$WORK/ev.o"                 "$ROOT/csrc/md_events.c"       asan
compile "$WORK/ev-overwrite.o"       "$WORK/inj_overwrite.c"        asan
compile "$WORK/ev-overwrite-blind.o" "$WORK/inj_overwrite.c"        plain
compile "$WORK/ev-leak.o"            "$WORK/inj_leak.c"             asan

link "$WORK/bin-overread"        "$WORK/md4c-canary.o"       "$WORK/ev.o"                 "$WORK/harness.o"
link "$WORK/bin-overread-blind"  "$WORK/md4c-canary-blind.o" "$WORK/ev.o"                 "$WORK/harness.o"
link "$WORK/bin-overwrite"       "$WORK/md4c.o"              "$WORK/ev-overwrite.o"       "$WORK/harness.o"
link "$WORK/bin-overwrite-blind" "$WORK/md4c.o"              "$WORK/ev-overwrite-blind.o" "$WORK/harness.o"
link "$WORK/bin-leak"            "$WORK/md4c.o"              "$WORK/ev-leak.o"            "$WORK/harness.o"
link "$WORK/bin-real"            "$WORK/md4c.o"              "$WORK/ev.o"                 "$WORK/harness.o"

# One small, real corpus entry for the canaries. The 200 KB line is item 6's.
CANARY_INPUT="$CORPUS_DIR/entities.md"
[ -f "$CANARY_INPUT" ] || {
  say "md-memory-gate: $CANARY_INPUT is gone -- the canaries need one small real input" >&2
  answer 2
}

say "MD MEMORY GATE"
say "  compiler   $($CC --version | head -1)"
say "  flags      $(printf '0x%X' "$FLAGS") (docstringFlags, out of src/Litedoc4/Md/Html.lean)"
say

reported () {  # reported <log>
  grep -q "ERROR: AddressSanitizer" "$1" && grep -q "heap-buffer-overflow" "$1"
}

did_the_work () {  # did_the_work <log>
  grep -q "^harness: 1 file(s)" "$1"
}

# --- 1 ------------------------------------------------------------------------
rc=0
ASAN_OPTIONS=detect_leaks=0 run_bounded "$CANARY_LIMIT" "$WORK/1.log" \
  "$WORK/bin-overread" "$FLAGS" "$CANARY_INPUT" || rc=$?
if [ "$rc" -ne 0 ] && reported "$WORK/1.log"; then
  ok 1 "a read past the input, made inside md4c.c, is reported"
else
  bad 1 "a read past the input, made inside md4c.c, was NOT reported (exit $rc)"
  excerpt "$WORK/1.log"
fi

# --- 2 ------------------------------------------------------------------------
rc=0
ASAN_OPTIONS=detect_leaks=0 run_bounded "$CANARY_LIMIT" "$WORK/2.log" \
  "$WORK/bin-overread-blind" "$FLAGS" "$CANARY_INPUT" || rc=$?
if [ "$rc" -eq 0 ] && ! reported "$WORK/2.log" && did_the_work "$WORK/2.log"; then
  ok 2 "the same read is invisible with md4c.c built without the flag"
else
  bad 2 "with md4c.c built without the flag the same read was still reported, or the run did not happen (exit $rc)"
  excerpt "$WORK/2.log"
fi

# --- 3 ------------------------------------------------------------------------
rc=0
ASAN_OPTIONS=detect_leaks=0 run_bounded "$CANARY_LIMIT" "$WORK/3.log" \
  "$WORK/bin-overwrite" "$FLAGS" "$CANARY_INPUT" || rc=$?
if [ "$rc" -ne 0 ] && reported "$WORK/3.log"; then
  ok 3 "a write past the event buffer, made inside md_events.c, is reported"
else
  bad 3 "a write past the event buffer, made inside md_events.c, was NOT reported (exit $rc)"
  excerpt "$WORK/3.log"
fi

# --- 4 ------------------------------------------------------------------------
rc=0
ASAN_OPTIONS=detect_leaks=0 run_bounded "$CANARY_LIMIT" "$WORK/4.log" \
  "$WORK/bin-overwrite-blind" "$FLAGS" "$CANARY_INPUT" || rc=$?
if [ "$rc" -eq 0 ] && ! reported "$WORK/4.log" && did_the_work "$WORK/4.log"; then
  ok 4 "the same write is invisible with md_events.c built without the flag"
else
  bad 4 "with md_events.c built without the flag the same write was still reported, or the run did not happen (exit $rc)"
  excerpt "$WORK/4.log"
fi

# --- 5 ------------------------------------------------------------------------
# `uname` and not a probe: LeakSanitizer on a platform that does not have it is
# a message from the runtime on some builds and silence on others, and a gate
# that read silence as "no leaks" would be exactly the shape items 2 and 4 exist
# to refuse.
if [ "$(uname -s)" = "Linux" ]; then
  rc=0
  ASAN_OPTIONS=detect_leaks=1 run_bounded "$CANARY_LIMIT" "$WORK/5.log" \
    "$WORK/bin-leak" "$FLAGS" "$CANARY_INPUT" || rc=$?
  if [ "$rc" -ne 0 ] && grep -q "ERROR: LeakSanitizer: detected memory leaks" "$WORK/5.log"; then
    ok 5 "a buffer md_events.c never frees is reported"
  else
    bad 5 "a buffer md_events.c never frees was NOT reported (exit $rc)"
    excerpt "$WORK/5.log"
  fi
else
  gone 5 "a buffer md_events.c never frees -- not asked: LeakSanitizer does not run on $(uname -s)"
fi

# --- 6 ------------------------------------------------------------------------
CORPUS=()
while IFS= read -r entry; do
  CORPUS+=("$entry")
done < <(find "$CORPUS_DIR" -name '*.md' | sort)
if [ "${#CORPUS[@]}" -eq 0 ]; then
  say "md-memory-gate: $CORPUS_DIR holds no .md file -- item 6 would run nothing and say ok" >&2
  answer 2
fi

leaks_here=0
if [ "$(uname -s)" = "Linux" ]; then
  leaks_here=1
fi
rc=0
ASAN_OPTIONS="detect_leaks=$leaks_here" run_bounded "$CORPUS_LIMIT" "$WORK/6.log" \
  "$WORK/bin-real" "$FLAGS" "${CORPUS[@]}" || rc=$?
if [ "$rc" -eq 0 ] \
   && grep -q "^harness: ${#CORPUS[@]} file(s)" "$WORK/6.log" \
   && ! grep -q "ERROR: " "$WORK/6.log"; then
  if [ "$leaks_here" -eq 1 ]; then
    ok 6 "the ${#CORPUS[@]} committed corpus entries are quiet, leaks included"
  else
    ok 6 "the ${#CORPUS[@]} committed corpus entries are quiet, leaks not asked"
  fi
else
  bad 6 "the ${#CORPUS[@]} committed corpus entries are not quiet (exit $rc)"
  excerpt "$WORK/6.log"
fi

say
if [ "$failed" -ne 0 ]; then
  say "MD MEMORY GATE: $failed of $ran answered items failed" >&2
  answer 1
fi
if [ "$ran" -ne "$DECLARED" ]; then
  say "MD MEMORY GATE: $ran of $DECLARED items answered"
  say
  say "  The rest could not be asked on this platform. That is not a pass -- the CI"
  say "  job on ubuntu-latest is where all $DECLARED are answered."
  answer 2
fi
say "MD MEMORY GATE: ok ($ran of $DECLARED) -- the committed corpus, not an exploration:"
say "  new entries came from libFuzzer runs that left the tree with fuzz/ on 2026-09-02."
answer 0
