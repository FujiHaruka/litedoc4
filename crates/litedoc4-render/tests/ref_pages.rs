//! The second oracle: the docstrings **inside the reference pages**, which the
//! frozen prototype wrote by running over the target package's IR with the real
//! `--link-index`. Neither that script nor the prototype is in this tree any
//! more; both exist only at tag `experiments-frozen`, and the pages themselves
//! only ever lived under /private/tmp — so this test is env-gated and
//! `#[ignore]`d rather than silently returning, which is what makes a run say
//! out loud that it did not compare anything.
//!
//! **Why this exists next to `tests/autolink.rs`**: that file compares against
//! the prototype's `renderDocString` given a context this repository builds,
//! and one input to it is not a slice — `moduleDeclNames`, the list
//! `nameToLink`'s last branch scans, which the generator lifts out of
//! `pageHtml` as an expression. If that lift were wrong, both sides would be
//! handed the same wrong list and would agree. The reference pages were
//! produced by the whole program, so the list in them is the real one. Unlike a
//! page-level byte diff, this says *which* docstring moved rather than which
//! file.
//!
//! Docstrings appear on a page in three places — `div.mod_doc`, the region
//! after a `decl_header`, and `div.structure_field_doc` — and none can be
//! confused with the surrounding template, because a rendered docstring
//! contains no `<div>` and no `<details>`: `MD_FLAG_NOHTML` sees to that and
//! `renderBlock` emits neither.

use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};

use litedoc4_ir::{IrTree, ModuleFile};
use litedoc4_render::autolink::{NameIndex, PageLinks, module_decl_names, page_root};
use litedoc4_render::escape::escape_html;
use litedoc4_render::{ExternalLinks, LinkIndex};
use litedoc4_testutil::corpus;

/// What may follow a declaration's docstring on a page: the rest of the
/// declaration, or the end of it. None of these can begin a docstring.
const TERMINATORS: [&str; 4] = ["</div>", "<div", "<details", "<ul class=\"structure_"];

/// The one docstring of the package where the prototype's hand-written
/// CommonMark subset and md4c disagree — a code span with nested backticks,
/// which the subset's `indexOf` scan closes in the wrong place.
///
/// It is *not* an autolink difference: the same input differs under `NoLinks`,
/// and doc-gen4 produces this crate's bytes (measured → `litedoc4-md`'s
/// `tests/ts_docstring.rs`). The reference page is the wrong one here, so this
/// test names it rather than counting how many differ.
const KNOWN_SUBSET_DIVERGENCE: &str =
    "InformationTheory.Shannon.TimeBandLimiting.Count module doc 1";

fn inputs() -> (PathBuf, PathBuf, PathBuf) {
    (
        corpus::LITEDOC4_IR.path(),
        corpus::LITEDOC4_LINK_INDEX.path(),
        corpus::LITEDOC4_REF_PAGES.path(),
    )
}

/// The text between `open` and the next `</div>`, and where it started.
///
/// No nesting count is needed: a rendered docstring contains no `<div>`, so the
/// first close is the wrapper's.
fn wrapped<'a>(page: &'a str, open: &str, from: usize) -> Option<(usize, &'a str)> {
    let at = page[from..].find(open)? + from + open.len();
    let end = page[at..].find("</div>")? + at;
    Some((at, &page[at..end]))
}

/// The byte just past the `</div>` that closes the `<div` starting at `start`.
///
/// The nesting count is not optional here: `decl_header` contains a
/// `div.decl_type`, so its *first* `</div>` is not its own — reading it as such
/// puts the docstring's start one element too early and every comparison fails
/// with an empty page-side region.
fn after_matching_div(page: &str, start: usize) -> Option<usize> {
    debug_assert!(page[start..].starts_with("<div"));
    let mut depth = 0usize;
    let mut at = start;
    loop {
        let open = page[at..].find("<div");
        let close = page[at..].find("</div>")?;
        if open.is_some_and(|o| o < close) {
            depth += 1;
            at += open.expect("checked") + "<div".len();
        } else {
            depth -= 1;
            at += close + "</div>".len();
            if depth == 0 {
                return Some(at);
            }
        }
    }
}

#[test]
#[ignore = "corpus: needs LITEDOC4_IR + LITEDOC4_LINK_INDEX + LITEDOC4_REF_PAGES (tools/corpus-gate.sh)"]
fn every_docstring_in_the_reference_pages_is_reproduced() {
    let (ir, lidx, pages) = inputs();

    let tree = IrTree::open(&ir).expect("the IR opens");
    let modules = tree.load_modules().expect("every module reads");
    let mut builder = NameIndex::builder();
    for dep in tree.load_dep_maps().expect("every dependency slice reads") {
        builder.dep_map(&dep);
    }
    for module in &modules {
        builder.module(module);
    }
    // The world is the one the oracle was recorded in: the prototype had no
    // dependency map, so its bytes are the fallback branch an empty
    // `ExternalLinks` reproduces exactly, and it rendered the whole
    // environment, so its links point at a page for every module.
    let index = builder.build_with_a_page_for_every_module(
        LinkIndex::read(&lidx).expect("the .lidx reads"),
        ExternalLinks::default(),
    );

    // `DocInfo.ofConstant` sets `render := false` for projection functions and
    // constructors, i.e. exactly the names that appear as another
    // declaration's members. Those get no `div.decl` on any page.
    let suppressed: HashSet<&str> = modules
        .iter()
        .flat_map(|m| m.declarations.iter())
        .flat_map(|d| d.members.iter())
        .map(|m| m.name.as_str())
        .collect();

    let mut counts = Counts::default();
    let mut failures = Vec::new();
    for module in &modules {
        let path = page_path(&pages, &module.module);
        let page =
            std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        check_page(
            module,
            &page,
            &index,
            &suppressed,
            &mut counts,
            &mut failures,
        );
    }

    eprintln!(
        "{} pages: {} module docs, {} declaration docs, {} field docs, {} anchors",
        modules.len(),
        counts.module_docs,
        counts.decl_docs,
        counts.field_docs,
        counts.anchors,
    );
    assert!(
        failures.is_empty(),
        "{} of {} docstrings differ from the reference pages:\n{}",
        failures.len(),
        counts.total(),
        failures
            .iter()
            .take(20)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
    // A run that found nothing would pass every assertion above.
    assert!(
        counts.module_docs > 500,
        "{} module docs",
        counts.module_docs
    );
    assert!(
        counts.decl_docs > 2_000,
        "{} declaration docs",
        counts.decl_docs
    );
    assert!(counts.anchors > 1_000, "{} anchors", counts.anchors);
    // Named, not tolerated: a second differing reference docstring is a new
    // fault and not this one.
    assert_eq!(
        counts.known_divergences, 1,
        "{KNOWN_SUBSET_DIVERGENCE} is meant to be the only reference docstring \
         this crate does not reproduce"
    );
}

#[derive(Default)]
struct Counts {
    known_divergences: usize,
    module_docs: usize,
    decl_docs: usize,
    field_docs: usize,
    anchors: usize,
}

impl Counts {
    fn total(&self) -> usize {
        self.module_docs + self.decl_docs + self.field_docs
    }
}

fn page_path(pages: &Path, module: &str) -> PathBuf {
    let mut path = pages.to_path_buf();
    for part in module.split('.') {
        path.push(part);
    }
    path.set_extension("html");
    path
}

fn check_page(
    module: &ModuleFile,
    page: &str,
    index: &NameIndex,
    suppressed: &HashSet<&str>,
    counts: &mut Counts,
    failures: &mut Vec<String>,
) {
    let root = page_root(&module.module);
    let names = module_decl_names(module);
    let links = PageLinks::new(index, &root, &names);
    let renderer = links.renderer();

    let mut from = 0;
    for (i, doc) in module.module_docs.iter().enumerate() {
        let what = format!("{} module doc {i}", module.module);
        let Some((at, region)) = wrapped(page, "<div class=\"mod_doc\">", from) else {
            failures.push(format!("{what}: no mod_doc left on the page"));
            continue;
        };
        from = at + region.len();
        counts.module_docs += 1;
        counts.anchors += region.matches("<a href=").count();
        record(
            failures,
            counts,
            &what,
            region,
            &renderer.docstring(&doc.text),
        );
    }

    // Declaration docs: no wrapper of their own, so they are found by the
    // element that always precedes them and bounded by the one that follows.
    for decl in &module.declarations {
        let Some(doc) = &decl.doc else { continue };
        if suppressed.contains(decl.name.as_str()) {
            continue;
        }
        let what = decl.name.clone();
        let key = format!("<div class=\"decl\" id=\"{}\">", escape_html(&decl.name));
        let Some(start) = page.find(&key) else {
            failures.push(format!("{what}: no div.decl on the page"));
            continue;
        };
        let Some(header) = page[start..].find("<div class=\"decl_header\">") else {
            failures.push(format!("{what}: no decl_header"));
            continue;
        };
        let Some(at) = after_matching_div(page, start + header) else {
            failures.push(format!("{what}: unterminated decl_header"));
            continue;
        };
        let got = renderer.docstring(doc);
        counts.decl_docs += 1;
        counts.anchors += got.matches("<a href=").count();
        let rest = &page[at..];
        if !rest.starts_with(&got) {
            let want_len = TERMINATORS
                .iter()
                .filter_map(|t| rest.find(t))
                .min()
                .unwrap_or(rest.len())
                .max(got.len() + 60)
                .min(rest.len());
            record(failures, counts, &what, &rest[..want_len], &got);
            continue;
        }
        // A truncated render would still be a prefix, so the boundary is
        // checked too: what follows has to be the next element, not more text.
        let after = &rest[got.len()..];
        assert!(
            TERMINATORS.iter().any(|t| after.starts_with(t)),
            "{what}: the docstring does not end where the page says it does, \
             next bytes are {:?}",
            &after[..after.len().min(40)]
        );
    }

    // Which members get a structure field doc is `structureHtml`'s business.
    // What is checked here is that each one on the page is a docstring of this
    // module rendered by this crate.
    let expected: BTreeSet<String> = module
        .declarations
        .iter()
        .flat_map(|d| d.members.iter())
        .filter_map(|m| m.doc.as_deref())
        .map(|doc| renderer.docstring(doc))
        .collect();
    let mut from = 0;
    while let Some((at, region)) = wrapped(page, "<div class=\"structure_field_doc\">", from) {
        from = at + region.len();
        counts.field_docs += 1;
        counts.anchors += region.matches("<a href=").count();
        if !expected.contains(region) {
            failures.push(format!(
                "{}: a structure_field_doc is not any member's docstring rendered here\n  page: {}",
                module.module,
                &region[..region.len().min(200)]
            ));
        }
    }
}

/// Records a mismatch, pointing at the first byte where the two part company.
/// The one docstring the prototype's CommonMark subset gets wrong is counted
/// rather than reported; everything else is a fault of this crate.
fn record(failures: &mut Vec<String>, counts: &mut Counts, what: &str, want: &str, got: &str) {
    if want == got {
        return;
    }
    if what == KNOWN_SUBSET_DIVERGENCE {
        counts.known_divergences += 1;
        return;
    }
    failures.push(format!(
        "{what}\n  page: {}\n  here: {}",
        context_where_they_part(want, got),
        context_where_they_part(got, want)
    ));
}

/// The context around the first place `a` and `b` part company, **out of `a`
/// alone** — deliberately not `litedoc4_testutil::text::Diff::report`, which
/// puts each window under a fixed label. The two lines here are `page:` and
/// `here:` of the *same* comparison, so the caller calls this twice with the
/// arguments swapped.
fn context_where_they_part(a: &str, b: &str) -> String {
    let at = a
        .char_indices()
        .zip(b.char_indices())
        .find(|((_, x), (_, y))| x != y)
        .map_or_else(|| a.len().min(b.len()), |((i, _), _)| i);
    let from = a[..at].char_indices().rev().nth(40).map_or(0, |(i, _)| i);
    let to = a[at..]
        .char_indices()
        .nth(60)
        .map_or(a.len(), |(i, _)| at + i);
    format!("…{}", &a[from..to])
}
