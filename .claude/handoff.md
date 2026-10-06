# Handoff — 2026-10-07 (multi-version: step 2 done)

## State

- Branch `multi-version`, pushed. Not `main`; no PR open. `ci.yml` green at `3adb63a`
  (run 37518150463); nothing in `src/` changed since.
- SoT: `docs/multiversion/plan.md` and `docs/multiversion/implementation.md`. Step 2 is marked
  **Done 2026-10-07**; its "Carried to step 3" list is what step 3 inherits.
- Step 2 on M (→ `benchmarks/results/mv-m-render-2026-10-07.txt`): render-twice and
  each-version-alone identities hold; 3,196 files / 4.88 MB hosted for three versions; a patch
  release adds 3 data files + 440 shells; ≈ 169 / 693 MB at 11 / 51 Mathlib versions
  (extrapolated); render 3.2 s CPU and ≈ 220 MiB per M version.
- New tool: `benchmarks/tools/mv-m-render.sh` (renders a store N times + each version alone, lays
  the output out by kind, reconciles with the renderer's counts).

## Relay control
- Mode: DONE
- Goal: step 2 of `docs/multiversion/implementation.md` ("The multi-version renderer") to its
  "Done when", including the four items step 1 carried to it. Leg plan from the user:
  implementation and measurement in separate legs.
- Leg: 2 / cap 8
- Predecessor: none (r1 killed)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Summary: step 2 done — implemented and gated on S (r1), measured on M (r2). The one
  optimisation lever found (dependency line ranges out of page files) trades hosted bytes against
  per-view bytes, so it was handed to step 3 rather than acted on.
- Progress ledger
  - r1: implemented and gated on S — record schema 3 `53dbc61`; per-page links + docstring words
    `de6bef7`; `store render` `3417628`; site config in the store `3adb63a`
  - r2: M store regenerated at schema 4; render measured and logged `780e2f9`, `d57a77d`; plans
    recorded and step 2 marked Done (this commit)

## Next step (step 3, not started)

Step 3 ("The page in the browser") of `implementation.md`. Read step 2's "Carried to step 3"
first: what a page fetches (dependency line table vs per-page lines; the module list; Used by as
a fourth fetch) is step 3's decision, and the numbers for each side are in the M render log
sections (4)–(5).

## Load-bearing context

- **Kept on purpose** (this session made them; the next session owns them):
  `/private/tmp/lean-doc-relay/mv-m/store` (13 MB, the three M entries at schema 4; regenerating
  costs ≈ 6 min + network via `benchmarks/tools/mv-m-run.sh`) and
  `/private/tmp/lean-doc-relay/mv-m-render/all-1` (15 MB, a rendered M site — step 3's browser
  input). `mv-m/measure` was deleted (re-askable). `mv-v4320` / `mv-v4341` (7.7 + 7.6 GB) are kept
  as before. Disk ≈ 12 GiB free.
- The S store at `/private/tmp/lean-doc-relay/mv-s/store` is schema 2 (old); `tools/mv-s-gate.sh`
  builds its own.
- Timing noise: another macOS user's Chrome holds compressed memory and 2.8 GB of swap; read CPU
  time and counters first.
- `tools/md-memory-gate.sh` does not cover `vendor/miniz` / `csrc/gzip.c` yet.
- `tools/purelean-render-gate.sh` needs `/private/tmp/lean-doc-relay/purelean` (absent); not run.
- Communicate with the user in Japanese, brief-me style, no code names in briefs.
