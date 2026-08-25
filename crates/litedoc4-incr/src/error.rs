//! The crate's error type, and the one place the exit codes are decided.
//!
//! Every stage's refusals are variants of the one [`Error`] below. A stage that
//! grew its own error type would give the pipeline two answers to "what exit
//! code is this", and it is being one type that keeps the codes comparable
//! across stages: `1` is a file that would not read, `2` is a caller that asked
//! for something that does not exist, `3` is the world and the files
//! disagreeing, where retrying will not help.

use std::io;
use std::path::PathBuf;

use crate::ledger::LEDGER_SCHEMA;

#[derive(Debug)]
pub enum Error {
    Io {
        path: PathBuf,
        source: io::Error,
    },
    Json {
        path: PathBuf,
        source: serde_json::Error,
    },
    NoOlean {
        lib_dir: String,
        modules: Vec<String>,
    },
    LedgerSchema {
        path: PathBuf,
        found: u64,
    },
    NoSuchModule {
        path: PathBuf,
        module: String,
    },
    /// Carried rather than flattened, so that the reader's own message — which
    /// names the module file and the schema it wanted — survives.
    Ir(litedoc4_ir::Error),
    /// An `index.json` that parses as JSON but is not an index. No shape of
    /// index this can come out of a real extraction, so it is a refusal rather
    /// than a guess at what was meant.
    IndexShape {
        path: PathBuf,
        message: String,
    },
    /// Refused before the first byte is written. `index.json`'s `modules`
    /// array is ordered by the list, so a mismatch leaves the odd ones out to a
    /// guess, and both available guesses are silent: appending the unlisted
    /// ones diverges from a from-scratch extraction, dropping the unbacked ones
    /// leaves a module with a file and no index entry, invisible to every later
    /// stage. Neither shows up in a page byte.
    ModuleListMismatch {
        /// In the list, with nothing in the merged tree behind it.
        missing: Vec<String>,
        /// In the merged tree, and not in the list.
        extra: Vec<String>,
    },
    /// A `--changed` module the IR's index does not have. Refused rather than
    /// skipped: under-rendering has to be loud.
    NotAModule {
        module: String,
    },
    /// Only reached when there was something to select — see
    /// [`crate::impact::Mode::Unrecognised`].
    UnknownMode {
        mode: String,
    },
    /// A check rather than a comment because it is reachable from a module
    /// name: [`crate::prune::page_of`] goes through `litedoc4_ir::module_path`,
    /// and a name Lean spells `«..».Foo` keeps its `..` as one
    /// component (measured 2026-08-23).
    OutsidePageRoot {
        root: PathBuf,
        path: PathBuf,
    },
}

impl Error {
    #[must_use]
    pub fn exit_code(&self) -> u8 {
        match self {
            Self::Io { .. } | Self::Json { .. } | Self::Ir(_) => 1,
            Self::UnknownMode { .. } => 2,
            Self::NoOlean { .. }
            | Self::LedgerSchema { .. }
            | Self::NoSuchModule { .. }
            | Self::IndexShape { .. }
            | Self::ModuleListMismatch { .. }
            | Self::NotAModule { .. }
            | Self::OutsidePageRoot { .. } => 3,
        }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io { path, source } => write!(f, "{}: {source}", path.display()),
            Self::Json { path, source } => write!(f, "{}: {source}", path.display()),
            Self::NoOlean { lib_dir, modules } => {
                write!(f, "no olean under {lib_dir} for: {}", modules.join(", "))
            }
            Self::LedgerSchema { path, found } => write!(
                f,
                "{} is ledgerSchema {found}; this build needs {LEDGER_SCHEMA} (the single envKey \
                 was split into extractKey/renderKey). Rebuild the ledger.",
                path.display()
            ),
            Self::NoSuchModule { path, module } => write!(
                f,
                "no such module in the ledger {}: {module}",
                path.display()
            ),
            Self::Ir(source) => write!(f, "{source}"),
            Self::IndexShape { path, message } => write!(f, "{}: {message}", path.display()),
            Self::ModuleListMismatch { missing, extra } => write!(
                f,
                "--modules and the merged IR name different modules: {} in the list with nothing \
                 behind them ({}), {} in the merged tree the list does not name ({}). index.json's \
                 module order is this list's, so the odd ones out would have to be guessed at — \
                 and a wrong guess moves index.json alone, where no page byte follows it",
                missing.len(),
                some_of(missing),
                extra.len(),
                some_of(extra),
            ),
            Self::NotAModule { module } => write!(f, "not a module of this package: {module}"),
            Self::UnknownMode { mode } => write!(f, "unknown --mode {mode}"),
            Self::OutsidePageRoot { root, path } => write!(
                f,
                "refusing to delete {} — it is not under the page root {}",
                path.display(),
                root.display()
            ),
        }
    }
}

/// A caller needs a name to start from, not a list that scrolls a screenful of
/// terminal away.
const NAMES_IN_REFUSAL: usize = 10;

fn some_of(names: &[String]) -> String {
    if names.is_empty() {
        return "none".to_owned();
    }
    let shown = names
        .iter()
        .take(NAMES_IN_REFUSAL)
        .map(String::as_str)
        .collect::<Vec<_>>()
        .join(", ");
    if names.len() > NAMES_IN_REFUSAL {
        format!("{shown}, … and {} more", names.len() - NAMES_IN_REFUSAL)
    } else {
        shown
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Json { source, .. } => Some(source),
            Self::Ir(source) => Some(source),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(count: usize) -> Vec<String> {
        (0..count).map(|n| format!("Micro.M{n}")).collect()
    }

    #[test]
    fn no_names_is_the_word_none_and_not_an_empty_line() {
        assert_eq!(some_of(&[]), "none");
    }

    #[test]
    fn the_elision_starts_one_past_the_limit_and_not_at_it() {
        let at = some_of(&names(NAMES_IN_REFUSAL));
        assert_eq!(at.split(", ").count(), NAMES_IN_REFUSAL);
        assert!(!at.contains("more"), "at the limit nothing is elided: {at}");

        let past = some_of(&names(NAMES_IN_REFUSAL + 1));
        assert!(
            past.ends_with("… and 1 more"),
            "one past the limit elides exactly one: {past}"
        );
        assert_eq!(past.split(", ").count(), NAMES_IN_REFUSAL + 1);
    }

    #[test]
    fn past_the_limit_ten_names_are_shown_and_the_rest_are_counted() {
        let shown = some_of(&names(NAMES_IN_REFUSAL + 7));
        assert!(shown.starts_with("Micro.M0, Micro.M1, "), "{shown}");
        assert!(
            shown.ends_with(&format!("Micro.M{}, … and 7 more", NAMES_IN_REFUSAL - 1)),
            "{shown}"
        );
        assert!(
            !shown.contains(&format!("Micro.M{NAMES_IN_REFUSAL}")),
            "the eleventh name is counted, not shown: {shown}"
        );
    }
}
