//! `litedoc4 watch` — keep the site current while the package is being edited,
//! and serve it.
//!
//! **It does not run `lake build`.** The user (or the GitHub action) builds the
//! package and litedoc4 reads the oleans; a Lean compile inside the loop would
//! bring its own errors and its own idea of what to do when it fails into the
//! one command whose purpose is to be predictable.
//!
//! **The trigger is the ledger, not a timestamp.** "Which modules are stale" has
//! one answer in this tree — [`litedoc4_incr::check_ledger`], the same call
//! `build` makes. A second answer derived from mtimes could disagree with the
//! first, and the quiet direction of that disagreement is a loop that never
//! rebuilds.
//!
//! **There is no file-system watcher** — no `notify`, no
//! `FSEvents`/`inotify`/`ReadDirectoryChanges`. Whatever wakes the loop, the
//! answer still comes from the ledger, so an event would only be a different
//! alarm clock — and the alarm clock is the part that behaves differently on
//! each operating system. "Events where available, polling otherwise" is two
//! code paths; polling is not the fallback here, it is the path. The cost is
//! measured: an idle pass is one `check_ledger` over the target's 422 modules —
//! 228 MB of oleans, 0.13 s warm 【実測
//! `benchmarks/results/watch-2026-08-21.txt`】. The price is that an edit is
//! noticed up to [`Flags::interval`] late.
//!
//! **A pass acts only when the ledger's answer is the same as the previous
//! pass's.** While `lake build` is writing oleans the answer keeps moving, and
//! extracting into that produces a site made of two half-worlds — or is stopped
//! by the resident extractor's generation guard (`crate::resident`, exit 3).
//!
//! **The resident extractor does not survive a pass.** Lean cannot swap a module
//! out of an imported environment (quoted in `crate::resident`), and a pass only
//! ever extracts when the oleans have moved — so a server held over from the
//! previous pass is by construction one whose environment just went stale.
//! Residency is still bought *within* a pass: the ownership/merge rounds share
//! one import.
//!
//! **A failed pass waits for the world to move again** before trying the same
//! thing; retrying immediately would start a 3 GB import every interval for as
//! long as the failure lasted. The first pass is the exception — it fails the
//! command, because until it succeeds there is no site to serve and no state to
//! continue from.

use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use litedoc4_incr::{CheckOptions, CheckSummary, check_ledger, sha256_text};

use crate::{Failure, USAGE, refused, usage};

const DEFAULT_INTERVAL: Duration = Duration::from_millis(1000);

const MIN_INTERVAL: Duration = Duration::from_millis(100);

const SETTLE_REPORT: Duration = Duration::from_secs(5);

/// How often an idle loop says it is still there: a silent terminal cannot be
/// told from a dead one.
const HEARTBEAT: Duration = Duration::from_secs(60);

/// `watch`'s own flags, filled in by [`crate::build::parse`]. They arrive as
/// text so that the refusal for `--port banana` is written next to what a port
/// means.
#[derive(Default)]
pub(crate) struct Flags {
    pub(crate) port: Option<String>,
    pub(crate) interval: Option<String>,
}

impl Flags {
    /// Both refusals, for a caller that wants them before it starts a `lake`.
    pub(crate) fn check(&self) -> Result<(), Failure> {
        self.port()?;
        self.interval()?;
        Ok(())
    }

    fn port(&self) -> Result<u16, Failure> {
        let Some(raw) = &self.port else {
            return Ok(crate::httpd::DEFAULT_PORT);
        };
        let port: u16 = raw
            .parse()
            .map_err(|_| Failure::Usage(format!("--port wants a number 1-65535, not `{raw}`")))?;
        if port == 0 {
            return usage(
                "--port 0 asks the kernel for whatever is free, which is an address nobody can \
                 type. Name the port, or leave the flag out for the default",
            );
        }
        Ok(port)
    }

    fn interval(&self) -> Result<Duration, Failure> {
        let Some(raw) = &self.interval else {
            return Ok(DEFAULT_INTERVAL);
        };
        let millis: u64 = raw.parse().map_err(|_| {
            Failure::Usage(format!(
                "--interval wants a whole number of milliseconds, not `{raw}`"
            ))
        })?;
        let interval = Duration::from_millis(millis);
        if interval < MIN_INTERVAL {
            return usage(format!(
                "--interval {millis} is below {} ms: a pass reads every olean of the package, so a \
                 shorter one spends a core asking a question whose last answer is still current",
                MIN_INTERVAL.as_millis(),
            ));
        }
        Ok(interval)
    }
}

pub fn watch(args: &[String]) -> Result<(), Failure> {
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("{USAGE}");
        return Ok(());
    }
    let mut flags = Flags::default();
    let mut request = crate::build::parse(args, Some(&mut flags))?;
    let port = flags.port()?;
    let interval = flags.interval()?;

    // Pinned here, once, and never derived again — see [`Trigger`].
    if request.libs.is_empty() {
        let declared = crate::lakefile::read_libraries(&request.root)?;
        println!(
            "watch   lib    {} (from {})",
            declared.names.join(", "),
            declared.file.display(),
        );
        request.libs = declared.names;
    }
    if request.source_url.is_none() {
        let derived = crate::build::derive_source_url(&request.root)?;
        crate::pipeline::check_source_url(&derived)?;
        println!(
            "watch   source {derived} (derived once, now — a commit during this session does not move it)"
        );
        request.source_url = Some(derived);
    }

    // Before the first build: a port that is taken has to be said while the
    // reader is still looking, not after a two-minute full generation.
    let listener = crate::httpd::bind(port)?;
    let site = request.layout.site.clone();
    println!(
        "watch   site   http://127.0.0.1:{port}/  ({})",
        site.display()
    );
    println!(
        "watch   root   {} — this command does **not** run `lake build`. Run it in another \
         window; watch notices the oleans it writes.",
        request.root.display(),
    );
    println!(
        "watch   asks the ledger every {} ms. Ctrl-C stops it.",
        interval.as_millis(),
    );
    // Detached on purpose: it has no exit condition, and the process ending is
    // what closes the listener.
    let _server = thread::Builder::new()
        .name("litedoc4-httpd".to_owned())
        .spawn(move || crate::httpd::serve(&listener, &site))
        .map_err(|source| Failure::Failed(format!("cannot start the server thread: {source}")))?;

    let trigger = Trigger {
        ledger: &request.layout.ledger,
        ir: &request.layout.ir,
        link_index: &request.link_index,
        source_url: request.source_url.clone().unwrap_or_default(),
        external_links: request.external_links.digest(),
        root: &request.root,
        libs: &request.libs,
    };
    run_loop(&request, &trigger, interval, port)
}

fn run_loop(
    request: &crate::build::Request,
    trigger: &Trigger<'_>,
    interval: Duration,
    port: u16,
) -> Result<(), Failure> {
    let mut previous: Option<String> = None;
    let mut acted: Option<String> = None;
    let mut passes: u64 = 0;
    let mut rebuilds: u64 = 0;
    let mut settling: Option<Instant> = None;
    let mut said: Option<Instant> = None;
    let mut quiet_since = Instant::now();

    loop {
        passes += 1;
        let asked_at = Instant::now();
        let now = match trigger.ask() {
            Ok(now) => now,
            Err(failure) => {
                // Said every time, unlike a failed rebuild: reading the ledger
                // costs nothing to retry, and the world moving is what fixes it.
                eprintln!("watch   cannot ask the ledger: {}", describe(&failure));
                thread::sleep(interval);
                continue;
            }
        };
        // What the poll costs, in the line that says the loop is alive: the one
        // number a reader can use to choose `--interval`.
        let asked = asked_at.elapsed();
        let step = match &now {
            None => Step::Rebuild,
            Some(reading) => decide(previous.as_deref(), acted.as_deref(), reading),
        };
        match step {
            Step::Idle => {
                settling = None;
                said = None;
                if quiet_since.elapsed() >= HEARTBEAT {
                    let up_to_date = now.as_ref().map_or(0, |reading| reading.modules);
                    println!(
                        "watch   idle — {up_to_date} module(s) up to date, {passes} pass(es) so \
                         far, {rebuilds} rebuild(s), {:.3} s to ask",
                        asked.as_secs_f64(),
                    );
                    quiet_since = Instant::now();
                }
            }
            Step::Settling => {
                let reading = now.as_ref().expect("settling implies a reading");
                let stale = reading.what();
                match settling {
                    // The first pass of a settling stretch is the ordinary case
                    // — a `lake build` that finished between two passes — so
                    // "a build is in flight" here would be a guess, usually wrong.
                    None => {
                        settling = Some(Instant::now());
                        said = Some(Instant::now());
                        println!(
                            "watch   {stale} — waiting one quiet interval in case something \
                             is still writing oleans",
                        );
                    }
                    Some(started) => {
                        if said.is_none_or(|at| at.elapsed() >= SETTLE_REPORT) {
                            println!(
                                "watch   still not quiet after {:.0} s — {stale}, and the \
                                 answer keeps moving, so a build is in flight. Waiting; nothing \
                                 is stuck.",
                                started.elapsed().as_secs_f64(),
                            );
                            said = Some(Instant::now());
                        }
                    }
                }
            }
            // Nothing is printed per pass: this state persists until the user
            // builds, so a line a second about it would bury everything else.
            // Only the heartbeat fires, because it can last for hours.
            Step::Skip => {
                settling = None;
                said = None;
                if quiet_since.elapsed() >= HEARTBEAT {
                    let what = now.as_ref().map_or_else(String::new, Reading::what);
                    println!(
                        "watch   waiting — {what}, unchanged since the last pass acted on it, so \
                         there is nothing new to do ({:.3} s to ask)",
                        asked.as_secs_f64(),
                    );
                    quiet_since = Instant::now();
                }
            }
            Step::Rebuild => {
                settling = None;
                said = None;
                rebuilds += 1;
                let first = rebuilds == 1 && acted.is_none();
                announce(rebuilds, now.as_ref());
                match crate::build::run(request) {
                    Ok(ran) => {
                        println!(
                            "watch   #{rebuilds} {} — re-extracted {} module(s), re-rendered {} \
                             page(s), started Lean {} time(s) in {:.3} s{}",
                            ran.what,
                            ran.modules_extracted,
                            ran.pages_rendered,
                            ran.extractor_requests,
                            ran.seconds,
                            if ran.pages_rendered == 0 {
                                " — no page on the site changed"
                            } else {
                                ""
                            },
                        );
                        println!("watch   #{rebuilds} reload http://127.0.0.1:{port}/");
                    }
                    Err(failure) => {
                        // The first one is fatal: with no site to serve and no
                        // state to continue from, looping here would loop over a
                        // broken configuration.
                        if first {
                            return Err(failure);
                        }
                        eprintln!(
                            "watch   #{rebuilds} the rebuild stopped: {}",
                            describe(&failure),
                        );
                        eprintln!(
                            "watch   #{rebuilds} not retrying until the oleans move again — a \
                             failing extraction restarted every {} ms would import 3 GB every {} \
                             ms",
                            interval.as_millis(),
                            interval.as_millis(),
                        );
                    }
                }
                acted = now.as_ref().map(|reading| reading.digest.clone());
                quiet_since = Instant::now();
            }
        }
        previous = now.as_ref().map(|reading| reading.digest.clone());
        thread::sleep(interval);
    }
}

fn announce(rebuilds: u64, now: Option<&Reading>) {
    println!();
    match now {
        None => println!(
            "watch   #{rebuilds} nothing has been built under --out yet — generating the whole \
             site. This imports the package's Lean environment once and extracts every module, \
             which is the slowest thing this command does; the lines below are that run's own",
        ),
        Some(reading) => println!("watch   #{rebuilds} the ledger reports {}", reading.what(),),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Step {
    Idle,
    /// There is work, but the answer moved since the last pass: something is
    /// still writing oleans.
    Settling,
    /// There is work, the world is quiet, and this is bit for bit the answer the
    /// last pass already acted on.
    ///
    /// Two states reach here and both need it. A pass that *failed* must not be
    /// retried until something changes, or a broken extraction becomes a 3 GB
    /// Lean import per interval. And a source file whose olean does not exist
    /// yet is reported stale by every pass for as long as that is true — what
    /// would fix it is `lake build`, not a rebuild — so without this the loop
    /// would rebuild once a second for ever.
    Skip,
    Rebuild,
}

/// The whole of the loop's judgement, as a pure function of three values so that
/// the four answers can be asserted without a toolchain, a package or a clock.
fn decide(previous: Option<&str>, acted: Option<&str>, now: &Reading) -> Step {
    if !now.work() {
        return Step::Idle;
    }
    if previous != Some(now.digest.as_str()) {
        return Step::Settling;
    }
    if acted == Some(now.digest.as_str()) {
        return Step::Skip;
    }
    Step::Rebuild
}

/// Everything one pass needs to ask the ledger the question `build` asks.
///
/// **Every field is fixed for the session.** The ledger records a render key
/// made of the source URL, the dependency map and the documentation map; if the
/// loop computed any of them differently from the run it triggers, the two would
/// take turns telling each other the key had moved and the loop would re-render
/// the whole site on every pass, for ever. So they are resolved once, in
/// [`watch`], and both sides read the same values — `--deps-docs-url` is refused
/// for the same reason (`crate::build`'s `DEPS_DOCS_IN_WATCH`).
///
/// The module list is the exception: it is re-globbed every pass, because a
/// source file that appeared or vanished is one of the things this loop exists
/// to notice.
struct Trigger<'a> {
    ledger: &'a Path,
    ir: &'a Path,
    link_index: &'a Path,
    source_url: String,
    external_links: String,
    root: &'a Path,
    libs: &'a [String],
}

impl Trigger<'_> {
    /// One reading, or `None` when nothing has ever been built here.
    fn ask(&self) -> Result<Option<Reading>, Failure> {
        if !self.ledger.is_file() {
            return Ok(None);
        }
        let modules = crate::pipeline::module_names(self.root, self.libs)?;
        let check = check_ledger(&CheckOptions {
            ledger: self.ledger,
            // The ledger's own, never an override: two algorithms produce
            // incomparable hashes and every module would read as changed.
            algorithm: None,
            modules: Some(&modules),
            ir: Some(self.ir),
            source_url: &self.source_url,
            link_index: Some(self.link_index),
            external_links: Some(&self.external_links),
            concurrency: crate::pipeline::hash_concurrency(),
            // Nothing is written. A question that moves the state its answer is
            // about is one a caller cannot stop on (`litedoc4_incr::detect`).
            changed_out: None,
            removed_out: None,
            render_all_out: None,
            timings: None,
        })
        .map_err(refused)?;
        Ok(Some(Reading::of(&check)))
    }
}

struct Reading {
    /// Over the olean hashes *and* the answer. Two passes during one `lake
    /// build` can report the same *list* of changed modules while the bytes
    /// underneath are still moving, and a digest over the list alone would call
    /// that quiet.
    digest: String,
    modules: usize,
    re_extract: usize,
    removed: usize,
    render_all: Vec<String>,
}

impl Reading {
    fn of(check: &CheckSummary) -> Self {
        let mut lines: Vec<String> = check
            .fresh
            .modules
            .iter()
            .map(|entry| format!("{} {}", entry.module, entry.hash))
            .collect();
        lines.push(format!("re-extract {}", check.re_extract.join(",")));
        lines.push(format!("removed {}", check.removed.join(",")));
        lines.push(format!("renderKey {}", check.render_key_changed.join(",")));
        lines.push(format!(
            "extractKey {}",
            check.extract_key_changed.join(",")
        ));
        Self {
            digest: sha256_text(&lines.join("\n")),
            modules: check.modules,
            re_extract: check.re_extract.len(),
            removed: check.removed.len(),
            render_all: check.render_key_changed.clone(),
        }
    }

    fn work(&self) -> bool {
        self.re_extract > 0 || self.removed > 0 || !self.render_all.is_empty()
    }

    fn what(&self) -> String {
        let mut parts: Vec<String> = Vec::new();
        if self.re_extract > 0 {
            parts.push(format!("{} module(s) to re-extract", self.re_extract));
        }
        if self.removed > 0 {
            parts.push(format!("{} removed", self.removed));
        }
        if !self.render_all.is_empty() {
            parts.push(format!(
                "the render key moved ({})",
                self.render_all.join(",")
            ));
        }
        if parts.is_empty() {
            return "nothing stale".to_owned();
        }
        parts.join(", ")
    }
}

/// A failure as one line, for a loop that reports it and carries on.
fn describe(failure: &Failure) -> String {
    match failure {
        Failure::Usage(message) | Failure::Failed(message) => message.clone(),
        Failure::Answered(code) => format!("exit {code}"),
        Failure::Refused { code, message } => format!("{message} (exit {code})"),
    }
}

/// The command line, the decision, and the question the loop asks — the parts
/// of this file that own their input. [`run_loop`] needs a package, a toolchain
/// and an extractor, so it is `crates/litedoc4/tests/watch.rs` (fake extractor)
/// and `tools/watch-gate.sh` (real one) instead.
#[cfg(test)]
mod tests {
    use std::fs;

    use litedoc4_incr::{Algorithm, BuildOptions, build_ledger};
    use litedoc4_testutil::TempDirs;

    use super::*;

    const TEMP: TempDirs = TempDirs::prefixed("litedoc4-watch");

    /// Any strings will do — what matters is that the ledger is seeded with the
    /// same ones the trigger asks with, because a mismatch is a moved render key
    /// and every pass would then report work.
    const URL: &str = "https://github.com/owner/repo/blob/0123456789abcdef";
    const EXTERNAL: &str = "external-links-digest";

    fn put(path: &Path, body: &[u8]) {
        fs::create_dir_all(path.parent().expect("a parent")).expect("writable");
        fs::write(path, body).expect("writable");
    }

    /// The sources the glob finds, the oleans it reads, and the two files
    /// `extractKey` is computed over.
    fn write_package(root: &Path, oleans: &[(&str, &str)]) {
        put(&root.join("lean-toolchain"), b"leanprover/lean4:v4.31.0\n");
        put(
            &root.join("lake-manifest.json"),
            br#"{"version":"1.1.0","packages":[]}"#,
        );
        for (module, olean) in oleans {
            let path = module.replace('.', "/");
            put(&root.join(format!("{path}.lean")), b"-- a source file\n");
            put(
                &root.join(format!(".lake/build/lib/lean/{path}.olean")),
                olean.as_bytes(),
            );
        }
    }

    fn seed_ledger(trigger: &Trigger<'_>, modules: &[String]) {
        build_ledger(&BuildOptions {
            modules,
            target: &trigger.root.display().to_string(),
            out: trigger.ledger,
            ir: Some(trigger.ir),
            source_url: &trigger.source_url,
            link_index: Some(trigger.link_index),
            external_links: Some(&trigger.external_links),
            algorithm: &Algorithm::sha256(),
            concurrency: 1,
            timings: None,
        })
        .expect("the ledger is written");
    }

    #[test]
    fn the_trigger_answers_none_an_error_a_stable_digest_and_a_moved_olean() {
        let work = TEMP.make("trigger-ask");
        let repo = work.path().join("repo");
        let ledger = work.path().join("ledger.json");
        let ir = work.path().join("ir");
        let lidx = work.path().join("link-index.lidx");
        write_package(&repo, &[("Pkg", "olean:Pkg:0"), ("Pkg.A", "olean:Pkg.A:0")]);
        // Only `schemaVersion` and `generator` of the index reach `extractKey`.
        put(
            &ir.join("index.json"),
            br#"{"schemaVersion":5,"generator":"litedoc4/crates/litedoc4/src/watch.rs"}"#,
        );
        put(&lidx, b"#lidx1\n@Dep.Home\nDep.Home\n\tDep.elsewhere\n");
        let libs = vec!["Pkg".to_owned()];
        let trigger = Trigger {
            ledger: &ledger,
            ir: &ir,
            link_index: &lidx,
            source_url: URL.to_owned(),
            external_links: EXTERNAL.to_owned(),
            root: &repo,
            libs: &libs,
        };

        assert!(
            trigger.ask().expect("no ledger is an answer").is_none(),
            "a directory nothing has built must read as `nothing yet`, not as a failure",
        );

        seed_ledger(&trigger, &["Pkg".to_owned(), "Pkg.A".to_owned()]);
        let quiet = trigger
            .ask()
            .expect("the ledger is readable")
            .expect("a reading");
        assert_eq!(quiet.modules, 2);
        assert!(
            !quiet.work(),
            "the ledger was built from this very tree and the trigger still found work: {}",
            quiet.what(),
        );
        assert_eq!(quiet.what(), "nothing stale");

        let again = trigger
            .ask()
            .expect("the ledger is readable")
            .expect("a reading");
        assert_eq!(
            again.digest, quiet.digest,
            "two passes over a world that did not move disagree, so no pass would ever be \
             quiet enough to build",
        );

        put(
            &repo.join(".lake/build/lib/lean/Pkg/A.olean"),
            b"olean:Pkg.A:1",
        );
        let moved = trigger
            .ask()
            .expect("the ledger is readable")
            .expect("a reading");
        assert_ne!(
            moved.digest, quiet.digest,
            "an olean moved and the digest did not, so the loop would sit on a stale site",
        );
        assert!(moved.work());
        assert_eq!(moved.re_extract, 1);
        assert_eq!(moved.what(), "1 module(s) to re-extract");

        put(&ledger, b"{ half-written");
        // Matched rather than `expect_err`, which would want a `Debug` on
        // `Reading` that nothing else in the product asks for.
        let failure = match trigger.ask() {
            Ok(_) => panic!("a ledger that will not parse read as `nothing has been built here`"),
            Err(failure) => failure,
        };
        assert!(
            describe(&failure).contains("ledger.json"),
            "the line the loop prints has to name the file: {}",
            describe(&failure),
        );
    }

    #[test]
    fn every_failure_becomes_one_line_that_still_says_what_happened() {
        assert_eq!(
            describe(&Failure::Usage("--port wants a number".to_owned())),
            "--port wants a number",
        );
        assert_eq!(
            describe(&Failure::Failed("/tmp/x: No such file".to_owned())),
            "/tmp/x: No such file",
        );
        assert_eq!(
            describe(&Failure::Answered(4)),
            "exit 4",
            "the extractor's own exit code is the whole content of this failure",
        );
        assert_eq!(
            describe(&Failure::Refused {
                code: crate::EXIT_REFUSED,
                message: "the ledger is older than this layout".to_owned(),
            }),
            "the ledger is older than this layout (exit 3)",
        );
    }

    fn reading(re_extract: usize, removed: usize, render_all: &[&str], digest: &str) -> Reading {
        Reading {
            digest: digest.to_owned(),
            modules: 422,
            re_extract,
            removed,
            render_all: render_all.iter().map(|name| (*name).to_owned()).collect(),
        }
    }

    #[test]
    fn nothing_stale_is_idle_whatever_the_history() {
        let quiet = reading(0, 0, &[], "a");
        assert_eq!(decide(None, None, &quiet), Step::Idle);
        assert_eq!(decide(Some("a"), Some("a"), &quiet), Step::Idle);
        assert_eq!(decide(Some("b"), Some("c"), &quiet), Step::Idle);
    }

    #[test]
    fn an_answer_that_moved_since_the_last_pass_is_a_build_in_flight() {
        let stale = reading(37, 0, &[], "a");
        assert_eq!(decide(None, None, &stale), Step::Settling);
        assert_eq!(decide(Some("earlier"), None, &stale), Step::Settling);
    }

    #[test]
    fn a_quiet_world_with_new_work_rebuilds_and_the_same_work_does_not_twice() {
        let stale = reading(1, 0, &[], "a");
        assert_eq!(decide(Some("a"), None, &stale), Step::Rebuild);
        assert_eq!(decide(Some("a"), Some("older"), &stale), Step::Rebuild);
        assert_eq!(decide(Some("a"), Some("a"), &stale), Step::Skip);
    }

    #[test]
    fn a_moved_render_key_is_work_even_with_nothing_to_re_extract() {
        let keyed = reading(0, 0, &["sourceUrl"], "a");
        assert!(keyed.work());
        assert_eq!(decide(Some("a"), None, &keyed), Step::Rebuild);
        let deleted = reading(0, 1, &[], "a");
        assert!(deleted.work());
        assert_eq!(decide(Some("a"), None, &deleted), Step::Rebuild);
    }

    #[test]
    fn the_work_is_described_by_what_is_actually_stale() {
        assert_eq!(reading(0, 0, &[], "a").what(), "nothing stale");
        assert_eq!(reading(1, 0, &[], "a").what(), "1 module(s) to re-extract");
        assert_eq!(reading(0, 2, &[], "a").what(), "2 removed");
        assert_eq!(
            reading(0, 0, &["sourceUrl"], "a").what(),
            "the render key moved (sourceUrl)",
            "a pass with nothing to re-extract must not report `0 module(s) stale`",
        );
        assert_eq!(
            reading(3, 1, &["linkIndex"], "a").what(),
            "3 module(s) to re-extract, 1 removed, the render key moved (linkIndex)",
        );
    }

    #[test]
    fn the_port_is_a_number_in_range_or_a_refusal_that_names_it() {
        let flags = Flags::default();
        assert_eq!(
            flags.port().expect("the default"),
            crate::httpd::DEFAULT_PORT
        );
        for (raw, needle) in [
            ("banana", "not `banana`"),
            ("70000", "not `70000`"),
            ("-1", "not `-1`"),
            ("0", "asks the kernel"),
        ] {
            let flags = Flags {
                port: Some(raw.to_owned()),
                interval: None,
            };
            let message = match flags.port() {
                Ok(port) => panic!("--port {raw} was accepted as {port}"),
                Err(failure) => describe(&failure),
            };
            assert!(message.contains(needle), "--port {raw}: {message}");
        }
        assert_eq!(
            Flags {
                port: Some("8484".to_owned()),
                interval: None,
            }
            .port()
            .expect("in range"),
            8484,
        );
    }

    #[test]
    fn the_interval_has_a_floor_and_it_says_what_the_floor_buys() {
        let flags = Flags::default();
        assert_eq!(flags.interval().expect("the default"), DEFAULT_INTERVAL);
        let too_fast = Flags {
            port: None,
            interval: Some("10".to_owned()),
        };
        let message = match too_fast.interval() {
            Ok(interval) => panic!("--interval 10 was accepted as {interval:?}"),
            Err(failure) => describe(&failure),
        };
        assert!(message.contains("reads every olean"), "{message}");
        assert!(message.contains("100 ms"), "{message}");
        assert_eq!(
            Flags {
                port: None,
                interval: Some("2500".to_owned()),
            }
            .interval()
            .expect("above the floor"),
            Duration::from_millis(2500),
        );
    }

    /// Both directions, because a one-directional check would pass on the day
    /// `--port` silently became a `build` flag that does nothing.
    #[test]
    fn each_command_refuses_the_others_flags_by_name() {
        let build = |args: &[&str]| {
            let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
            crate::build::parse(&args, None).err().map(|f| describe(&f))
        };
        let watch = |args: &[&str]| {
            let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
            let mut flags = Flags::default();
            crate::build::parse(&args, Some(&mut flags))
                .err()
                .map(|f| describe(&f))
        };

        for (args, needle) in [
            (vec!["--port", "8484"], "is a `watch` flag"),
            (vec!["--interval", "500"], "is a `watch` flag"),
        ] {
            let message = build(&args).expect("refused");
            assert!(message.contains(needle), "{args:?}: {message}");
        }
        for (args, needle) in [
            (vec!["--full"], "is not a `watch` flag"),
            (
                vec!["--deps-docs-url", "Mathlib=https://example.invalid"],
                "over the network",
            ),
            (
                vec!["--deps-docs-index", "Mathlib=/tmp/table.bmp"],
                "over the network",
            ),
        ] {
            let message = watch(&args).expect("refused");
            assert!(message.contains(needle), "{args:?}: {message}");
        }
        // The shared refusals still land on both: one parser.
        assert!(
            watch(&["--out", "/tmp/x"])
                .expect("refused")
                .contains("--root"),
        );
    }
}
