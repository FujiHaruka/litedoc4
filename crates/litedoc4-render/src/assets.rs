//! The static assets a page needs to look like a page, carried in the binary.
//!
//! `include_str!` rather than files shipped next to the binary, so that **the
//! assets cannot be a version behind the renderer**. The CSS is coupled to
//! class names [`crate::decl`] and [`crate::frame`] emit; a stylesheet shipped
//! separately can be the one from before those names moved, and the failure is
//! a page that renders with half its rules silently not matching.
//!
//! `style.css` and `favicon.svg` are the bytes in the repository's `assets/`,
//! which is also where the Lean half's generated `src/Litedoc4/Assets.lean`
//! reads them from — one copy, two consumers. **`app.js` is not** — it is the
//! bundle `build.rs` compiles from the TypeScript in `web/`, read out of
//! cargo's `OUT_DIR`, for the same reason one level down. What it costs is
//! node, at build time, for whoever builds from source.
//!
//! These are **not** in the incremental render key
//! (`litedoc4_incr::render_key`), and that is a decision. A page's bytes do not
//! depend on these files — it names them in an `href` and the href does not
//! carry their content — so putting them in the key would re-render 432 pages
//! every time a CSS rule moved and buy nothing. What pays for it is that
//! [`write_assets`] runs on **every** build, full or incremental, so the tree
//! is never carrying yesterday's stylesheet either.

use std::fs;
use std::path::Path;

use crate::site::Error;

/// Each asset's path **under the site root**, paired with its bytes.
///
/// The paths are flat and relative because that is what the pages ask for:
/// [`crate::head_html`] builds every asset href as
/// [`crate::autolink::page_root`] of the page plus this name. A path added
/// later keeps `/` as its separator — it is a URL, not a filesystem path.
pub const ASSETS: [(&str, &str); 3] = [
    ("style.css", include_str!("../../../assets/style.css")),
    // `assets/app.js` is committed for the Lean half, which cannot run vite,
    // and this reads `OUT_DIR` anyway: a bundle that is a version behind its
    // sources is the failure `build.rs` exists to prevent, and the two are
    // reconciled by `the_committed_bundles_match_what_build_rs_bundled`.
    ("app.js", include_str!(concat!(env!("OUT_DIR"), "/app.js"))),
    ("favicon.svg", include_str!("../../../assets/favicon.svg")),
];

/// **Unconditional and idempotent**: it overwrites whatever is at each path
/// rather than asking whether it differs, because a build that skips an asset
/// because "it was already there" leaves an *edited* or truncated file in place
/// and nothing downstream would notice.
///
/// It is a whole-tree operation, so it is **not** part of
/// [`crate::render_site`]: that one is called per incremental round, sometimes
/// with no modules at all, and the assets have to land on those runs too.
pub fn write_assets(site: &Path) -> Result<(), Error> {
    fs::create_dir_all(site).map_err(|source| Error::Io {
        path: site.to_owned(),
        source,
    })?;
    for (name, body) in ASSETS {
        let path = site.join(name);
        fs::write(&path, body).map_err(|source| Error::Io { path, source })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use litedoc4_testutil::TempDirs;

    const TEMP: TempDirs = TempDirs::prefixed("litedoc4-assets");

    /// Matching on the **escaped** quote is what keeps prose out of the result:
    /// a doc comment writes `class="x"` with plain quotes, only a string
    /// literal writes `class=\"x\"`.
    fn emitted_classes(source: &str) -> Vec<&str> {
        const OPEN: &str = "class=\\\"";
        let mut out = Vec::new();
        let mut rest = source;
        while let Some(at) = rest.find(OPEN) {
            rest = &rest[at + OPEN.len()..];
            let Some(end) = rest.find("\\\"") else { break };
            out.extend(rest[..end].split_whitespace());
            rest = &rest[end..];
        }
        out
    }

    /// Every class the site's TypeScript assigns at run time. `x.className =
    /// "name";` and nothing else — the site's scripts have no other spelling
    /// (measured 2026-08-23: `rg 'className|classList|class='` over `web/src`),
    /// and a scanner that guessed at more shapes would be claiming a coverage
    /// it cannot check.
    fn scripted_classes(source: &str) -> Vec<&str> {
        const OPEN: &str = ".className = \"";
        let mut out = Vec::new();
        let mut rest = source;
        while let Some(at) = rest.find(OPEN) {
            rest = &rest[at + OPEN.len()..];
            let Some(end) = rest.find('"') else { break };
            out.extend(rest[..end].split_whitespace());
            rest = &rest[end..];
        }
        out
    }

    /// Every `.name` in the stylesheet, from anywhere in it — comments
    /// included. Deliberately crude: the direction that matters is "emitted but
    /// not styled", and over-collecting here can only make the test *milder*,
    /// never wrong. A `.5rem` is not picked up because the character after the
    /// dot has to be a letter.
    fn styled_classes(css: &str) -> std::collections::HashSet<&str> {
        let bytes = css.as_bytes();
        let mut out = std::collections::HashSet::new();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] != b'.' || !bytes.get(i + 1).is_some_and(u8::is_ascii_alphabetic) {
                i += 1;
                continue;
            }
            let start = i + 1;
            let mut end = start;
            while bytes
                .get(end)
                .is_some_and(|b| b.is_ascii_alphanumeric() || *b == b'-' || *b == b'_')
            {
                end += 1;
            }
            out.insert(&css[start..end]);
            i = end;
        }
        out
    }

    /// Not a lower bound on how many were found: the scripts assign 9 times
    /// and `search-empty` is two of them, so a threshold of 8 stays green
    /// through the first deletion and then blames the scan for the second. A
    /// name that arrives or leaves has to fail here as that name.
    const SCRIPTED_CLASSES: [&str; 8] = [
        "count",
        "kind",
        "node-name",
        "row",
        "search-empty",
        "twisty",
        "twisty-spacer",
        "where",
    ];

    /// The failure this catches is silent: a class renamed in `decl.rs` still
    /// renders, still validates, and simply has no styling.
    ///
    /// `litedoc4-md` also emits classes (`markdown-heading`, `hover-link`,
    /// `language-…`) and is not checked: those come out of a docstring, not out
    /// of a literal, and this test cannot see them.
    #[test]
    fn every_class_the_renderer_emits_is_styled() {
        let css = ASSETS
            .iter()
            .find(|(path, _)| *path == "style.css")
            .expect("the stylesheet is an asset")
            .1;
        let styled = styled_classes(css);

        let sources = [
            ("frame.rs", include_str!("frame.rs")),
            ("page.rs", include_str!("page.rs")),
            ("decl.rs", include_str!("decl.rs")),
            ("code.rs", include_str!("code.rs")),
        ];
        // Not a glob over `web/src`: `include_str!` needs a literal, and a
        // sixth file assigning a class would be invisible here. What catches
        // that is `tools/assets-gate.sh`, which reconciles this list against
        // the files that actually assign one.
        let scripted = [
            ("web/src/tree.ts", include_str!("../web/src/tree.ts")),
            (
                "web/src/result-item.ts",
                include_str!("../web/src/result-item.ts"),
            ),
            (
                "web/src/instances.ts",
                include_str!("../web/src/instances.ts"),
            ),
            (
                "web/src/search-box.ts",
                include_str!("../web/src/search-box.ts"),
            ),
            (
                "web/src/imported-by.ts",
                include_str!("../web/src/imported-by.ts"),
            ),
        ];
        let mut seen = 0;
        let mut missing: Vec<String> = Vec::new();
        for (file, source) in sources {
            for class in emitted_classes(source) {
                seen += 1;
                if !styled.contains(class) {
                    missing.push(format!("{file}: .{class}"));
                }
            }
        }
        let mut from_scripts: Vec<&str> = Vec::new();
        for (file, source) in scripted {
            for class in scripted_classes(source) {
                seen += 1;
                from_scripts.push(class);
                if !styled.contains(class) {
                    missing.push(format!("{file}: .{class}"));
                }
            }
        }
        from_scripts.sort_unstable();
        from_scripts.dedup();
        assert_eq!(
            from_scripts, SCRIPTED_CLASSES,
            "the classes the site's scripts assign are not the recorded ones"
        );
        missing.sort_unstable();
        missing.dedup();
        assert!(
            missing.is_empty(),
            "the renderer writes classes the stylesheet says nothing about: {missing:#?}"
        );
        // A scan that finds nothing would pass silently, checking that the
        // empty set is a subset of anything.
        assert!(
            seen > 20,
            "only {seen} class names found — did the scan break?"
        );
    }

    /// An `include_str!` of a file that was moved or emptied still compiles,
    /// and a zero-byte `style.css` is a site that loads and has no styling.
    #[test]
    fn every_asset_has_a_distinct_path_and_a_body() {
        let mut paths: Vec<&str> = ASSETS.iter().map(|(path, _)| *path).collect();
        paths.sort_unstable();
        paths.dedup();
        assert_eq!(paths.len(), ASSETS.len(), "two assets share a path");
        for (path, body) in ASSETS {
            assert!(!body.is_empty(), "{path} is empty");
            assert!(!path.contains(".."), "{path} could leave the site root");
        }
    }

    /// The assets ship inside the binary and land on every generated site, so
    /// their size is a property of this project rather than of the package
    /// being documented.
    ///
    /// The limits are **round numbers above the current size, not the current
    /// size**: a budget pinned to today's bytes fails on every edit, which
    /// teaches people to raise it without looking. This one only speaks when
    /// something grows by a lot (measured 2026-08-16: style.css 21,516 B /
    /// favicon.svg 360 B; measured 2026-08-19: app.js 15,113 B minified,
    /// 4,912 B gzipped).
    /// Raising a limit is allowed; raising it *without reading what grew* is
    /// what this is here to make awkward.
    #[test]
    fn the_assets_stay_within_their_budget() {
        const BUDGET: [(&str, usize); 3] = [
            ("style.css", 32 * 1024),
            ("app.js", 20 * 1024),
            ("favicon.svg", 4 * 1024),
        ];
        for (path, limit) in BUDGET {
            let body = ASSETS
                .iter()
                .find(|(name, _)| *name == path)
                .unwrap_or_else(|| panic!("{path} is no longer an asset"))
                .1;
            assert!(
                body.len() <= limit,
                "{path} is {} B, over its {limit} B budget. Either shrink it or \
                 raise the budget deliberately — but read what grew first: the \
                 assets are downloaded by every reader of every generated site, \
                 the answer to a large stylesheet is to delete from it, not to \
                 adopt a framework.",
                body.len(),
            );
        }
    }

    /// Stated in that direction on purpose: what must never happen is a
    /// reference to a file nothing puts in the tree.
    #[test]
    fn the_frame_only_names_assets_that_are_written() {
        let head = crate::head_html("Pkg.A", "../", &crate::SiteMeta::default());
        for name in ["style.css", "favicon.svg", "app.js"] {
            assert!(head.contains(name), "the <head> stopped naming {name}");
            assert!(
                ASSETS.iter().any(|(path, _)| *path == name),
                "the <head> names {name} and nothing writes it",
            );
        }
    }

    /// The Lean half cannot run vite, so the bundles are **committed** under
    /// `assets/` and `src/Litedoc4/Assets.lean` is generated from them. That is
    /// two answers to "what is app.js" for as long as both halves exist, and
    /// this is the one place that says they are the same answer.
    ///
    /// A test rather than a gate because `build.rs` has already run vite by the
    /// time this compiles — the comparison costs nothing that was not paid
    /// already, and `cargo test --workspace` is what every commit is judged by.
    /// It leaves with the Rust tree, which is correct: after that there is one
    /// bundle and nothing to reconcile.
    #[test]
    fn the_committed_bundles_match_what_build_rs_bundled() {
        const PAIRS: [(&str, &str, &str); 2] = [
            (
                "app.js",
                include_str!(concat!(env!("OUT_DIR"), "/app.js")),
                include_str!("../../../assets/app.js"),
            ),
            (
                "theme-boot.js",
                include_str!(concat!(env!("OUT_DIR"), "/theme-boot.js")),
                include_str!("../../../assets/theme-boot.js"),
            ),
        ];
        for (name, bundled, committed) in PAIRS {
            // Not `assert_eq!`: these are 15 KB of minified JavaScript, and a
            // failure that prints both of them in full buries the one thing
            // the reader needs.
            let at = bundled
                .bytes()
                .zip(committed.bytes())
                .position(|(a, b)| a != b);
            assert!(
                bundled == committed,
                "assets/{name} is not the bundle vite just built \
                 ({} B committed, {} B bundled, first difference at byte {}). \
                 Rebuild and re-embed:\n  \
                 cd crates/litedoc4-render/web && npm run build\n  \
                 cp dist/{name} ../../../assets/{name}\n  \
                 tools/gen-assets.py",
                committed.len(),
                bundled.len(),
                at.map_or_else(
                    || format!(
                        "none — one is a prefix of the other, at {}",
                        bundled.len().min(committed.len())
                    ),
                    |at| at.to_string()
                ),
            );
        }
    }

    #[test]
    fn writing_twice_leaves_the_same_bytes() {
        let dir = TEMP.reserve("idempotent");
        write_assets(dir.path()).expect("the first write creates the directory");
        // An edit between the two runs, as a hand-patched deployment leaves.
        fs::write(dir.path().join("style.css"), "/* hand-edited */").expect("the file is writable");
        write_assets(dir.path()).expect("the second write overwrites");

        for (name, body) in ASSETS {
            let on_disk = fs::read_to_string(dir.path().join(name)).expect("the asset is there");
            assert_eq!(on_disk, body, "{name} is not what the binary carries");
        }
        let written = fs::read_dir(dir.path())
            .expect("the directory is readable")
            .count();
        assert_eq!(
            written,
            ASSETS.len(),
            "the write left something else behind"
        );
    }
}
