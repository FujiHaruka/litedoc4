//! Starting the command-line binary and reading what it said.
//!
//! The path is an argument rather than an `env!` here because cargo defines
//! `CARGO_BIN_EXE_<name>` only when compiling a test target of the package that
//! declares that binary, and this crate declares none. It stays a
//! `&'static str` so the caller's binding can be a `const`:
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

use std::ffi::OsStr;
use std::process::{Command, Output};

pub struct Cli {
    /// `&'static str` and not `PathBuf` so that the binding can be a `const`
    /// alongside the `env!` that produced it.
    bin: &'static str,
    cleared: &'static [&'static str],
}

impl Cli {
    pub const fn at(bin: &'static str) -> Self {
        Self { bin, cleared: &[] }
    }

    /// `vars` is the whole list of names removed from the child's environment,
    /// not an addition to one.
    ///
    /// Opt-in per binding and deliberately not the default: a file that clears
    /// `EXTRACT_BIN` stops being able to see an ambient one, which is a change
    /// to what it tests rather than to how it runs. A variable passed to
    /// [`Self::run_with_env`] still wins — the removals happen first, so a case
    /// may put back exactly what it means to test.
    pub const fn clearing(self, vars: &'static [&'static str]) -> Self {
        Self {
            bin: self.bin,
            cleared: vars,
        }
    }

    pub fn run<S: AsRef<OsStr>>(&self, args: &[S]) -> Output {
        self.run_with_env(args, &[])
    }

    /// [`Self::run`] with `env` set in the child on top of what it inherits.
    pub fn run_with_env<S: AsRef<OsStr>>(&self, args: &[S], env: &[(&str, &str)]) -> Output {
        let mut command = Command::new(self.bin);
        command.args(args);
        for name in self.cleared {
            command.env_remove(name);
        }
        for (name, value) in env {
            command.env(name, value);
        }
        command.output().expect("the binary under test runs")
    }
}

pub fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

pub fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// The exit code, with the process's own diagnostics attached.
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
// at. `cargo test --workspace` runs on `ubuntu-latest`
// (`.github/workflows/ci.yml`), so nothing is skipped where it is checked.
#[cfg(all(test, unix))]
mod tests {
    use super::*;

    const SH: Cli = Cli::at("/bin/sh");

    #[test]
    fn run_with_env_sets_the_variable_in_the_child() {
        let output = SH.run_with_env(
            &["-c", "printf %s \"$LITEDOC4_TESTUTIL_PROBE\""],
            &[("LITEDOC4_TESTUTIL_PROBE", "set-by-the-test")],
        );
        assert_eq!(code(&output), 0, "{}", stderr(&output));
        assert_eq!(stdout(&output), "set-by-the-test");
    }

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

    #[test]
    fn stdout_stderr_and_code_read_the_three_things_a_run_produces() {
        let output = SH.run(&["-c", "printf out; printf err >&2; exit 3"]);
        assert_eq!(stdout(&output), "out");
        assert_eq!(stderr(&output), "err");
        assert_eq!(code(&output), 3);
    }

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
