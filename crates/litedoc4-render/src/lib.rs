//! Rendering module pages from the IR.
//!
//! Filled in by milestone **M1**.
//!
//! The acceptance oracle compares bytes, so a few defaults have to be
//! overridden rather than inherited (plan §7):
//!
//! - HTML escaping covers `& < > "` and nothing else. `'` is left alone.
//! - Sorting follows UTF-16 code unit order, not UTF-8 byte order. The two
//!   disagree above U+FFFF, which is exactly where the mathematical
//!   alphanumerics live.
//! - String literals inside `<script>` follow Lean's `String.quote`.
//!
//! One interface rule: the set of modules to render is a [`ModuleSet`], whose
//! empty case is a value rather than the absence of one. The prototype
//! expressed it as the presence or absence of a flag, which collapsed "empty
//! set" into "every module" and silently re-rendered all 432 pages. See plan §5
//! and [`site`]'s heading, which is where the rule lives.
//!
//! # What is here so far (M1-b, M1-c)
//!
//! The pieces the page builder is written on top of, each a transcription of a
//! named function in the frozen prototype (`experiments/stage7d/render.ts`):
//!
//! | | prototype | here |
//! |---|---|---|
//! | HTML escape / Lean string literal | `escapeHtml`, `leanQuote` | [`escape`] |
//! | `String.lt` / `Name.lt` | `stringLt`, `nameLt` | [`order`] |
//! | schema-3 whitespace replay | `applyWsWidths` | [`whitespace`] |
//! | the dependency closure's map | `render.ts:2067-2084` | [`link_index`] |
//! | docstring name resolution | `nameToLink`, `isNameLit`, `isLetterLike` | [`autolink`] |
//!
//! # What is here so far (M1-d1)
//!
//! [`code`] — one printed code fragment (a signature, a binder, an equation, a
//! structure field) to HTML: `buildTree`, `Renderer`, and the name handling
//! around them. It is the leaf the page builder calls, and the only part of the
//! page that resolves constants against the IR's own map rather than against
//! the dependency closure's.
//!
//! The fifth item of plan §7's list — UTF-16 code unit order — is in
//! [`litedoc4_ir::cmp_utf16`] instead: M2's global artifacts and M3's ledger
//! sort with it too, and one comparator with one set of tests is the point.
//!
//! Each of the five is checked against the prototype's own answers rather than
//! against a reading of it; see `tests/differential.rs`.
//!
//! # What is here so far (M1-d2)
//!
//! The parts a declaration's block on a page is made of, and the frame around
//! them. [`decl`] is `div.decl` — header, attributes, docstring, structure
//! members, equations, instance stubs — and [`frame`] is `<head>`, `<header>`
//! and the left-hand navigation. Both are byte-compared against the prototype
//! over the real IR (`tests/page_parts.rs`).
//!
//! # What is here so far (M1-d3)
//!
//! [`page`] assembles one module's page — which declarations get an entry
//! ([`page::Suppressed`], site-wide) and in what order they and the module
//! docstrings appear — and [`site`] is the run: read the IR, build the maps in
//! the order that decides what links where, write one file per wanted module.
//!
//! [`site::render_site`] is the whole of M1 as one call. Its output is
//! compared to the frozen prototype's, byte for byte, by
//! `tools/render-compare.sh`.
//!
//! # What is here so far (M7-b, M7-c)
//!
//! [`external`] — the map from a **dependency's** module root to the
//! version-pinned GitHub blob prefix its sources live under, and the lookup that
//! turns a module name into a URL. `litedoc4`'s `packages` module resolves it out
//! of the target's `lake-manifest.json` and its toolchain.
//!
//! **M7-c is where the pages use it.** Every link *into another module* — a
//! docstring autolink, a constant in a signature, an inherited structure field,
//! an entry in the import list — is built by [`autolink::NameIndex::link_to`], which is
//! the only place the choice is made:
//!
//! | the module is | the href |
//! |---|---|
//! | in the map with a `/blob/<rev>` (a pinned dependency) | `…/blob/<rev>/<path>.lean#L<from>-L<to>` |
//! | in the map with an empty base (an unpinnable dependency) | none: the name is text |
//! | not in the map, and this run wrote its page | the relative page link, unchanged |
//! | not in the map, and it has no page | none: the name is text |
//!
//! The package being documented is never in the map, so its own links do not
//! move — and **an empty map, over a run that renders every module it can name,
//! reproduces the pre-M7 bytes exactly**, which is what keeps the frozen
//! prototype's fixtures meaningful as the fallback branch's oracle
//! ([`autolink::NameIndexBuilder::build_with_a_page_for_every_module`] is that
//! world; doc-gen4 byte compatibility was retired once M7 pinned dependency
//! links to versioned GitHub URLs, and is no longer claimed for dependency
//! links).
//!
//! The last row is 2026-08-17's: a package whose `lakefile.toml` declares more
//! than one `[[lean_lib]]` has modules that this run does not render, and
//! linking to them relatively wrote an href to a file nobody created.
//!
//! # What is here so far (M8-a)
//!
//! [`assets`] — the `style.css` / `app.js` / `favicon.svg` the pages reference,
//! carried in the binary by `include_str!` and written into the site tree by
//! [`write_assets`]. Until M8-a the `<head>` named files nothing produced, so
//! the tree `litedoc4 build` wrote could not be opened without hand-copying
//! doc-gen4's own assets over it.
//! **They are deliberately outside the incremental render key** — see the
//! module's own heading.

pub mod assets;
pub mod autolink;
pub mod code;
pub mod config;
pub mod decl;
pub mod escape;
pub mod external;
pub mod frame;
pub mod link_index;
pub mod order;
pub mod page;
pub mod site;
pub mod whitespace;

// **A `pub use` here means another crate in this workspace imports the item.**
// Everything else stays `pub` in its own module and is reached as
// `litedoc4_render::<module>::<item>` — the module list above is the surface.
// The exception is a value whose *meaning* has its single source of truth here;
// those carry a line saying so.
pub use assets::{ASSETS, write_assets};
// Meaning, not caller: the spelling Lean prints in front of a private name, which
// anything that has to recognise one would otherwise spell a second time.
pub use autolink::PRIVATE_PREFIX;
pub use code::{break_within, css_kind};
pub use config::SiteConfig;
// Meaning, not caller: the name of the file a package's site settings live in —
// what a caller looking for one has to agree with.
pub use config::CONFIG_FILE;
// Meaning, not caller: doc-gen4's cut-off, the length at which an equation is
// stored as NULL and replaced by a notice.
pub use decl::EQUATION_LIMIT;
pub use external::{DepDocs, ExternalLinks};
// Meaning, not caller: the two version tokens an `ExternalLinks` digest is taken
// over. What a digest covers is decided by these lines and nothing else.
pub use external::{DIGEST_MARKER, DOCS_DIGEST_MARKER};
pub use frame::{SiteMeta, head_html, topbar_html};
pub use link_index::LinkIndex;
pub use page::page_path;
pub use site::{ModuleSet, RenderOptions, RenderSummary, render_site};
