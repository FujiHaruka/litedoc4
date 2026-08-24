//! Derived from doc-gen4 (Copyright (c) 2021 Henrik Böving, Apache-2.0) and
//! changed; see this repository's NOTICE and `docs/provenance.md`.
//!
//! `DocGen4/Output/DocString.lean`, transcribed.
//!
//! doc-gen4 builds an `Html` tree and then serialises it; every element the
//! docstring path creates is built with `flatten = true`, whose serialisation
//! is `<tag attrs>children</tag>` with no whitespace of its own. Nothing here
//! depends on the tree existing, so this writes the same bytes straight into a
//! `String`. The two node kinds that are *not* elements still matter and are
//! marked at each use: `Html.text` is escaped, `Html.raw` is not.
//!
//! `nameToLink?` is a caller-supplied [`LinkResolver`]: answering it needs the
//! union of the IR's module names, the ledger's `known` and the `@` sections of
//! the `.lidx` file, none of which belongs to a markdown crate. Everything
//! downstream of it is here and runs even under [`NoLinks`], with the anchors
//! simply absent.
//!
//! `docStringToHtml` also appends a reference-link definition for every citekey
//! the docstring mentions. The target package has no `.bib` file, so `refsMap`
//! is empty and the appended text is exactly the `"\n\n"`
//! [`Renderer::docstring`] appends; anything else would be a feature there is
//! no oracle for.

use std::cell::Cell;

use crate::ast::{AttrText, Block, Document, Li, Text};
use crate::escape::escape_html_into;
use crate::gc::{is_p_z_c, is_z_c};
use crate::math::to_mathml;
use crate::parse::parse;

/// Implementations receive the string exactly as the docstring wrote it (minus
/// the `.lean` of a source path) and return a URL ready to be escaped into an
/// `href`.
pub trait LinkResolver {
    fn name_to_link(&self, name: &str) -> Option<String>;

    /// The branch a word like `Foo/Bar.lean` takes. `path` is that word without
    /// its `.lean` and always contains a `/`; `root` is the renderer's site
    /// root, passed in so that a resolver holding no root of its own can still
    /// answer.
    ///
    /// The default is doc-gen4's own answer: the path is read as relative to
    /// the **repository root**, so the page is the same path with the extension
    /// swapped. That is right for a docstring that writes
    /// `Mathlib/Order/Basic.lean` and wrong for one that writes a path relative
    /// to its own module, which resolves to a page nobody wrote — 160 dangling
    /// links on the measurement target 【実測 2026-08-16,
    /// `benchmarks/results/m8-ui2-dead-links.txt`】.
    ///
    /// **A resolver that holds a module index should override this** and answer
    /// `None` rather than guess: a link to the wrong page is worse than no link
    /// (`litedoc4_render::PageLinks`).
    fn source_path_to_link(&self, root: &str, path: &str) -> Option<String> {
        Some(format!("{root}{path}.html"))
    }
}

/// A resolver that resolves no *name*: every `` `Nat.succ` `` stays plain text
/// rather than becoming a dangling link. A source path still resolves, because
/// [`LinkResolver::source_path_to_link`]'s default needs no index — this is the
/// configuration that reproduces doc-gen4 with an empty `AnalyzerResult`, which
/// is what `tests/docgen4.rs` compares against.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoLinks;

impl LinkResolver for NoLinks {
    fn name_to_link(&self, _name: &str) -> Option<String> {
        None
    }
}

/// `root` is the relative path back to the site root from the page being
/// written (`getRoot`: `"./"`, `"../"`, `"../.././"`, …). It is prepended to
/// every relative link, so it is part of the bytes.
pub struct Renderer<'a> {
    root: &'a str,
    links: &'a dyn LinkResolver,
    /// A `Cell` because every rendering method takes `&self` — the alternative
    /// was threading a counter through nine of them. It makes `Renderer` not
    /// `Sync`, which costs nothing: one is built per page and never shared.
    math_failures: Cell<usize>,
}

impl<'a> Renderer<'a> {
    #[must_use]
    pub const fn new(root: &'a str, links: &'a dyn LinkResolver) -> Self {
        Self {
            root,
            links,
            math_failures: Cell::new(0),
        }
    }

    /// The math fallback is silent in the page, so this counter is the only
    /// place a build can learn that a docstring's mathematics did not come out
    /// as mathematics.
    #[must_use]
    pub fn math_failures(&self) -> usize {
        self.math_failures.get()
    }

    /// `docStringToHtml`. The trailing `"\n\n"` is doc-gen4's `refsMarkdown`
    /// with an empty bibliography, and it is not cosmetic — it terminates
    /// whatever block the docstring ended in the middle of.
    ///
    /// When the parser refuses the input, doc-gen4 records an error and emits a
    /// red message followed by the source; that is reproduced rather than
    /// panicking, though md4c has never refused one of the target package's
    /// 4,947 docstrings 【実測】.
    #[must_use]
    pub fn docstring(&self, md: &str) -> String {
        let mut source = String::with_capacity(md.len() + 2);
        source.push_str(md);
        source.push_str("\n\n");
        match parse(&source) {
            Ok(doc) => self.document(&doc),
            Err(_) => {
                let mut out =
                    "<span style='color:red;'>Error: failed to parse markdown: </span>".to_owned();
                // `Html.text docString`: the *original* string, not the one the
                // newlines were appended to.
                escape_html_into(&mut out, md);
                out
            }
        }
    }

    /// No trimming: `Html.toString` trims the whole page once, at the top, and
    /// a docstring is never the whole page.
    #[must_use]
    pub fn document(&self, doc: &Document) -> String {
        let mut out = String::new();
        self.blocks_into(&mut out, &doc.blocks, false);
        out
    }

    fn blocks_into(&self, out: &mut String, blocks: &[Block], tight: bool) {
        for block in blocks {
            self.block_into(out, block, tight);
        }
    }

    /// `renderBlock`. `tight` reaches only `.p`.
    fn block_into(&self, out: &mut String, block: &Block, tight: bool) {
        match block {
            Block::P(texts) => {
                if tight {
                    self.texts_into(out, texts, false);
                } else {
                    out.push_str("<p>");
                    self.texts_into(out, texts, false);
                    out.push_str("</p>");
                }
            }
            Block::Ul { tight, items, .. } => {
                out.push_str("<ul>");
                for item in items {
                    self.li_into(out, item, *tight);
                }
                out.push_str("</ul>");
            }
            Block::Ol {
                tight,
                start,
                items,
                ..
            } => {
                if *start == 1 {
                    out.push_str("<ol>");
                } else {
                    out.push_str("<ol start=\"");
                    // A decimal `Nat`; nothing in it can need escaping.
                    out.push_str(&start.to_string());
                    out.push_str("\">");
                }
                for item in items {
                    self.li_into(out, item, *tight);
                }
                out.push_str("</ol>");
            }
            // `Html.raw`, and the newline is part of it.
            Block::Hr => out.push_str("<hr>\n"),
            Block::Header { level, texts } => {
                let id = heading_id(texts);
                out.push_str("<h");
                out.push_str(&level.to_string());
                out.push_str(" id=\"");
                escape_html_into(out, &id);
                out.push_str("\" class=\"markdown-heading\">");
                self.texts_into(out, texts, false);
                // `Html.text " "` — one space, then the hover anchor.
                out.push_str(" <a class=\"hover-link\" href=\"#");
                escape_html_into(out, &id);
                out.push_str("\">#</a></h");
                out.push_str(&level.to_string());
                out.push('>');
            }
            Block::Code { lang, content, .. } => {
                let lang_str = attr_text_to_string(lang);
                out.push_str("<pre><code");
                if !lang_str.is_empty() {
                    out.push_str(" class=\"language-");
                    escape_html_into(out, &lang_str);
                    out.push('"');
                }
                out.push('>');
                if lang_str.is_empty() || lang_str == "lean" {
                    self.auto_link_inline(out, content);
                } else {
                    escape_html_into(out, &content.concat());
                }
                out.push_str("</code></pre>");
            }
            // `Html.raw`. Unreachable under `MD_FLAG_NOHTML`, which is why it
            // is not the place to start trusting input.
            Block::Html(content) => out.push_str(&content.concat()),
            Block::BlockQuote(blocks) => {
                out.push_str("<blockquote>");
                // `tight` is not passed down: a quote inside a tight item still
                // renders its paragraphs.
                self.blocks_into(out, blocks, false);
                out.push_str("</blockquote>");
            }
            Block::Table { head, body } => {
                out.push_str("<table><thead><tr>");
                for cell in head {
                    out.push_str("<th>");
                    self.texts_into(out, cell, false);
                    out.push_str("</th>");
                }
                out.push_str("</tr></thead><tbody>");
                for row in body {
                    out.push_str("<tr>");
                    for cell in row {
                        out.push_str("<td>");
                        self.texts_into(out, cell, false);
                        out.push_str("</td>");
                    }
                    out.push_str("</tr>");
                }
                out.push_str("</tbody></table>");
            }
        }
    }

    /// `renderLi`.
    fn li_into(&self, out: &mut String, li: &Li, tight: bool) {
        out.push_str("<li>");
        if li.is_task {
            if li.task_char == Some('x') || li.task_char == Some('X') {
                out.push_str("<input type=\"checkbox\" checked=\"\" disabled=\"\">");
            } else {
                out.push_str("<input type=\"checkbox\" disabled=\"\">");
            }
        }
        self.blocks_into(out, &li.contents, tight);
        out.push_str("</li>");
    }

    fn texts_into(&self, out: &mut String, texts: &[Text], in_link: bool) {
        for text in texts {
            self.text_into(out, text, in_link);
        }
    }

    /// `renderText`. `in_link` suppresses auto-linking inside an `<a>`, which is what stops
    /// the output from nesting anchors.
    fn text_into(&self, out: &mut String, text: &Text, in_link: bool) {
        match text {
            Text::Normal(s) => escape_html_into(out, s),
            // `Html.raw "�"` — CommonMark's replacement for a NUL.
            Text::NullChar => out.push('\u{FFFD}'),
            // `Html.raw`, and the newline is part of it. Not `<br></br>`.
            Text::Br(_) => out.push_str("<br>\n"),
            Text::SoftBr(_) => out.push('\n'),
            // `Html.raw s`: entities are passed through with their `&` and `;`,
            // unvalidated and unexpanded. This is why no entity table is
            // vendored.
            Text::Entity(s) => out.push_str(s),
            Text::Em(ts) => self.wrap_into(out, "em", ts, in_link),
            Text::Strong(ts) => self.wrap_into(out, "strong", ts, in_link),
            Text::U(ts) => self.wrap_into(out, "u", ts, in_link),
            Text::Del(ts) => self.wrap_into(out, "del", ts, in_link),
            Text::A {
                href,
                title,
                children,
                ..
            } => {
                // `isAuto` is ignored: a permissive autolink renders exactly
                // like the link someone wrote out.
                let title_str = attr_text_to_string(title);
                out.push_str("<a href=\"");
                escape_html_into(out, &self.extend_link(&attr_text_to_string(href)));
                out.push('"');
                if !title_str.is_empty() {
                    out.push_str(" title=\"");
                    escape_html_into(out, &title_str);
                    out.push('"');
                }
                out.push('>');
                self.texts_into(out, children, true);
                out.push_str("</a>");
            }
            Text::Img { src, title, alt } => {
                // Built as a raw string, so the attribute order is fixed: src,
                // alt, then title if any.
                let title_str = attr_text_to_string(title);
                out.push_str("<img src=\"");
                escape_html_into(out, &attr_text_to_string(src));
                out.push_str("\" alt=\"");
                let mut alt_text = String::new();
                for t in alt {
                    text_to_plaintext(&mut alt_text, t);
                }
                escape_html_into(out, &alt_text);
                out.push('"');
                if !title_str.is_empty() {
                    out.push_str(" title=\"");
                    escape_html_into(out, &title_str);
                    out.push('"');
                }
                out.push('>');
            }
            Text::Code(parts) => {
                out.push_str("<code>");
                if in_link {
                    escape_html_into(out, &parts.concat());
                } else {
                    self.auto_link_inline(out, parts);
                }
                out.push_str("</code>");
            }
            Text::LatexMath(parts) => self.math_into(out, &parts.concat(), false),
            Text::LatexMathDisplay(parts) => self.math_into(out, &parts.concat(), true),
            Text::WikiLink { target, children } => {
                out.push_str("<x-wikilink data-target=\"");
                escape_html_into(out, &attr_text_to_string(target));
                out.push_str("\">");
                self.texts_into(out, children, in_link);
                out.push_str("</x-wikilink>");
            }
        }
    }

    /// The MathML, or — when the LaTeX does not parse — the dollars and the
    /// source, which is what doc-gen4 emits for every span, so such a page is no
    /// worse than a doc-gen4 page. What is lost is silence, which is why
    /// [`Renderer::math_failures`] counts.
    fn math_into(&self, out: &mut String, latex: &str, display: bool) {
        if let Some(mathml) = to_mathml(latex, display) {
            // `Html.raw`: the MathML is markup, and escaping it would print it.
            out.push_str(&mathml);
            return;
        }
        self.math_failures.set(self.math_failures.get() + 1);
        let delimiter = if display { "$$" } else { "$" };
        out.push_str(delimiter);
        escape_html_into(out, latex);
        out.push_str(delimiter);
    }

    fn wrap_into(&self, out: &mut String, tag: &str, texts: &[Text], in_link: bool) {
        out.push('<');
        out.push_str(tag);
        out.push('>');
        self.texts_into(out, texts, in_link);
        out.push_str("</");
        out.push_str(tag);
        out.push('>');
    }

    /// A word that ends in `.lean` and contains a `/` is a path to a source
    /// file — not a rare corner, it is how the target package's module docs
    /// cross-reference each other and accounts for 131 of its 4,987 docstrings
    /// 【実測】. Which page that path names is a question about the packages
    /// being documented, so it goes to the resolver like every other lookup.
    #[must_use]
    pub fn resolve_link(&self, s: &str) -> Option<String> {
        if let Some(path) = s.strip_suffix(".lean")
            && s.contains('/')
        {
            return self.links.source_path_to_link(self.root, path);
        }
        self.links.name_to_link(s)
    }

    /// `extendLink`. The `http` test is `startsWith "http"`, not a scheme check
    /// — `httpfoo:` is left alone too, and that is doc-gen4's behaviour, not a
    /// simplification.
    fn extend_link(&self, s: &str) -> String {
        if let Some(name) = s.strip_prefix("##") {
            return self
                .resolve_link(name)
                .unwrap_or_else(|| format!("{}find/?pattern={name}#doc", self.root));
        }
        if s.starts_with('#') || s.starts_with("http") {
            return s.to_owned();
        }
        format!("{}{s}", self.root)
    }

    /// `autoLinkInline`: every whitespace-separated word of a code span or Lean
    /// code block that names something documented becomes a link to it.
    ///
    /// Two lookups per word: the word itself, then — if that fails — whatever
    /// follows its last `.`, so that `Nat.succ` links `succ` when the qualified
    /// name is unknown. When neither resolves, the words written back out
    /// reassemble the original string exactly, because `splitAround` keeps the
    /// separators it splits on.
    fn auto_link_inline(&self, out: &mut String, parts: &[String]) {
        for part in parts {
            for piece in split_around(part, is_z_c) {
                if let Some(link) = self.resolve_link(piece) {
                    push_anchor(out, &link, piece);
                    continue;
                }
                // With no dot at all the head is empty and the tail is the
                // whole piece, so the second lookup repeats the first — as it
                // does in Lean.
                let (head, tail) = match piece.rfind('.') {
                    Some(at) => piece.split_at(at + 1),
                    None => ("", piece),
                };
                if let Some(link) = self.resolve_link(tail) {
                    if !head.is_empty() {
                        escape_html_into(out, head);
                    }
                    push_anchor(out, &link, tail);
                } else {
                    escape_html_into(out, piece);
                }
            }
        }
    }
}

fn push_anchor(out: &mut String, href: &str, text: &str) {
    out.push_str("<a href=\"");
    escape_html_into(out, href);
    out.push_str("\">");
    escape_html_into(out, text);
    out.push_str("</a>");
}

/// `attrTextToString`: a link destination, title or info string flattened.
/// Entities stay as written.
#[must_use]
pub fn attr_text_to_string(attrs: &[AttrText]) -> String {
    let mut out = String::new();
    for attr in attrs {
        match attr {
            AttrText::Normal(s) | AttrText::Entity(s) => out.push_str(s),
            AttrText::NullChar => out.push('\u{FFFD}'),
        }
    }
    out
}

/// `textToPlaintext`: an inline run with all formatting dropped. Feeds image
/// alt text and heading ids.
fn text_to_plaintext(out: &mut String, text: &Text) {
    match text {
        Text::Normal(s) | Text::Entity(s) => out.push_str(s),
        Text::NullChar => out.push('\u{FFFD}'),
        // A newline is what the heading id treats as a separator, like any
        // other `C` character.
        Text::Br(_) | Text::SoftBr(_) => out.push('\n'),
        Text::Em(ts)
        | Text::Strong(ts)
        | Text::U(ts)
        | Text::Del(ts)
        | Text::A { children: ts, .. }
        | Text::WikiLink { children: ts, .. } => {
            for t in ts {
                text_to_plaintext(out, t);
            }
        }
        Text::Img { alt, .. } => {
            for t in alt {
                text_to_plaintext(out, t);
            }
        }
        Text::Code(parts) | Text::LatexMath(parts) | Text::LatexMathDisplay(parts) => {
            for part in parts {
                out.push_str(part);
            }
        }
    }
}

/// `mdGetHeadingId`: the heading's plain text with every run of `P | Z | C`
/// replaced by one `-`, and no leading or trailing `-` because the empty pieces
/// are dropped first. Cases are preserved, so `## Main results` becomes
/// `Main-results` and not `main-results`.
#[must_use]
pub fn heading_id(texts: &[Text]) -> String {
    let mut plain = String::new();
    for text in texts {
        text_to_plaintext(&mut plain, text);
    }
    let mut out = String::with_capacity(plain.len());
    let mut first = true;
    for piece in plain.split(is_p_z_c) {
        if piece.is_empty() {
            continue;
        }
        if !first {
            out.push('-');
        }
        out.push_str(piece);
        first = false;
    }
    out
}

/// `splitAround`: `String.split` that keeps the separators as elements of their
/// own, so `"a b"` is `["a", " ", "b"]`. Empty pieces are kept — two separators
/// in a row produce an empty string between them — because `autoLinkInline`
/// writes every piece it cannot resolve back out unchanged.
fn split_around(s: &str, p: fn(char) -> bool) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    for (at, c) in s.char_indices() {
        if p(c) {
            out.push(&s[start..at]);
            out.push(&s[at..at + c.len_utf8()]);
            start = at + c.len_utf8();
        }
    }
    out.push(&s[start..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(md: &str) -> String {
        Renderer::new("../", &NoLinks).docstring(md)
    }

    #[test]
    fn math_becomes_mathml_and_a_failure_keeps_the_dollars() {
        let renderer = Renderer::new("../", &NoLinks);
        let good = renderer.docstring("$x^2$ and $$\\sum_i x_i$$");
        assert!(good.contains("<math><msup>"), "{good}");
        assert!(good.contains("<math display=\"block\">"), "{good}");
        assert!(!good.contains('$'), "{good}");
        assert_eq!(renderer.math_failures(), 0);

        // `\colim` is not a command this parser has, so the page keeps what the
        // docstring wrote, escaped.
        let bad = renderer.docstring("$a < \\colim_k F$");
        assert!(bad.contains("$a &lt; \\colim_k F$"), "{bad}");
        assert_eq!(renderer.math_failures(), 1, "the fallback is counted");
    }

    #[test]
    fn split_around_keeps_the_separators() {
        assert_eq!(split_around("a b", is_z_c), vec!["a", " ", "b"]);
        assert_eq!(split_around("  ", is_z_c), vec!["", " ", "", " ", ""]);
        assert_eq!(split_around("Nat.succ", is_z_c), vec!["Nat.succ"]);
        assert_eq!(split_around("", is_z_c), vec![""]);
    }

    #[test]
    fn a_heading_id_drops_runs_of_punctuation() {
        let doc = parse("## Main results: `Foo.bar`!\n").unwrap();
        let Block::Header { texts, .. } = &doc.blocks[0] else {
            panic!("{:?}", doc.blocks)
        };
        assert_eq!(heading_id(texts), "Main-results-Foo-bar");
    }

    #[test]
    fn a_paragraph_is_wrapped_and_escaped() {
        assert_eq!(render("a < b & c\n"), "<p>a &lt; b &amp; c</p>");
    }

    #[test]
    fn a_tight_item_has_no_paragraph_and_a_loose_one_does() {
        assert_eq!(render("- a\n- b\n"), "<ul><li>a</li><li>b</li></ul>");
        assert_eq!(
            render("- a\n\n- b\n"),
            "<ul><li><p>a</p></li><li><p>b</p></li></ul>"
        );
    }

    #[test]
    fn entities_are_passed_through_raw() {
        // Not expanded, not escaped, not even validated: md4c reports anything
        // shaped like an entity as one and `Html.raw` writes it out, so
        // `&notanentity;` survives with its `&` intact.
        assert_eq!(
            render("&amp; &notanentity;\n"),
            "<p>&amp; &notanentity;</p>"
        );
        // A bare `&` is *not* entity-shaped, so it goes through the text path
        // and is escaped.
        assert_eq!(render("a & b\n"), "<p>a &amp; b</p>");
    }

    #[test]
    fn a_relative_link_gets_the_root_and_an_absolute_one_does_not() {
        assert_eq!(
            render("[a](b.html) [c](http://x/y) [d](#e)\n"),
            "<p><a href=\"../b.html\">a</a> <a href=\"http://x/y\">c</a> \
             <a href=\"#e\">d</a></p>"
        );
    }

    #[test]
    fn an_unresolved_name_search_falls_back_to_the_find_page() {
        assert_eq!(
            render("[a](##Nat.succ)\n"),
            "<p><a href=\"../find/?pattern=Nat.succ#doc\">a</a></p>"
        );
    }

    #[test]
    fn a_resolver_that_answers_puts_anchors_in_code_spans() {
        struct Yes;
        impl LinkResolver for Yes {
            fn name_to_link(&self, name: &str) -> Option<String> {
                (name == "Nat.succ").then(|| "../Nat.html#Nat.succ".to_owned())
            }
        }
        let got = Renderer::new("../", &Yes).docstring("`Nat.succ x` is fine\n");
        assert_eq!(
            got,
            "<p><code><a href=\"../Nat.html#Nat.succ\">Nat.succ</a> x</code> is fine</p>"
        );
        // …and no anchor inside an anchor.
        let got = Renderer::new("../", &Yes).docstring("[`Nat.succ`](x)\n");
        assert_eq!(got, "<p><a href=\"../x\"><code>Nat.succ</code></a></p>");
    }

    #[test]
    fn a_code_block_keeps_its_language_class_and_a_lean_one_is_linked() {
        assert_eq!(
            render("```python\nx = 1\n```\n"),
            "<pre><code class=\"language-python\">x = 1\n</code></pre>"
        );
        assert_eq!(render("```\nx\n```\n"), "<pre><code>x\n</code></pre>");
    }
}
