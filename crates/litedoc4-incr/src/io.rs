//! The three writers every stage uses.
//!
//! They are here and not in one stage because all five call them: `detect`
//! writes `--changed-out` / `--removed-out` / `--render-all-out`, `ownership`
//! and `merge` write their own name sets, and every stage that takes
//! `--timings` writes one JSON line. A stage that grows a fourth spelling of
//! "write this set of names" is the failure this module exists to prevent —
//! the empty file below is load-bearing and has to be empty everywhere.

use std::fs;
use std::path::Path;

use serde::Serialize;

use crate::error::Error;

/// One name per line, and **no line at all** when there are no names.
///
/// The empty file is load-bearing: it is what the pipeline hands to
/// `--only-from`, where an empty set has to mean "render nothing" rather than
/// "render everything" (plan §5).
pub(crate) fn lines_file(items: &[String]) -> String {
    if items.is_empty() {
        String::new()
    } else {
        items.join("\n") + "\n"
    }
}

/// Writes a set of names as [`lines_file`] spells it.
///
/// Shared by every stage that hands a module set to the next one:
/// `--changed-out`, `--removed-out`, `--render-all-out`, `--print-set`. One
/// spelling, so the empty file cannot be empty in one stage and a blank line in
/// another.
pub(crate) fn write_text(path: &Path, items: &[String]) -> Result<(), Error> {
    write(path, &lines_file(items))
}

pub(crate) fn write(path: &Path, body: &str) -> Result<(), Error> {
    if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
        fs::create_dir_all(dir).map_err(|source| Error::Io {
            path: dir.to_owned(),
            source,
        })?;
    }
    fs::write(path, body).map_err(|source| Error::Io {
        path: path.to_owned(),
        source,
    })
}

pub(crate) fn write_json_line(path: &Path, record: &impl Serialize) -> Result<(), Error> {
    let body = serde_json::to_string(record).expect("counts and durations serialise") + "\n";
    write(path, &body)
}
