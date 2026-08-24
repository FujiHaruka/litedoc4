//! Derived from doc-gen4 (Copyright (c) 2021 Henrik Böving, Apache-2.0) and
//! changed; see this repository's NOTICE and `docs/provenance.md`.
//!
//! `Html.escape` — the only escape doc-gen4 applies to HTML text and attributes.
//!
//! It covers `& < > "` and **nothing else**; in particular `'` is left alone
//! (`DocGen4/Output/ToHtmlFormat.lean`). Every general-purpose HTML-escaping
//! crate also rewrites `'`, and one such character in a page is one byte of
//! mismatch against doc-gen4's own output.
//!
//! It is not markdown-specific — it is the escape every HTML assembly in this
//! workspace uses — but it lives here because this is the lowest crate that
//! assembles HTML, and `litedoc4-render` depends on `litedoc4-md` rather than
//! the other way round. `litedoc4_render::escape_html` re-exports it, so there
//! is one implementation.

use std::borrow::Cow;

const fn is_escapable(byte: u8) -> bool {
    matches!(byte, b'&' | b'<' | b'>' | b'"')
}

pub fn escape_html(s: &str) -> Cow<'_, str> {
    if !s.bytes().any(is_escapable) {
        return Cow::Borrowed(s);
    }
    let mut out = String::with_capacity(s.len() + 8);
    escape_html_into(&mut out, s);
    Cow::Owned(out)
}

pub fn escape_html_into(out: &mut String, s: &str) {
    // The four characters are ASCII, and UTF-8 never encodes a non-ASCII scalar
    // with an ASCII byte, so scanning bytes cannot split a multi-byte scalar.
    let mut rest = s;
    while let Some(at) = rest.bytes().position(is_escapable) {
        out.push_str(&rest[..at]);
        out.push_str(match rest.as_bytes()[at] {
            b'&' => "&amp;",
            b'<' => "&lt;",
            b'>' => "&gt;",
            _ => "&quot;",
        });
        rest = &rest[at + 1..];
    }
    out.push_str(rest);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_four_characters_and_no_others() {
        assert_eq!(
            escape_html("a & b < c > d \" e"),
            "a &amp; b &lt; c &gt; d &quot; e"
        );
        assert_eq!(escape_html("Nat.succ'"), "Nat.succ'");
        assert_eq!(escape_html("a/b"), "a/b");
    }

    #[test]
    fn escape_borrows_when_it_can() {
        assert!(matches!(escape_html("∀ x, p x"), Cow::Borrowed(_)));
        assert!(matches!(escape_html("a<b"), Cow::Owned(_)));
    }

    #[test]
    fn escape_leaves_non_ascii_alone() {
        assert_eq!(escape_html("ℕ ∑ ≐ μ 𝒜 日本語"), "ℕ ∑ ≐ μ 𝒜 日本語");
    }
}
