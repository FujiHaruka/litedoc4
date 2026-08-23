//! Putting a directory tree somewhere else.

use std::fs;
use std::path::Path;

/// Copy everything under `from` into `to`, recursively.
///
/// `to` is created if it is not there. **What is already in `to` stays**: this
/// merges a tree into a destination rather than replacing it, which is what
/// both callers want — `litedoc4-incr/tests/{impact,merge}.rs` lay a corpus
/// tree into a directory they are also writing into by hand, so that the same
/// scenario can be run against a copy without the 432-module original being
/// touched.
///
/// Recursion is decided by the entry's own type, so a symbolic link is copied
/// (its target's bytes, under the link's name) rather than walked.
///
/// # Panics
///
/// If `from` cannot be read, or any part of the copy fails. Every caller is a
/// test whose subject is what happens *after* the tree is in place, so a copy
/// that half-succeeded has to stop the run rather than change what is being
/// measured.
///
/// # This is not the only function with this name
///
/// `crates/litedoc4/tests/incremental.rs` has its own `copy_tree` and it is a
/// **different function**: it removes the destination first, goes through that
/// file's `tree()`/`write()` pair, and creates a `deps` directory at the end.
/// It is not a fork of this one and folding the two would silently change
/// both — one of several pairs of names elsewhere in this workspace that
/// collide by accident rather than share an implementation.
pub fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).expect("creatable");
    for entry in fs::read_dir(from).expect("the source tree reads") {
        let entry = entry.expect("a directory entry");
        let target = to.join(entry.file_name());
        if entry.file_type().expect("a file type").is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).expect("copyable");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDirs;

    const TEMP: TempDirs = TempDirs::prefixed("litedoc4-testutil-tree");

    /// Every path under the root, relative to it, with `/` for a directory —
    /// enough to tell "the directory is there and empty" from "the directory is
    /// not there", which is the difference the copy is allowed to lose.
    fn listing(root: &Path) -> Vec<String> {
        let mut out = Vec::new();
        let mut stack = vec![root.to_owned()];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir).expect("readable") {
                let entry = entry.expect("an entry");
                let path = entry.path();
                let relative = path.strip_prefix(root).expect("under the root").to_owned();
                let name = relative.to_str().expect("utf-8").to_owned();
                if entry.file_type().expect("a file type").is_dir() {
                    out.push(format!("{name}/"));
                    stack.push(path);
                } else {
                    out.push(name);
                }
            }
        }
        out.sort();
        out
    }

    /// The whole shape arrives, directories that hold nothing included.
    ///
    /// The empty directory is the case a copy driven by a list of *files*
    /// loses, and `litedoc4-incr`'s scenarios put page roots that hold only
    /// subdirectories in front of `prune`.
    #[test]
    fn a_nested_tree_arrives_with_its_empty_directories() {
        let work = TEMP.make("nested");
        let from = work.path().join("from");
        fs::create_dir_all(from.join("a/b")).expect("creatable");
        fs::create_dir_all(from.join("empty")).expect("creatable");
        fs::create_dir_all(from.join("a/also-empty")).expect("creatable");
        fs::write(from.join("top.txt"), b"top").expect("writable");
        fs::write(from.join("a/b/deep.txt"), b"deep").expect("writable");

        let to = work.path().join("to");
        copy_tree(&from, &to);

        assert_eq!(listing(&to), listing(&from));
        assert_eq!(
            listing(&to),
            [
                "a/",
                "a/also-empty/",
                "a/b/",
                "a/b/deep.txt",
                "empty/",
                "top.txt"
            ]
        );
        assert_eq!(
            fs::read(to.join("a/b/deep.txt")).expect("readable"),
            b"deep"
        );
        assert_eq!(fs::read(to.join("top.txt")).expect("readable"), b"top");
    }

    /// The destination need not exist, and what it already holds survives.
    ///
    /// This is the promise that separates this function from the `copy_tree` in
    /// `crates/litedoc4/tests/incremental.rs`, which begins with a
    /// `remove_dir_all` — see this module's doc comment. A test that asserted
    /// the destination came out equal to the source would pass for both and
    /// would not be checking either.
    #[test]
    fn the_destination_is_created_and_what_it_already_holds_is_kept() {
        let work = TEMP.make("merge");
        let from = work.path().join("from");
        fs::create_dir_all(&from).expect("creatable");
        fs::write(from.join("new.txt"), b"new").expect("writable");
        fs::write(from.join("shared.txt"), b"from-the-source").expect("writable");

        let to = work.path().join("nowhere/yet");
        copy_tree(&from, &to);
        assert!(to.join("new.txt").is_file(), "the destination was created");

        fs::write(to.join("was-here.txt"), b"was here").expect("writable");
        fs::write(to.join("shared.txt"), b"about to be overwritten").expect("writable");
        copy_tree(&from, &to);

        assert_eq!(
            listing(&to),
            ["new.txt", "shared.txt", "was-here.txt"],
            "the copy removed something it did not put there",
        );
        assert_eq!(
            fs::read(to.join("shared.txt")).expect("readable"),
            b"from-the-source",
            "a file the source also has is the source's",
        );
    }

    /// A link is copied, never walked.
    ///
    /// `DirEntry::file_type` reports the link itself, so the recursion never
    /// descends through one — a link that points back at an ancestor cannot
    /// make this loop. What lands at the other end is a plain file holding the
    /// target's bytes.
    #[cfg(unix)]
    #[test]
    fn a_symbolic_link_is_copied_rather_than_followed_into() {
        let work = TEMP.make("symlink");
        let from = work.path().join("from");
        fs::create_dir_all(from.join("real")).expect("creatable");
        fs::write(from.join("real/page.html"), b"<p>page</p>").expect("writable");
        std::os::unix::fs::symlink(Path::new("real/page.html"), from.join("link.html"))
            .expect("the symlink is creatable");

        let to = work.path().join("to");
        copy_tree(&from, &to);

        assert_eq!(listing(&to), ["link.html", "real/", "real/page.html"]);
        assert!(
            !fs::symlink_metadata(to.join("link.html"))
                .expect("it is there")
                .is_symlink(),
            "the copy is a link rather than the bytes it pointed at",
        );
        assert_eq!(
            fs::read(to.join("link.html")).expect("readable"),
            b"<p>page</p>"
        );
    }
}
