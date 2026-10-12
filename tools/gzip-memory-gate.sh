#!/usr/bin/env bash
# Is the gzip reader Lake links into every litedoc4 executable memory-safe over
# real, truncated and split gzip members?
#
# The subject is `csrc/gzip.c` and nothing else: the framing, the trailer
# verdict, and the reader that hands a store entry's files out of one member a
# piece at a time without ever holding all of it. `vendor/miniz/miniz.c` is
# built with the same flag because gzip.c calls into it, but it is not the
# subject. The reasons for a standalone harness and a stand-in `lean.h` are
# md-memory-gate.sh's and hold here unchanged (`csrc/memcheck/lean/lean.h`).
#
# FOUR ITEMS, AND TWO OF THEM EXIST TO MAKE THE OTHER TWO MEAN SOMETHING
#   A sanitizer that reports nothing looks the same whether the subject is clean
#   or the instrumentation never reached it, so a defect is injected into a copy
#   of gzip.c and run twice: once instrumented, once with only gzip.c built
#   without the flag. The pair is the evidence, as in md-memory-gate.sh.
#
#     1  a volatile read one past the input piece, injected into gzip.c   reports
#     2  the same copy, with gzip.c built without the flag                silent
#     3  a reader gzip.c allocates and its finalizer never frees          reports
#     4  the corpus, against the tree's own gzip.c                        quiet
#
# THE CORPUS
#   Built on every run: the two members Python's zlib wrote that
#   `test/Litedoc4Test/Gzip.lean` pins, read out of that file; members Python's
#   gzip module writes here over text, noise, both, nothing, and with a file
#   name in the header; every proper prefix of the two pinned members; and a
#   pinned member with each trailer field wrong and with a byte after it. The
#   harness reads each member whole, then cut in two at every byte (past 4096
#   bytes, the first and last 64 cuts and every 4093rd), asking in turn for a
#   line and for a fixed count, so that both ways the reader fills a piece and
#   every chunk boundary run under the sanitizer.
#
# WHAT THIS DOES NOT ANSWER
#   Item 3 needs LeakSanitizer, which runs on Linux and not on Darwin: elsewhere
#   the gate answers three of four and exits 2. The whole gate exits 2 the same
#   way where a program built with `-fsanitize=address` cannot reach its own
#   `main`, which is this development machine.
#
# usage: gzip-memory-gate.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
answer_required
# shellcheck source=lib/asan.sh
source "$HERE/lib/asan.sh" || exit 1

CC="${CC:-cc}"
DECLARED=4

PROBE_LIMIT="${GZIP_MEMORY_PROBE_LIMIT:-30}"
CANARY_LIMIT="${GZIP_MEMORY_CANARY_LIMIT:-120}"
CORPUS_LIMIT="${GZIP_MEMORY_CORPUS_LIMIT:-600}"

say () { printf '%s\n' "$*"; }

ran=0
failed=0

ok ()   { ran=$((ran + 1));                        say "  $1 of $DECLARED  ok    $2"; }
bad ()  { ran=$((ran + 1)); failed=$((failed + 1)); say "  $1 of $DECLARED  FAIL  $2"; }
gone () {                                           say "  $1 of $DECLARED  ----  $2"; }

command -v "$CC" >/dev/null 2>&1 || {
  say "gzip-memory-gate: no C compiler ($CC) -- this check has nothing to build with" >&2
  answer 2
}
command -v python3 >/dev/null 2>&1 || {
  say "gzip-memory-gate: no python3 -- the corpus and the flags are read with it" >&2
  answer 2
}

WORK="$(mktemp -d)"
on_exit 'rm -rf "$WORK"'

PRODUCT_OPT="$(asan_product_opt)" || answer 2

# `minizFlags` in lakefile.lean, for the reason asan_product_opt reads ccFlags:
# miniz.h declares a different API under different macros.
MINIZ_FLAGS=()
while IFS= read -r flag; do
  MINIZ_FLAGS+=("$flag")
done < <(python3 - "$ROOT" <<'MINIZ'
import pathlib
import re
import sys

text = (pathlib.Path(sys.argv[1]) / "lakefile.lean").read_text(encoding="utf-8")
body = re.search(r"(?ms)^def minizFlags\b.*?(?=^(?:def |/--|@\[|end |target )|\Z)", text)
if not body:
    sys.exit("gzip-memory-gate: lakefile.lean no longer defines minizFlags")
flags = re.findall(r'"(-D[^"]*)"', body.group(0))
if not flags:
    sys.exit("gzip-memory-gate: minizFlags names no -D macro, which is not what it was")
print("\n".join(flags))
MINIZ
)
[ "${#MINIZ_FLAGS[@]}" -gt 0 ] || answer 2

CFLAGS_COMMON=(-g -Werror=implicit-function-declaration
               -I "$ROOT/csrc/memcheck" -I "$ROOT/vendor/miniz" "${MINIZ_FLAGS[@]}")
[ -z "$PRODUCT_OPT" ] || CFLAGS_COMMON+=("$PRODUCT_OPT")

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

# ------------------------------------------------------------------- corpus --
mkdir -p "$WORK/corpus"
python3 - "$ROOT" "$WORK/corpus" <<'PY'
import gzip
import io
import pathlib
import random
import re
import sys

root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
source = (root / "test/Litedoc4Test/Gzip.lean").read_text(encoding="utf-8")

def pinned(name):
    m = re.search(r"(?ms)^def %s : ByteArray := ⟨#\[(.*?)\]⟩" % name, source)
    if not m:
        sys.exit(
            "gzip-memory-gate: test/Litedoc4Test/Gzip.lean no longer pins %s -- those "
            "bytes are the corpus's members nobody here wrote" % name
        )
    return bytes(int(t, 16) for t in re.findall(r"0x[0-9a-fA-F]{2}", m.group(1)))

members = {}
python = pinned("pythonMember")
every_field = pinned("pythonMemberWithEveryField")
members["pinned-plain"] = python
members["pinned-every-field"] = every_field

text = b"theorem foo (n : Nat) : n + 0 = n := rfl\n" * 9000
noise = bytes(random.Random(7).getrandbits(8) for _ in range(70000))
for label, data, level in [("empty", b"", 6), ("text", text, 6), ("text-fast", text, 1),
                           ("noise", noise, 6), ("noise-then-text", noise + text, 9)]:
    members["python-" + label] = gzip.compress(data, level, mtime=0)
named = io.BytesIO()
with gzip.GzipFile(filename="ir.json", mode="wb", fileobj=named, mtime=0) as f:
    f.write(text[:5000])
members["python-named"] = named.getvalue()

for label, m in [("plain", python), ("every-field", every_field)]:
    for cut in range(len(m)):
        members["prefix-%s-%03d" % (label, cut)] = m[:cut]

def le32(m, at, v):
    return m[:at] + (v & 0xffffffff).to_bytes(4, "little") + m[at + 4:]

n = len(python)
crc = int.from_bytes(python[n - 8:n - 4], "little")
size = int.from_bytes(python[n - 4:], "little")
members["wrong-crc"] = le32(python, n - 8, crc ^ 1)
members["length-one-short"] = le32(python, n - 4, size - 1)
members["length-one-long"] = le32(python, n - 4, size + 1)
members["byte-after"] = python + b"\0"
members["block-type-3"] = python[:10] + b"\x07" + python[n - 8:]

for i, (label, m) in enumerate(sorted(members.items())):
    (out / ("%03d-%s.gz" % (i, label))).write_bytes(m)
PY
CORPUS=()
while IFS= read -r entry; do
  CORPUS+=("$entry")
done < <(find "$WORK/corpus" -name '*.gz' | sort)
if [ "${#CORPUS[@]}" -eq 0 ]; then
  say "gzip-memory-gate: the corpus came out empty -- item 4 would run nothing and say ok" >&2
  answer 2
fi
CANARY_INPUT="$(find "$WORK/corpus" -name '*-pinned-plain.gz' | head -1)"
[ -n "$CANARY_INPUT" ] || answer 2

# ------------------------------------------------------------ injected copies --
python3 - "$ROOT" "$WORK" <<'PY'
import pathlib
import sys

root, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
src = (root / "csrc/gzip.c").read_text(encoding="utf-8")

INJECTIONS = [
    ("overread",
     "static void inflate_some(struct gz_member *m, const uint8_t *in, size_t len, size_t *pos) {\n",
     "static void inflate_some(struct gz_member *m, const uint8_t *in, size_t len, size_t *pos) {\n"
     "    if (len != 0) {\n"
     "        volatile uint8_t litedoc4_canary = in[len];\n"
     "        (void)litedoc4_canary;\n"
     "    }\n"),
    ("leak",
     "static void reader_finalize(void *m) { free(m); }\n",
     "static void reader_finalize(void *m) { (void)m; }\n"),
]

for name, old, new in INJECTIONS:
    seen = src.count(old)
    if seen != 1:
        sys.exit(
            "gzip-memory-gate: the %s canary looks for a passage that appears %d times in "
            "csrc/gzip.c, not once -- the file has moved and this gate would be compiling an "
            "unmodified copy and calling the sanitizer quiet\n  wanted: %r" % (name, seen, old)
        )
    (work / ("inj_" + name + ".c")).write_text(src.replace(old, new), encoding="utf-8")
PY

# --------------------------------------------------------------------- probe --
probe_rc=0
asan_probe "$WORK" "$PROBE_LIMIT" || probe_rc=$?
if [ "$probe_rc" -ne 0 ]; then
  asan_unstartable "GZIP MEMORY GATE" "$DECLARED" "$probe_rc" "$WORK" "$PROBE_LIMIT"
  answer 2
fi

# -------------------------------------------------------------------- builds --
compile "$WORK/harness.o"         "$ROOT/csrc/memcheck/gzip_harness.c" asan
compile "$WORK/miniz.o"           "$ROOT/vendor/miniz/miniz.c"         asan
compile "$WORK/gzip.o"            "$ROOT/csrc/gzip.c"                  asan
compile "$WORK/gzip-canary.o"     "$WORK/inj_overread.c"               asan
compile "$WORK/gzip-canary-blind.o" "$WORK/inj_overread.c"             plain
compile "$WORK/gzip-leak.o"       "$WORK/inj_leak.c"                   asan

link "$WORK/bin-overread"       "$WORK/gzip-canary.o"       "$WORK/miniz.o" "$WORK/harness.o"
link "$WORK/bin-overread-blind" "$WORK/gzip-canary-blind.o" "$WORK/miniz.o" "$WORK/harness.o"
link "$WORK/bin-leak"           "$WORK/gzip-leak.o"         "$WORK/miniz.o" "$WORK/harness.o"
link "$WORK/bin-real"           "$WORK/gzip.o"              "$WORK/miniz.o" "$WORK/harness.o"

say "GZIP MEMORY GATE"
say "  compiler   $($CC --version | head -1)"
say "  corpus     ${#CORPUS[@]} member(s), built by this run"
say

reported () {  # reported <log>
  grep -q "ERROR: AddressSanitizer" "$1" && grep -q "heap-buffer-overflow" "$1"
}

did_the_work () {  # did_the_work <log> <members>
  grep -q "^harness: $2 member(s), [0-9]* read(s), 0 unanswered" "$1"
}

# --- 1 ------------------------------------------------------------------------
rc=0
ASAN_OPTIONS=detect_leaks=0 run_bounded "$CANARY_LIMIT" "$WORK/1.log" \
  "$WORK/bin-overread" "$CANARY_INPUT" || rc=$?
if [ "$rc" -ne 0 ] && reported "$WORK/1.log"; then
  ok 1 "a read past the input piece, made inside gzip.c, is reported"
else
  bad 1 "a read past the input piece, made inside gzip.c, was NOT reported (exit $rc)"
  excerpt "$WORK/1.log"
fi

# --- 2 ------------------------------------------------------------------------
rc=0
ASAN_OPTIONS=detect_leaks=0 run_bounded "$CANARY_LIMIT" "$WORK/2.log" \
  "$WORK/bin-overread-blind" "$CANARY_INPUT" || rc=$?
if [ "$rc" -eq 0 ] && ! reported "$WORK/2.log" && did_the_work "$WORK/2.log" 1; then
  ok 2 "the same read is invisible with gzip.c built without the flag"
else
  bad 2 "with gzip.c built without the flag the same read was still reported, or the run did not happen (exit $rc)"
  excerpt "$WORK/2.log"
fi

# --- 3 ------------------------------------------------------------------------
# `uname` and not a probe, for md-memory-gate.sh's reason: LeakSanitizer where it
# does not run is a message on some builds and silence on others.
if [ "$(uname -s)" = "Linux" ]; then
  rc=0
  ASAN_OPTIONS=detect_leaks=1 run_bounded "$CANARY_LIMIT" "$WORK/3.log" \
    "$WORK/bin-leak" "$CANARY_INPUT" || rc=$?
  if [ "$rc" -ne 0 ] && grep -q "ERROR: LeakSanitizer: detected memory leaks" "$WORK/3.log"; then
    ok 3 "a reader gzip.c allocates and never frees is reported"
  else
    bad 3 "a reader gzip.c allocates and never frees was NOT reported (exit $rc)"
    excerpt "$WORK/3.log"
  fi
else
  gone 3 "a reader gzip.c allocates and never frees -- not asked: LeakSanitizer does not run on $(uname -s)"
fi

# --- 4 ------------------------------------------------------------------------
leaks_here=0
if [ "$(uname -s)" = "Linux" ]; then
  leaks_here=1
fi
rc=0
ASAN_OPTIONS="detect_leaks=$leaks_here" run_bounded "$CORPUS_LIMIT" "$WORK/4.log" \
  "$WORK/bin-real" "${CORPUS[@]}" || rc=$?
if [ "$rc" -eq 0 ] && did_the_work "$WORK/4.log" "${#CORPUS[@]}" && ! grep -q "ERROR: " "$WORK/4.log"; then
  reads="$(sed -n 's/^harness: [0-9]* member(s), \([0-9]*\) read(s).*/\1/p' "$WORK/4.log")"
  if [ "$leaks_here" -eq 1 ]; then
    ok 4 "the ${#CORPUS[@]} corpus members, $reads reads, are quiet, leaks included"
  else
    ok 4 "the ${#CORPUS[@]} corpus members, $reads reads, are quiet, leaks not asked"
  fi
else
  bad 4 "the ${#CORPUS[@]} corpus members are not quiet, or a read went unanswered (exit $rc)"
  excerpt "$WORK/4.log"
fi

say
if [ "$failed" -ne 0 ]; then
  say "GZIP MEMORY GATE: $failed of $ran answered items failed" >&2
  answer 1
fi
if [ "$ran" -ne "$DECLARED" ]; then
  say "GZIP MEMORY GATE: $ran of $DECLARED items answered"
  say
  say "  The rest could not be asked on this platform. That is not a pass -- the CI"
  say "  job on ubuntu-latest is where all $DECLARED are answered."
  answer 2
fi
say "GZIP MEMORY GATE: ok ($ran of $DECLARED)"
answer 0
