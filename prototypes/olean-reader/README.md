# Olean reader prototypes — frozen reference

The prototypes behind `docs/multiversion/plan.md` U9 (the `.olean` reader, the hybrid environment,
the environment patch, the print-reuse key, the oracle), copied as they were on 2026-10-06 from the
work area they were measured in. Lean v4.34.1, built there against a Mathlib v4.34.1 workspace.

- **Not built, not run, not part of the package.** No gate reads this directory, and the root
  `lakefile.lean` does not see it. Environment-variable switches, the hard-coded prefix list and
  the literal key index list are prototype-only.
- **Step 5 of `docs/multiversion/implementation.md` ports from here into `src/`** and deletes this
  directory when it does.
- The writer record for Lean v4.29.0 is not in `OleanReader.lean` here; it is in the diff inside
  `benchmarks/results/mathlib-oldest-release-drift-2026-10-05.txt` (section
  "OleanReader.lean: diff against the reader log's OleanReader.lean").
- `differential-design.md` is the design memo the patch-path experiments followed; the numbers in
  it are the memo's, and the measured ones are in the logs the plan cites.
