# miniz — where these files came from

miniz **3.1.2**, MIT © 2013-2014 RAD Game Tools and Valve Software,
© 2010-2014 Rich Geldreich and Tenacious Software LLC. Keep `LICENSE` next to
the sources when redistributing.

- downloaded on 2026-10-06 as the release asset
  `https://github.com/richgel999/miniz/releases/download/3.1.2/miniz-3.1.2.zip`
  (SHA-256
  `f0446d863f9c19926ad9483c523fdc42e42b8d4a6a431d27e09d49c79a140d9a`, equal to
  the `digest` GitHub's release API reports for that asset);
- `miniz.c`, `miniz.h` and `LICENSE` copied out of it unmodified:

  | file | SHA-256 |
  |---|---|
  | `miniz.c` | `e2c1aeb66eef9191d8c3feb164db2def2335a61d039bf04ed849f6b042433b30` |
  | `miniz.h` | `b53b62ed122e559b8f679e3cb787a0b0035fe87a58f909da0e44931678f4e85f` |
  | `LICENSE` | `0115478d567121238cf6cc1c0c361926cf07a49d9e4c9e66da97fac6a01646b3` |

The release asset is the single-file amalgamation upstream builds for exactly
this use; the repository's `miniz_tdef.c` / `miniz_tinfl.c` / … split is the
same code before that step.

## This is the copy the Lake package builds

`lakefile.lean`'s `minizObj` target compiles `vendor/miniz/miniz.c` with the
Lean toolchain's own clang, and both executables link it. `csrc/gzip.c` is what
calls it: miniz has deflate and inflate but no gzip framing, so the header, the
CRC-32 trailer and the refusals are written there.

**Do not edit these files.** Configuration is by `-D` in `lakefile.lean`'s
`minizFlags`, which both `miniz.c` and `csrc/gzip.c` are compiled with, so the
two agree on what `miniz.h` declares:

| macro | why |
|---|---|
| `MINIZ_NO_STDIO` | no file API is used, and `csrc/libc` has no stdio declarations to offer it |
| `MINIZ_NO_TIME` | the same for `time.h`; only the ZIP archive API reads the clock |
| `MINIZ_NO_ARCHIVE_APIS` | nothing here reads or writes ZIP archives |
| `MINIZ_NO_ZLIB_APIS` | the zlib-compatible stream API and its names (`deflate`, `crc32`, …) are not used; leaving them out also leaves out names that could collide with another zlib at link time. `mz_crc32` and the `tdefl_` / `tinfl_` functions stay |
| `MINIZ_USE_UNALIGNED_LOADS_AND_STORES=0` | the 3.1.2 default on every CPU, written down so that a later default cannot give one platform a different match finder and so different compressed bytes |

What this costs in `csrc/libc` is one function, `abort`, reached only through
`assert`, and an `assert.h` (`csrc/libc/README.md`).

## What is deliberately not copied

`examples/`, `readme.md` and `ChangeLog.md` from the same archive. The change log
is upstream's, at the tag; this file records the version.

## Updating

This directory is the origin, so an update means a new miniz release. Record the
release, its digest and the three files' digests here. The test
`aFixedInputCompressesToThePinnedBytes` pins one compressed member byte for byte
and will fail on any release whose deflate output differs; that is the point at
which compressed sizes recorded elsewhere stop describing what is built.
