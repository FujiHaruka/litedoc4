//! Temporary directories that remove themselves.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

/// One counter for the whole crate rather than one per call site, so that two
/// files picking the same prefix still cannot collide; the process id separates
/// concurrent test binaries.
static NEXT: AtomicU32 = AtomicU32::new(0);

/// The temporary directories one test file makes, named after that file.
///
/// The prefix is not decoration: a directory left behind by a run that died is
/// traced back to whatever made it **by its name and nothing else**, and this
/// workspace has filled a disk with untraced ones before. So each file binds
/// its own:
///
/// ```
/// use litedoc4_testutil::TempDirs;
///
/// const TEMP: TempDirs = TempDirs::prefixed("litedoc4-pages");
///
/// let work = TEMP.make("both-link-index-flags");
/// assert!(work.path().is_dir());
/// ```
///
/// Binding it once per file is also what keeps the prefix out of the call
/// signature: `TempDir::new(prefix, what)` would be two `&str` in a row, and
/// swapping them is not something the compiler can see.
pub struct TempDirs {
    prefix: &'static str,
}

impl TempDirs {
    pub const fn prefixed(prefix: &'static str) -> Self {
        Self { prefix }
    }

    /// A unique, empty directory that **exists** on return.
    pub fn make(&self, what: &str) -> TempDir {
        let dir = self.reserve(what);
        fs::create_dir_all(&dir.path).expect("the temporary directory is creatable");
        dir
    }

    /// A unique path that **nothing has made yet**, for the tests whose whole
    /// subject is that the code under test creates the directory itself.
    ///
    /// Dropping it still removes the directory, if one came to exist.
    pub fn reserve(&self, what: &str) -> TempDir {
        // Non-alphanumerics become `-` so that the name cannot carry a
        // separator, a quote or a space: a `/` would put the directory one
        // level deeper than the path this value deletes, leaking the level
        // above it, and `litedoc4/tests/extract.rs` writes the path into a
        // shell script.
        let slug: String = what
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .take(40)
            .collect();
        let path = std::env::temp_dir().join(format!(
            "{}-{}-{}-{slug}",
            self.prefix,
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        TempDir { path }
    }
}

/// A unique directory under the system temporary one, removed with its contents
/// when it goes out of scope — so a run that fails part way does not leave a
/// tree of pages behind.
///
/// Hand-rolled rather than `tempfile` because an external crate is a licence
/// and an advisory decision here even as a `dev-dependency`: `deny.toml`'s
/// `[graph]` sets no `exclude-dev`.
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEMP: TempDirs = TempDirs::prefixed("litedoc4-testutil");

    /// `Drop` returning without removing anything leaves every other test in
    /// the workspace green, so nothing but this would notice.
    #[test]
    fn the_directory_is_gone_when_the_value_is() {
        let path = {
            let dir = TEMP.make("dropped");
            fs::write(dir.path().join("a-file"), b"contents").expect("writable");
            assert!(
                dir.path().is_dir(),
                "the directory is there while it is held"
            );
            dir.path().to_owned()
        };
        assert!(
            !path.exists(),
            "the directory outlived the value that owns it: {}",
            path.display()
        );
    }

    #[test]
    fn reserve_makes_nothing_and_make_makes_it() {
        let reserved = TEMP.reserve("reserved");
        assert!(!reserved.path().exists(), "reserve created the directory");
        let made = TEMP.make("made");
        assert!(made.path().is_dir(), "make did not create the directory");
    }

    #[test]
    fn names_are_unique_within_a_process() {
        let first = TEMP.make("same");
        let second = TEMP.make("same");
        assert_ne!(first.path(), second.path());
    }

    #[test]
    fn a_separator_in_the_name_does_not_become_one_in_the_path() {
        let dir = TEMP.make("a/b c\"d");
        let name = dir
            .path()
            .file_name()
            .expect("a file name")
            .to_str()
            .expect("utf-8");
        assert!(name.ends_with("-a-b-c-d"), "{name}");
        assert_eq!(
            dir.path().parent(),
            Some(std::env::temp_dir().as_path()),
            "the directory is not directly under the system temporary one",
        );
    }
}
