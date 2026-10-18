---
title: Commands and flags
description: The build and watch commands and the flags you are most likely to need.
---

```
litedoc4 build  --root <repo> --out <dir> [--lib <Name>]... [--versions <list>]
                [--jobs <n>] [--source-url <url>] [--config <file>] [--full]
litedoc4 watch  --root <repo> --out <dir> [--lib <Name>]... [--jobs <n>] [--port <n>]
```

`build` writes the site once. `watch` serves it and rebuilds it when the package's oleans change ([Watching while you work](/litedoc4/guides/watch/)).

`lake run docs` fills in `--root`, `--lib` and `--extractor-bin` for you. Call the commands directly for `watch` and for flags that `docs` does not pass. After the first `lake run docs`, both executables are in `.lake/packages/litedoc4/.lake/build/bin/`. `litedoc4 --help-all` lists every flag.

## Flags

| Flag | Commands | What it does |
|---|---|---|
| `--root <repo>` | build, watch | The Lean package to document |
| `--out <dir>` | build, watch | The directory litedoc4 owns. The site is `<out>/site`. It must be outside the package, and a relative path is read from the package directory |
| `--lib <Name>` | build, watch | A library root, repeatable. Needed when the libraries cannot be read from `lakefile.toml`, as in most `lakefile.lean` packages |
| `--full` | build | Extract every module again |
| `--jobs <n>` | build, watch | Threads for hashing the oleans and for the extractor |
| `--source-url <url>` | build, watch | Base URL for source links, when `origin` is not GitHub |
| `--config <file>` | build, watch | A file read instead of the package's `litedoc4.toml` ([Configuring the site](/litedoc4/guides/configuration/)) |
| `--versions <list>` | build | Tags, branches or commits, separated by commas, the newest last ([Several versions](/litedoc4/guides/versions/)) |
| `--store <dir>` | build | With `--versions`, where the built versions are kept. Default: `<out>/store` |
| `--hash-urls` | build, watch | Serve every page from the root `index.html`, with the route in the URL fragment |
| `--extractor-bin <path>` | build, watch | A prebuilt extractor. Without it, one is built for the Lean that `--root` pins |
| `--lake <path>` | build, watch | The `lake` executable to use |
| `--timings <file>` | build | Write one JSON line of counts and durations |
| `--port <n>` | watch | The port to serve on. Default: 8484 |
| `--interval <ms>` | watch | How often to check for changed oleans, in milliseconds. Default: 1000 |
