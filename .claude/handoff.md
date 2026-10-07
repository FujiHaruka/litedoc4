# Handoff — 2026-10-08 (multi-version: render memory explained; next = one process per version)

## State

- Working directory: /Users/haruka/dev/lean-doc
- Branch `multi-version`, pushed, clean. Not `main`; no PR open.
- Working context: the user chose (2026-10-08) "one process per version" as the fix for the
  per-version memory growth. Nothing of it is written yet.

## Where we are

The cause is measured and logged (`benchmarks/results/mv-l-render-memory-2026-10-08.txt`,
implementation.md step 4 "On L"): Lean's bundled mimalloc 2.2.3 (every toolchain in
`tools/lean-toolchains.txt`) never reuses or returns a freed block of 66 MiB (40 MiB is reused;
threshold between, not narrowed). `Store.read` allocates two such blocks per version (63 MiB
compressed entry, 538 MiB inflated pack) → +~0.6 GiB per version read in one process. Nothing
litedoc4 retains is involved. Full render peak ≈ 3.67 + 0.585 (n−1) GiB on the runner.

## Next step

Make every per-version step that reads or writes a store entry run in its own child process, so
the peak stops depending on the version count:

1. **Render**: `Data.SiteLedger.renderSite` (and `Data.Site.renderStore`) call `writeEntry` per
   version in-process. Spawn the litedoc4 executable itself per version (an internal, undocumented
   subcommand is fine — `tools/public-surface.txt` is the promise list; keep it off that list and
   off `--help`, or the `@usage` block in `tools/refusals.txt` must be refrozen). The child returns
   what the parent needs (`Written`: counts, `Listed`, paths) on stdout as JSON; the root files and
   ledger stay in the parent.
2. **build --versions put loop** (`src/Litedoc4/Main.lean` ~850–885): `Store.put` packs + gzips
   per version in the build process. Growth there is **inferred, not measured** — measure first
   (S is too small; L only on the runner) or just move put into the child too.
3. Gate with a count, not RSS: e.g. "render processes spawned = versions rendered" in the
   counts JSON / S gate (`tools/mv-s-gate.sh`), each new item made to fail once.
4. Verify on L: re-run `mv-l.yml` (push to `benchmarks/tools/mv-l-run.sh` triggers it, ~60 min);
   `render-alone default` should give flat ~3.7 GiB for 1/2/3. Byte-identical site vs before is
   the correctness check (`*-site.sha256` in the run artifact).

## Files to read first

- `benchmarks/results/mv-l-render-memory-2026-10-08.txt` — the evidence and the numbers to beat
- `src/Litedoc4/Data/SiteLedger.lean` — `renderSite`, the build's render loop (line ~181)
- `src/Litedoc4/Data/Site.lean` — `writeEntry` / `writeVersion` / `renderStore`
- `src/Litedoc4/Main.lean` — `build --versions` loop (~820–890), `storeRender` (~1543)

## Load-bearing context

- Ruled out with measurements (don't redo): glibc tunables, `MIMALLOC_PURGE_DELAY=0`,
  `MIMALLOC_DISALLOW_ARENA_ALLOC=1` (worse), `MIMALLOC_ARENA_EAGER_COMMIT=0`, `mi_collect(true)`.
  macOS footprint/RSS can't separate retained from freed (compressor) — use Linux `/proc` floors.
- Lean v4.34.1 ships mimalloc 3.4.4; untested whether it keeps the block. Not a supported row yet.
- Experiment code is readable at commit 070e030 (`litedoc4_exp_*` in `csrc/gzip.c`, phases in
  `renderStore`, `.github/workflows/mv-l-render.yml`); removed in ab086f9.
- Run 37630692670's artifact `mv-l-store` (3 L entries) expires 2026-10-21; a local copy is at
  `/private/tmp/lean-doc-relay/mv-l-r3/store` (190 MB). Disk ≈ 8.8 GiB free.
- GitHub pushes returned 500 for ~5 min once; a retry loop got through. A workflow whose step
  name contains ": " is invalid YAML and silently creates no named run — validate with
  `python3 -c "import yaml; yaml.safe_load(open(...))"`.
- `mv-l.yml` still has the glibc-tuned arm (e) (proved useless; drop it when next editing) and a
  `push:` trigger on this branch (make dispatch-only before merging).
- Open items from before (unchanged): kept versions' bibliography warning not printed; partial
  render reports ledger `dataAdded`; step 6 needs the deployed site at `<out>/site`; dead links not
  reported; version rule not built; README pins v1.4.0; hash-mode not covered by browser items.
- Communicate with the user in Japanese, brief-me style.
