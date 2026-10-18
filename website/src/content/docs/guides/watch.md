---
title: Watching while you work
description: Serve the site locally and rebuild it when your oleans change.
---

```sh
B=.lake/packages/litedoc4/.lake/build/bin
$B/litedoc4 watch --root . --out ../mypkg-docs --extractor-bin $B/extract --lib MyPkg
```

The two executables are in `.lake/packages/litedoc4/.lake/build/bin/` after the first `lake run docs`.

`watch` serves the site on `http://127.0.0.1:8484/` (`--port` changes the port) and rebuilds it when your package's `.olean` files change.

- **It does not run `lake build`.** Run that in another terminal. `watch` sees the oleans it writes.
- **Its first pass is a `build`.** A `--out` that another litedoc4 run wrote is brought up to date before it is served.
- **It waits for `lake build` to finish.** It checks once a second (`--interval`) which modules are stale, and it rebuilds only when the answer has stopped changing. So it never reads oleans that are still being written. While it waits, it says what it is waiting for.
- **Each rebuild prints** how many modules were extracted again and how long it took.
- **Reload the tab yourself.** The pages it serves are the files it wrote, with no live-reload script added. What you see is what you will publish.
- **A port that is in use is refused** by name. `watch` does not move to another port.
