# md4c — where these files came from

Copied on 2026-08-30 from this repository's own first copy:

    crates/litedoc4-md/vendor/md4c/{md4c.c,md4c.h,LICENSE.md}

and **byte-identical to it** (`/usr/bin/diff -q`, all three files). That copy's
own `PROVENANCE.md` records the rest of the chain: it came from MD4Lean as the
measurement target pins it, and it is md4c **0.5.2**, MIT © 2016-2024 Martin
Mitáš. Keep `LICENSE.md` next to the sources when redistributing.

Being the same bytes is the point. doc-gen4 parses docstrings with this md4c,
`crates/litedoc4-md` parses them with this md4c, and now the Lean prototype
does too — so the three agree by construction rather than by version number.

## Why a second copy in the tree rather than a reference to the first

Lake builds a package from the package directory. A `target` here cannot reach
up into `crates/` without making the prototype's build depend on the layout of
a sibling tree, and a symlink would not survive a checkout on every platform.
If the pure-Lean renderer ever becomes the product, this directory and
`crates/litedoc4-md/vendor/md4c/` merge back into one.

**Do not edit these files.** Any local change is a place where this parser and
doc-gen4's can silently disagree — and the check that they do not is
`benchmarks/results/purelean-md4c-2026-08-30.txt`, which compares 422 rendered
pages against the Rust half.

## What is deliberately not copied

`entity.c` / `entity.h` / `md4c-html.c` / `md4c-html.h` are md4c's HTML
renderer. Nothing here uses it: `Md.lean` takes the callback stream and
`Render.lean` builds the HTML itself, the same division doc-gen4 and the Rust
half use. `md4c.c` includes only `md4c.h` and standard headers, so the parser
builds without them.

## Updating

Re-copy from `crates/litedoc4-md/vendor/md4c/` and record the date here. If that
copy moves to a new md4c release, both move together or the "same parser by
construction" claim above is no longer true.
