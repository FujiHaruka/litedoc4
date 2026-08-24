//! `litedoc4 ledger` — the three subcommands' own command line, and what
//! `check` and `touch` say. The answers themselves belong to `litedoc4-incr`'s
//! tests; the subcommand layer is what only exists here.
//!
//! `ledger touch` is the only way this repository can express "module M changed"
//! without writing to a package it is not allowed to write to, so the round trip
//! below — touch, then check — is what `tools/watch-gate.sh` and
//! `tools/build-gate.sh` rest on.

use std::fs;
use std::path::{Path, PathBuf};

use litedoc4_testutil::TempDirs;
use litedoc4_testutil::cli::{Cli, code, message, stdout};

const TEMP: TempDirs = TempDirs::prefixed("litedoc4-ledger");

const LITEDOC4: Cli = Cli::at(env!("CARGO_BIN_EXE_litedoc4"));

/// Four modules rather than one, because `check`'s counts line reports three
/// numbers at once and a fixture with one module cannot tell "1 changed" from
/// "1 added".
const MODULES: [&str; 4] = ["Pkg", "Pkg.A", "Pkg.B", "Pkg.C"];

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

    /// The bytes are the whole subject: the ledger is a content hash, so an
    /// mtime does not move it and neither does anything else about the file.
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

    /// Nothing is asserted about what `build` prints: `tests/incremental.rs`
    /// drives this same subcommand as the seed of every round, and a second
    /// reader of one answer is not a check of another.
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

/// The lines about a module or a key, read by prefix rather than by position:
/// `check` opens with whatever `resolve_external_links` has to say about a run
/// with no `--root`, and asserting on the first line would assert on that note.
fn indented(log: &str) -> Vec<&str> {
    log.lines().filter(|line| line.starts_with("  ")).collect()
}

/// `ledger` parses one flat set of flags and *then* dispatches, so without a
/// table saying which subcommand owns which flag `ledger touch --concurrency 9`
/// would run, ignore the number and say nothing. The refusal names the flag and
/// the subcommands that do read it, because "unknown argument" would send the
/// reader looking for a typo in a flag that exists.
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

/// The three states are separate lines because they are separate things to do: a
/// *changed* module is re-extracted, an *added* one has never been extracted, and
/// a *removed* one has a page to delete. Counts alone would leave the caller —
/// `tools/build-gate.sh` — unable to act on any of them.
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

    world.set_olean("Pkg.A", "olean:Pkg.A:1");
    world.set_olean("Pkg.New", "olean:Pkg.New:0");
    world.list(&["Pkg", "Pkg.A", "Pkg.B", "Pkg.New"]);

    // Asked for in the same run as the printed answer, because the point is that
    // they are that answer: a run whose files and whose log disagreed would have
    // the extractor and the reader working from two different sets.
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

    // `--changed-out` is the re-extract set, `changed ∪ added` — not the
    // `changed` line alone, which would leave `Pkg.New` without IR.
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

/// A moved *extract* key means every module's IR is invalid whatever its own
/// hash says; a moved *render* key means the IR is fine and every page has to be
/// written again. A run that printed one for the other would either re-import
/// Lean for nothing or serve pages built against inputs that have moved.
#[test]
fn check_says_which_key_moved_and_what_that_costs() {
    let world = World::new("ledger-keys");
    world.build();

    // `leanToolchain` is part of the extract key: a different compiler wrote the
    // oleans, so no module's IR can be trusted.
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

/// Not writing the olean is the entire reason this subcommand exists rather than
/// the gates rewriting a file in the measurement target. Coming back as
/// `changed` and not as `added` is the other half: the entry is invalidated
/// rather than deleted, and a deleted entry reads as an addition, which is not
/// what an edit produces and selects a different render set.
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

    // `--out` lets a gate inject into a copy of a ledger it did not write,
    // instead of copying the file itself and spelling the path twice.
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

    // Exit 3 and not a silent success: a gate that injected a change into a name
    // it misspelled would otherwise wait for a rebuild that cannot happen.
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
