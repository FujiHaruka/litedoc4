//! Lean module names: the two spellings, and where each one is right.
//!
//! A module list is built from path components (`Alpha/Odd-Name.lean` →
//! `Alpha.Odd-Name`), and the extractor turns each line back into a `Name` with
//! `String.toName` — a *parser* that accepts a component only if it is an
//! identifier, an escaped `«…»`, or a numeral (`Init/Meta/Defs.lean:1218-1233`).
//! `Odd-Name` is none of the three, so the entry parses as `Name.anonymous` and
//! the extractor exits 1 with `import failed, trying to import module with
//! anonymous name` 【実測 2026-08-15】.
//!
//! So which spelling is canonical is not a choice. **The name** is
//! `Alpha.«Odd-Name»`: the extractor writes it into `index.json` and into
//! `modules/<name>.json`, and `merge --modules` refuses a list that disagrees
//! with the tree. **The path** is `Alpha/Odd-Name`: the olean is at the source's
//! path, and doc-gen4 builds a page path out of
//! `Name.toString (escape := false)` components (`Output/Base.lean:188`). All
//! 432 module names of the measurement target are plain identifiers, so both
//! spellings are the identity there 【実測】.
//!
//! [`is_id_first`] / [`is_id_rest`] / [`is_letter_like`] / [`is_subscript_alnum`]
//! are transcribed from `Init/Meta/Defs.lean:98-137` of the toolchain the
//! targets pin (`leanprover/lean4:v4.31.0`). Lean's `Char.isAlpha` is **ASCII
//! only** — every non-ASCII identifier character comes from the two range
//! tables, which is why they are written out here rather than reached for in a
//! Unicode crate: a crate would bring a different UCD and a divergence with it.

use std::borrow::Cow;

/// `Lean.isLetterLike` — `Init/Meta/Defs.lean:101-112`.
#[must_use]
pub fn is_letter_like(c: char) -> bool {
    let v = c as u32;
    (0x3b1..=0x3c9).contains(&v) && v != 0x3bb          // lower Greek, not lambda
        || (0x391..=0x3a9).contains(&v) && v != 0x3a0 && v != 0x3a3 // upper Greek, not Pi/Sigma
        || (0x3ca..=0x3fb).contains(&v)                 // Coptic
        || (0x1f00..=0x1ffe).contains(&v)               // polytonic Greek
        || (0x2100..=0x214f).contains(&v)               // letterlike symbols
        || (0x1d49c..=0x1d59f).contains(&v)             // script / double-struck / fraktur
        || (0x00c0..=0x00ff).contains(&v) && v != 0x00d7 && v != 0x00f7
        || (0x0100..=0x017f).contains(&v)
}

/// `Lean.isSubScriptAlnum` — `Init/Meta/Defs.lean:114-118`.
#[must_use]
pub fn is_subscript_alnum(c: char) -> bool {
    let v = c as u32;
    (0x2080..=0x2089).contains(&v)
        || (0x2090..=0x209c).contains(&v)
        || (0x1d62..=0x1d6a).contains(&v)
        || v == 0x2c7c
}

/// `Lean.isIdFirst`. `Char.isAlpha` is ASCII in Lean.
#[must_use]
pub fn is_id_first(c: char) -> bool {
    c.is_ascii_alphabetic() || c == '_' || is_letter_like(c)
}

/// `Lean.isIdRest`. `Char.isAlphanum` is ASCII in Lean.
#[must_use]
pub fn is_id_rest(c: char) -> bool {
    c.is_ascii_alphanumeric()
        || c == '_'
        || c == '\''
        || c == '!'
        || c == '?'
        || is_letter_like(c)
        || is_subscript_alnum(c)
}

/// Whether a name component is spelled as itself by `Name.toString`.
#[must_use]
pub fn needs_no_escape(component: &str) -> bool {
    let mut chars = component.chars();
    match chars.next() {
        None => false,
        Some(first) => is_id_first(first) && chars.all(is_id_rest),
    }
}

/// `Name.escapePart` with `force := false` (`Init/Meta/Defs.lean:198-207`).
///
/// A component containing `»` is **not escaped**, because wrapping it would
/// produce something that does not parse back. Transcribed, not improved — the
/// spelling this has to agree with is the extractor's.
#[must_use]
pub fn escape_component(component: &str) -> Cow<'_, str> {
    if needs_no_escape(component) || component.contains('»') {
        Cow::Borrowed(component)
    } else {
        Cow::Owned(format!("«{component}»"))
    }
}

/// A module name built from path components, as `Name.toString` spells it.
pub fn escape_module<'a>(components: impl IntoIterator<Item = &'a str>) -> String {
    components
        .into_iter()
        .map(|component| escape_component(component).into_owned())
        .collect::<Vec<String>>()
        .join(".")
}

/// The components of a module name, **unescaped**.
///
/// The split is on `.` outside `«…»`, because an escaped component may contain
/// one — `«a.b»` is one component and not two.
#[must_use]
pub fn module_components(module: &str) -> Vec<&str> {
    // `char_indices`, not a byte walk: a byte walk slices inside a multi-byte
    // character the moment a name holds one, and both `𝒜` and `ﬀ` are in this
    // project's curated test cases 【実測】.
    let mut out = Vec::new();
    let mut start = 0;
    let mut depth = 0usize;
    for (at, c) in module.char_indices() {
        match c {
            '«' => depth += 1,
            '»' => depth = depth.saturating_sub(1),
            '.' if depth == 0 => {
                out.push(unescape_component(&module[start..at]));
                start = at + 1;
            }
            _ => {}
        }
    }
    out.push(unescape_component(&module[start..]));
    out
}

#[must_use]
pub fn unescape_component(component: &str) -> &str {
    component
        .strip_prefix('«')
        .and_then(|rest| rest.strip_suffix('»'))
        .unwrap_or(component)
}

/// The module's path stem: `Alpha.«Odd-Name»` → `Alpha/Odd-Name`. Every place
/// that turns a module name into a file path goes through this.
#[must_use]
pub fn module_path(module: &str) -> String {
    module_components(module).join("/")
}

/// `Alpha.«Odd-Name»` → `Alpha/Odd-Name.html`, relative to the site root.
///
/// **Three crates need this rule and it has to be one rule**: the renderer
/// writes the page, `prune` deletes it, and the whole-package artifacts link to
/// it. Writer and remover disagreeing leaves the dead page behind; writer and
/// index disagreeing emits `href`s to pages that are not there. **Neither shows
/// up in a byte comparison of either side.** The separator is `/`: this is a URL
/// path as much as a file path.
///
/// **A name can carry a `..` through this**: `«..».Foo` comes out as
/// `../Foo.html` 【実測 2026-08-23】. Refusing it belongs where there is a tree
/// to refuse against, `litedoc4_incr::prune::PageRoot`.
#[must_use]
pub fn page_path(module: &str) -> String {
    let mut path = module_path(module);
    path.push_str(".html");
    path
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_names_are_their_own_spelling() {
        for module in [
            "InformationTheory.Shannon.BroadcastChannel.Basic",
            "Alpha",
            "Mathlib.Data.Nat.Basic",
            "Alpha.AstralNames",
        ] {
            let parts: Vec<&str> = module.split('.').collect();
            assert_eq!(escape_module(parts.clone()), module);
            assert_eq!(module_components(module), parts);
            assert_eq!(module_path(module), module.replace('.', "/"));
        }
    }

    #[test]
    fn a_component_that_is_not_an_identifier_is_escaped() {
        assert_eq!(escape_module(["Alpha", "Odd-Name"]), "Alpha.«Odd-Name»");
        assert_eq!(module_components("Alpha.«Odd-Name»"), ["Alpha", "Odd-Name"]);
        assert_eq!(module_path("Alpha.«Odd-Name»"), "Alpha/Odd-Name");
    }

    #[test]
    fn astral_letter_like_characters_are_identifiers() {
        assert!(is_id_first('𝒜'));
        assert_eq!(escape_component("𝒜"), "𝒜");
        assert_eq!(escape_component("𝒜-z"), "«𝒜-z»");
        assert_eq!(escape_component("ﬀ-z"), "«ﬀ-z»");
        // U+FB00 is not letter-like in Lean's table, so even alone it escapes.
        assert_eq!(escape_component("ﬀ"), "«ﬀ»");
    }

    #[test]
    fn a_component_holding_the_closing_bracket_is_left_alone() {
        assert_eq!(escape_component("a»b"), "a»b");
    }

    #[test]
    fn the_split_does_not_cut_inside_an_escape() {
        assert_eq!(module_components("Alpha.«a.b».C"), ["Alpha", "a.b", "C"]);
        assert_eq!(module_path("Alpha.«a.b».C"), "Alpha/a.b/C");
    }

    #[test]
    fn a_multi_byte_character_does_not_split_a_component() {
        assert_eq!(module_components("Pkg.𝒜.ﬀ"), ["Pkg", "𝒜", "ﬀ"]);
        assert_eq!(module_path("Pkg.«𝒜-z»"), "Pkg/𝒜-z");
    }

    #[test]
    fn a_page_path_is_the_module_path_plus_the_suffix() {
        for module in ["Pkg", "Pkg.A.B", "Alpha.«Odd-Name»", "Alpha.«a.b».C", ""] {
            assert_eq!(page_path(module), format!("{}.html", module_path(module)));
        }
        assert_eq!(page_path("Pkg.A.B"), "Pkg/A/B.html");
        assert_eq!(page_path(""), ".html");
    }

    /// Asserted so that a future escape-time change cannot silently make
    /// `litedoc4_incr::prune::PageRoot`'s reason stale 【実測 2026-08-23】.
    #[test]
    fn an_escaped_component_can_spell_a_parent_directory() {
        assert_eq!(page_path("«..».Foo"), "../Foo.html");
    }

    #[test]
    fn an_empty_component_escapes_rather_than_vanishing() {
        assert_eq!(escape_component(""), "«»");
        assert!(!needs_no_escape(""));
    }
}
