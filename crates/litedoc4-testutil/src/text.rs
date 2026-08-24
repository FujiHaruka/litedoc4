//! Turning a string into a failure message, and one comparison report.
//!
//! **The subject of the comparison picks the escape, not taste.** Comparing
//! markup a person reads → [`show`], which keeps printable non-ASCII: the
//! render corpora are full of `₂`, `β`, `↑`, `→`, `μ`, and spelling those
//! `<U+2082>` would make the message unreadable in the one case it exists for.
//! Comparing bytes against an oracle → [`show_ascii`], or [`show_ascii_head`]
//! where an input runs to kilobytes, which destroys exactly those characters:
//! the md corpora hold combining marks, so `é` is either one code point or two,
//! and a message that printed the character would read `expected é, got é`.

use std::fmt::Write as _;

/// Every control character named, everything else — printable non-ASCII
/// included — left alone. See the module header for when that is the wrong
/// policy and [`show_ascii`] is the right one.
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
/// The escape for a comparison **against a byte oracle**, where two characters
/// that draw the same are still a failure. [`show`] is the one for markup a
/// person is reading.
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
/// Without the trailing `...`, a message that ended at a 200-character boundary
/// and a message about a 200-character input are the same string. `max` counts
/// characters of the input, not of the escaped output — one astral character
/// can expand to eight.
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
/// One constant, deliberately: per-oracle window sizes print the same
/// disagreement two ways, and the two messages then cannot be laid side by
/// side. Moving these moves **every** report.
const BEFORE: usize = 40;
const AFTER: usize = 90;

/// Two strings that were meant to be equal, and what to call each of them:
/// `want` is the recorded side (the oracle, the frozen fixture), `got` is what
/// this tree produced.
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
    pub want: &'a str,
    /// What a reader should call [`Self::want`] — "frozen", "doc-gen4".
    pub want_label: &'a str,
    pub got: &'a str,
    /// What a reader should call [`Self::got`] — usually "here".
    pub got_label: &'a str,
}

impl Diff<'_> {
    /// The first byte at which the two part company, with a window of **both**
    /// sides around it, verbatim — for markup, where the characters are the
    /// subject of the comparison. Use [`Self::report_escaped`] against a byte
    /// oracle.
    pub fn report(&self) -> String {
        self.format(str::to_owned)
    }

    /// [`Self::report`] with both windows through [`show_ascii`], for a
    /// comparison whose subject is bytes.
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

    /// The window is cut with `floor_char_boundary` on both ends rather than by
    /// slicing bytes, so a difference that lands **inside** a multi-byte
    /// character trims to the character before it instead of panicking. That is
    /// also why `at` can name a byte the window does not reach: the offset is
    /// the answer, the window is context for it.
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

    #[test]
    fn show_names_the_control_characters_and_keeps_the_rest() {
        assert_eq!(show("a\tb\nc"), "a\\tb\\nc");
        assert_eq!(show("α ≤ β"), "α ≤ β");
        assert_eq!(show("\u{0}\u{7f}"), "<U+0000><U+007F>");
        // Not a control character, and not ASCII: the branch that separates the
        // two policies.
        assert_eq!(show("\u{a0}"), "\u{a0}");
    }

    #[test]
    fn show_ascii_destroys_what_show_keeps() {
        assert_eq!(show_ascii("α ≤ β"), "<U+03B1> <U+2264> <U+03B2>");
        assert_eq!(show_ascii("a\tb\nc"), "a<U+0009>b<U+000A>c");
        assert_eq!(show_ascii("plain ASCII!"), "plain ASCII!");
    }

    #[test]
    fn show_ascii_separates_a_combining_mark_from_the_composed_character() {
        assert_ne!(show_ascii("e\u{301}"), show_ascii("\u{e9}"));
        assert_eq!(show_ascii("e\u{301}"), "e<U+0301>");
        assert_eq!(show_ascii("\u{e9}"), "<U+00E9>");
        assert_eq!(show("e\u{301}"), "e\u{301}");
        assert_eq!(show("\u{e9}"), "\u{e9}");
    }

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

    #[test]
    fn report_names_the_offset_and_both_labels() {
        let report = diff("hello world", "hello WORLD").report();
        assert_eq!(
            report,
            "byte 6 of 11 (frozen) / 11 (here)\n  frozen: …hello world…\n  here:   …hello WORLD…"
        );
    }

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

    #[test]
    fn report_escaped_escapes_only_the_windows() {
        let d = diff("α", "β");
        let (plain, escaped) = (d.report(), d.report_escaped());
        assert_eq!(plain.lines().count(), escaped.lines().count());
        assert!(escaped.contains("<U+03B1>"), "{escaped}");
        assert!(escaped.contains("<U+03B2>"), "{escaped}");
        assert!(!escaped.contains('α'), "{escaped}");
        assert!(plain.contains('α'), "{plain}");
        assert_eq!(plain.lines().next(), escaped.lines().next());
    }

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

    /// The width is written down here rather than read from [`BEFORE`] and
    /// [`AFTER`]: reading the constants would make this test agree with
    /// whatever they said, which is not a check. Moving the window has to be
    /// written twice, on purpose.
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
