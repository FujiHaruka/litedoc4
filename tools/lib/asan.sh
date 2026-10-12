#!/usr/bin/env bash
# What the gates that build this tree's C with AddressSanitizer share:
# tools/md-memory-gate.sh and tools/gzip-memory-gate.sh. Source it after
# tools/lib/common.sh, with ROOT and CC set — and **always with `|| exit 1`**
# (tools/lib/target.sh carries the reason).

ASAN=(-fsanitize=address -fno-omit-frame-pointer)

# The level lakefile.lean's `ccFlags` compiles the product's C at, or nothing
# when it names none. Read from the file rather than written down in a gate: a
# gate compiled at a level the product does not ship would be watching code
# nobody runs. md-memory-gate.sh watched -O1 against a product built with no
# `-O` at all until this was read from the file (measured 2026-09-02 ->
# benchmarks/results/md-memory-opt-2026-09-02.txt), and writing the level down
# again would only move the day the two drift.
#
# `-g` is not part of this and is added on top by each gate: it emits debug info
# and changes no code, and without it a report names no line.
asan_product_opt () {
  python3 - "$ROOT" <<'LAKEOPT'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
text = (root / "lakefile.lean").read_text(encoding="utf-8")

body = re.search(r"(?ms)^def ccFlags\b.*?(?=^(?:def |/--|@\[|end )|\Z)", text)
if not body:
    sys.exit(
        "asan: lakefile.lean no longer defines ccFlags -- that function is "
        "what the product's C is compiled with, and a gate cannot guess the level"
    )
levels = re.findall(r'"(-O[^"]*)"', body.group(0))
if len(levels) > 1:
    sys.exit(
        "asan: ccFlags names %d optimisation levels (%s) -- which one reaches "
        "the C depends on a branch this reader does not follow" % (len(levels), ", ".join(levels))
    )
sys.stdout.write(levels[0] if levels else "")
LAKEOPT
}

# A watchdog and not a `timeout`: macOS ships no `timeout`, and a gate here has
# to be able to say "the sanitizer runtime never came up" on the machine where
# that actually happens rather than hang there.
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

# Not skipped: on macOS 26's Command Line Tools clang 17 the runtime spins in its own initializer, and hung items would say nothing about the C.
asan_probe () {  # asan_probe <work dir> <seconds>
  printf 'int main(void) { return 0; }\n' > "$1/probe.c"
  "$CC" "${ASAN[@]}" -g -o "$1/probe" "$1/probe.c"
  run_bounded "$2" "$1/probe.log" "$1/probe"
}

asan_unstartable () {  # asan_unstartable <HEADING> <declared> <probe status> <work dir> <seconds>
  printf '%s: 0 of %s items answered\n\n' "$1" "$2"
  if [ "$3" -eq 137 ]; then
    printf '  A three-line program built with -fsanitize=address did not reach its own\n'
    printf '  main within %ss using %s.\n' "$5" "$("$CC" --version | head -1)"
  else
    printf '  A three-line program built with -fsanitize=address exited %s using\n' "$3"
    printf '  %s.\n' "$("$CC" --version | head -1)"
  fi
  excerpt "$4/probe.log"
  printf '\n'
  printf '  The AddressSanitizer runtime does not start on this platform, so nothing\n'
  printf '  below would be watching the C. This is not a pass: the memory question is\n'
  printf '  answered by the CI job on ubuntu-latest, which has a runtime that starts.\n'
}
