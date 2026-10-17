#!/usr/bin/env python3
"""Two renders of the same versions, one from the native store and one from the
reader-filled store: which pages differ, and does each difference trace to a
declaration benchmarks/tools/mv-m-run.sh's classification names?

A page is a shell naming content-addressed blobs under d/: data-page (the module's
names, words and lines, and its content blob: one entry per declaration),
data-used-by, and data-data (the version's blob, which names the version-wide
blobs: modules, search, instances, references, front). A page differs when a blob
of its own differs; the version-wide blobs are reported once per version.

Traced means: every content entry that differs is a declaration whose IR differs
in the classification's byModule in a field the entry is drawn from; a `names` or
`words` entry differs only on a module with a declaration that prints differently
(both follow the rendered code); a used-by list gains or loses only a declaration
the classification names as differing in `refs`.

usage: mv-m-site-diff.py <native-site> <reader-site> <logs-dir> <v1,v2,...>
Exits 0 when every differing page is traced, 1 otherwise.
"""

import gzip
import json
import pathlib
import re
import sys

if len(sys.argv) != 5:
    sys.exit(__doc__)
native, reader, logs = (pathlib.Path(p) for p in sys.argv[1:4])
versions = sys.argv[4].split(",")
ATTR = re.compile(r'data-([a-z-]+)="([^"]*)"')
RENDERED_FROM = {"t": {"type", "typeCode"}, "b": {"binders", "binderCode", "implicits"},
                 "eq": {"equations", "equationCode"}, "eqOmitted": {"equations"}, "f": {"members"}, "ctor": {"members"},
                 "attrs": {"attrs"}, "doc": {"doc"}, "k": {"kind"}}


def blob(site, h):
    if not h:
        return None
    for p in (site / "d").glob(h + ".*"):
        raw = p.read_bytes()
        if p.name.endswith(".gz"):
            raw = gzip.decompress(raw)
        return json.loads(raw) if ".json" in p.name else raw
    raise SystemExit(f"{site}: no blob {h}")


def shell(path):
    return dict(ATTR.findall(path.read_text(encoding="utf-8")))


def entries(content):
    out = {}
    for i, e in enumerate(content or []):
        out[e.get("n", f"#{i}")] = e
    return out


untraced_total = 0
for v in versions:
    sidecar = json.loads((logs / f"{v}-classify.json").read_text(encoding="utf-8"))
    by_module = sidecar["byModule"]
    pages_n = sorted(p.relative_to(native / v).as_posix() for p in (native / v).rglob("*.html"))
    pages_r = sorted(p.relative_to(reader / v).as_posix() for p in (reader / v).rglob("*.html"))
    print(f"=== {v}: {len(pages_n)} page(s) native, {len(pages_r)} reader")
    if pages_n != pages_r:
        print(f"  page sets differ: native only {sorted(set(pages_n) - set(pages_r))[:5]}, "
              f"reader only {sorted(set(pages_r) - set(pages_n))[:5]}")
        untraced_total += len(set(pages_n) ^ set(pages_r))
    differing, traced, untraced, to_defect = 0, 0, [], []
    decl_diffs = 0
    version_blobs = None
    for page in sorted(set(pages_n) & set(pages_r)):
        sn, sr = shell(native / v / page), shell(reader / v / page)
        if version_blobs is None and sn.get("data"):
            vn, vr = blob(native, sn["data"]), blob(reader, sr["data"])
            version_blobs = (vn, vr)
        if sn.get("page") == sr.get("page") and sn.get("used-by") == sr.get("used-by"):
            continue
        differing += 1
        module = sn.get("module", "")
        why = []
        decls = by_module.get(module, {})
        printed_moved = {d for d, fields in decls.items() if any(not c.startswith("reducibility") for c in fields.values())}
        pn, pr = blob(native, sn.get("page")), blob(reader, sr.get("page"))
        if pn != pr:
            for k in sorted(set(pn) | set(pr)):
                if k == "content" or pn.get(k) == pr.get(k):
                    continue
                if k == "names":
                    for name in sorted(set(pn[k]) | set(pr[k])):
                        if pn[k].get(name) != pr[k].get(name) and not printed_moved:
                            why.append(f"names[{name}] differs and no declaration of {module} prints differently")
                elif k == "words" and printed_moved:
                    continue
                else:
                    why.append(f"page `{k}` differs")
            cn, cr = entries(blob(native, pn.get("content"))), entries(blob(reader, pr.get("content")))
            if list(cn) != list(cr):
                why.append(f"content entries differ in name or order: native {list(cn)[:4]} reader {list(cr)[:4]}")
            for name in cn:
                if name in cr and cn[name] != cr[name]:
                    decl_diffs += 1
                    moved = {re.sub(r"\[.*", "", f) for f in decls.get(name, {})}
                    for k in sorted(k for k in set(cn[name]) | set(cr[name]) if cn[name].get(k) != cr[name].get(k)):
                        if not RENDERED_FROM.get(k, set()) & moved:
                            why.append(f"{name} renders `{k}` differently, and the IR fields it is drawn from "
                                       f"({sorted(RENDERED_FROM.get(k, {'?'}))}) are equal")
        un, ur = blob(native, sn.get("used-by")), blob(reader, sr.get("used-by"))
        if un != ur:
            for name in sorted(set(un or {}) | set(ur or {})):
                a, b = (un or {}).get(name, []), (ur or {}).get(name, [])
                if a == b:
                    continue
                for user, mod in [tuple(x) for x in a if x not in b] + [tuple(x) for x in b if x not in a]:
                    if "refs" not in by_module.get(mod, {}).get(user, {}):
                        why.append(f"used-by[{name}] gains or loses {user} ({mod}), whose refs are equal")
        if why:
            untraced.append((page, why))
        else:
            traced += 1
            if any(c == "defect" for fields in decls.values() for c in fields.values()):
                to_defect.append(page)
    print(f"  pages whose own blobs differ: {differing} of {len(pages_n)}; traced {traced} "
          f"({len(to_defect)} of them on a module with a defect: {', '.join(to_defect) or '-'}); untraced {len(untraced)}; "
          f"declaration entries rendered differently: {decl_diffs}")
    for page, why in untraced[:10]:
        print(f"  untraced {page}: " + "; ".join(why[:4]))
    untraced_total += len(untraced)
    if version_blobs:
        vn, vr = version_blobs
        for k in sorted(set(vn) | set(vr)):
            if vn.get(k) != vr.get(k):
                same = "differs"
                if k in ("modules", "instances", "references", "front", "search"):
                    a, b = blob(native, vn.get(k)), blob(reader, vr.get(k))
                    same = "differs (blob)" if a != b else "equal content, different hash"
                    if k == "instances" and a != b:
                        untraced_total += 1
                        same += ": instance lists come from instClass/instTypes, which are not printed"
                print(f"  version blob `{k}`: {same}")
            else:
                print(f"  version blob `{k}`: equal")
print(f"untraced pages: {untraced_total}")
sys.exit(1 if untraced_total else 0)
