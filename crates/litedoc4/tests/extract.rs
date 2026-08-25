//! The part of `litedoc4 extract` that is **not** the extraction: the command
//! line it builds, the directory it refuses, and the fold from the events JSONL
//! into one JSON object. Judging the extraction itself needs a Lean toolchain, a
//! built target package and 20 seconds, so it is a gate.
//!
//! Everything here runs against a fake `lake` and a fake extractor — two shell
//! scripts. Without that seam none of these assertions would exist at all.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use litedoc4_testutil::cli::{Cli, code, message, stderr};
use litedoc4_testutil::{TempDir, TempDirs};

const TEMP: TempDirs = TempDirs::prefixed("litedoc4-extract");

const BIN: &str = env!("CARGO_BIN_EXE_litedoc4");

/// One test below starts `BIN` through `Command` itself instead: its subject is
/// the child's working directory, which is the one thing a shared runner does
/// not carry.
const LITEDOC4: Cli = Cli::at(BIN);

/// Shortened from a real `*-events.jsonl`. Two of its properties are
/// load-bearing: the `stage4b.` prefix is on every phase, and the extra keys are
/// typed — numbers, booleans and strings in the same file.
const EVENTS: &str = r#"{"phase":"stage4b.initSearchPath","pid":7,"us":34}
{"phase":"stage4b.importModules","pid":7,"us":2498376,"directImports":432,"resident":0}

{"phase":"stage4b.writeIR","pid":7,"us":123456,"taggedCode":"true","moduleFiles":2,"ok":true}
"#;

#[test]
fn the_events_become_one_timings_object() {
    let world = World::new("fold");
    let output = world.run(&["--jobs", "3"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let record = world.timings();
    assert_eq!(record["initSearchPath"], serde_json::json!(0.000_034));
    assert_eq!(record["importModules"], serde_json::json!(2.498_376));
    assert_eq!(record["writeIR"], serde_json::json!(0.123_456));
    assert_eq!(
        record["importModules:directImports"],
        serde_json::json!(432)
    );
    assert_eq!(record["importModules:resident"], serde_json::json!(0));
    assert_eq!(record["writeIR:taggedCode"], serde_json::json!("true"));
    assert_eq!(record["writeIR:moduleFiles"], serde_json::json!(2));
    assert_eq!(record["writeIR:ok"], serde_json::json!(true));
    assert!(
        record.get("initSearchPath:pid").is_none(),
        "pid identifies the process, not the measurement: {record}"
    );
    assert_eq!(record["targetModules"], serde_json::json!(2));
    assert_eq!(record["jobsRequested"], serde_json::json!(3));
    assert_eq!(
        record.as_object().expect("an object").len(),
        10,
        "nothing else is invented: {record}"
    );
}

#[test]
fn the_extractor_is_run_inside_the_target_with_the_schema_5_flags() {
    let world = World::new("command-line");
    let output = world.run(&["--jobs", "4"]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let argv = world.argv();
    assert_eq!(
        argv,
        vec![
            world.modules.display().to_string(),
            world.events().display().to_string(),
            "--equations".to_owned(),
            "--refs".to_owned(),
            "--write-ir".to_owned(),
            "--tagged-code".to_owned(),
            "--jobs".to_owned(),
            "4".to_owned(),
            "--ir-dir".to_owned(),
            world.ir_dir.display().to_string(),
        ],
        "the order the extractor is given its flags in",
    );
    assert_eq!(
        fs::canonicalize(
            fs::read_to_string(world.root.join("cwd"))
                .expect("recorded")
                .trim()
        )
        .expect("a real directory"),
        fs::canonicalize(&world.target).expect("a real directory"),
        "`lake env` has to run inside the package being documented",
    );
    assert!(
        world.ir_dir.is_dir(),
        "the IR directory is created before the extractor is started",
    );
}

#[test]
fn the_events_file_defaults_beside_the_timings_and_is_never_appended_to() {
    let world = World::new("stale-events");
    // `incremental` passes only `--timings`, so a stale round's events land in
    // the file the default names, and a fold that appended would report a phase
    // this run never ran.
    fs::write(
        world.events(),
        "{\"phase\":\"stage4b.ghost\",\"pid\":1,\"us\":9}\n",
    )
    .expect("writable");
    let output = world.run(&[]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    let record = world.timings();
    assert!(
        record.get("ghost").is_none(),
        "a stale events file is removed, not folded in: {record}"
    );
    assert_eq!(record["jobsRequested"], serde_json::json!(1), "the default");
}

#[test]
fn an_ir_dir_inside_the_target_is_refused() {
    let world = World::new("inside-target");
    let inside = world.target.join("build").join("ir");
    let output = world.run(&["--ir-dir", &inside.display().to_string()]);
    assert_eq!(code(&output), 3, "{}", stderr(&output));
    assert!(
        stderr(&output).contains("read-only"),
        "the message says why: {}",
        stderr(&output)
    );
    assert!(
        !inside.exists(),
        "the refusal comes before the directory is created — creating it is \
         already a write into the target",
    );
    assert!(
        !world.root.join("argv").exists(),
        "and before the extractor is started",
    );
}

/// A relative path on the child's command line resolves against the target,
/// because that is the child's working directory (measured 2026-08-15). So
/// `--ir-dir out` passes the guard above — it resolves against *this* process's
/// directory, which is not under the target — and then the extractor writes
/// several MB into `<target>/out`: a write into the measurement target through
/// the one command that promises never to make one.
#[test]
fn every_path_reaches_the_child_absolute_because_its_directory_is_the_target() {
    let world = World::new("relative-paths");
    let output = Command::new(BIN)
        .current_dir(&world.root)
        .args([
            "extract",
            "--modules",
            "modules.txt",
            "--ir-dir",
            "ir",
            "--timings",
            "timings.json",
            "--extractor-bin",
            "extract",
            "--target",
            "target-repo",
            // The one exception: `--lake` is a name looked up on PATH.
            "--lake",
            &world.lake.display().to_string(),
        ])
        .output()
        .expect("the binary under test runs");
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let argv = world.argv();
    for (what, path) in [
        ("--modules", PathBuf::from(&argv[0])),
        ("--events", PathBuf::from(&argv[1])),
        ("--ir-dir", PathBuf::from(argv.last().expect("--ir-dir"))),
    ] {
        assert!(path.is_absolute(), "{what} reached the child as {path:?}");
        assert!(
            !path.starts_with(fs::canonicalize(&world.target).expect("a real directory")),
            "{what} would have been written inside the target: {path:?}",
        );
    }
    assert!(
        !world.target.join("ir").exists(),
        "and nothing was written into the target",
    );
    assert!(
        world.root.join("ir").is_dir(),
        "the tree is where it was asked for"
    );
}

#[test]
fn a_failing_extractor_is_exit_4_and_says_the_tree_is_incomplete() {
    let world = World::new("extractor-fails");
    fs::write(
        &world.extractor,
        "#!/bin/sh\necho 'unknown constant' >&2\nexit 1\n",
    )
    .expect("writable");
    make_executable(&world.extractor);
    let output = world.run(&[]);
    assert_eq!(code(&output), 4, "{}", stderr(&output));
    assert!(
        stderr(&output).contains("incomplete"),
        "a partial IR tree is the thing a caller must not merge: {}",
        stderr(&output)
    );
    assert!(
        !world.timings_path.exists(),
        "and no timings record is written for a run that did not happen",
    );
}

/// Each of these is a real flag of the extractor behind this command, so the
/// answer a caller needs is why it is not offered — not "unknown argument".
#[test]
fn the_flags_that_are_not_offered_are_refused_by_name() {
    for (flag, word) in [
        ("--serve", "incremental --serve"),
        ("--serve-dir", "incremental --serve"),
        ("--serve-from", "incremental --serve"),
        ("--write-ir", "always on"),
        ("--tagged-code", "always on"),
        ("--equations", "always on"),
        ("--refs", "always on"),
        ("--no-attrs", "ablation"),
        ("--no-inst-index", "ablation"),
        ("--no-member-extra", "ablation"),
        ("--pp-breakdown", "measurement"),
        ("--decl-profile", "measurement"),
        ("--only", "measurement"),
    ] {
        let world = World::new(&format!("refuse{flag}"));
        let output = world.run(&[flag, "x"]);
        assert_eq!(code(&output), 2, "{flag}: {}", stderr(&output));
        let said = message(&output);
        assert!(said.contains(flag), "{flag} is named: {said}");
        assert!(said.contains(word), "{flag} says `{word}`: {said}");
        assert!(
            !said.contains("unknown argument"),
            "{flag} is not a typo: {said}"
        );
    }
}

#[test]
fn the_paths_with_no_default_are_required() {
    let world = World::new("required");
    for (missing, word) in [
        ("--modules", "one name per line"),
        ("--ir-dir", "no default"),
        ("--timings", "phase timers"),
        ("--extractor-bin", "no default"),
        ("--target", "lake env"),
    ] {
        let output = world.run_without(missing);
        assert_eq!(code(&output), 2, "{missing}: {}", stderr(&output));
        // The *message*, not the whole of stderr: every one of these words also
        // appears in the `USAGE` printed under it.
        let said = message(&output);
        assert!(said.contains(missing), "{missing} is named: {said}");
        assert!(said.contains(word), "{missing} says `{word}`: {said}");
    }
}

struct World {
    root: PathBuf,
    target: PathBuf,
    modules: PathBuf,
    ir_dir: PathBuf,
    timings_path: PathBuf,
    extractor: PathBuf,
    lake: PathBuf,
    _guard: TempDir,
}

impl World {
    fn new(what: &str) -> Self {
        let guard = TEMP.make(what);
        let root = guard.path().to_path_buf();
        let target = root.join("target-repo");
        fs::create_dir_all(&target).expect("writable");

        let modules = root.join("modules.txt");
        // A blank line and a comment, because `targetModules` counts neither.
        fs::write(&modules, "A.One\n\n# a comment\nA.Two\n").expect("writable");

        // `lake env <program> <args…>` — the one thing about `lake` this
        // subcommand relies on.
        let lake = root.join("lake");
        fs::write(
            &lake,
            "#!/bin/sh\n[ \"$1\" = env ] || { echo \"expected env, got $1\" >&2; exit 9; }\n\
             shift\nexec \"$@\"\n",
        )
        .expect("writable");
        make_executable(&lake);

        // Prints to stdout as well as writing the events, because the caller is
        // supposed to send that stdout to /dev/null.
        let extractor = root.join("extract");
        fs::write(
            &extractor,
            format!(
                "#!/bin/sh\n\
                 : > {argv}\n\
                 for a in \"$@\"; do printf '%s\\n' \"$a\" >> {argv}; done\n\
                 pwd -P > {cwd}\n\
                 cat > \"$2\" <<'JSONL'\n{EVENTS}JSONL\n\
                 echo 'phase report nobody reads'\n",
                argv = shell_quote(&root.join("argv")),
                cwd = shell_quote(&root.join("cwd")),
            ),
        )
        .expect("writable");
        make_executable(&extractor);

        Self {
            target,
            modules,
            ir_dir: root.join("ir"),
            timings_path: root.join("timings.json"),
            extractor,
            lake,
            root,
            _guard: guard,
        }
    }

    /// Where `--events` lands when nobody passes it.
    fn events(&self) -> PathBuf {
        self.root.join("timings-events.jsonl")
    }

    fn run(&self, extra: &[&str]) -> Output {
        let mut args = self.base_args();
        args.extend(extra.iter().map(|arg| (*arg).to_owned()));
        LITEDOC4.run(&args)
    }

    fn run_without(&self, flag: &str) -> Output {
        let base = self.base_args();
        let mut args: Vec<String> = Vec::new();
        let mut skip = false;
        for arg in base {
            if skip {
                skip = false;
                continue;
            }
            if arg == flag {
                skip = true;
                continue;
            }
            args.push(arg);
        }
        LITEDOC4.run(&args)
    }

    fn base_args(&self) -> Vec<String> {
        [
            "extract",
            "--modules",
            &self.modules.display().to_string(),
            "--ir-dir",
            &self.ir_dir.display().to_string(),
            "--timings",
            &self.timings_path.display().to_string(),
            "--extractor-bin",
            &self.extractor.display().to_string(),
            "--target",
            &self.target.display().to_string(),
            "--lake",
            &self.lake.display().to_string(),
        ]
        .iter()
        .map(|arg| (*arg).to_owned())
        .collect()
    }

    fn timings(&self) -> serde_json::Value {
        let text = fs::read_to_string(&self.timings_path).expect("a timings record");
        assert!(
            !text.ends_with('\n'),
            "no trailing newline, as `json.dump` writes none",
        );
        serde_json::from_str(&text).expect("valid JSON")
    }

    fn argv(&self) -> Vec<String> {
        fs::read_to_string(self.root.join("argv"))
            .expect("the extractor recorded its arguments")
            .lines()
            .map(str::to_owned)
            .collect()
    }
}

fn make_executable(path: &Path) {
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).expect("chmod");
}

/// These paths hold a process id and a counter, never a quote — quoted anyway
/// so that the fixture cannot be the thing that breaks.
fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
}
