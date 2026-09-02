#!/usr/bin/env python3
"""Hold litedoc4's output against doc-gen4's own reference tree.

Three questions, and they are the only checks anywhere in this repository that
grade litedoc4 against an implementation nobody here wrote. They used to be
`#[ignore]`d Rust tests; `crates/` left HEAD on 2026-09-02 and took them with it
(`docs/verification-log.md`, "M10 step E"). The bodies are readable at
`git show rust-frozen:crates/litedoc4-render/tests/pages.rs` (line 583) and
`git show rust-frozen:crates/litedoc4/src/packages.rs` (lines 775 and 896).

**This is a one-shot, not a gate, and it cannot become one.** doc-gen4 is not in
the measurement target's manifest, so `lake update` or a `.lake` wipe there
destroys the oracle for good and nothing can re-mint it. A standing comparator
over a dying oracle would have to grow an exception list, which is the shape
CLAUDE.md forbids. What it is for is to answer, once, whether the promise in
`tools/public-surface.txt` — "page paths and declaration anchors keep doc-gen4's
shape" — is true at the target's scale rather than only over the 49 frozen files
of `e2e/micro-expected`, which are minted from litedoc4's own output and so
cannot say whose shape it was to begin with.

**Python, on purpose.** CLAUDE.md: do not rewrite an oracle in the same language
with the same design, which is why the site check is Python too.

**Which half of question 3's answer is litedoc4's.** Every URL in questions 1 and
2 is litedoc4's own — the pages come out of `litedoc4 site` and the roots out of
`litedoc4 links`, whose `url`/`moduleUrl` columns are `ExternalLinks.urlFor`
itself. Question 3 asks about ~500k declaration names, and no command prints a
URL per name, so this script composes them from litedoc4's resolved bases and
litedoc4's own `.lidx`. What that leaves to the comparator is two lines of string
building (`base/Mod/Ule.lean#L<a>-L<b>`); what stays litedoc4's is everything
that can actually be wrong — which revision each root is pinned to, which module
a name belongs to, and the line range the extractor recorded. The composition is
not taken on trust either: it is run against every `url`/`moduleUrl` question 2
already has from `urlFor`, and the count of those agreements is reported.

usage: docgen4-compare.py --ir DIR --site DIR --tree DIR --lidx FILE
                          --links JSON --oracle TSV
"""
import argparse
import difflib
import json
import pathlib
import re
import sys

ENTITIES = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&#39;", "'")]


def unescape_html(name):
    """The five entities doc-gen4's escape produces, undone. `&amp;` last, so a
    name that really contains `&lt;` is not turned into `<`."""
    for entity, ch in ENTITIES:
        if entity in name:
            name = name.replace(entity, ch)
    return name.replace("&amp;", "&") if "&amp;" in name else name


def attr_after(html, marker):
    """Every attribute value that follows `marker`, in document order."""
    out = []
    at = html.find(marker)
    while at >= 0:
        start = at + len(marker)
        end = html.find('"', start)
        if end < 0:
            end = len(html)
        out.append(html[start:end])
        at = html.find(marker, end)
    return out


def text_of(html):
    """Tags dropped, whitespace collapsed."""
    out = []
    rest = html
    while rest:
        at = rest.find("<")
        if at < 0:
            out.append(rest)
            break
        out.append(rest[:at])
        end = rest.find(">", at)
        if end < 0:
            break
        rest = rest[end + 1:]
    return " ".join("".join(out).split())


def wrapped_texts(html, opening):
    """No nesting count is needed: a rendered docstring contains no `<div>`
    (`MD_FLAG_NOHTML`), so the first close is the wrapper's."""
    out = []
    at = html.find(opening)
    while at >= 0:
        start = at + len(opening)
        end = html.find("</div>", start)
        if end < 0:
            end = len(html)
        out.append(text_of(html[start:end]))
        at = html.find(opening, end)
    return out


def source_files(html, markers):
    """The paths those source links name, with the revision and the line range
    dropped — the part that does not move when the package's sources are edited.
    The tree on disk is older than the IR, so a shared declaration whose `.lean`
    file was edited has a legitimately different `#L…-L…`."""
    out = set()
    for marker in markers:
        for href in attr_after(html, marker):
            path = href.split("#", 1)[0]
            if "/blob/" not in path:
                continue
            after_blob = path.split("/blob/", 1)[1]
            if "/" not in after_blob:
                continue
            out.add(after_blob.split("/", 1)[1])
    return out


def first_blob_url(html):
    """The first `https://github.com/…/blob/…` href, with any line anchor kept.
    On a doc-gen4 page that is the nav's `gh_nav_link`: the *module's* own source
    file, so no anchor — exactly what `urlFor(module, none)` builds."""
    at = html.find("https://github.com/")
    if at < 0:
        return None
    end = html.find('"', at)
    if end < 0:
        return None
    url = html[at:end]
    return url if "/blob/" in url else None


def page_path(module):
    return module.replace(".", "/") + ".html"


def compose(base, module, line_range):
    """`Litedoc4.External.sourceUrlAt`, which is the two lines this comparator
    owns. Validated against `urlFor`'s own answers below."""
    url = base + "".join("/" + part for part in module.split(".")) + ".lean"
    if line_range is None:
        return url
    return f"{url}#L{line_range[0]}-L{line_range[1]}"


def read_lidx(path):
    """`Litedoc4.Render.LinkIndex.parseLidx`: `#` is a comment, `@<module>` is a
    module the index holds, a tab-led line is `<name>\\t<from>\\t<to>` in the
    current group, and anything else opens a group named by a module. A `0`
    start line means "held, but with no range"."""
    names = {}
    modules = set()
    group = ""
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            if line.startswith("@"):
                modules.add(line[1:])
            elif line.startswith("\t"):
                fields = line[1:].split("\t")
                name = fields[0]
                span = None
                if len(fields) >= 3 and fields[1].isdigit() and fields[2].isdigit():
                    start, stop = int(fields[1]), int(fields[2])
                    if start != 0:
                        span = (start, stop)
                names[name] = (group, span)
            else:
                group = line
    return names, modules


def tokens(text):
    """The words a comparison can be made of: three word-characters or more.

    Punctuation is dropped because the three texts are punctuated differently by
    construction — the source is Markdown, doc-gen4's page is one rendering of it
    and litedoc4's is another — so `(Cover-Thomas)` and `(Cover-Thomas` are the
    same evidence about content and differ only in where a diff cut them."""
    return set(re.findall(r"\w{3,}", text, re.UNICODE))


def explain(theirs, ours, source):
    """Why do these two renderings of one module docstring differ?

    `"math"`, `"older"`, or `None` for "nothing here explains it", which is the
    only answer that fails. **Not an exception list**: both tests are questions
    about a third party — the IR's own `moduleDocs`, which the extractor read out
    of the target's *current* sources — and both fail closed.

      - a word litedoc4 shows that neither doc-gen4 nor the source has is
        **invented**, and
      - a word doc-gen4 shows that the source still has and litedoc4 does not is
        **dropped**.

    Anything left is the tree being older than the sources it was built from,
    which is the same reason the source links' `#L…-L…` ranges are not compared
    at all. **What it gives up is order**: two texts made of the same words in a
    different arrangement are not told apart. Nothing observed does that, and the
    1,060 identical docstrings are compared as sequences.

    The math case is first because it fails the other two tests by design:
    doc-gen4 emits the docstring's LaTeX for the browser to typeset, litedoc4
    renders MathML server-side (MathML4Lean, decided 2026-08-30), so one page's
    text carries `\\le` where the other carries `≤`. Its members are listed in the
    report rather than tolerated silently, so a third page joining them is a new
    fact and not this one."""
    source_words, theirs_words, ours_words = tokens(source), tokens(theirs), tokens(ours)
    if "$" in source and "$" in theirs and theirs_words - ours_words:
        return "math"
    if ours_words - theirs_words - source_words:
        return None
    if (theirs_words & source_words) - ours_words:
        return None
    return "older"


def question_one(ir, site, tree, report):
    """Every page doc-gen4 also has carries its declaration anchors, as a set and
    in order; its module docstrings; and its source links' file paths.

    **Every bucket is printed with its denominator and only the unexplained ones
    fail** — the shape question 3 already had. The tree is a snapshot of one build
    of a repository outside this one, so a disagreement is a claim about two
    things at once, and the buckets are what separate them: a name doc-gen4 has
    that today's IR does not is the tree being older, and a name today's IR has
    that litedoc4 did not render is litedoc4's."""
    index = json.loads((ir / "index.json").read_text(encoding="utf-8"))
    positions, docs_source, decl_names = {}, {}, set()
    for entry in index["modules"]:
        module = json.loads((ir / entry["file"]).read_text(encoding="utf-8"))
        declarations = module.get("declarations") or []
        positions[entry["module"]] = {d["name"]: (d["line"], d["col"]) for d in declarations}
        decl_names.update(d["name"] for d in declarations)
        docs_source[entry["module"]] = " ".join(
            d["text"] for d in module.get("moduleDocs") or [])

    pages = anchors = docs = 0
    unpaged, reordered, identical_docs = [], [], 0
    gone, moved, stale_docs, math_docs = [], [], [], []
    failures = []
    for entry in index["modules"]:
        module = entry["module"]
        ours = site / page_path(module)
        theirs = tree / page_path(module)
        if not theirs.is_file():
            # A module doc-gen4 has no page for was added to the package after
            # its tree was last built.
            unpaged.append(module)
            continue
        if not ours.is_file():
            failures.append(f"{module}: the render wrote no page and doc-gen4 has one")
            continue
        want = theirs.read_text(encoding="utf-8")
        got = ours.read_text(encoding="utf-8")
        pages += 1

        want_ids = attr_after(want, '<div class="decl" id="')
        got_ids = attr_after(got, '<section class="decl" id="')
        anchors += len(want_ids)
        here = positions.get(module, {})
        extra = [g for g in got_ids if g not in want_ids]
        if extra:
            failures.append(f"{module}: litedoc4 rendered {extra[:8]}, which doc-gen4 has no "
                            "anchor for")
        for name in (w for w in want_ids if w not in got_ids):
            if name in here:
                failures.append(f"{module}: doc-gen4 has an anchor for {name}, which is in "
                                "today's IR for this module and which litedoc4 did not render")
            elif name in decl_names:
                moved.append(name)
            else:
                gone.append(name)
        if not extra and sorted(want_ids) == sorted(got_ids) and want_ids != got_ids:
            # Only doc-gen4's unstable sort may explain this: its
            # `Process.Module.members` finishes with a non-stable `qsort`, so two
            # declarations at one `(line, col)` come out in an order that is a
            # property of the run. The two orders must walk the same positions.
            if [here.get(n) for n in want_ids] != [here.get(n) for n in got_ids]:
                failures.append(f"{module}: the page order differs somewhere other than a tie")
            reordered.append(module)

        want_docs = wrapped_texts(want, '<div class="mod_doc">')
        got_docs = wrapped_texts(got, '<div class="moddoc">')
        docs += len(want_docs)
        if len(want_docs) != len(got_docs):
            failures.append(f"{module}: {len(want_docs)} module docstring(s) against "
                            f"{len(got_docs)}")
        else:
            source = docs_source.get(module, "")
            for a, b in zip(want_docs, got_docs):
                if a == b:
                    identical_docs += 1
                    continue
                why = explain(a, b, source)
                if why == "math":
                    math_docs.append(module)
                elif why == "older":
                    stale_docs.append(module)
                else:
                    failures.append(
                        f"{module}: a module docstring differs and neither the tree's age nor "
                        f"MathML explains it\n  theirs: {a[:200]!r}\n  ours:   {b[:200]!r}")

        want_files = source_files(
            want, ['class="gh_link"><a href="', 'class="gh_nav_link"><a href="'])
        got_files = source_files(got, ['<a class="src" href="'])
        if want_files != got_files:
            failures.append(
                f"{module}: the source links name different files\n"
                f"  want: {sorted(want_files)}\n  got:  {sorted(got_files)}")

    report(f"Q1  {pages} shared page(s), {anchors} anchor(s), {docs} module docstring(s); "
           f"{len(unpaged)} module(s) doc-gen4 has no page for")
    report(f"Q1  anchors: {len(gone)} doc-gen4 has that today's IR does not "
           f"({sorted(gone)}), {len(moved)} that moved to another module ({sorted(moved)})")
    report(f"Q1  reordered by doc-gen4's unstable sort: {reordered}")
    report(f"Q1  module docstrings: {identical_docs} identical, {len(stale_docs)} where the "
           f"target's text moved after the tree was built, {len(math_docs)} where doc-gen4 "
           f"ships LaTeX and litedoc4 ships MathML ({sorted(set(math_docs))})")
    report("Q1  source-link file paths: every shared page agrees"
           if not any("source links" in f for f in failures) else
           "Q1  source-link file paths: SOME PAGE DISAGREES")
    # A run that matched nothing would satisfy every comparison above.
    if pages < 300 or anchors < 3000 or docs < 1000:
        failures.append(
            f"{pages} pages, {anchors} anchors, {docs} docstrings: the tree stopped "
            "overlapping the IR, so the comparisons above ran on almost nothing")
    return failures


def question_two(tree, links, report):
    """Every root litedoc4 resolves produces the URL doc-gen4 itself wrote."""
    rows = links["rows"]
    checked = {}
    unpaged = []
    failures = []
    composed_agreements = 0
    for row in rows:
        root, base = row["root"], row["base"]
        asked = 0
        for module, got in ((root, row["url"]), (row["module"], row["moduleUrl"])):
            if module is None or got is None:
                continue
            asked += 1
            if base and compose(base, module, None) == got:
                composed_agreements += 1
            path = tree / page_path(module)
            if not path.is_file():
                continue
            want = first_blob_url(path.read_text(encoding="utf-8"))
            if want is None:
                continue
            if want == got:
                checked[root] = module
            else:
                failures.append(f"  {module}\n    want: {want}\n    got:  {got}")
        if asked and root not in checked:
            # Counted, not passed over: the target's site documents its own
            # import closure, not every package in its manifest.
            unpaged.append(root)

    report(f"Q2  {len(checked)} of {len(rows)} root(s) checked against doc-gen4: "
           f"{sorted(checked)}")
    report(f"Q2  {len(unpaged)} root(s) the tree has no page for: {unpaged}")
    report(f"Q2  {composed_agreements} composed URL(s) agree with ExternalLinks.urlFor")
    if not checked:
        failures.append("no root was compared at all")
    # Named, so a shrinking sample cannot hide a prefix shape: a package, core's
    # `/src`, and core's `/src/lake`, which is not `/src`.
    for shape in ("Mathlib", "Init", "Lake"):
        if shape not in checked:
            failures.append(f"{shape} was not among the roots checked, so its prefix shape "
                            "went unasked")
    return failures, composed_agreements


def question_three(lidx_path, oracle_path, links, report):
    """For every name the `.lidx` carries, the source URL built out of it is the
    one doc-gen4 wrote on that declaration's page.

    **Only the mismatch bucket is a failure.** The two populations are not the
    same set — the `.lidx` is the environment this extraction loaded, the oracle
    is whatever pages that doc-gen4 build happened to write — so every bucket is
    printed with its denominator and only a name they *both* have and disagree
    about fails."""
    names, _ = read_lidx(lidx_path)
    bases = {row["root"]: row["base"] for row in links["rows"] if row["base"]}

    wanted = {}
    oracle_lines = collisions = 0
    with open(oracle_path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            oracle_lines += 1
            # doc-gen4 writes the name into an HTML attribute, so `<` `>` `&`
            # arrive escaped; the `.lidx` writes `Name.toString`.
            name = unescape_html(parts[0])
            if name in wanted:
                collisions += 1
            wanted[name] = parts[1]

    matched = unlinkable = 0
    mismatched = []
    lidx_only = []
    seen = set()
    ranged = 0
    for name, (module, span) in names.items():
        if span is not None:
            ranged += 1
        base = bases.get(module.split(".", 1)[0]) if module else None
        if base is None:
            # The package being documented: a map that does not hold the root is
            # how that is said.
            unlinkable += 1
            continue
        got = compose(base, module, span)
        want = wanted.get(name)
        if want is None:
            lidx_only.append(name)
            continue
        seen.add(name)
        if got == want:
            matched += 1
        else:
            mismatched.append(f"  {name}\n    want: {want}\n    got:  {got}")

    oracle_only = []
    oracle_unlinkable = 0
    for name in wanted:
        if name in seen:
            continue
        if name in names:
            oracle_unlinkable += 1
        else:
            oracle_only.append(name)

    # A `.lidx` entry whose *parent* is in the oracle is a structure field or a
    # constructor, which doc-gen4 renders inside the parent's `decl` div, so the
    # oracle has nothing to compare against.
    nested = sum(1 for name in lidx_only
                 if "." in name and name.rsplit(".", 1)[0] in wanted)
    absent_roots = {}
    for name in oracle_only:
        head = name.split(".", 1)[0]
        absent_roots[head] = absent_roots.get(head, 0) + 1
    top = sorted(absent_roots.items(), key=lambda kv: -kv[1])[:5]

    linkable = matched + len(mismatched) + len(lidx_only)
    report(f"Q3  .lidx entries                        : {len(names)}")
    report(f"Q3    under a root the map resolves      : {linkable}")
    report(f"Q3      matched                          : {matched}")
    report(f"Q3      mismatched                       : {len(mismatched)}")
    report(f"Q3      not in the oracle                : {len(lidx_only)} "
           f"({nested} have a parent that is)")
    report(f"Q3    under a root the map does not hold : {unlinkable}")
    report(f"Q3  oracle entries                       : {len(wanted)} "
           f"({oracle_lines} lines, {collisions} collision(s) after unescaping)")
    report(f"Q3    not in the .lidx at all            : {len(oracle_only)}")
    report(f"Q3    in the .lidx, root not in the map  : {oracle_unlinkable}")
    report(f"Q3  .lidx entries with a line range      : {ranged} of {len(names)}")
    report(f"Q3  the names the .lidx does not have, by first component: {top}")
    report(f"Q3  .lidx-only sample : {', '.join(lidx_only[:6])}")
    report(f"Q3  oracle-only sample: {', '.join(oracle_only[:6])}")

    failures = []
    if mismatched:
        failures.append(
            f"{len(mismatched)} of {linkable} resolvable .lidx entries disagree with "
            "doc-gen4:\n" + "\n".join(mismatched[:20]))
    if matched == 0:
        failures.append("nothing was compared")
    return failures


def main():
    parser = argparse.ArgumentParser(add_help=True)
    for flag in ("--ir", "--site", "--tree", "--lidx", "--links", "--oracle"):
        parser.add_argument(flag, required=True)
    args = parser.parse_args()

    lines = []

    def report(line):
        lines.append(line)
        print(line, flush=True)

    links = json.loads(pathlib.Path(args.links).read_text(encoding="utf-8"))
    failures = question_one(pathlib.Path(args.ir), pathlib.Path(args.site),
                            pathlib.Path(args.tree), report)
    two, _ = question_two(pathlib.Path(args.tree), links, report)
    failures += two
    failures += question_three(args.lidx, args.oracle, links, report)

    if failures:
        print(f"\nDOCGEN4 COMPARE: {len(failures)} disagreement(s)", file=sys.stderr)
        for failure in failures[:12]:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print("\nDOCGEN4 COMPARE: ok — three questions, no disagreement")
    return 0


if __name__ == "__main__":
    sys.exit(main())
