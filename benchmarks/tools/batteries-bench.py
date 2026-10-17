"""Measurement helpers for batteries-bench.sh: declared modules, lake job lines, per-round rows, summary.

usage: batteries-bench.py libs <lakefile>
       batteries-bench.py declared <package root> <lib> <out dir>
       batteries-bench.py lakejobs <lake log>
       batteries-bench.py html-count <dir> <depth>
       batteries-bench.py round --logs D --rows F --id I --arm A --jobs N --kind K --parts p1[,p2]
                      --declared F --declared-glob F
       batteries-bench.py skip --rows F --id I --arm A --jobs N --kind K --reason R [--status S]
       batteries-bench.py summarize --rows F --cells F --out D
"""
import argparse
import csv
import json
import os
import re
import statistics
import sys

COLUMNS = [
    "id", "arm", "jobs", "kind", "status", "note", "exit",
    "wall_s", "user_s", "sys_s", "cpu_s", "cpu_pct",
    "gnu_maxrss_kib", "peak_tree_anon_kib", "peak_machine_used_delta_kib",
    "swapout_pages", "swapin_pages", "majflt_delta", "peak_nprocs", "samples",
    "peak_tree_vmrss_kib", "peak_tree_rssfile_kib", "peak_tree_vmswap_kib",
    "docs_wall_s", "header_wall_s", "docinfo_n", "docinfo_job_sum_s",
    "fromdb_lib_s", "fromdb_pkg_s", "headerdata_s",
    "ld4_modules", "ld4_extracted", "ld4_extract_s", "ld4_put_s", "ld4_render_s", "ld4_total_s",
    "ld4_plan", "ld4_extractor",
]

SUMMARY_KINDS = ("cold", "warm")

JOB = re.compile(
    r"^(?:\S+\s+)?\[(\d+)/(\d+)\]\s+(Built|Ran|Replayed|Fetched)\s+(\S+)"
    r"(?:\s+\((\d+(?:\.\d+)?)(ms|s)\))?")

IMPORT = re.compile(r"^\s*(?:public\s+)?(?:meta\s+)?import\s+(?:all\s+)?([A-Za-z_][\w.']*)", re.M)


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def cmd_libs(args):
    text = read_text(args.lakefile) or ""
    if args.lakefile.endswith(".toml"):
        names = []
        for block in re.split(r"^\[\[", text, flags=re.M)[1:]:
            if block.startswith("lean_lib]]"):
                m = re.search(r'^\s*name\s*=\s*"([^"]+)"', block, re.M)
                names.append(m.group(1) if m else "?")
    else:
        names = re.findall(r"^\s*lean_lib\s+(\S+)", text, re.M)
    print("lean_libs\t%d\t%s" % (len(names), " ".join(names)))


def module_glob(root, lib):
    found = set()
    if os.path.isfile(os.path.join(root, lib + ".lean")):
        found.add(lib)
    base = os.path.join(root, lib)
    for d, _, files in os.walk(base):
        for f in files:
            if f.endswith(".lean"):
                rel = os.path.relpath(os.path.join(d, f), root)[:-len(".lean")]
                found.add(rel.replace(os.sep, "."))
    return found


def import_closure(root, lib):
    seen, stack = set(), [lib]
    while stack:
        mod = stack.pop()
        if mod in seen:
            continue
        seen.add(mod)
        text = read_text(os.path.join(root, *mod.split(".")) + ".lean")
        if text is None:
            continue
        stack.extend(i for i in IMPORT.findall(text) if i == lib or i.startswith(lib + "."))
    return seen


def cmd_declared(args):
    glob = module_glob(args.root, args.lib)
    closure = import_closure(args.root, args.lib)
    for name, mods in (("declared-glob.txt", glob), ("declared-closure.txt", closure)):
        with open(os.path.join(args.out, name), "w") as f:
            f.write("".join(m + "\n" for m in sorted(mods)))
    print("declared %s: %d by glob (%s.lean and %s/, what litedoc4 --lib reads), "
          "%d by import closure of %s (what doc-gen4's docInfo walks)"
          % (args.lib, len(glob), args.lib, args.lib, len(closure), args.lib))
    print("glob-not-closure\t%s" % " ".join(sorted(glob - closure)))
    print("closure-not-glob\t%s" % " ".join(sorted(closure - glob)))


def lake_jobs(text):
    jobs = []
    for line in (text or "").splitlines():
        m = JOB.match(line)
        if not m:
            continue
        name = m.group(4)
        base, _, facet = name.rpartition(":") if ":" in name else (name, "", "")
        pkg, _, target = base.partition("/") if "/" in base else ("", "", base)
        secs = None
        if m.group(5) is not None:
            secs = float(m.group(5)) / (1000.0 if m.group(6) == "ms" else 1.0)
        jobs.append({"verb": m.group(3), "name": name, "pkg": pkg, "target": target,
                     "facet": facet, "secs": secs})
    return jobs


def cmd_lakejobs(args):
    for j in lake_jobs(read_text(args.log)):
        print("\t".join([j["verb"], j["pkg"], j["target"], j["facet"],
                         "" if j["secs"] is None else "%.3f" % j["secs"], j["name"]]))


def cmd_html_count(args):
    counts = {}
    total = 0
    for d, _, files in os.walk(args.dir):
        rel = os.path.relpath(d, args.dir)
        parts = [] if rel == "." else rel.split(os.sep)
        key = "/".join(parts[:args.depth]) if len(parts) >= args.depth else "(above depth %d)" % args.depth
        n = sum(1 for f in files if f.endswith(".html"))
        if n:
            counts[key] = counts.get(key, 0) + n
            total += n
    print("dir\t%s" % args.dir)
    for key in sorted(counts):
        print("%s\t%d" % (key, counts[key]))
    print("total\t%d" % total)


def read_kv(path):
    out = {}
    for line in (read_text(path) or "").splitlines():
        k, sep, v = line.partition("\t")
        if sep:
            out[k] = v
    return out


def gnu_time(path):
    text = read_text(path)
    if text is None:
        return None
    vals = {}
    for line in text.splitlines():
        k, sep, v = line.strip().rpartition(": ")
        if sep:
            vals[k] = v.strip()
    def num(key):
        try:
            return float(vals[key])
        except (KeyError, ValueError):
            return None
    wall = None
    raw = vals.get("Elapsed (wall clock) time (h:mm:ss or m:ss)")
    if raw:
        try:
            wall = 0.0
            for piece in raw.split(":"):
                wall = wall * 60 + float(piece)
        except ValueError:
            wall = None
    return {"user": num("User time (seconds)"), "sys": num("System time (seconds)"), "wall": wall,
            "maxrss": num("Maximum resident set size (kbytes)"),
            "majflt": num("Major (requiring I/O) page faults")}


def read_tsv(path):
    text = read_text(path)
    if text is None:
        return []
    return list(csv.DictReader(text.splitlines(), delimiter="\t"))


def to_int(value):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def peak(rows, key):
    vals = [to_int(r.get(key)) for r in rows]
    vals = [v for v in vals if v is not None]
    return max(vals) if vals else None


def part_measure(logs, part):
    outcome = read_kv(os.path.join(logs, part + "-outcome.txt"))
    t = gnu_time(os.path.join(logs, part + ".time"))
    samples = read_tsv(os.path.join(logs, part + "-sampler.tsv"))
    mem = {r.get("when"): r for r in read_tsv(os.path.join(logs, part + "-mem.tsv"))}
    before, after = mem.get("before", {}), mem.get("after", {})
    used_before = None
    if to_int(before.get("MemTotal")) is not None and to_int(before.get("MemAvailable")) is not None:
        used_before = to_int(before["MemTotal"]) - to_int(before["MemAvailable"])
    used = [to_int(r.get("MemTotal")) - to_int(r.get("MemAvailable")) for r in samples
            if to_int(r.get("MemTotal")) is not None and to_int(r.get("MemAvailable")) is not None]
    def delta(key):
        a, b = to_int(after.get(key)), to_int(before.get(key))
        return None if a is None or b is None else a - b
    return {
        "present": bool(outcome),
        "outcome": outcome.get("outcome", "missing"),
        "exit": to_int(outcome.get("exit")),
        "wall": (t or {}).get("wall") if (t or {}).get("wall") is not None else to_int(outcome.get("wall_s")),
        "user": (t or {}).get("user"), "sys": (t or {}).get("sys"), "maxrss": (t or {}).get("maxrss"),
        "anon": peak(samples, "RssAnon"), "vmrss": peak(samples, "VmRSS"),
        "rssfile": peak(samples, "RssFile"), "vmswap": peak(samples, "VmSwap"),
        "nprocs": peak(samples, "nprocs"), "samples": len(samples),
        "used_delta": (max(used) - used_before) if used and used_before is not None else None,
        "swapout": delta("pswpout"), "swapin": delta("pswpin"), "majflt": delta("pgmajfault"),
    }


def total(values):
    vals = [v for v in values if v is not None]
    return sum(vals) if vals else None


def biggest(values):
    vals = [v for v in values if v is not None]
    return max(vals) if vals else None


def read_declared(path):
    return set(line.strip() for line in (read_text(path) or "").splitlines() if line.strip())


def docgen_scope(logs, rid, declared, row):
    problems, warnings = [], []
    docs = lake_jobs(read_text(os.path.join(logs, rid + "-docs.log")))
    header = lake_jobs(read_text(os.path.join(logs, rid + "-header.log")))
    built = [j for j in docs if j["verb"] == "Built"]
    docinfo = [j for j in built if j["facet"] == "docInfo"]
    ours = [j["target"] for j in docinfo if j["pkg"] == "batteries"]
    others = sorted(j["name"] for j in docinfo if j["pkg"] != "batteries")
    got = set(ours)
    row["docinfo_n"] = len(got)
    row["docinfo_job_sum_s"] = total(j["secs"] for j in docinfo if j["pkg"] == "batteries")
    if got != declared:
        missing, extra = sorted(declared - got), sorted(got - declared)
        problems.append("docInfo built for %d of %d declared modules (missing %d: %s; extra %d: %s)"
                        % (len(got & declared), len(declared), len(missing), " ".join(missing[:5]),
                           len(extra), " ".join(extra[:5])))
    if len(ours) != len(got):
        problems.append("docInfo built twice for %d module(s)" % (len(ours) - len(got)))
    if others:
        problems.append("docInfo built outside batteries: %d (%s)" % (len(others), " ".join(others[:5])))
    for label, jobs in (("docs", docs), ("docsHeader", header)):
        core = [j["name"] for j in jobs if j["verb"] == "Built" and j["target"] == "coreDocs"]
        if core:
            problems.append("%s rebuilt core: %s" % (label, " ".join(core)))
        compiled = [j["name"] for j in jobs if j["verb"] == "Built" and j["pkg"] == ""
                    and (j["target"] == "Batteries" or j["target"].startswith("Batteries."))
                    and j["facet"] != "docs"]
        if compiled:
            problems.append("%s compiled Batteries modules: %d (%s)" % (label, len(compiled), " ".join(compiled[:5])))
    lib_fromdb = [j for j in built if j["name"] == "batteries/Batteries:docs"]
    if not lib_fromdb:
        problems.append("no `Built batteries/Batteries:docs` (the library's fromDb) in the docs log")
    row["fromdb_lib_s"] = total(j["secs"] for j in lib_fromdb)
    hbuilt = [j for j in header if j["verb"] == "Built"]
    pkg_fromdb = [j for j in hbuilt if j["name"] == "batteries:docs"]
    header_data = [j for j in hbuilt if j["name"] == "batteries/Batteries:docsHeader"]
    hdocinfo = [j for j in hbuilt if j["facet"] == "docInfo"]
    row["fromdb_pkg_s"] = total(j["secs"] for j in pkg_fromdb)
    row["headerdata_s"] = total(j["secs"] for j in header_data)
    if read_text(os.path.join(logs, rid + "-header.log")) is not None:
        if not header_data:
            problems.append("no `Built batteries/Batteries:docsHeader` in the header log")
        if hdocinfo:
            problems.append("docsHeader built docInfo again: %d" % len(hdocinfo))
        if not pkg_fromdb:
            warnings.append("no `Built batteries:docs` (the package's fromDb) in the header log")
    known = {"batteries/Batteries:docs", "batteries:docs", "batteries/Batteries:docsHeader"}
    rest = sorted(set(j["name"] for j in docs + header
                      if j["verb"] == "Built" and j["facet"] != "docInfo" and j["name"] not in known
                      and j["target"] != "coreDocs" and not j["facet"].startswith("srcUri")))
    if rest:
        warnings.append("other built jobs: %s" % " ".join(rest[:10]))
    return problems, warnings


def litedoc4_scope(logs, rid, kind, declared, row):
    problems, warnings = [], []
    log = read_text(os.path.join(logs, rid + ".log")) or ""
    def line(prefix):
        for l in log.splitlines():
            if l.startswith(prefix):
                return l
        return None
    if line("lib     Batteries (--lib)") is None:
        problems.append("no `lib     Batteries (--lib)` line")
    mods = line("modules ")
    n = to_int(mods.split()[1]) if mods and len(mods.split()) > 1 else None
    row["ld4_modules"] = n
    if n != len(declared):
        problems.append("modules %s, declared %d" % (n, len(declared)))
    plan = line("plan    ")
    row["ld4_plan"] = (plan or "").replace("plan    ", "", 1)
    if not plan or not plan.startswith("plan    extract everything ("):
        problems.append("plan is not `extract everything`: %s" % plan)
    ext = line("extract ")
    m = re.match(r"extract\s+(\d+) module\(s\)", ext or "")
    extracted = int(m.group(1)) if m else None
    row["ld4_extracted"] = extracted
    if extracted != len(declared):
        problems.append("extracted %s, declared %d" % (extracted, len(declared)))
    extractor = line("extractor ")
    row["ld4_extractor"] = extractor or ""
    if kind != "prime" and (extractor is None or "(cached)" not in extractor):
        problems.append("extractor not reused: %s" % extractor)
    if line("versions rendered: 1 of 1") is None:
        problems.append("no `versions rendered: 1 of 1` line")
    listed = read_declared(os.path.join(logs, rid + "-modules.txt"))
    if listed and listed != declared:
        problems.append("work/modules.txt differs from the declared glob: missing %d, extra %d"
                        % (len(declared - listed), len(listed - declared)))
    if not listed:
        warnings.append("no copy of work/modules.txt")
    timings = None
    for l in (read_text(os.path.join(logs, rid + "-timings.jsonl")) or "").splitlines():
        try:
            obj = json.loads(l)
        except ValueError:
            continue
        if obj.get("command") == "build":
            timings = obj
    if timings is None:
        problems.append("no build line in the timings file")
    else:
        row["ld4_extract_s"] = timings.get("extractSeconds")
        row["ld4_put_s"] = timings.get("putSeconds")
        row["ld4_render_s"] = timings.get("renderSeconds")
        row["ld4_total_s"] = timings.get("totalSeconds")
        if timings.get("extracted") != len(declared) or timings.get("modules") != len(declared):
            problems.append("timings say modules %s extracted %s, declared %d"
                            % (timings.get("modules"), timings.get("extracted"), len(declared)))
    return problems, warnings


def fmt(value):
    if value is None:
        return ""
    if isinstance(value, float):
        return "%.1f" % value
    return str(value).replace("\t", " ").replace("\n", " ")


def append_row(path, row):
    header = "\t".join(COLUMNS) + "\n"
    existing = read_text(path) or ""
    if not existing.startswith(header):
        with open(path, "w") as f:
            f.write(header + existing)
    with open(path, "a") as f:
        f.write("\t".join(fmt(row.get(c)) for c in COLUMNS) + "\n")


def cmd_round(args):
    parts = [p for p in args.parts.split(",") if p]
    measured = [part_measure(args.logs, p) for p in parts]
    row = {"id": args.id, "arm": args.arm, "jobs": args.jobs, "kind": args.kind}
    ran = [m for m in measured if m["present"]]
    exits = [m["exit"] for m in ran]
    row["exit"] = ",".join("" if e is None else str(e) for e in exits)
    row["wall_s"] = total(m["wall"] for m in ran)
    row["user_s"] = total(m["user"] for m in ran)
    row["sys_s"] = total(m["sys"] for m in ran)
    if row["user_s"] is not None and row["sys_s"] is not None:
        row["cpu_s"] = row["user_s"] + row["sys_s"]
        if row["wall_s"]:
            row["cpu_pct"] = 100.0 * row["cpu_s"] / row["wall_s"]
    row["gnu_maxrss_kib"] = biggest(m["maxrss"] for m in ran)
    row["peak_tree_anon_kib"] = biggest(m["anon"] for m in ran)
    row["peak_machine_used_delta_kib"] = biggest(m["used_delta"] for m in ran)
    row["swapout_pages"] = total(m["swapout"] for m in ran)
    row["swapin_pages"] = total(m["swapin"] for m in ran)
    row["majflt_delta"] = total(m["majflt"] for m in ran)
    row["peak_nprocs"] = biggest(m["nprocs"] for m in ran)
    row["samples"] = total(m["samples"] for m in ran)
    row["peak_tree_vmrss_kib"] = biggest(m["vmrss"] for m in ran)
    row["peak_tree_rssfile_kib"] = biggest(m["rssfile"] for m in ran)
    row["peak_tree_vmswap_kib"] = biggest(m["vmswap"] for m in ran)
    if args.arm == "docgen4":
        row["docs_wall_s"] = measured[0]["wall"] if measured and measured[0]["present"] else None
        if len(measured) > 1 and measured[1]["present"]:
            row["header_wall_s"] = measured[1]["wall"]
        problems, warnings = docgen_scope(args.logs, args.id, read_declared(args.declared), row)
    else:
        problems, warnings = litedoc4_scope(args.logs, args.id, args.kind,
                                            read_declared(args.declared_glob), row)
    if len(ran) < len(parts):
        status = "incomplete"
        problems.insert(0, "%d of %d commands ran" % (len(ran), len(parts)))
    elif any(m["outcome"] == "timeout" for m in ran):
        status = "timeout"
    elif any(e != 0 for e in exits):
        status = "exit-fail"
    elif problems:
        status = "scope-fail"
    else:
        status = "ok"
    row["status"] = status
    row["note"] = "; ".join(problems + ["warning: " + w for w in warnings])
    append_row(args.rows, row)
    print("status %s" % status)
    for p in problems:
        print("FAIL %s" % p)
    for w in warnings:
        print("warning %s" % w)
    print("wall %s" % fmt(row["wall_s"]))


def cmd_skip(args):
    append_row(args.rows, {"id": args.id, "arm": args.arm, "jobs": args.jobs, "kind": args.kind,
                           "status": args.status, "note": args.reason})
    print("status %s" % args.status)


def stats(values):
    vals = [v for v in values if v is not None]
    if not vals:
        return ["", "", ""]
    return [fmt(float(statistics.median(vals))), fmt(float(min(vals))), fmt(float(max(vals)))]


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def mib(value):
    v = number(value)
    return None if v is None else v / 1024.0


def cmd_summarize(args):
    rows = read_tsv(args.rows)
    cells = []
    for line in (read_text(args.cells) or "").splitlines():
        f = line.split("\t")
        if len(f) >= 4 and f[3].isdigit():
            cells.append((f[0], f[1], f[2], int(f[3]), f[4] if len(f) > 4 else ""))
    groups = {}
    for r in rows:
        if r.get("status") == "ok" and r.get("kind") in SUMMARY_KINDS:
            groups.setdefault((r["arm"], r["jobs"], r["kind"]), []).append(r)
    header = ["arm", "jobs", "kind", "n",
              "wall_median_s", "wall_min_s", "wall_max_s",
              "cpu_median_s", "cpu_min_s", "cpu_max_s",
              "tree_anon_peak_median_mib", "tree_anon_peak_min_mib", "tree_anon_peak_max_mib",
              "machine_used_delta_median_mib", "machine_used_delta_min_mib", "machine_used_delta_max_mib",
              "largest_process_maxrss_median_mib", "swapout_pages_max", "peak_nprocs_max",
              "fromdb_lib_median_s", "fromdb_pkg_median_s"]
    lines = ["\t".join(header)]
    keys = sorted(set(list(groups) + [(c[0], c[1], c[2]) for c in cells if c[2] in SUMMARY_KINDS]),
                  key=lambda k: (k[0], -int(k[1]) if k[1].isdigit() else 0, k[2]))
    for key in keys:
        rs = groups.get(key, [])
        swap = [number(r.get("swapout_pages")) for r in rs]
        swap = [v for v in swap if v is not None]
        procs = [number(r.get("peak_nprocs")) for r in rs]
        procs = [v for v in procs if v is not None]
        lines.append("\t".join(
            list(key) + [str(len(rs))]
            + stats(number(r.get("wall_s")) for r in rs)
            + stats(number(r.get("cpu_s")) for r in rs)
            + stats(mib(r.get("peak_tree_anon_kib")) for r in rs)
            + stats(mib(r.get("peak_machine_used_delta_kib")) for r in rs)
            + stats(mib(r.get("gnu_maxrss_kib")) for r in rs)[:1]
            + [fmt(max(swap)) if swap else "", fmt(int(max(procs))) if procs else ""]
            + stats(number(r.get("fromdb_lib_s")) for r in rs)[:1]
            + stats(number(r.get("fromdb_pkg_s")) for r in rs)[:1]))
    with open(os.path.join(args.out, "summary.tsv"), "w") as f:
        f.write("\n".join(lines) + "\n")
    cell_lines = ["arm\tjobs\tkind\tdeclared\tran\tpassed\tnote"]
    report = []
    for arm, jobs, kind, declared, note in cells:
        mine = [r for r in rows if (r.get("arm"), r.get("jobs"), r.get("kind")) == (arm, jobs, kind)]
        ran = [r for r in mine if r.get("status") not in ("skipped", "reset-failed")]
        passed = [r for r in mine if r.get("status") == "ok"]
        cell_lines.append("\t".join([arm, jobs, kind, str(declared), str(len(ran)), str(len(passed)), note]))
        report.append("%s jobs=%s %s: %d of %d passed (%d ran)%s"
                      % (arm, jobs, kind, len(passed), declared, len(ran), (" - " + note) if note else ""))
    with open(os.path.join(args.out, "cells.tsv"), "w") as f:
        f.write("\n".join(cell_lines) + "\n")
    print("\n".join(lines))
    print()
    print("\n".join(report))
    failed = [r for r in rows if r.get("status") not in ("ok",)]
    for r in failed:
        print("not counted: %s %s %s" % (r.get("id"), r.get("status"), (r.get("note") or "")[:300]))


def main(argv):
    ap = argparse.ArgumentParser(usage=__doc__)
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("libs"); p.add_argument("lakefile"); p.set_defaults(fn=cmd_libs)
    p = sub.add_parser("declared"); p.add_argument("root"); p.add_argument("lib"); p.add_argument("out")
    p.set_defaults(fn=cmd_declared)
    p = sub.add_parser("lakejobs"); p.add_argument("log"); p.set_defaults(fn=cmd_lakejobs)
    p = sub.add_parser("html-count"); p.add_argument("dir"); p.add_argument("depth", type=int)
    p.set_defaults(fn=cmd_html_count)
    p = sub.add_parser("round")
    for name in ("--logs", "--rows", "--id", "--arm", "--jobs", "--kind", "--parts", "--declared",
                 "--declared-glob"):
        p.add_argument(name, required=True)
    p.set_defaults(fn=cmd_round)
    p = sub.add_parser("skip")
    for name in ("--rows", "--id", "--arm", "--jobs", "--kind", "--reason"):
        p.add_argument(name, required=True)
    p.add_argument("--status", default="skipped")
    p.set_defaults(fn=cmd_skip)
    p = sub.add_parser("summarize")
    for name in ("--rows", "--cells", "--out"):
        p.add_argument(name, required=True)
    p.set_defaults(fn=cmd_summarize)
    args = ap.parse_args(argv)
    if not getattr(args, "fn", None):
        ap.print_usage()
        return 2
    args.fn(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
