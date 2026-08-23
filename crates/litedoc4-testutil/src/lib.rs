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
//!
//! WHY IT DEPENDS ON NOTHING
//!   An external crate is a licence and an advisory decision here even as a
//!   `dev-dependency` — `deny.toml`'s `[graph]` sets no `exclude-dev`. A
//!   workspace member that is `publish = false` costs neither.

// `cli`, `corpus`, `hash`, `text` and `tree` are `pub mod` with no root
// `pub use`: the root's re-exports carry only what another crate imports by
// name and what has no other route. Call sites read `litedoc4_testutil::corpus::LITEDOC4_IR.path()`
// and `litedoc4_testutil::text::show_ascii(..)`, which say where the variable
// name and the escaping policy come from.
//
// **Plain comments and not doc comments**: an outer `///` on a `mod` line is
// the first fragment of that module's documentation, and rustdoc then resolves
// the whole of it — including the module's own `//!` header — against *this*
// module. All eight intra-doc links in `corpus.rs`'s header broke that way, and
// `RUSTDOCFLAGS=-D warnings cargo doc` is what said so 【実測 2026-08-23】.
// Each module's documentation lives in its own file.
pub mod cli;
pub mod corpus;
pub mod hash;
mod temp;
pub mod text;
pub mod tree;

pub use temp::{TempDir, TempDirs};

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    /// **One inner `#![allow]` in the tree, and this is the one.**
    ///
    /// `clippy::allow_attributes` — the lint that pushes every suppression
    /// towards `#[expect]`, which fails once the lint stops firing — **does not
    /// look at the inner form**, while `allow_attributes_without_reason` does
    /// 【実測 2026-08-23】. So a
    /// `#![allow(…, reason = "…")]` can be written anywhere in the workspace
    /// and `cargo clippy -- -D warnings` stays green: what `Cargo.toml`
    /// enforces is that a suppression carries a reason, not that it expires.
    ///
    /// Pinning the count is the whole guard. An allowlist of files would be the
    /// "例外リストを持つ比較器" this repository refuses (CLAUDE.md), and a lint
    /// cannot be made to fire. A number can only be raised on purpose.
    #[test]
    fn the_tree_has_one_inner_allow_and_this_is_it() {
        let crates = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        let mut sources = Vec::new();
        rust_sources_under(&crates, &mut sources);
        let mut found: Vec<String> = Vec::new();
        for source in &sources {
            let text = std::fs::read_to_string(source).expect("a file this walk just listed");
            for (line, text) in text.lines().enumerate() {
                if text.trim_start().starts_with("#![allow") {
                    found.push(format!("{}:{}", source.display(), line + 1));
                }
            }
        }
        assert!(
            sources.len() > 20,
            "{} .rs files found under {}, which is too few to have walked the workspace",
            sources.len(),
            crates.display()
        );
        assert_eq!(
            found.len(),
            1,
            "the tree should hold exactly one inner `#![allow]`, the reasoned `dead_code` in \
             litedoc4-render/tests/common/mod.rs. Found {}: {}. Clippy will not object to a new \
             one as long as it carries a reason, so this test is the objection: remove it, turn \
             it into an `#[expect]`, or raise the number here and say why.",
            found.len(),
            found.join(", ")
        );
    }

    /// Every `*.rs` at or under `dir`.
    fn rust_sources_under(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => rust_sources_under(&path, out),
                Ok(kind) if kind.is_file() && path.extension().is_some_and(|ext| ext == "rs") => {
                    out.push(path);
                }
                _ => {}
            }
        }
    }
}
