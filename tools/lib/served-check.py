"""The oracle half of tools/served-gate.sh: one `ITEM <name> ok|FAIL <line>` per
item, and nothing else on stdout. The gate owns the inventory and the summary.

usage: served-check.py <declared,comma,list> <build out dir> <site base URL>
"""
import gzip
import html.parser
import json
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 30


class Unreachable(Exception):
    pass


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
            if response.status != 200:
                raise Unreachable("%s answered %d" % (url, response.status))
            return response.read()
    except urllib.error.HTTPError as e:
        raise Unreachable("%s answered %d" % (url, e.code))
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, "reason", e)
        raise Unreachable("%s: %s" % (url, reason))


def get_json(url):
    raw = get(url)
    if raw[:2] == b"\x1f\x8b":
        try:
            raw = gzip.decompress(raw)
        except (OSError, EOFError) as e:
            raise Unreachable("%s is not gzip: %s" % (url, e))
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise Unreachable("%s is not JSON: %s" % (url, e))


class Page(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.body = {}
        self.refs = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "body":
            self.body = a
        elif tag == "link" and a.get("href"):
            self.refs.append(a["href"])
        elif tag == "script" and a.get("src"):
            self.refs.append(a["src"])


def page(url):
    p = Page()
    p.feed(get(url).decode("utf-8", errors="replace"))
    return p


def item(name, ok, line):
    print("ITEM %s %s %s" % (name, "ok" if ok else "FAIL", line), flush=True)


def built(declared, out):
    marker = out / "litedoc4-build.json"
    try:
        record = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        return {v: (False, "%s unreadable: %s" % (marker, e)) for v in declared}, []
    if not isinstance(record, dict) or not isinstance(record.get("versions"), list):
        why = "%s is not a `build --versions` record (no `versions` list)" % marker
        return {v: (False, why) for v in declared}, []
    listed = record["versions"]
    if record.get("complete") is not True:
        why = "%s says the build did not finish (complete: %s)" % (marker, record.get("complete"))
        return {v: (False, why) for v in declared}, listed
    return {v: (True, "%s lists %s, complete" % (marker, v)) if v in listed
            else (False, "%s does not list %s among %s" % (marker, v, listed))
            for v in declared}, listed


def site_list(base):
    entries = get_json(base + "versions.json")
    if not isinstance(entries, list) or not all(
            isinstance(e, dict) and isinstance(e.get("name"), str) and isinstance(e.get("data"), str)
            for e in entries):
        raise Unreachable("%sversions.json is not a list of {name, data}" % base)
    root = page(base + "index.html")
    hashed = root.body.get("data-mode") == "hash"
    with_routes = [e["name"] for e in entries if "routes" in e]
    if hashed and len(with_routes) != len(entries):
        raise Unreachable("the root page is a hash-URL site but versions.json gives no routes for %s"
                          % [e["name"] for e in entries if "routes" not in e])
    if not hashed and with_routes:
        raise Unreachable("the root page is a path-URL site but versions.json gives routes for %s"
                          % with_routes)
    return entries, root, hashed


def front_files(base, at, refs, entry, hashed):
    fetched = [urllib.parse.urljoin(at, r) for r in refs]
    for url in fetched:
        get(url)
    data_url = base + "d/%s.json.gz" % entry["data"]
    version = get_json(data_url)
    if not isinstance(version, dict) or version.get("version") != entry["name"]:
        raise Unreachable("%s is not %s's data file" % (data_url, entry["name"]))
    fetched.append(data_url)
    wanted = [version.get("modules")]
    if version.get("front") is not None:
        wanted.append(version["front"])
    if hashed:
        wanted.append(entry["routes"])
    for address in wanted:
        if not isinstance(address, str):
            raise Unreachable("%s names no address where one is needed" % data_url)
        url = base + "d/%s.json.gz" % address
        get_json(url)
        fetched.append(url)
    return len(fetched)


def served(declared, base):
    try:
        entries, root, hashed = site_list(base)
    except Unreachable as e:
        return {v: (False, str(e)) for v in declared}, None
    by_name = {e["name"]: e for e in entries}
    embedded = {}
    if hashed:
        try:
            embedded = {e["name"]: e for e in json.loads(root.body.get("data-versions", "null"))}
        except (TypeError, ValueError, KeyError) as e:
            why = "the root page's data-versions is not a version list: %s" % e
            return {v: (False, why) for v in declared}, list(by_name)
    results = {}
    for v in declared:
        entry = by_name.get(v)
        if entry is None:
            results[v] = (False, "%sversions.json does not list %s" % (base, v))
            continue
        try:
            if hashed:
                if embedded.get(v) != entry:
                    raise Unreachable("the root page's data-versions gives %s as %s, versions.json as %s"
                                      % (v, embedded.get(v), entry))
                n = front_files(base, base + "index.html", root.refs, entry, True)
                results[v] = (True, "hash URLs; root page and versions.json agree on %s; %d files answered 200" % (v, n))
            else:
                shell_url = base + urllib.parse.quote(v) + "/index.html"
                shell = page(shell_url)
                if shell.body.get("data-version") != v or shell.body.get("data-data") != entry["data"]:
                    raise Unreachable("%s draws version %s from data %s, versions.json says %s from %s"
                                      % (shell_url, shell.body.get("data-version"),
                                         shell.body.get("data-data"), v, entry["data"]))
                n = front_files(base, shell_url, shell.refs, entry, False)
                results[v] = (True, "path URLs; %s/index.html and %d files it draws from answered 200" % (v, n))
        except Unreachable as e:
            results[v] = (False, str(e))
    return results, list(by_name)


def main():
    declared = [v for v in sys.argv[1].split(",") if v]
    out = pathlib.Path(sys.argv[2])
    base = sys.argv[3].rstrip("/") + "/"

    built_results, in_record = built(declared, out)
    for v in declared:
        item("built-" + v, *built_results[v])

    served_results, in_site = served(declared, base)
    for v in declared:
        item("served-" + v, *served_results[v])

    extra_built = [v for v in in_record if v not in declared]
    extra_served = [v for v in (in_site or []) if v not in declared]
    if in_site is None:
        item("undeclared", False, "versions.json could not be read, so the set served is unknown")
    elif extra_built or extra_served:
        item("undeclared", False, "not declared, yet built: %s; served: %s" % (extra_built, extra_served))
    else:
        item("undeclared", True, "the build record and versions.json name no version outside the %d declared" % len(declared))


if __name__ == "__main__":
    main()
