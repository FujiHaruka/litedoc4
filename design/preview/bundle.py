#!/usr/bin/env python3
"""Inline the shipped stylesheet, script and icon into one standalone preview.

The preview pages reference `crates/litedoc4-render/assets/` directly — those
are the files that ship, and keeping a second copy here is how the two drift.
This script exists only because the places a preview gets looked at (a chat
attachment, a published page) serve a single file with no siblings.

`style.css` and `favicon.svg` sit in `assets/`. **`app.js` does not**: since
the site's JavaScript became TypeScript, `crates/litedoc4-render/build.rs`
bundles `web/src/` into `OUT_DIR` and the result is never committed. So it is
read out of the build directory, and running this needs a build first.

    cargo build -p litedoc4-render
    python3 bundle.py [out.html] [page.html]
"""

import base64
import pathlib
import sys

HERE = pathlib.Path(__file__).parent
ROOT = HERE.parent.parent
ASSETS = ROOT / "crates" / "litedoc4-render" / "assets"
REF = "../../crates/litedoc4-render/assets"


def app_js() -> str:
    """The bundled `app.js`, newest first.

    The path carries cargo's hash for the crate, and a tree can hold several
    (one per profile, plus stale ones from earlier builds), so the newest is
    the one this build produced rather than the one that happens to sort first.
    """
    built = sorted(
        ROOT.glob("target/*/build/litedoc4-render-*/out/app.js"),
        key=lambda path: path.stat().st_mtime,
    )
    if not built:
        raise SystemExit(
            "no app.js under target/: it is built, not committed "
            "(build.rs bundles web/src). Run `cargo build -p litedoc4-render` first."
        )
    return built[-1].read_text(encoding="utf-8")


def bundle(page: str = "module.html") -> str:
    html = (HERE / page).read_text(encoding="utf-8")
    css = (ASSETS / "style.css").read_text(encoding="utf-8")
    js = app_js()
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
