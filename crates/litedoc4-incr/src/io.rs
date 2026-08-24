//! The writers every stage shares, so that "write this set of names" has one
//! spelling: the empty file below is load-bearing and has to be empty
//! everywhere.

use std::fs;
use std::path::Path;

use serde::Serialize;

use crate::error::Error;

/// One name per line, and **no line at all** when there are no names: the
/// pipeline hands this to `--only-from`, where an empty file has to mean
/// "render nothing" rather than "render everything".
pub(crate) fn lines_file(items: &[String]) -> String {
    if items.is_empty() {
        String::new()
    } else {
        items.join("\n") + "\n"
    }
}

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

#[cfg(test)]
mod tests {
    use super::*;
    use litedoc4_testutil::TempDirs;

    const TEMP: TempDirs = TempDirs::prefixed("litedoc4-incr-io");

    #[test]
    fn an_empty_set_reaches_the_disk_as_a_file_with_no_line_in_it() {
        let dir = TEMP.make("empty-set");
        let path = dir.path().join("set.txt");
        write_text(&path, &[]).expect("an empty set is writable");
        assert_eq!(fs::read_to_string(&path).expect("it is there"), "");
    }

    #[test]
    fn a_directory_that_cannot_be_made_is_named_as_the_directory() {
        let dir = TEMP.make("parent-is-a-file");
        let occupied = dir.path().join("in-the-way");
        fs::write(&occupied, "not a directory").expect("the file is written");

        let error = write(&occupied.join("under-it.txt"), "body")
            .expect_err("a file cannot be a parent directory");
        let Error::Io { path, .. } = &error else {
            panic!("expected an io failure, got {error:?}");
        };
        assert_eq!(
            path, &occupied,
            "the directory is named, not the file under it"
        );
    }

    #[test]
    fn a_file_that_cannot_be_written_is_named_as_the_file() {
        let dir = TEMP.make("target-is-a-directory");
        let occupied = dir.path().join("in-the-way");
        fs::create_dir(&occupied).expect("the directory is made");

        let error = write(&occupied, "body").expect_err("a directory cannot be written over");
        let Error::Io { path, .. } = &error else {
            panic!("expected an io failure, got {error:?}");
        };
        assert_eq!(path, &occupied);
    }
}
