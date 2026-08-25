//! Derived from MD4Lean's `wrapper/wrapper.c` (MIT, Copyright (c) 2024 Jz Pan)
//! and changed; see this repository's NOTICE and `docs/provenance.md`.
//!
//! md4c's push callbacks, assembled into the AST of [`crate::ast`].
//!
//! This is a transliteration, not a design. doc-gen4 renders `MD4Lean.parse`'s
//! output, and `wrapper.c` is what turns md4c's callbacks into that value, so
//! the way to be sure our tree is the same tree is to run the same algorithm
//! rather than an equivalent one. Two of its rules are not obvious:
//!
//! - **Details are read where the wrapper reads them.** For containers one
//!   md4c block record can close one node and open the next, so `leave_block`'s
//!   `detail` is not always the leaving node's. The wrapper keeps UL / OL / H
//!   details from `enter_block` and takes LI / CODE (and every span's) from
//!   `leave_block` / `leave_span`; copying that choice is cheaper than
//!   re-deriving it.
//! - **Implicit paragraphs inside list items.** md4c puts text directly under
//!   `MD_BLOCK_LI`, mixed with real blocks; MD4Lean's `Li` holds blocks only,
//!   so a `P` is opened when text arrives under an `LI` and closed when a
//!   sibling block starts or the item ends. doc-gen4's `renderLi` iterates
//!   blocks, so this is load-bearing, not cosmetic.
//!
//! Three inputs make the Lean wrapper do something undefined — all three kill
//! the process (measured) — so none can be matched. Each is decided here and
//! pinned by `tests/md4lean.rs`:
//!
//! 1. **A NUL inside a code block.** md4c reports `MD_TEXT_NULLCHAR` even in
//!    verbatim content, where MD4Lean's types expect strings, and the wrapper
//!    pushes a scalar constructor into an `Array String`. We substitute U+FFFD,
//!    which is what CommonMark asks for and what doc-gen4 renders `.nullchar`
//!    as.
//! 2. **A table with a header and no body rows.** md4c then emits no
//!    `MD_BLOCK_TBODY` at all, and the wrapper indexes a child that is not
//!    there. We produce an empty body.
//! 3. **Inline raw HTML**, which needs `MD_FLAG_NOHTMLSPANS` off and so cannot
//!    happen to a docstring. `MD4Lean.Text` has no constructor for it, and the
//!    wrapper puts a bare `String` in an `Array Text`. We return
//!    [`Error::Unrepresentable`]: widening this crate's AST would put a branch
//!    in the HTML port that doc-gen4 has no counterpart for.

use std::ffi::{c_int, c_void};
use std::slice;

use crate::ast::{AttrText, Block, Document, Li, Text};
use crate::error::{Error, Result};
use crate::ffi::{
    MdAttribute, MdBlockCodeDetail, MdBlockHDetail, MdBlockLiDetail, MdBlockOlDetail, MdBlockType,
    MdBlockUlDetail, MdChar, MdParser, MdSize, MdSpanADetail, MdSpanImgDetail, MdSpanType,
    MdSpanWikilinkDetail, MdTextType, md_parse,
};
use crate::flags;

/// Parses with the flags doc-gen4 uses ([`flags::DOCSTRING_FLAGS`]).
///
/// ```
/// let doc = litedoc4_md::parse("a *b*").unwrap();
/// assert_eq!(doc.blocks.len(), 1);
/// ```
pub fn parse(text: &str) -> Result<Document> {
    parse_with_flags(text, flags::DOCSTRING_FLAGS)
}

/// Public so the differential test against MD4Lean can drive both sides with
/// the same flags: a dialect that only exists as a constant is one nobody can
/// vary in a test.
pub fn parse_with_flags(text: &str, flags: u32) -> Result<Document> {
    let size =
        MdSize::try_from(text.len()).map_err(|_| Error::InputTooLarge { bytes: text.len() })?;

    let parser = MdParser {
        abi_version: 0,
        flags,
        enter_block: Some(enter_block),
        leave_block: Some(leave_block),
        enter_span: Some(enter_span),
        leave_span: Some(leave_span),
        text: Some(on_text),
        debug_log: None,
        syntax: None,
    };

    let mut builder = Builder::new();
    // SAFETY: `text` is a `&str`, so `size` bytes from its pointer are
    // readable; `parser` outlives the call; the userdata pointer is the only
    // live reference to `builder` for the duration of the call, and every
    // callback reconstructs it as `&mut` exactly once and drops it before
    // returning.
    let code = unsafe {
        md_parse(
            text.as_ptr().cast::<MdChar>(),
            size,
            &raw const parser,
            (&raw mut builder).cast::<c_void>(),
        )
    };

    // The builder's own error is more specific than md4c's "a callback said
    // stop", so it is reported first.
    if let Some(error) = builder.error {
        return Err(error);
    }
    if code != 0 {
        return Err(Error::Md4c { code });
    }
    builder
        .document
        .map(|blocks| Document { blocks })
        .ok_or(Error::Malformed(
            "md_parse succeeded without closing the document",
        ))
}

/// What a frame is collecting, which decides where implicit paragraphs go.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tag {
    /// A block other than a list item.
    Block,
    /// A span.
    Text,
    Li,
    /// A paragraph this builder opened, not md4c.
    ImplicitP,
}

/// The detail md4c gave at `enter_block`, for the block types whose
/// `leave_block` detail cannot be trusted.
#[derive(Clone, Copy)]
enum Detail {
    None,
    Ul(MdBlockUlDetail),
    Ol(MdBlockOlDetail),
    H(MdBlockHDetail),
}

/// The Lean wrapper pushes every child of an open node into the same untyped
/// `Array`; this enum is what replaces its `assert`s.
enum Node {
    Block(Block),
    Text(Text),
    /// Verbatim content: `MD_TEXT_CODE` / `MD_TEXT_HTML` / `MD_TEXT_LATEXMATH`.
    Str(String),
    Li(Li),
    Cell(Vec<Text>),
    Row(Vec<Vec<Text>>),
    Body(Vec<Vec<Vec<Text>>>),
}

struct Frame {
    items: Vec<Node>,
    detail: Detail,
    tag: Tag,
}

struct Builder {
    /// Always non-empty: index 0 is the root, whose tag is `Block` so that the
    /// implicit-paragraph test at the top of `enter_block` has something
    /// defined to read. `wrapper.c` leaves `tags[0]` uninitialised instead.
    stack: Vec<Frame>,
    document: Option<Vec<Block>>,
    error: Option<Error>,
}

impl Builder {
    fn new() -> Self {
        Self {
            stack: vec![Frame {
                items: Vec::new(),
                detail: Detail::None,
                tag: Tag::Block,
            }],
            document: None,
            error: None,
        }
    }

    fn top_tag(&self) -> Tag {
        self.stack.last().map_or(Tag::Block, |frame| frame.tag)
    }

    fn push_frame(&mut self, detail: Detail, tag: Tag) {
        self.stack.push(Frame {
            items: Vec::new(),
            detail,
            tag,
        });
    }

    fn pop_frame(&mut self) -> Result<(Vec<Node>, Detail)> {
        if self.stack.len() < 2 {
            return Err(Error::Malformed("left more nodes than were entered"));
        }
        let frame = self.stack.pop().expect("checked above");
        Ok((frame.items, frame.detail))
    }

    fn save(&mut self, node: Node) -> Result<()> {
        self.stack
            .last_mut()
            .ok_or(Error::Malformed("no open node to attach to"))?
            .items
            .push(node);
        Ok(())
    }

    fn close_implicit_p(&mut self) -> Result<()> {
        // Checked before the pop, not after: asking afterwards means the
        // builder has already been changed by the time the answer is no.
        if self.stack.len() < 2 || self.stack[self.stack.len() - 2].tag != Tag::Li {
            return Err(Error::Malformed(
                "an implicit paragraph was not directly inside a list item",
            ));
        }
        let (items, _) = self.pop_frame()?;
        self.save(Node::Block(Block::P(into_texts(items)?)))
    }

    fn open_implicit_p_if_in_li(&mut self) {
        if self.top_tag() == Tag::Li {
            self.push_frame(Detail::None, Tag::ImplicitP);
        }
    }
}

fn into_texts(items: Vec<Node>) -> Result<Vec<Text>> {
    items
        .into_iter()
        .map(|node| match node {
            Node::Text(text) => Ok(text),
            // Only `MD_TEXT_HTML` reaches here, and only with
            // `MD_FLAG_NOHTMLSPANS` off. MD4Lean itself dies on this input.
            Node::Str(_) => Err(Error::Unrepresentable(
                "inline raw HTML (parse with MD_FLAG_NOHTMLSPANS, as doc-gen4 does)",
            )),
            _ => Err(Error::Malformed(
                "a non-text node turned up where inline text was expected",
            )),
        })
        .collect()
}

fn into_blocks(items: Vec<Node>) -> Result<Vec<Block>> {
    items
        .into_iter()
        .map(|node| match node {
            Node::Block(block) => Ok(block),
            _ => Err(Error::Malformed(
                "a non-block node turned up where a block was expected",
            )),
        })
        .collect()
}

/// A NUL inside verbatim content becomes U+FFFD rather than the type confusion
/// MD4Lean produces.
fn into_strings(items: Vec<Node>) -> Result<Vec<String>> {
    items
        .into_iter()
        .map(|node| match node {
            Node::Str(text) => Ok(text),
            Node::Text(Text::NullChar) => Ok("\u{FFFD}".to_owned()),
            _ => Err(Error::Malformed(
                "a non-verbatim node turned up inside verbatim content",
            )),
        })
        .collect()
}

fn into_lis(items: Vec<Node>) -> Result<Vec<Li>> {
    items
        .into_iter()
        .map(|node| match node {
            Node::Li(li) => Ok(li),
            _ => Err(Error::Malformed(
                "a list held something that is not an item",
            )),
        })
        .collect()
}

fn into_cells(items: Vec<Node>) -> Result<Vec<Vec<Text>>> {
    items
        .into_iter()
        .map(|node| match node {
            Node::Cell(cell) => Ok(cell),
            _ => Err(Error::Malformed(
                "a table row held something that is not a cell",
            )),
        })
        .collect()
}

fn into_rows(items: Vec<Node>) -> Result<Vec<Vec<Vec<Text>>>> {
    items
        .into_iter()
        .map(|node| match node {
            Node::Row(row) => Ok(row),
            _ => Err(Error::Malformed(
                "a table section held something that is not a row",
            )),
        })
        .collect()
}

/// # Safety
///
/// `text` must point at `size` initialised bytes.
unsafe fn read_str(text: *const MdChar, size: MdSize) -> Result<String> {
    if size == 0 {
        return Ok(String::new());
    }
    if text.is_null() {
        return Err(Error::Malformed("a non-empty fragment had a null pointer"));
    }
    // SAFETY: the caller guarantees `size` readable bytes at `text`; `MD_CHAR`
    // is `char`, so the reinterpretation to `u8` is a sign change only.
    let bytes = unsafe { slice::from_raw_parts(text.cast::<u8>(), size as usize) };
    std::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| Error::NotUtf8)
}

/// # Safety
///
/// `attr` must be a live `MD_ATTRIBUTE` as md4c fills it.
unsafe fn read_attr(attr: &MdAttribute) -> Result<Vec<AttrText>> {
    let mut out = Vec::new();
    if attr.size == 0 {
        return Ok(out);
    }
    if attr.substr_types.is_null() || attr.substr_offsets.is_null() {
        return Err(Error::Malformed("an attribute had null substring arrays"));
    }

    let mut i = 0usize;
    loop {
        // SAFETY: md4c's invariant is that the offsets array is terminated by
        // one entry equal to `size`, so the read below stays inside it and the
        // loop stops at that entry.
        let start = unsafe { *attr.substr_offsets.add(i) };
        if start >= attr.size {
            break;
        }
        // SAFETY: as above; `i + 1` is at most the terminating entry.
        let end = unsafe { *attr.substr_offsets.add(i + 1) };
        if end < start || end > attr.size {
            return Err(Error::Malformed("an attribute's substring ran backwards"));
        }
        // SAFETY: one type per substring, and this substring exists.
        let raw = unsafe { *attr.substr_types.add(i) };
        // SAFETY: `start .. end` is inside the attribute's `size` bytes.
        let text = unsafe { read_str(attr.text.add(start as usize), end - start)? };
        out.push(match MdTextType::from_raw(raw) {
            Some(MdTextType::Normal) => AttrText::Normal(text),
            Some(MdTextType::Entity) => AttrText::Entity(text),
            Some(MdTextType::NullChar) => AttrText::NullChar,
            // The header promises only those three inside an attribute.
            _ => {
                return Err(Error::Malformed(
                    "an attribute held an unexpected text type",
                ));
            }
        });
        i += 1;
    }
    Ok(out)
}

/// # Safety
///
/// `detail` must point at a live `T` for the duration of the callback.
unsafe fn detail_of<T: Copy>(detail: *mut c_void) -> Result<T> {
    if detail.is_null() {
        return Err(Error::Malformed("a block that carries a detail got none"));
    }
    // SAFETY: the caller matched `T` to the block or span type md4c reported,
    // and the pointer is valid until the callback returns.
    Ok(unsafe { *detail.cast::<T>() })
}

/// md4c's marks and delimiters are ASCII by construction (`-`, `+`, `*`, `.`,
/// `)`, `` ` ``, `~`, `x`, `X`, space). `MD_CHAR` is signed, so this is where
/// that assumption is written down rather than hidden in a cast.
#[expect(
    clippy::cast_sign_loss,
    reason = "md4c's marks are the ASCII set listed above, so the sign is never set"
)]
fn mark_char(mark: MdChar) -> char {
    char::from(mark as u8)
}

/// Latches the first error and tells md4c to stop.
///
/// # Safety
///
/// `userdata` must be the `Builder` pointer handed to `md_parse`.
unsafe fn with_builder(
    userdata: *mut c_void,
    body: impl FnOnce(&mut Builder) -> Result<()>,
) -> c_int {
    if userdata.is_null() {
        return 1;
    }
    // SAFETY: `md_parse` propagates the userdata pointer unchanged, callbacks
    // are not re-entered, and the `&mut` is dropped before this returns.
    let builder = unsafe { &mut *userdata.cast::<Builder>() };
    if builder.error.is_some() {
        return 1;
    }
    match body(builder) {
        Ok(()) => 0,
        Err(error) => {
            builder.error = Some(error);
            1
        }
    }
}

unsafe extern "C" fn enter_block(ty: c_int, detail: *mut c_void, userdata: *mut c_void) -> c_int {
    // SAFETY: `userdata` is the pointer given to `md_parse`.
    unsafe {
        with_builder(userdata, |builder| {
            let ty = MdBlockType::from_raw(ty)
                .ok_or(Error::Malformed("md4c reported an unknown block type"))?;

            // A block that is a sibling of text under a list item closes the
            // paragraph that text opened.
            if builder.top_tag() == Tag::ImplicitP {
                builder.close_implicit_p()?;
            }

            let saved = match ty {
                MdBlockType::Ul => Detail::Ul(detail_of::<MdBlockUlDetail>(detail)?),
                MdBlockType::Ol => Detail::Ol(detail_of::<MdBlockOlDetail>(detail)?),
                MdBlockType::H => Detail::H(detail_of::<MdBlockHDetail>(detail)?),
                _ => Detail::None,
            };
            builder.push_frame(
                saved,
                if ty == MdBlockType::Li {
                    Tag::Li
                } else {
                    Tag::Block
                },
            );
            Ok(())
        })
    }
}

unsafe extern "C" fn leave_block(ty: c_int, detail: *mut c_void, userdata: *mut c_void) -> c_int {
    // SAFETY: `userdata` is the pointer given to `md_parse`.
    unsafe {
        with_builder(userdata, |builder| {
            let ty = MdBlockType::from_raw(ty)
                .ok_or(Error::Malformed("md4c reported an unknown block type"))?;
            match ty {
                MdBlockType::Doc => {
                    let (items, _) = builder.pop_frame()?;
                    builder.document = Some(into_blocks(items)?);
                }
                MdBlockType::Ul => {
                    let (items, saved) = builder.pop_frame()?;
                    let Detail::Ul(ul) = saved else {
                        return Err(Error::Malformed("a list closed without its enter detail"));
                    };
                    builder.save(Node::Block(Block::Ul {
                        tight: ul.is_tight != 0,
                        mark: mark_char(ul.mark),
                        items: into_lis(items)?,
                    }))?;
                }
                MdBlockType::Ol => {
                    let (items, saved) = builder.pop_frame()?;
                    let Detail::Ol(ol) = saved else {
                        return Err(Error::Malformed("a list closed without its enter detail"));
                    };
                    builder.save(Node::Block(Block::Ol {
                        tight: ol.is_tight != 0,
                        start: ol.start,
                        mark: mark_char(ol.mark_delimiter),
                        items: into_lis(items)?,
                    }))?;
                }
                MdBlockType::Li => {
                    // Unlike UL / OL / H, the item's own detail is the one
                    // handed to `leave_block`.
                    let li = detail_of::<MdBlockLiDetail>(detail)?;
                    if builder.top_tag() != Tag::Li {
                        builder.close_implicit_p()?;
                    }
                    let (items, _) = builder.pop_frame()?;
                    let is_task = li.is_task != 0;
                    builder.save(Node::Li(Li {
                        is_task,
                        task_char: is_task.then(|| mark_char(li.task_mark)),
                        task_mark_offset: is_task.then_some(li.task_mark_offset),
                        contents: into_blocks(items)?,
                    }))?;
                }
                MdBlockType::Hr => {
                    let (items, _) = builder.pop_frame()?;
                    if !items.is_empty() {
                        return Err(Error::Malformed("a thematic break had children"));
                    }
                    builder.save(Node::Block(Block::Hr))?;
                }
                MdBlockType::H => {
                    let (items, saved) = builder.pop_frame()?;
                    let Detail::H(h) = saved else {
                        return Err(Error::Malformed(
                            "a heading closed without its enter detail",
                        ));
                    };
                    builder.save(Node::Block(Block::Header {
                        level: h.level,
                        texts: into_texts(items)?,
                    }))?;
                }
                MdBlockType::Code => {
                    let code = detail_of::<MdBlockCodeDetail>(detail)?;
                    let info = read_attr(&code.info)?;
                    let lang = read_attr(&code.lang)?;
                    let (items, _) = builder.pop_frame()?;
                    builder.save(Node::Block(Block::Code {
                        info,
                        lang,
                        fence_char: (code.fence_char != 0).then(|| mark_char(code.fence_char)),
                        content: into_strings(items)?,
                    }))?;
                }
                MdBlockType::Html => {
                    let (items, _) = builder.pop_frame()?;
                    builder.save(Node::Block(Block::Html(into_strings(items)?)))?;
                }
                MdBlockType::P => {
                    let (items, _) = builder.pop_frame()?;
                    builder.save(Node::Block(Block::P(into_texts(items)?)))?;
                }
                MdBlockType::Quote => {
                    let (items, _) = builder.pop_frame()?;
                    builder.save(Node::Block(Block::BlockQuote(into_blocks(items)?)))?;
                }
                MdBlockType::Table => {
                    let (items, _) = builder.pop_frame()?;
                    let mut head = Vec::new();
                    let mut body = Vec::new();
                    for item in items {
                        match item {
                            Node::Row(row) => head = row,
                            Node::Body(rows) => body = rows,
                            _ => {
                                return Err(Error::Malformed(
                                    "a table held something that is not a header row or a body",
                                ));
                            }
                        }
                    }
                    builder.save(Node::Block(Block::Table { head, body }))?;
                }
                MdBlockType::Thead => {
                    // md4c documents exactly one header row, so the extra
                    // level of nesting is dropped here.
                    let (items, _) = builder.pop_frame()?;
                    let mut rows = into_rows(items)?;
                    if rows.len() != 1 {
                        return Err(Error::Malformed("a table header was not one row"));
                    }
                    let row = rows.remove(0);
                    builder.save(Node::Row(row))?;
                }
                MdBlockType::Tbody => {
                    let (items, _) = builder.pop_frame()?;
                    builder.save(Node::Body(into_rows(items)?))?;
                }
                MdBlockType::Tr => {
                    let (items, _) = builder.pop_frame()?;
                    builder.save(Node::Row(into_cells(items)?))?;
                }
                MdBlockType::Th | MdBlockType::Td => {
                    let (items, _) = builder.pop_frame()?;
                    builder.save(Node::Cell(into_texts(items)?))?;
                }
            }
            Ok(())
        })
    }
}

unsafe extern "C" fn enter_span(ty: c_int, _detail: *mut c_void, userdata: *mut c_void) -> c_int {
    // SAFETY: `userdata` is the pointer given to `md_parse`.
    unsafe {
        with_builder(userdata, |builder| {
            MdSpanType::from_raw(ty)
                .ok_or(Error::Malformed("md4c reported an unknown span type"))?;
            // The detail md4c passes here is not the one to keep; every span
            // that carries one reads it at `leave_span`.
            builder.open_implicit_p_if_in_li();
            builder.push_frame(Detail::None, Tag::Text);
            Ok(())
        })
    }
}

unsafe extern "C" fn leave_span(ty: c_int, detail: *mut c_void, userdata: *mut c_void) -> c_int {
    // SAFETY: `userdata` is the pointer given to `md_parse`.
    unsafe {
        with_builder(userdata, |builder| {
            let ty = MdSpanType::from_raw(ty)
                .ok_or(Error::Malformed("md4c reported an unknown span type"))?;
            match ty {
                MdSpanType::Em | MdSpanType::Strong | MdSpanType::U | MdSpanType::Del => {
                    let (items, _) = builder.pop_frame()?;
                    let texts = into_texts(items)?;
                    builder.save(Node::Text(match ty {
                        MdSpanType::Em => Text::Em(texts),
                        MdSpanType::Strong => Text::Strong(texts),
                        MdSpanType::U => Text::U(texts),
                        _ => Text::Del(texts),
                    }))?;
                }
                MdSpanType::Code | MdSpanType::LatexMath | MdSpanType::LatexMathDisplay => {
                    let (items, _) = builder.pop_frame()?;
                    let parts = into_strings(items)?;
                    builder.save(Node::Text(match ty {
                        MdSpanType::Code => Text::Code(parts),
                        MdSpanType::LatexMath => Text::LatexMath(parts),
                        _ => Text::LatexMathDisplay(parts),
                    }))?;
                }
                MdSpanType::A => {
                    let a = detail_of::<MdSpanADetail>(detail)?;
                    let href = read_attr(&a.href)?;
                    let title = read_attr(&a.title)?;
                    let (items, _) = builder.pop_frame()?;
                    builder.save(Node::Text(Text::A {
                        href,
                        title,
                        is_auto: a.is_autolink != 0,
                        children: into_texts(items)?,
                    }))?;
                }
                MdSpanType::Img => {
                    let img = detail_of::<MdSpanImgDetail>(detail)?;
                    let src = read_attr(&img.src)?;
                    let title = read_attr(&img.title)?;
                    let (items, _) = builder.pop_frame()?;
                    builder.save(Node::Text(Text::Img {
                        src,
                        title,
                        alt: into_texts(items)?,
                    }))?;
                }
                MdSpanType::Wikilink => {
                    let link = detail_of::<MdSpanWikilinkDetail>(detail)?;
                    let target = read_attr(&link.target)?;
                    let (items, _) = builder.pop_frame()?;
                    builder.save(Node::Text(Text::WikiLink {
                        target,
                        children: into_texts(items)?,
                    }))?;
                }
            }
            Ok(())
        })
    }
}

unsafe extern "C" fn on_text(
    ty: c_int,
    text: *const MdChar,
    size: MdSize,
    userdata: *mut c_void,
) -> c_int {
    // SAFETY: `userdata` is the pointer given to `md_parse`, and md4c passes
    // `size` readable bytes at `text`.
    unsafe {
        with_builder(userdata, |builder| {
            let ty = MdTextType::from_raw(ty)
                .ok_or(Error::Malformed("md4c reported an unknown text type"))?;
            builder.open_implicit_p_if_in_li();
            let node = match ty {
                MdTextType::Normal => Node::Text(Text::Normal(read_str(text, size)?)),
                // The payload of a null character is a single NUL byte, which
                // carries nothing; MD4Lean drops it too.
                MdTextType::NullChar => Node::Text(Text::NullChar),
                MdTextType::Br => Node::Text(Text::Br(read_str(text, size)?)),
                MdTextType::SoftBr => Node::Text(Text::SoftBr(read_str(text, size)?)),
                MdTextType::Entity => Node::Text(Text::Entity(read_str(text, size)?)),
                // These three are uniquely determined by the block or span
                // they sit in, so no constructor is spent on them.
                MdTextType::Code | MdTextType::Html | MdTextType::LatexMath => {
                    Node::Str(read_str(text, size)?)
                }
            };
            builder.save(node)
        })
    }
}
