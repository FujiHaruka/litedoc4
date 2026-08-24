//! Incremental rebuild: what to re-extract and what to re-render.
//!
//! Two questions asked at two different times, not one question asked twice.
//! What to re-extract is decided before Lean runs, from the `.olean` files;
//! what to re-render is decided after, from the IR.
//!
//! The order the caller has to run the stages in is not visible from the stage
//! names:
//!
//! - ownership before merge, because merge overwrites the previous owner of
//!   every name it touches;
//! - the global artifacts before impact, because their diff is what tells
//!   impact which pages have a docstring link that just went stale;
//! - extract/ownership/merge form a loop, bounded by `--max-rounds` and leaving
//!   the process with **exit 5** when the bound is reached with modules still
//!   stale. The loop belongs to the driver, which is what has the extractor
//!   between ownership and merge; what is here is a round's machinery —
//!   [`mod@ownership`]'s `--exclude` says what earlier rounds already took and
//!   its `--print-set` is the next round's input;
//! - a `renderKey` change overrides the impact mode and re-renders everything.
//!
//! Key comparison is a union: a key present on only one side counts as a
//! change. Under-rendering has to be loud, never silent.
//!
//! ```no_run
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! use litedoc4_incr::{Algorithm, BuildOptions, build_ledger};
//! let modules = litedoc4_incr::read_module_list(std::path::Path::new("modules.txt"))?;
//! let summary = build_ledger(&BuildOptions {
//!     modules: &modules,
//!     target: "/path/to/repo",
//!     out: std::path::Path::new("ledger.json"),
//!     ir: None,
//!     source_url: "",
//!     link_index: None,
//!     external_links: None,
//!     algorithm: &Algorithm::sha256(),
//!     concurrency: 1,
//!     timings: None,
//! })?;
//! println!("{} modules, {} olean files", summary.modules, summary.files);
//! # Ok(()) }
//! ```

pub mod detect;
pub mod error;
pub mod impact;
pub(crate) mod io;
pub mod ledger;
pub mod merge;
pub mod ordered;
pub mod ownership;
pub mod prune;

// A `pub use` here means another crate in this workspace imports the item;
// everything else is reached as `litedoc4_incr::<module>::<item>`.
pub use detect::{
    BuildOptions, CheckOptions, CheckSummary, TouchOptions, build_ledger, check_ledger,
    read_module_list, touch_ledger,
};
pub use error::Error;
pub use impact::{ImpactOptions, Mode, impact};
pub use ledger::{
    Algorithm, Ledger, extract_key, hash_module, link_index_digest, render_key, sha256_hex,
    sha256_text,
};
// Exported for meaning rather than for a caller: these two tokens decide what
// a stored key covers, and a run that disagrees re-extracts or re-renders all.
pub use ledger::{EXTRACTOR_ID, RENDERER_ID};
pub use merge::{MergeOptions, merge, verify};
pub use ownership::{OwnershipOptions, WITNESSES_IN_LOG, ownership};
pub use prune::{ORPHANS_IN_LOG, PruneOptions, PruneSummary, page_of, prune};
