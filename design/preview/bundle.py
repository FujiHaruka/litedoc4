#!/usr/bin/env python3
"""Inline the shipped stylesheet, script and icon into one standalone preview.

The preview pages reference `assets/` directly — those are the files that ship,
and keeping a second copy here is how the two drift. This script exists only
because the places a preview gets looked at (a chat attachment, a published
page) serve a single file with no siblings.

All three files are in `assets/`, so this needs no build. `app.js` is committed
there for the Lean half, which cannot run vite; that it is the bundle vite
produces is checked by `the_committed_bundles_match_what_build_rs_bundled` in
`crates/litedoc4-render/src/assets.rs`.

    python3 bundle.py [out.html] [page.html]
"""

import base64
import pathlib
import sys

HERE = pathlib.Path(__file__).parent
ROOT = HERE.parent.parent
ASSETS = ROOT / "assets"
REF = "../../assets"


def bundle(page: str = "module.html") -> str:
    html = (HERE / page).read_text(encoding="utf-8")
    css = (ASSETS / "style.css").read_text(encoding="utf-8")
    js = (ASSETS / "app.js").read_text(encoding="utf-8")
    icon = base64.b64encode((ASSETS / "favicon.svg").read_bytes()).decode()

    html = html.replace(f'<link rel="stylesheet" href="{REF}/style.css">', f"<style>\n{css}\n</style>")
    html = html.replace(f'<script type="module" src="{REF}/app.js"></script>', f'<script type="module">\n{js}\n</script>')
    return html.replace(f'href="{REF}/favicon.svg"', f'href="data:image/svg+xml;base64,{icon}"')


if __name__ == "__main__":
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "preview-bundle.html")
    text = bundle(sys.argv[2] if len(sys.argv) > 2 else "module.html")
    if REF in text:
        raise SystemExit(f"an asset reference survived inlining — did {REF} move?")
    out.write_text(text, encoding="utf-8")
    print(f"{out}: {len(text)} bytes")
