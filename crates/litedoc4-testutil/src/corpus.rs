//! The corpus inputs: what a test asks the environment for, and where it looks
//! when nobody said.
//!
//! None of these is a fixture. Every one names a tree or a file that lives
//! **outside the repository** — the 432-module IR of the measurement target,
//! the pages the frozen prototype rendered, a 10 MB `.lidx` — which is why
//! every test that reaches this module is `#[ignore]`d and
//! `tools/corpus-gate.sh` is the only thing that should be asking for it.
//!
//! The whole inventory is here and nowhere else. [`Input`]'s fields are private,
//! so a call site can ask for an input this module already knows about but
//! cannot invent one out of its own `std::env::var`. The variable names are not
//! this module's to choose either: `tools/corpus-gate.sh` prints them and
//! `tools/corpus-tests.txt` is checked against the `#[ignore]` reasons that
//! name them.
//!
//! Two shapes that look like duplication and are not:
//!
//!   1. **One tree, three variable names.** `…/m1/ref-pages` is asked for as
//!      [`LITEDOC4_REF_PAGES`], [`LITEDOC4_REFERENCE_PAGES`] and
//!      [`LITEDOC4_PAGES`], one per test that wants it. The gate sets them one
//!      at a time, so a machine can hold the pages for one comparison and not
//!      for another.
//!
//!   2. **One variable name, two defaults.** [`LITEDOC4_LINK_INDEX`] defaults
//!      to the file the render corpus tests read; [`LITEDOC4_M7A_LINK_INDEX`]
//!      defaults to where `benchmarks/tools/check-lidx-urls.sh` leaves the
//!      `.lidx` it drives, because the two tests that use it are coupled to
//!      that driver rather than to the relay directory. One name, so the gate
//!      sets one variable; two defaults, so an unset run still finds the file
//!      its own driver wrote.

use std::path::{Path, PathBuf};

/// One input the corpus gate provides.
///
/// Constructed only by the `pub const`s below: the fields are private so that
/// the set of inputs is a list one file long.
pub struct Input {
    /// What the thing is, in the words the panic uses ("IR tree", "link
    /// index") — not the variable name, because a reader of a failing test
    /// wants to know what is missing before knowing what to export.
    what: &'static str,
    /// The environment variable `tools/corpus-gate.sh` sets.
    var: &'static str,
    /// Where to look when it is unset. **Frozen paths.** The
    /// `/private/tmp/lean-doc-relay/**` ones keep the pre-rename spelling on
    /// purpose — the committed fixtures carry it as the path they were
    /// generated at, and these defaults have to match that frozen path
    /// exactly.
    default: &'static str,
}

/// The generated IR of the target package: 432 modules, 16 MB of JSON.
pub const LITEDOC4_IR: Input = Input {
    what: "IR tree",
    var: "LITEDOC4_IR",
    default: "/private/tmp/lean-doc-relay/w7h/base-ir",
};

/// The same tree, under the name the incremental crates ask for it by: there it
/// is the IR a run is measured **against**, so the tests that edit an IR can be
/// pointed at a base without moving the one the render tests read.
pub const LITEDOC4_BASE_IR: Input = Input {
    what: "IR tree",
    var: "LITEDOC4_BASE_IR",
    default: "/private/tmp/lean-doc-relay/w7h/base-ir",
};

/// doc-gen4's own output on the measurement target. Inside the target's
/// `.lake`, which is gitignored there and never written to from here.
pub const LITEDOC4_DOCGEN4_TREE: Input = Input {
    what: "doc-gen4 tree",
    var: "LITEDOC4_DOCGEN4_TREE",
    default: "/Users/haruka/dev/lean-projects/.lake/build/doc",
};

/// The `.lidx` of the target's dependency closure as the relay directory holds
/// it — what the render corpus tests resolve dependency links against.
pub const LITEDOC4_LINK_INDEX: Input = Input {
    what: "link index",
    var: "LITEDOC4_LINK_INDEX",
    default: "/private/tmp/lean-doc-relay/w7c/linkindex/link-index.lidx",
};

/// The same variable, defaulted to where `benchmarks/tools/check-lidx-urls.sh`
/// — the driver that makes both this and [`LITEDOC4_DECL_URLS`] — leaves it.
/// Any `litedoc4 build --out <dir>` writes one at `<dir>/link-index.lidx`;
/// copy it here.
pub const LITEDOC4_M7A_LINK_INDEX: Input = Input {
    what: "link index",
    var: "LITEDOC4_LINK_INDEX",
    default: "/private/tmp/litedoc4-m7a/link-index.lidx",
};

/// The per-declaration source URLs mined out of doc-gen4's own pages, ~41 MB.
/// Same `WORK_DIR` and same driver as [`LITEDOC4_M7A_LINK_INDEX`].
pub const LITEDOC4_DECL_URLS: Input = Input {
    what: "declaration URLs",
    var: "LITEDOC4_DECL_URLS",
    default: "/private/tmp/litedoc4-m7a/decl-source-urls.tsv",
};

/// The pages the frozen prototype rendered, read as the docstring oracle.
pub const LITEDOC4_REF_PAGES: Input = Input {
    what: "reference pages",
    var: "LITEDOC4_REF_PAGES",
    default: "/private/tmp/lean-doc-relay/m1/ref-pages",
};

/// The same tree, read as the whole-page byte oracle.
pub const LITEDOC4_REFERENCE_PAGES: Input = Input {
    what: "reference pages",
    var: "LITEDOC4_REFERENCE_PAGES",
    default: "/private/tmp/lean-doc-relay/m1/ref-pages",
};

/// The same tree again, read by the incremental scenarios — the module pages
/// **without** the whole-package artifacts. Read only: every scenario copies it
/// first.
pub const LITEDOC4_PAGES: Input = Input {
    what: "reference pages",
    var: "LITEDOC4_PAGES",
    default: "/private/tmp/lean-doc-relay/m1/ref-pages",
};

/// The whole-package artifacts the frozen prototype wrote.
pub const LITEDOC4_REFERENCE_GLOBAL: Input = Input {
    what: "reference tree",
    var: "LITEDOC4_REFERENCE_GLOBAL",
    default: "/private/tmp/lean-doc-relay/m2/ref-global",
};

/// The whole site: the module pages **plus** the whole-package artifacts, three
/// of which are `.html` — which is what makes the orphan rule interesting.
/// Read only.
pub const LITEDOC4_SITE: Input = Input {
    what: "reference site",
    var: "LITEDOC4_SITE",
    default: "/private/tmp/lean-doc-relay/m2/gate/ref-site",
};

/// The `fixtures/` subdirectory of the tree `tools/merge-reference.sh` writes:
/// the partial extractions **both** implementations were fed.
pub const LITEDOC4_MERGE_FIXTURES: Input = Input {
    what: "fixtures",
    var: "LITEDOC4_MERGE_FIXTURES",
    default: "/private/tmp/lean-doc-relay/m3b/ref/fixtures",
};

/// A state file the frozen prototype wrote, over [`LITEDOC4_IR`].
pub const LITEDOC4_PROTOTYPE_STATE: Input = Input {
    what: "prototype state",
    var: "LITEDOC4_PROTOTYPE_STATE",
    default: "/private/tmp/lean-doc-relay/w7h/base-state/global-state.json",
};

impl Input {
    /// The path, checked to be **there and not empty**, or a panic naming the
    /// variable to set.
    ///
    /// Every caller is `#[ignore]`d, so reaching this at all means the corpus
    /// gate asked for the test by name. Returning "not here, never mind" would
    /// be a green result for a comparison that never ran.
    pub fn path(&self) -> PathBuf {
        self.checked(None)
    }

    /// [`Input::path`], plus the command that makes the thing — for the inputs
    /// a tool in this repository produces, where a reader who has the target
    /// but not the file needs one line rather than a search.
    pub fn path_built_by(&self, how: &str) -> PathBuf {
        self.checked(Some(how))
    }

    /// The path, **unchecked** — for the callers that make a *stronger* claim
    /// than a file count: asserting `index.json` by name, or reading the file
    /// and reporting the `io::Error` that says *why* it could not be read.
    ///
    /// Anything weaker than that belongs in [`Input::path`]. The door back to
    /// `is_dir()` stays shut (an emptied directory that still exists must count
    /// as absent, not present), and "I do my own check" is not the same claim
    /// as "I do a stronger one".
    pub fn raw(&self) -> PathBuf {
        PathBuf::from(std::env::var(self.var).unwrap_or_else(|_| self.default.to_owned()))
    }

    fn checked(&self, how: Option<&str>) -> PathBuf {
        let path = self.raw();
        assert!(
            file_count(&path) != 0,
            "no {} at {} (empty or missing): set {}, {}run this test through \
             tools/corpus-gate.sh, which is the only thing that should be asking for it",
            self.what,
            path.display(),
            self.var,
            how.map_or_else(
                || "or ".to_owned(),
                |how| format!("or make it with\n    {how}\nor ")
            ),
        );
        path
    }
}

/// A `--full` recording's path, or a panic naming what to set.
///
/// Separate from [`Input`] because these have **no default and can have none**:
/// the generator that wrote them exists only at tag `experiments-frozen`, so a
/// default path would name a file HEAD cannot produce — a worse answer than no
/// path at all.
pub fn recording(var: &str) -> String {
    std::env::var(var).unwrap_or_else(|_| {
        panic!(
            "set {var} to a `--full` recording made by the generator at tag \
             experiments-frozen (HEAD cannot make one), or run this test through \
             tools/corpus-gate.sh, which is the only thing that should be asking for it"
        )
    })
}

/// Regular files at or under `path`; 1 for a plain file, 0 for a missing path.
///
/// **Presence is counted in files, not directories.** These trees live under
/// `/private/tmp`, which is swept: an emptied `ref-pages` leaves its directory
/// behind, `is_dir()` says yes, and the comparison then fails somewhere further
/// in for an environmental reason — an environment problem wearing a code
/// problem's clothes.
///
/// A plain file counts as one because some of the inputs **are** files. One
/// predicate for directories and files together is deliberate: splitting it
/// into "is this a non-empty directory" and "is this a file" is what re-opens
/// the door to `is_dir()`.
fn file_count(path: &Path) -> usize {
    let Ok(entries) = std::fs::read_dir(path) else {
        return usize::from(path.is_file());
    };
    entries
        .flatten()
        .map(|entry| match entry.file_type() {
            Ok(kind) if kind.is_dir() => file_count(&entry.path()),
            Ok(kind) if kind.is_file() => 1,
            _ => 0,
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDirs;

    const TEMP: TempDirs = TempDirs::prefixed("litedoc4-corpus");

    /// An input whose default is `dir` and whose variable is one nothing sets.
    /// The leak is what buys the `&'static str` a `default` is; a test process
    /// that ends is the collector.
    ///
    /// **No test in this module writes an environment variable**:
    /// `std::env::set_var` is `unsafe` in edition 2024 because it races every
    /// other thread's `getenv`, and the harness runs this file's tests on
    /// several. The half that would need one is covered by
    /// [`tests::the_variable_wins_over_the_default`] through a variable **cargo
    /// itself sets**.
    fn input_at(dir: &Path) -> Input {
        Input {
            what: "test tree",
            var: "LITEDOC4_TESTUTIL_NOTHING_SETS_THIS",
            default: Box::leak(dir.to_str().expect("utf-8").to_owned().into_boxed_str()),
        }
    }

    /// The whole sentence is pinned, not just the verdict: the two branches of
    /// the message are assembled from one format string, and a dropped
    /// connective is invisible to an assertion on the verdict alone.
    #[test]
    #[should_panic(
        expected = "(empty or missing): set LITEDOC4_TESTUTIL_NOTHING_SETS_THIS, or run this \
                    test through tools/corpus-gate.sh, which is the only thing that should be \
                    asking for it"
    )]
    fn an_existing_but_empty_directory_is_not_an_input() {
        let dir = TEMP.make("empty");
        let _ = input_at(dir.path()).path();
    }

    #[test]
    fn a_directory_holding_a_file_is_an_input() {
        let dir = TEMP.make("holding-a-file");
        std::fs::write(dir.path().join("index.json"), b"{}").expect("writable");
        assert_eq!(input_at(dir.path()).path(), dir.path());
    }

    #[test]
    #[should_panic(expected = "no test tree at")]
    fn a_missing_path_is_not_an_input() {
        let dir = TEMP.reserve("never-made");
        let _ = input_at(dir.path()).path();
    }

    #[test]
    fn a_plain_file_counts_as_one_and_a_missing_path_as_none() {
        let dir = TEMP.make("counting");
        let file = dir.path().join("link-index.lidx");
        std::fs::write(&file, b"#lidx2\n").expect("writable");
        assert_eq!(file_count(&file), 1);
        assert_eq!(file_count(&dir.path().join("not-here")), 0);
        assert_eq!(file_count(dir.path()), 1);
    }

    /// Driven through `CARGO_MANIFEST_DIR`, which cargo sets for every test
    /// binary and which names a real, non-empty tree, so the assertion needs no
    /// write to the environment.
    #[test]
    fn the_variable_wins_over_the_default() {
        let set = std::env::var("CARGO_MANIFEST_DIR").expect(
            "cargo sets CARGO_MANIFEST_DIR in a test binary it runs, and this test needs a \
             variable that something else has already set",
        );
        let input = Input {
            what: "crate directory",
            var: "CARGO_MANIFEST_DIR",
            default: "/nonexistent/litedoc4-testutil/the-default",
        };
        assert_eq!(input.path(), PathBuf::from(set));
    }

    #[test]
    fn the_default_is_used_when_the_variable_is_not_set() {
        let input = Input {
            what: "source directory",
            var: "LITEDOC4_TESTUTIL_NOTHING_SETS_THIS",
            default: concat!(env!("CARGO_MANIFEST_DIR"), "/src"),
        };
        assert_eq!(
            input.path(),
            PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/src"))
        );
    }

    #[test]
    fn raw_does_not_check_that_anything_is_there() {
        let dir = TEMP.reserve("never-made");
        assert_eq!(input_at(dir.path()).raw(), dir.path());
    }

    #[test]
    #[should_panic(expected = "or make it with\n    tools/merge-reference.sh --out <dir>\nor run")]
    fn path_built_by_names_the_command() {
        let dir = TEMP.make("empty");
        let _ = input_at(dir.path()).path_built_by("tools/merge-reference.sh --out <dir>");
    }

    #[test]
    #[should_panic(expected = "made by the generator at tag experiments-frozen")]
    fn a_recording_with_no_variable_says_where_one_comes_from() {
        let _ = recording("LITEDOC4_TESTUTIL_NOTHING_SETS_THIS");
    }

    /// **Every command a `path_built_by` message names has to be runnable as
    /// written.** The argument is a `&str`, so nothing else looks at it: a
    /// renamed flag leaves an instruction that still reads correctly, is still
    /// printed to the one reader who has the target but not the file, and
    /// cannot be run. A stale one survived a week that way (measured 2026-08-23).
    ///
    /// The check is on the flags and not on the whole line: the paths in these
    /// messages are `<dir>`-shaped placeholders on purpose, so "runnable" here
    /// means every `--flag` is one the named command has an arm for.
    #[test]
    fn every_path_built_by_instruction_names_flags_the_command_accepts() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let mut sources = Vec::new();
        rust_sources_under(&repo.join("crates"), &mut sources);

        let mut checked = 0;
        for source in &sources {
            let text = std::fs::read_to_string(source).expect("a file this walk just listed");
            for instruction in path_built_by_arguments(&text) {
                let mut words = instruction.split_whitespace();
                let command = words.next().unwrap_or_default();
                let (accepts, declared) = accepted_flags_of(&repo, command).unwrap_or_else(|| {
                    panic!(
                        "{}: `path_built_by` tells a reader to run\n    {instruction}\nand this \
                         repository has no {command}",
                        source.display()
                    )
                });
                for flag in words.filter(|word| word.starts_with("--")) {
                    assert!(
                        accepts.iter().any(|known| known == flag),
                        "{}: `path_built_by` tells a reader to run\n    {instruction}\nbut no \
                         {declared} of {command} spells {flag}",
                        source.display(),
                    );
                }
                checked += 1;
            }
        }
        assert!(
            checked >= 3,
            "{checked} `path_built_by` instructions found under crates/, and there are three. The \
             scanner stopped matching the call, so this test is checking nothing"
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

    /// The string literal each `path_built_by(..)` call in `text` is handed.
    /// The definition, and any call whose argument is not a literal, have no
    /// `"` where this looks and are skipped rather than mistaken for one.
    fn path_built_by_arguments(text: &str) -> Vec<String> {
        // Spelled in two pieces so that this scanner does not find itself: the
        // needle is the one thing in the tree that must not match.
        const CALL: &str = concat!("path_built_by", "(");
        let mut found = Vec::new();
        let mut rest = text;
        while let Some(at) = rest.find(CALL) {
            rest = &rest[at + CALL.len()..];
            let Some(literal) = rest.trim_start().strip_prefix('"') else {
                continue;
            };
            let mut chars = literal.char_indices();
            while let Some((at, character)) = chars.next() {
                match character {
                    '\\' => drop(chars.next()),
                    '"' => {
                        found.push(literal[..at].to_owned());
                        break;
                    }
                    _ => {}
                }
            }
        }
        found
    }

    /// The flags `command` accepts, or `None` if this repository has no such
    /// command.
    ///
    /// Two shapes, because the two kinds of command declare their flags in two
    /// places. A `tools/*.sh` declares them as `case` arms, the only spelling
    /// that decides what the script does — a script's own `usage:` header is
    /// prose, and prose is what goes stale. `litedoc4` declares them in
    /// `USAGE`, read here as text because `litedoc4` dev-depends on this crate
    /// and so cannot be depended on back.
    ///
    /// The shell half collects every arm in the file, including those of a
    /// `case` inside a function, so the rule is "spelled as an arm somewhere".
    /// That catches the failure this exists for — a removed flag loses its arm
    /// everywhere — and would let through an instruction naming an inner
    /// helper's flag. Deciding which `case` is the command line means guessing
    /// at indentation across the whole of `tools/`, and a guess there would
    /// make the test wrong rather than weak.
    fn accepted_flags_of(repo: &Path, command: &str) -> Option<(Vec<String>, &'static str)> {
        if command == "litedoc4" {
            let lib = std::fs::read_to_string(repo.join("crates/litedoc4/src/lib.rs")).ok()?;
            let usage = lib.split_once("pub const USAGE: &str = \"")?.1;
            return Some((
                usage
                    .split_once("\n\";")?
                    .0
                    .split_whitespace()
                    .map(|word| word.trim_matches(|c| "[](),.|".contains(c)))
                    .filter(|word| word.starts_with("--"))
                    .map(str::to_owned)
                    .collect(),
                "`USAGE` line",
            ));
        }
        let script = std::fs::read_to_string(repo.join(command)).ok()?;
        Some((
            script
                .split_whitespace()
                .filter_map(|word| word.strip_suffix(')'))
                .flat_map(|arm| arm.split('|'))
                .filter(|word| word.starts_with("--"))
                .map(str::to_owned)
                .collect(),
            "`case` arm",
        ))
    }
}
