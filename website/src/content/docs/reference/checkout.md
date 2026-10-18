---
title: Running from a checkout
description: Build litedoc4 from a clone of this repository and document a package with it.
---

```sh
git clone https://github.com/FujiHaruka/litedoc4 && cd litedoc4
tools/ci-build.sh --root /path/to/your-package --out /path/to/docs
```

This builds both executables with your package's toolchain and then documents the package. It leaves `litedoc4` in `.lake/build/bin/` and the extractor in `extractor/build/`. Running the script again reuses both.

`lake` does not run next to this repository's own `lakefile.lean`, because the repository has no `lean-toolchain`. So the script writes a one-line package under `.lake/host` that requires this checkout, copies your package's `lean-toolchain` into it, and builds from there.

To watch from a checkout:

```sh
.lake/build/bin/litedoc4 watch --root /path/to/your-package --out /path/to/docs \
  --extractor-bin extractor/build/extract
```
