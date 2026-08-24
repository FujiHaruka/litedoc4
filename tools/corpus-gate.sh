#!/usr/bin/env bash
# The tests that need the measurement target — run on purpose, never by accident.
#
# A test owns its input; these do not. They read the 432-module package at
# /Users/haruka/dev/lean-projects, its doc-gen4 reference tree, generated IR
# trees and multi-megabyte `--full` recordings, none of which is in the repository.
#
# They are `#[ignore]`d rather than skipped from inside, because a
# `eprintln!("skipping: …") + return` never reaches the exit code: 7 of them were
# green while the fixtures they wanted had been deleted 【実測 2026-08-16】.
# `tools/corpus-tests.txt` is the inventory and `--verify-list` fails if the two
# sides drift — a test that quietly leaves the gate and a gate that names a test
# nobody wrote are the same bug seen from two ends.
#
# usage:
#   corpus-gate.sh                 run every corpus test (needs the corpus)
#   corpus-gate.sh --verify-list   only check the inventory (needs nothing)
#   corpus-gate.sh --list          print what cargo currently ignores
#   corpus-gate.sh --update-list   rewrite the inventory from cargo's answer
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1
INVENTORY="$HERE/corpus-tests.txt"
PYTHON="${PYTHON:-python3}"

# Every `#[ignore]`d test cargo knows about, as `<target>::<name>`. The target
# prefix is not decoration: bare names collapse the inventory from 21 entries to
# 19 and hide three tests inside their namesakes 【実測 2026-08-23】. Each binary
# is asked directly rather than `cargo test`'s combined output parsed — cargo
# prints `Running …` on stderr and the names on stdout, so on a CI runner they
# arrive in one block and pairing them up yields `::name` for everything.
listed() {
  (cd "$ROOT" && cargo test --workspace --no-run --message-format=json 2>/dev/null) \
    | "$PYTHON" -c '
import json, os, subprocess, sys

for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("reason") != "compiler-artifact":
        continue
    if not message.get("profile", {}).get("test"):
        continue
    exe = message.get("executable")
    if not exe:
        continue
    target = os.path.basename(exe).rsplit("-", 1)[0]
    listed = subprocess.run(
        [exe, "--ignored", "--list"], capture_output=True, text=True
    ).stdout
    suffix = ": test"
    for entry in listed.splitlines():
        if entry.endswith(suffix):
            print(target + "::" + entry[: -len(suffix)])
' | sort -u
}

# From cargo's own output rather than by globbing `target/debug/deps/*`: the hash
# suffix is cargo's, and stale binaries from earlier builds sit beside the fresh ones.
executables() {
  (cd "$ROOT" && cargo test --workspace --no-run --message-format=json 2>/dev/null) \
    | "$PYTHON" -c '
import json, os, sys

for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("reason") != "compiler-artifact":
        continue
    if not message.get("profile", {}).get("test"):
        continue
    exe = message.get("executable")
    if not exe:
        continue
    print(os.path.basename(exe).rsplit("-", 1)[0], exe)
' | sort -u
}

# A trailing `# note` on a line says why that test needs the corpus and is not
# part of the name.
entries() {
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' | sort -u
}

expected() {
  entries "$INVENTORY"
}

# Everything after the `## frozen` header needs a generator that is not in HEAD
# (tag `experiments-frozen`), so running it could only ever panic — and a gate
# that is permanently red is a gate nobody reads.
runnable() {
  sed '/^## frozen/,$d' "$INVENTORY" > "$TMP_RUNNABLE"
  entries "$TMP_RUNNABLE"
}

frozen() {
  sed -n '/^## frozen/,$p' "$INVENTORY" > "$TMP_FROZEN"
  entries "$TMP_FROZEN"
}

TMP_RUNNABLE="$(mktemp)"
TMP_FROZEN="$(mktemp)"
on_exit 'rm -f "$TMP_RUNNABLE" "$TMP_FROZEN"'

case "${1:-run}" in
  --list)
    listed
    ;;

  --update-list)
    # Additive on purpose: which section a test belongs in is a judgement about
    # whether its input can be regenerated from HEAD, which cargo cannot make.
    added=0
    for name in $(listed); do
      if ! expected | grep -qxF "$name"; then
        printf '%s\n' "$name" >> "$TMP_RUNNABLE.add"
        added=$((added + 1))
      fi
    done
    if [ "$added" -eq 0 ]; then
      echo "nothing to add: $INVENTORY already lists every ignored test"
    else
      awk -v add="$TMP_RUNNABLE.add" '
        /^## frozen/ && !done { while ((getline line < add) > 0) print line; done=1 }
        { print }
        END { if (!done) { while ((getline line < add) > 0) print line } }
      ' "$INVENTORY" > "$INVENTORY.new"
      mv "$INVENTORY.new" "$INVENTORY"
      echo "added $added test(s) to $INVENTORY — move any that cannot be regenerated"
      echo "from HEAD into the '## frozen' section by hand."
    fi
    rm -f "$TMP_RUNNABLE.add"
    ;;

  --verify-list)
    got="$(listed)"
    want="$(expected)"
    if [ "$got" = "$want" ]; then
      echo "corpus gate inventory: ok ($(printf '%s\n' "$want" | wc -l | tr -d ' ') tests)"
      exit 0
    fi
    echo "corpus gate inventory: DRIFT" >&2
    echo >&2
    comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got") \
      | sed 's/^/  ignored but not in the inventory: /' >&2
    comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got") \
      | sed 's/^/  in the inventory but not ignored: /' >&2
    echo >&2
    echo "  If the change was intended: tools/corpus-gate.sh --update-list" >&2
    exit 1
    ;;

  run)
    target="${LITEDOC4_TARGET:-/Users/haruka/dev/lean-projects}"
    echo "== what this machine has"
    printf '  %-24s %s\n' "target" "$target $([ -d "$target" ] && echo '(present)' || echo '(MISSING)')"
    for var in LITEDOC4_IR LITEDOC4_BASE_IR LITEDOC4_DOCGEN4_TREE LITEDOC4_LINK_INDEX \
               LITEDOC4_REF_PAGES LITEDOC4_REFERENCE_PAGES LITEDOC4_REFERENCE_GLOBAL \
               LITEDOC4_PAGES LITEDOC4_SITE LITEDOC4_PROTOTYPE_STATE LITEDOC4_MERGE_FIXTURES \
               LITEDOC4_DECL_URLS LITEDOC4_AUTOLINK_FULL LITEDOC4_FRAGMENT_FULL \
               LITEDOC4_PAGE_PARTS_FULL LITEDOC4_DOCGEN4_FULL LITEDOC4_MD4LEAN_FULL; do
      value="${!var:-}"
      if [ -n "$value" ]; then
        printf '  %-24s %s %s\n' "$var" "$value" "$([ -e "$value" ] && echo '(present)' || echo '(MISSING)')"
      else
        printf '  %-24s %s\n' "$var" "(unset — the test's default path is used)"
      fi
    done
    echo
    frozen_list="$(frozen)"
    if [ -n "$frozen_list" ]; then
      echo "== not run: no regenerator in HEAD (tag experiments-frozen)"
      printf '%s\n' "$frozen_list" | sed 's/^/  /'
      echo
    fi

    echo "== the tests"
    # A missing input is a failure here, not a skip: these tests panic naming
    # the variable they wanted.
    #
    # **One inventory entry, one test binary, one test.** A bare name passed to
    # `cargo test -- --exact` is wrong three ways that each hid tests rather than
    # failing 【実測】: `--exact` matches the whole path a binary prints and cargo
    # exits 0 when a filter selects nothing; without `--no-fail-fast` a red binary
    # hides its namesakes; and a name shared by a runnable and a frozen entry
    # pulls the frozen one in. Running each binary by target removes all three.
    status=0
    ran_total=0
    want_total="$(runnable | wc -l | tr -d ' ')"
    EXES="$(mktemp)"
    on_exit 'rm -f "$TMP_RUNNABLE" "$TMP_FROZEN" "$EXES"'
    executables > "$EXES"
    while read -r entry; do
      target_name="${entry%%::*}"
      test_path="${entry#*::}"
      exe="$(awk -v t="$target_name" '$1 == t { print $2 }' "$EXES")"
      echo "-- $target_name :: $test_path"
      if [ -z "$exe" ]; then
        echo "   NO SUCH TEST TARGET: $target_name — the inventory names a binary cargo did not build" >&2
        status=1
        continue
      fi
      log="$(mktemp)"
      "$exe" --ignored --exact "$test_path" --nocapture > "$log" 2>&1 || status=1
      cat "$log"
      ran="$(sed -n 's/^test result:[^0-9]*\([0-9]*\) passed; \([0-9]*\) failed.*/\1 \2/p' "$log" \
             | awk '{ total += $1 + $2 } END { print total + 0 }')"
      echo "   reported a result: $ran"
      if [ "$ran" -ne 1 ]; then
        echo "   NOT ONE TEST — $target_name has no test at $test_path" >&2
        status=1
      fi
      ran_total=$((ran_total + ran))
      rm -f "$log"
    done < <(runnable)
    echo
    echo "tests that reported a result: $ran_total (the inventory lists $want_total)"
    if [ "$ran_total" -ne "$want_total" ]; then
      echo "the gate did not run what it claims to run" >&2
      status=1
    fi
    exit "$status"
    ;;

  *)
    echo "usage: corpus-gate.sh [--verify-list | --list | --update-list]" >&2
    exit 2
    ;;
esac
