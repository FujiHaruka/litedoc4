//! Turning a string into a failure message, and one comparison report.
//!
//! Nothing here is ever reached by a passing test. Every function is on the
//! branch after an assertion has already decided the run is red; what they
//! decide is whether the person reading the red can tell **what** disagreed.
//!
//! WHICH ESCAPE — THE SUBJECT OF THE COMPARISON DECIDES, NOT TASTE
//!
//! [`show`] keeps every printable character whatever its code point and names
//! only the control ones. Its callers compare **markup a person reads**:
//! `litedoc4-render/tests/fragment.rs` and `.../autolink.rs` put a rendered
//! docstring in front of whoever is reading the failure, and those two corpora
//! hold 3,409 and 2,126 non-ASCII characters — `₂`, `β`, `↑`, `→`, `μ`
//! 【実測 2026-08-23, the two `tests/data/*-expected.json`】. Rendering those as
//! `<U+2082>` would make the message unreadable in the one case it exists for.
//!
//! [`show_ascii`] destroys exactly those characters: anything outside the ASCII
//! graphic range becomes `<U+XXXX>`. Its callers compare **bytes against an
//! oracle** — `litedoc4-md/tests/docgen4.rs`, `.../md4lean.rs` and
//! `litedoc4-render/tests/differential.rs` — where the two sides can differ by a
//! code point no terminal draws differently. That is not hypothetical in these
//! corpora: `docgen4-expected.json` carries 12 combining marks (U+0301, U+0302,
//! U+0303) and `md4lean-expected.json` 28 【実測 2026-08-23】, so `é` there is
//! either one code point or two, and a message that printed the character would
//! read `expected é, got é`. `tests/data/fuzz/astral.md` is the same shape
//! written down on purpose.
//!
//! So: comparing what a reader sees → [`show`]. Comparing what a byte oracle
//! recorded → [`show_ascii`], or [`show_ascii_head`] where an input runs to
//! kilobytes.

use std::fmt::Write as _;

/// Every control character named, everything else left alone.
///
/// `\n` and `\t` get their usual two-character spellings because they are the
/// two that occur in every disagreement; any other control character becomes
/// `<U+XXXX>`. **Printable non-ASCII survives** — see the module header for why
/// that is the point and not an omission, and [`show_ascii`] for the other
/// policy.
pub fn show(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c == '\n' {
            out.push_str("\\n");
        } else if c == '\t' {
            out.push_str("\\t");
        } else if c.is_ascii_graphic() || c == ' ' || !c.is_control() {
            out.push(c);
        } else {
            write!(out, "<U+{:04X}>", c as u32).expect("writing to a String cannot fail");
        }
    }
    out
}

/// Only ASCII graphic characters and the space survive; everything else,
/// printable or not, becomes `<U+XXXX>`.
///
/// This is the escape for a comparison **against a byte oracle**, where two
/// characters that draw the same are still a failure — see the module header.
/// [`show`] is the one for markup a person is reading.
pub fn show_ascii(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c.is_ascii_graphic() || c == ' ' {
            out.push(c);
        } else {
            write!(out, "<U+{:04X}>", c as u32).expect("writing to a String cannot fail");
        }
    }
    out
}

/// [`show_ascii`] of the first `max` characters, with `...` appended **only if
/// there were more**.
///
/// The trailing `...` is the whole point of the cut being visible: without it a
/// message that ended at a 200-character boundary and a message about a
/// 200-character input are the same string. `max` counts characters of the
/// input, not of the escaped output — one astral character can expand to eight.
pub fn show_ascii_head(s: &str, max: usize) -> String {
    let head: String = s.chars().take(max).collect();
    let shown = show_ascii(&head);
    if s.chars().count() > max {
        format!("{shown}...")
    } else {
        shown
    }
}

/// How far either side of the first difference [`Diff`] shows, in bytes.
///
/// **One constant, deliberately.** Two oracles over the same corpus used to cut
/// their windows differently (40/90 in `litedoc4-render/tests/page_parts.rs`,
/// 40/40 in `litedoc4-md/tests/docgen4.rs`), so the same disagreement printed
/// two ways and the two messages could not be laid side by side — §7 U3 of
/// `docs/plans/refactoring.md`. Moving these moves **every** report; that is
/// what makes them comparable.
const BEFORE: usize = 40;
/// See [`BEFORE`].
const AFTER: usize = 90;

/// Two strings that were meant to be equal, and what to call each of them.
///
/// The labels are fields rather than positional arguments so that a call site
/// cannot swap them without the swap being written down — the weakness §4 R8 of
/// `docs/plans/refactoring.md` removed from three other signatures. `want` is
/// the recorded side (the oracle, the frozen fixture); `got` is what this tree
/// produced.
///
/// ```
/// use litedoc4_testutil::text::Diff;
///
/// let report = Diff {
///     want: "abc",
///     want_label: "frozen",
///     got: "abd",
///     got_label: "here",
/// }
/// .report();
/// assert!(report.starts_with("byte 2 of 3 (frozen) / 3 (here)"));
/// ```
pub struct Diff<'a> {
    /// The recorded side.
    pub want: &'a str,
    /// What a reader should call [`Self::want`] — "frozen", "doc-gen4".
    pub want_label: &'a str,
    /// What this tree produced.
    pub got: &'a str,
    /// What a reader should call [`Self::got`] — usually "here".
    pub got_label: &'a str,
}

impl Diff<'_> {
    /// The first byte at which the two part company, with a window of **both**
    /// sides around it, verbatim.
    ///
    /// For HTML and other markup, where the characters are the subject of the
    /// comparison. Use [`Self::report_escaped`] against a byte oracle.
    pub fn report(&self) -> String {
        self.format(str::to_owned)
    }

    /// [`Self::report`] with both windows through [`show_ascii`].
    ///
    /// For a comparison whose subject is bytes, where a look-alike code point
    /// is a real difference the reader must be able to see.
    pub fn report_escaped(&self) -> String {
        self.format(show_ascii)
    }

    /// The first byte position at which the two differ, or the length of the
    /// shorter one when one is a prefix of the other.
    fn at(&self) -> usize {
        self.want
            .bytes()
            .zip(self.got.bytes())
            .position(|(a, b)| a != b)
            .unwrap_or_else(|| self.want.len().min(self.got.len()))
    }

    /// Both windows, each through `render`, under the two labels.
    ///
    /// The window is cut with `floor_char_boundary` on both ends rather than by
    /// slicing bytes, so a difference that lands **inside** a multi-byte
    /// character trims to the character before it instead of panicking or
    /// printing a replacement character. That is also why `at` can name a byte
    /// the window does not reach: the offset is the answer, the window is
    /// context for it.
    fn format(&self, render: impl Fn(&str) -> String) -> String {
        let at = self.at();
        let window = |text: &str| {
            let start = text.floor_char_boundary(at.saturating_sub(BEFORE));
            let end = text.floor_char_boundary((at + AFTER).min(text.len()));
            render(&text[start..end])
        };
        let want_tag = format!("{}:", self.want_label);
        let got_tag = format!("{}:", self.got_label);
        let w = want_tag.len().max(got_tag.len());
        format!(
            "byte {at} of {} ({}) / {} ({})\n  {want_tag:<w$} …{}…\n  {got_tag:<w$} …{}…",
            self.want.len(),
            self.want_label,
            self.got.len(),
            self.got_label,
            window(self.want),
            window(self.got)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The two spellings [`show`] gives a name and the one it must not.
    ///
    /// The `α` is the whole disagreement with [`show_ascii`]: a render oracle
    /// prints thousands of them and a message that escaped them would be the
    /// unreadable one.
    #[test]
    fn show_names_the_control_characters_and_keeps_the_rest() {
        assert_eq!(show("a\tb\nc"), "a\\tb\\nc");
        assert_eq!(show("α ≤ β"), "α ≤ β");
        assert_eq!(show("\u{0}\u{7f}"), "<U+0000><U+007F>");
        // Not a control character, and not ASCII: the branch that separates the
        // two policies.
        assert_eq!(show("\u{a0}"), "\u{a0}");
    }

    /// The other policy, on the same input.
    #[test]
    fn show_ascii_destroys_what_show_keeps() {
        assert_eq!(show_ascii("α ≤ β"), "<U+03B1> <U+2264> <U+03B2>");
        assert_eq!(show_ascii("a\tb\nc"), "a<U+0009>b<U+000A>c");
        assert_eq!(show_ascii("plain ASCII!"), "plain ASCII!");
    }

    /// The two look-alike spellings of `é`, which is why the md oracles escape.
    #[test]
    fn show_ascii_separates_a_combining_mark_from_the_composed_character() {
        assert_ne!(show_ascii("e\u{301}"), show_ascii("\u{e9}"));
        assert_eq!(show_ascii("e\u{301}"), "e<U+0301>");
        assert_eq!(show_ascii("\u{e9}"), "<U+00E9>");
        // And `show` copies both through untouched, naming neither code point:
        // the two messages differ only in bytes a terminal draws identically,
        // which is the reason the md tests are not allowed to use it.
        assert_eq!(show("e\u{301}"), "e\u{301}");
        assert_eq!(show("\u{e9}"), "\u{e9}");
    }

    /// The ellipsis marks a cut and nothing else.
    #[test]
    fn show_ascii_head_appends_the_ellipsis_only_when_it_cut() {
        assert_eq!(show_ascii_head("abcde", 5), "abcde");
        assert_eq!(show_ascii_head("abcdef", 5), "abcde...");
        assert_eq!(show_ascii_head("abc", 5), "abc");
        // Characters, not bytes: three astral characters are twelve bytes and
        // the cut is after the second.
        assert_eq!(show_ascii_head("𝒜𝒜𝒜", 2), "<U+1D49C><U+1D49C>...");
    }

    fn diff<'a>(want: &'a str, got: &'a str) -> Diff<'a> {
        Diff {
            want,
            want_label: "frozen",
            got,
            got_label: "here",
        }
    }

    /// A report names where, how long each side is, and which side is which.
    #[test]
    fn report_names_the_offset_and_both_labels() {
        let report = diff("hello world", "hello WORLD").report();
        assert_eq!(
            report,
            "byte 6 of 11 (frozen) / 11 (here)\n  frozen: …hello world…\n  here:   …hello WORLD…"
        );
    }

    /// The labels reach the message rather than being decoration on the struct.
    #[test]
    fn report_uses_the_labels_it_was_given() {
        let report = Diff {
            want: "a",
            want_label: "doc-gen4",
            got: "b",
            got_label: "here",
        }
        .report();
        assert_eq!(
            report,
            "byte 0 of 1 (doc-gen4) / 1 (here)\n  doc-gen4: …a…\n  here:     …b…"
        );
    }

    /// `report_escaped` is the same report with the windows escaped, and the
    /// escaping is the only difference.
    #[test]
    fn report_escaped_escapes_only_the_windows() {
        let d = diff("α", "β");
        let (plain, escaped) = (d.report(), d.report_escaped());
        assert_eq!(plain.lines().count(), escaped.lines().count());
        assert!(escaped.contains("<U+03B1>"), "{escaped}");
        assert!(escaped.contains("<U+03B2>"), "{escaped}");
        assert!(!escaped.contains('α'), "{escaped}");
        assert!(plain.contains('α'), "{plain}");
        // The offset line is byte for byte the same in both.
        assert_eq!(plain.lines().next(), escaped.lines().next());
    }

    /// The window is cut on character boundaries, so a difference inside a
    /// multi-byte character is reported rather than panicked on.
    #[test]
    fn a_difference_inside_a_multibyte_character_does_not_panic() {
        // `α` and `β` share their first byte, so the first differing byte is 1
        // — the middle of a two-byte character on both sides.
        let d = diff("α", "β");
        assert!(d.report().starts_with("byte 1 of 2 (frozen) / 2 (here)"));
        assert!(d.report_escaped().starts_with("byte 1 of 2 "));
        // Far enough in that the window's start also lands mid-character.
        let want = "α".repeat(60);
        let got = format!("{}β", "α".repeat(59));
        let d = diff(&want, &got);
        assert!(d.report().contains("byte 119"), "{}", d.report());
        assert!(
            d.report_escaped().contains("byte 119"),
            "{}",
            d.report_escaped()
        );
    }

    /// One side a prefix of the other: the offset is the shorter length, which
    /// is one past the end of that side's window.
    #[test]
    fn a_prefix_reports_at_the_end_of_the_shorter_side() {
        let d = diff("abc", "abcdef");
        assert_eq!(
            d.report(),
            "byte 3 of 3 (frozen) / 6 (here)\n  frozen: …abc…\n  here:   …abcdef…"
        );
        assert_eq!(diff("", "").report().lines().count(), 3);
        assert!(
            diff("", "x")
                .report()
                .starts_with("byte 0 of 0 (frozen) / 1")
        );
    }

    /// Both sides of both reports are cut to the same width, and the width is
    /// written down here rather than read from [`BEFORE`] and [`AFTER`].
    ///
    /// Reading the constants would make this test agree with whatever they
    /// said, which is not a check. The number is the decision §7 U3 of
    /// `docs/plans/refactoring.md` asked for — two oracles over one corpus used
    /// 40/90 and 40/40 — so moving it has to be written twice, on purpose.
    #[test]
    fn every_window_is_one_hundred_and_thirty_bytes() {
        let want = format!("{}X{}", "a".repeat(200), "b".repeat(200));
        let got = format!("{}Y{}", "a".repeat(200), "b".repeat(200));
        let d = diff(&want, &got);
        let widths = |report: &str| -> Vec<usize> {
            report
                .lines()
                .skip(1)
                .map(|line| {
                    let window = line.split_once('…').expect("an opening ellipsis").1;
                    window.strip_suffix('…').expect("a closing ellipsis").len()
                })
                .collect()
        };
        assert_eq!(widths(&d.report()), vec![130, 130]);
        assert_eq!(widths(&d.report_escaped()), vec![130, 130]);
    }
}
