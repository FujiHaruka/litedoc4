//! `litedoc4 ledger` — the three subcommands' own command line, and what
//! `check` and `touch` say.
//!
//! **What is new here is the subcommand layer, not the answers.**
//! `litedoc4-incr`'s own tests hold the hashing, the key comparison and the
//! entry invalidation; `crates/litedoc4/tests/incremental.rs` drives
//! `ledger build` as the seed of every incremental round. What none of them
//! reaches is `crates/litedoc4/src/ledger.rs`: the one flat parse that then
//! dispatches on the subcommand, and the six lines `check` prints.
//!
//! Two of those are the reason this file exists rather than a unit test:
//!
//! - **`LEDGER_FLAGS` is a refusal by name.** One parse accepts every flag for
//!   all three subcommands and reads it for one, so without the table
//!   `ledger touch --concurrency 9` runs, ignores the number and says nothing.
//!   A flag that does nothing is the shape this project keeps finding.
//! - **`ledger touch` had no test at all.** It is the only way this repository
//!   can express "module M changed" without writing to a package it is not
//!   allowed to write to (`tools/watch-gate.sh`, `tools/build-gate.sh`), so the
//!   round trip below — touch, then check — is what those gates rest on.

use std::fs;
use std::path::{Path, PathBuf};

use litedoc4_testutil::TempDirs;
use litedoc4_testutil::cli::{Cli, code, message, stdout};

const TEMP: TempDirs = TempDirs::prefixed("litedoc4-ledger");

const LITEDOC4: Cli = Cli::at(env!("CARGO_BIN_EXE_litedoc4"));

// ------------------------------------------------------------------ the world

/// The package a ledger is built over: the sources `--modules` names and the
/// oleans `--target` holds.
///
/// Four modules rather than one, because `check`'s counts line reports three
/// numbers at once and a fixture with one module cannot tell "1 changed" from
/// "1 added".
const MODULES: [&str; 4] = ["Pkg", "Pkg.A", "Pkg.B", "Pkg.C"];

/// One package, one ledger, run over and over.
struct World {
    dir: litedoc4_testutil::TempDir,
    target: PathBuf,
    ledger: PathBuf,
    modules: PathBuf,
}

impl World {
    fn new(what: &str) -> Self {
        let dir = TEMP.make(what);
        let world = Self {
            target: dir.path().join("repo"),
            ledger: dir.path().join("ledger.json"),
            modules: dir.path().join("modules.txt"),
            dir,
        };
        put(
            &world.target.join("lean-toolchain"),
            b"leanprover/lean4:v4.31.0\n",
        );
        put(
            &world.target.join("lake-manifest.json"),
            br#"{"version":"1.1.0","packages":[]}"#,
        );
        for module in MODULES {
            world.set_olean(module, &format!("olean:{module}:0"));
        }
        world.list(&MODULES);
        world
    }

    /// The olean the ledger hashes. **Its bytes are the whole subject**: the
    /// ledger is a content hash, so an mtime does not move it and neither does
    /// anything else this fixture could do to the file.
    fn set_olean(&self, module: &str, body: &str) {
        put(
            &self.target.join(format!(
                ".lake/build/lib/lean/{}.olean",
                module.replace('.', "/")
            )),
            body.as_bytes(),
        );
    }

    /// `--modules`: which modules the package is said to have *now*.
    fn list(&self, modules: &[&str]) {
        let mut body = String::new();
        for module in modules {
            body.push_str(module);
            body.push('\n');
        }
        put(&self.modules, body.as_bytes());
    }

    /// The ledger over the package as it is now. Nothing is asserted about what
    /// `build` prints: `tests/incremental.rs` drives this same subcommand as the
    /// seed of every round, and a second check of its counts line would be a
    /// second reader of one answer rather than a check of another.
    fn build(&self) {
        let output = LITEDOC4.run(&[
            "ledger".as_ref(),
            "build".as_ref(),
            "--modules".as_ref(),
            self.modules.as_os_str(),
            "--target".as_ref(),
            self.target.as_os_str(),
            "--out".as_ref(),
            self.ledger.as_os_str(),
        ]);
        assert_eq!(
            code(&output),
            0,
            "ledger build: {}",
            litedoc4_testutil::cli::stderr(&output)
        );
    }

    /// `ledger check`, with `extra` appended. Handed back whole — stdout,
    /// stderr and the exit — because half of what is asserted below is a
    /// refusal.
    fn check(&self, extra: &[&str]) -> std::process::Output {
        let mut args: Vec<String> = vec![
            "ledger".to_owned(),
            "check".to_owned(),
            "--ledger".to_owned(),
            self.ledger.display().to_string(),
            "--modules".to_owned(),
            self.modules.display().to_string(),
        ];
        args.extend(extra.iter().map(|arg| (*arg).to_owned()));
        LITEDOC4.run(&args)
    }
}

fn put(path: &Path, body: &[u8]) {
    fs::create_dir_all(path.parent().expect("a parent")).expect("writable");
    fs::write(path, body).expect("writable");
}

/// The lines `check` indents, which are the ones about a module or a key.
///
/// Read by prefix rather than by position: `check` opens with whatever
/// `resolve_external_links` has to say about a run with no `--root`, and a
/// fixture that asserted on the first line would be asserting on that note.
fn indented(log: &str) -> Vec<&str> {
    log.lines().filter(|line| line.starts_with("  ")).collect()
}

// ---------------------------------------------------------------- the refusals

/// The two ways of naming a subcommand that is not one, and the flag table that
/// decides which subcommand a flag belongs to.
///
/// The last of the three is the one with a history: `ledger` parses one flat set
/// of flags and *then* dispatches, so before [`LEDGER_FLAGS`]
/// `ledger touch --concurrency 9` ran, ignored the number and said nothing. The
/// refusal names both the flag and the subcommands that do read it, because
/// "unknown argument" would send the reader looking for a typo in a flag that
/// exists.
#[test]
fn ledger_refuses_no_subcommand_an_unknown_one_and_a_flag_that_belongs_to_another() {
    let world = World::new("ledger-refusals");

    let bare = LITEDOC4.run(&["ledger"]);
    assert_eq!(code(&bare), 2, "{}", litedoc4_testutil::cli::stderr(&bare));
    assert_eq!(
        message(&bare),
        "litedoc4: ledger needs a subcommand: build, check or touch",
    );

    let unknown = LITEDOC4.run(&["ledger", "rebuild"]);
    assert_eq!(code(&unknown), 2);
    assert_eq!(
        message(&unknown),
        "litedoc4: unknown ledger subcommand `rebuild`",
        "a subcommand nobody has is not the same refusal as a flag nobody has",
    );

    let misplaced = LITEDOC4.run(&[
        "ledger".as_ref(),
        "touch".as_ref(),
        "--ledger".as_ref(),
        world.ledger.as_os_str(),
        "--module".as_ref(),
        "Pkg".as_ref(),
        "--concurrency".as_ref(),
        "9".as_ref(),
    ]);
    assert_eq!(code(&misplaced), 2);
    assert_eq!(
        message(&misplaced),
        "litedoc4: --concurrency is not a flag of `ledger touch`: it belongs to `ledger build` \
         / `ledger check`",
        "a flag accepted by the parse and read by nobody is the failure this table exists for",
    );

    // The two "this subcommand needs these" refusals, which is what a caller
    // that named the subcommand and nothing else sees.
    let no_ledger = LITEDOC4.run(&["ledger", "check"]);
    assert_eq!(code(&no_ledger), 2);
    assert_eq!(
        message(&no_ledger),
        "litedoc4: ledger check needs --ledger <ledger.json>",
    );

    let half_a_touch = LITEDOC4.run(&[
        "ledger".as_ref(),
        "touch".as_ref(),
        "--ledger".as_ref(),
        world.ledger.as_os_str(),
    ]);
    assert_eq!(code(&half_a_touch), 2);
    assert_eq!(
        message(&half_a_touch),
        "litedoc4: ledger touch needs --ledger <ledger.json> and --module <Module>",
    );

    let bare_build = LITEDOC4.run(&["ledger", "build"]);
    assert_eq!(code(&bare_build), 2);
    assert_eq!(
        message(&bare_build),
        "litedoc4: ledger build needs --modules <file>, --target <repo> and --out <ledger.json>",
    );

    // The two arms every subcommand in this repository shares.
    // `crates/litedoc4/tests/queries.rs` states them for the five query
    // subcommands and **does not reach `ledger`**, which is the same gap the
    // `--help` arm had drifted into three spellings through before `cli::help`
    // existed.
    let help = LITEDOC4.run(&["ledger", "check", "--help"]);
    assert_eq!(code(&help), 0, "{}", litedoc4_testutil::cli::stderr(&help));
    assert_eq!(stdout(&help), format!("{}\n", litedoc4::USAGE));

    let unknown_flag = LITEDOC4.run(&["ledger", "check", "--colour"]);
    assert_eq!(code(&unknown_flag), 2);
    assert_eq!(
        message(&unknown_flag),
        "litedoc4: unknown argument `--colour`",
        "a flag nobody has is refused by name, not by the subcommand it was passed to",
    );
}

// ------------------------------------------------------------------- `check`

/// **The three states a module can be in, in one run.**
///
/// They are separate lines because they are separate things to do: a *changed*
/// module is re-extracted, an *added* one has never been extracted, and a
/// *removed* one has a page to delete. A run that reported three numbers and no
/// names would leave a caller unable to act on any of them, and this is exactly
/// what `tools/build-gate.sh` reads.
#[test]
fn check_counts_and_names_the_changed_the_added_and_the_removed() {
    let world = World::new("ledger-three-states");
    world.build();

    let quiet = world.check(&[]);
    assert_eq!(
        code(&quiet),
        0,
        "{}",
        litedoc4_testutil::cli::stderr(&quiet)
    );
    assert!(
        stdout(&quiet)
            .contains("check 4 modules (sha256, concurrency 1): 0 changed, 0 added, 0 removed"),
        "a ledger built from this very tree reported work: {}",
        stdout(&quiet),
    );
    assert_eq!(
        indented(&stdout(&quiet)),
        Vec::<&str>::new(),
        "nothing moved and the run still named a module: {}",
        stdout(&quiet),
    );

    // One module's olean rewritten, one module that the ledger has never seen,
    // one that has left the package.
    world.set_olean("Pkg.A", "olean:Pkg.A:1");
    world.set_olean("Pkg.New", "olean:Pkg.New:0");
    world.list(&["Pkg", "Pkg.A", "Pkg.B", "Pkg.New"]);

    // The three files the next stage reads, plus the diagnostic. They are asked
    // for here rather than in a case of their own because the point is that they
    // are **the same answer as the printed one** — a run whose file and whose
    // log disagreed would have the extractor and the reader working from two
    // different sets.
    let changed_out = world.dir.path().join("changed.txt");
    let removed_out = world.dir.path().join("removed.txt");
    let render_all_out = world.dir.path().join("render-all.txt");
    let timings = world.dir.path().join("timings.jsonl");
    let moved = world.check(&[
        "--changed-out",
        &changed_out.display().to_string(),
        "--removed-out",
        &removed_out.display().to_string(),
        "--render-all-out",
        &render_all_out.display().to_string(),
        "--timings",
        &timings.display().to_string(),
    ]);
    assert_eq!(
        code(&moved),
        0,
        "{}",
        litedoc4_testutil::cli::stderr(&moved)
    );
    let log = stdout(&moved);
    assert!(
        log.contains("check 4 modules (sha256, concurrency 1): 1 changed, 1 added, 1 removed"),
        "the counts line: {log}",
    );
    assert_eq!(
        indented(&log),
        ["  changed  Pkg.A", "  added    Pkg.New", "  removed  Pkg.C"],
        "the three states, named and in that order — a count a caller cannot act on is not \
         an answer, and `Pkg.B` did not move: {log}",
    );

    // `--changed-out` is the **re-extract** set, which is `changed ∪ added` —
    // not the `changed` line alone. A stage handed the printed `changed` list
    // instead would leave `Pkg.New` without IR and its page unwritten.
    assert_eq!(
        fs::read_to_string(&changed_out).expect("--changed-out was written"),
        "Pkg.A\nPkg.New\n",
    );
    assert_eq!(
        fs::read_to_string(&removed_out).expect("--removed-out was written"),
        "Pkg.C\n",
    );
    assert_eq!(
        fs::read_to_string(&render_all_out).expect("--render-all-out was written"),
        "",
        "an empty file is `the render set follows from the IR diff as usual`, and neither key \
         moved here",
    );
    let record = fs::read_to_string(&timings).expect("--timings was written");
    assert!(
        record.lines().count() == 1 && record.contains("\"changed\":1"),
        "the timings record is one JSON line describing this run: {record}",
    );
}

/// **The two keys, and the sentence each of them ends in.**
///
/// They are different answers and the difference is the whole of the incremental
/// design: a moved *extract* key means every module's IR is invalid whatever its
/// own hash says, and a moved *render* key means the IR is fine and every page
/// has to be written again. A run that printed one for the other would either
/// re-import Lean for nothing or serve pages built against inputs that have
/// moved.
#[test]
fn check_says_which_key_moved_and_what_that_costs() {
    let world = World::new("ledger-keys");
    world.build();

    // `leanToolchain` is one of `extractKey`'s five values: a different compiler
    // wrote the oleans, so no module's IR can be trusted.
    put(
        &world.target.join("lean-toolchain"),
        b"leanprover/lean4:v4.33.0\n",
    );
    let extract = world.check(&[]);
    assert_eq!(
        code(&extract),
        0,
        "{}",
        litedoc4_testutil::cli::stderr(&extract)
    );
    assert!(
        stdout(&extract).contains("  extract key changed (leanToolchain) -> all 4 re-extracted"),
        "the run did not say which key invalidated every module: {}",
        stdout(&extract),
    );

    // The render key is the other half: the IR is untouched and the pages are
    // not, so the re-extract count on this line is zero.
    put(
        &world.target.join("lean-toolchain"),
        b"leanprover/lean4:v4.31.0\n",
    );
    let render = world.check(&["--source-url", "https://example.invalid/o/r/blob/deadbeef"]);
    assert_eq!(
        code(&render),
        0,
        "{}",
        litedoc4_testutil::cli::stderr(&render)
    );
    assert!(
        stdout(&render).contains("  render key changed (sourceUrl) -> re-render all, re-extract 0"),
        "a moved render key must re-render everything and re-extract nothing: {}",
        stdout(&render),
    );
}

// ------------------------------------------------------------------- `touch`

/// **The round trip the gates rest on**: `touch` then `check` reports that
/// module, and only it, as *changed*.
///
/// Three things are being asserted and each is a separate way for the injection
/// to be useless:
///
/// - **the olean is not written.** The measurement target must not be modified
///   (CLAUDE.md), which is the entire reason this subcommand exists rather than
///   the gates rewriting a file;
/// - **it comes back as `changed`, not as `added`.** The entry is invalidated
///   rather than deleted, and a deleted entry would be reported as an addition —
///   which is not what an edit produces, and selects a different render set;
/// - **`--out` puts the injection somewhere else and leaves the original
///   alone**, so a gate can inject into a copy of a ledger it did not write.
#[test]
fn touch_makes_the_next_check_report_that_module_as_changed_and_leaves_the_olean_alone() {
    let world = World::new("ledger-touch");
    world.build();
    let olean = world.target.join(".lake/build/lib/lean/Pkg/B.olean");
    let before = fs::read(&olean).expect("the olean is there");

    let touched = LITEDOC4.run(&[
        "ledger".as_ref(),
        "touch".as_ref(),
        "--ledger".as_ref(),
        world.ledger.as_os_str(),
        "--module".as_ref(),
        "Pkg.B".as_ref(),
    ]);
    assert_eq!(
        code(&touched),
        0,
        "{}",
        litedoc4_testutil::cli::stderr(&touched)
    );
    assert!(
        stdout(&touched).starts_with("touched Pkg.B in ")
            && stdout(&touched).contains("injected change, the olean is untouched"),
        "the line has to say what was injected and where: {}",
        stdout(&touched),
    );
    assert_eq!(
        fs::read(&olean).expect("the olean is there"),
        before,
        "the olean moved, which is the one thing this subcommand exists not to do",
    );

    let after = world.check(&[]);
    assert_eq!(
        code(&after),
        0,
        "{}",
        litedoc4_testutil::cli::stderr(&after)
    );
    let log = stdout(&after);
    assert!(
        log.contains("check 4 modules (sha256, concurrency 1): 1 changed, 0 added, 0 removed"),
        "the injected change did not come back as exactly one changed module: {log}",
    );
    assert_eq!(
        indented(&log),
        ["  changed  Pkg.B"],
        "an injected change has to come back as `changed` and name the module it was \
         injected for: {log}",
    );

    // `--out`: the same injection, written somewhere else. Without it a gate
    // that wanted to keep the ledger it was handed would have to copy the file
    // itself and hope the two spellings of "where the ledger is" agree.
    let elsewhere = world.dir.path().join("injected/ledger.json");
    let copied = LITEDOC4.run(&[
        "ledger".as_ref(),
        "touch".as_ref(),
        "--ledger".as_ref(),
        world.ledger.as_os_str(),
        "--module".as_ref(),
        "Pkg.A".as_ref(),
        "--out".as_ref(),
        elsewhere.as_os_str(),
    ]);
    assert_eq!(
        code(&copied),
        0,
        "{}",
        litedoc4_testutil::cli::stderr(&copied)
    );
    let original = fs::read_to_string(&world.ledger).expect("the ledger is there");
    assert!(
        !original.contains("injected-change:injected-change")
            && original.matches("injected-change").count() == 1,
        "--out wrote back into the ledger it was reading from",
    );
    assert_eq!(
        fs::read_to_string(&elsewhere)
            .expect("--out was written")
            .matches("injected-change")
            .count(),
        2,
        "the second injection is not in the file --out named",
    );

    // A module the ledger has never heard of is **exit 3**, not a silent
    // success: a gate that injected a change into a name it misspelled would
    // otherwise wait for a rebuild that has no reason to happen.
    let nobody = LITEDOC4.run(&[
        "ledger".as_ref(),
        "touch".as_ref(),
        "--ledger".as_ref(),
        world.ledger.as_os_str(),
        "--module".as_ref(),
        "Pkg.Ghost".as_ref(),
    ]);
    assert_eq!(
        code(&nobody),
        3,
        "{}",
        litedoc4_testutil::cli::stderr(&nobody)
    );
    assert!(
        message(&nobody).contains("Pkg.Ghost"),
        "the refusal names the module that is not there: {}",
        message(&nobody),
    );
}
