//! Everything the whole-package artifacts need from **one** module.
//!
//! **If a fact the derivation reads is not in [`ModuleFacts`], adding it is a
//! bump of [`crate::STATE_DERIVATION`], not an edit.** A cache that keeps
//! entries built by an older rule is fast and wrong: a state file written before
//! the field existed has no such key, and every module the cache hits then
//! derives its artifacts from a fact that is silently absent.
//!
//! [`ModuleFacts::tokens`] is the one field no artifact carries. It exists for
//! the whole-package map delta ("do this module's docstrings mention a name that
//! moved"), and lives here because the cache boundary is per module.

use std::collections::{BTreeMap, HashSet};

use litedoc4_ir::{Decl, ModuleFile, SpanKind, cmp_utf16};
use serde::{Deserialize, Serialize};

/// The seven keys the frozen prototype's `factsOf` emits, in its order.
///
/// What is asserted against it is that [`ModuleFacts`]'s serialised key list
/// *starts* with this (`tests::the_prototypes_keys_come_first`), never the
/// difference between the two — a stated difference goes silently false the next
/// time this struct grows a field.
pub const PROTOTYPE_FACT_KEYS: [&str; 7] = [
    "module",
    "contentHash",
    "imports",
    "tactics",
    "decls",
    "instances",
    "tokens",
];

/// **The field order below is the state file's bytes**, so **every field this
/// struct has that the prototype does not has to come after all seven of
/// [`PROTOTYPE_FACT_KEYS`]** — that is what lets a state file written here still
/// be compared entry by entry with one the prototype wrote.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModuleFacts {
    pub module: String,
    /// Lean's `String.hash` of the module JSON, carried from `index.json`.
    ///
    /// The cache key. It lives inside the entry rather than beside it so a
    /// cached entry cannot be separated from the hash it was built for.
    pub content_hash: String,
    pub imports: Vec<String>,
    pub tactics: usize,
    /// `(name, kind)` per declaration, in the module's own order.
    pub decls: Vec<(String, String)>,
    /// `(class, instance name)` for each instance whose printed type has a head
    /// constant, in the module's own order.
    pub instances: Vec<(String, String)>,
    /// The names this module's docstrings could autolink: deduplicated and
    /// sorted in **UTF-16 code unit order**.
    pub tokens: Vec<String>,
    /// `(type name, instance name)` for each of an instance's `instTypes`, in
    /// the module's own order — the other direction of the instance index,
    /// "which instances mention this type".
    ///
    /// The rule is doc-gen4's `getInstanceTypes`: the head constant of each
    /// **explicit** argument of the class application. The extractor ports it
    /// verbatim into [`litedoc4_ir::Decl::inst_types`], so nothing is re-derived
    /// here — the IR is read. Measured against doc-gen4's own
    /// `declarations/declaration-data.bmp`: **59 of 59** shared instances agree
    /// exactly (measured 2026-08-16), where taking every constant in the printed
    /// type instead agrees with **0 of 59**.
    pub instances_for: Vec<(String, String)>,
    /// **Which of this module's declarations mention each constant** — the
    /// forward half of "Used by", inverted by [`crate::artifacts::Artifacts`].
    ///
    /// Key: the constant's name, exactly as `litedoc4_ir::Ref` carries it.
    /// Value: **indices into [`ModuleFacts::decls`]**, ascending and
    /// deduplicated. Indices rather than names because names are what makes this
    /// field large: 54,424 edges over 422 modules cost 469 KB as indices and
    /// about four times that as names (measured 2026-08-22), on a state file that
    /// was 838 KB.
    ///
    /// **Not filtered to this package, on purpose.** A reference whose defining
    /// module belongs to a *dependency* is stored too, and dropped when the map
    /// is inverted. Filtering here would be smaller — 182 KB — and **wrong
    /// across a restructure**: whether a module is "ours" is not a property of
    /// the module, so a cached entry built when it was a dependency would keep
    /// answering that after it became part of the package, with an unchanged
    /// `contentHash` and nothing to notice it.
    pub refs: BTreeMap<String, Vec<u32>>,
}

impl ModuleFacts {
    /// `content_hash` comes from the index entry, not from the file.
    #[must_use]
    pub fn of(module: &ModuleFile, content_hash: &str) -> Self {
        let mut decls = Vec::with_capacity(module.declarations.len());
        let mut instances = Vec::new();
        let mut instances_for = Vec::new();
        let mut tokens: HashSet<String> = HashSet::new();

        // Module docstrings contribute no tokens, on purpose: the extractor
        // writes `line` / `col` / `text` for a module doc and no `doc` field, so
        // there is nothing to tokenise. Reading `text` instead would be a fix,
        // not a port — it changes which modules the map delta calls affected, so
        // it has to be measured rather than slipped in.
        // `litedoc4_ir::ModuleDoc` is `deny_unknown_fields`, so an IR that did
        // carry `doc` would fail to parse rather than change behaviour silently.

        let mut refs: BTreeMap<String, Vec<u32>> = BTreeMap::new();

        for decl in &module.declarations {
            #[expect(
                clippy::cast_possible_truncation,
                reason = "a module with 2^32 declarations is not a module"
            )]
            let index = decls.len() as u32;
            decls.push((decl.name.clone(), decl.kind.clone()));
            for reference in &decl.refs {
                let users = refs.entry(reference.name.clone()).or_default();
                // `Decl::refs` is deduplicated per declaration, so this can only
                // repeat when two declarations share a name — which the
                // extractor does not produce, but which costs one comparison to
                // survive.
                if users.last() != Some(&index) {
                    users.push(index);
                }
            }
            if decl.kind == "instance" {
                if let Some(class) = head_const(decl).filter(|class| !class.is_empty()) {
                    instances.push((class.to_owned(), decl.name.clone()));
                }
                for ty in &decl.inst_types {
                    if !ty.is_empty() {
                        instances_for.push((ty.clone(), decl.name.clone()));
                    }
                }
            }
            if let Some(doc) = decl.doc.as_deref().filter(|doc| !doc.is_empty()) {
                tokens.extend(autolink_tokens(doc));
            }
        }

        let mut tokens: Vec<String> = tokens.into_iter().collect();
        tokens.sort_by(|a, b| cmp_utf16(a, b));

        Self {
            module: module.module.clone(),
            content_hash: content_hash.to_owned(),
            imports: module.imports.clone(),
            tactics: module.tactics.len(),
            decls,
            instances,
            tokens,
            instances_for,
            refs,
        }
    }
}

/// The name on the tagged constant span that starts earliest. The spans come in
/// the extractor's pre-order, which is **not** sorted by `start`; ties keep the
/// earlier element of `type_code`.
#[must_use]
pub fn head_const(decl: &Decl) -> Option<&str> {
    let mut best: Option<(u32, &str)> = None;
    for span in &decl.type_code {
        if span.kind != SpanKind::Const {
            continue;
        }
        let Some(name) = span.name.as_deref() else {
            continue;
        };
        if best.is_none_or(|(start, _)| span.start < start) {
            best = Some((span.start, name));
        }
    }
    best.map(|(_, name)| name)
}

/// The names a docstring could autolink, in push order: duplicates kept, empty
/// strings possible.
///
/// The unit is the **whitespace-separated part of a code span**, not the code
/// span: `` `Nat.succ n` `` offers `Nat.succ`, `succ` and `n`. Every part that
/// contains a dot also offers its last component, unconditionally — including
/// when that component is empty, which is how `` `a.` `` contributes `""`.
/// Markdown link targets go through the same name resolution in the renderer, so
/// `](Target)` is tokenised too.
///
/// Deliberately an over-approximation: this does not parse Markdown, because it
/// is a filter in front of the delta, where a token too many costs a re-render
/// and a token too few costs a stale page. Widening is safe, narrowing is not —
/// which is also why it splits on the union of two separator sets rather than
/// choosing between them ([`is_token_separator`]).
#[must_use]
pub fn autolink_tokens(doc: &str) -> Vec<String> {
    let mut out = Vec::new();
    for inner in code_spans(doc) {
        for part in inner.split(is_token_separator) {
            push_token(&mut out, part);
        }
    }
    for target in link_targets(doc) {
        push_token(&mut out, target);
    }
    out
}

/// What [`autolink_tokens`] breaks a code span into parts on: the union of two
/// answers to "is this code point whitespace", neither of them wrong — V8's
/// `/[\p{Z}\p{C}]/u`, which the delta this crate has to agree with was computed
/// with, and UnicodeBasic's `Z | C` ([`litedoc4_md::gc::is_z_c`]), which decides
/// which names a page actually ends up linking.
///
/// **Do not narrow this to one of them.** These tokens are the filter in front
/// of the whole-package map delta ([`crate::delta::Delta`]) — a module is
/// re-rendered iff one of its tokens is a name that moved — and the two ways to
/// be wrong are not mirror images: too many tokens costs a re-render, too few
/// keeps a link pointing at the module a name used to live in and **nothing
/// downstream notices**. With `c` a code point V8 separates on and UnicodeBasic
/// does not, `` `Nat.succ<c>Foo` `` offers `Nat.succ` under V8 and not under
/// UnicodeBasic alone.
///
/// The tables disagree on 4,803 code points, every one of them a separator for
/// V8 and not for UnicodeBasic — a UCD version gap, the code points being
/// assigned in UnicodeBasic's database and unassigned (`Cn`, inside `C`) in
/// V8's (measured 2026-08-12 →
/// `benchmarks/results/m2b-v6-token-separators.json`). So the first disjunct is
/// dead today and stays: the two tables are pinned to things that move
/// independently (a `lake-manifest.json` rev and a V8 build), and the day one
/// gains a separator the other lacks, the `||` is what keeps this a superset of
/// both instead of a silent narrowing.
/// `the_two_separator_sets_disagree_the_way_v6_measured_them` asserts the
/// one-sidedness rather than assuming it.
#[must_use]
pub fn is_token_separator(c: char) -> bool {
    litedoc4_md::gc::is_z_c(c) || crate::v8_gc::is_z_c(c)
}

fn push_token(out: &mut Vec<String>, part: &str) {
    if part.is_empty() {
        return;
    }
    out.push(part.to_owned());
    // Deliberately asymmetric with the guard above: the last component is pushed
    // whether or not it is empty, so a part ending in a dot contributes `""`.
    if let Some(dot) = part.rfind('.') {
        out.push(part[dot + 1..].to_owned());
    }
}

/// The inside of every `` `...` `` in the text, as ``/`([^`\n]+)`/g`` finds
/// them: non-overlapping, left to right, no newline inside, never empty.
fn code_spans(doc: &str) -> Vec<&str> {
    let bytes = doc.as_bytes();
    let mut out = Vec::new();
    let mut open = 0;
    while let Some(offset) = bytes[open..].iter().position(|b| *b == b'`') {
        let start = open + offset + 1;
        let mut at = start;
        while at < bytes.len() && bytes[at] != b'`' && bytes[at] != b'\n' {
            at += 1;
        }
        // A run that stopped anywhere but on a closing backtick fails, and the
        // regex retries one position later — which here is the next backtick,
        // since the scan above never steps over one.
        if at < bytes.len() && bytes[at] == b'`' && at > start {
            out.push(&doc[start..at]);
            open = at + 1;
        } else {
            open = start;
        }
    }
    out
}

/// Every `](target)` in the text, as `/\]\(([^)\s]+)\)/g` finds them.
fn link_targets(doc: &str) -> Vec<&str> {
    let bytes = doc.as_bytes();
    let mut out = Vec::new();
    let mut open = 0;
    while open + 1 < bytes.len() {
        let Some(offset) = bytes[open..].windows(2).position(|pair| pair == b"](") else {
            break;
        };
        let start = open + offset + 2;
        let mut at = start;
        while at < bytes.len() {
            let ch = doc[at..].chars().next().expect("at is a char boundary");
            if ch == ')' || is_js_space(ch) {
                break;
            }
            at += ch.len_utf8();
        }
        if at < bytes.len() && bytes[at] == b')' && at > start {
            out.push(&doc[start..at]);
            open = at + 1;
        } else {
            open = open + offset + 1;
        }
    }
    out
}

/// JavaScript's `\s`: `WhiteSpace` plus `LineTerminator`.
///
/// Not `char::is_whitespace`, which is `White_Space` and excludes U+FEFF while
/// including U+0085.
fn is_js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202f}'
                | '\u{205f}'
                | '\u{3000}'
                | '\u{feff}'
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_prototypes_keys_come_first() {
        let facts = ModuleFacts {
            module: String::new(),
            content_hash: String::new(),
            imports: Vec::new(),
            tactics: 0,
            decls: Vec::new(),
            instances: Vec::new(),
            tokens: Vec::new(),
            instances_for: Vec::new(),
            refs: BTreeMap::new(),
        };
        let value = serde_json::to_value(&facts).expect("the facts serialise");
        let object = value.as_object().expect("a struct is an object");
        let keys: Vec<&str> = object.keys().map(String::as_str).collect();
        assert!(
            keys.len() >= PROTOTYPE_FACT_KEYS.len(),
            "ModuleFacts has fewer keys ({keys:?}) than the prototype's seven: a field the \
             comparison in tests/state_and_delta.rs rests on has been removed, not added"
        );
        assert_eq!(
            &keys[..PROTOTYPE_FACT_KEYS.len()],
            &PROTOTYPE_FACT_KEYS[..],
            "a field was added or reordered in front of the prototype's seven. The state file is \
             then no longer the prototype's keys followed by ours, and the entry-by-entry \
             comparison in tests/state_and_delta.rs compares the wrong things"
        );
    }

    #[test]
    fn code_spans_are_found_the_way_the_regex_finds_them() {
        assert_eq!(code_spans("`a`"), ["a"]);
        assert_eq!(code_spans("x `a` y `b` z"), ["a", "b"]);
        // An empty span is not a match, and its closing backtick can open one.
        assert_eq!(code_spans("``a`"), ["a"]);
        assert_eq!(code_spans("``"), Vec::<&str>::new());
        assert_eq!(code_spans("`a\nb`"), Vec::<&str>::new());
        assert_eq!(code_spans("`a`b`c`"), ["a", "c"]);
        assert_eq!(code_spans("no ticks"), Vec::<&str>::new());
        assert_eq!(code_spans("`α → β`"), ["α → β"]);
    }

    #[test]
    fn link_targets_are_found_the_way_the_regex_finds_them() {
        assert_eq!(link_targets("[t](Foo.Bar)"), ["Foo.Bar"]);
        assert_eq!(link_targets("[a](x) [b](y)"), ["x", "y"]);
        assert_eq!(link_targets("[t](a b)"), Vec::<&str>::new());
        assert_eq!(link_targets("[t]()"), Vec::<&str>::new());
        assert_eq!(link_targets("[t](a\u{a0}b)"), Vec::<&str>::new());
        // The greedy class eats everything that is not `)` or space.
        assert_eq!(link_targets("](](x)"), ["](x"]);
        assert_eq!(link_targets("]("), Vec::<&str>::new());
    }

    #[test]
    fn a_part_ending_in_a_dot_contributes_the_empty_string() {
        assert_eq!(autolink_tokens("`a.`"), ["a.", ""]);
        assert_eq!(autolink_tokens("`Nat.succ`"), ["Nat.succ", "succ"]);
        assert_eq!(autolink_tokens("`n`"), ["n"]);
        assert_eq!(autolink_tokens("`  a  `"), ["a"]);
    }

    /// U+088F ARABIC HALF MADDA OVER MADDA: a separator for V8 and not for
    /// UnicodeBasic — the direction that costs correctness.
    const V8_ONLY: char = '\u{088F}';

    /// U+00A0 NO-BREAK SPACE: a separator for both tables, which is as close as
    /// the disagreement gets to being two-sided.
    const BOTH: char = '\u{00A0}';

    #[test]
    fn the_split_is_a_superset_of_both_implementations() {
        assert_eq!(
            autolink_tokens(&format!("`Nat.succ{V8_ONLY}Foo`")),
            ["Nat.succ", "succ", "Foo"],
            "a code point V8 separates on and UnicodeBasic does not was kept inside a token"
        );
        assert_eq!(
            autolink_tokens(&format!("`Nat.succ{BOTH}Foo`")),
            ["Nat.succ", "succ", "Foo"],
            "a code point both tables separate on was kept inside a token"
        );
        assert!(
            autolink_tokens(&format!("`Nat.succ{V8_ONLY}Foo`")).contains(&"Nat.succ".to_owned())
        );
    }

    #[test]
    fn the_two_separator_sets_disagree_the_way_v6_measured_them() {
        let mut v8_only = 0usize;
        let mut unicode_basic_only = 0usize;
        for cp in 0..=0x10_FFFFu32 {
            let Some(c) = char::from_u32(cp) else {
                continue;
            };
            let v8 = crate::v8_gc::is_z_c(c);
            let unicode_basic = litedoc4_md::gc::is_z_c(c);
            assert_eq!(
                is_token_separator(c),
                v8 || unicode_basic,
                "U+{cp:04X} is not the union of the two tables"
            );
            if v8 && !unicode_basic {
                v8_only += 1;
            }
            if unicode_basic && !v8 {
                unicode_basic_only += 1;
            }
        }
        // (measured 2026-08-12 → benchmarks/results/m2b-v6-token-separators.json)
        assert_eq!(
            v8_only, 4_803,
            "the code points only the prototype splits on are not the 4,803 V6 measured"
        );
        assert_eq!(
            unicode_basic_only, 0,
            "UnicodeBasic is no longer a subset of V8: the union now widens both ways, and \
             is_token_separator's doc comment says it is one-sided"
        );
        assert!(is_token_separator(V8_ONLY) && !litedoc4_md::gc::is_z_c(V8_ONLY));
        assert!(is_token_separator(BOTH) && litedoc4_md::gc::is_z_c(BOTH));
    }
}
