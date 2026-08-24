//! The command-line surface of `litedoc4 incremental --serve`: which flag means
//! what, and which combinations are refused before anything is started. Every
//! case below ends before a process exists, which is the property being tested —
//! a command line that is wrong costs nothing.
//!
//! The protocol and the teardown belong to `src/resident.rs`'s own tests, and
//! agreement between the resident and one-shot paths needs a Lean toolchain and
//! a 3 GB process, so it is a gate.

#![cfg(unix)]

use std::fs;
use std::path::PathBuf;
use std::process::Output;

use litedoc4_testutil::cli::{Cli, code, message, stderr};

const BIN: &str = env!("CARGO_BIN_EXE_litedoc4");

/// Every case here ends before a process exists, so an inherited `EXTRACT_BIN`
/// is the one thing that could carry a command line past a refusal and make a
/// "this flag is required" case pass for the wrong reason. The other test files
/// in this crate deliberately keep the ambient environment.
const LITEDOC4: Cli = Cli::at(BIN).clearing(&["EXTRACT_BIN", "TARGET_REPO", "LAKE"]);

/// 40 lower-case hex digits after `/blob/`, or `incremental` refuses the URL
/// before it ever reaches the flags under test.
const URL: &str = "https://example.invalid/o/r/blob/0123456789abcdef0123456789abcdef01234567";

#[test]
fn serve_and_extractor_are_two_answers_to_the_same_question() {
    let world = World::new("exclusive");
    let refusal = world.run(&["--extractor", "/bin/true", "--serve"]);
    assert_eq!(code(&refusal), 2, "{}", stderr(&refusal));
    assert!(
        message(&refusal).contains("exclusive"),
        "{}",
        message(&refusal)
    );
    let refusal = world.run(&[]);
    assert_eq!(code(&refusal), 2, "{}", stderr(&refusal));
    let said = message(&refusal);
    assert!(said.contains("--extractor"), "{said}");
    assert!(said.contains("--serve"), "{said}");
}

#[test]
fn the_servers_own_flags_are_refused_without_it() {
    let world = World::new("serve-only-flags");
    // Each is a real flag of `litedoc4 extract`, so the refusal owes the caller
    // which command owns it rather than "unknown argument".
    for (flag, value) in [
        ("--extractor-bin", "/tmp/extract"),
        ("--target", "/tmp/repo"),
        ("--lake", "/tmp/lake"),
    ] {
        let refusal = world.run(&["--extractor", "/bin/true", flag, value]);
        assert_eq!(code(&refusal), 2, "{flag}: {}", stderr(&refusal));
        let said = message(&refusal);
        assert!(said.contains("a flag of --serve"), "{flag}: {said}");
    }
    // The resident server's job count is fixed by its start-up `cfg`, so it is
    // this command's to choose exactly when this command starts the server.
    let refusal = world.run(&["--extractor", "/bin/true", "--jobs", "4"]);
    assert_eq!(code(&refusal), 2, "{}", stderr(&refusal));
    let said = message(&refusal);
    assert!(said.contains("--extractor-arg --jobs"), "{said}");
    assert!(said.contains("fixes it at start-up"), "{said}");
}

#[test]
fn the_two_paths_with_no_default_are_required_by_serve() {
    let world = World::new("serve-required");
    let refusal = world.run(&["--serve", "--target", "/tmp/repo"]);
    assert_eq!(code(&refusal), 2, "{}", stderr(&refusal));
    let said = message(&refusal);
    assert!(said.contains("EXTRACT_BIN"), "{said}");
    assert!(
        said.contains("171 MB"),
        "the reason there is no default: {said}"
    );

    let refusal = world.run(&["--serve", "--extractor-bin", "/tmp/extract"]);
    assert_eq!(code(&refusal), 2, "{}", stderr(&refusal));
    let said = message(&refusal);
    assert!(said.contains("TARGET_REPO"), "{said}");
    assert!(
        said.contains("generation"),
        "why the target matters: {said}"
    );
}

#[test]
fn the_two_paths_may_come_from_the_environment_instead() {
    let world = World::new("serve-env");
    // Reaching the *next* refusal — the target does not exist — is the proof
    // both were picked up.
    let refusal = world.run_with_env(
        &["--serve"],
        &[
            ("EXTRACT_BIN", "/tmp/extract"),
            ("TARGET_REPO", "/tmp/no-such-repository"),
        ],
    );
    assert_eq!(code(&refusal), 3, "{}", stderr(&refusal));
    assert!(
        message(&refusal).contains("--target /tmp/no-such-repository"),
        "{}",
        message(&refusal),
    );
}

#[test]
fn an_empty_environment_variable_is_not_a_value() {
    let world = World::new("serve-empty-env");
    // `TARGET_REPO=` in a wrapper script is how a shell spells "I did not set
    // this"; taken literally it would make the target the filesystem root.
    let refusal = world.run_with_env(
        &["--serve", "--extractor-bin", "/tmp/extract"],
        &[("TARGET_REPO", "")],
    );
    assert_eq!(code(&refusal), 2, "{}", stderr(&refusal));
    assert!(
        message(&refusal).contains("TARGET_REPO"),
        "{}",
        message(&refusal)
    );
}

#[test]
fn a_job_count_of_zero_is_refused() {
    let world = World::new("serve-zero-jobs");
    let refusal = world.run(&[
        "--serve",
        "--extractor-bin",
        "/tmp/extract",
        "--target",
        "/tmp/repo",
        "--jobs",
        "0",
    ]);
    assert_eq!(code(&refusal), 2, "{}", stderr(&refusal));
    assert!(
        message(&refusal).contains("at least 1"),
        "{}",
        message(&refusal)
    );
    let refusal = world.run(&["--serve", "--jobs", "many"]);
    assert_eq!(code(&refusal), 2, "{}", stderr(&refusal));
    assert!(
        message(&refusal).contains("not many"),
        "{}",
        message(&refusal)
    );
}

#[test]
fn the_two_flags_that_stayed_retired_say_what_replaced_them() {
    let world = World::new("retired");
    // Both name a server the caller owns, and both are refused for the same
    // reason: correctness comes from the server's olean generation, never from
    // the round number.
    let refusal = world.run(&["--extractor", "/bin/true", "--serve-dir", "/tmp/server"]);
    assert_eq!(code(&refusal), 2, "{}", stderr(&refusal));
    let said = message(&refusal);
    assert!(said.contains("stage 6a"), "{said}");
    assert!(said.contains("generation"), "{said}");

    let refusal = world.run(&["--extractor", "/bin/true", "--serve-from", "2"]);
    assert_eq!(code(&refusal), 2, "{}", stderr(&refusal));
    assert!(
        message(&refusal).contains("round number"),
        "{}",
        message(&refusal)
    );
}

#[test]
fn extract_still_refuses_every_serve_spelling_and_now_says_why() {
    for flag in ["--serve", "--serve-dir", "--serve-from"] {
        let refusal = LITEDOC4.run(&["extract", flag]);
        assert_eq!(code(&refusal), 2, "{flag}: {}", stderr(&refusal));
        let said = message(&refusal);
        assert!(said.contains("incremental --serve"), "{flag}: {said}");
        assert!(
            said.contains("one-shot") || said.contains("one request"),
            "{flag}: {said}",
        );
    }
}

/// A module list and nothing else: every case here is decided before the
/// pipeline opens an IR tree.
struct World {
    root: PathBuf,
    modules: PathBuf,
}

impl World {
    fn new(what: &str) -> Self {
        use std::sync::atomic::{AtomicU32, Ordering};
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let root = std::env::temp_dir().join(format!(
            "litedoc4-resident-cli-{}-{}-{what}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("the temporary directory is creatable");
        let modules = root.join("modules.txt");
        fs::write(&modules, "Pkg.A\nPkg.B\n").expect("writable");
        Self { root, modules }
    }

    fn base(&self) -> Vec<String> {
        [
            "incremental",
            "--ir",
            "ir",
            "--pages",
            "pages",
            "--ledger",
            "ledger.json",
            "--work",
            "work",
            "--modules",
            &self.modules.display().to_string(),
            "--source-url",
            URL,
            "--link-index",
            "link-index.lidx",
            "--state",
            "state",
        ]
        .iter()
        .map(|arg| (*arg).to_owned())
        .collect()
    }

    fn run(&self, extra: &[&str]) -> Output {
        self.run_with_env(extra, &[])
    }

    fn run_with_env(&self, extra: &[&str], env: &[(&str, &str)]) -> Output {
        let mut args = self.base();
        args.extend(extra.iter().map(|arg| (*arg).to_owned()));
        LITEDOC4.run_with_env(&args, env)
    }
}

impl Drop for World {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
