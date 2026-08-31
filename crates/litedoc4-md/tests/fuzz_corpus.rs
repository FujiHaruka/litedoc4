//! Nothing crashes the parser — the claim this crate makes and could not check.
//!
//! **MD4Lean dies on two inputs**: a NUL inside a fenced code block is a
//! SIGSEGV and a GFM table with no body row is a SIGABRT. Lean's behaviour
//! there is undefined, so byte equality was never possible, and **this crate
//! was deliberately written to fall the other way** — U+FFFD for the NUL, an
//! empty body for the table. That decision was verified against 4,858 real
//! docstrings that contain **neither** shape, and a claim about inputs the
//! corpus does not contain cannot be checked by the corpus.
//!
//! Two things are checked, and they are different in kind:
//!
//! - **The committed corpus** (`fixtures/md/fuzz/`) is every input shape known
//!   to be dangerous — the two that kill MD4Lean, plus deep nesting,
//!   unterminated constructs, astral characters, a 200 KB line, entity edge
//!   cases, CR without LF, and the empty string. **Adding a file to that
//!   directory adds a case**; a crash found later belongs there rather than in
//!   a comment.
//! - **Generated input**, from a fixed seed. The generator is deliberately
//!   crude — it splices corpus fragments and byte noise — because the failures
//!   this is guarding against are memory-safety failures in C, and those do not
//!   need well-formed Markdown to happen.
//!
//! Not `cargo-fuzz`: it, libFuzzer and `-Zsanitizer=address` all need nightly,
//! and `rust-toolchain.toml` pins stable for everyone including CI, so that
//! gate would run on one machine. Exhaustive exploration is still worth doing
//! out-of-band; what belongs here is the part that has to keep passing on every
//! push.

#![expect(
    clippy::cast_possible_truncation,
    reason = "the PRNG word is reduced modulo the fragment count on the same line"
)]

use std::path::{Path, PathBuf};

use litedoc4_md::{NoLinks, Renderer};

fn corpus_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/md/fuzz")
}

/// The return value is deliberately ignored: what is asserted is that control
/// comes back at all. A wrong `<p>` is a bug for another test; a segfault is
/// this one's whole subject.
fn render(text: &str) {
    let renderer = Renderer::new("../", &NoLinks);
    let _ = renderer.docstring(text);
}

#[test]
fn no_committed_input_crashes() {
    let dir = corpus_dir();
    let mut seen = 0;
    for entry in std::fs::read_dir(&dir).expect("the fuzz corpus directory exists") {
        let path = entry.expect("a readable entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let bytes = std::fs::read(&path).expect("a readable input");
        // Lossy on purpose: the extractor hands this crate a Lean `String`, so
        // the input is always valid UTF-8 by the time it arrives. What the
        // corpus exercises is the *content*, NUL included.
        let text = String::from_utf8_lossy(&bytes);
        render(&text);
        seen += 1;
    }
    // A corpus that silently emptied would make this test pass while checking
    // nothing.
    assert!(
        seen >= 12,
        "only {seen} corpus inputs found in {} — did the directory move?",
        dir.display()
    );
}

/// Duplicated from the corpus on purpose: if somebody deletes the files, the
/// two cases the **decision to fall the other way** was made about must still
/// be run.
#[test]
fn the_two_inputs_that_kill_md4lean_return() {
    // SIGSEGV in MD4Lean.
    render("```\n\0\n```\n");
    render("prose\n\n```lean\nexample : Nat := \0 1\n```\n");
    // Assertion failure, SIGABRT in MD4Lean.
    render("| a | b |\n| --- | --- |\n");
    render("text\n\n| only | a | header |\n| --- | --- | --- |\n\nmore\n");
}

/// The seed is fixed because a gate that fails on one push in fifty and passes
/// on the retry teaches people to hit retry. New shapes come from raising
/// `ROUNDS` or adding a corpus file, deliberately — not from the clock.
#[test]
fn generated_input_does_not_crash() {
    const ROUNDS: usize = 4_000;
    let fragments = [
        "```",
        "~~~",
        "\0",
        "| a |",
        "| --- |",
        "> ",
        "- ",
        "#",
        "`",
        "**",
        "[",
        "]",
        "(",
        ")",
        "<div>",
        "</div>",
        "\r",
        "\n",
        "  ",
        "\t",
        "𝒜",
        "é",
        "&#x1D49C;",
        "&",
        ";",
        "$",
        "\\",
        "http://x.invalid",
        "_",
        "*",
        "!",
        "^",
        "~",
        "|",
        "=",
        "'",
        "\"",
        "<",
        ">",
    ];
    let mut state: u64 = 0x5EED_1234_ABCD_0001;
    let mut next = move || {
        // xorshift64*: a PRNG small enough to read, which is the only property
        // that matters here.
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        state.wrapping_mul(0x2545_F491_4F6C_DD1D)
    };

    for _ in 0..ROUNDS {
        let pieces = (next() % 24) as usize + 1;
        let mut input = String::new();
        for _ in 0..pieces {
            input.push_str(fragments[(next() as usize) % fragments.len()]);
        }
        render(&input);
    }
}

/// An FFI boundary is where "the same input twice gives the same bytes" stops
/// being obvious — uninitialised memory read back as a length, or a buffer
/// reused between calls, shows up exactly here and nowhere else.
#[test]
fn rendering_is_deterministic_over_the_corpus() {
    for entry in std::fs::read_dir(corpus_dir()).expect("the fuzz corpus directory exists") {
        let path = entry.expect("a readable entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let text =
            String::from_utf8_lossy(&std::fs::read(&path).expect("a readable input")).into_owned();
        let renderer = Renderer::new("../", &NoLinks);
        let once = renderer.docstring(&text);
        let twice = renderer.docstring(&text);
        assert_eq!(once, twice, "{} rendered differently twice", path.display());
    }
}
