---
title: Performance
description: How long litedoc4 and doc-gen4 take, under which conditions, with the logs.
---

| | doc-gen4 | litedoc4 |
|---|---:|---:|
| A package of 419 modules on Mathlib | documents all of Mathlib too | **14 s** |
| Batteries | 80 s | **8.5 s** |
| Mathlib | 1 h 53 min | **9.4 min** |

All values are (measured), on GitHub-hosted `ubuntu-latest` runners on 2026-10-17. The rows answer different questions, so read each with its conditions below. Each log is in [`benchmarks/results/`](https://github.com/FujiHaruka/litedoc4/tree/main/benchmarks/results).

## A package of 419 modules on Mathlib

- **What:** `litedoc4 build` of the [information-theory](https://fujiharuka.github.io/information-theory/) package's `InformationTheory` library, 419 modules, one version, from an empty `--out`, `--jobs 4`. It took 14.1 s, of which extraction was 10.8 s.
- **Where:** that package's own docs workflow, with the litedoc4 v2.0.0 action. Lean v4.31.0. The package was built earlier in the same job, so its oleans had just been written or restored.
- **Not counted:** building the extractor (17.6 s) and the `litedoc4` executable (48.2 s), which happens once and is then cached, and the package's own `lake build`.
- **Runner:** `ubuntu-latest`. The log does not print the CPU and memory. 4 vCPU and 16 GB is that runner class for a public repository (assumed).
- **One run.** A single value, not a converged series.
- **doc-gen4** was not run on this package. It documents the whole import closure, so it would document all of Mathlib too.
- **Log:** [`benchmarks/results/information-theory-ci-2026-10-17.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/benchmarks/results/information-theory-ci-2026-10-17.txt)

## Batteries

- **What:** Batteries v4.35.0, documented by both tools on the same runner, rounds alternating between the tools. Both tools document the same 195 modules, because Batteries depends on nothing but Lean core. litedoc4 `build` with its defaults; doc-gen4 `lake build Batteries:docs`.
- **Values:** medians of 5 warm rounds, 4 parallel jobs: litedoc4 8.5 s, doc-gen4 80.5 s. Peak memory of the process tree: litedoc4 198 MiB, doc-gen4 2,277 MiB.
- **doc-gen4's time includes** its final HTML pass, which also writes Lean core's 2,505 pages. A doc-gen4 user cannot avoid that pass.
- **Excluded from both:** building doc-gen4 and its database of Lean core, and building the litedoc4 extractor.
- **Runner:** `ubuntu-latest`, AMD EPYC 7763, 4 vCPU, 16 GB. Lean v4.35.0, doc-gen4 v4.35.0.
- **Log:** [`benchmarks/results/batteries-docgen4-litedoc4-2026-10-17.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/benchmarks/results/batteries-docgen4-litedoc4-2026-10-17.txt)

## Mathlib

- **What:** Mathlib v4.35.0's documentation from nothing, both tools one after the other on the same runner. litedoc4 `build --lib Mathlib`, one version, empty `--out`, `--jobs 4`: 565.7 s. doc-gen4 `lake build Mathlib:docs` plus `Mathlib:docsHeader`, with Lake's default parallelism (4 jobs): 6,773 s.
- **The scopes are different.** litedoc4 documents the 8,625 modules of the `Mathlib` library and links its dependencies. doc-gen4 also documents the dependencies and Lean core: 11,548 HTML files against litedoc4's 8,631 pages. So the ratio is not a measure of the same work.
- **Equations favour litedoc4.** litedoc4 ran with `no_equations_under = ["Mathlib.Tactic", "Mathlib.Meta"]` and generated no equations for definitions under those namespaces. doc-gen4 has no such setting and computes equations for every definition.
- **Not counted in either:** building litedoc4, building doc-gen4, and `lake exe cache get`.
- **Runner:** `ubuntu-latest`, AMD EPYC 7763, 4 vCPU, 16 GB. Lean v4.35.0, doc-gen4 v4.35.0. The oleans had just been written by `lake exe cache get`.
- **One run per tool.**
- **Log:** [`benchmarks/results/docgen4-runner-2026-10-17.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/benchmarks/results/docgen4-runner-2026-10-17.txt)

## Twelve Mathlib releases in one site

[mathlib.fuji.land](https://mathlib.fuji.land) holds twelve Mathlib releases, built and deployed by one workflow on `ubuntu-latest` (4 vCPU, 16 GB), `--jobs 4`. One run each:

- **All twelve from an empty store:** 84.6 min of build.
- **Adding the twelfth to a deployed site of eleven:** 11.6 min of build, and 18.5 min from the start of the job to the deployed site passing its checks. The eleven versions already in the store were neither extracted nor rendered again.
- **Logs:** [`benchmarks/results/mathlib-site-first-run-2026-10-17.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/benchmarks/results/mathlib-site-first-run-2026-10-17.txt), [`benchmarks/results/mathlib-site-add-one-2026-10-17.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/benchmarks/results/mathlib-site-add-one-2026-10-17.txt)
