//! The crate's error type, and the one place the exit codes are decided.
//!
//! **Every stage's refusals are variants of the [`Error`] below** — `detect`'s
//! missing olean, `merge`'s malformed index, `impact`'s unknown mode, `prune`'s
//! path outside the page root. `litedoc4_incr::Error` *is* this type, and a
//! sixth stage adds its variant **here**: a second error type in a stage's own
//! file would give the pipeline two answers to "what exit code is this", and
//! [`Error::exit_code`] is the single `match` that answers it for all of them.
//!
//! Being one type is also why the codes stay comparable across stages: `1` is a
//! file that would not read, `2` is a caller that asked for something that does
//! not exist, and `3` is the prototype's refusal — the world and the files
//! disagree, and retrying will not help.

use std::io;
use std::path::PathBuf;

use crate::ledger::LEDGER_SCHEMA;

/// Why a run stopped.
///
/// The three refusals below are the prototype's **exit 3**: a run that stopped
/// because the ledger and the world disagree, as against one that could not read
/// a file. The caller maps them back onto the same exit codes.
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
    /// `build`: modules in the list have no olean under `lib_dir`.
    NoOlean {
        lib_dir: String,
        modules: Vec<String>,
    },
    /// `check`: the ledger predates the `extractKey` / `renderKey` split.
    LedgerSchema {
        path: PathBuf,
        found: u64,
    },
    /// `touch`: no such module in the ledger.
    NoSuchModule {
        path: PathBuf,
        module: String,
    },
    /// `ownership` / `merge`: the IR would not read. Carried rather than
    /// flattened so the reader's own message — which names the module file and
    /// the schema it wanted — survives.
    Ir(litedoc4_ir::Error),
    /// `merge` / `prune`: an `index.json` that parses as JSON but is not an
    /// index.
    ///
    /// The prototype reads `e.file` off whatever the JSON held and would write a
    /// file called `undefined`; there is no shape of index this can reach from a
    /// real extraction, so it is a refusal (exit 3) rather than a guess.
    IndexShape {
        path: PathBuf,
        message: String,
    },
    /// `merge --modules`: the package's module list and the tree the merge is
    /// about to write name different modules.
    ///
    /// **Exit 3, and refused before the first byte is written** 【判断】. The
    /// list is what `index.json`'s `modules` array is ordered by, so a mismatch
    /// leaves the order of the odd ones out to a guess — and the only guesses
    /// available are the two this project refuses to make silently: append the
    /// unlisted ones (which is the divergence from a from-scratch extraction
    /// that M3-d2b removed) or drop the unbacked ones (a module with a file and
    /// no index entry, invisible to every later stage). Neither shows up in a
    /// page byte, so neither would ever be noticed.
    ModuleListMismatch {
        /// In the list, with nothing in the merged tree behind it.
        missing: Vec<String>,
        /// In the merged tree, and not in the list.
        extra: Vec<String>,
    },
    /// `impact`: a `--changed` module the IR's index does not have. The
    /// prototype's **exit 3** — under-rendering has to be loud (plan §5, M3).
    NotAModule {
        module: String,
    },
    /// `impact`: a `--mode` nobody recognises. The prototype's **exit 2**, and
    /// it is only reached when there was something to select — see
    /// [`crate::impact::Mode::Unrecognised`].
    UnknownMode {
        mode: String,
    },
    /// `prune`: a path that would be deleted outside the page root.
    ///
    /// **Reachable from a module name**, which is exactly why it is a check and
    /// not a comment: [`crate::prune::page_of`] goes through
    /// `litedoc4_ir::module_path` (M5-b), and a name Lean spells `«..».Foo`
    /// keeps its `..` as one component【実測 2026-08-23】. Exit 3: the world
    /// and the files disagree, and retrying will not help.
    OutsidePageRoot {
        root: PathBuf,
        path: PathBuf,
    },
}

impl Error {
    /// The process exit code, as the prototype's.
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
            // The prototype's exact wording: `impact.ts:182` and `:207`.
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

/// How many names a refusal spells out before it only counts them.
///
/// The same shape as `merge --verify`'s `VERIFY_DEP_FAILURES`: a caller needs a
/// name to start from, not a list that scrolls a screenful of terminal away.
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

    /// **The values are built here rather than reached through a stage.**
    /// What is under examination is the arithmetic of the elision, and driving
    /// eleven names out of `merge` would mean an eleven-module IR tree to check
    /// a subtraction with. The refusals that *carry* these lists are reached
    /// from an input in `crates/litedoc4/tests/queries.rs`.
    fn names(count: usize) -> Vec<String> {
        (0..count).map(|n| format!("Micro.M{n}")).collect()
    }

    #[test]
    fn no_names_is_the_word_none_and_not_an_empty_line() {
        assert_eq!(some_of(&[]), "none");
    }

    /// **The boundary, from both sides.** Checking only "ten is whole" and
    /// "seventeen is elided" leaves `>` free to be `>=`: the first list that
    /// gets elided is the eleventh name's, and nothing else moves when that
    /// comparison slips by one.
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

    /// Past the limit the reader gets a name to start from and a count — not a
    /// list that scrolls a screenful of terminal away.
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
