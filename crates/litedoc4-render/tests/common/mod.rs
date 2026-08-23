//! What more than one oracle in this directory needs: the one rewrite they all
//! apply, the world they build to apply it in, and the HTML scanners their
//! assertions read with.
//!
//! **Anything that knows about `litedoc4_render`'s types or about HTML lives
//! here; anything that is only string handling lives in `litedoc4-testutil`**
//! (§7 U3 of `docs/plans/refactoring.md`). That is the line, and it is what
//! keeps `litedoc4_testutil` free of a dependency on the crate under test.
//!
//! # The rewrite
//!
//! **M8, gate UI-2** (`docs/plans/ui-redesign.md` §1). doc-gen4 and the frozen
//! prototype both turn a source path in a code span — `` `EPI/Stam/ToBridge.lean` ``
//! — into a link without consulting anything: the path is read as relative to
//! the repository root and the extension is swapped. The measurement target
//! writes those paths relative to the *module* they sit in, so the page named
//! does not exist; 160 of the site's 32,868 internal links were dangling
//! 【実測 2026-08-16, `benchmarks/results/m8-ui2-dead-links.txt`】. This crate
//! asks `NameIndex::module_for_source_path` instead, which is the only branch of
//! `nameToLink?` where its answer is deliberately not its oracle's.
//!
//! So the oracles compare against their recorded bytes *with that one branch
//! re-answered* ([`rewrite_source_path_anchors`]) and pin how many anchors
//! moved ([`Tally`]). Everything else stays byte for byte, and a second
//! divergence still fails.

// Each test binary uses a part of this module; `mod common;` compiles all of it
// into each of them.
#![allow(
    dead_code,
    reason = "not `expect`: which part is dead depends on which test binary is compiling this"
)]

use std::collections::BTreeMap;

use litedoc4_render::autolink::NameIndex;
use litedoc4_render::{ExternalLinks, LinkIndex};

/// The [`NameIndex`] a case builds from its three sources, the way a run builds
/// it from the IR and the `.lidx`.
///
/// **Two of the four `Case::index()` in this directory are this, and two are
/// not.** `fragment.rs` and `docgen4_linked.rs` build a different world and say
/// so at their own definitions; only `page_parts.rs` and `autolink.rs` call
/// here (§7 U3 of `docs/plans/refactoring.md`).
///
/// M7-c: the prototype had no dependency map, so its bytes are the **fallback**
/// branch — which an empty [`ExternalLinks`] reproduces exactly. With a map
/// every link into a dependency moves, on purpose
/// (`docs/implementation-plan.md` §1).
///
/// 2026-08-17: and the prototype rendered the whole environment, so its links
/// point at pages it wrote. A run's world has pages for the target package
/// alone; the oracle is resolved in the world it was recorded in.
pub(crate) fn name_index(
    ir_modules: &[String],
    known: &BTreeMap<String, String>,
    lidx: &str,
) -> NameIndex {
    let mut builder = NameIndex::builder();
    for module in ir_modules {
        builder.module_name(module);
    }
    for (name, module) in known {
        builder.declaration(name, module);
    }
    builder.build_with_a_page_for_every_module(LinkIndex::parse(lidx), ExternalLinks::default())
}

/// Every ` name="…"` value, in document order. The leading space is what keeps
/// `id` from matching inside `data-name` and the like.
pub(crate) fn attr_values<'a>(html: &'a str, name: &str) -> Vec<&'a str> {
    let needle = format!(" {name}=\"");
    let mut out = Vec::new();
    let mut rest = html;
    while let Some(at) = rest.find(&needle) {
        let value = &rest[at + needle.len()..];
        let end = value.find('"').unwrap_or(value.len());
        out.push(&value[..end]);
        rest = &value[end..];
    }
    out
}

/// The text between the first `open` and the `close` that follows it.
pub(crate) fn between<'a>(html: &'a str, open: &str, close: &str) -> Option<&'a str> {
    let at = html.find(open)? + open.len();
    let end = html[at..].find(close)? + at;
    Some(&html[at..end])
}

/// `(href, text)` of every anchor, with the href unescaped and the text **as
/// written**.
///
/// The raw text is what the two views below decide on: a caller that wants only
/// the anchors whose text is plain has to ask before anything unescapes `&lt;`
/// into a `<` that was never markup.
fn raw_anchors(html: &str) -> Vec<(String, &str)> {
    let mut out = Vec::new();
    let mut rest = html;
    while let Some(at) = rest.find("<a href=\"") {
        rest = &rest[at + 9..];
        let Some(end) = rest.find('"') else { break };
        let href = unescape(&rest[..end]);
        rest = &rest[end + 2..];
        let Some(close) = rest.find("</a>") else {
            break;
        };
        out.push((href, &rest[..close]));
        rest = &rest[close + 4..];
    }
    out
}

/// `(href, text)` of every anchor in a fragment, with the text unescaped.
pub(crate) fn anchors_of(html: &str) -> Vec<(String, String)> {
    raw_anchors(html)
        .into_iter()
        .map(|(href, text)| (href, unescape(text)))
        .collect()
}

/// [`anchors_of`] restricted to the anchors whose text is plain, which is every
/// anchor `autoLinkInline` makes.
///
/// The test is on the text **as written**, before unescaping: `&lt;` is a `<`
/// that the renderer escaped, not a tag, and filtering after [`unescape`] would
/// drop anchors this is meant to keep.
pub(crate) fn plain_anchors_of(html: &str) -> Vec<(String, String)> {
    raw_anchors(html)
        .into_iter()
        .filter(|(_, text)| !text.contains('<'))
        .map(|(href, text)| (href, unescape(text)))
        .collect()
}

/// What [`rewrite_source_path_anchors`] did, so that a comparison cannot pass
/// by rewriting everything or by rewriting nothing.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Tally {
    /// The new answer names the page the oracle named.
    pub unchanged: usize,
    /// The new answer names a different page.
    pub relinked: usize,
    /// There is no new answer: no module matches the path, or several do.
    pub dropped: usize,
}

impl Tally {
    /// Every source-path anchor seen, however it was answered.
    pub(crate) fn total(&self) -> usize {
        self.unchanged + self.relinked + self.dropped
    }
}

/// `html` with every anchor whose text is a **source path** re-answered by
/// `answer`, which is given the path without its `.lean`.
///
/// `Some(href)` replaces the anchor's href and `None` replaces the whole anchor
/// with its text — which is exactly what `autoLinkInline` writes for a word that
/// resolves to nothing. Every other anchor, and every byte between anchors, is
/// copied.
pub(crate) fn rewrite_source_path_anchors(
    html: &str,
    answer: &dyn Fn(&str) -> Option<String>,
    tally: &mut Tally,
) -> String {
    const OPEN: &str = "<a href=\"";
    let mut out = String::new();
    let mut rest = html;
    while let Some(at) = rest.find(OPEN) {
        let after = &rest[at + OPEN.len()..];
        let (Some(shut), Some(end)) = (after.find("\">"), after.find("</a>")) else {
            break;
        };
        let (href, text) = (&after[..shut], &after[shut + 2..end]);
        let path = unescape(text);
        // A source path is what `nameToLink?`'s first branch takes: `.lean` and
        // a `/`. The anchor text is the word `splitAround` cut out, so it is the
        // path itself.
        let Some(stem) = path.strip_suffix(".lean").filter(|p| p.contains('/')) else {
            out.push_str(&rest[..at + OPEN.len() + end + 4]);
            rest = &after[end + 4..];
            continue;
        };
        out.push_str(&rest[..at]);
        match answer(stem) {
            Some(link) => {
                // Nothing in these corpora needs escaping in an href, and a
                // corpus that did would need this helper to escape it.
                assert!(
                    !link.contains(['&', '<', '>', '"']),
                    "{link} needs escaping"
                );
                if link == unescape(href) {
                    tally.unchanged += 1;
                } else {
                    tally.relinked += 1;
                }
                out.push_str(OPEN);
                out.push_str(&link);
                out.push_str("\">");
                out.push_str(text);
                out.push_str("</a>");
            }
            None => {
                tally.dropped += 1;
                out.push_str(text);
            }
        }
        rest = &after[end + 4..];
    }
    out.push_str(rest);
    out
}

/// The four characters `Html.escape` writes, back.
pub(crate) fn unescape(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&amp;", "&")
}
