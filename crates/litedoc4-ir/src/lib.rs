//! Reading only: the extractor stays in Lean, so nothing here serialises, and
//! [`IndexEntry::content_hash`] is read and carried rather than recomputed.
//!
//! Every read of a module file goes through this crate, so the `contentHash`
//! cache that would remove the pipeline's repeated full passes has exactly one
//! place to go. [`metrics`] counts those reads.
//!
//! ```no_run
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let tree = litedoc4_ir::IrTree::open("/path/to/ir")?;
//! for module in tree.modules() {
//!     let module = module?;
//!     for decl in &module.declarations {
//!         for span in &decl.type_code {
//!             let tagged = decl.ty.slice(span.range());
//!             println!("{} {:?} {tagged}", decl.name, span.kind);
//!         }
//!     }
//! }
//! # Ok(()) }
//! ```

mod error;
pub mod metrics;
mod model;
pub mod name;
mod reader;
mod span;
pub mod utf16;

// A `pub use` here means another crate in this workspace imports the item;
// everything else is reached as `litedoc4_ir::<module>::<item>`.
pub use error::{Error, Result};
pub use metrics::{IrFile, IrReads};
pub use model::{
    Attr, Decl, DeclNaming, DepMap, DepMapEntry, Generated, GeneratedFact, Index, IndexEntry,
    Member, ModuleDoc, ModuleFile, Ref, SelectionRange, SorryFact, SorryKind, Tactic,
};
pub use name::{escape_module, module_components, module_path, page_path};
pub use reader::{IrTree, MIN_SCHEMA_VERSION, read_module_file};
pub use span::{Span, SpanKind};
pub use utf16::{Utf16Text, cmp_utf16, sort_utf16};
