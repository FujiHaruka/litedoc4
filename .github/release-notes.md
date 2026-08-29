Fast HTML documentation for Lean 4 packages that depend on Mathlib. litedoc4 documents **your**
package only; every reference to a dependency links to that dependency's version-pinned source on
GitHub. [README](https://github.com/FujiHaruka/litedoc4#readme) is the manual, and there are two
live examples: [422 modules](https://fujiharuka.github.io/information-theory/) built by this
release, and [seven](https://fujiharuka.github.io/litedoc4/) rebuilt from `main` on every push.

## Pin to this tag

```yaml
- uses: FujiHaruka/litedoc4@v@VERSION@
```

```lean
require «litedoc4» from git "https://github.com/FujiHaruka/litedoc4" @ "v@VERSION@"
```

One pin is enough: the action and the Lake script both resolve the `litedoc4` binary by the
version in the ref you pinned, so the extractor and the binary always come from the same tree.

## What 1.x keeps

The names your own files can contain do not move inside 1.x: the action's ten inputs and four
outputs, `litedoc4.toml`'s keys, `build`'s and `watch`'s flags, and the site's page paths
(`Foo/Bar.html`) and declaration anchors (`#Foo.bar`). The list is `tools/public-surface.txt`, and
CI fails when one of those names goes missing.

The IR schema, the ledger and `.lidx` are internal, and you never pin them yourself.

## Lean versions

v4.31.0, v4.32.2, v4.33.0 and v4.33.1. Every one of them is built and run end to end on each
change to the extractor or the fixture, and their output is compared: they write byte-identical IR
once Lean's own rename of a reducible instance's reducibility status is applied, which is the only
recorded difference between them. A toolchain that is not in `tools/lean-toolchains.txt` fails by
name rather than by bad output.

## What the archives carry

`litedoc4-x86_64-unknown-linux-musl.tar.gz`, `litedoc4-aarch64-unknown-linux-musl.tar.gz` and
`litedoc4-aarch64-apple-darwin.tar.gz`, each holding the binary plus `LICENSE` and `NOTICE`, with
`checksums.txt` beside them. Every download is checked against that file before it is used.

Windows and Intel macOS build from source, which needs Rust, a C compiler and node. The Lean
extractor is never shipped as a binary: it is compiled against **your** toolchain.
