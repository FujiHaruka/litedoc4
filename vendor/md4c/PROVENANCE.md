# md4c — where these files came from

md4c **0.5.2**, MIT © 2016-2024 Martin Mitáš. Keep `LICENSE.md` next to the
sources when redistributing.

The chain is written out here rather than cited, because the file it used to be
cited from leaves the tree:

- copied into this repository on 2026-08-11 from the MD4Lean package as the
  measurement target `lean-projects` pins it,
  `.lake/packages/MD4Lean/md4c/{md4c.c,md4c.h,LICENSE.md,CHANGELOG.md}`, at
  MD4Lean rev `6a3fb240133bcb7e1a066fdc784b3fdc304e3fc5` (`lake-manifest.json`);
  the version is md4c's own `CHANGELOG.md`;
- copied into this directory on 2026-08-30 from that first copy, and
  **byte-identical to it** (`/usr/bin/diff -q`, all three files).

Being the same bytes is the point. doc-gen4 parses docstrings with this md4c,
`crates/litedoc4-md` parses them with this md4c, and the Lean half compiled from
this directory parses them with this md4c — so the three agree by construction
rather than by version number.

## This is the copy the Lake package builds

`lakefile.lean`'s `md4cObj` target compiles `vendor/md4c/md4c.c` with the Lean
toolchain's own clang, and `lean_exe litedoc4` links the result. A consumer who
writes `require «litedoc4»` builds these bytes; nothing else in the tree is on
that path.

`crates/litedoc4-md/vendor/md4c/` is the Rust half's copy of the same three
files. Two copies exist because Lake builds a package from the package
directory: a `target` here cannot reach into `crates/` without making the
package's build depend on the layout of a sibling tree, and a symlink would not
survive a checkout on every platform. The Rust half is scheduled to leave the
tree, and this copy is the one that stays.

**Do not edit these files.** Any local change is a place where this parser and
doc-gen4's can silently disagree — and the check that they do not is
`benchmarks/results/purelean-md4c-2026-08-30.txt`, which compares 422 rendered
pages against the Rust half.

## What is deliberately not copied

`entity.c` / `entity.h` / `md4c-html.c` / `md4c-html.h` are md4c's HTML
renderer. Nothing here uses it: `src/Litedoc4/Md.lean` takes the callback stream
and the renderer builds the HTML itself, the same division doc-gen4 and the Rust
half use. `md4c.c` includes only `md4c.h` and standard headers, so the parser
builds without them.

## Updating

While both copies exist they move together, or the "same parser by
construction" claim above is no longer true: re-copy from
`crates/litedoc4-md/vendor/md4c/` and record the date here. Once that copy is
gone, this directory is the origin and an update means a new md4c release —
record the release and re-run the 422-page comparison against the frozen Rust
output before taking it.
