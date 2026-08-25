//! The resident extractor: **one Lean environment, many extractions**.
//!
//! The environment load is the extraction's fixed cost and it is paid **per
//! process** (`Extract.lean:2700-2705`), so anything that runs the extractor once
//! per round pays it once per round. The server is the answer: import once, then
//! answer requests over a pipe.
//!
//! ```text
//! lake env <extract> <modules.txt> <events.jsonl> --equations --refs
//!          --write-ir --tagged-code --jobs N --ir-dir <unused> --serve
//!
//!   stdin   <modules.txt> <events.jsonl> <ir-dir>      one request per line
//!   stdout  ready <ns> <envModules> <targets>          once, at start-up
//!           ok <exit code> <ns>                        one per request
//! ```
//!
//! # The request channel is a pipe
//!
//! The server's loop ends on EOF (`Extract.lean:2747`), and the channel is the
//! child's **stdin pipe**, held open in [`Server::stdin`] for as long as the
//! server is wanted. What that buys:
//!
//! > **A pipe cannot outlive its writer.** However this process dies — an error
//! > path, a panic, `SIGINT`, `SIGKILL` — the kernel closes the write end, the
//! > server reads EOF and returns 0 through its own exit path. The 3 GB process
//! > cannot be orphaned by a failure of the driver, because the thing that keeps
//! > it alive *is* the driver.
//!
//! A separate holder process on a FIFO has no such property, and no signal
//! handler covers `SIGKILL`. [`Drop`] is what makes the *ordinary* stop clean
//! rather than merely eventual; `main` returns an [`std::process::ExitCode`] and
//! this crate calls `std::process::exit` nowhere, so every error path unwinds
//! through here.
//!
//! # There is no `--serve-dir`: a server this process does not own
//!
//! **Correctness comes from the server's olean generation, never from the round
//! number** (measured, stage 6a). A server imported *before* an edit answers with
//! the pre-edit owner of every name that moved — the exact stale pair ownership
//! exists to repair — and with such a server *no* round is safe, including round
//! 2. Pointing at somebody else's server can only read that server's self-report,
//! so residency is owned by the run instead.
//!
//! [`Generation`] is what makes that checkable rather than argued: **Lake's own
//! content hash of every olean of every module in `--modules`**, over the same
//! files in the same order the ledger hashes, so the guard and `detect` cannot
//! disagree about what "the world" is. It is taken once at the head of the run
//! and compared before the spawn, when the server reports `ready`, and before and
//! after every request. A difference stops the run with **exit 3** and names the
//! modules that moved, which catches the one way the pipeline can still be handed
//! a stale environment: a `lake build` that lands *while* a run is in flight. It
//! costs three `stat`s and one 64-byte read per module.
//!
//! # Two traps, both measured
//!
//! 1. **`--ir-dir` is required at start-up even though every request overrides
//!    it** (measured 2026-08-15): the extractor refuses `--write-ir` without one
//!    (`Extract.lean:2778-2782`), so a start-up line without it exits 1 before
//!    importing anything, while a request's third field replaces it
//!    (`Extract.lean:2753`). The value passed here names nothing that is written.
//! 2. **stderr is inherited, exactly as the one-shot path inherits it.** A Lean
//!    error has to reach the caller, and the two extraction paths have to be
//!    diagnosable the same way. Capturing it would also change what a recorded
//!    run's output holds: `lake` warns about a modified dependency checkout on
//!    every start (measured).

use std::fs::{self, File};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

use litedoc4_incr::{Algorithm, hash_module, sha256_text};

use crate::Failure;
use crate::extract::{EXIT_EXTRACTOR, FIXED_FLAGS, events_beside, fold_timings};

/// How long a stopped server is given to leave through its own exit path before
/// it is signalled. Reaching it means the server did not act on EOF, which has
/// not been observed; the signal is there so that a stop is bounded rather than
/// hopeful.
const STOP_GRACE: Duration = Duration::from_secs(10);

const STOP_POLL: Duration = Duration::from_millis(50);

const MOVED_IN_MESSAGE: usize = 5;

/// Everything the server is started with. `modules` is the **superset** it
/// imports — whatever the requests ask for later has to be inside it, because a
/// resident environment is never grown (`Extract.lean:2707-2714`).
pub(crate) struct Serve {
    /// The Lean extractor, `extractor/build.sh`'s output.
    pub bin: PathBuf,
    /// The `lake` to borrow the target's environment with.
    pub lake: PathBuf,
    /// The package being documented, already canonicalised. `lake env` runs in
    /// it and nothing is ever written into it.
    pub target: PathBuf,
    pub jobs: usize,
    pub modules_file: PathBuf,
    /// The same list, parsed — [`Generation`] hashes exactly these.
    pub modules: Vec<String>,
    /// The start-up events file and the unused `--ir-dir` go here.
    pub work: PathBuf,
    /// Where the server writes the dependency closure's `name -> module` map, or
    /// `None` to write none.
    ///
    /// **Start-up configuration, not a request field, and that is the extractor's
    /// shape rather than a choice here**: the serve loop builds every request's
    /// `cfg` from the start-up one, so a map path given here is written once per
    /// request. That is acceptable because every round writes the same bytes —
    /// the map is derived from the *environment*, which a resident server imports
    /// once and never reloads (measured: five runs of one environment at 8,465,776 B,
    /// 5/5 byte-identical) — and because the cost is marginal, 0.9 s warm on top
    /// of an extraction that is already several seconds. [`Server::start`]'s
    /// `--link-index-omit` is the second and stronger reason for the same
    /// property.
    pub link_index: Option<PathBuf>,
    /// The token the extractor compares the map's `.key` sidecar against before
    /// deciding whether it has to write the map at all, or `None` to make it
    /// write unconditionally.
    ///
    /// **Start-up configuration for the same reason [`Self::link_index`] is**,
    /// and it has to be: a token that changed between two requests of one server
    /// would describe two different maps in one file. What it does **not** cover
    /// is the imported module set and this file's format; both are checked on the
    /// extractor's side, which is the only side that can see them.
    pub link_index_key: Option<String>,
}

/// A resident extractor and the world it is valid for.
///
/// **Started lazily, at the first request**: a run that extracts *nothing* — the
/// commonest answer this pipeline gives — then never pays 3 GB and an import for
/// a server it does not speak to. The generation is taken at the head of the run
/// either way, so the guard covers the delay.
pub(crate) struct Resident {
    serve: Serve,
    /// The world as it stood at the head of the run, before `detect` looked at
    /// it. Every later check is against this one value.
    generation: Generation,
    server: Option<Server>,
    requests: usize,
}

impl Resident {
    /// Records the world; starts nothing.
    pub(crate) fn new(serve: Serve) -> Result<Self, Failure> {
        if !serve.bin.is_file() {
            return Err(Failure::Refused {
                code: crate::EXIT_REFUSED,
                message: format!(
                    "--extractor-bin {}: not a file. It is `extractor/build.sh`'s output, 171 MB, \
                     built against the target's toolchain and therefore not committed",
                    serve.bin.display(),
                ),
            });
        }
        let generation = Generation::take(&serve.target, &serve.modules)?;
        Ok(Self {
            serve,
            generation,
            server: None,
            requests: 0,
        })
    }

    /// One extraction round, on the same interface as a `--extractor` program:
    /// a module list in, an IR tree and a timings record out.
    pub(crate) fn extract(
        &mut self,
        modules: &Path,
        ir_dir: &Path,
        timings: &Path,
    ) -> Result<(), Failure> {
        // The one-shot path's default, kept: both extraction paths have to leave
        // the events file in the same place under the same name, or two records
        // of the same run stop being comparable.
        let events = events_beside(timings);
        // The extractor appends, so a file an earlier round left behind would be
        // folded into this round's timings.
        let _ = fs::remove_file(&events);
        fs::create_dir_all(ir_dir).map_err(|source| Failure::io(ir_dir, &source))?;
        guard_target(&self.serve.target, ir_dir)?;

        let line = request_line(&[modules, &events, ir_dir])?;
        self.check_generation("before the request")?;
        let started = Instant::now();
        let reply = self.server()?.request(&line)?;
        self.requests += 1;
        // After as well as before, so that the interval the request ran in is one
        // the world provably did not move in.
        self.check_generation("after the request")?;

        let code = reply.split_whitespace().nth(1).unwrap_or("");
        if code != "0" {
            return Err(Failure::Refused {
                code: EXIT_EXTRACTOR,
                message: format!(
                    "the resident extractor answered `{reply}` for {}; the IR tree at {} is \
                     incomplete",
                    modules.display(),
                    ir_dir.display(),
                ),
            });
        }
        let counted = fold_timings(&crate::extract::Folded {
            events: &events,
            modules,
            jobs: self.serve.jobs,
            out: timings,
        })?;
        println!(
            "        served {counted} module(s) from the resident environment in {:.3}s",
            started.elapsed().as_secs_f64(),
        );
        Ok(())
    }

    /// How many extraction requests this run has sent.
    ///
    /// **The same field the stop line prints** — `serve stopped after N
    /// request(s)` — rather than a second tally: two counters of one thing are
    /// two things that can disagree, and this one is a gate's input.
    pub(crate) fn requests(&self) -> usize {
        self.requests
    }

    /// Stops the server, if one was ever started. Idempotent, and [`Drop`] is the
    /// backstop for every path that does not reach here.
    pub(crate) fn stop(&mut self) {
        if let Some(server) = self.server.take() {
            let requests = self.requests;
            let status = server.stop();
            println!("serve   stopped after {requests} request(s){status}");
        }
    }

    /// The running server, started on first use.
    fn server(&mut self) -> Result<&mut Server, Failure> {
        if self.server.is_none() {
            // No check before the spawn: [`Self::extract`] has just made one and
            // this is its next statement. A second reading here would be a second
            // answer to the same question, which is how two guards start
            // disagreeing.
            let server = Server::start(&self.serve)?;
            // The import window: the server is holding the oleans as they were at
            // some instant inside it, and this says which. The server is already
            // in hand, so a refusal here drops it — which is the stop.
            let generation = Generation::take(&self.serve.target, &self.serve.modules)?;
            let moved = self.generation.moved(&generation);
            if !moved.is_empty() {
                return Err(stale(&moved, "while the server was importing"));
            }
            println!(
                "serve   {} ({} jobs, generation {})",
                server.ready.trim(),
                self.serve.jobs,
                &self.generation.digest[..16],
            );
            self.server = Some(server);
        }
        Ok(self.server.as_mut().expect("just started"))
    }

    fn check_generation(&self, when: &str) -> Result<(), Failure> {
        let now = Generation::take(&self.serve.target, &self.serve.modules)?;
        let moved = self.generation.moved(&now);
        if moved.is_empty() {
            return Ok(());
        }
        Err(stale(&moved, when))
    }

    #[must_use]
    pub(crate) fn generation(&self) -> &str {
        &self.generation.digest
    }
}

impl Drop for Resident {
    fn drop(&mut self) {
        // Silent, unlike `stop`: a `Drop` that prints is a `Drop` that reports a
        // failure twice. The work is [`Server::drop`]'s either way.
        self.server.take();
    }
}

/// Modules whose oleans moved under a running server.
fn stale(moved: &[String], when: &str) -> Failure {
    let named: Vec<&str> = moved
        .iter()
        .take(MOVED_IN_MESSAGE)
        .map(String::as_str)
        .collect();
    let rest = moved.len().saturating_sub(named.len());
    Failure::Refused {
        code: crate::EXIT_REFUSED,
        message: format!(
            "the oleans moved {when}: {} module(s) — {}{}. The resident extractor imported the \
             world as it was at the head of this run and Lean cannot swap one module out of an \
             imported environment (`Extract.lean:2716-2721`), so every answer it has given since \
             is about the old world. Re-run after the build that is in flight has finished",
            moved.len(),
            named.join(", "),
            if rest > 0 {
                format!(" and {rest} more")
            } else {
                String::new()
            },
        ),
    }
}

/// The oleans of one module list, as Lake's own content hashes.
///
/// `--algorithm lake` rather than `sha256`: it reads the `<file>.hash` Lake
/// already wrote beside every olean, so this is 432 small reads instead of
/// 227 MB. It is the same function the ledger calls, over the same file set in
/// the same order, which is what makes "the world" one thing here rather than
/// two.
struct Generation {
    /// `(module, hash)`, in the module list's order. `-` is a module with no
    /// olean at all, which is a real state: it is what `detect` reports as
    /// removed.
    entries: Vec<(String, String)>,
    digest: String,
}

impl Generation {
    fn take(target: &Path, modules: &[String]) -> Result<Self, Failure> {
        let target = target.to_string_lossy();
        let target = target.trim_end_matches('/');
        let lib_dir = format!("{target}/.lake/build/lib/lean");
        let mut entries: Vec<(String, String)> = Vec::with_capacity(modules.len());
        for module in modules {
            let entry =
                hash_module(target, &lib_dir, module, &Algorithm::lake()).map_err(|source| {
                    Failure::Refused {
                        code: crate::EXIT_REFUSED,
                        message: format!(
                            "the resident extractor's generation over {lib_dir}: {source}"
                        ),
                    }
                })?;
            entries.push((
                module.clone(),
                entry.map_or_else(|| "-".to_owned(), |entry| entry.hash),
            ));
        }
        let joined: Vec<String> = entries
            .iter()
            .map(|(module, hash)| format!("{module} {hash}"))
            .collect();
        Ok(Self {
            digest: sha256_text(&joined.join("\n")),
            entries,
        })
    }

    /// The modules that differ between two takes, by name.
    ///
    /// The lists are the same module list in the same order, so this is a walk
    /// rather than a join — and if they ever are not, the length difference is
    /// reported rather than silently zipped away.
    fn moved(&self, other: &Self) -> Vec<String> {
        if self.digest == other.digest && self.entries.len() == other.entries.len() {
            return Vec::new();
        }
        let mut moved: Vec<String> = Vec::new();
        for (before, after) in self.entries.iter().zip(&other.entries) {
            if before != after {
                moved.push(before.0.clone());
            }
        }
        for extra in self
            .entries
            .iter()
            .skip(other.entries.len())
            .chain(other.entries.iter().skip(self.entries.len()))
        {
            moved.push(extra.0.clone());
        }
        moved
    }
}

struct Server {
    child: Child,
    /// The request channel. `Option` because stopping is "close this".
    stdin: Option<ChildStdin>,
    stdout: BufReader<ChildStdout>,
    /// `<work>/serve.out`: every line the server printed, protocol and phase
    /// report alike, in order. Written and never read back.
    log: File,
    ready: String,
}

impl Server {
    fn start(serve: &Serve) -> Result<Self, Failure> {
        fs::create_dir_all(&serve.work).map_err(|source| Failure::io(&serve.work, &source))?;
        let events = serve.work.join("serve-events.jsonl");
        let _ = fs::remove_file(&events);
        // Trap 1 in the heading: named, and never written to.
        let unused_ir = serve.work.join("serve-ir-unused");
        let log_path = serve.work.join("serve.out");
        let log = File::create(&log_path).map_err(|source| Failure::io(&log_path, &source))?;

        let mut command = Command::new(&serve.lake);
        command
            .current_dir(&serve.target)
            .arg("env")
            .arg(&serve.bin)
            .arg(&serve.modules_file)
            .arg(&events)
            .args(FIXED_FLAGS)
            .arg("--jobs")
            .arg(serve.jobs.to_string())
            .arg("--ir-dir")
            .arg(&unused_ir);
        if let Some(link_index) = &serve.link_index {
            command.arg("--link-index").arg(link_index);
            // The map leaves out the groups of the modules named here, and
            // **`modules_file` is the right list precisely because it is the
            // start-up one, fixed for the life of the server**. A request's own
            // `<modules.txt>` is a *subset* — the round loop extracts what went
            // stale — so deriving the omit set from the request would make the
            // map's bytes depend on which round happened to write it, and the
            // map's SHA-256 is in `renderKey`. It is also the package's own
            // modules, which the renderer answers out of the IR-derived index
            // before it ever reads the `.lidx`. The extractor's serve loop keeps
            // `linkIndexOmitPath` from start-up and never lets a request replace
            // it.
            command.arg("--link-index-omit").arg(&serve.modules_file);
            // With the token the extractor may decide the map on disk is already
            // the one it would write and skip the walk that produces it (490,287
            // constants, 1.2 s warm). Without it — `None` — it writes
            // unconditionally, which is what every caller outside this pipeline
            // gets and what the flag's absence has to keep meaning.
            if let Some(key) = &serve.link_index_key {
                command.arg("--link-index-key").arg(key);
            }
        }
        command
            .arg("--serve")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // Trap 2 in the heading.
            .stderr(Stdio::inherit());
        let mut child = command.spawn().map_err(|source| Failure::Refused {
            code: EXIT_EXTRACTOR,
            message: format!(
                "{} env {} --serve: {source}",
                serve.lake.display(),
                serve.bin.display(),
            ),
        })?;
        let stdin = child.stdin.take().expect("stdin was piped");
        let stdout = child.stdout.take().expect("stdout was piped");
        let mut server = Self {
            child,
            stdin: Some(stdin),
            stdout: BufReader::new(stdout),
            log,
            ready: String::new(),
        };
        server.ready = server.wait_for("ready ")?;
        Ok(server)
    }

    /// Writes one request and returns its `ok` line.
    fn request(&mut self, line: &str) -> Result<String, Failure> {
        let stdin = self.stdin.as_mut().ok_or_else(|| {
            Failure::Failed("the resident extractor was already stopped".to_owned())
        })?;
        stdin
            .write_all(line.as_bytes())
            .and_then(|()| stdin.flush())
            .map_err(|source| Failure::Refused {
                code: EXIT_EXTRACTOR,
                message: format!("writing to the resident extractor: {source}"),
            })?;
        self.wait_for("ok ")
    }

    /// The next line with this prefix, with everything before it logged.
    ///
    /// **Located by prefix, not by position**: the extractor prints a
    /// human-readable phase report to the same stdout as the protocol, so
    /// counting lines would be counting the report.
    fn wait_for(&mut self, prefix: &str) -> Result<String, Failure> {
        loop {
            let mut line = String::new();
            let read = self
                .stdout
                .read_line(&mut line)
                .map_err(|source| Failure::Refused {
                    code: EXIT_EXTRACTOR,
                    message: format!("reading from the resident extractor: {source}"),
                })?;
            if read == 0 {
                // EOF: the server is gone. Its stderr already reached the
                // caller's, so what is added here is what was being waited for
                // and what the process exited with.
                let status = self.child.wait().ok().and_then(|status| status.code());
                return Err(Failure::Refused {
                    code: EXIT_EXTRACTOR,
                    message: format!(
                        "the resident extractor exited {} before `{}`",
                        status.map_or_else(|| "on a signal".to_owned(), |code| code.to_string()),
                        prefix.trim(),
                    ),
                });
            }
            let _ = self.log.write_all(line.as_bytes());
            let text = line.trim_end_matches(['\n', '\r']).to_owned();
            if text.starts_with(prefix) {
                return Ok(text);
            }
            if text.starts_with("err ") {
                return Err(Failure::Refused {
                    code: EXIT_EXTRACTOR,
                    message: format!("the resident extractor rejected the request: {text}"),
                });
            }
        }
    }

    /// Closes the pipe and waits, then signals. Returns what to say about it.
    fn stop(mut self) -> String {
        let status = self.shut_down();
        match status {
            Some(0) => String::new(),
            Some(code) => format!(" (the server exited {code})"),
            None => " (the server had to be signalled)".to_owned(),
        }
    }

    /// The whole of the teardown, so that [`Drop`] and [`Self::stop`] cannot
    /// drift apart. `None` means it did not leave on its own and was signalled.
    fn shut_down(&mut self) -> Option<i32> {
        // EOF. The server's loop ends on it and returns 0 through its own exit
        // path rather than being signalled.
        drop(self.stdin.take());
        let deadline = Instant::now() + STOP_GRACE;
        loop {
            match self.child.try_wait() {
                Ok(Some(status)) => return Some(status.code().unwrap_or(-1)),
                Ok(None) => {}
                Err(_) => break,
            }
            if Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(STOP_POLL);
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        None
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if self.stdin.is_some() {
            self.shut_down();
        }
    }
}

/// One request line, or a refusal naming the path that cannot be sent.
///
/// The protocol splits on spaces and tabs (`Extract.lean:2748`), so a path with
/// whitespace in it does not fail — it arrives as two shorter paths and the
/// server writes an IR tree somewhere nobody named. It is therefore refused
/// before anything is written.
///
/// The paths are absolute because the server's working directory is the target:
/// a relative one resolves against the package being documented, which is the one
/// directory this project never writes into.
fn request_line(paths: &[&Path]) -> Result<String, Failure> {
    let mut line = String::new();
    for path in paths {
        let text = crate::extract::absolute(path)
            .to_string_lossy()
            .into_owned();
        if text.chars().any(char::is_whitespace) {
            return Err(Failure::Refused {
                code: crate::EXIT_REFUSED,
                message: format!(
                    "the resident extractor's protocol is one space-separated line per request \
                     (`Extract.lean:2748`), so a path with whitespace in it cannot be sent: {text}"
                ),
            });
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(&text);
    }
    line.push('\n');
    Ok(line)
}

/// The same rule `litedoc4 extract` states, for the same reason: the package
/// being documented is opened read-only and nothing is ever written into it.
fn guard_target(target: &Path, ir_dir: &Path) -> Result<(), Failure> {
    crate::extract::refuse_inside(target, "the target", ir_dir, "the round's --ir-dir", "")
}

/// The protocol, the guard and the teardown, against a fake extractor.
///
/// **The oracle for the extraction itself is elsewhere**: that the resident path
/// and the one-shot path write the same IR over the same module list needs a Lean
/// toolchain and a built package, so it is a gate and not a test. What is here is
/// what the gate cannot reach — the failure shapes. Every one of them ends with a
/// 3 GB process either stopped or never started, so this is also the only place
/// "no process is leaked" is asserted rather than observed once by hand.
#[cfg(all(test, unix))]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    struct World {
        root: PathBuf,
        target: PathBuf,
        modules: Vec<String>,
        modules_file: PathBuf,
        work: PathBuf,
        lake: PathBuf,
        bin: PathBuf,
    }

    impl World {
        fn new(what: &str, code: &str) -> Self {
            Self::with_hooks(what, code, ":", ":")
        }

        /// The two hooks are `sh`, run at the two moments a real build could
        /// land: `importing` before the server reports `ready`, `serving` inside
        /// the request loop before the reply. They are how a test makes the world
        /// move under a server that is already running.
        fn with_hooks(what: &str, code: &str, importing: &str, serving: &str) -> Self {
            let root = scratch(what);
            let target = root.join("target");
            let modules: Vec<String> = vec!["Pkg.A".to_owned(), "Pkg.B".to_owned()];
            for module in &modules {
                write_olean(&target, module, &format!("{module} v1"));
            }
            let modules_file = root.join("modules.txt");
            fs::write(&modules_file, modules.join("\n") + "\n").expect("writable");

            let lake = root.join("lake");
            write_executable(
                &lake,
                "#!/bin/sh\n[ \"$1\" = env ] || exit 9\nshift\nexec \"$@\"\n",
            );

            // Records its argv and its pid once, answers every request, and
            // leaves on EOF the way `Extract.lean:2747` leaves. It also prints a
            // report line to the same stdout as the protocol, which a reply found
            // by position rather than by prefix would find instead.
            let bin = root.join("extract");
            write_executable(
                &bin,
                &format!(
                    "#!/bin/sh\n\
                     printf '%s\\n' \"$$\" > {pid}\n\
                     : > {argv}\n\
                     for a in \"$@\"; do printf '%s\\n' \"$a\" >> {argv}; done\n\
                     {importing}\n\
                     printf 'ready 2500000 99 2\\n'\n\
                     while read -r mods events irdir; do\n\
                     \x20 [ -z \"$mods\" ] && exit 0\n\
                     \x20 printf '%s %s %s\\n' \"$mods\" \"$events\" \"$irdir\" >> {reqs}\n\
                     \x20 {serving}\n\
                     \x20 mkdir -p \"$irdir\"\n\
                     \x20 printf '{{\"phase\":\"stage4b.importModules\",\"pid\":1,\"us\":7,\"resident\":1}}\\n' > \"$events\"\n\
                     \x20 printf 'served, and this line is not a reply\\n'\n\
                     \x20 printf 'ok {code} 4242\\n'\n\
                     done\n",
                    pid = quoted(&root.join("server.pid")),
                    argv = quoted(&root.join("argv")),
                    reqs = quoted(&root.join("requests")),
                ),
            );

            Self {
                work: root.join("work"),
                target,
                modules,
                modules_file,
                lake,
                bin,
                root,
            }
        }

        fn resident(&self) -> Result<Resident, Failure> {
            Resident::new(Serve {
                link_index: None,
                // No map, so nothing to key: the token is only ever paired with
                // `--link-index`.
                link_index_key: None,
                bin: self.bin.clone(),
                lake: self.lake.clone(),
                target: fs::canonicalize(&self.target).expect("a real directory"),
                jobs: 3,
                modules_file: self.modules_file.clone(),
                modules: self.modules.clone(),
                work: self.work.clone(),
            })
        }

        fn extract(&self, resident: &mut Resident, round: usize) -> Result<(), Failure> {
            resident.extract(
                &self.modules_file,
                &self.root.join(format!("inc-ir-{round}")),
                &self.work.join(format!("extract-timings-{round}.json")),
            )
        }

        fn argv(&self) -> Vec<String> {
            read_lines(&self.root.join("argv"))
        }

        fn requests(&self) -> Vec<String> {
            read_lines(&self.root.join("requests"))
        }

        fn server_pid(&self) -> String {
            fs::read_to_string(self.root.join("server.pid"))
                .expect("the server recorded its pid")
                .trim()
                .to_owned()
        }
    }

    impl Drop for World {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn one_environment_answers_every_round_and_the_reply_is_found_by_prefix() {
        let world = World::new("rounds", "0");
        let mut resident = world.resident().expect("a resident");
        world.extract(&mut resident, 1).expect("round 1");
        let pid = world.server_pid();
        world.extract(&mut resident, 2).expect("round 2");

        assert_eq!(world.requests().len(), 2, "two requests");
        assert_eq!(
            world.server_pid(),
            pid,
            "one process answered both: the whole point of residency",
        );
        // The reply was located by prefix, not by position — the fake prints a
        // report line before it.
        for round in [1, 2] {
            let path = world.work.join(format!("extract-timings-{round}.json"));
            let record: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&path).expect("a timings record"))
                    .expect("valid JSON");
            assert_eq!(record["importModules"], serde_json::json!(0.000_007));
            assert_eq!(record["importModules:resident"], serde_json::json!(1));
            assert_eq!(record["targetModules"], serde_json::json!(2));
            // The server's, not a request's: `Extract.lean:2751` carries the
            // start-up `cfg` into every request.
            assert_eq!(record["jobsRequested"], serde_json::json!(3));
        }
        assert!(
            world.root.join("inc-ir-2").is_dir(),
            "the IR directory is created before the request",
        );
        drop(resident);
        assert!(
            !alive(&pid),
            "the server is gone once nobody holds the pipe"
        );
    }

    #[test]
    fn the_start_up_command_line_carries_an_ir_dir_that_no_request_ever_names() {
        let world = World::new("start-up", "0");
        let mut resident = world.resident().expect("a resident");
        world.extract(&mut resident, 1).expect("round 1");

        let argv = world.argv();
        assert_eq!(argv[0], world.modules_file.display().to_string());
        assert_eq!(
            argv[1],
            world.work.join("serve-events.jsonl").display().to_string()
        );
        for flag in FIXED_FLAGS {
            assert!(argv.iter().any(|arg| arg == flag), "{flag}: {argv:?}");
        }
        assert_eq!(argv.last().map(String::as_str), Some("--serve"));
        let at = argv.iter().position(|arg| arg == "--jobs").expect("--jobs");
        assert_eq!(argv[at + 1], "3");
        // Trap 1 in this file's heading, asserted: the value is a directory a
        // request always replaces, and it stays unwritten.
        let at = argv
            .iter()
            .position(|arg| arg == "--ir-dir")
            .expect("--ir-dir is passed at start-up");
        let unused = PathBuf::from(&argv[at + 1]);
        assert_eq!(unused, world.work.join("serve-ir-unused"));
        assert!(!unused.exists(), "no request ever named it");
        assert!(
            world.requests()[0].ends_with(&world.root.join("inc-ir-1").display().to_string()),
            "every request carries its own IR directory: {:?}",
            world.requests(),
        );
    }

    #[test]
    fn a_request_the_server_failed_is_exit_four() {
        let world = World::new("failed-request", "7");
        let mut resident = world.resident().expect("a resident");
        let failure = world.extract(&mut resident, 1).expect_err("exit 4");
        let (code, message) = refusal(&failure);
        assert_eq!(code, EXIT_EXTRACTOR);
        assert!(message.contains("ok 7 4242"), "{message}");
        assert!(message.contains("incomplete"), "{message}");
    }

    #[test]
    fn oleans_that_move_under_a_running_server_stop_the_run() {
        // The hook rewrites one olean's Lake hash while the server is answering,
        // which is what a `lake build` landing mid-run looks like to this guard.
        let world = World::with_hooks(
            "stale",
            "0",
            ":",
            "printf 'moved\\n' > \"$(dirname \"$0\")/target/.lake/build/lib/lean/Pkg/B.olean.hash\"",
        );
        let mut resident = world.resident().expect("a resident");
        let pid_before = world.requests();
        assert!(pid_before.is_empty());
        let failure = world.extract(&mut resident, 1).expect_err("exit 3");
        let (code, message) = refusal(&failure);
        assert_eq!(code, 3, "{message}");
        assert!(message.contains("Pkg.B"), "the module is named: {message}");
        assert!(
            !message.contains("Pkg.A"),
            "only the one that moved: {message}"
        );
        assert!(message.contains("after the request"), "{message}");
        let pid = world.server_pid();
        drop(resident);
        assert!(!alive(&pid), "a refusal does not leak a 3 GB process");
    }

    #[test]
    fn oleans_that_move_while_the_server_imports_stop_the_run() {
        // The import window — between the stamp taken before the spawn and the
        // one taken when `ready` lands. A `lake build` landing there is the worst
        // case: the environment is a mixture, and nothing the server says
        // afterwards names which half a given answer came from.
        let world = World::with_hooks(
            "stale-import",
            "0",
            "printf 'moved\\n' > \"$(dirname \"$0\")/target/.lake/build/lib/lean/Pkg/A.olean.hash\"",
            ":",
        );
        let mut resident = world.resident().expect("a resident");
        let failure = failed(world.extract(&mut resident, 1));
        let (code, message) = refusal(&failure);
        assert_eq!(code, 3, "{message}");
        assert!(message.contains("Pkg.A"), "{message}");
        assert!(
            message.contains("while the server was importing"),
            "the check that closes the import window caught it: {message}",
        );
        let pid = world.server_pid();
        drop(resident);
        assert!(!alive(&pid), "the half-built server is stopped, not leaked");
        assert!(
            world.requests().is_empty(),
            "and it was never asked anything",
        );
    }

    #[test]
    fn a_server_that_dies_is_reported_rather_than_waited_for() {
        let world = World::new("dead", "0");
        // A `lake` that exits without ever printing `ready`: the read gets EOF
        // rather than a reply.
        write_executable(&world.lake, "#!/bin/sh\nexit 3\n");
        let mut resident = world.resident().expect("a resident");
        let failure = world.extract(&mut resident, 1).expect_err("no server");
        let (code, message) = refusal(&failure);
        assert_eq!(code, EXIT_EXTRACTOR);
        assert!(message.contains("exited 3"), "{message}");
        assert!(
            message.contains("ready"),
            "what it was waiting for: {message}"
        );
    }

    #[test]
    fn a_path_with_whitespace_is_refused_before_the_server_is_started() {
        let world = World::new("whitespace", "0");
        let mut resident = world.resident().expect("a resident");
        let failure = resident
            .extract(
                &world.modules_file,
                &world.root.join("inc ir 1"),
                &world.work.join("extract-timings-1.json"),
            )
            .expect_err("refused");
        let (code, message) = refusal(&failure);
        assert_eq!(code, 3);
        assert!(message.contains("space-separated"), "{message}");
        assert!(
            !world.root.join("server.pid").exists(),
            "nothing was started for a request that cannot be sent",
        );
    }

    #[test]
    fn an_ir_dir_inside_the_target_is_refused() {
        let world = World::new("ir-in-target", "0");
        let mut resident = world.resident().expect("a resident");
        let failure = resident
            .extract(
                &world.modules_file,
                &world.target.join("inc-ir-1"),
                &world.work.join("extract-timings-1.json"),
            )
            .expect_err("refused");
        let (code, message) = refusal(&failure);
        assert_eq!(code, 3);
        assert!(message.contains("read-only"), "{message}");
    }

    #[test]
    fn a_missing_extractor_binary_is_refused_before_anything_runs() {
        let world = World::new("no-bin", "0");
        fs::remove_file(&world.bin).expect("removable");
        let failure = failed(world.resident());
        let (code, message) = refusal(&failure);
        assert_eq!(code, 3);
        assert!(message.contains("extractor/build.sh"), "{message}");
    }

    /// The failure of a `Result` whose `Ok` side is not printable.
    fn failed<T>(result: Result<T, Failure>) -> Failure {
        match result {
            Ok(_) => panic!("expected a refusal"),
            Err(failure) => failure,
        }
    }

    fn refusal(failure: &Failure) -> (u8, String) {
        match failure {
            Failure::Refused { code, message } => (*code, message.clone()),
            Failure::Usage(message) | Failure::Failed(message) => {
                panic!("expected a refusal, got: {message}")
            }
            Failure::Answered(code) => panic!("expected a refusal, got exit {code}"),
        }
    }

    /// One module's olean and the `<file>.hash` Lake writes beside it, which is
    /// what `--algorithm lake` — and therefore [`Generation`] — reads.
    fn write_olean(target: &Path, module: &str, body: &str) {
        let path = target
            .join(".lake/build/lib/lean")
            .join(format!("{}.olean", module.replace('.', "/")));
        fs::create_dir_all(path.parent().expect("a parent")).expect("writable");
        fs::write(&path, body).expect("writable");
        // Lake's `.hash` is a content hash; here it is the content, which has
        // the one property this fixture needs — it moves when the olean moves.
        fs::write(path.with_extension("olean.hash"), format!("{body}\n")).expect("writable");
    }

    fn alive(pid: &str) -> bool {
        Command::new("kill")
            .args(["-0", pid])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }

    /// Writes a script and makes it runnable, **through a rename**.
    ///
    /// Linux returns `ETXTBSY` — exit 126 — when a file is `exec`'d while some
    /// process still holds a write descriptor to it, and `cargo test` runs these
    /// tests in parallel threads that fork: a sibling's `Command::spawn` inherits
    /// the descriptor this thread just wrote through, so the exec races the
    /// close. Renaming over the path hands the exec a fresh inode that no
    /// descriptor points at.
    ///
    /// **This is a fix for a measured symptom against a reasoned cause, and the
    /// cause is not itself measured**: CI went red once in eight pushes
    /// (measured 2026-08-18, run 32133544132) with `the resident extractor exited
    /// 126 before ` + "`ready`" + `, on a commit that changed only prose. macOS
    /// has never reproduced it, and a green run after this does not prove the
    /// diagnosis.
    fn write_executable(path: &Path, body: &str) {
        let tmp = path.with_extension("new");
        fs::write(&tmp, body).expect("writable");
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).expect("chmod");
        fs::rename(&tmp, path).expect("rename");
    }

    fn read_lines(path: &Path) -> Vec<String> {
        fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The temporary paths hold a pid and a counter, never a quote — but a path
    /// that reaches a shell script is quoted anyway, so the fixture cannot be the
    /// thing that breaks.
    fn quoted(path: &Path) -> String {
        format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
    }

    fn scratch(what: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "litedoc4-resident-{}-{}-{what}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).expect("the temporary directory is creatable");
        path
    }
}
