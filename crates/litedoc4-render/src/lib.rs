//! Rendering module pages from the IR.
//!
//! The set of modules to render is a [`ModuleSet`], whose empty case is a value
//! rather than the absence of one — a flag's presence or absence collapses
//! "empty set" into "every module", and the two have to stay apart.
//!
//! Every link *into another module* — a docstring autolink, a constant in a
//! signature, an inherited structure field, an entry in the import list — is
//! built by [`autolink::NameIndex::link_to`], which is the only place that
//! choice is made.

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
