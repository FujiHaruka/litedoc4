//! Tag spans over a printed fragment.
//!
//! The extractor flattens doc-gen4's `CodeWithInfos` tree into a pre-order list
//! of spans over the fragment's plain text. On the wire each span is a JSON
//! array in one of three shapes:
//!
//! ```text
//! [start, stop, kind]                      kind 0 (fn) or 2 (sort)
//! [start, stop, 1, name]                   kind 1 (const), no whitespace to restore
//! [start, stop, 1, name, front, back]      kind 1 (const), schema 3 widths
//! ```
//!
//! All four numbers are **UTF-16 code unit** offsets into the fragment text —
//! see [`crate::Utf16Text`]. They are left as plain `u32` here on purpose: the
//! text type refuses to be indexed by bytes, so there is no byte offset around
//! for them to be confused with.
//!
//! They are also not independent of each other. `start <= stop` because
//! `[start, stop)` is a range, and `front <= start` because `front` counts
//! units *in front of* `start`. Both are checked while reading, for the reason
//! the rest of this crate refuses rather than guesses: the arithmetic that
//! assumes them is one method call away from any [`Span`] that exists.

use std::ops::Range;

use serde::de::{self, Deserialize, Deserializer, SeqAccess, Visitor};
use std::fmt;

/// What a span tags. Numbered as the extractor writes them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SpanKind {
    /// `0` — a printed sub-expression with no link of its own (`span.fn`).
    Fn,
    /// `1` — a constant reference, carrying the constant's name.
    Const,
    /// `2` — a sort (`Type`, `Prop`, ...), linked to `foundational_types.html`.
    Sort,
    /// Any other code. Never produced by the current extractor; kept so that
    /// reading an IR from a newer writer cannot fail, and so the renderer can
    /// decide what to do rather than the reader deciding for it.
    Other(u8),
}

impl SpanKind {
    pub fn from_code(code: u8) -> Self {
        match code {
            0 => Self::Fn,
            1 => Self::Const,
            2 => Self::Sort,
            other => Self::Other(other),
        }
    }

    pub fn code(self) -> u8 {
        match self {
            Self::Fn => 0,
            Self::Const => 1,
            Self::Sort => 2,
            Self::Other(other) => other,
        }
    }
}

/// One tag position over a printed fragment.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Span {
    /// First UTF-16 code unit of the tagged text.
    pub start: u32,
    /// One past the last UTF-16 code unit of the tagged text.
    pub stop: u32,
    pub kind: SpanKind,
    /// The constant's name. `Some` exactly when the wire form carried a fourth
    /// element, which the extractor only writes for [`SpanKind::Const`].
    pub name: Option<String>,
    /// Schema 3: UTF-16 code units of whitespace immediately *before* `start`
    /// that doc-gen4 rewrites as plain spaces. Zero when the wire form was the
    /// short one.
    pub front: u32,
    /// Same, immediately *after* `stop`.
    pub back: u32,
}

impl Span {
    pub fn is_const(&self) -> bool {
        self.kind == SpanKind::Const
    }

    /// The tagged text's own range.
    pub fn range(&self) -> Range<u32> {
        self.start..self.stop
    }

    /// The leading whitespace run doc-gen4 turns into spaces, if any.
    ///
    /// # Panics
    ///
    /// If `front > start`, which is a run of whitespace longer than the text in
    /// front of it. A deserialised [`Span`] cannot be in that state — the
    /// visitor refuses the pair — so this is reachable only by building one
    /// field by field, and it panics rather than guessing which of the two
    /// numbers was meant.
    pub fn front_range(&self) -> Option<Range<u32>> {
        (self.front > 0).then(|| self.start - self.front..self.start)
    }

    /// The trailing whitespace run doc-gen4 turns into spaces, if any.
    ///
    /// `None` when the run would end past `u32::MAX`. Unlike `front`, that is
    /// **not** a relation the visitor can refuse on its own: `stop` and `back`
    /// are each legal and only their sum is not, and a fragment that long does
    /// not exist to hold the range anyway — so the same `None` that means "no
    /// trailing whitespace" is the right answer rather than a guess.
    pub fn back_range(&self) -> Option<Range<u32>> {
        (self.back > 0)
            .then(|| self.stop.checked_add(self.back))
            .flatten()
            .map(|end| self.stop..end)
    }
}

impl<'de> Deserialize<'de> for Span {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_seq(SpanVisitor)
    }
}

struct SpanVisitor;

impl<'de> Visitor<'de> for SpanVisitor {
    type Value = Span;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a span array of 3, 4 or 6 elements")
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Span, A::Error> {
        let number = |index: usize, seq: &mut A| -> Result<u32, A::Error> {
            seq.next_element::<u32>()?
                .ok_or_else(|| de::Error::invalid_length(index, &self))
        };
        let start = number(0, &mut seq)?;
        let stop = number(1, &mut seq)?;
        let code = number(2, &mut seq)?;
        let code = u8::try_from(code)
            .map_err(|_| de::Error::custom(format!("span kind {code} does not fit a byte")))?;

        let name = seq.next_element::<String>()?;
        let front = seq.next_element::<u32>()?;
        let back = seq.next_element::<u32>()?;
        if seq.next_element::<de::IgnoredAny>()?.is_some() {
            return Err(de::Error::custom("span array has more than 6 elements"));
        }
        // The widths only mean something as a pair, so a 5-element array is a
        // malformed span rather than a short one. A name is implied by them
        // positionally: element 3 cannot be skipped.
        let (front, back) = match (front, back) {
            (None, None) => (0, 0),
            (Some(front), Some(back)) => (front, back),
            _ => return Err(de::Error::invalid_length(5, &self)),
        };

        // The element count and the kind were the only things checked here, and
        // the four numbers also have to stand in a relation to one another. The
        // extractor writes them from one accumulator — `start = off + front`
        // and `stop = off + total - back` (`Extract.lean:1125`) — so both
        // relations hold by construction on anything it wrote; what these
        // refuse is an IR from somewhere else. Refused at the seam rather than
        // survived downstream: `front_range` is `start - front`, one call away
        // from a `Span` that exists, and an integer overflow there says nothing
        // about which fragment or which span was wrong.
        if start > stop {
            return Err(de::Error::custom(format!(
                "span [{start}, {stop}) is not a range: it ends before it starts"
            )));
        }
        if front > start {
            return Err(de::Error::custom(format!(
                "a span at {start} cannot carry {front} units of leading whitespace: \
                 there are only {start} units in front of it"
            )));
        }

        Ok(Span {
            start,
            stop,
            kind: SpanKind::from_code(code),
            name,
            front,
            back,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(json: &str) -> Span {
        serde_json::from_str(json).expect("valid span")
    }

    #[test]
    fn three_element_form() {
        let s = parse("[0,7,0]");
        assert_eq!(s.start, 0);
        assert_eq!(s.stop, 7);
        assert_eq!(s.kind, SpanKind::Fn);
        assert_eq!(s.name, None);
        assert_eq!((s.front, s.back), (0, 0));
        assert_eq!(s.front_range(), None);
        assert_eq!(s.back_range(), None);
    }

    #[test]
    fn four_element_form_names_a_constant() {
        let s = parse(r#"[2,5,1,"Nat.succ"]"#);
        assert!(s.is_const());
        assert_eq!(s.name.as_deref(), Some("Nat.succ"));
        assert_eq!(s.range(), 2..5);
    }

    #[test]
    fn six_element_form_carries_widths() {
        let s = parse(r#"[4,6,1,"HAdd.hAdd",1,3]"#);
        assert_eq!((s.front, s.back), (1, 3));
        assert_eq!(s.front_range(), Some(3..4));
        assert_eq!(s.back_range(), Some(6..9));
    }

    #[test]
    fn sort_kind() {
        assert_eq!(parse("[0,4,2]").kind, SpanKind::Sort);
    }

    #[test]
    fn unknown_kind_is_kept() {
        assert_eq!(parse("[0,1,9]").kind, SpanKind::Other(9));
    }

    #[test]
    fn malformed_forms_are_rejected() {
        for bad in [
            "[0,1]",
            r#"[0,1,1,"n",2]"#,
            r#"[0,1,1,"n",2,3,4]"#,
            "[0,1,300]",
            // The two the element count and the kind cannot catch: `[5,2)` is
            // not a range, and 3 units of leading whitespace cannot precede
            // offset 0.
            "[5,2,0]",
            r#"[0,1,1,"n",3,0]"#,
        ] {
            assert!(
                serde_json::from_str::<Span>(bad).is_err(),
                "expected {bad} to be rejected"
            );
        }
    }

    /// The refusals name the numbers, as [`crate::Utf16Text::slice`]'s panic
    /// does: a reader who sees `span [5, 2)` in a log knows which span in which
    /// fragment to go and look at, and "invalid value" does not.
    #[test]
    fn the_refusals_say_which_numbers() {
        let inverted = serde_json::from_str::<Span>("[5,2,0]")
            .expect_err("an inverted span is refused")
            .to_string();
        assert!(inverted.contains("[5, 2)"), "{inverted}");

        let front = serde_json::from_str::<Span>(r#"[0,1,1,"n",3,0]"#)
            .expect_err("a front wider than the offset is refused")
            .to_string();
        assert!(front.contains('3'), "{front}");
    }

    /// A span at the very end of the address space: `stop + back` is what
    /// [`Span::back_range`] adds, and the pair is legal on the wire, so the
    /// addition is the one that has to be checked rather than refused.
    #[test]
    fn a_trailing_width_that_runs_off_the_end_is_not_a_range() {
        let s = parse(&format!(r#"[0,{max},1,"n",0,1]"#, max = u32::MAX));
        assert_eq!(s.back_range(), None);
    }
}
