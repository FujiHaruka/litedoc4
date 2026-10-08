#!/usr/bin/env python3
"""Does an IR tree the .olean reader wrote equal the one the native extractor wrote?

The comparator of tools/reader-hybrid-gate.sh and tools/mv-reader-gate.sh: one
file, so the two cannot come to apply different normalizations. Equal except:
  - the reducibility spelling: the native IR spells it the way its own Lean does
    (tools/lean-toolchains.txt column 2), the reader the way the running Lean
    does; exactly that rename is applied to the native side, and counted
  - `contentHash`, which has to differ exactly where the raw module bytes do
  - `extractorIdentity`: `source=` digests the copy of Extract.lean the reader
    compiles (without `main`), and the reader's fields follow; both predicted

With --classify (benchmarks/tools/mv-m-run.sh --through-reader), the same
exceptions, and then every remaining difference is classified instead of
failing: a field the newest Lean's printer writes (the list is printed) differs
as printer drift, bucketed by cause, with "cause not recognised" its own bucket;
any other field differing, and any module, declaration, member or file on one
side only, is a defect. The report goes to stdout and, in full, to <report.json>.

usage: reader-compare.py [--classify <report.json>]
         <native-ir> <native-lidx> <read-ir> <read-lidx> <lean-version>
         <native-spelling> <running-spelling> <Extract.lean> <cut Extract.lean>
         <reader-identity-file>
Prints one line and exits 0 when equal; prints at most eight differences and
exits 1 otherwise. With --classify: exits 0 when there is no defect, 1 otherwise.
"""

import collections
import json
import pathlib
import re
import sys

args = sys.argv[1:]
report_path = None
if args[:1] == ["--classify"]:
    if len(args) < 2:
        sys.exit(__doc__)
    report_path, args = pathlib.Path(args[1]), args[2:]
if len(args) != 10:
    sys.exit(__doc__)
native, native_lidx, read, read_lidx = (pathlib.Path(p) for p in args[0:4])
version, spelled, running = args[4], args[5].encode(), args[6].encode()
full, cut, reader_identity = (pathlib.Path(p) for p in args[7:10])
problems = []


def fnv(path):
    h = 0xCBF29CE484222325
    for b in path.read_bytes():
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "fnv1a64:%016x" % h


def files(root):
    return {p.relative_to(root).as_posix(): p for p in sorted(root.rglob("*")) if p.is_file()}


def renamed(raw):
    if spelled == running:
        return raw, 0
    return raw.replace(spelled, running), raw.count(spelled)


def index_problems(ni, ri, ignored_module_keys, ignored_dep_keys):
    out = []
    for side, index in (("native", ni), ("reader", ri)):
        if index.get("leanVersion") != version:
            out.append(f"the {side} index names Lean {index.get('leanVersion')!r}, not {version}")
    source_full, source_cut = "source=" + fnv(full), "source=" + fnv(cut)
    native_id = ni.get("extractorIdentity", "")
    if source_full not in native_id.split(" "):
        out.append(f"the native identity does not carry {source_full}: {native_id}")
    reader_fields = [f for f in reader_identity.read_text(encoding="utf-8").split() if f.startswith("reader")]
    want_id = " ".join([source_cut if f == source_full else f for f in native_id.split(" ")] + reader_fields)
    if ri.get("extractorIdentity") != want_id:
        out.append(f"the reader identity is {ri.get('extractorIdentity')!r}, predicted {want_id!r}")
    blank = " ".join(f.split("=")[0] + "=" if f.split("=")[0] in ("lean", "leanGithash") else f for f in want_id.split(" "))
    if reader_identity.read_text(encoding="utf-8").strip() != blank:
        out.append("`reader extract --identity` does not print the run's identity with lean= and leanGithash= blank")
    hashes = 0
    for nm, rm in zip(ni.get("modules", []), ri.get("modules", [])):
        raw_equal = (native / nm["file"]).read_bytes() == (read / rm["file"]).read_bytes()
        if raw_equal != (nm.get("contentHash") == rm.get("contentHash")):
            out.append(f"{nm['module']}: raw bytes {'match' if raw_equal else 'differ'} but contentHash does not follow")
        if "bytes" in ignored_module_keys and raw_equal and nm.get("bytes") != rm.get("bytes"):
            out.append(f"{nm['module']}: raw bytes match but `bytes` does not")
        hashes += nm.get("contentHash") != rm.get("contentHash")

    def strip(ix):
        return {**ix, "extractorIdentity": None,
                "modules": [{k: (None if k in ("contentHash",) + ignored_module_keys else v) for k, v in m.items()}
                            for m in ix.get("modules", [])],
                "dependencyMaps": [{k: (None if k in ignored_dep_keys else v) for k, v in m.items()}
                                   for m in ix.get("dependencyMaps", [])]}
    if strip(ni) != strip(ri):
        keys = sorted(k for k in set(ni) | set(ri) if strip(ni).get(k) != strip(ri).get(k))
        out.append(f"index.json differs beyond the identity and contentHash: {keys}")
    return out, hashes


def exact():
    rewrites = 0
    n, r = files(native), files(read)
    if not n:
        problems.append(f"{native} holds no file")
    for name in sorted(set(n) | set(r)):
        if name not in r:
            problems.append(f"the reader did not write {name}")
            continue
        if name not in n:
            problems.append(f"the reader wrote {name}, the native extractor did not")
            continue
        if name == "index.json":
            continue
        want, count = renamed(n[name].read_bytes())
        rewrites += count
        got = r[name].read_bytes()
        if want != got:
            at = next((i for i, (u, v) in enumerate(zip(want, got)) if u != v), min(len(want), len(got)))
            problems.append(f"{name} differs at byte {at}: native {want[at:at + 60]!r} reader {got[at:at + 60]!r}")
    if native_lidx.read_bytes() != read_lidx.read_bytes():
        problems.append("the link index differs")

    ni = json.loads((native / "index.json").read_text(encoding="utf-8"))
    ri = json.loads((read / "index.json").read_text(encoding="utf-8"))
    found, hashes = index_problems(ni, ri, (), ())
    problems.extend(found)

    if problems:
        for p in problems[:8]:
            print(p)
        sys.exit(1)
    print(f"{len(n)} IR files and the link index equal; reducibility spelling "
          f"{spelled.decode()} -> {running.decode()} applied {rewrites} time(s), "
          f"contentHash differs in {hashes} module(s) exactly where the bytes do, identity as predicted")


PRINTED_DECL = ("type", "typeCode", "binders", "binderCode", "implicits", "equations", "equationCode", "refs")
PRINTED_MEMBER = ("text", "code", "binders", "binderCode", "implicits")
TEXT_OF = {"typeCode": "type", "binderCode": "binders", "equationCode": "equations", "implicits": "binders",
           "code": "text"}
UNRECOGNISED = "cause not recognised"
DEFECT = "defect"
SPELLING = "reducibility spelling (tools/lean-toolchains.txt column 2), renamed on the native side"
TACTICS = "tactics: the reader writes no tactic list (step 5 item 3, open)"

IDENT = re.compile(r"[^\W\d][\w'!?.₀-₉ᵢ-ᵪ]*")
HYGIENE = re.compile(r"✝[⁰¹²³⁴⁵⁶⁷⁸⁹]*")
INST = re.compile(r"\binst_\d+\b|\binst\b")


def ws(s):
    return " ".join(s.split())


def set_builder_opened(s):
    out, i = [], 0
    while True:
        j = s.find("setOf fun ", i)
        if j < 0:
            return "".join(out) + s[i:]
        b = j + len("setOf fun ")
        if s.startswith("(", b):
            depth, e = 0, b
            while e < len(s):
                depth += {"(": 1, ")": -1}.get(s[e], 0)
                if depth == 0:
                    break
                e += 1
            binder, k = s[b + 1:e], e + 1
        else:
            k = s.find(" ", b)
            binder = s[b:k] if k >= 0 else s[b:]
        if not s.startswith(" => ", k):
            return "".join(out) + s[i:]
        out.append(s[i:j] + "{" + binder + " | ")
        i = k + len(" => ")


def set_builder(a, b):
    if "setOf fun " not in b or "setOf fun " in a:
        return a, b
    unbracketed = lambda s: re.sub(r"[(){}\s]", "", s)
    return unbracketed(a), unbracketed(set_builder_opened(b))


def each(f):
    return lambda a, b: (f(a), f(b))


STEPS = [
    ("whitespace (line breaking)", each(ws)),
    ("set-builder: an old `setOf` prints `setOf fun x => p` (newest Mathlib unexpands only `Set.ofPred`), "
     "with the parentheses that forces", set_builder),
    ("`↧` notation (newest Mathlib's ConcreteCategory notation)", each(lambda s: s.replace("↧", ""))),
    ("hygiene (`✝`, inst_N)", each(lambda s: INST.sub("inst", HYGIENE.sub("", s)))),
    ("coercion arrows (`↑ ⇑ ↥`)", each(lambda s: re.sub(r"[↑⇑↥]", "", s))),
    ("explicit `@`", each(lambda s: s.replace("@", ""))),
    ("namespace qualification", each(lambda s: IDENT.sub(lambda m: m.group(0).split(".")[-1], s))),
]


def cause_of(a, b):
    for name, step in STEPS:
        a, b = step(a, b)
        if a == b:
            return name
    return UNRECOGNISED


def text_pairs(nd, rd):
    out = [("type", nd.get("type", ""), rd.get("type", ""))]
    nb, rb = nd.get("binders", []), rd.get("binders", [])
    out.append(("binders", " ".join(nb), " ".join(rb)))
    ne, re_ = nd.get("equations", []), rd.get("equations", [])
    for i in range(max(len(ne), len(re_))):
        out.append((f"equations[{i}]", ne[i] if i < len(ne) else "", re_[i] if i < len(re_) else ""))
    rm = {(m.get("label"), m.get("name")): m for m in rd.get("members", [])}
    for m in nd.get("members", []):
        o = rm.get((m.get("label"), m.get("name")))
        if o is None:
            continue
        out.append((f"members[{m.get('name')}].text", m.get("text", ""), o.get("text", "")))
        out.append((f"members[{m.get('name')}].binders", " ".join(m.get("binders", [])), " ".join(o.get("binders", []))))
    return out


def tagged_names(node):
    out = []
    if isinstance(node, list):
        if len(node) >= 4 and node[2] == 1 and isinstance(node[3], str) and all(isinstance(x, int) for x in node[:3]):
            out.append(node[3])
        else:
            for x in node:
                out.extend(tagged_names(x))
    return out


class Report:
    def __init__(self):
        self.defects = []
        self.tactics = []
        self.buckets = collections.Counter()
        self.bucket_decls = collections.defaultdict(set)
        self.examples = {}
        self.unrecognised = []
        self.fields = collections.Counter()
        self.sidecar = collections.defaultdict(dict)
        self.reader_only_refs = []
        self.spelling = collections.Counter()
        self.compared_modules = 0
        self.compared_decls = 0
        self.decls_differing = 0

    def defect(self, where, what):
        self.defects.append(f"{where}: {what}")

    def drift(self, module, decl, path, cause, example):
        self.buckets[cause] += 1
        self.bucket_decls[cause].add((module, decl))
        self.fields[re.sub(r"\[[^\]]*\]", "", path)] += 1
        self.sidecar[module].setdefault(decl, {})[path] = cause
        if cause not in self.examples:
            self.examples[cause] = (module, decl, path, example)
        if cause == UNRECOGNISED and not example[0].startswith("follows the"):
            self.unrecognised.append((module, decl, path, example))


def compare_decl(rep, module, nd, rd):
    name = nd["name"]
    where = f"{module} {name}"
    nonprinted = set(nd) | set(rd)
    nonprinted -= set(PRINTED_DECL)
    nonprinted.discard("members")
    for k in sorted(nonprinted):
        if nd.get(k) != rd.get(k):
            rep.sidecar[module].setdefault(name, {})[k] = DEFECT
            rep.defect(where, f"`{k}` native {json.dumps(nd.get(k), ensure_ascii=False)[:160]} "
                              f"reader {json.dumps(rd.get(k), ensure_ascii=False)[:160]}")
    nmem = [(m.get("label"), m.get("name")) for m in nd.get("members", [])]
    rmem = [(m.get("label"), m.get("name")) for m in rd.get("members", [])]
    if nmem != rmem:
        rep.defect(where, f"members native {nmem[:6]} reader {rmem[:6]}")
    rmap = {(m.get("label"), m.get("name")): m for m in rd.get("members", [])}
    for m in nd.get("members", []):
        o = rmap.get((m.get("label"), m.get("name")))
        if o is None:
            continue
        for k in sorted((set(m) | set(o)) - set(PRINTED_MEMBER)):
            if m.get(k) != o.get(k):
                rep.defect(where, f"member {m.get('name')} `{k}` native {json.dumps(m.get(k), ensure_ascii=False)[:160]} "
                                  f"reader {json.dumps(o.get(k), ensure_ascii=False)[:160]}")

    causes = {}
    for path, a, b in text_pairs(nd, rd):
        if a != b:
            causes[path] = cause_of(a, b)
            rep.drift(module, name, path, causes[path], (a[:300], b[:300]))
    text_cause = sorted(set(causes.values()))

    def follow(text_path):
        return next((c for p, c in causes.items() if p == text_path or p.startswith(text_path + "[")), None)

    for k in ("typeCode", "binderCode", "implicits", "equationCode"):
        if nd.get(k) != rd.get(k):
            c = follow(TEXT_OF[k])
            if c is None:
                nn, rn = tagged_names(nd.get(k)), tagged_names(rd.get(k))
                c = UNRECOGNISED
                example = (json.dumps(nd.get(k))[:300], json.dumps(rd.get(k))[:300])
                if nn != rn:
                    example = ("tags " + " ".join(n for n in nn if n not in rn)[:300],
                               "tags " + " ".join(n for n in rn if n not in nn)[:300])
                rep.drift(module, name, k, c, example)
            else:
                rep.drift(module, name, k, c, ("follows the text", ""))
    for m in nd.get("members", []):
        o = rmap.get((m.get("label"), m.get("name")))
        if o is None:
            continue
        for k in ("code", "binderCode", "implicits"):
            if m.get(k) != o.get(k):
                path = f"members[{m.get('name')}].{k}"
                c = causes.get(f"members[{m.get('name')}].{TEXT_OF[k]}")
                if c is None:
                    rep.drift(module, name, path, UNRECOGNISED,
                              (json.dumps(m.get(k))[:300], json.dumps(o.get(k))[:300]))
                else:
                    rep.drift(module, name, path, c, ("follows the text", ""))

    nr = [tuple(x) for x in nd.get("refs", [])]
    rr = [tuple(x) for x in rd.get("refs", [])]
    if nr != rr:
        nmod, rmod = dict((n, m) for m, n in nr), dict((n, m) for m, n in rr)
        for n in sorted(set(nmod) & set(rmod)):
            if nmod[n] != rmod[n]:
                rep.defect(where, f"ref {n} resolves to {nmod[n]} natively and {rmod[n]} in the reader")
        for n in sorted(set(rmod) - set(nmod)):
            rep.reader_only_refs.append((module, name, n, rmod[n]))
        code_differs = any(nd.get(k) != rd.get(k) for k in ("typeCode", "binderCode", "equationCode")) or any(
            m.get("code") != rmap.get((m.get("label"), m.get("name")), {}).get("code")
            or m.get("binderCode") != rmap.get((m.get("label"), m.get("name")), {}).get("binderCode")
            for m in nd.get("members", []))
        if text_cause:
            rep.drift(module, name, "refs", text_cause[0], ("follows the text", ""))
        elif code_differs:
            rep.drift(module, name, "refs", rep.sidecar[module][name].get("typeCode", UNRECOGNISED),
                      ("follows the code", ""))
        else:
            rep.drift(module, name, "refs", UNRECOGNISED,
                      (" ".join(n for _, n in nr if n not in rmod)[:300], " ".join(n for _, n in rr if n not in nmod)[:300]))
    return bool(causes) or any(nd.get(k) != rd.get(k) for k in PRINTED_DECL)


def classify():
    rep = Report()
    rewrites = 0
    n, r = files(native), files(read)
    if not n:
        rep.defect("tree", f"{native} holds no file")
    for name in sorted(set(n) | set(r)):
        if name not in r:
            rep.defect(name, "the reader did not write it")
        elif name not in n:
            rep.defect(name, "the reader wrote it, the native extractor did not")

    ni = json.loads((native / "index.json").read_text(encoding="utf-8"))
    ri = json.loads((read / "index.json").read_text(encoding="utf-8"))
    found, hashes = index_problems(ni, ri, ("bytes",), ("bytes", "entries"))
    for p in found:
        rep.defect("index.json", p)

    native_names, refs_native, refs_read = set(), set(), set()
    for mod in sorted(name for name in set(n) & set(r) if name.startswith("modules/")):
        raw, count = renamed(n[mod].read_bytes())
        rewrites += count
        nm = json.loads(raw.decode("utf-8"))
        rm = json.loads(r[mod].read_bytes().decode("utf-8"))
        module = nm.get("module", mod)
        rep.compared_modules += 1
        if count:
            spelled_as = {d["name"]: d for d in json.loads(n[mod].read_bytes().decode("utf-8")).get("declarations", [])}
            for d in nm.get("declarations", []):
                before = spelled_as.get(d["name"], {})
                for k in sorted(k for k in d if d[k] != before.get(k)):
                    rep.sidecar[module].setdefault(d["name"], {})[k] = SPELLING
                    rep.spelling[d["name"]] += 1
        for k in sorted((set(nm) | set(rm)) - {"declarations"}):
            if nm.get(k) != rm.get(k):
                if k == "tactics" and rm.get(k) == [] and nm.get(k):
                    rep.tactics.append((module, len(nm[k])))
                else:
                    rep.defect(module, f"module `{k}` native {json.dumps(nm.get(k), ensure_ascii=False)[:200]} "
                                       f"reader {json.dumps(rm.get(k), ensure_ascii=False)[:200]}")
        nds = {d["name"]: d for d in nm.get("declarations", [])}
        rds = {d["name"]: d for d in rm.get("declarations", [])}
        native_names |= set(nds)
        for d in nm.get("declarations", []):
            refs_native |= {x[1] for x in d.get("refs", [])}
        for d in rm.get("declarations", []):
            refs_read |= {x[1] for x in d.get("refs", [])}
        for name in sorted(set(nds) - set(rds)):
            rep.defect(f"{module} {name}", "declaration the reader did not write")
        for name in sorted(set(rds) - set(nds)):
            rep.defect(f"{module} {name}", "declaration only the reader wrote")
        for name in sorted(set(nds) & set(rds)):
            rep.compared_decls += 1
            if nds[name] != rds[name]:
                rep.decls_differing += compare_decl(rep, module, nds[name], rds[name])

    native_deps = {}
    dep_drift = 0
    for dep in sorted(name for name in set(n) & set(r) if name.startswith("deps/")):
        nd = json.loads(n[dep].read_text(encoding="utf-8")).get("declarations", {})
        rd = json.loads(r[dep].read_text(encoding="utf-8")).get("declarations", {})
        native_deps.update(nd)
        for k in sorted(set(nd) | set(rd)):
            if k in nd and k in rd:
                if nd[k] != rd[k]:
                    rep.defect(dep, f"{k} is in {nd[k]} natively and {rd[k]} in the reader")
            elif k in nd and k in refs_native and k not in refs_read:
                dep_drift += 1
            elif k in rd and k in refs_read and k not in refs_native:
                dep_drift += 1
            else:
                rep.defect(dep, f"{k} only on the {'native' if k in nd else 'reader'} side, and the refs do not say why")

    lidx_equal = native_lidx.read_bytes() == read_lidx.read_bytes()
    if not lidx_equal:
        a = native_lidx.read_text(encoding="utf-8").splitlines()
        b = read_lidx.read_text(encoding="utf-8").splitlines()
        at = next((i for i, (u, v) in enumerate(zip(a, b)) if u != v), min(len(a), len(b)))
        rep.defect("link-index.lidx", f"differs from line {at + 1} ({len(a)} vs {len(b)} lines): "
                                      f"native {a[at] if at < len(a) else '<end>'!r} reader {b[at] if at < len(b) else '<end>'!r}")

    unknown_refs = [x for x in rep.reader_only_refs if x[2] not in native_names and x[2] not in native_deps]

    print("printed fields (a difference here is printer drift, bucketed by cause; anything else is a defect):")
    print("  declaration: " + ", ".join(PRINTED_DECL))
    print("  member:      " + ", ".join(PRINTED_MEMBER))
    print("  deps/*.json: an entry on one side only, when only that side's refs name it (the maps follow refs)")
    print("  index.json:  modules[].bytes and dependencyMaps[].bytes/entries (sizes of the files above)")
    print(f"compared: {rep.compared_modules} module(s), {rep.compared_decls} declaration(s) present on both sides; "
          f"{rep.decls_differing} declaration(s) differ in a printed field")
    print(f"reducibility spelling {spelled.decode()} -> {running.decode()} applied {rewrites} time(s) to the native side; "
          f"in {sum(rep.spelling.values())} field(s) of {len(rep.spelling)} declaration(s); "
          f"contentHash differs in {hashes} module(s) exactly where the bytes do; identity "
          f"{'as predicted' if not any('identity' in p for p in found) else 'NOT as predicted'}")
    print(f"link index: {'byte-identical' if lidx_equal else 'DIFFERS'}; dependency-map entries following refs: {dep_drift}")
    print(f"defects (non-printed field differing, or present on one side only): {len(rep.defects)}")
    for d in rep.defects[:40]:
        print("  " + d)
    if len(rep.defects) > 40:
        print(f"  ... {len(rep.defects) - 40} more in {report_path}")
    print(f"non-printed, named open item: {TACTICS}: {len(rep.tactics)} module(s), "
          f"{sum(c for _, c in rep.tactics)} tactic(s) native, 0 reader")
    print("printer drift by cause (field occurrences / declarations), one example each:")
    order = [s for s, _ in STEPS] + [UNRECOGNISED]
    for cause in sorted(rep.buckets, key=lambda c: (order.index(c) if c in order else len(order), c)):
        mod, decl, path, ex = rep.examples[cause]
        print(f"  {rep.buckets[cause]:6d} / {len(rep.bucket_decls[cause]):5d}  {cause}")
        print(f"      e.g. {mod} {decl} {path}")
        print(f"        native: {ex[0][:240]!r}")
        print(f"        reader: {ex[1][:240]!r}")
    print(f"cause not recognised: {rep.buckets.get(UNRECOGNISED, 0)} field occurrence(s) in "
          f"{len(rep.bucket_decls.get(UNRECOGNISED, ()))} declaration(s)")
    for mod, decl, path, ex in rep.unrecognised[:12]:
        print(f"  {mod} {decl} {path}")
        print(f"    native: {ex[0][:300]!r}")
        print(f"    reader: {ex[1][:300]!r}")
    print("drift by field: " + ", ".join(f"{k} {v}" for k, v in sorted(rep.fields.items())))
    print(f"refs only the reader has: {len(rep.reader_only_refs)}, of which {len(unknown_refs)} name a constant "
          f"neither the native IR's modules nor its dependency maps declare")
    for x in unknown_refs[:8]:
        print(f"  {x[0]} {x[1]} -> {x[2]} ({x[3]})")

    report_path.write_text(json.dumps({
        "comparedModules": rep.compared_modules, "comparedDeclarations": rep.compared_decls,
        "declarationsDiffering": rep.decls_differing, "renames": rewrites, "contentHashDiffers": hashes,
        "linkIndexEqual": lidx_equal, "depEntriesFollowingRefs": dep_drift,
        "defects": rep.defects, "tactics": rep.tactics,
        "buckets": {c: {"fields": rep.buckets[c], "declarations": len(rep.bucket_decls[c])} for c in rep.buckets},
        "unrecognised": rep.unrecognised, "readerOnlyRefs": rep.reader_only_refs, "unknownRefs": unknown_refs,
        "byModule": rep.sidecar,
    }, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    sys.exit(1 if rep.defects else 0)


if report_path is None:
    exact()
else:
    classify()
