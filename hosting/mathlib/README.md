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

## The license notice

Mathlib is released under the Apache License 2.0, which allows redistributing it and works derived
from it on condition that recipients get the license, the copyright notices are kept, and changes
are stated. The pages carry Mathlib's docstrings and declarations reformatted, so `footer.md` links
the license, names the copyright holders, and says the pages are generated rather than Mathlib's
own. The license grants no rights to the name, so the footer also says the site is not affiliated
with or endorsed by the Mathlib project.
