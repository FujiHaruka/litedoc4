//! Whole-site artifacts: the name map, the site's entry pages and the two
//! indexes the browser reads.
//!
//! Instance lists and importer lists are in no page's bytes — the browser fills
//! them in from `instances.json` and `modules.json`. A moved instance is only
//! ever right because these artifacts were rebuilt, so "the pages are unchanged"
//! is not a reason to skip the run.
//!
//! ```no_run
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let mut options = litedoc4_global::GlobalOptions::new(
//!     std::path::Path::new("/path/to/ir"),
//!     std::path::Path::new("/path/to/site"),
//! );
//! options.state = Some(std::path::Path::new("/path/to/state"));
//! let summary = litedoc4_global::build_global(&options)?;
//! println!("{} declarations", summary.declarations);
//! println!("{} cached, {} read", summary.cache_hits, summary.cache_misses);
//! # Ok(()) }
//! ```

pub mod artifacts;
pub mod delta;
pub mod entry;
pub mod facts;
pub mod search_index;
mod site;
pub mod state;
pub mod v8_gc;

// A `pub use` here means another crate in this workspace imports the item;
// everything else is reached as `litedoc4_global::<module>::<item>`.
// `unreachable_pub` catches a re-export that stops being needed, except for
// `Error`, which is reachable only as `build_global`'s error type.
pub use artifacts::page_path;
pub use site::{Error, FactsRun, GlobalOptions, GlobalSummary, build_global, facts_for};
// Re-exported for their meaning rather than for a caller: anything that has to
// find the cache file, or decide whether a cached entry answers for this
// version, has to agree with these two.
pub use state::{STATE_DERIVATION, STATE_FILE};
