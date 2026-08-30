/* See README.md in this directory.

md4c includes <stdio.h> unconditionally but calls nothing from it — its `abort`
occurrences are a goto label, not the libc function (measured 2026-08-30). So
this header is deliberately empty: it exists to satisfy the include, and the
day something does call a stdio function the build fails with that name, which
is the point. */
#ifndef LITEDOC4_SHIM_STDIO_H
#define LITEDOC4_SHIM_STDIO_H
#endif
