---
title: Coming from doc-gen4
description: What stays the same as doc-gen4 and what is different.
---

litedoc4 keeps doc-gen4's page paths, declaration anchors, docstring Markdown and bibliography format. Links and docstrings written for a doc-gen4 site work unchanged.

Each page path has the version in front of it, `<version>/Foo/Bar.html`, and keeps doc-gen4's shape after it. Declaration anchors are `#Foo.bar`. A link in doc-gen4's shape without the version goes to that page in the newest version, on a host that answers a missing path with the site's `404.html`. GitHub Pages does this.

## What is different

| | doc-gen4 | litedoc4 |
|---|---|---|
| Dependencies | Pages for your whole import closure | Your package only. Dependency names link to their source |
| Search | Every declaration you import | Your package's declarations |
| Math | MathJax, in the browser | MathML, when the site is built |
| Pages | Static HTML | Drawn by a script. Serve them over HTTP |
| Not in litedoc4 | | The tactics page, `find/?pattern=` links, declaration data as JSON, local-file and VS Code source links |

Dependency names link to their source at the revision you pinned, never to another documentation site.
