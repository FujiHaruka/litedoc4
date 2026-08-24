//! The page frame: `<head>`, the top bar, the sidebar and the module heading.
//!
//! Nothing here names another host: the site renders from a bare directory.
//!
//! Two things are deliberate and look like mistakes:
//!
//! 1. **The theme is set by an inline script in `<head>`.** An external module
//!    runs after first paint, so a reader on the dark theme would see a white
//!    flash on every navigation. The cost is ~120 bytes on every page.
//! 2. **The import list is sorted by [`crate::order::cmp_name`], not by string
//!    order.** `Name.lt` compares parents first, so `Init` and `Mathlib` both
//!    precede `Init.Core`. This is doc-gen4's order, and it groups a package's
//!    modules together where alphabetical order does not.
//!
//! Duplicate imports are dropped keeping the first occurrence: the module system
//! does produce duplicates, and doc-gen4's DB hid them behind an
//! `INSERT OR IGNORE`.

use crate::autolink::NameIndex;
use crate::code::break_within;
use crate::config::SiteConfig;
use crate::escape::escape_html_into;
use crate::order::sort_names;

/// What every page says about the site it belongs to. Configuration, not IR.
#[derive(Clone, Copy, Debug)]
pub struct SiteMeta<'a> {
    /// Shown in the top bar and after the module name in `<title>`.
    /// `litedoc4.toml`'s `title`, else the package's root module, else
    /// `"Documentation"`.
    pub title: &'a str,
    /// `litedoc4.toml`'s `index`, **already rendered to HTML**.
    ///
    /// Reaches the site's index page and nothing else — a module page is about
    /// its module. Carried here rather than passed alongside because it and the
    /// title come from one file and are decided together; two carriers is two
    /// things to forget.
    pub intro: Option<&'a str>,
}

impl Default for SiteMeta<'_> {
    fn default() -> Self {
        Self {
            title: "Documentation",
            intro: None,
        }
    }
}

impl<'a> SiteMeta<'a> {
    /// The name the modules share, when they share one.
    ///
    /// The IR does not carry a package name and the CLI's `--root` is a
    /// directory, but a package whose modules are all `Foo.*` is called `Foo`.
    /// When they do not all agree there is no right answer, and the generic
    /// title is the honest one.
    ///
    /// Derived rather than configured on purpose: a `--title` flag would be one
    /// more thing that can be forgotten on one of the three commands that
    /// render, and then two of them would disagree.
    #[must_use]
    pub fn of_modules(modules: impl IntoIterator<Item = &'a str>) -> Self {
        let mut roots = modules
            .into_iter()
            .map(|module| litedoc4_ir::module_components(module).into_iter().next());
        match roots.next().flatten() {
            Some(head) if roots.all(|root| root == Some(head)) => Self {
                title: head,
                intro: None,
            },
            _ => Self::default(),
        }
    }

    /// [`SiteMeta::of_modules`], with whatever the package configured on top.
    ///
    /// **This is the one place the two sources are combined.** Every command
    /// that renders calls it with the same [`SiteConfig`], so "the three
    /// commands agree" is a property of one function rather than of three call
    /// sites that have to be kept in step.
    ///
    /// `intro` is the rendered `index` Markdown; the caller renders it, because
    /// this crate's docstring renderer takes a link resolver and the answer to
    /// "does this name have a page" is not a fact about the site's title.
    #[must_use]
    pub fn of(
        config: &'a SiteConfig,
        intro: Option<&'a str>,
        modules: impl IntoIterator<Item = &'a str>,
    ) -> Self {
        let derived = Self::of_modules(modules);
        Self {
            title: config.title.as_deref().unwrap_or(derived.title),
            intro,
        }
    }
}

/// Runs before first paint so a dark-theme reader never sees a white flash.
///
/// **Not a file on the site and not part of `app.js`.** Both would be fetched
/// after the HTML, and the whole job of this script is to have finished before
/// the first paint — so it is inlined, and it is the smallest thing that can do
/// the job.
///
/// It is nevertheless *written* in TypeScript, in `web/src/theme-boot.ts`, and
/// bundled by `build.rs` alongside `app.js`, so that the storage key is one
/// string (`web/src/theme-key.ts`) rather than a Rust literal and a TypeScript
/// one that can be renamed apart.
const THEME_BOOT_JS: &str = include_str!(concat!(env!("OUT_DIR"), "/theme-boot.js"));

const ICON_MENU: &str =
    "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M3 5h14M3 10h14M3 15h14\"/></svg>";
const ICON_THEME: &str = "<svg viewBox=\"0 0 20 20\" aria-hidden=\"true\"><path d=\"M10 3a7 7 0 1 0 7 7 5.5 5.5 0 0 1-7-7z\"/></svg>";

/// `getSourceUrl` for a module: the configured repository/revision prefix, the
/// module's components as directories, and `.lean`. The prefix is
/// **configuration, not IR** — the extractor never saw it.
#[must_use]
pub fn module_source_url(base: &str, module: &str) -> String {
    let mut out = String::with_capacity(base.len() + module.len() + 6);
    out.push_str(base);
    // The source file's path, so the components are the unescaped ones:
    // `Alpha.«Odd-Name»` lives in `Alpha/Odd-Name.lean`.
    for part in litedoc4_ir::module_components(module) {
        out.push('/');
        out.push_str(part);
    }
    out.push_str(".lean");
    out
}

#[must_use]
pub fn head_html(module: &str, root: &str, site: &SiteMeta<'_>) -> String {
    let mut out = String::with_capacity(640);
    out.push_str(
        "<head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>",
    );
    escape_html_into(&mut out, module);
    if !site.title.is_empty() && site.title != module {
        out.push_str(" · ");
        escape_html_into(&mut out, site.title);
    }
    out.push_str("</title><link rel=\"stylesheet\" href=\"");
    push_asset(&mut out, root, "style.css");
    out.push_str("\"><link rel=\"icon\" href=\"");
    push_asset(&mut out, root, "favicon.svg");
    out.push_str("\">");
    // No `type="module"` on this one, and that is the point: a module is
    // deferred. `trim_end` because the bundler leaves a trailing newline and
    // this goes inside a tag on one line.
    out.push_str("<script>");
    out.push_str(THEME_BOOT_JS.trim_end());
    out.push_str("</script>");
    out.push_str("<script type=\"module\" src=\"");
    push_asset(&mut out, root, "app.js");
    out.push_str("\"></script></head>");
    out
}

/// `root + name`, escaped as one string — which is the same as escaping the
/// parts for every root this crate produces, but not for an arbitrary one.
fn push_asset(out: &mut String, root: &str, name: &str) {
    let mut href = String::with_capacity(root.len() + name.len());
    href.push_str(root);
    href.push_str(name);
    escape_html_into(out, &href);
}

/// `with_nav` is false on the pages that have no sidebar — the index, search
/// and not-found pages are one column, and a button that opens nothing is worse
/// than no button.
#[must_use]
pub fn topbar_html(root: &str, site: &SiteMeta<'_>, with_nav: bool) -> String {
    let mut out = String::with_capacity(768);
    out.push_str("<header class=\"topbar\">");
    if with_nav {
        out.push_str(
            "<button class=\"iconbtn\" id=\"nav-toggle\" aria-label=\"Modules\" \
             aria-expanded=\"false\" aria-controls=\"sidebar\">",
        );
        out.push_str(ICON_MENU);
        out.push_str("</button>");
    }
    out.push_str("<a class=\"home\" href=\"");
    push_asset(&mut out, root, "index.html");
    out.push_str("\">");
    escape_html_into(&mut out, site.title);
    out.push_str("</a><form class=\"search\" role=\"search\" action=\"");
    push_asset(&mut out, root, "search.html");
    out.push_str(
        "\"><input type=\"search\" id=\"search-input\" name=\"q\" autocomplete=\"off\" \
         spellcheck=\"false\" placeholder=\"Search declarations\" \
         aria-label=\"Search declarations\">\
         <ul class=\"search-results\" id=\"search-results\" hidden></ul></form>\
         <button class=\"iconbtn\" id=\"theme-toggle\" aria-label=\"Theme\">",
    );
    out.push_str(ICON_THEME);
    out.push_str("</button></header>");
    out
}

/// `member_names` is the page's declarations **in page order** — the order
/// `page_html` emitted them in, not a sort — because it is a table of contents
/// for what is below it.
///
/// The module tree is empty markup that `app.js` fills: doc-gen4's equivalent
/// `navbar.html` is 57,949 B for the target package, and putting it on all 432
/// pages would add ~25 MB. The `<noscript>` link is the fallback, and it is the
/// reason `index.html` has to exist.
#[must_use]
pub fn sidebar_html(root: &str, member_names: &[&str]) -> String {
    let mut out = String::with_capacity(512 + member_names.len() * 96);
    out.push_str(
        "<div class=\"scrim\" id=\"scrim\" hidden></div>\
         <nav class=\"sidebar\" id=\"sidebar\" aria-label=\"Navigation\">",
    );
    if !member_names.is_empty() {
        out.push_str(
            "<section class=\"side\"><h2 class=\"side-title\">On this page</h2><ul class=\"toc\">",
        );
        for name in member_names {
            out.push_str("<li><a href=\"#");
            escape_html_into(&mut out, name);
            out.push_str("\">");
            out.push_str(&break_within(name));
            out.push_str("</a></li>");
        }
        out.push_str("</ul></section>");
    }
    out.push_str(
        "<section class=\"side\"><h2 class=\"side-title\">Modules</h2>\
         <div class=\"tree\" id=\"module-tree\"><noscript><a href=\"",
    );
    push_asset(&mut out, root, "index.html");
    out.push_str("\">Module index</a></noscript></div></section></nav>");
    out
}

/// No breadcrumb: the name is spelled out in full here and the tree in the
/// sidebar already shows where it sits, so a second copy of the hierarchy would
/// only compete with it.
#[must_use]
pub fn module_head_html(module: &str, module_source_url: &str) -> String {
    let mut out = String::with_capacity(256 + module.len() * 2);
    out.push_str("<div class=\"modhead\"><h1>");
    out.push_str(&break_within(module));
    out.push_str("</h1><p class=\"modactions\"><a class=\"src\" href=\"");
    escape_html_into(&mut out, module_source_url);
    out.push_str("\">source</a></p></div>");
    out
}

/// The two import blocks under the heading.
///
/// Nearly every import of a package like the measurement target is a
/// *dependency's* module — `Mathlib.Order.Basic`, `Init.Prelude` — and this site
/// has a page for none of them, so a relative link here is a 404 on every page.
///
/// **Two kinds of import get no `<a>` at all**: a dependency that could not be
/// version-pinned, and a module of *this* package that this run writes no page
/// for. They are listed by name inside their `<li>` — the import is a fact about
/// the module and stays on the page, while where to read it is a fact this run
/// does not have. That whole three-way decision is [`NameIndex::link_to`]'s
/// rather than this function's, which is why the index is taken whole rather
/// than the dependency map alone.
///
/// "Imported by" is empty markup and starts `hidden`: it is a fact about the
/// whole site, `app.js` fills it from `modules.json`, and a module nothing
/// imports has the block removed rather than shown empty.
#[must_use]
pub fn module_meta_html(root: &str, imports: &[String], index: &NameIndex) -> String {
    let sorted = sorted_imports(imports);
    let mut out = String::with_capacity(256 + sorted.len() * 96);
    out.push_str("<div class=\"modmeta\"><details class=\"imports\"><summary>Imports");
    if !sorted.is_empty() {
        out.push_str(" <span class=\"count\">");
        out.push_str(&sorted.len().to_string());
        out.push_str("</span>");
    }
    out.push_str("</summary><ul>");
    for import in sorted {
        match index.link_to_module(root, import) {
            Some(href) => {
                out.push_str("<li><a href=\"");
                escape_html_into(&mut out, &href);
                out.push_str("\">");
                escape_html_into(&mut out, import);
                out.push_str("</a></li>");
            }
            None => {
                out.push_str("<li>");
                escape_html_into(&mut out, import);
                out.push_str("</li>");
            }
        }
    }
    out.push_str(
        "</ul></details>\
         <details class=\"imports\" data-fill=\"imported-by\" hidden>\
         <summary>Imported by</summary><ul></ul></details></div>",
    );
    out
}

/// Duplicates dropped keeping the first occurrence, then a **stable** sort by
/// `Name.lt`. The de-duplication happens before the sort, which is why it keeps
/// the first occurrence rather than any other.
#[must_use]
fn sorted_imports(imports: &[String]) -> Vec<&str> {
    let mut seen = std::collections::HashSet::with_capacity(imports.len());
    let mut out: Vec<&str> = Vec::with_capacity(imports.len());
    for import in imports {
        if seen.insert(import.as_str()) {
            out.push(import.as_str());
        }
    }
    sort_names(&mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::external::ExternalLinks;
    use crate::link_index::LinkIndex;

    /// `pages` are the modules this run rendered, `external` is what it knows
    /// about everything else. A whole index rather than a bare
    /// [`ExternalLinks`], because two of the list's three answers need the page
    /// set.
    fn index(pages: &[&str], external: ExternalLinks) -> NameIndex {
        let mut builder = NameIndex::builder();
        for module in pages {
            builder.module_name(module);
        }
        builder.build(LinkIndex::default(), external)
    }

    #[test]
    fn the_source_url_joins_components_with_slashes() {
        assert_eq!(
            module_source_url("https://host/o/r/blob/abc", "Foo.Bar"),
            "https://host/o/r/blob/abc/Foo/Bar.lean"
        );
        assert_eq!(module_source_url("", "Foo"), "/Foo.lean");
    }

    /// A page asks its own directory for everything.
    #[test]
    fn the_head_names_no_other_host() {
        let head = head_html(
            "Foo.Bar",
            ".././",
            &SiteMeta {
                title: "Pkg",
                intro: None,
            },
        );
        assert!(!head.contains("//cdn"), "{head}");
        assert!(!head.contains("http"), "{head}");
        assert!(head.contains("href=\".././style.css\""), "{head}");
        assert!(head.contains("src=\".././app.js\""), "{head}");
        assert!(head.contains("<title>Foo.Bar · Pkg</title>"), "{head}");
    }

    #[test]
    fn the_theme_is_set_inline_before_the_module_script() {
        let head = head_html("Foo", "./", &SiteMeta::default());
        let boot = head.find("litedoc4-theme").expect("theme boot is inline");
        let app = head.find("app.js").expect("app.js is linked");
        assert!(boot < app, "{head}");
    }

    /// `THEME_BOOT_JS` is minifier output pasted between `<script>` and
    /// `</script>` without escaping — which is correct, script content is not
    /// HTML — so a `</script` anywhere inside it would close the tag early and
    /// spill the rest of the bundle into the document as text. The minifier
    /// chooses the output and nobody reviews it.
    #[test]
    fn the_inlined_boot_script_cannot_close_its_own_tag() {
        let lowered = THEME_BOOT_JS.to_ascii_lowercase();
        assert!(
            !lowered.contains("</script"),
            "the theme boot bundle contains `</script`, which ends the tag it is \
             inlined into: {THEME_BOOT_JS}",
        );
        // `<!--` opens an HTML comment inside a classic script for the same
        // historical reason, and has the same "silently eats the rest" failure.
        assert!(!THEME_BOOT_JS.contains("<!--"), "{THEME_BOOT_JS}");
    }

    /// The boot script and the toggle agree about the storage key by
    /// construction — both come from `web/src/theme-key.ts`. This checks the
    /// half that reaches Rust.
    #[test]
    fn the_boot_script_carries_the_storage_key() {
        assert!(
            THEME_BOOT_JS.contains("litedoc4-theme"),
            "the theme boot bundle no longer names the key it reads: {THEME_BOOT_JS}",
        );
    }

    #[test]
    fn the_title_does_not_repeat_itself_on_the_root_module() {
        let head = head_html(
            "Pkg",
            "./",
            &SiteMeta {
                title: "Pkg",
                intro: None,
            },
        );
        assert!(head.contains("<title>Pkg</title>"), "{head}");
    }

    #[test]
    fn the_head_escapes_the_module_name() {
        let head = head_html(
            "A\"B",
            "./",
            &SiteMeta {
                title: "S",
                intro: None,
            },
        );
        assert!(head.contains("<title>A&quot;B · S</title>"), "{head}");
    }

    #[test]
    fn a_page_without_a_sidebar_gets_no_drawer_button() {
        let with = topbar_html("./", &SiteMeta::default(), true);
        let without = topbar_html("./", &SiteMeta::default(), false);
        assert!(with.contains("id=\"nav-toggle\""));
        assert!(!without.contains("id=\"nav-toggle\""));
        // Both still search and still lead home.
        for bar in [&with, &without] {
            assert!(bar.contains("id=\"search-input\""), "{bar}");
            assert!(bar.contains("href=\"./index.html\""), "{bar}");
        }
    }

    #[test]
    fn the_sidebar_lists_the_page_in_page_order() {
        let side = sidebar_html(".././", &["M.N.b", "M.N.a"]);
        let b = side.find("#M.N.b").expect("first entry");
        let a = side.find("#M.N.a").expect("second entry");
        assert!(b < a, "the toc is the page's order, not a sort: {side}");
        assert!(side.contains("<div class=\"tree\" id=\"module-tree\">"));
        assert!(
            side.contains("<noscript><a href=\".././index.html\">Module index</a></noscript>"),
            "{side}"
        );
    }

    #[test]
    fn an_empty_page_has_no_table_of_contents() {
        let side = sidebar_html("./", &[]);
        assert!(!side.contains("On this page"), "{side}");
        assert!(side.contains("Modules"), "{side}");
    }

    #[test]
    fn the_module_heading_is_the_name_and_its_source() {
        let head = module_head_html("M.N", "https://x/M/N.lean");
        assert_eq!(
            head,
            "<div class=\"modhead\"><h1><span class=\"name\">M</span>.\
             <span class=\"name\">N</span></h1><p class=\"modactions\">\
             <a class=\"src\" href=\"https://x/M/N.lean\">source</a></p></div>"
        );
    }

    #[test]
    fn imports_are_deduplicated_before_being_sorted_by_name_lt() {
        let imports: Vec<String> = ["Mathlib.Order", "Init", "Mathlib.Order", "Init.Core", "Zzz"]
            .iter()
            .map(|s| (*s).to_owned())
            .collect();
        assert_eq!(
            sorted_imports(&imports),
            ["Init", "Zzz", "Init.Core", "Mathlib.Order"],
            "`Name.lt` compares parents first, so the one-component names lead"
        );
    }

    #[test]
    fn the_meta_block_counts_imports_and_leaves_imported_by_to_the_script() {
        let imports = vec!["B.C".to_owned(), "A".to_owned()];
        let meta = module_meta_html(
            ".././",
            &imports,
            &index(&["A", "B.C"], ExternalLinks::default()),
        );
        assert!(
            meta.contains("<summary>Imports <span class=\"count\">2</span></summary>"),
            "{meta}"
        );
        assert!(
            meta.contains(
                "<ul><li><a href=\".././A.html\">A</a></li>\
                 <li><a href=\".././B/C.html\">B.C</a></li></ul>"
            ),
            "{meta}"
        );
        assert!(meta.contains("data-fill=\"imported-by\" hidden"), "{meta}");
    }

    #[test]
    fn a_module_with_no_imports_still_gets_the_block_but_no_count() {
        let meta = module_meta_html("./", &[], &index(&[], ExternalLinks::default()));
        assert!(
            meta.contains("<summary>Imports</summary><ul></ul>"),
            "{meta}"
        );
    }

    /// The sort is over the module names, not the hrefs, so `A` still leads even
    /// though its href is the longer one.
    #[test]
    fn an_import_of_a_dependency_points_at_its_pinned_source() {
        let imports = vec!["B.C".to_owned(), "A".to_owned()];
        let meta = module_meta_html(
            ".././",
            &imports,
            &index(
                &["B.C"],
                ExternalLinks::new([("A", "https://host/o/dep/blob/abc")]),
            ),
        );
        assert!(
            meta.contains(
                "<ul><li><a href=\"https://host/o/dep/blob/abc/A.lean\">A</a></li>\
                 <li><a href=\".././B/C.html\">B.C</a></li></ul>"
            ),
            "{meta}"
        );
    }

    /// The `<li>` stays, the `<a>` goes. `B.C` beside it still gets its page
    /// link, which is what says the loss is confined to the root that could not
    /// be resolved.
    #[test]
    fn an_import_that_cannot_be_version_pinned_is_listed_without_a_link() {
        let imports = vec!["B.C".to_owned(), "A".to_owned()];
        let meta = module_meta_html(
            ".././",
            &imports,
            &index(&["B.C"], ExternalLinks::new([("A", "")])),
        );
        assert!(
            meta.contains("<ul><li>A</li><li><a href=\".././B/C.html\">B.C</a></li></ul>"),
            "{meta}"
        );
        assert!(
            meta.contains("<summary>Imports <span class=\"count\">2</span></summary>"),
            "an unlinkable import is still an import: {meta}"
        );
        assert!(!meta.contains("<a href=\".././A.html\">"), "{meta}");
    }

    /// The three answers an import can get, on one list. `Pkg.Recycling` is the
    /// case this exists for — a module of the package being documented that this
    /// run writes no page for, which is what a `lakefile.toml` with more than
    /// one `[[lean_lib]]` produces.
    #[test]
    fn an_import_this_run_writes_no_page_for_is_listed_without_a_link() {
        let imports: Vec<String> = ["Mathlib.Order", "Dep.Aux", "Pkg.Recycling", "Pkg.Two"]
            .iter()
            .map(|s| (*s).to_owned())
            .collect();
        let meta = module_meta_html(
            ".././",
            &imports,
            &index(
                &["Pkg.Two"],
                ExternalLinks::new([("Mathlib", "https://host/o/m/blob/abc"), ("Dep", "")]),
            ),
        );
        assert!(
            meta.contains(
                "<ul><li>Dep.Aux</li>\
                 <li><a href=\"https://host/o/m/blob/abc/Mathlib/Order.lean\">Mathlib.Order</a></li>\
                 <li>Pkg.Recycling</li>\
                 <li><a href=\".././Pkg/Two.html\">Pkg.Two</a></li></ul>"
            ),
            "{meta}"
        );
    }
}
