//! Incremental rebuild: what to re-extract and what to re-render.
//!
//! Milestone **M3** — see `docs/implementation-plan.md`. **All five stages are
//! here**: `detect` (from `experiments/stage5/ledger.ts`), `ownership` (from
//! `ownership.ts`), `merge` (from `merge-ir.ts`), `impact` (from `impact.ts`)
//! and `prune` (from `prune-pages.ts`), all frozen prototypes. The pipeline that
//! sequences them is **M3-d** — it is the piece that owns the module-list glob,
//! the round loop and the union of the two render-set derivations, none of which
//! belong to a stage.
//!
//! These are two questions asked at two different times, not one question
//! asked twice. What to re-extract is decided before Lean runs, from the
//! `.olean` files; what to re-render is decided after, from the IR.
//!
//! Order within a run is constrained, and the constraints are not obvious
//! from the stage names:
//!
//! - ownership runs *before* merge, because merge overwrites the previous
//!   owner of every name it touches;
//! - the global artifacts run *before* impact, because their diff is what
//!   tells impact which pages have a docstring link that just went stale;
//! - extract/ownership/merge form a loop, bounded by `--max-rounds` (default 5)
//!   and leaving the process with **exit 5** when the bound is reached with
//!   modules still stale. The loop is the **pipeline's**, not a stage's: it
//!   needs the extractor between ownership and merge, so it arrives with the
//!   driver (`incremental.sh:291-294` is what has to move). What is here is the
//!   round's machinery — [`mod@ownership`]'s `--exclude` is how a round says what
//!   earlier rounds already took, and its `--print-set` is the next round's
//!   input;
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

// **A `pub use` here means another crate in this workspace imports the item.**
// Everything else stays `pub` in its own module and is reached as
// `litedoc4_incr::<module>::<item>` — the module list above is the surface.
// Every module here is `pub`, so nothing reaches the root for want of another
// path; the exception is a value whose *meaning* has its single source of truth
// here, and those carry a line saying so.
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
// Meaning, not caller: the two compatibility tokens a ledger's keys are taken
// over. What a stored key covers is decided by these lines and nothing else,
// and a run that disagrees with either re-extracts or re-renders everything.
pub use ledger::{EXTRACTOR_ID, RENDERER_ID};
pub use merge::{MergeOptions, merge, verify};
pub use ownership::{OwnershipOptions, WITNESSES_IN_LOG, ownership};
pub use prune::{ORPHANS_IN_LOG, PruneOptions, PruneSummary, page_of, prune};
