# Handoff — 2026-10-11 (multi-version: 11 readers in; step 3 waits on hosting)

## State

- Working directory: /Users/haruka/dev/lean-doc
- Branch: multi-version (pushed; no PR). Clean after the handoff commit.
- Working context: the three steps the user ordered on 2026-10-11 — (1) the store record says whose prints an entry reused, (2) reader records for the remaining releases then delete the prototype, (3) CI/hosting with no full-Mathlib measurement until the user approves.

## Where we are

- Step 1 done (d74a0bf): store schema 5 carries `reusedFrom`; an exact read refills reused or unrecorded entries; the chain keeps exact ones. mv-reader-gate 20 of 20.
- Step 2 done: reader records for all 11 releases (6ea63ee: v4.32.1, v4.34.0; 852d575: v4.30.0, v4.29.1, v4.29.0 — simp flag count, extension renames and core header version are record data). reader-hybrid-gate 35/35, mv-reader-gate 20/20. `prototypes/olean-reader/` deleted (4612689; read it at `git show 852d575:prototypes/olean-reader/`).
- Step 3, the part that needs no account: `tools/served-gate.sh` (1a9956d), the plan's `<built> of <declared>` gate, `manual`, made to fail once on micro in both URL modes. Never run against a live host or with dotted release names.
- After the pause, on the user's word (2026-10-11): the resident reader session is removed (1655b76, −2,846 lines); `footer` in litedoc4.toml and `build`/`watch --config <file>` (77ea5e1); `hosting/mathlib/` holds Mathlib's config, its license footer (Apache-2.0, copyright, not affiliated) and `versions.sh`. The deploy workflow reads `hosting/mathlib/`.

## Next step (blocked on the user)

1. Cloudflare R2 (decided 2026-10-16, user's call): bucket `mathlib-docs`, served at `mathlib.fuji.land` (fuji.land's DNS moved to Cloudflare; account `ab236b68c2f6f5943bc40abfe51aba70`). Secrets `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` set 2026-10-15. Still open: the custom domain is not yet connected to the bucket (no DNS record for `mathlib.fuji.land` as of 2026-10-16).
1b. Done 2026-10-16/17: `.github/workflows/mathlib-site.yml` + `tools/mathlib-site.sh` (e16c3ef; push trigger on multi-version naming those two paths — pushing either without `[skip ci]` STARTS THE PRODUCTION RUN). Lean v4.35.0 supported (76d7b81); Mathlib's set is now 12 releases.
1c. Done 2026-10-17: `mathlib.fuji.land` connected to `mathlib-docs` (HTTPS answers; 404 while empty) and the rewrite rule `mathlib directory index` deployed on the fuji.land zone (hosting/mathlib/README.md). The Cloudflare session is in Brave ("Browser 1" of the Chrome extension).
2. The workflow lives in this repo and reads `hosting/mathlib/` (user's call 2026-10-11, by asking for that directory).
3. Done 2026-10-17 (user approved "やろう"): first production run 38983206954 built all 12 from nothing (84.6 min) and deployed; its live check failed only because Cloudflare 403s urllib's default User-Agent. Fixed with rclone 1.75.2 and bucket checks (0fd31aa); second run 38992516164 green in 27.3 min, 0 of 12 extracted, render 14.1 min because the site directory is not restored. Logs: benchmarks/results/mathlib-site-first-run-2026-10-17.txt, mathlib-site-second-run-2026-10-17.txt. mathlib.fuji.land serves all 12.
4. In progress 2026-10-17 (user: "1をやって", skip the single-version comparison): measure adding one release in production. The render ledger is saved to the store bucket after a checked deploy; restore brings it and the deployed site back so only new versions render; deploy uploads only files the build wrote. Run A = workflow env MATHLIB_SITE_HOLD_BACK=v4.35.0 (11 versions; the live site lists 11 until B). Run B = replace it with MATHLIB_SITE_REEXTRACT=v4.35.0 (the measured add-one). After B, remove the knob with [skip ci]. Report build-command wall (the plan's 13.5 min row) and whole-run wall.
Then: the workflow (restore the store from an R2 prefix the site does not serve, `build --versions` with the 11 non-prerelease releases from the GitHub API, save the store, deploy, run served-gate against the live URL). A new workflow on a branch can only run through a `push:` trigger naming the branch, which would start the full run — so write it only once (3) is approved.

## Files to read first

- `docs/multiversion/implementation.md` — "### 6. CI, hosting and the full set"
- `tools/served-gate.sh`

## Load-bearing context

- User rules (also in memory): measure as lightly as possible — one run per arm, ±10% fine; full-Mathlib runs only after asking; Japanese brief-me, no code names.
- Subagent prompts: every command foreground, ≤ 9 min each; at most 1 subagent; tell it not to commit.
- Pushing `.github/workflows/mv-l.yml` or `benchmarks/tools/mv-l-run.sh` starts a full-Mathlib runner run. Ask first, or `[skip ci]`.
- Do not touch /private/tmp/lean-doc-relay/mv-v4341 or mv-v4320. After editing extractor/ or src/, rebuild with `tools/build-lean-exe.sh --toolchain-from e2e/micro` before gates (the reader source is embedded in the binary).

## Relay control
- Mode: PAUSED
- Goal: steps 1–3 above, no full-Mathlib measurement
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Paused on: user-decision — R2 account/domain/secrets, where the workflow lives, approval of the first full run
- Progress ledger:
  - r1: d74a0bf, 0f73c2b, 6ea63ee, 852d575, 4612689, 1a9956d (steps 1 and 2 done; step 3's gate); 1655b76, 77ea5e1 (session removed; footer, --config, hosting/mathlib)
