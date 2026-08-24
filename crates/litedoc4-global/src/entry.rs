//! The four pages a reader arrives at rather than navigates to: `index.html`,
//! the site's front door and the `<noscript>` landing place the sidebar falls
//! back to; `404.html`, which GitHub Pages serves for anything missing and
//! `app.js` fills in; `search.html`, where the top bar's form submits; and
//! `foundational_types.html`, which every `Sort` / `Type` / `Prop` span in every
//! signature links to (`litedoc4_render::code`).
//!
//! **Building HTML in the *global* crate is not the layering mistake it looks
//! like.** What decides a page's shape is [`litedoc4_render`] — the head, the
//! top bar, the class names, the stylesheet they are written against — and all
//! four take theirs from there unchanged. What decides a page's *content* is a
//! fact about the **whole package** (how many modules, which ones, how many
//! declarations), and the whole package is what this crate is; putting them in
//! the renderer would mean handing it the module list a second time, from the
//! other side of the pipeline.
//!
//! These pages are one column and carry no repository link. A drawer button that
//! opens an empty drawer is worse than no button, and the repository URL is
//! `--source-url`, which reaches the renderer and not this crate — a second path
//! for one anchor is not worth a knob that can be forgotten on one of the two
//! commands that build a site.

use litedoc4_md::escape_html;
use litedoc4_render::{SiteMeta, break_within, head_html, topbar_html};

/// All four pages sit at the site root, so every asset is one hop away.
const ROOT: &str = "./";

/// One page's frame, with `body` dropped into `main.content`.
///
/// The `data-module` attribute is empty on purpose: `app.js` reads it to decide
/// which tree node is current, and none of these pages *is* a module.
fn plain_page(title: &str, site: &SiteMeta<'_>, body: &str) -> String {
    let mut out = String::with_capacity(body.len() + 2048);
    out.push_str("<!DOCTYPE html><html lang=\"en\">");
    out.push_str(&head_html(title, ROOT, site));
    out.push_str(
        "<body class=\"plain\" data-root=\"./\" data-module=\"\">\
         <a class=\"skip\" href=\"#content\">Skip to content</a>",
    );
    out.push_str(&topbar_html(ROOT, site, false));
    out.push_str("<div class=\"shell\"><main class=\"content\" id=\"content\">");
    out.push_str(body);
    out.push_str("</main></div></body></html>");
    out
}

/// The front page: what the package is, how big it is, and every module of it.
///
/// **The module list is the whole list, spelled out in the HTML** — the sidebar
/// is a JSON fetch, and this is the page its `<noscript>` sends a reader to, so
/// it is the one page that may not need JavaScript to say anything.
///
/// `modules` is expected already sorted, in the UTF-16 order this crate sorts
/// everything else with.
#[must_use]
pub fn index_html(site: &SiteMeta<'_>, modules: &[(&str, String)], declarations: usize) -> String {
    let mut body = String::with_capacity(modules.len() * 128 + 1024);
    body.push_str("<div class=\"modhead\"><h1>");
    body.push_str(&escape_html(site.title));
    body.push_str(
        "</h1><p class=\"lede\">API documentation for every module of this package, generated \
         from the compiled environment. Declarations link to their pinned source; an import of a \
         dependency links to that dependency's source at the revision this package is built \
         against.</p></div>",
    );

    // `litedoc4.toml`'s `index`, between the lede and the counts: it is what the
    // package wants said about itself, and the counts are what this tool has to
    // say about it.
    if let Some(intro) = site.intro {
        body.push_str("<div class=\"intro doc\">");
        body.push_str(intro);
        body.push_str("</div>");
    }

    body.push_str("<dl class=\"stats\"><div><dt>Modules</dt><dd>");
    body.push_str(&grouped(modules.len()));
    body.push_str("</dd></div><div><dt>Declarations</dt><dd>");
    body.push_str(&grouped(declarations));
    body.push_str("</dd></div></dl>");

    body.push_str("<h2 class=\"section-title\">Modules</h2><ul class=\"modlist\">");
    for (module, page) in modules {
        body.push_str("<li><a href=\"./");
        body.push_str(&escape_html(page));
        body.push_str("\">");
        // The same per-component markup the module headings and the sidebar
        // use, so a long name wraps between components rather than mid-word.
        body.push_str(&break_within(module));
        body.push_str("</a></li>");
    }
    body.push_str("</ul>");
    plain_page(site.title, site, &body)
}

/// Static markup with two holes `app.js` fills: `#missing-path` gets the URL
/// that was asked for, `#how-about` the nearest declaration names. The heading
/// above the list starts `hidden` because "Did you mean" with nothing under it
/// is worse than silence, and the paragraph names the module index in prose
/// because with JavaScript off both holes stay empty.
#[must_use]
pub fn not_found_html(site: &SiteMeta<'_>) -> String {
    plain_page(
        "Not found",
        site,
        "<div class=\"modhead\"><h1>Page not found</h1>\
         <p class=\"lede\">Nothing in this documentation is at \
         <code class=\"missing-path\" id=\"missing-path\"></code>. If a declaration has moved, \
         the closest matches are below; otherwise the \
         <a href=\"./index.html\">module index</a> lists every page.</p></div>\
         <h2 class=\"section-title\" id=\"how-about-heading\" hidden>Did you mean</h2>\
         <ul class=\"results\" id=\"how-about\"></ul>",
    )
}

/// **There is no input field here.** `app.js`'s `initSearchPage` reads the top
/// bar's `#search-input`, seeds it from `?q=` and renders into `#page-results`;
/// a second box on a search page is a question about which one is real. The note
/// is `aria-live` because it is the only thing that says how many hits there
/// were.
#[must_use]
pub fn search_html(site: &SiteMeta<'_>) -> String {
    plain_page(
        "Search",
        site,
        "<div class=\"modhead\"><h1>Search</h1>\
         <p class=\"lede\">Every declaration this package documents, by name. Type in the box at \
         the top of the page — a prefix of the last component of a name is matched first, then a \
         prefix of the whole name, then anything containing it.</p></div>\
         <p class=\"results-note\" id=\"page-note\" aria-live=\"polite\"></p>\
         <ul class=\"results\" id=\"page-results\"></ul>\
         <noscript><p class=\"results-note\">Search needs JavaScript. The \
         <a href=\"./index.html\">module index</a> lists every page.</p></noscript>",
    )
}

/// What `Type`, `Prop` and `Sort` mean, for the reader who clicked one in a
/// signature.
///
/// **Written here rather than copied from doc-gen4**, whose page is another
/// project's prose under a different licence. Deliberately short: this is a
/// footnote reached from a signature, not a tutorial, and anything longer
/// competes with Lean's own documentation, which the last paragraph points at
/// instead.
#[must_use]
pub fn foundational_types_html(site: &SiteMeta<'_>) -> String {
    plain_page(
        "Foundational types",
        site,
        "<div class=\"modhead\"><h1>Foundational types</h1>\
         <p class=\"lede\">The sorts and the function type are built into Lean rather than \
         declared in a module, so they have no page of their own to link to. This is that \
         page.</p></div>\
         <div class=\"doc\">\
         <h2><code>Sort u</code></h2>\
         <p>The type of types, one level at a time. Every type in Lean belongs to some \
         <code>Sort u</code>, where the universe level <code>u</code> is a natural number or a \
         variable standing for one. A term of <code>Sort u</code> is itself a type, whose own \
         terms are the values.</p>\
         <p>The hierarchy is strict: <code>Sort u : Sort (u+1)</code>, and there is no \
         <code>Sort ∞</code>. That is what keeps the system consistent — a single type of all \
         types would contain itself.</p>\
         <h2><code>Prop</code></h2>\
         <p><code>Prop</code> is <code>Sort 0</code>, the sort of propositions. A term of a \
         proposition is a proof of it, and <code>Prop</code> is <em>proof-irrelevant</em>: any \
         two proofs of the same proposition are definitionally equal, so a proof can never be \
         inspected to produce data. This is why theorems can be erased at compile time and why \
         they are shown apart from definitions in this documentation.</p>\
         <h2><code>Type u</code></h2>\
         <p><code>Type u</code> abbreviates <code>Sort (u+1)</code>, and <code>Type</code> on its \
         own means <code>Type 0</code>. These are the sorts data lives in: <code>Nat</code>, \
         <code>List α</code> and every structure declared in this package are terms of some \
         <code>Type u</code>. Unlike <code>Prop</code>, distinct terms of a type stay \
         distinct.</p>\
         <h2>Dependent function types</h2>\
         <p><code>(x : α) → β x</code> is the type of functions whose <em>result type may \
         mention the argument</em>. When <code>β</code> does not use <code>x</code> it is written \
         <code>α → β</code>, the ordinary function type. Binders in the signatures on these pages \
         are the same thing in another spelling: <code>∀ (x : α), β x</code> is the dependent \
         function type when the result is a proposition, and <code>{x : α}</code> or \
         <code>[Inst α]</code> mark an argument the elaborator is expected to supply.</p>\
         <p>For the rules behind any of this, see Lean's own documentation — this page only \
         names the things a signature on this site can link to.</p>\
         </div>",
    )
}

fn grouped(n: usize) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn site() -> SiteMeta<'static> {
        SiteMeta {
            title: "Pkg",
            intro: None,
        }
    }

    #[test]
    fn counts_are_grouped_in_threes() {
        assert_eq!(grouped(0), "0");
        assert_eq!(grouped(432), "432");
        assert_eq!(grouped(4_750), "4,750");
        assert_eq!(grouped(1_000_000), "1,000,000");
    }

    #[test]
    fn every_page_is_one_column_and_names_no_other_host() {
        let modules = [("Pkg", "Pkg.html".to_owned())];
        for page in [
            index_html(&site(), &modules, 1),
            not_found_html(&site()),
            search_html(&site()),
            foundational_types_html(&site()),
        ] {
            assert!(
                page.starts_with("<!DOCTYPE html><html lang=\"en\">"),
                "{page}"
            );
            assert!(page.contains("<body class=\"plain\""), "{page}");
            assert!(!page.contains("id=\"nav-toggle\""), "{page}");
            assert!(
                !page.contains("http://") && !page.contains("https://"),
                "{page}"
            );
            assert!(page.contains("id=\"search-input\""), "{page}");
        }
    }

    /// A rename on either side of these ids is a page that loads, validates and
    /// does nothing.
    #[test]
    fn the_script_finds_the_holes_it_fills() {
        let not_found = not_found_html(&site());
        for id in ["missing-path", "how-about", "how-about-heading"] {
            assert!(not_found.contains(&format!("id=\"{id}\"")), "{not_found}");
        }
        assert!(
            not_found.contains("id=\"how-about-heading\" hidden"),
            "an empty \"Did you mean\" heading is shown before there is anything under it"
        );
        let search = search_html(&site());
        for id in ["page-results", "page-note"] {
            assert!(search.contains(&format!("id=\"{id}\"")), "{search}");
        }
        assert!(
            !search.contains("<input type=\"search\" id=\"search-input\" name=\"q\"><"),
            "search.html grew a second input"
        );
    }

    #[test]
    fn the_index_lists_every_module_and_its_counts() {
        let modules = [
            ("Pkg", "Pkg.html".to_owned()),
            ("Pkg.A<B", "Pkg/A<B.html".to_owned()),
        ];
        let page = index_html(&site(), &modules, 4_750);
        assert!(page.contains("<dd>2</dd>"), "{page}");
        assert!(page.contains("<dd>4,750</dd>"), "{page}");
        assert!(page.contains("href=\"./Pkg.html\""), "{page}");
        assert!(
            page.contains("href=\"./Pkg/A&lt;B.html\""),
            "the page path was not escaped: {page}"
        );
        assert!(
            page.contains("<span class=\"name\">A&lt;B</span>"),
            "the module name was not escaped: {page}"
        );
    }

    #[test]
    fn the_foundational_page_covers_the_four_things_a_signature_links_to() {
        let page = foundational_types_html(&site());
        for what in ["Sort u", "Prop", "Type u", "Dependent function types"] {
            assert!(page.contains(what), "{what} is not on the page");
        }
    }
}
