#!/usr/bin/env python3
"""The questions the single-version site gates asked, asked of a site
`litedoc4 store render` wrote, read out of its gzip data files.

tools/mv-s-gate.sh runs it over S and reads one `ok|FAIL <item>: <what>` line
per item, every version of the render:

  render-usedby      IR refs between the package's declarations ⟺ the per-module
                     Used-by files, both ways
  render-closure     index subscripts resolve, instance values are indexed names,
                     nothing loads from another host
  render-content-ir  the content's sorry and origin are the IR's
  render-summaries   a module row is described exactly when its docstring opens
                     with a heading
  render-math        Example.Math's formulas converted, the unreadable one kept
  render-references  one reference per bibliography entry; back-references ⟺
                     the content's citation links
  render-sources     every source link names a file, and a line range inside it,
                     in the version's own commit

Python, and not litedoc4's readers: an oracle written in the writer's language
with its design makes the writer's mistakes.

usage:
  check-store-render.py --site <render> --repo <S repository> --builds <dir>
                        --versions v1,v2,...
    --builds  holds <version>/ir, the IR each version was rendered from
  check-store-render.py --site <render> --print-index
    every version's search index as {version: [[name, module], ...]}, for
    benchmarks/tools/check-mv-pages.ts to hold against the drawn pages

The index is decoded by check-site-closure.py's reader, the one reader of the
format that is neither its writer nor the site's own.
"""

import argparse
import collections
import gzip
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
RESOURCE = re.compile(r'<(?:script\b[^>]*\bsrc|link\b[^>]*\bhref)="([^"]*)"', re.IGNORECASE)
EXTERNAL = re.compile(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:)?//")
CSS_URL = re.compile(r"(?:url\(\s*['\"]?|@import\s+['\"])([^'\")\s]+)")
CITE = re.compile(r'<a href="references\.html#ref_([^"]*)"[^>]*\bdata-cite\b')
MATH = re.compile(r"<math[^>]*>.*?</math>", re.S)


def say(ok, name, what):
    print("%s %s: %s" % ("ok" if ok else "FAIL", name, what))


def check(name, body):
    try:
        ok, what = body()
    except Exception as e:
        ok, what = False, "could not be asked: %r" % (e,)
    say(ok, name, what)


def few(xs, n=4):
    xs = sorted(xs)
    return "; ".join(str(x) for x in xs[:n]) + ("; and %d more" % (len(xs) - n) if len(xs) > n else "")


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo)] + list(args), check=True,
                          capture_output=True, text=True).stdout


def unescape_component(s):
    return s[1:-1] if len(s) >= 2 and s.startswith("«") and s.endswith("»") else s


def module_path(module):
    out, depth, start = [], 0, 0
    for i, c in enumerate(module):
        if c == "«":
            depth += 1
        elif c == "»":
            depth -= 1
        elif c == "." and depth == 0:
            out.append(unescape_component(module[start:i]))
            start = i + 1
    out.append(unescape_component(module[start:]))
    return "/".join(out)


def load_closure_reader():
    spec = importlib.util.spec_from_file_location("check_site_closure", HERE / "check-site-closure.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.read_search_index


class Site:
    def __init__(self, root, builds, versions):
        self.root = pathlib.Path(root)
        self.builds = pathlib.Path(builds)
        listed = json.loads((self.root / "versions.json").read_text(encoding="utf-8"))
        self.listed = {e["name"]: e for e in listed}
        if sorted(self.listed) != sorted(versions):
            raise SystemExit("versions.json lists %s, expected %s" % (sorted(self.listed), versions))
        self.versions = versions
        self._index = {}
        self._ir = {}

    def data(self, address, ext="json"):
        raw = gzip.decompress((self.root / "d" / ("%s.%s.gz" % (address, ext))).read_bytes())
        return raw if ext == "bin" else json.loads(raw.decode("utf-8"))

    def version_file(self, v):
        return self.data(self.listed[v]["data"])

    def modules(self, v):
        return self.data(self.version_file(v)["modules"])["modules"]

    def shell_attr(self, v, rel, key):
        text = (self.root / v / rel).read_text(encoding="utf-8")
        m = re.search(r' data-%s="([0-9a-f]+)"' % key, text)
        if not m:
            raise RuntimeError("%s/%s has no data-%s" % (v, rel, key))
        return m.group(1)

    def pages(self, v):
        for m in self.modules(v):
            page = self.data(self.shell_attr(v, m["p"], "page"))
            content = [] if page["content"] is None else self.data(page["content"])
            yield m, page, content

    def index(self, v):
        if v not in self._index:
            raw = self.data(self.version_file(v)["search"], "bin")
            scratch = tempfile.mkdtemp()
            try:
                with open(os.path.join(scratch, "search-index.bin"), "wb") as handle:
                    handle.write(raw)
                problems = []
                decoded = READ_SEARCH_INDEX(scratch, problems)
            finally:
                shutil.rmtree(scratch)
            if decoded is None:
                raise RuntimeError("%s's search index: %s" % (v, "; ".join(problems)))
            self._index[v] = decoded
        return self._index[v]

    def ir(self, v):
        if v not in self._ir:
            out = {}
            for path in sorted((self.builds / v / "ir" / "modules").glob("*.json")):
                out[path.name] = json.loads(path.read_text(encoding="utf-8"))
            if not out:
                raise RuntimeError("no module IR under %s" % (self.builds / v / "ir" / "modules"))
            self._ir[v] = out
        return self._ir[v]


def docs_of(item):
    if "moddoc" in item:
        yield item["moddoc"]
        return
    yield item.get("doc", "")
    for member in item.get("f", []) + item.get("c", []):
        yield member.get("doc", "")


def usedby(site):
    said = []
    for v in site.versions:
        declares, want = {}, {}
        modules = site.ir(v).values()
        for module in modules:
            for decl in module["declarations"]:
                declares[decl["name"]] = module["module"]
        for module in modules:
            for decl in module["declarations"]:
                for _, target in decl.get("refs", []):
                    if target in declares:
                        want.setdefault(target, set()).add((decl["name"], declares[decl["name"]]))
        got, misplaced = {}, []
        for m in site.modules(v):
            for target, users in site.data(site.shell_attr(v, m["p"], "used-by")).items():
                if declares.get(target) != m["n"]:
                    misplaced.append("%s %s in %s's Used-by file" % (v, target, m["n"]))
                got.setdefault(target, set()).update((u, mod) for u, mod in users)
        missing = ["%s %s -> %s" % (v, u, t) for t, us in want.items() for u in us - got.get(t, set())]
        invented = ["%s %s -> %s" % (v, u, t) for t, us in got.items() for u in us - want.get(t, set())]
        edges = sum(len(us) for us in want.values())
        if missing or invented or misplaced or edges == 0:
            return False, "%s: %d IR reference(s) no Used-by file holds (%s); %d Used-by entr(ies) no IR reference supports (%s); %d target(s) in another module's file (%s); %d edges" % (
                v, len(missing), few(missing), len(invented), few(invented), len(misplaced), few(misplaced), edges)
        said.append("%s %d targets / %d edges" % (v, len(want), edges))
    return True, "IR refs between this package's declarations = the per-module Used-by files, both ways, each user with the module that declares it and each target in its own module's file: %s" % ", ".join(said)


def closure(site):
    bad, said = [], []
    for v in site.versions:
        ix = site.index(v)
        modules = site.modules(v)
        names = set(ix["names"])
        rows = list(zip(ix["names"], ix["kind_of"], ix["modules"]))
        bad += ["%s %s: module subscript %d of %d" % (v, n, mi, len(modules)) for n, _, mi in rows if mi >= len(modules)]
        bad += ["%s %s: kind subscript %d of %d" % (v, n, k, len(ix["labels"])) for n, k, _ in rows if k >= len(ix["labels"])]
        declared = site.data(site.version_file(v)["modules"])["declarations"]
        if declared != len(rows):
            bad.append("%s: the module list says %d declarations, the index holds %d" % (v, declared, len(rows)))
        maps = site.data(site.version_file(v)["instances"])
        values = [n for group in maps["instances"].values() for n in group]
        pairs = [n for group in maps["instancesFor"].values() for n in group]
        bad += ["%s instance %s is no indexed declaration" % (v, n) for n in values + pairs if n not in names]
        said.append("%s %d names, %d instance values" % (v, len(rows), len(values) + len(pairs)))
    loads = 0
    for path in sorted(site.root.rglob("*")):
        if path.suffix == ".html":
            urls = RESOURCE.findall(path.read_text(encoding="utf-8"))
        elif path.suffix == ".css":
            urls = CSS_URL.findall(path.read_text(encoding="utf-8"))
        else:
            continue
        loads += len(urls)
        bad += ["%s loads %s" % (path.relative_to(site.root), u) for u in urls if EXTERNAL.match(u)]
    if loads == 0:
        bad.append("no <script src>, <link href> or CSS url() anywhere: nothing was checked for another host")
    if bad:
        return False, "%d: %s" % (len(bad), few(bad))
    return True, "every index row's module and kind subscript resolves, the module list's declaration count is the index's, every instance value is an indexed name (%s); none of %d resource loads in the HTML and CSS names another host" % (
        ", ".join(said), loads)


def content_ir(site):
    bad, compared = [], 0
    for v in site.versions:
        ir = {}
        for module in site.ir(v).values():
            for decl in module["declarations"]:
                ir[(module["module"], decl["name"])] = decl
        on_page = set()
        for m, _, content in site.pages(v):
            for item in content:
                if "n" not in item:
                    continue
                decl = ir.get((m["n"], item["n"]))
                on_page.add((m["n"], item["n"]))
                if decl is None:
                    bad.append("%s %s on %s is no IR declaration of that module" % (v, item["n"], m["n"]))
                    continue
                compared += 1
                if item.get("sorry") != decl.get("sorry"):
                    bad.append("%s %s: sorry %r in the content, %r in the IR" % (v, item["n"], item.get("sorry"), decl.get("sorry")))
                if item.get("gen") != decl.get("generated"):
                    bad.append("%s %s: gen %r in the content, generated %r in the IR" % (v, item["n"], item.get("gen"), decl.get("generated")))
        flagged = [k for k, d in ir.items() if (d.get("sorry") or d.get("generated")) and k not in on_page]
        bad += ["%s %s claims sorry or an origin in the IR and is on no page" % (v, n) for _, n in flagged]
    if bad:
        return False, "%d: %s" % (len(bad), few(bad))
    if compared == 0:
        return False, "no content declaration was compared"
    return True, "sorry and gen of %d content declarations (all versions) equal the IR's sorry and generated, and every IR declaration carrying either is on a page" % compared


def summaries(site):
    bad, said = [], []
    for v in site.versions:
        docs = {m["module"]: m.get("moduleDocs") or [] for m in site.ir(v).values()}
        rows = site.modules(v)
        described = 0
        for row in rows:
            first = docs.get(row["n"])
            if first is None:
                bad.append("%s %s is listed and has no IR" % (v, row["n"]))
                continue
            headed = bool(first) and first[0]["text"].startswith("# ")
            if headed != ("s" in row):
                bad.append("%s %s: docstring opens with a heading %s, row described %s" % (v, row["n"], headed, "s" in row))
            if "s" in row:
                described += 1
                if not row["s"].strip():
                    bad.append("%s %s: an empty description" % (v, row["n"]))
                if row["s"] == row["n"].rsplit(".", 1)[-1]:
                    bad.append("%s %s: the description only repeats the module's name" % (v, row["n"]))
        if sorted(docs) != sorted(r["n"] for r in rows):
            bad.append("%s: the module list is not the IR's modules" % v)
        shapes = [r for r in rows if r["n"] == "Example.Shapes"]
        if not shapes or "<code>Example.Basic</code>" not in shapes[0].get("s", ""):
            bad.append("%s Example.Shapes' description is %r, not its heading's code span rendered" % (
                v, shapes[0].get("s") if shapes else None))
        if described == 0 or described == len(rows):
            bad.append("%s: %d of %d rows described; the sample has a module that opens with prose" % (v, described, len(rows)))
        said.append("%s %d of %d" % (v, described, len(rows)))
    if bad:
        return False, "%d: %s" % (len(bad), few(bad))
    return True, "a module list row carries a description exactly when its IR docstring opens with a heading, none empty or repeating the module's name, Example.Shapes' code span rendered: %s" % ", ".join(said)


def math(site):
    bad, said = [], []
    for v in site.versions:
        found = [c for m, _, c in site.pages(v) if m["n"] == "Example.Math"]
        if not found:
            bad.append("%s has no Example.Math page" % v)
            continue
        docs = "".join(d for item in found[0] for d in docs_of(item))
        counts = (len(re.findall(r"<math>", docs)), docs.count('<math display="block">'), docs.count("<merror"))
        if counts != (3, 1, 0):
            bad.append("%s: inline, block, merror = %s, expected (3, 1, 0)" % (v, counts))
        if "$\\colim_k F(k)$" not in docs:
            bad.append("%s: the unconvertible span is not there as its own source" % v)
        if "$a &lt; b$" in docs:
            bad.append("%s: `$a < b$` was written back as LaTeX" % v)
        for formula in MATH.findall(docs):
            if re.search(r"<(?![/a-zA-Z])", formula) or re.search(r"&(?![a-zA-Z]+;|#[0-9]+;|#x[0-9a-fA-F]+;)", formula):
                bad.append("%s: markup unescaped inside %r" % (v, formula[:60]))
        said.append(v)
    if bad:
        return False, "%d: %s" % (len(bad), few(bad))
    return True, "Example.Math's content in %s: 3 inline and 1 block <math>, no merror, $\\colim_k F(k)$ kept as its source, $a < b$ converted, nothing unescaped inside a formula" % ", ".join(said)


def references(site, repo):
    bad, said = [], []
    for v in site.versions:
        vf = site.version_file(v)
        entries = site.data(vf["references"])
        bib = git(repo, "show", "%s:docs/references.bib" % vf["commit"])
        want = len(re.findall(r"^\s*@\w+\s*\{", bib, re.M))
        if len(entries) != want:
            bad.append("%s: %d references, docs/references.bib at %s holds %d entries" % (v, len(entries), vf["commit"][:12], want))
        cited = collections.Counter()
        for m, _, content in site.pages(v):
            for item in content:
                for doc in docs_of(item):
                    for key in CITE.findall(doc):
                        cited[(m["n"], key)] += 1
        listed = collections.Counter((b[0], e["key"]) for e in entries for b in e["by"])
        if cited != listed or not cited:
            bad.append("%s: citations in the content %s, back-references in the references data %s" % (
                v, sorted(cited.items()), sorted(listed.items())))
        said.append("%s %d entries, %d citations" % (v, len(entries), sum(cited.values())))
    if bad:
        return False, "; ".join(bad)
    return True, "the references data has one entry per @ entry of the version's own docs/references.bib, and its back-references are exactly the data-cite links the content holds, by module and key: %s" % ", ".join(said)


def sources(site, repo):
    slug = re.sub(r"^.*github\.com[:/]", "", git(repo, "config", "--get", "remote.origin.url").strip())
    slug = slug[:-4] if slug.endswith(".git") else slug
    bad, said, dependency = [], [], 0
    for v in site.versions:
        vf = site.version_file(v)
        commit = git(repo, "rev-parse", v).strip()
        want = "https://github.com/%s/blob/%s" % (slug, commit)
        if vf["commit"] != commit or vf["source"] != want:
            bad.append("%s: commit %s, source %s; the tag is %s and the source should be %s" % (v, vf["commit"], vf["source"], commit, want))
            continue
        files = set(git(repo, "ls-tree", "-r", "--name-only", commit).splitlines())
        ranges = 0
        for m, page, _ in site.pages(v):
            path = module_path(m["n"]) + ".lean"
            if path not in files:
                bad.append("%s links %s/%s, which is not in the tree at %s" % (v, want, path, commit[:12]))
                continue
            length = len(git(repo, "show", "%s:%s" % (commit, path)).splitlines())
            for lines in page["lines"]:
                if lines == 0:
                    continue
                ranges += 1
                if not 1 <= lines[0] <= lines[1] <= length:
                    bad.append("%s %s#L%d-L%d: the file has %d lines at %s" % (v, path, lines[0], lines[1], length, commit[:12]))
        dependency += len(vf["roots"])
        said.append("%s %d pages, %d line ranges" % (v, len(site.modules(v)), ranges))
    if bad:
        return False, "%d: %s" % (len(bad), few(bad))
    return True, "every version's source is github.com/%s/blob/<its tag's commit>, each module page's <module path>.lean is in the tree at that commit and every line range fits the file there (%s); %d dependency root bases are other repositories and not resolved here" % (
        slug, ", ".join(said), dependency)


def print_index(root):
    listed = json.loads((pathlib.Path(root) / "versions.json").read_text(encoding="utf-8"))
    site = Site(root, root, [e["name"] for e in listed])
    out = {}
    for v in site.versions:
        modules = site.modules(v)
        ix = site.index(v)
        out[v] = [[n, modules[mi]["n"] if mi < len(modules) else None] for n, mi in zip(ix["names"], ix["modules"])]
    json.dump(out, sys.stdout, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--site", required=True)
    parser.add_argument("--print-index", action="store_true",
                        help="print {version: [[name, module], ...]} decoded from each search index, and nothing else")
    parser.add_argument("--repo")
    parser.add_argument("--builds")
    parser.add_argument("--versions")
    args = parser.parse_args()
    if args.print_index:
        return print_index(args.site)
    if not (args.repo and args.builds and args.versions):
        parser.error("--repo, --builds and --versions are required unless --print-index")
    site = Site(args.site, args.builds, args.versions.split(","))
    check("render-usedby", lambda: usedby(site))
    check("render-closure", lambda: closure(site))
    check("render-content-ir", lambda: content_ir(site))
    check("render-summaries", lambda: summaries(site))
    check("render-math", lambda: math(site))
    check("render-references", lambda: references(site, args.repo))
    check("render-sources", lambda: sources(site, args.repo))


READ_SEARCH_INDEX = load_closure_reader()

if __name__ == "__main__":
    sys.exit(main())
