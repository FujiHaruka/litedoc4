//! Test helpers shared across the workspace.
//!
//! Nothing here is part of the program. Every crate that uses it names it as a
//! `dev-dependency`, so it is absent from `cargo tree -p litedoc4 -e normal` —
//! the tree `tools/provenance-gate.sh` derives NOTICE from — and absent from
//! every released binary.
//!
//! WHY A CRATE AND NOT A `tests/common/mod.rs` PER CRATE
//!   A `tests/common/mod.rs` is compiled into the integration test binaries of
//!   its own crate and reaches nothing else. Five of the fifteen `TempDir`
//!   copies this replaced sit in a `#[cfg(test)] mod tests` **inside `src/`** —
//!   `litedoc4-incr/src/prune.rs`, `litedoc4/src/packages.rs` and
//!   `litedoc4-render/src/{assets,config,site}.rs` — and a `tests/` file cannot
//!   reach those at all. That, and not the line count, is what decided a crate.
//!   §7 U2 of `docs/plans/refactoring.md` records the decision.
//!
//! WHY IT DEPENDS ON NOTHING
//!   §2.3 of the same plan: an external crate is a licence and an advisory
//!   decision here even as a `dev-dependency` — `deny.toml`'s `[graph]` sets no
//!   `exclude-dev`. A workspace member that is `publish = false` costs neither.

mod temp;

pub use temp::{TempDir, TempDirs};
