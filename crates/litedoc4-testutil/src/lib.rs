//! Test helpers shared across the workspace.
//!
//! Every crate that uses this names it as a `dev-dependency`, so it is absent
//! from `cargo tree -p litedoc4 -e normal` — the tree `tools/provenance-gate.sh`
//! derives NOTICE from — and absent from every released binary.
//!
//! A `tests/common/mod.rs` per crate would not do: it is compiled into its own
//! crate's integration test binaries and reaches nothing else, while several
//! users of these helpers are `#[cfg(test)] mod tests` **inside `src/`**, which
//! a `tests/` file cannot reach at all.
//!
//! It depends on nothing outside the workspace on purpose: `deny.toml`'s
//! `[graph]` sets no `exclude-dev`, so an external crate is a licence and an
//! advisory decision even as a `dev-dependency`. A `publish = false` workspace
//! member costs neither.

// **Plain comments and not doc comments**: an outer `///` on a `mod` line is
// the first fragment of that module's documentation, and rustdoc then resolves
// the whole of it — including the module's own `//!` header — against *this*
// module. All eight intra-doc links in `corpus.rs`'s header broke that way, and
// `RUSTDOCFLAGS=-D warnings cargo doc` is what said so (measured 2026-08-23).
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

    /// `clippy::allow_attributes` — the lint that pushes every suppression
    /// towards `#[expect]`, which fails once the lint stops firing — **does not
    /// look at the inner `#![allow]` form**, while `allow_attributes_without_reason`
    /// does (measured 2026-08-23). A reasoned inner `#![allow]` can therefore be
    /// written anywhere and `cargo clippy -- -D warnings` stays green.
    ///
    /// Pinning the count is the whole guard: an allowlist of files would be the
    /// "a comparator with an exception list" this repository refuses, and a lint cannot be
    /// made to fire. A number can only be raised on purpose.
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
