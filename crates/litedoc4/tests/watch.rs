//! `litedoc4 watch` — the loop, started for real and then stopped.
//!
//! **What this reaches that no other test in this workspace does.** The loop's
//! judgement is a pure function and is asserted beside it
//! (`crates/litedoc4/src/watch.rs`); so is the question it asks
//! (`Trigger::ask`, same file). What neither can reach is
//! everything that only exists in a process: the banner, the server thread, the
//! order the lines come out in, and the three things a *pass* does — announce,
//! build, and say what the build cost. `run_loop` has no exit condition, so
//! there is no way to call it and come back.
//!
//! # `run_loop` is not decomposed, and that is a decision 【判断】
//!
//! It could be: hand it a clock and a "build this" closure and the four arms
//! become callable. It is not, for the reason the module header of `watch.rs`
//! gives for refusing a file-system watcher — **one path, not two**. A seam
//! that lets a test drive the loop without a build is a second definition of
//! what a pass does, and the quiet direction of a disagreement between the two
//! is a loop that a test says rebuilds and a user says does not. What the loop
//! does that is worth checking is *observable from outside*: every arm it takes
//! prints a line, and every line is below.
//!
//! # The long-lived process
//!
//! `watch` **outlives the shell that started it** 【実測 2026-08-21, CLAUDE.md】
//! — an interrupted session left one rewriting the IR a later gate was reading,
//! which was reported as a corrupt IR tree and as `rm: Directory not empty`,
//! neither of which looks like what it is. Rust's `Child` does not kill on drop
//! either. So every case here holds a [`Watching`], whose `Drop` kills and
//! **waits**, and which therefore runs on a panicking assertion too.
//!
//! # The ports are fixed, and these three
//!
//! `--port 0` is refused by the product on purpose ("an address nobody can
//! type"), so a test cannot ask the kernel for a free one. 18484-18486 is
//! `watch`'s own default (8484) plus 10000: below every ephemeral range
//! (Linux's 32768-60999, macOS's 49152-65535) so the kernel will not have
//! handed one out, clear of `tools/watch-gate.sh`'s 8485, and registered to
//! nothing. One per case, because the cases run on their own threads.

mod common;

use std::fs::{self, File};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use common::{Features, write_fake_extractor};
use litedoc4_testutil::TempDirs;
use litedoc4_testutil::cli::{Cli, code, stderr};
use serde_json::{Value, json};

const TEMP: TempDirs = TempDirs::prefixed("litedoc4-watch-loop");

const LITEDOC4: Cli = Cli::at(env!("CARGO_BIN_EXE_litedoc4"));

/// Pinned rather than derived from a checkout: `watch` pins the URL once for the
/// session, and a test that made it come from `git` would be checking the
/// derivation `tests/build.rs` already owns.
const URL: &str = "https://github.com/owner/repo/blob/0123456789abcdef0123456789abcdef01234567";

/// How long a pass sleeps. Above the product's 100 ms floor, and small enough
/// that a case that waits for three passes waits under a second.
const INTERVAL_MS: &str = "200";

/// The longest any of these cases waits for a line before calling it a failure.
///
/// It is a **bound, not an expectation** — a full generation of three modules
/// through a `/bin/sh` extractor is milliseconds, and nothing here asserts on a
/// duration.
const PATIENCE: Duration = Duration::from_secs(60);

// ------------------------------------------------------------------ the world

/// One module: its olean's bytes, what it imports, and its docstring.
struct ModuleSpec {
    name: &'static str,
    olean: String,
    imports: &'static [&'static str],
}

fn base_world() -> Vec<ModuleSpec> {
    vec![
        ModuleSpec {
            name: "Pkg",
            olean: "olean:Pkg:0".to_owned(),
            imports: &[],
        },
        ModuleSpec {
            name: "Pkg.A",
            olean: "olean:Pkg.A:0".to_owned(),
            imports: &["Pkg"],
        },
        ModuleSpec {
            name: "Pkg.B",
            olean: "olean:Pkg.B:0".to_owned(),
            imports: &["Pkg"],
        },
    ]
}

/// One declaration with every key the schema-5 reader requires, and no other:
/// `litedoc4_ir::Decl` is `deny_unknown_fields`.
fn decl_json(name: &str) -> Value {
    json!({
        "binderCode": [], "binders": [], "col": 0, "doc": Value::Null,
        "endCol": 1, "endLine": 1, "equationCode": [], "equations": [],
        "implicits": [], "index": 0, "kind": "def", "line": 1, "members": [],
        "modifiers": [], "name": name, "refs": [], "type": "Prop", "typeCode": [],
    })
}

/// The baked IR the fake extractor copies out of, and the index entry of each
/// module for it to splice.
fn write_world(root: &Path, world: &[ModuleSpec]) {
    let _ = fs::remove_dir_all(root);
    for module in world {
        let name = format!("{}.{}", module.name, module.name.to_lowercase());
        let body = serde_json::to_string(&json!({
            "declarations": [decl_json(&name)],
            "imports": module.imports,
            "module": module.name,
            "moduleDocs": [],
            "schemaVersion": 5,
            "tactics": [],
        }))
        .expect("serialises");
        put(
            &root.join(format!("ir/modules/{}.json", module.name)),
            body.as_bytes(),
        );
        put(
            &root.join(format!("entries/{}.json", module.name)),
            serde_json::to_string(&json!({
                "bytes": body.len(),
                // Any 16 hex digits that move with the bytes: the extractor
                // computes this with Lean's `String.hash` and nothing here
                // re-implements that.
                "contentHash": format!("{:016x}", fnv(&body)),
                "declarations": 1,
                "file": format!("modules/{}.json", module.name),
                "module": module.name,
            }))
            .expect("serialises")
            .as_bytes(),
        );
    }
}

fn fnv(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// The package: the lakefile `watch` reads its library from when `--lib` is
/// absent, the sources the glob finds, and the oleans the ledger hashes.
fn write_repo(repo: &Path, world: &[ModuleSpec]) {
    put(
        &repo.join("lakefile.toml"),
        b"name = \"pkg\"\nversion = \"0.1.0\"\ndefaultTargets = [\"Pkg\"]\n\n\
          [[lean_lib]]\nname = \"Pkg\"\n",
    );
    put(&repo.join("lean-toolchain"), b"leanprover/lean4:v4.31.0\n");
    put(
        &repo.join("lake-manifest.json"),
        br#"{"version":"1.1.0","packages":[]}"#,
    );
    for module in world {
        let path = module.name.replace('.', "/");
        put(&repo.join(format!("{path}.lean")), b"-- a source file\n");
        put(
            &repo.join(format!(".lake/build/lib/lean/{path}.olean")),
            module.olean.as_bytes(),
        );
    }
}

fn put(path: &Path, body: &[u8]) {
    fs::create_dir_all(path.parent().expect("a parent")).expect("writable");
    fs::write(path, body).expect("writable");
}

// ---------------------------------------------------------------- the harness

/// One package, one `--out`, and the `watch` process looking at them.
struct Live {
    trees: litedoc4_testutil::TempDir,
    repo: PathBuf,
    out: PathBuf,
    world: PathBuf,
    lidx: PathBuf,
    script: PathBuf,
    log: PathBuf,
}

impl Live {
    fn new(what: &str) -> Self {
        let trees = TEMP.make(what);
        let live = Self {
            repo: trees.path().join("repo"),
            out: trees.path().join("out"),
            world: trees.path().join("world"),
            lidx: trees.path().join("link-index.lidx"),
            script: trees.path().join("extract.sh"),
            log: trees.path().join("watch.log"),
            trees,
        };
        let world = base_world();
        write_repo(&live.repo, &world);
        write_world(&live.world, &world);
        put(
            &live.lidx,
            b"#lidx1\n@Dep.Home\nDep.Home\n\tDep.elsewhere\n\tDep.Home.other\n",
        );
        write_fake_extractor(
            &live.script,
            Features {
                corrupt: false,
                deps: false,
            },
        );
        live
    }

    /// `litedoc4 watch` on `port`, with its output — both streams, in the order
    /// they were written — going to one file.
    ///
    /// **`--lib` is deliberately absent**: the loop reads the library out of the
    /// lakefile and pins it, and the line saying so is one of the ones asserted
    /// below. `--source-url` is passed because deriving it needs a checkout,
    /// which is `tests/build.rs`'s subject rather than this one's.
    fn watch(&self, port: u16, extra: &[&str]) -> Watching {
        let log = File::create(&self.log).expect("the log file is creatable");
        let errors = log.try_clone().expect("the log file can be shared");
        let mut args: Vec<String> = vec![
            "watch".to_owned(),
            "--root".to_owned(),
            self.repo.display().to_string(),
            "--out".to_owned(),
            self.out.display().to_string(),
            "--link-index".to_owned(),
            self.lidx.display().to_string(),
            "--source-url".to_owned(),
            URL.to_owned(),
            "--port".to_owned(),
            port.to_string(),
            "--interval".to_owned(),
            INTERVAL_MS.to_owned(),
            "--extractor".to_owned(),
            "/bin/sh".to_owned(),
            "--extractor-arg".to_owned(),
            self.script.display().to_string(),
            "--extractor-arg".to_owned(),
            "--world".to_owned(),
            "--extractor-arg".to_owned(),
            self.world.display().to_string(),
        ];
        args.extend(extra.iter().map(|arg| (*arg).to_owned()));
        let child = Command::new(env!("CARGO_BIN_EXE_litedoc4"))
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::from(log))
            .stderr(Stdio::from(errors))
            .spawn()
            .expect("the binary under test starts");
        Watching {
            child,
            log: self.log.clone(),
            port,
        }
    }

    /// Everything `watch` has said so far. Missing is empty: the file exists
    /// from the moment the child is spawned, but a reader can get there first.
    fn log(&self) -> String {
        fs::read_to_string(&self.log).unwrap_or_default()
    }

    /// `litedoc4 ledger touch` on this run's own ledger — "module M changed",
    /// injected, with the olean left exactly as it is.
    fn touch(&self, module: &str) {
        let output = LITEDOC4.run(&[
            "ledger".as_ref(),
            "touch".as_ref(),
            "--ledger".as_ref(),
            self.out.join("ledger.json").as_os_str(),
            "--module".as_ref(),
            module.as_ref(),
        ]);
        assert_eq!(code(&output), 0, "{}", stderr(&output));
    }
}

/// A running `watch`, killed and reaped when this value goes out of scope.
///
/// `Child` does **not** kill on drop, and this process serves a port and
/// rewrites a directory: one left behind holds both, and the next thing to use
/// either reports a fault that is not its own 【実測 2026-08-21】. `Drop` runs
/// on a panicking assertion, which is the case that matters — a test that killed
/// the child on its last line would leak one on every failure.
struct Watching {
    child: Child,
    log: PathBuf,
    port: u16,
}

impl Watching {
    /// Waits until `needle` appears in the log, and fails loudly if the process
    /// dies first or the patience runs out.
    ///
    /// **A dead child is reported as a dead child.** A wait that can only time
    /// out turns "the port was taken" into "sixty seconds passed", which is the
    /// shape doc-gen4 #404 was mistaken for.
    fn wait_for(&mut self, needle: &str) {
        let started = Instant::now();
        loop {
            let log = fs::read_to_string(&self.log).unwrap_or_default();
            if log.contains(needle) {
                return;
            }
            if let Some(status) = self.child.try_wait().expect("the child is waitable") {
                panic!(
                    "watch exited {status} while waiting for `{needle}` on port {}:\n{log}",
                    self.port,
                );
            }
            assert!(
                started.elapsed() < PATIENCE,
                "`{needle}` never appeared in {PATIENCE:?} on port {}:\n{log}",
                self.port,
            );
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// Waits for the process to end, and hands back its exit code.
    fn wait_for_the_end(&mut self) -> i32 {
        let started = Instant::now();
        loop {
            if let Some(status) = self.child.try_wait().expect("the child is waitable") {
                return status.code().unwrap_or_else(|| {
                    panic!(
                        "watch was killed by a signal rather than exiting:\n{}",
                        fs::read_to_string(&self.log).unwrap_or_default(),
                    )
                });
            }
            assert!(
                started.elapsed() < PATIENCE,
                "watch was still running after {PATIENCE:?}:\n{}",
                fs::read_to_string(&self.log).unwrap_or_default(),
            );
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    fn is_running(&mut self) -> bool {
        self.child
            .try_wait()
            .expect("the child is waitable")
            .is_none()
    }

    /// One request over one connection, the whole answer as text.
    fn get(&self, target: &str) -> String {
        let mut stream = TcpStream::connect(("127.0.0.1", self.port))
            .unwrap_or_else(|source| panic!("nothing is listening on {}: {source}", self.port));
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .expect("the timeout is settable");
        stream
            .write_all(format!("GET {target} HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes())
            .expect("writable");
        stream.flush().expect("flushable");
        let mut answer = Vec::new();
        stream
            .read_to_end(&mut answer)
            .unwrap_or_else(|source| panic!("GET {target} was never answered: {source}"));
        String::from_utf8_lossy(&answer).into_owned()
    }
}

impl Drop for Watching {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// How many times `needle` occurs in `text`.
fn occurrences(text: &str, needle: &str) -> usize {
    text.matches(needle).count()
}

// -------------------------------------------------------------------- the loop

/// **One session, end to end**: the banner, the first generation, the server,
/// and a second pass that rebuilds exactly the module that went stale.
///
/// Every line asserted here is one an arm of the loop prints and nothing else
/// does, so a failure names the arm:
///
/// - the three banner lines are what `watch` pins before it binds — the library
///   from the lakefile, the address, and the sentence saying it does not run
///   `lake build`;
/// - `#1 nothing has been built under --out yet` is `announce`'s first-run
///   branch, which exists because a silent two-minute generation is the shape
///   #404 was mistaken for;
/// - `waiting one quiet interval` is `Step::Settling`, and it must appear
///   between the touch and the rebuild: without it the loop would extract into
///   a directory something else is still writing;
/// - `#2 the ledger reports` is `announce`'s other branch, and the counts after
///   it are the pass's own answer to what it cost.
#[test]
fn watch_generates_a_site_serves_it_and_rebuilds_the_module_the_ledger_says_moved() {
    let live = Live::new("watch-rebuild");
    let mut watching = live.watch(18484, &[]);

    watching.wait_for("watch   asks the ledger every 200 ms");
    let banner = live.log();
    assert!(
        banner.contains("watch   lib    Pkg (from"),
        "the library was not read from the lakefile and pinned: {banner}",
    );
    assert!(
        banner.contains("watch   site   http://127.0.0.1:18484/"),
        "the banner does not say where the site is being served: {banner}",
    );
    assert!(
        banner.contains("does **not** run `lake build`"),
        "the banner stopped saying the one thing every reader asks first: {banner}",
    );

    watching.wait_for("watch   #1 reload");
    let first = live.log();
    assert!(
        first.contains("watch   #1 nothing has been built under --out yet"),
        "the first pass did not describe the long wait in advance: {first}",
    );
    assert!(
        first.contains("watch   #1 full — re-extracted 3 module(s), re-rendered 3 page(s)"),
        "the first pass did not report a whole-package generation: {first}",
    );

    let root = watching.get("/");
    assert!(
        root.starts_with("HTTP/1.1 200 OK\r\n"),
        "the site the pass just wrote is not being served: {root:.200}",
    );
    let page = watching.get("/Pkg/B.html");
    assert!(
        page.starts_with("HTTP/1.1 200 OK\r\n") && page.contains("Pkg.B"),
        "a module page of the site the pass just wrote: {page:.200}",
    );
    let missing = watching.get("/Pkg/Nope.html");
    assert!(
        missing.starts_with("HTTP/1.1 404 Not Found\r\n"),
        "a page that is not there: {missing:.200}",
    );

    // "module Pkg.B changed", injected into this run's own ledger — the olean is
    // untouched, which is what makes this expressible without a Lean toolchain.
    live.touch("Pkg.B");

    watching.wait_for("watch   #2 reload");
    let second = live.log();
    assert!(
        second.contains("waiting one quiet interval in case something is still writing oleans"),
        "the pass that first saw the moved answer rebuilt without waiting for it to settle: \
         {second}",
    );
    assert!(
        second.contains("watch   #2 the ledger reports 1 module(s) to re-extract"),
        "the second pass did not say what the ledger told it: {second}",
    );
    assert!(
        second.contains(
            "watch   #2 incremental — re-extracted 1 module(s), re-rendered 1 page(s), \
             started Lean 1 time(s)"
        ),
        "one module went stale and the pass did not do exactly one module's work: {second}",
    );
    assert!(
        watching.is_running(),
        "the loop ended after a pass that succeeded",
    );
}

/// **The first rebuild is the one failure that ends the command.**
///
/// Until it succeeds there is no site to serve and no state to continue from, so
/// a loop here would be a loop over a broken configuration — and the process
/// would sit there printing the same failure every interval while serving
/// nothing.
#[test]
fn a_first_rebuild_that_fails_ends_the_command_rather_than_looping_on_it() {
    let live = Live::new("watch-first-fails");
    let mut watching = live.watch(18485, &["--extractor-arg", "--fail"]);

    // 4 is what the extraction stage answers with when the extractor itself
    // exits non-zero (`tests/build.rs`), and it reaches the shell unchanged:
    // `watch` returns the first pass's failure instead of swallowing it.
    assert_eq!(
        watching.wait_for_the_end(),
        4,
        "the command did not fail with the extractor's own exit:\n{}",
        live.log(),
    );
    let log = live.log();
    assert!(
        log.contains("watch   #1 nothing has been built under --out yet"),
        "the pass never started: {log}",
    );
    assert!(
        !log.contains("not retrying until the oleans move again"),
        "the first failure was reported as one to wait out, which is what a loop over a \
         package that has never built would do: {log}",
    );
}

/// **A later failure is said once and then waited out**, and the loop stays up.
///
/// This is the half of the design doc-gen4 #404 is named after: a rebuild that
/// retried immediately would start a fresh extraction every interval for as long
/// as the failure lasted. What stops it is `Step::Skip` — the same answer the
/// last pass already acted on — so the assertion is a **count**, not a
/// presence. One line, several intervals later.
#[test]
fn a_later_rebuild_that_fails_is_reported_once_and_not_retried_every_interval() {
    let live = Live::new("watch-later-fails");
    let mut watching = live.watch(18486, &[]);
    watching.wait_for("watch   #1 reload");

    // The world loses `Pkg.B`'s baked IR and its olean moves: the ledger reports
    // one module to re-extract, and the extractor cannot produce it. Breaking
    // the *world* rather than passing `--fail` keeps the failure to one module,
    // which is what a real broken build looks like.
    fs::remove_file(live.world.join("ir/modules/Pkg.B.json")).expect("the baked module is there");
    put(
        &live.repo.join(".lake/build/lib/lean/Pkg/B.olean"),
        b"olean:Pkg.B:1",
    );

    watching.wait_for("watch   #2 the rebuild stopped");
    watching.wait_for("not retrying until the oleans move again");

    // Six intervals. A loop that retried would be on `#8` by now; one that
    // retried and reported only once would still have re-run the extractor, so
    // the count is taken over the line the *pass* prints rather than over the
    // failure.
    std::thread::sleep(Duration::from_millis(1_200));
    let log = live.log();
    assert_eq!(
        occurrences(&log, "the rebuild stopped"),
        1,
        "the failed rebuild was retried while nothing had changed: {log}",
    );
    assert_eq!(
        occurrences(&log, "the ledger reports"),
        1,
        "a second pass announced a rebuild for an answer the last one already acted on: {log}",
    );
    assert!(
        watching.is_running(),
        "a rebuild that failed after the first one ended the loop:\n{log}",
    );

    // …and the world moving is what starts it again: the module comes back and
    // the next pass rebuilds, which is the other half of "wait for the world to
    // move" — a loop that waited for ever would be indistinguishable from a
    // hang.
    write_world(&live.world, &base_world());
    put(
        &live.repo.join(".lake/build/lib/lean/Pkg/B.olean"),
        b"olean:Pkg.B:2",
    );
    watching.wait_for("watch   #3 reload");
    assert!(
        live.trees.path().join("out/site/Pkg/B.html").is_file(),
        "the page the recovered pass rebuilt is not on the site",
    );
}
