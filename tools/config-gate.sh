#!/usr/bin/env bash
# `litedoc4.toml`, read the same way by every command that writes HTML.
#
# Four commands put HTML on disk — `build`, `site`, `render`, `global` — and the
# site's title and index prose come from `litedoc4.toml` rather than from a flag,
# because a flag can be forgotten on one command and then two of them disagree.
# This gate turns that argument into a checked property:
#
#   - every module page's <title> ends in the configured title, in all three
#     trees that write module pages
#   - index.html's <title>, its <h1> and the rendered `index` Markdown are
#     byte-identical in all three trees that write index.html
#   - `docs/references.bib` the same way: references.html is byte-identical in
#     the three trees that write it and lists one entry per `@` entry the file
#     holds, and the citations the module pages link — with the back-reference
#     anchor each carries — are the same in all three trees that write those
#     pages. The back-references references.html lists are exactly those anchors,
#     so `global`, which writes references.html without writing a page, is held
#     to what the pages say
#
# The comparison is over the *rendered* bytes, not over "did the command read the
# file": a command that read it and then dropped the value would pass that
# question and fail this one.
#
# The counts are asserted too, because a package with no `litedoc4.toml` and a run
# that produced no pages both make every command agree trivially. A package with
# no bibliography is still compared: three empty lists of references and no
# citation anywhere is an agreement, and a bibliography that links nothing is not.
#
# usage: config-gate.sh --root <pkg> --ir <dir> --built <site> [--out <dir>]
#                       [--link-index <file>] [--blind site|render|global]
#          --built   the tree `litedoc4 build` already wrote (e2e-micro.sh has one)
#          --link-index  the `.lidx` that build wrote. Without it a package whose
#                    signatures mention a dependency's names cannot be rendered
#                    at all — `--no-link-index` is only for a package that has
#                    no such name.
#          --blind   run one command **without** `--root`, to see the gate fail.
#                    Never in CI; it is how the gate was falsified.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LITEDOC4="${LITEDOC4:-$REPO/.lake/build/bin/litedoc4}"

ROOT=""; IR=""; BUILT=""; OUT=""; BLIND=""; LIDX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --ir) IR="$2"; shift 2 ;;
    --built) BUILT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --blind) BLIND="$2"; shift 2 ;;
    --link-index) LIDX="$2"; shift 2 ;;
    -h|--help) sed -n '1,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ROOT" ] && [ -n "$IR" ] && [ -n "$BUILT" ] || {
  echo "usage: config-gate.sh --root <pkg> --ir <dir> --built <site>" >&2; exit 2; }
[ -x "$LITEDOC4" ] || {
  echo "no litedoc4 at $LITEDOC4 — tools/build-lean-exe.sh --toolchain-from e2e/micro" >&2; exit 2; }
[ -f "$ROOT/litedoc4.toml" ] || {
  echo "$ROOT has no litedoc4.toml — this gate needs a package that configures something" >&2
  exit 2; }

TEMPORARY=0
if [ -z "$OUT" ]; then OUT="$(mktemp -d)"; TEMPORARY=1; fi
mkdir -p "$OUT"

root_for() { [ "$1" = "$BLIND" ] || printf -- '--root\n%s\n' "$ROOT"; }

URL="https://example.invalid/o/r/blob/$(printf '0%.0s' $(seq 40))"
if [ -n "$LIDX" ]; then LINKS=(--link-index "$LIDX"); else LINKS=(--no-link-index); fi

rm -rf "$OUT/site" "$OUT/render" "$OUT/global" "$OUT/state"
# shellcheck disable=SC2046
"$LITEDOC4" site --ir "$IR" --out "$OUT/site" --source-url "$URL" "${LINKS[@]}" \
  --state "$OUT/state" $(root_for site) > "$OUT/site.log" 2>&1 || {
  echo "config-gate: \`site\` failed" >&2; sed -n '1,20p' "$OUT/site.log" >&2; exit 1; }
# shellcheck disable=SC2046
"$LITEDOC4" render --ir "$IR" --pages "$OUT/render" --source-url "$URL" "${LINKS[@]}" \
  $(root_for render) > "$OUT/render.log" 2>&1 || {
  echo "config-gate: \`render\` failed" >&2; sed -n '1,20p' "$OUT/render.log" >&2; exit 1; }
# shellcheck disable=SC2046
"$LITEDOC4" global --ir "$IR" --out "$OUT/global" $(root_for global) \
  > "$OUT/global.log" 2>&1 || {
  echo "config-gate: \`global\` failed" >&2; sed -n '1,20p' "$OUT/global.log" >&2; exit 1; }

python3 - "$ROOT" "$BUILT" "$OUT/site" "$OUT/render" "$OUT/global" <<'PY'
import html
import os
import re
import sys

root, built, site, render, glob_out = sys.argv[1:6]
problems = []

# Read straight out of the file: the gate's expectation may not come from the
# thing it is checking.
config = open(os.path.join(root, "litedoc4.toml"), encoding="utf-8").read()
want_title = re.search(r'^title\s*=\s*"([^"]*)"', config, re.M)
want_index = re.search(r'^index\s*=\s*"([^"]*)"', config, re.M)
if not want_title and not want_index:
    sys.exit("config-gate: litedoc4.toml sets neither key — nothing to compare")
title = want_title.group(1) if want_title else None

TITLE = re.compile(r"<title>(.*?)</title>", re.S)
INTRO = re.compile(r'<div class="intro doc">(.*?)</div>', re.S)


def pages(tree):
    found = {}
    for base, _, files in os.walk(tree):
        for name in files:
            if not name.endswith(".html"):
                continue
            path = os.path.join(base, name)
            found[os.path.relpath(path, tree)] = open(path, encoding="utf-8").read()
    return found


trees = {"build": pages(built), "site": pages(site), "render": pages(render),
         "global": pages(glob_out)}

module_pages = sorted(
    name for name, text in trees["render"].items() if 'data-module="' in text
)
if not module_pages:
    problems.append("the render tree holds no module page — nothing was compared")
checked_titles = 0
for page in module_pages:
    seen = {}
    for which in ("build", "site", "render"):
        text = trees[which].get(page)
        if text is None:
            problems.append(f"{which} did not write {page}")
            continue
        found = TITLE.search(text)
        seen[which] = html.unescape(found.group(1)) if found else "<no title>"
    if len(set(seen.values())) > 1:
        problems.append(f"{page}: the three commands disagree — {seen}")
        continue
    checked_titles += 1
    if title is not None and not next(iter(seen.values())).endswith(title):
        problems.append(
            f"{page}: <title> is {next(iter(seen.values()))!r}, "
            f"which does not end in the configured {title!r}"
        )

index_writers = ("build", "site", "global")
indexes = {}
for which in index_writers:
    text = trees[which].get("index.html")
    if text is None:
        problems.append(f"{which} did not write index.html")
        continue
    found_title = TITLE.search(text)
    found_intro = INTRO.search(text)
    indexes[which] = (
        html.unescape(found_title.group(1)) if found_title else "<no title>",
        found_intro.group(1) if found_intro else None,
    )
if len(set(indexes.values())) > 1:
    problems.append(f"index.html differs between {index_writers}: {indexes}")
elif indexes:
    got_title, got_intro = next(iter(indexes.values()))
    if title is not None and title not in got_title:
        problems.append(f"index.html <title> is {got_title!r}, not the configured {title!r}")
    if want_index and not got_intro:
        problems.append("litedoc4.toml names an `index` but no index prose is on the page")
    if want_index and got_intro:
        # A heading is an <h1>, not a line starting with `#`: the Markdown went
        # through the renderer rather than being pasted.
        if "#" in got_intro.split("<")[0]:
            problems.append("the index prose reached the page unrendered")

bib = os.path.join(root, "docs", "references.bib")
want_entries = 0
if os.path.exists(bib):
    want_entries = len(re.findall(r"^\s*@\w+\s*\{", open(bib, encoding="utf-8").read(), re.M))
references = {}
for which in index_writers:
    text = trees[which].get("references.html")
    if text is None:
        problems.append(f"{which} did not write references.html")
    else:
        references[which] = text
got_entries = 0
if len(set(references.values())) > 1:
    problems.append(f"references.html differs between {index_writers}")
elif references:
    got_entries = next(iter(references.values())).count('<li id="ref_')
    if got_entries != want_entries:
        problems.append(f"references.html lists {got_entries} entr(ies); "
                        f"docs/references.bib holds {want_entries}")

CITATION = re.compile(r'<a href="[^"]*references\.html#ref_([^"]*)"([^>]*)>')
BACKREF_ID = re.compile(r'\bid="(_backref_[^"]*)"')
ENTRY = re.compile(r'<li id="ref_([^"]*)">(.*?)</li>', re.S)
BACKREF_LINK = re.compile(r'<a href="\./([^"#]*)#(_backref_[^"]*)"')


def citations_on(text):
    for key, rest in CITATION.findall(text):
        found = BACKREF_ID.search(rest)
        yield key, found.group(1) if found else None


citations = {
    which: tuple((page, key, anchor) for page in module_pages
                 for key, anchor in citations_on(trees[which].get(page, "")))
    for which in ("build", "site", "render")
}
listed = set()
if len(set(citations.values())) > 1:
    counts = {which: len(found) for which, found in citations.items()}
    problems.append(f"the commands disagree about which citations are links: {counts}")
elif want_entries and not citations["build"]:
    problems.append("docs/references.bib has entries and no module page links a citation "
                    "— nothing was compared")
else:
    anchorless = [(page, key) for page, key, anchor in citations["build"] if anchor is None]
    if anchorless:
        problems.append(f"{len(anchorless)} citation link(s) carry no back-reference anchor, "
                        f"the first {anchorless[0]}")
    for key, body in ENTRY.findall(references.get("build", "")):
        for page, anchor in BACKREF_LINK.findall(body):
            listed.add((html.unescape(page), key, html.unescape(anchor)))
    anchored = set(citations["build"])
    if listed != anchored:
        problems.append(
            "references.html's back-references are not the pages' citation anchors: "
            f"{sorted(listed - anchored)[:3]} listed and not on a page, "
            f"{sorted(anchored - listed)[:3]} on a page and not listed")

if problems:
    for problem in problems:
        print(f"CONFIG GATE FAIL  {problem}", file=sys.stderr)
    sys.exit(1)

print(
    f"config       title {title!r} on {checked_titles} module page(s) x 3 commands; "
    f"index.html identical across {len(index_writers)} commands; references.html "
    f"identical with {got_entries} entr(ies), {len(citations['build'])} citation link(s) "
    f"identical x 3 commands and listed as {len(listed)} back-reference(s)"
)
PY
status=$?

if [ "$TEMPORARY" -eq 1 ]; then rm -rf "$OUT"; fi
exit "$status"
