# Handoff — 2026-10-07 (multi-version: step 3 done)

## State

- Branch `multi-version`, pushed. Not `main`; no PR open. `ci.yml` green at `0316a55` (run
  37559545386).
- SoT: `docs/multiversion/plan.md` and `docs/multiversion/implementation.md`. Step 3 is marked
  Done; its "What exists" block carries the settle time, the re-derived M numbers and the six
  decisions. Next is step 4 ("One command over the version set").
- Waiting on the user: confirmation of D6's four defaults (plan.md D6, "Implemented with proposed
  defaults").

## Relay control
- Mode: DONE
- Goal: step 3 of `docs/multiversion/implementation.md` ("The page in the browser") to its
  "Done when".
- Leg: 2 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Summary: the drawn largest page settles in 217 ms against 322 ms static (same session); the D9
  check existed from r1. Hash mode now fetches three files in a row before drawing; the other
  levers were measured and kept. D6 defaults await confirmation.
- Progress ledger
  - r1: implemented and gated on S — drawn pages + assets `5281a10`; switcher, search, on-demand
    `c60c898`; root / 404 / canonical / hash-URL mode `a1fec28`; D9 gate failed once `9ddc4bf`;
    plans recorded (the commit after it)
  - r2: settle time `a5d2293`; M re-derived + render-script hash-mode fix `2ec2851`; version list
    in the hash root `a53153a`; step 3 recorded and done `0316a55`

## Load-bearing context

- **Kept**: `/private/tmp/lean-doc-relay/mv-m/store` (the three M entries); `mv-m-settle` (61 MB:
  the one-version StructuredArrow slice's store, static and drawn sites, logs — the settle
  measurement's input); `mv-m-render-path` / `mv-m-render-hash` (15 + 9.6 MB); `mv-s-gate`;
  `mv-v4320` / `mv-v4341` (7.7 + 7.6 GB). Disk ≈ 11 GiB free (95% full).
- Path mode now validates `versions.json` (a malformed list shows no switcher).
- `tools/md-memory-gate.sh` does not cover `vendor/miniz` / `csrc/gzip.c` yet.
- Communicate with the user in Japanese, brief-me style, no code names in briefs.
