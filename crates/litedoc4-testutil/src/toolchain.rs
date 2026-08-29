//! A Lean toolchain that is deliberately not there.

use std::path::{Path, PathBuf};

/// A `lake` path for a test that wants Lean core to contribute nothing.
///
/// `litedoc4`'s `packages::lean_beside` turns `<dir>/lake` into `<dir>/lean`,
/// and Lean core's revision is that program's answer to `--githash`. Pointed at
/// nothing, core contributes no roots and the run **still succeeds**: refusing
/// would trade a site with some dead links for no site at all.
///
/// **The path has to have a directory in it.** `Path::new("no-such-lake")` has
/// none, so the sibling is the bare name `lean`, and `Command::new("lean")`
/// resolves that on `PATH` — the test then reads whatever toolchain the machine
/// happens to have, and its subject quietly becomes the machine. Three unit
/// tests in `packages.rs` did exactly that: green everywhere Lean has no default
/// toolchain, and three failures the moment one is configured
/// (measured 2026-08-29, `benchmarks/results/arm64-linux-runner-2026-08-29.txt`).
/// Naming a real toolchain instead would make these cases depend on the machine
/// the other way round, which is the line between a test and a gate.
#[must_use]
pub fn lake_that_is_not_there(dir: &Path) -> PathBuf {
    dir.join("no-toolchain/lake")
}
