//! The IR's schema-5 shapes, as the extractor writes them: it decides which
//! keys exist and which are omitted, and this module models what it writes
//! rather than what any one consumer reads.
//!
//! Every struct is `deny_unknown_fields`. A field the extractor starts emitting
//! and this crate does not know about is then a loud parse failure instead of a
//! silent drop; the schema version is what governs compatibility, so there is no
//! forward-compatibility left for tolerant parsing to buy.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;

use serde::de::{self, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};

use crate::{Span, Utf16Text};

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Index {
    pub schema_version: u32,
    /// The extractor's identity string, part of the extraction cache key: it
    /// must change when the implementation does.
    pub generator: String,
    pub lean_version: String,
    /// Names the algorithm behind [`IndexEntry::content_hash`].
    pub hash_algorithm: String,
    pub module_count: u32,
    pub declaration_count: u32,
    /// A refusal marker: the extractor ran with an ablation flag, so the IR is
    /// deliberately incomplete and rendering it would produce a page that looks
    /// fine and is wrong.
    #[serde(default)]
    pub ablations: Vec<String>,
    pub modules: Vec<IndexEntry>,
    pub dependency_maps: Vec<DepMapEntry>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct IndexEntry {
    pub module: String,
    /// Path relative to the IR root, e.g. `modules/Foo.Bar.json`. The file name
    /// is the module's full name with no directories.
    pub file: String,
    /// The writer's `String.utf8ByteSize` of the module file.
    pub bytes: u64,
    pub declarations: u32,
    /// Lean's `String.hash` of the module JSON, 16 hex digits. **Never
    /// recomputed on this side** — that would mean porting `lean_string_hash`.
    pub content_hash: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DepMapEntry {
    pub package: String,
    pub file: String,
    pub entries: u32,
    pub bytes: u64,
}

impl Index {
    pub fn require_renderable(&self) -> Result<(), crate::Error> {
        if self.schema_version < crate::MIN_SCHEMA_VERSION {
            return Err(crate::Error::Schema {
                found: self.schema_version,
                required: crate::MIN_SCHEMA_VERSION,
                what: "index.json".to_owned(),
            });
        }
        if !self.ablations.is_empty() {
            return Err(crate::Error::Ablated {
                ablations: self.ablations.clone(),
            });
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModuleFile {
    pub schema_version: u32,
    pub module: String,
    pub imports: Vec<String>,
    pub module_docs: Vec<ModuleDoc>,
    /// **Empty for every module of the target package** 【実測 2026-08-21】, so
    /// the shape below follows the writer (`Extract.lean:2007-2011`), not
    /// observed data.
    pub tactics: Vec<Tactic>,
    pub declarations: Vec<Decl>,
}

impl ModuleFile {
    /// **Three-valued, and it has to be.** A schema-5 writer omits the key to
    /// mean "no `sorry`"; a schema-4 file has no key to omit, so the same
    /// absence means "nobody was asked". Reading [`Decl::sorry`] directly
    /// conflates them into "this package has no holes", which is a claim about
    /// the package made from a fact about the extractor's version.
    ///
    /// This is the only thing that should read [`Decl::sorry`].
    pub fn sorry_of(&self, decl: &Decl) -> SorryFact {
        if self.schema_version < crate::reader::SORRY_SCHEMA_VERSION {
            return SorryFact::Unknown;
        }
        match decl.sorry {
            None => SorryFact::Clean,
            Some(SorryKind::Direct) => SorryFact::Direct,
            Some(SorryKind::Transitive) => SorryFact::Transitive,
        }
    }

    /// [`Decl::selection_range`]'s three-valued reading: below schema 5 the key
    /// cannot exist, so the answer is [`DeclNaming::Unknown`] without looking.
    /// This is the only thing that should read [`Decl::selection_range`].
    pub fn naming_of(&self, decl: &Decl) -> DeclNaming {
        if self.schema_version < crate::reader::SELECTION_RANGE_SCHEMA_VERSION {
            return DeclNaming::Unknown;
        }
        match decl.selection_range {
            None => DeclNaming::Unknown,
            Some(sel) => {
                if sel.line == decl.line
                    && sel.col == decl.col
                    && sel.end_line == decl.end_line
                    && sel.end_col == decl.end_col
                {
                    DeclNaming::Unnamed
                } else {
                    DeclNaming::Named(sel)
                }
            }
        }
    }

    /// [`Decl::generated`]'s three-valued reading. This is the only thing that
    /// should read [`Decl::generated`].
    pub fn generated_by<'a>(&self, decl: &'a Decl) -> GeneratedFact<'a> {
        if self.schema_version < crate::reader::SELECTION_RANGE_SCHEMA_VERSION {
            return GeneratedFact::Unknown;
        }
        match decl.generated.as_ref() {
            None => GeneratedFact::Unclaimed,
            Some(generated) => GeneratedFact::By(generated),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SorryFact {
    /// The file predates schema 5. Nothing is known — in particular this is
    /// **not** [`SorryFact::Clean`].
    Unknown,
    /// Schema 5 or newer, and the writer said nothing: no `sorry`.
    Clean,
    Direct,
    Transitive,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModuleDoc {
    pub line: u32,
    pub col: u32,
    /// Markdown. Not tagged, so no UTF-16 offsets point into it.
    pub text: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Tactic {
    pub internal_name: String,
    pub user_name: String,
    pub tags: Vec<String>,
    pub doc_string: String,
}

/// A span list indexes its paired text in UTF-16 code units; every other string
/// is an ordinary `String`.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Decl {
    pub name: String,
    /// `def`, `theorem`, `structure`, `class`, `instance`, ...
    pub kind: String,
    pub modifiers: Vec<String>,
    pub binders: Vec<Utf16Text>,
    /// Parallel to `binders`: whether each binder is implicit.
    pub implicits: Vec<bool>,
    /// Parallel to `binders`.
    pub binder_code: Vec<Vec<Span>>,
    #[serde(rename = "type")]
    pub ty: Utf16Text,
    pub type_code: Vec<Span>,
    pub line: u32,
    pub col: u32,
    pub end_line: u32,
    pub end_col: u32,
    /// The *other* range `findDeclarationRanges?` returns. On its own,
    /// `selection_range == range` does not reliably mean "auto-generated".
    ///
    /// **Read it through [`ModuleFile::naming_of`], not directly.** A schema-4
    /// file has no such key, so `None` here means "nobody was asked" rather
    /// than any fact about the declaration.
    #[serde(default)]
    pub selection_range: Option<SelectionRange>,
    /// Position in the order the extractor enumerated the module. Two pairs of
    /// declarations in this package share a `(line, col)` — four declarations
    /// 【実測 2026-08-21 → `benchmarks/results/generated-decls-2026-08-21.txt`】
    /// — so the range alone does not order the page.
    pub index: u32,
    pub members: Vec<Member>,
    pub doc: Option<String>,
    pub equations: Vec<Utf16Text>,
    /// Parallel to `equations`.
    pub equation_code: Vec<Vec<Span>>,
    /// Deduplicated references, `(defining module, name)`.
    pub refs: Vec<Ref>,
    /// Omitted by the writer when empty, so an empty vector means "no
    /// attributes", never "unknown". The element shape moved in schema 5:
    /// `[name, value]` where schema 4 had `"name value"`; both parse.
    #[serde(default)]
    pub attrs: Vec<Attr>,
    /// Instances only: the class this instance is for. `None` for everything
    /// else, and then `inst_types` is empty as well.
    #[serde(default)]
    pub inst_class: Option<String>,
    /// Instances only.
    #[serde(default)]
    pub inst_types: Vec<String>,
    /// Whether this declaration is a hole, and whose (doc-gen4 #270).
    ///
    /// **Read it through [`ModuleFile::sorry_of`], not directly.** The writer
    /// omits the key when neither value applies, so `None` means "no `sorry`" —
    /// but only in a file that says `schemaVersion` 5, and a schema-4 file has
    /// no key to omit. On its own this field cannot tell the two apart.
    #[serde(default)]
    pub sorry: Option<SorryKind>,
    /// The declaration `@[ext]` realized this one **from**, one step, as
    /// `["ext", name]` on the wire.
    ///
    /// **Read it through [`ModuleFile::generated_by`], not directly**: the
    /// writer omits the key when it has nothing to say, so `None` is "not
    /// realized by `@[ext]`" only in a file that says `schemaVersion` 5.
    ///
    /// Only `@[ext]` is ever named here, and the boundary is not a matter of
    /// taste: `simps` / `to_additive` / `mk_iff` / `to_dual` / `alias` keep
    /// their maps in Mathlib's environment extensions, and an extractor that
    /// imported Mathlib would stop building against a Mathlib-free package.
    /// The measured cost of that boundary is that **7 of 94 `ext`-shaped
    /// declarations in the Mathlib sample are realized through `to_additive` /
    /// `to_dual` and get no key** 【実測 2026-08-21 →
    /// `benchmarks/results/generated-decls-2026-08-21.txt`】; none of them gets
    /// a *wrong* one.
    #[serde(default)]
    pub generated: Option<Generated>,
}

/// `[line, col, endLine, endCol]` on the wire.
///
/// Where the source names the declaration this is a proper sub-range of it;
/// where nothing does, Lean defaults the selection range to the whole range
/// (`Lean/Elab/DeclarationRange.lean:53`), so the two are **equal**.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SelectionRange {
    pub line: u32,
    pub col: u32,
    pub end_line: u32,
    pub end_col: u32,
}

impl<'de> Deserialize<'de> for SelectionRange {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let (line, col, end_line, end_col) = <(u32, u32, u32, u32)>::deserialize(deserializer)?;
        Ok(Self {
            line,
            col,
            end_line,
            end_col,
        })
    }
}

/// **This is not "generated" and must not be read as it**
/// 【実測 2026-08-21 → `benchmarks/results/generated-decls-2026-08-21.txt`】:
/// over 2,786 Mathlib declarations, [`DeclNaming::Unnamed`] also covers field
/// projections and macro-defined declarations (209 of 779), and does **not**
/// cover the `to_additive` twins whose additive name the author wrote out (376
/// are [`DeclNaming::Named`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeclNaming {
    /// No `selectionRange` key. Nothing is known — in particular this is
    /// **not** [`DeclNaming::Unnamed`].
    Unknown,
    Named(SelectionRange),
    Unnamed,
}

/// `[origin, name]` on the wire. `origin` is always `ext` today; a second
/// origin would arrive as a second value here rather than as a second key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Generated {
    pub origin: String,
    /// What the realization took as **input**, one step: `P.ext` names the
    /// structure `P`, `P.ext_iff` names `P.ext`. Following the chain — and
    /// stopping when a step has no key, which is what a hand-written `P.ext`
    /// looks like — is the reader's business.
    pub from: String,
}

impl<'de> Deserialize<'de> for Generated {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let (origin, from) = <(String, String)>::deserialize(deserializer)?;
        Ok(Self { origin, from })
    }
}

/// [`ModuleFile::generated_by`]'s answer.
///
/// Three values, and the middle one is the reason: **"the extractor said
/// nothing" is not "the author wrote it"**. [`GeneratedFact::Unclaimed`] covers
/// hand-written declarations *and* everything the Mathlib-side attributes
/// realized, so a reader that prints "written by hand" for it is making a claim
/// the IR does not carry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GeneratedFact<'a> {
    /// The file predates the key. Nothing is known.
    Unknown,
    /// Schema 5 or newer, and the writer said nothing: not realized by `@[ext]`.
    Unclaimed,
    By(&'a Generated),
}

/// Two values rather than a flag because they are **different claims**; a
/// declaration that is both is `Direct`.
///
/// The IR deliberately does *not* carry the axiom set: every Mathlib-dependent
/// declaration transitively uses `Classical.choice` / `propext` / `Quot.sound`,
/// so the full list is a large field with almost no information in it.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SorryKind {
    /// This declaration's own statement or proof mentions `sorryAx`.
    Direct,
    /// It does not, but something it depends on does.
    Transitive,
}

/// Schema 5 writes a two-element `[name, value]` array; schema 4 wrote one
/// concatenated string per attribute, `"deprecated Foo"`, and **that still
/// parses** — a bare string arrives here as a name with an empty
/// [`Attr::value`].
///
/// What the reader must **not** do is split such a string on its first space.
/// An attribute value can contain spaces (`deprecated`) and brackets
/// (`specialize #[0, 1]`), so where the boundary is is a fact only the
/// extractor has. A consumer that wants to *act* on an attribute must check
/// [`Attr::value`] is non-empty rather than assume the pair was split.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attr {
    pub name: String,
    /// Empty for the attributes that take no argument, and for **every**
    /// attribute of a schema-4 file.
    pub value: String,
}

impl Attr {
    pub fn text(&self) -> Cow<'_, str> {
        if self.value.is_empty() {
            Cow::Borrowed(&self.name)
        } else {
            Cow::Owned(format!("{} {}", self.name, self.value))
        }
    }
}

impl<'de> Deserialize<'de> for Attr {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(AttrVisitor)
    }
}

/// An array of any arity but two is an error rather than a best-effort read: a
/// one-element array would become a name with no value, indistinguishable from
/// a legitimate schema-4 string, and a three-element one would silently drop
/// whatever the writer added.
struct AttrVisitor;

impl<'de> Visitor<'de> for AttrVisitor {
    type Value = Attr;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(
            "an attribute: a two-element [name, value] array (schema 5), \
             or a string (schema 4)",
        )
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<Attr, E> {
        Ok(Attr {
            name: value.to_owned(),
            value: String::new(),
        })
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Attr, A::Error> {
        let name: String = seq
            .next_element()?
            .ok_or_else(|| de::Error::invalid_length(0, &self))?;
        let value: String = seq
            .next_element()?
            .ok_or_else(|| de::Error::invalid_length(1, &self))?;
        let mut extra = 2;
        while seq.next_element::<de::IgnoredAny>()?.is_some() {
            extra += 1;
        }
        if extra > 2 {
            return Err(de::Error::invalid_length(extra, &self));
        }
        Ok(Attr { name, value })
    }
}

/// Only `label == "field"` members carry the five optional keys; the writer
/// omits them for `ctor` and `parent` rather than paying five empty keys per
/// structure.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Member {
    /// `field`, `ctor` or `parent`.
    pub label: String,
    pub name: String,
    pub text: Utf16Text,
    pub code: Vec<Span>,
    #[serde(default)]
    pub binders: Vec<Utf16Text>,
    #[serde(default)]
    pub implicits: Vec<bool>,
    #[serde(default)]
    pub binder_code: Vec<Vec<Span>>,
    #[serde(default)]
    pub doc: Option<String>,
    /// **Three-valued on purpose.** A *missing* key is a direct field, so a
    /// plain `#[serde(default)] bool` would make it `false` = inherited: the
    /// opposite reading, and one no byte comparison on this package can catch,
    /// because all 156 field members of the target package's IR carry the key
    /// 【実測】. [`Member::is_inherited`] is the only thing that reads it.
    #[serde(default)]
    pub is_direct: Option<bool>,
}

impl Member {
    pub fn is_field(&self) -> bool {
        self.label == "field"
    }

    pub fn is_inherited(&self) -> bool {
        self.is_direct == Some(false)
    }
}

/// `[module, name]` on the wire: which module defines the constant.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ref {
    pub module: String,
    pub name: String,
}

impl<'de> Deserialize<'de> for Ref {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let (module, name) = <(String, String)>::deserialize(deserializer)?;
        Ok(Self { module, name })
    }
}

/// `deps/<PackageRoot>.json`. Two columns is all a link needs: `kind` is only
/// wanted by a search UI, and `docLink` is recoverable from `(module, name)`.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DepMap {
    pub schema_version: u32,
    pub package: String,
    /// Constant name -> defining module. A `BTreeMap` rather than an
    /// order-preserving map: no consumer does anything but look names up.
    pub declarations: BTreeMap<String, String>,
}
