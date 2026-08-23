//! Starting the command-line binary and reading what it said.
//!
//! Five files in `crates/litedoc4/tests/` — `build.rs`, `site.rs`,
//! `incremental.rs`, `extract.rs`, `resident.rs` — drive the binary as a child
//! process. Each of the five files used to carry its own `litedoc4()`,
//! `stderr()` and `code()`: five copies of the first, in three signatures, and
//! five byte-identical copies of each of the other two 【実測 2026-08-23】,
//! before they were consolidated into this crate.
//!
//! WHY THE PATH IS AN ARGUMENT AND NOT AN `env!` HERE
//!   Cargo defines `CARGO_BIN_EXE_<name>` only when compiling a test target of
//!   the package that declares that binary. This crate declares none, so
//!   `env!("CARGO_BIN_EXE_litedoc4")` here would not compile — the name has to
//!   be handed in. It is a `&'static str`, so the binding stays a `const` — and
//!   each of the five files still says out loud which binary it runs and what
//!   it runs it in:
//!
//! ```
//! use litedoc4_testutil::cli::Cli;
//!
//! // In `crates/litedoc4/tests/*.rs` this is `env!("CARGO_BIN_EXE_litedoc4")`.
//! const BIN: &str = "/path/to/litedoc4";
//!
//! const LITEDOC4: Cli = Cli::at(BIN);
//! const RESIDENT: Cli = Cli::at(BIN).clearing(&["EXTRACT_BIN", "TARGET_REPO", "LAKE"]);
//! ```
//!
//! WHY THE ARGUMENTS ARE GENERIC
//!   The three signatures this replaced were `&[&str]` (build / site /
//!   incremental), `&[String]` (extract) and `&[String]` plus an environment
//!   (resident). `S: AsRef<OsStr>` takes all of them, which is what let seven
//!   call sites drop a `let borrowed: Vec<&str> = args.iter().map(String::as_str)`
//!   that existed only to satisfy the narrower one.

use std::ffi::OsStr;
use std::process::{Command, Output};

/// A binary to start, and the environment it is started in.
///
/// Bound once per test file as a `const`, so that a call site reads
/// `LITEDOC4.run(&[…])` and cannot pick a different binary or a different
/// environment without the difference being written at the top of the file.
pub struct Cli {
    /// The executable. `&'static str` and not `PathBuf` so that the binding
    /// can be a `const` alongside the `env!` that produced it.
    bin: &'static str,
    /// Names removed from the child's environment before it starts.
    cleared: &'static [&'static str],
}

impl Cli {
    /// The binary at `bin`, started with this process's environment unchanged.
    pub const fn at(bin: &'static str) -> Self {
        Self { bin, cleared: &[] }
    }

    /// The same binary, with `vars` removed from the child's environment
    /// before it starts. `vars` is the whole list, not an addition to one.
    ///
    /// **Opt-in, per binding, and deliberately not the default.** Exactly one
    /// of the five files asks for it: `crates/litedoc4/tests/resident.rs`
    /// clears `EXTRACT_BIN`, `TARGET_REPO` and `LAKE`, so that a developer who
    /// has exported one of them cannot make a "this flag is required" case pass
    /// for the wrong reason — every case in that file ends before a process
    /// exists, and an inherited value would be the one thing able to carry it
    /// further.
    ///
    /// Clearing them for everyone would be the reverse of that: the other four
    /// files would stop seeing an ambient `EXTRACT_BIN` **and stop being able
    /// to**, which is a change to what they test rather than to how they run.
    /// Naming the variables at the one `const` that wants them is what keeps
    /// the difference visible where it applies.
    ///
    /// A variable passed to [`Self::run_with_env`] still wins: the removals
    /// happen first, so a case may put back exactly what it means to test.
    pub const fn clearing(self, vars: &'static [&'static str]) -> Self {
        Self {
            bin: self.bin,
            cleared: vars,
        }
    }

    /// Run to completion with `args`, and hand back everything it produced.
    pub fn run<S: AsRef<OsStr>>(&self, args: &[S]) -> Output {
        self.run_with_env(args, &[])
    }

    /// [`Self::run`] with `env` set in the child on top of what it inherits.
    pub fn run_with_env<S: AsRef<OsStr>>(&self, args: &[S], env: &[(&str, &str)]) -> Output {
        let mut command = Command::new(self.bin);
        command.args(args);
        // Removals before additions: see [`Self::clearing`].
        for name in self.cleared {
            command.env_remove(name);
        }
        for (name, value) in env {
            command.env(name, value);
        }
        command.output().expect("the binary under test runs")
    }
}

/// Everything the child wrote to its standard error.
pub fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// Everything the child wrote to its standard output.
pub fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// The exit code, with the process's own diagnostics attached.
///
/// A test that only says "expected 2, got 1" makes the reader run the command
/// by hand. A process that never had an exit code — killed by a signal — is a
/// panic here rather than a number, because every caller compares it against
/// one of the documented exits.
pub fn code(output: &Output) -> i32 {
    output
        .status
        .code()
        .unwrap_or_else(|| panic!("the process was killed by a signal: {}", stderr(output)))
}

/// The refusal on its own: everything before the first blank line of
/// [`stderr`].
///
/// `main` prints `litedoc4: <message>\n\n<USAGE>`, and the usage text names
/// every flag — so an assertion over the whole of stderr is an assertion about
/// `USAGE` wearing a refusal's name.
pub fn message(output: &Output) -> String {
    stderr(output)
        .split("\n\n")
        .next()
        .unwrap_or_default()
        .to_owned()
}

// Every test below starts `/bin/sh`, because the promises being checked are
// about a real child process and there is no binary in this package to point
// at. `crates/litedoc4/tests/{extract,resident,incremental}.rs` are `#![cfg(unix)]`
// for the same reason; `cargo test --workspace` runs on `ubuntu-latest`
// (`.github/workflows/ci.yml`), so nothing is skipped where it is checked.
#[cfg(all(test, unix))]
mod tests {
    use super::*;

    /// A shell, used as a stand-in for the binary under test: this crate has no
    /// binary of its own and cannot name one belonging to another package (see
    /// the module header).
    const SH: Cli = Cli::at("/bin/sh");

    /// The variable is read **by the child**, not off the struct. Asserting on
    /// `Cli`'s fields would pass just as well if `Command` were never told
    /// about them, which is the failure this is here to catch.
    #[test]
    fn run_with_env_sets_the_variable_in_the_child() {
        let output = SH.run_with_env(
            &["-c", "printf %s \"$LITEDOC4_TESTUTIL_PROBE\""],
            &[("LITEDOC4_TESTUTIL_PROBE", "set-by-the-test")],
        );
        assert_eq!(code(&output), 0, "{}", stderr(&output));
        assert_eq!(stdout(&output), "set-by-the-test");
    }

    /// `clearing` takes a variable **out** of an environment that has it.
    ///
    /// `CARGO_PKG_NAME` is set by cargo in this process for every test run, so
    /// the parent side of the comparison needs no `set_var` — which is
    /// `unsafe` in edition 2024 and would race the harness's other threads.
    #[test]
    fn clearing_removes_a_variable_the_parent_has() {
        assert_eq!(
            std::env::var("CARGO_PKG_NAME").as_deref(),
            Ok("litedoc4-testutil"),
            "cargo no longer exports the variable this test inherits",
        );
        let script = &["-c", "printf %s \"${CARGO_PKG_NAME-<unset>}\""];

        let inherited = SH.run(script);
        assert_eq!(stdout(&inherited), "litedoc4-testutil");

        let cleared = Cli::at("/bin/sh").clearing(&["CARGO_PKG_NAME"]).run(script);
        assert_eq!(stdout(&cleared), "<unset>");
    }

    /// A variable named by both wins where the case sets it: the removals run
    /// first, so `resident.rs` can clear `LAKE` for every run and still hand it
    /// to the one case whose subject is that it was set.
    #[test]
    fn a_cleared_variable_can_be_put_back_by_the_case() {
        let output = Cli::at("/bin/sh")
            .clearing(&["CARGO_PKG_NAME"])
            .run_with_env(
                &["-c", "printf %s \"${CARGO_PKG_NAME-<unset>}\""],
                &[("CARGO_PKG_NAME", "put-back")],
            );
        assert_eq!(stdout(&output), "put-back");
    }

    /// Both argument shapes the five files use reach the child, through one
    /// function.
    #[test]
    fn the_arguments_reach_the_child_as_both_str_and_string() {
        let borrowed = SH.run(&["-c", "printf %s \"$0\"", "from-a-str"]);
        assert_eq!(stdout(&borrowed), "from-a-str");

        let owned: Vec<String> = ["-c", "printf %s \"$0\"", "from-a-string"]
            .iter()
            .map(|arg| (*arg).to_owned())
            .collect();
        assert_eq!(stdout(&SH.run(&owned)), "from-a-string");
    }

    /// The three readers, on one child that used all three channels.
    #[test]
    fn stdout_stderr_and_code_read_the_three_things_a_run_produces() {
        let output = SH.run(&["-c", "printf out; printf err >&2; exit 3"]);
        assert_eq!(stdout(&output), "out");
        assert_eq!(stderr(&output), "err");
        assert_eq!(code(&output), 3);
    }

    /// `message` cuts at the first blank line, which is where `main` puts the
    /// usage text — and leaves a refusal that has no usage after it whole.
    #[test]
    fn message_is_the_refusal_without_the_usage_after_it() {
        let output = SH.run(&[
            "-c",
            "printf 'litedoc4: --ir is required\\n\\nUsage: litedoc4 …\\n' >&2",
        ]);
        assert_eq!(message(&output), "litedoc4: --ir is required");

        let whole = SH.run(&["-c", "printf 'litedoc4: one line only\\n' >&2"]);
        assert_eq!(message(&whole), "litedoc4: one line only\n");

        let silent = SH.run(&["-c", "true"]);
        assert_eq!(message(&silent), "");
    }
}
