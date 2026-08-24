//! The document tree, shaped exactly like MD4Lean's Lean ADT.
//!
//! The renderer in `html.rs` is a transcription of `DocGen4/Output/DocString.lean`,
//! which is a `match` over `MD4Lean.Block` / `MD4Lean.Text`. Every branch it
//! takes and every field it reads has to exist here under the same meaning, or
//! the port becomes a translation — and a translation is where byte differences
//! come from. So the constructors below are the ones in `MD4Lean.lean`, in that
//! order, carrying the same payloads.
//!
//! Two consequences of following Lean rather than md4c:
//!
//! - **Verbatim contents are `Vec<String>`, not `Vec<Text>`.** Code blocks,
//!   code spans, math spans and raw HTML blocks receive exactly one text type
//!   from md4c, so MD4Lean drops the wrapper and keeps the strings. doc-gen4
//!   relies on that: it calls `String.join` on them.
//! - **Table cells are `Vec<Text>` with no alignment.** md4c reports
//!   `MD_ALIGN` per cell; MD4Lean discards it, so doc-gen4 never emits an
//!   `align` attribute, so neither do we.
//!
//! Entities are **not** expanded. md4c has no entity table (that lives in the
//! HTML renderer we deliberately do not vendor), and doc-gen4 passes them
//! through with `Html.raw`, so [`Text::Entity`] carries the source text
//! including the `&` and `;`.

/// Text inside an attribute: a link destination, an image source, a title, or a
/// code fence's info string.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AttrText {
    Normal(String),
    Entity(String),
    NullChar,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Text {
    Normal(String),
    NullChar,
    /// The payload is md4c's source text for the break.
    Br(String),
    /// The payload is md4c's source text for the break.
    SoftBr(String),
    Entity(String),
    Em(Vec<Self>),
    Strong(Vec<Self>),
    /// Needs `MD_FLAG_UNDERLINE`, which docstrings do not use.
    U(Vec<Self>),
    A {
        href: Vec<AttrText>,
        /// Empty when the source gave none.
        title: Vec<AttrText>,
        /// True for `<...>` and permissive autolinks.
        is_auto: bool,
        children: Vec<Self>,
    },
    Img {
        src: Vec<AttrText>,
        /// Empty when the source gave none.
        title: Vec<AttrText>,
        alt: Vec<Self>,
    },
    /// md4c may split one span into several pieces.
    Code(Vec<String>),
    Del(Vec<Self>),
    LatexMath(Vec<String>),
    LatexMathDisplay(Vec<String>),
    /// Needs `MD_FLAG_WIKILINKS`, which docstrings do not use.
    WikiLink {
        target: Vec<AttrText>,
        children: Vec<Self>,
    },
}

/// The task fields are populated only under `MD_FLAG_TASKLISTS`, which the
/// docstring dialect does enable.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Li {
    pub is_task: bool,
    /// The character between the brackets: `x`, `X` or a space.
    pub task_char: Option<char>,
    /// Byte offset of that character in the input.
    pub task_mark_offset: Option<u32>,
    pub contents: Vec<Block>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Block {
    P(Vec<Text>),
    Ul {
        tight: bool,
        /// The bullet character used in the source.
        mark: char,
        items: Vec<Li>,
    },
    Ol {
        tight: bool,
        start: u32,
        /// The delimiter after the number: `.` or `)`.
        mark: char,
        items: Vec<Li>,
    },
    Hr,
    Header {
        level: u32,
        texts: Vec<Text>,
    },
    Code {
        /// Everything after the opening fence.
        info: Vec<AttrText>,
        /// The first word of `info`; what doc-gen4 turns into `language-…`.
        lang: Vec<AttrText>,
        /// `None` for an indented code block.
        fence_char: Option<char>,
        /// In the pieces md4c produced: one per line, plus the newlines.
        content: Vec<String>,
    },
    /// Never produced under `MD_FLAG_NOHTML`.
    Html(Vec<String>),
    BlockQuote(Vec<Self>),
    Table {
        /// md4c guarantees exactly one header row.
        head: Vec<Vec<Text>>,
        body: Vec<Vec<Vec<Text>>>,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Document {
    pub blocks: Vec<Block>,
}
