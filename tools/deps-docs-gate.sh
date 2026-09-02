#!/usr/bin/env bash
# The two halves of the dependency-documentation rule, read out of the HTML a run
# actually wrote.
#
# It fails saying either "a link this run wrote to a dependency's documentation
# site does not exist there" or "a name the table did not hold was linked at that
# site anyway" — naming the href, the page's HTTP status, the anchor the page
# does not carry, or the name whose fallback did not happen.
#
# A gate and not a test because it needs the measurement target, its toolchain,
# the Lean extractor **and the network**, none of which the test suite may reach.
# `Litedoc4Test.DepsDocs` reads a declaration table from disk; what it cannot ask
# is whether the other side's server agrees.
#
# **Both branches of the rule are checked**, because a gate that only checks the
# first checks the half that is easy to get right.
#
# Branch 1 — verified names resolve. Every `<base>/...` href is collected out of
# the HTML, entities and all, each distinct page is fetched, and each anchor is
# looked for in the bytes that came back as `id="<anchor>"`. **The anchor is
# looked for in the served page and not in the declaration table**: the table is
# the build's own input, so checking against it would answer "the resolver copied
# the table correctly" and call it "the link resolves" — and a declaration
# renamed inside a module that still exists (Mathlib's deprecated aliases expire
# after six months → benchmarks/results/deps-link-rot-2026-08-19.txt §4) is
# invisible to a page-only check and to a table-only check alike. The expensive
# way costs a couple of seconds: a page is 12-31 kB and ~0.2 s, six at a time
# (measured 2026-08-19).
#
# Branch 2 — names the table did not hold really fell back. For each: (a) no href
# anywhere on the site is that name's documentation page, read off the collected
# hrefs by fragment, so a link to a page that exists and answers 200 is caught
# just the same — a wrong-but-live page passes every HTTP check branch 1 has; and
# (b) where the name is linked at all, the href is its root's **version-pinned
# source**, whose base is asked of `litedoc4 links --out` rather than rebuilt
# here, so this compares the renderer with the product's own answer and not with
# a second implementation of the same string join. (b) goes by anchor text, the
# *display* form, so a name rendered as notation (`≤`) or shortened is reported
# as not found by text rather than as verified; (a) has no such gap.
#
# Init is pointed at the site by default and not only Mathlib because branch 2 is
# empty otherwise: the table holds 396 of 396 Mathlib names and 127 of 130 Init
# names (measured 2026-08-19), so Init is the only root where the fallback fires at
# all. mathlib4_docs documents Lean core, which is why Init has an answer there.
#
# Not covered: **resolved names the site never links** — they exist, 11 of 396 on
# the measurement target, so branch 1's denominator is **the hrefs the site
# wrote** and not the map's names, which would report links as checked that were
# never written. Nor **anything about tomorrow** (mathlib4_docs is rebuilt from
# `master`, so a pass is a statement about the minute it ran in), nor **the
# page's own correctness** (`id="X"` present is not "X says the right thing").
#
# Made to fail on purpose (measured 2026-08-19), rewriting only copies under this
# script's work area: `--inject anchor` points one entry at an anchor the page
# does not carry (the page still answers 200 — the case a page-only check
# passes); `--inject page` points it at a page the site does not have; `--inject
# fallback` removes a verified, linked name from the *reference* map, so the real
# pages still link it at its real live documentation page. The last is staged on
# the reference side because a documentation href that is live in every respect
# is the only thing branch 1 cannot see.
#
# usage: tools/deps-docs-gate.sh [--out DIR] [--keep] [--inject anchor|page|fallback]
#                                [--target DIR] [--lib NAME] [--jobs N]
#                                [--base URL] [--root-name NAME]...
#                                [--parallel N] [--reuse]
#   --out        work area (default: /private/tmp/lean-doc-relay/depsdocs)
#   --keep       do not delete the work area on success (a site is ~35 MB)
#   --root-name  a module root to point at --base; repeatable, and the first one
#                given replaces the default pair (Mathlib, Init)
#   --inject     build, then break one thing on purpose and check that tree too;
#                the run FAILS if the break is not reported
#   --reuse      keep an existing build under --out instead of rebuilding
#   --parallel   concurrent page fetches (default 6)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/target.sh
source "$HERE/lib/target.sh" || exit 1
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh" || exit 1

OUT=/private/tmp/lean-doc-relay/depsdocs
TARGET="$TARGET_REPO"
LIB=InformationTheory
JOBS=4
PARALLEL=6
BASE=https://leanprover-community.github.io/mathlib4_docs
ROOTS=(Mathlib Init)
ROOTS_GIVEN=0
INJECT=
KEEP=0
REUSE=0
LITEDOC4="${LITEDOC4:-$REPO/.lake/build/bin/litedoc4}"
EXTRACT_BIN="${EXTRACT_BIN:-$REPO/extractor/build/extract}"
LAKE="${LAKE:-$HOME/.elan/bin/lake}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --lib) LIB="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --root-name)
      if [ "$ROOTS_GIVEN" -eq 0 ]; then ROOTS=(); ROOTS_GIVEN=1; fi
      ROOTS+=("$2"); shift 2 ;;
    --inject) INJECT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --reuse) REUSE=1; shift ;;
    -h|--help) sed -n '1,/^set -/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$INJECT" in
  ""|anchor|page|fallback) ;;
  *) echo "--inject takes anchor, page or fallback, not $INJECT" >&2; exit 2 ;;
esac
[ "${#ROOTS[@]}" -gt 0 ] || { echo "--root-name named no root" >&2; exit 2; }

[ -x "$LITEDOC4" ] || {
  echo "no litedoc4 at $LITEDOC4 — tools/build-lean-exe.sh --toolchain-from e2e/micro" >&2; exit 2; }
[ -x "$EXTRACT_BIN" ] || {
  echo "no extractor at $EXTRACT_BIN — extractor/build.sh" >&2; exit 2; }
command -v "$LAKE" >/dev/null 2>&1 || { echo "no lake at $LAKE — set LAKE" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "no target package at $TARGET" >&2; exit 2; }
case "$OUT" in
  "$TARGET"|"$TARGET"/*) echo "--out may not be inside the target" >&2; exit 2 ;;
  "$REPO"|"$REPO"/*) echo "--out may not be inside this repository" >&2; exit 2 ;;
esac

# Deleted on the way out unless --keep: a site is tens of megabytes and this
# repository has filled a disk with five generations of them (measured 2026-08-17).
#
# `if`, never `[ … ] && rm`: an EXIT trap's last command decides the script's
# exit status, so a trailing test that comes out false makes a successful run
# exit 1, printing "ok" (measured 2026-08-18).
cleanup () {
  if [ "$KEEP" -eq 0 ]; then
    if [ -d "$OUT" ]; then rm -rf "$OUT"; fi
  fi
}
on_exit cleanup

say () { printf '\n=== %s\n' "$1"; }

mkdir -p "$OUT"
SITE_OUT="$OUT/build"
MAP="$SITE_OUT/work/deps-docs-map.json"
LINKS="$OUT/links.json"
ROOT_LIST="$(IFS=,; printf '%s' "${ROOTS[*]}")"

say "1/4 build $LIB with $ROOT_LIST -> $BASE"
if [ "$REUSE" -eq 1 ] && [ -f "$MAP" ] && [ -f "$LINKS" ]; then
  echo "reusing $SITE_OUT"
else
  rm -rf "$SITE_OUT"
  DOCS_FLAGS=()
  for root in "${ROOTS[@]}"; do
    DOCS_FLAGS+=(--deps-docs-url "$root=$BASE")
  done
  # Redirected to a file rather than piped through `tee`: a pipeline reports its
  # **last** stage's status, so `litedoc4 … | tee` is exit 0 even when litedoc4
  # refused with 3 (measured 2026-08-18).
  build_status=0
  "$LITEDOC4" build --root "$TARGET" --lib "$LIB" --out "$SITE_OUT" \
    --extractor-bin "$EXTRACT_BIN" --lake "$LAKE" --jobs "$JOBS" \
    "${DOCS_FLAGS[@]}" > "$OUT/build.log" 2>&1 || build_status=$?
  if [ "$build_status" -ne 0 ]; then
    echo "the build failed (exit $build_status); last lines:" >&2
    tail -25 "$OUT/build.log" >&2
    KEEP=1
    exit 1
  fi
  # The version-pinned base per root, **from the product**, for branch 2 (b).
  links_status=0
  "$LITEDOC4" links --root "$TARGET" --lake "$LAKE" --out "$LINKS" \
    > "$OUT/links.log" 2>&1 || links_status=$?
  if [ "$links_status" -ne 0 ]; then
    echo "litedoc4 links failed (exit $links_status); last lines:" >&2
    tail -25 "$OUT/links.log" >&2
    KEEP=1
    exit 1
  fi
fi
grep -E '^(deps|external|source) ' "$OUT/build.log" || true

# Without the resolved map the run under test never had the feature on, and
# everything below would check zero links and pass: "0 dead links" is only worth
# something next to "of how many".
[ -f "$MAP" ] || {
  echo "no resolved documentation map at $MAP — the build did not pass --deps-docs-url" >&2
  KEEP=1
  exit 1; }

# One python program does every half, so that the inventory it built and the
# inventory it reports on cannot drift apart — that is how a gate comes to report
# success while checking nothing. It fetches through `curl` because a build
# already depends on `curl`, and a second HTTP client would be a second thing to
# be wrong.
check_site () { # check_site <label> <page tree> <report> <reference map>
  python3 - "$1" "$2" "$3" "$BASE" "$ROOT_LIST" "$4" "$PARALLEL" "$OUT" \
    "$SITE_OUT/ir" "$LINKS" <<'PY'
import html
import json
import os
import re
import subprocess
import sys
import urllib.parse

(label, pages, report, base, root_list, map_path, parallel, work, ir_dir,
 links_path) = sys.argv[1:11]
base = base.rstrip("/")
parallel = max(1, int(parallel))
roots = [name for name in root_list.split(",") if name]

# Attribute values are unescaped before anything is done with them: an `id` or an
# `href` compared without undoing `&amp;`/`&lt;` produces a difference in both
# directions at once, which reads as a broken site and is really two different
# character sets (measured 2026-08-17).
ANCHOR = re.compile(r'<a[^>]*href="([^"]*)"[^>]*>([^<]*)</a>')
HREF = re.compile(r'href="([^"]*)"')
ID = re.compile(r'id="([^"]*)"')

links = {}          # docs url -> [(file, page, anchor)]
by_text = {}        # anchor text -> {(file, href)}
files_read = 0
for root, _dirs, names in os.walk(pages):
    for name in names:
        if not name.endswith(".html"):
            continue
        path = os.path.join(root, name)
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        files_read += 1
        where = os.path.relpath(path, pages)
        for raw in HREF.findall(text):
            url = html.unescape(raw)
            if not url.startswith(base + "/"):
                continue
            page, _, anchor = url.partition("#")
            links.setdefault(url, []).append((where, page, anchor))
        for raw_href, raw_text in ANCHOR.findall(text):
            by_text.setdefault(html.unescape(raw_text), set()).add(
                (where, html.unescape(raw_href))
            )

pages_wanted = sorted({page for entries in links.values() for _f, page, _a in entries})
anchors_wanted = {}
for entries in links.values():
    for _f, page, anchor in entries:
        if anchor:
            anchors_wanted.setdefault(page, set()).add(anchor)
# By fragment: doc-gen4's `docLink` for a declaration ends in its full name,
# which is what makes this the name-level question and not a string search.
documented_here = {}
for url, entries in links.items():
    for where, _page, anchor in entries:
        if anchor:
            documented_here.setdefault(anchor, set()).add((where, url))

# The request set is re-derived from the IR the way `Want::of` does — every
# `deps/*.json` slice, bucketed by the **defining module's** first component —
# and checked against the count the product recorded. A re-derivation that
# disagrees with `requestedNames` is a bug in this script, and it says so rather
# than report a fallback set of its own invention.
with open(map_path, encoding="utf-8") as handle:
    resolved = json.load(handle)
by_root = {entry["root"]: entry for entry in resolved.get("roots", [])}

requested = {}
with open(os.path.join(ir_dir, "index.json"), encoding="utf-8") as handle:
    index = json.load(handle)
for entry in index.get("dependencyMaps", []):
    with open(os.path.join(ir_dir, entry["file"]), encoding="utf-8") as handle:
        slice_ = json.load(handle)
    for name, module in slice_.get("declarations", {}).items():
        root = module.split(".", 1)[0]
        if root in by_root:
            requested.setdefault(root, set()).add(name)

problems = []
fallback = {}
for root, entry in by_root.items():
    asked = requested.get(root, set())
    if len(asked) != entry["requestedNames"]:
        problems.append(
            "GATE ERROR  %s: this script re-derived %d requested name(s) and the "
            "run recorded %d — the fallback set below would be invented"
            % (root, len(asked), entry["requestedNames"])
        )
    fallback[root] = sorted(asked - set(entry["declarations"]))

with open(links_path, encoding="utf-8") as handle:
    source_base = {row["root"]: (row.get("base") or "")
                   for row in json.load(handle)["rows"]}

if not links:
    print(
        "%s: the site wrote no %s link at all — there is nothing to check, and a "
        "gate that checks nothing is the failure this one exists not to be"
        % (label, base),
        file=sys.stderr,
    )
    sys.exit(1)

# One process, one connection pool. Bodies are named by index so that a URL's
# characters never become a path's.
jar = os.path.join(work, "fetched-" + label)
os.makedirs(jar, exist_ok=True)
config = os.path.join(work, "fetch-" + label + ".curl")
bodies = {}
with open(config, "w", encoding="utf-8") as handle:
    for index_, page in enumerate(pages_wanted):
        body = os.path.join(jar, "%05d.html" % index_)
        bodies[page] = body
        handle.write('url = "%s"\n' % page)
        handle.write('output = "%s"\n' % body)
    handle.write("--compressed\n--location\n--silent\n--show-error\n")
    handle.write("--connect-timeout 10\n--max-time 120\n")
    handle.write("--retry 2\n--retry-connrefused\n")

status_path = os.path.join(work, "fetch-" + label + ".status")
with open(status_path, "w", encoding="utf-8") as out:
    # Not `--fail`: a 404 is an answer this gate reports, not an error that
    # should stop the fetch of the other pages. curl's own exit code is read
    # anyway, below, for the transport failures that are not answers.
    finished = subprocess.run(
        [
            "curl",
            "--parallel",
            "--parallel-max",
            str(parallel),
            "--write-out",
            "%{http_code} %{size_download} %{url}\n",
            "--config",
            config,
        ],
        stdout=out,
        stderr=subprocess.PIPE,
    )
answered = {}
with open(status_path, encoding="utf-8") as handle:
    for line in handle:
        parts = line.split()
        # `--compressed` is on, so the byte count is what crossed the wire and
        # not what the file expands to — the number a caller is spending.
        if len(parts) == 3:
            answered[parts[2]] = (parts[0], int(parts[1]))


def answer_for(page):
    """curl echoes the URL it was given, but a non-ASCII path can come back
    percent-encoded, so both spellings are tried before a page is called
    unanswered."""
    for spelling in (page, urllib.parse.quote(page, safe=":/?#[]@!$&'()*+,;=~"),
                     urllib.parse.unquote(page)):
        if spelling in answered:
            return answered[spelling]
    return None


codes = {}
wire_bytes = 0
for page in pages_wanted:
    answer = answer_for(page)
    if answer is not None:
        codes[page] = answer[0]
        wire_bytes += answer[1]

# What was answered against what was asked, which is what makes the numbers below
# mean anything: curl exiting 0 says nothing about how many of the URLs in its
# config file it got to.
unanswered = [page for page in pages_wanted if page not in codes]
if unanswered:
    print(
        "%s: curl exited %d and answered for %d of %d page(s) — the run cannot say "
        "whether the rest resolve, so it is not reporting that they do"
        % (label, finished.returncode, len(answered), len(pages_wanted)),
        file=sys.stderr,
    )
    for page in unanswered[:5]:
        print("  no answer  %s" % page, file=sys.stderr)
    if finished.stderr:
        print(finished.stderr.decode("utf-8", "replace").strip()[:2000], file=sys.stderr)
    sys.exit(1)

dead = []
pages_ok = 0
anchors_checked = 0
for page in pages_wanted:
    code = codes[page]
    where = sorted({entry[0] for entries in links.values() for entry in entries
                    if entry[1] == page})
    if code != "200":
        for anchor in sorted(anchors_wanted.get(page, {""})):
            url = page + ("#" + anchor if anchor else "")
            dead.append(
                "DEAD  %s  page HTTP %s  (written by %s)"
                % (url, code, where[0] if where else "?")
            )
        continue
    pages_ok += 1
    with open(bodies[page], encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    ids = {html.unescape(found) for found in ID.findall(text)}
    for anchor in sorted(anchors_wanted.get(page, set())):
        anchors_checked += 1
        if anchor not in ids:
            dead.append(
                "DEAD  %s#%s  page HTTP 200, no id=\"%s\" on it  (written by %s)"
                % (page, anchor, anchor, where[0] if where else "?")
            )

leaked = []
leaked_names = set()
fell_back_total = 0
fallback_linked = 0
fallback_unlinked = 0
fallback_unpinned = 0
for root in sorted(fallback):
    prefix = source_base.get(root, "")
    for name in fallback[root]:
        fell_back_total += 1
        # (a) the site must not have sent anyone to that name's documentation
        #     page, whatever that page answers.
        for where, url in sorted(documented_here.get(name, set())):
            leaked_names.add(name)
            leaked.append(
                "LEAKED  %s  the table did not hold this name, and %s links it at "
                "%s instead of %s's version-pinned source"
                % (name, where, url, root)
            )
        # (b) where it is linked at all, by the text the renderer wrote, the
        #     href has to be that root's pinned source.
        found = by_text.get(name, set())
        if not found:
            fallback_unlinked += 1
            continue
        if not prefix:
            fallback_unpinned += 1
            continue
        fallback_linked += 1
        for where, href in sorted(found):
            # A documentation href is (a)'s to report; saying it twice would
            # make one defect look like two.
            if href.startswith(base + "/") or href.startswith(prefix + "/"):
                continue
            leaked_names.add(name)
            leaked.append(
                "LEAKED  %s  %s links it at %s, which is neither %s's "
                "version-pinned source (%s) nor a documentation page"
                % (name, where, href, root, prefix)
            )

lines = [
    "site               %s" % pages,
    "html files read    %d" % files_read,
    "hrefs at %-9s %d distinct (%d occurrence(s))"
    % (base.rsplit("/", 1)[-1], len(links),
       sum(len(entries) for entries in links.values())),
    "distinct pages     %d fetched, %d answered 200 (%d B over the wire)"
    % (len(pages_wanted), pages_ok, wire_bytes),
    "distinct anchors   %d checked against the served HTML" % anchors_checked,
]
# Both denominators, per root, so that a run whose fallback set came out empty
# is visible as such rather than as a pass.
for root in sorted(by_root):
    entry = by_root[root]
    lines.append(
        "%-18s %d requested: %d verified -> docs, %d fell back -> source"
        % (root, entry["requestedNames"], len(entry["declarations"]),
           len(fallback.get(root, [])))
    )
lines.append(
    "fallback checked   %d name(s): %d linked and checked against the pinned "
    "source, %d not linked from any page, %d in a root with no pinned source"
    % (fell_back_total, fallback_linked, fallback_unlinked, fallback_unpinned)
)
lines.append("dead links         %d" % len(dead))
lines.append("leaked fallbacks   %d name(s), %d occurrence(s)"
             % (len(leaked_names), len(leaked)))
with open(report, "w", encoding="utf-8") as handle:
    for line in lines + dead + leaked + problems:
        handle.write(line + "\n")
# `--inject` reads this so that the link it breaks is one the site demonstrably
# wrote: breaking a map entry nothing links to would produce a tree with no dead
# link in it, and the gate would then fail for having *not* found one.
with open(report + ".urls", "w", encoding="utf-8") as handle:
    for url in sorted(links):
        handle.write(url + "\n")
for line in lines:
    print(line)
if fell_back_total == 0:
    print("fallback branch    NOT EXERCISED — every requested name was in the "
          "table, so nothing here checked the source fallback")

# A tree whose anchors were all unchecked passes the loop above without looking
# at anything, and every href this site wrote into a declaration carries one, so
# zero is not a state a real run reaches.
if anchors_checked == 0:
    print(
        "%s: %d page(s) were fetched and not one anchor was checked — the links "
        "carry no #fragment, so this run verified pages only"
        % (label, len(pages_wanted)),
        file=sys.stderr,
    )
    sys.exit(1)

for problem in problems:
    print(problem, file=sys.stderr)
for line in (dead + leaked)[:40]:
    print(line, file=sys.stderr)
if len(dead) + len(leaked) > 40:
    print("  … and %d more (all of them in %s)"
          % (len(dead) + len(leaked) - 40, report), file=sys.stderr)
if dead:
    print(
        "%s: a link this run wrote to a dependency's documentation site does not "
        "exist there (%d of %d distinct link(s))" % (label, len(dead), len(links)),
        file=sys.stderr,
    )
if leaked:
    print(
        "%s: a name the declaration table did not hold was linked at the "
        "documentation site anyway (%d of %d fallen-back name(s), %d occurrence(s))"
        % (label, len(leaked_names), fell_back_total, len(leaked)),
        file=sys.stderr,
    )
if dead or leaked or problems:
    sys.exit(1)
PY
}

say "2/4 fetch what every href points at, and read the fallback names out of the same HTML"
check_status=0
check_site real "$SITE_OUT/site" "$OUT/report-real.txt" "$MAP" || check_status=$?
if [ "$check_status" -ne 0 ]; then
  echo "DEPS DOCS GATE: FAIL — see $OUT/report-real.txt" >&2
  KEEP=1
  exit 1
fi

if [ -n "$INJECT" ]; then
  say "3/4 --inject $INJECT — break one thing on purpose and check that tree"
  # Only copies under this work area are rewritten: nothing to restore, and no
  # `git checkout` to get wrong.
  python3 - "$MAP" "$OUT/injected-map.json" "$INJECT" "$ROOT_LIST" "$BASE" \
    "$OUT/report-real.txt.urls" <<'PY'
import json
import sys

src, dst, mode, root_list, base, inventory = sys.argv[1:7]
base = base.rstrip("/")
roots = [name for name in root_list.split(",") if name]
with open(inventory, encoding="utf-8") as handle:
    written = {line.strip() for line in handle if line.strip()}
with open(src, encoding="utf-8") as handle:
    record = json.load(handle)
for entry in record.get("roots", []):
    if entry["root"] not in roots:
        continue
    # A name whose href the real site demonstrably wrote, so that the break is on
    # a page and the checker has to meet it.
    candidates = [
        name
        for name, link in sorted(entry.get("declarations", {}).items())
        if base + "/" + link.lstrip("./") in written
    ]
    if not candidates:
        continue
    name = candidates[0]
    was = entry["declarations"][name]
    page, _, _anchor = was.partition("#")
    if mode == "anchor":
        # A declaration renamed inside a module that still exists: the page is
        # served, the anchor is not on it — the half a page-only check misses.
        entry["declarations"][name] = page + "#litedoc4GateNoSuchDeclaration"
        now = entry["declarations"][name]
    elif mode == "page":
        entry["declarations"][name] = "Mathlib/Litedoc4Gate/NoSuchModule.html#" + name
        now = entry["declarations"][name]
    else:
        # The reference map loses a name the real pages link at its real
        # documentation page, so the reference says "this one fell back" while
        # the HTML says otherwise. Nothing about that href is broken, which is
        # the point: branch 1 checks hrefs.
        del entry["declarations"][name]
        now = "(removed from the reference map)"
    with open(dst, "w", encoding="utf-8") as handle:
        json.dump(record, handle)
        handle.write("\n")
    print("injected  %s (%s): %s -> %s" % (name, entry["root"], was, now))
    sys.exit(0)
sys.exit("no declaration in the resolved map is linked from the site, so "
         "breaking one would not reach a page")
PY

  if [ "$INJECT" = fallback ]; then
    # No re-render: the pages under test are the real ones, and the only thing
    # that moved is what the run claims it resolved.
    INJECT_PAGES="$SITE_OUT/site"
  else
    SOURCE_URL="$(python3 - "$OUT/build.log" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
found = re.search(r"^source\s+(\S+://\S+)$", text, re.M)
print(found.group(1) if found else "")
PY
)"
    [ -n "$SOURCE_URL" ] || { echo "no source URL in $OUT/build.log" >&2; exit 1; }

    rm -rf "$OUT/injected"
    render_status=0
    "$LITEDOC4" render --ir "$SITE_OUT/ir" --pages "$OUT/injected" \
      --source-url "$SOURCE_URL" --link-index "$SITE_OUT/link-index.lidx" \
      --root "$TARGET" --lake "$LAKE" \
      --deps-docs-map "$OUT/injected-map.json" > "$OUT/injected.log" 2>&1 || render_status=$?
    if [ "$render_status" -ne 0 ]; then
      echo "the injected render failed (exit $render_status):" >&2
      tail -25 "$OUT/injected.log" >&2
      KEEP=1
      exit 1
    fi
    INJECT_PAGES="$OUT/injected"
  fi

  inject_status=0
  check_site injected "$INJECT_PAGES" "$OUT/report-injected.txt" \
    "$OUT/injected-map.json" || inject_status=$?
  if [ "$inject_status" -eq 0 ]; then
    echo "DEPS DOCS GATE: FAIL — the injected fault was not reported, so this" >&2
    echo "gate passes whatever the site links at and is worth nothing" >&2
    KEEP=1
    exit 1
  fi
  echo
  echo "the injected fault was reported (exit $inject_status), which is what --inject asks for"
fi

say "4/4 summary"
cat "$OUT/report-real.txt"
printf 'out                %s\n' "$OUT"

echo
if grep -q '^leaked fallbacks   0 name' "$OUT/report-real.txt" &&
   grep -qE '^fallback checked   0 name' "$OUT/report-real.txt"; then
  echo "DEPS DOCS GATE: ok (branch 2 not exercised — no name fell back)"
else
  echo "DEPS DOCS GATE: ok"
fi
