//! `tests/data/docgen4-expected.json` is a frozen recording. It was generated
//! by `tests/oracle/gen-docgen4-expected.ts`, which runs `docStringToHtml`
//! under `lake env lean` in the measurement target and prints the bytes, over
//! every docstring in that package's IR plus hand-written cases for the corners
//! it does not contain. Regenerate the doc-gen4 side with:
//!
//! ```text
//! deno run --allow-read --allow-write --allow-run --allow-env \
//!   crates/litedoc4-md/tests/oracle/gen-docgen4-expected.ts
//! ... --check      # verify the committed file
//! ... --full PATH  # write every case, for a check by hand (no test reads it)
//! ```
//!
//! The whole corpus can be compared, auto-links included: doc-gen4 resolves
//! names against the environment, but `nameToLink?` reads *only* the
//! `AnalyzerResult` in its context and the dumper hands it the empty one, so
//! every lookup misses — which is precisely [`NoLinks`]. Nothing is excluded and
//! nothing is normalised away except the two inputs that kill the Lean side
//! outright ([`the_inputs_that_kill_doc_gen4_here`]).
//!
//! **The point of this oracle is not "doc-gen4 is right".** It is not: it dies
//! outright on a NUL in a fenced code block and on a header-only GFM table, and
//! the generator has to resume around 99 such inputs. What it *defines* is the
//! **dialect** — which extensions are on, how entities and math are read, where
//! relative links resolve from — and Lean's docstrings are written against that
//! dialect. Byte equality is a cheap sufficient condition for "the dialect did
//! not move"; writing a judge for dialect equality directly would be a second
//! implementation sharing this one's mistakes.
//!
//! Only the committed sample runs here — a designed cover of the rules (every
//! hand-written case, then a greedy cover of the output features, then the first
//! case showing each byte-level feature, then a stride over the rest). **The
//! 4,414 cases outside the sample are not checked**: that is the price, stated
//! rather than hidden.

use litedoc4_md::{NoLinks, Renderer};
use litedoc4_testutil::text::{Diff, show_ascii_head};
use serde::Deserialize;

const FIXTURE: &str = include_str!("data/docgen4-expected.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Expected {
    oracle: String,
    lean_toolchain: String,
    doc_gen4_rev: Option<String>,
    ir_docstrings: usize,
    /// The `getRoot` values the corpus was rendered at.
    roots: Vec<String>,
    cases: Vec<Case>,
    /// The inputs that kill the Lean side, recorded rather than expected.
    crashes_doc_gen4: Vec<Crasher>,
}

#[derive(Deserialize)]
struct Case {
    /// Where the docstring came from: a declaration name, or `curated: …`.
    what: String,
    root: String,
    md: String,
    html: String,
}

#[derive(Deserialize)]
struct Crasher {
    what: String,
    md: String,
}

fn expected() -> Expected {
    serde_json::from_str(FIXTURE).expect("tests/data/docgen4-expected.json is valid")
}

/// [`Diff::report_escaped`] and not [`Diff::report`]: this corpus carries
/// combining marks, and a message that printed the characters could read
/// `expected é, got é`.
fn first_difference(want: &str, got: &str) -> String {
    Diff {
        want,
        want_label: "doc-gen4",
        got,
        got_label: "here",
    }
    .report_escaped()
}

fn check(case: &Case) -> Option<String> {
    let got = Renderer::new(&case.root, &NoLinks).docstring(&case.md);
    if got == case.html {
        return None;
    }
    Some(format!(
        "{} (root {:?})\n  input: {}\n  {}",
        case.what,
        case.root,
        show_ascii_head(&case.md, 200),
        first_difference(&case.html, &got)
    ))
}

#[test]
fn the_fixture_is_doc_gen4s_own_output() {
    let e = expected();
    assert!(e.oracle.contains("docStringToHtml"), "{}", e.oracle);
    assert_eq!(e.lean_toolchain, "leanprover/lean4:v4.31.0");
    assert_eq!(
        e.doc_gen4_rev.as_deref(),
        Some("0bc516c1b9db83658d6475c40d9b1ed71219b921"),
        "the doc-gen4 the reference tree was built with"
    );
    // 実測: the target package's IR holds this many distinct docstrings.
    assert_eq!(e.ir_docstrings, 4_858);
    // The root reaches the bytes, so more than one of them has to be exercised.
    assert_eq!(e.roots, ["./", ".././", "../.././"]);
    assert!(e.cases.len() >= 300, "only {} cases", e.cases.len());
    assert_eq!(e.crashes_doc_gen4.len(), 2);
}

/// The fixture holds **this renderer's** frozen bytes, not doc-gen4's: `$…$` is
/// converted to MathML at build time and doc-gen4 does not do that, so five of
/// these cases could never agree with it again, and a comparison that is wrong
/// about five cases by design is one nobody reads twice. So this no longer says
/// "the dialect did not move" — `tests/oracle/gen-docgen4-expected.ts` still
/// produces doc-gen4's answers and that claim can still be re-checked, it is
/// simply not what `cargo test` asserts.
#[test]
fn every_case_matches_the_frozen_output() {
    let e = expected();
    if bless_requested() {
        bless(&e);
        return;
    }
    let failures: Vec<String> = e.cases.iter().filter_map(check).collect();
    assert!(
        failures.is_empty(),
        "{} of {} cases differ from the frozen output:\n{}\n\n\
         If the change is intended, regenerate with:\n    \
         LITEDOC4_BLESS=1 cargo test -p litedoc4-md --test docgen4",
        failures.len(),
        e.cases.len(),
        failures
            .iter()
            .take(10)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}

/// `LITEDOC4_BLESS=1` — rewrite the fixture instead of comparing against it.
fn bless_requested() -> bool {
    std::env::var("LITEDOC4_BLESS").is_ok_and(|value| value == "1")
}

/// Rewrites the fixture from this renderer's output and **prints every case it
/// changed**: the file is one 220 KB line, so its diff is not a review, and this
/// output is where *what changed and because of which case* is read.
///
/// It asserts it is **idempotent** — a second run must change nothing — which
/// catches the failure where re-serialising moves key order or escaping and
/// every future diff is the whole file.
fn bless(e: &Expected) {
    let path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/docgen4-expected.json");
    let original = std::fs::read_to_string(&path).expect("the fixture is readable");
    let mut document: serde_json::Value =
        serde_json::from_str(&original).expect("the fixture is JSON");

    // Round-tripped **before** any edit: if this is not the byte the file
    // holds, every value below would arrive with a different spelling and the
    // change this run is about would be invisible among them.
    let round_trip = serde_json::to_string(&document).expect("it came from JSON") + "\n";
    assert_eq!(
        round_trip, original,
        "re-serialising the fixture does not reproduce it; blessing would rewrite \
         the whole file and no diff of it could be reviewed"
    );

    let cases = document
        .get_mut("cases")
        .and_then(serde_json::Value::as_array_mut)
        .expect("the fixture has cases");
    let mut changed = 0usize;
    for (case, value) in e.cases.iter().zip(cases.iter_mut()) {
        let got = Renderer::new(&case.root, &NoLinks).docstring(&case.md);
        if got == case.html {
            continue;
        }
        changed += 1;
        println!(
            "bless {}\n  was: {}\n  now: {}",
            case.what,
            show_ascii_head(&case.html, 200),
            show_ascii_head(&got, 200)
        );
        value["html"] = serde_json::Value::String(got);
    }
    let updated = serde_json::to_string(&document).expect("values are strings") + "\n";
    std::fs::write(&path, &updated).expect("the fixture is writable");
    println!(
        "bless: {changed} of {} case(s) rewritten in {}",
        e.cases.len(),
        path.display()
    );
    assert_eq!(
        serde_json::to_string(
            &serde_json::from_str::<serde_json::Value>(&updated).expect("what was written is JSON")
        )
        .expect("round trip")
            + "\n",
        updated,
        "the file this wrote does not round-trip"
    );
}

/// The committed sample has to keep reaching every branch of the renderer, or a
/// machine without the target package is checking less than it looks. The
/// markers are on the *output* side on purpose: they are what a wrong branch
/// would change.
#[test]
fn the_sample_still_covers_the_output() {
    let e = expected();
    let all: String = e.cases.iter().map(|c| c.html.as_str()).collect();
    for marker in [
        "<p>",
        "<ul>",
        "<ol>",
        "<ol start=\"",
        "<li>",
        "<hr>\n",
        "<h1 ",
        "<h6 ",
        "class=\"markdown-heading\"",
        "class=\"hover-link\"",
        "<pre><code>",
        "<pre><code class=\"language-",
        "<blockquote>",
        "<table><thead><tr><th>",
        "<tbody><tr><td>",
        "<em>",
        "<strong>",
        "<del>",
        "<br>\n",
        "<code>",
        "<img src=\"",
        " title=\"",
        "<a href=\"",
        "find/?pattern=",
        "$",
        "$$",
        "<input type=\"checkbox\" checked=\"\" disabled=\"\">",
        "<input type=\"checkbox\" disabled=\"\">",
        "&amp;",
        "&lt;",
        "&quot;",
        "\u{FFFD}",
    ] {
        assert!(
            all.contains(marker),
            "nothing in the sample produces {marker:?}"
        );
    }
    // Constructors the docstring dialect's flags leave off; their appearance
    // would mean the dialect had drifted.
    for never in ["<u>", "<x-wikilink"] {
        assert!(
            !all.contains(never),
            "{never:?} appeared; the dialect drifted"
        );
    }
}

/// Both are undefined behaviour on the Lean side, so there are no bytes to
/// match; what is pinned is that neither crashes us and that both still render
/// something.
#[test]
fn the_inputs_that_kill_doc_gen4_here() {
    for crasher in expected().crashes_doc_gen4 {
        let got = Renderer::new("./", &NoLinks).docstring(&crasher.md);
        assert!(!got.is_empty(), "{}", crasher.what);
    }
    // A NUL inside a fenced code block: U+FFFD, then the byte md4c re-reports.
    assert_eq!(
        Renderer::new("./", &NoLinks).docstring("```\na\0b\n```\n"),
        "<pre><code>a\u{FFFD}\0b\n</code></pre>"
    );
    // A table with a header and no body rows: an empty `<tbody>`.
    assert_eq!(
        Renderer::new("./", &NoLinks).docstring("| a | b |\n|---|---|\n"),
        "<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody></tbody></table>"
    );
}
