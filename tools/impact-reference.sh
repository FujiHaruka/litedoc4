#!/usr/bin/env bash
# Run the `impact` and `prune` stages over the measurement target's IR and page
# tree and record everything they write, decide and exit with.
#
# Both stages live here because they share the base IR, the module names and the
# idea of what a page is called; splitting them would write the module list twice.
#
# **Nothing outside $OUT is ever written to.** `prune` deletes files, so every
# scenario that runs it copies a page tree into $OUT first and `guard_writable`
# refuses a `--pages` that is not under $OUT — the target package's real site and
# the reference fixtures cannot be reached even by a typo.
#
# usage: tools/impact-reference.sh [--out DIR] [--base-ir DIR]
#                                  [--pages DIR] [--site DIR]

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_BIN="$REPO/target/release/litedoc4"

OUT=
BASE_IR=/private/tmp/lean-doc-relay/w7h/base-ir
PAGES_SRC=/private/tmp/lean-doc-relay/m1/ref-pages
SITE_SRC=/private/tmp/lean-doc-relay/m2/gate/ref-site

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --base-ir) BASE_IR="$2"; shift 2 ;;
    --pages) PAGES_SRC="$2"; shift 2 ;;
    --site) SITE_SRC="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

OUT="${OUT:-/private/tmp/lean-doc-relay/m3c/rust}"

for d in "$BASE_IR" "$PAGES_SRC" "$SITE_SRC"; do
  [ -d "$d" ] || { echo "missing: $d" >&2; exit 1; }
done

[ -x "$RUST_BIN" ] || {
  echo "missing: $RUST_BIN — run: cargo build --release -p litedoc4" >&2; exit 1;
}
impact () { "$RUST_BIN" impact "$@"; }
prune ()  { "$RUST_BIN" prune "$@"; }

rm -rf "$OUT"
mkdir -p "$OUT/fixtures"

# declarations / importedByDirect / importersTransitive / referrersDirect, from
# `litedoc4 impact --census` over the base IR 【実測 2026-08-15】:
#   HUB   4 / 15 / 261 / 49 — 49 modules name something of its through a
#         (module, name) pair, which is what `--mode referrers` follows.
#   LEAF  1 / 281 / 414 / 0 — **a misnomer**: 281 modules import it. What the
#         scenarios turn on is that nothing refers to it *by name*.
#   OTHER 8 / 2 / 2 / 1 — small in every direction.
#   GHOST not a module of the package at all.
HUB=InformationTheory.Shannon.Bridge
LEAF=InformationTheory.Meta.EntryPoint
OTHER=InformationTheory.Polymatroid.Basic
GHOST=InformationTheory.Nonexistent.Module
CASCADE_1=InformationTheory.Shannon.ConditionalMethodOfTypes.Mass.Concentration
CASCADE_2=InformationTheory.Shannon.ConditionalMethodOfTypes.Mass.SliceMass
CASCADE_3=InformationTheory.Shannon.ConditionalMethodOfTypes.Core
CASCADE_4=InformationTheory.Shannon.ConditionalMethodOfTypes.Mass

FIX="$OUT/fixtures"
{
  printf '# an earlier round already took these\n'
  printf '\n'
  printf '%s\n' "$HUB"
  printf '   %s   \n' "$LEAF"
  printf '%s\n' "$HUB"
} > "$FIX/changed-three.txt"
printf '%s\n' "$LEAF" > "$FIX/changed-leaf.txt"
# **0 bytes, no newline** — what `global --print-set` writes when the map delta
# is empty, and what the pipeline hands on unchanged. An empty file is a real
# answer, not a missing one.
: > "$FIX/changed-empty.txt"
printf '%s\n' "$GHOST" > "$FIX/changed-ghost.txt"

printf '%s\n%s\n' "$LEAF" "$GHOST" > "$FIX/remove-leaf-and-ghost.txt"
printf '%s\n' "$OTHER" > "$FIX/remove-other.txt"
printf '%s\n' "$GHOST" > "$FIX/remove-ghost-only.txt"
printf '%s\n%s\n%s\n%s\n' \
  "$CASCADE_1" "$CASCADE_2" "$CASCADE_3" "$CASCADE_4" > "$FIX/remove-cascade.txt"

# The *wording* on stderr is not compared — a diagnostic's wording belongs to the
# implementation that wrote it — but "did it complain" is a fact about the answer.
record () { # record <name> <status> ; stdout/stderr already written
  local name="$1" status="$2"
  printf '%s\n' "$status" > "$OUT/$name-status.txt"
  if [ -s "$OUT/$name-stderr.txt" ]; then
    printf 'yes\n' > "$OUT/$name-complained.txt"
  else
    printf 'no\n' > "$OUT/$name-complained.txt"
  fi
}

run_impact () { # run_impact <name> [args...]
  local name="$1"; shift
  local status=0
  impact "$@" > "$OUT/$name-stdout.txt" 2> "$OUT/$name-stderr.txt" || status=$?
  record "$name" "$status"
  # A `--print-set` that was asked for and not written is the answer to "nothing
  # changed and the mode is not `all`", and the pipeline then reads a file that
  # is not there. Recorded on its own: an absent file cannot be diffed.
  local want= set_path=
  for arg in "$@"; do
    if [ -n "$want" ]; then set_path="$arg"; want=; continue; fi
    [ "$arg" = --print-set ] && want=1
  done
  if [ -n "$set_path" ]; then
    if [ -f "$set_path" ]; then
      printf 'yes\n' > "$OUT/$name-printset-exists.txt"
    else
      printf 'no\n' > "$OUT/$name-printset-exists.txt"
    fi
  fi
}

guard_writable () { # guard_writable <path> — nothing outside $OUT is deletable
  case "$1" in
    "$OUT"/*) ;;
    *) echo "refusing to prune outside $OUT: $1" >&2; exit 1 ;;
  esac
}

page_copy () { # page_copy <name> <source> -> the copy's path
  local dir="$OUT/$1/pages"
  mkdir -p "$OUT/$1"
  cp -R "$2" "$dir"
  printf '%s' "$dir"
}

run_prune () { # run_prune <name> <pages> [args...]
  local name="$1" pages="$2"; shift 2
  guard_writable "$pages"
  local status=0
  prune --pages "$pages" "$@" > "$OUT/$name-stdout.txt" 2> "$OUT/$name-stderr.txt" || status=$?
  record "$name" "$status"
  snapshot "$name" "$pages"
}

# What is left: a stage that deletes is as wrong when it takes too much as when
# it takes too little, and only the survivors say which.
snapshot () { # snapshot <name> <pages>
  local name="$1" pages="$2"
  if [ -d "$pages" ]; then
    # LC_ALL=C: byte order, so the listing is the same on any machine and is
    # the order `cargo test`'s BTreeSet reproduces.
    ( cd "$pages" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) > "$OUT/$name-files.txt"
    ( cd "$pages" && find . -type d | sed 's|^\./||' | LC_ALL=C sort ) > "$OUT/$name-dirs.txt"
    printf '%s\n%s\n' \
      "files $(wc -l < "$OUT/$name-files.txt" | tr -d ' ')" \
      "dirs $(wc -l < "$OUT/$name-dirs.txt" | tr -d ' ')" > "$OUT/$name-counts.txt"
  else
    printf 'no page tree\n' > "$OUT/$name-counts.txt"
  fi
}

run_impact census --ir "$BASE_IR" --census "$OUT/census-census.tsv"

run_impact self --ir "$BASE_IR" --changed "$HUB" --mode self \
  --print-set "$OUT/self-set.txt" --json "$OUT/self-impact.json"
run_impact referrers --ir "$BASE_IR" --changed "$HUB" --mode referrers \
  --print-set "$OUT/referrers-set.txt" --json "$OUT/referrers-impact.json"
run_impact importers --ir "$BASE_IR" --changed "$HUB" --mode importers \
  --print-set "$OUT/importers-set.txt" --json "$OUT/importers-impact.json"

# `importers` is the default, so this has to agree with the run above file for file.
run_impact default-mode --ir "$BASE_IR" --changed "$HUB" \
  --print-set "$OUT/default-mode-set.txt" --json "$OUT/default-mode-impact.json"

# `all` is the one mode that is valid with nothing changed (the render-key case),
# and with a changed set it has to select the same modules anyway.
run_impact all-empty --ir "$BASE_IR" --mode all \
  --print-set "$OUT/all-empty-set.txt" --json "$OUT/all-empty-impact.json"

run_impact all-changed --ir "$BASE_IR" --changed "$HUB" --mode all \
  --print-set "$OUT/all-changed-set.txt" --json "$OUT/all-changed-impact.json"

run_impact leaf --ir "$BASE_IR" --changed "$LEAF" --mode importers \
  --print-set "$OUT/leaf-set.txt" --json "$OUT/leaf-impact.json"

# Flags **and** a file, with a repeat across the two: `changed` is the
# concatenation in order with repeats kept, and `self` is the set.
run_impact multi --ir "$BASE_IR" --changed "$OTHER" --changed "$HUB" \
  --changed-file "$FIX/changed-three.txt" --mode referrers \
  --print-set "$OUT/multi-set.txt" --json "$OUT/multi-impact.json"

run_impact file-only --ir "$BASE_IR" --changed-file "$FIX/changed-leaf.txt" \
  --mode importers --print-set "$OUT/file-only-set.txt" \
  --json "$OUT/file-only-impact.json"

# The empty changed set — what the pipeline meets whenever only the whole-package
# map moved: nothing is selected and `--print-set` is not written at all.
run_impact empty-file --ir "$BASE_IR" --changed-file "$FIX/changed-empty.txt" \
  --mode importers --print-set "$OUT/empty-file-set.txt" \
  --json "$OUT/empty-file-impact.json"

run_impact empty-file-all --ir "$BASE_IR" --changed-file "$FIX/changed-empty.txt" \
  --mode all --print-set "$OUT/empty-file-all-set.txt" \
  --json "$OUT/empty-file-all-impact.json"

# An unrecognised mode is never looked at when there is nothing to select: exit 0,
# silently. With something to select it is exit 2.
run_impact unknown-mode-quiet --ir "$BASE_IR" --mode nonsense \
  --print-set "$OUT/unknown-mode-quiet-set.txt"

run_impact unknown-mode --ir "$BASE_IR" --changed "$HUB" --mode nonsense \
  --print-set "$OUT/unknown-mode-set.txt"

# A changed module the package does not have: exit 3, nothing written. No `--ir`: exit 2.
run_impact not-a-module --ir "$BASE_IR" --changed-file "$FIX/changed-ghost.txt" \
  --mode importers --print-set "$OUT/not-a-module-set.txt" \
  --json "$OUT/not-a-module-impact.json"

run_impact no-ir --mode all

# Census first, whatever the selection does.
run_impact census-and-set --ir "$BASE_IR" --changed "$LEAF" --mode referrers \
  --census "$OUT/census-and-set-census.tsv" \
  --print-set "$OUT/census-and-set-set.txt" \
  --json "$OUT/census-and-set-impact.json"

run_impact dup-changed --ir "$BASE_IR" --changed "$HUB" --changed "$HUB" \
  --mode self --print-set "$OUT/dup-changed-set.txt" \
  --json "$OUT/dup-changed-impact.json"

# One page there, one already gone: dry, then for real. The directory the page
# was alone in goes too.
run_prune dry-remove "$(page_copy dry-remove "$PAGES_SRC")" \
  --remove "$FIX/remove-leaf-and-ghost.txt" --dry-run \
  --json "$OUT/dry-remove-prune.json"

run_prune real-remove "$(page_copy real-remove "$PAGES_SRC")" \
  --remove "$FIX/remove-leaf-and-ghost.txt" \
  --json "$OUT/real-remove-prune.json"

# The orphan rule over a whole site, where three `.html` artifacts belong to no
# module. Dry, because the answer is a warning.
run_prune orphans-site "$(page_copy orphans-site "$SITE_SRC")" \
  --remove "$FIX/remove-leaf-and-ghost.txt" --ir "$BASE_IR" --dry-run \
  --json "$OUT/orphans-site-prune.json"

run_prune orphans-pages "$(page_copy orphans-pages "$PAGES_SRC")" \
  --remove "$FIX/remove-other.txt" --ir "$BASE_IR" \
  --json "$OUT/orphans-pages-prune.json"

# No remove list, so the orphan half is isolated: every page of a module that
# left the IR is an orphan.
run_prune orphans-only "$(page_copy orphans-only "$SITE_SRC")" \
  --ir "$BASE_IR" --json "$OUT/orphans-only-prune.json"

# The recursive half of the empty-directory pass.
run_prune cascade "$(page_copy cascade "$PAGES_SRC")" \
  --remove "$FIX/remove-cascade.txt" --json "$OUT/cascade-prune.json"

run_prune already-absent "$(page_copy already-absent "$PAGES_SRC")" \
  --remove "$FIX/remove-ghost-only.txt" --json "$OUT/already-absent-prune.json"

# The same deletion twice: the second run has nothing to do, and has to say so
# rather than fail.
RERUN="$(page_copy rerun "$PAGES_SRC")"
run_prune rerun-1 "$RERUN" --remove "$FIX/remove-other.txt" \
  --json "$OUT/rerun-1-prune.json"
run_prune rerun-2 "$RERUN" --remove "$FIX/remove-other.txt" \
  --json "$OUT/rerun-2-prune.json"

# The two usage refusals. `--pages` names a tree that does not exist, so a run
# that got past the refusal has nothing it could delete.
status=0
prune --pages "$FIX/no-such-page-tree" > "$OUT/no-list-stdout.txt" \
  2> "$OUT/no-list-stderr.txt" || status=$?
record no-list "$status"
status=0
prune --remove "$FIX/remove-other.txt" > "$OUT/no-pages-stdout.txt" \
  2> "$OUT/no-pages-stderr.txt" || status=$?
record no-pages "$status"

# Makes an accidental edit to the recorded tree loud.
( cd "$OUT" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 ) > "$OUT.sha256"

printf 'base IR: %s\n' "$BASE_IR"
printf 'pages: %s\n' "$PAGES_SRC"
printf 'site: %s\n' "$SITE_SRC"
printf 'files: %s\n' "$(find "$OUT" -type f | wc -l | tr -d ' ')"
printf 'manifest: %s\n' "$OUT.sha256"
