# Hosting Mathlib's documentation

What this repository needs to build and serve a documentation site for every public Mathlib
release. Mathlib's own repository is not changed: everything the site needs from outside it lives
here.

| File | What it is |
|---|---|
| `litedoc4.toml` | The site's config, given to `litedoc4 build --config` in place of a `litedoc4.toml` Mathlib does not have: the title, the footer, and no equations for the definitions under `Mathlib.Tactic` and `Mathlib.Meta` |
| `footer.md` | The footer on every page: Mathlib's license and copyright, and that the site is not Mathlib's own |
| `versions.sh` | The version set: every release on Mathlib's Releases page that is not a draft or a prerelease, in version order (`gh`, authenticated) |

## Building it

From a clone of `leanprover-community/mathlib4` with its release tags, and elan's `lake`:

```
litedoc4 build --root <mathlib clone> --lib Mathlib --out <out> \
  --versions "$(hosting/mathlib/versions.sh)" \
  --config hosting/mathlib/litedoc4.toml --lake "$(command -v lake)"
```

`<out>/store` holds every version built, and keeping it between runs is what makes adding a new
release extract only that release. Then `tools/served-gate.sh --declared "$(hosting/mathlib/versions.sh)"
--out <out> --url <where the site is served>` checks that every version in the set was built and
is served.

## Where it is served

`https://mathlib.fuji.land`, a custom domain of the Cloudflare R2 bucket `mathlib-docs`. The store
lives in a second bucket, `mathlib-docs-store`, which no domain serves, beside an archive of the
site as deployed with its render ledger. `tools/mathlib-site.sh`, run by
`.github/workflows/mathlib-site.yml`, restores the store and the archive, so a build renders only the
versions the deployed site does not hold; then it builds, saves the store, uploads the files the
build wrote, archives the site again, and checks the site as served. It needs the repository secrets
`R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`, a token with object read and write on both buckets.
The workflow runs only when started by hand (Actions → Mathlib site → Run workflow), on `main`.

R2 answers a path with the object of that exact key and has no directory index, so the `fuji.land`
zone carries a URL rewrite rule: when the host is `mathlib.fuji.land` and the path ends with `/`,
the path becomes `concat(http.request.uri.path, "index.html")`. Without it the site root and each
`<version>/` answer 404. A path with no object answers Cloudflare's own 404 page rather than the
site's `404.html`, so a versionless link in doc-gen4's shape (`Mathlib/Order/Basic.html`) does not
reach the newest version here.

## The license notice

Mathlib is released under the Apache License 2.0, which allows redistributing it and works derived
from it on condition that recipients get the license, the copyright notices are kept, and changes
are stated. The pages carry Mathlib's docstrings and declarations reformatted, so `footer.md` links
the license, names the copyright holders, and says the pages are generated rather than Mathlib's
own. The license grants no rights to the name, so the footer also says the site is not affiliated
with or endorsed by the Mathlib project.
