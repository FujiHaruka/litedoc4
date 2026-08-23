//! The outermost surface of the command line: dispatch, the three ways of
//! asking for the usage, and what a `Failure` costs at the exit.
//!
//! **`main.rs` is the one file no library test reaches.** It is the only place
//! a [`litedoc4::Failure`] becomes an `ExitCode`, and an `ExitCode` exists only
//! in a process that has ended — so everything here starts the real binary.
//! The library tests beside it check which `Failure` a command line produces;
//! what they cannot ask is what the shell then sees.

use litedoc4_testutil::TempDirs;
use litedoc4_testutil::cli::{Cli, code, message, stderr, stdout};

const TEMP: TempDirs = TempDirs::prefixed("litedoc4-cli-surface");

const LITEDOC4: Cli = Cli::at(env!("CARGO_BIN_EXE_litedoc4"));

/// Every subcommand `main.rs` dispatches, spelled out.
///
/// Derived from nothing: the dispatch `match` is the only other place these
/// names live, and a list built from it would agree with it by construction.
/// A subcommand added there and not here is one nobody checked.
const COMMANDS: [&str; 14] = [
    "build",
    "watch",
    "incremental",
    "modules",
    "links",
    "extract",
    "site",
    "render",
    "global",
    "ledger",
    "ownership",
    "merge",
    "impact",
    "prune",
];

/// `--version` is read by a release check, so it says the crate's own version
/// rather than a string beside it that could drift.
#[test]
fn version_prints_the_name_and_the_crate_version() {
    let output = LITEDOC4.run(&["--version"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert_eq!(
        stdout(&output),
        format!("litedoc4 {}\n", env!("CARGO_PKG_VERSION"))
    );
    assert!(stderr(&output).is_empty(), "{}", stderr(&output));
}

/// Three ways of asking for the usage, and they have to be one answer.
///
/// The point is not that each prints something — it is that they print the
/// **same bytes as each other and as `USAGE`**. `cli::help` exists because the
/// `--help` arm had already drifted into three spellings once.
#[test]
fn every_way_of_asking_for_the_usage_prints_the_same_bytes_and_succeeds() {
    let bare = LITEDOC4.run::<&str>(&[]);
    assert_eq!(code(&bare), 0, "{}", stderr(&bare));
    assert_eq!(stdout(&bare), format!("{}\n", litedoc4::USAGE));
    for spelling in ["--help", "-h"] {
        let output = LITEDOC4.run(&[spelling]);
        assert_eq!(code(&output), 0, "{spelling}: {}", stderr(&output));
        assert_eq!(stdout(&output), stdout(&bare), "{spelling}");
    }
}

/// `Failure::Usage` is exit 2, the refusal names what it did not know, and the
/// usage follows it — on **stderr**, so a caller reading stdout for an answer
/// gets nothing rather than a wall of flags.
#[test]
fn an_unknown_subcommand_is_refused_by_name_and_costs_exit_2() {
    let output = LITEDOC4.run(&["frobnicate"]);
    assert_eq!(code(&output), 2, "{}", stderr(&output));
    assert_eq!(
        message(&output),
        "litedoc4: unknown subcommand `frobnicate`"
    );
    assert!(
        stderr(&output).contains("usage: litedoc4 build"),
        "the usage follows the refusal: {}",
        stderr(&output)
    );
    assert!(
        stdout(&output).is_empty(),
        "a refusal writes nothing to stdout: {}",
        stdout(&output)
    );
}

/// `Failure::Failed` is exit 1 and prints **no** usage.
///
/// The distinction is the product's, not a detail: the command line was right
/// and the run did not finish, so the flags are not what the reader should be
/// looking at. A run that printed the usage here would send them to re-read
/// the flags for a missing file.
#[test]
fn a_run_that_could_not_finish_costs_exit_1_and_prints_no_usage() {
    let dir = TEMP.make("no-ledger");
    let missing = dir.path().join("ledger.json");
    let output = LITEDOC4.run(&[
        "ledger".as_ref(),
        "check".as_ref(),
        "--ledger".as_ref(),
        missing.as_os_str(),
    ]);
    assert_eq!(code(&output), 1, "{}", stderr(&output));
    assert!(
        message(&output).contains("ledger.json"),
        "the refusal names the file: {}",
        message(&output)
    );
    assert!(
        !stderr(&output).contains("usage: litedoc4"),
        "a run that failed is not a command line to re-read: {}",
        stderr(&output)
    );
}

/// **Every subcommand answers `--help`, and with the same bytes.**
///
/// `cli::help` exists because this arm had already drifted into three
/// spellings once, and the drift is silent: a subcommand that stops answering
/// still builds, still runs, and only fails the person who typed `--help`.
///
/// Both spellings, because they are separate patterns in every arm that has
/// them — a `match` that lost `-h` passes a check that only asks `--help`.
#[test]
fn every_subcommand_answers_help_with_the_same_usage() {
    let usage = stdout(&LITEDOC4.run(&["--help"]));
    assert!(
        usage.starts_with("usage: litedoc4 build"),
        "the top-level usage is the thing being compared against: {usage}"
    );
    for command in COMMANDS {
        for spelling in ["--help", "-h"] {
            let output = LITEDOC4.run(&[command, spelling]);
            assert_eq!(
                code(&output),
                0,
                "`litedoc4 {command} {spelling}` was refused: {}",
                message(&output)
            );
            assert_eq!(
                stdout(&output),
                usage,
                "`litedoc4 {command} {spelling}` answered with different bytes"
            );
        }
    }
}
