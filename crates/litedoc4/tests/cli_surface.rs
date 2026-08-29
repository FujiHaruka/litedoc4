//! `main.rs` is the one file no library test reaches: it is the only place a
//! [`litedoc4::Failure`] becomes an `ExitCode`, and an `ExitCode` exists only
//! in a process that has ended. So every case here starts the real binary and
//! asks what the shell sees, which is the one thing the library tests beside
//! it cannot.

use litedoc4_testutil::TempDirs;
use litedoc4_testutil::cli::{Cli, code, message, stderr, stdout};

const TEMP: TempDirs = TempDirs::prefixed("litedoc4-cli-surface");

const LITEDOC4: Cli = Cli::at(env!("CARGO_BIN_EXE_litedoc4"));

/// Spelled out rather than derived: the dispatch `match` is the only other
/// place these names live, so a list built from it would agree with it by
/// construction and a subcommand added there and not here is one nobody
/// checked.
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

/// The release check reads `--version`, so it has to be the crate's own
/// version and not a literal beside it that could drift.
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

/// The front door is [`litedoc4::SUMMARY`], not [`litedoc4::USAGE`]: only
/// `build` and `watch` are things a consumer runs, and `--help-all` is where
/// the other twelve keep their command lines.
#[test]
fn every_way_of_asking_for_the_usage_prints_the_same_bytes_and_succeeds() {
    let bare = LITEDOC4.run::<&str>(&[]);
    assert_eq!(code(&bare), 0, "{}", stderr(&bare));
    assert_eq!(stdout(&bare), format!("{}\n", litedoc4::SUMMARY));
    for spelling in ["--help", "-h"] {
        let output = LITEDOC4.run(&[spelling]);
        assert_eq!(code(&output), 0, "{spelling}: {}", stderr(&output));
        assert_eq!(stdout(&output), stdout(&bare), "{spelling}");
    }

    let all = LITEDOC4.run(&["--help-all"]);
    assert_eq!(code(&all), 0, "{}", stderr(&all));
    assert_eq!(stdout(&all), format!("{}\n", litedoc4::USAGE));
}

/// A subcommand the front door does not name is one nobody finds. It does not
/// have to be named as a synopsis — being named at all, next to the sentence
/// that says where its command line is, is the whole obligation.
#[test]
fn the_summary_names_every_subcommand_and_says_where_the_rest_of_them_live() {
    let summary = stdout(&LITEDOC4.run(&["--help"]));
    for command in COMMANDS {
        assert!(
            summary.contains(command),
            "`{command}` is reachable from the dispatch and named nowhere a reader looks: {summary}"
        );
    }
    assert!(
        summary.contains("--help-all"),
        "the twelve are hidden with no way back to them: {summary}"
    );
}

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

/// Both spellings, because they are separate patterns in every arm that has
/// them: a `match` that lost `-h` passes a check that only asks `--help`.
#[test]
fn every_subcommand_answers_help_with_the_same_usage() {
    let usage = stdout(&LITEDOC4.run(&["--help-all"]));
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

/// The wording is not compared: `ledger` takes `--frobnicate` where a
/// subcommand belongs and refuses it as one. What all fourteen owe is the exit
/// code, quoting back what they were given, and silence on stdout.
#[test]
fn every_subcommand_refuses_an_unknown_argument_and_quotes_it() {
    for command in COMMANDS {
        let output = LITEDOC4.run(&[command, "--frobnicate"]);
        assert_eq!(
            code(&output),
            2,
            "`litedoc4 {command} --frobnicate` was not refused: {}",
            message(&output)
        );
        assert!(
            message(&output).contains("--frobnicate"),
            "`litedoc4 {command}`'s refusal does not quote it: {}",
            message(&output)
        );
        assert!(
            stdout(&output).is_empty(),
            "`litedoc4 {command}` wrote to stdout while refusing: {}",
            stdout(&output)
        );
    }
}
