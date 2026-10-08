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

usage: reader-compare.py <native-ir> <native-lidx> <read-ir> <read-lidx> <lean-version>
         <native-spelling> <running-spelling> <Extract.lean> <cut Extract.lean>
         <reader-identity-file>
Prints one line and exits 0 when equal; prints at most eight differences and
exits 1 otherwise.
"""

import json
import pathlib
import sys

if len(sys.argv) != 11:
    sys.exit(__doc__)
native, native_lidx, read, read_lidx = (pathlib.Path(p) for p in sys.argv[1:5])
version, spelled, running = sys.argv[5], sys.argv[6].encode(), sys.argv[7].encode()
full, cut, reader_identity = (pathlib.Path(p) for p in sys.argv[8:11])
problems = []


def fnv(path):
    h = 0xCBF29CE484222325
    for b in path.read_bytes():
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "fnv1a64:%016x" % h


def files(root):
    return {p.relative_to(root).as_posix(): p for p in sorted(root.rglob("*")) if p.is_file()}


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
    want = n[name].read_bytes()
    if spelled != running:
        rewrites += want.count(spelled)
        want = want.replace(spelled, running)
    got = r[name].read_bytes()
    if want != got:
        at = next((i for i, (u, v) in enumerate(zip(want, got)) if u != v), min(len(want), len(got)))
        problems.append(f"{name} differs at byte {at}: native {want[at:at + 60]!r} reader {got[at:at + 60]!r}")
if native_lidx.read_bytes() != read_lidx.read_bytes():
    problems.append("the link index differs")

ni = json.loads((native / "index.json").read_text(encoding="utf-8"))
ri = json.loads((read / "index.json").read_text(encoding="utf-8"))
for side, index in (("native", ni), ("reader", ri)):
    if index.get("leanVersion") != version:
        problems.append(f"the {side} index names Lean {index.get('leanVersion')!r}, not {version}")
source_full, source_cut = "source=" + fnv(full), "source=" + fnv(cut)
native_id = ni.get("extractorIdentity", "")
if source_full not in native_id.split(" "):
    problems.append(f"the native identity does not carry {source_full}: {native_id}")
reader_fields = [f for f in reader_identity.read_text(encoding="utf-8").split() if f.startswith("reader")]
want_id = " ".join([source_cut if f == source_full else f for f in native_id.split(" ")] + reader_fields)
if ri.get("extractorIdentity") != want_id:
    problems.append(f"the reader identity is {ri.get('extractorIdentity')!r}, predicted {want_id!r}")
blank = " ".join(f.split("=")[0] + "=" if f.split("=")[0] in ("lean", "leanGithash") else f for f in want_id.split(" "))
if reader_identity.read_text(encoding="utf-8").strip() != blank:
    problems.append("`reader extract --identity` does not print the run's identity with lean= and leanGithash= blank")
hashes = 0
for nm, rm in zip(ni.get("modules", []), ri.get("modules", [])):
    raw_equal = (native / nm["file"]).read_bytes() == (read / rm["file"]).read_bytes()
    if raw_equal != (nm.get("contentHash") == rm.get("contentHash")):
        problems.append(f"{nm['module']}: raw bytes {'match' if raw_equal else 'differ'} but contentHash does not follow")
    hashes += nm.get("contentHash") != rm.get("contentHash")
strip = lambda ix: {**ix, "extractorIdentity": None,
                    "modules": [{**m, "contentHash": None} for m in ix.get("modules", [])]}
if strip(ni) != strip(ri):
    keys = sorted(k for k in set(ni) | set(ri) if strip(ni).get(k) != strip(ri).get(k))
    problems.append(f"index.json differs beyond the identity and contentHash: {keys}")

if problems:
    for p in problems[:8]:
        print(p)
    sys.exit(1)
print(f"{len(n)} IR files and the link index equal; reducibility spelling "
      f"{spelled.decode()} -> {running.decode()} applied {rewrites} time(s), "
      f"contentHash differs in {hashes} module(s) exactly where the bytes do, identity as predicted")
