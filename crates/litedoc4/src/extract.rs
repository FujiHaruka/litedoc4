//! `litedoc4 extract` — one extractor process over a module list, and its phase
//! timers folded into one JSON object.
//!
//! [`fold_timings`], [`FIXED_FLAGS`] and [`resolve`] are the resident path's too
//! ([`crate::resident`]): the two paths differ in **who owns the process**, and
//! in nothing else that reaches a byte. Residency itself is not a flag here —
//! every `--serve*` spelling is refused by name below, with the reason.
//!
//! **A subcommand and not a library call**, unlike every other stage of the
//! pipeline:
//!
//! - **`litedoc4 incremental --extractor` already names a program**, whose
//!   contract is `<program> [<extractor-arg>…] --modules <list> --ir-dir <dir>
//!   --timings <file>` ([`crate::pipeline`]'s `Extractor`). A subcommand lets the
//!   product be its own extractor — `--extractor <litedoc4> --extractor-arg
//!   extract` — **without closing the seam**: the pipeline's tests still hand it
//!   a fake, so testing the pipeline still does not need Lean and a 20-second
//!   extraction.
//! - **The Lean binary cannot be linked in.** It is 171 MB, it is built by
//!   `extractor/build.sh` against the *target's* toolchain, and it has to run
//!   with that target as its working directory. `lake env` is what sets that
//!   environment up, so a process boundary exists whatever this file does.
//!
//! **The four flags in [`FIXED_FLAGS`] are not configurable**, because they *are*
//! the IR the rest of the product reads: `--tagged-code` is what makes it schema
//! 5, `--refs` fills the reference arrays that link resolution and `ownership`
//! both consume, and `--write-ir` is the point. A run with any of them off
//! produces a tree that parses and renders wrongly, so they are refused by name
//! rather than silently accepted or silently ignored.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::{Failure, usage};

/// The same number [`crate::pipeline`] reports when a child extractor fails: when
/// this command *is* that child, the code a caller sees is the same whichever of
/// the two produced it.
pub(crate) const EXIT_EXTRACTOR: u8 = 4;

/// What "IR schema 5" means, minus the two flags the caller chooses.
pub(crate) const FIXED_FLAGS: [&str; 4] = ["--equations", "--refs", "--write-ir", "--tagged-code"];

pub fn extract(args: &[String]) -> Result<(), Failure> {
    let mut modules: Option<PathBuf> = None;
    let mut ir_dir: Option<PathBuf> = None;
    let mut timings: Option<PathBuf> = None;
    let mut events: Option<PathBuf> = None;
    let mut link_index: Option<PathBuf> = None;
    let mut link_index_omit: Option<PathBuf> = None;
    let mut link_index_key: Option<String> = None;
    let mut jobs: usize = 1;
    let mut bin: Option<PathBuf> = None;
    let mut target: Option<PathBuf> = None;
    let mut lake: Option<PathBuf> = None;

    let mut args = crate::cli::Args::new(args);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--modules" => modules = Some(args.value("--modules")?.into()),
            "--ir-dir" => ir_dir = Some(args.value("--ir-dir")?.into()),
            "--timings" => timings = Some(args.value("--timings")?.into()),
            "--events" => events = Some(args.value("--events")?.into()),
            "--jobs" => jobs = args.number("--jobs")?,
            // The dependency closure's `name -> module` map, written out of the
            // environment this process has imported for the extraction anyway.
            // Optional because the map is a whole-package artefact and an
            // extraction is often a subset.
            "--link-index" => link_index = Some(args.value("--link-index")?.into()),
            // The modules whose own declaration groups the map leaves out. The
            // renderer answers those names out of the IR-derived index before it
            // reads the `.lidx` at all, so leaving them out renders the same
            // bytes — and it is the only part of the map an edit to the package
            // moves, which is what makes the map stop invalidating `renderKey`.
            //
            // A path, not a derivation from `--modules`: this command extracts a
            // *subset* as often as not, and the omit set has to be the package,
            // not this round's slice of it.
            "--link-index-omit" => link_index_omit = Some(args.value("--link-index-omit")?.into()),
            // An opaque token, passed through verbatim: the caller's promise
            // about the two inputs the extractor cannot see (the oleans behind
            // the imported modules, and the omit list's bytes). It leaves the map
            // alone while the token matches the sidecar `<map>.key` *and* the
            // map's `@` section still matches the environment.
            //
            // Not derived here from `--target`, unlike `litedoc4 build`'s: this
            // command is the seam, and a caller driving it in a loop is the one
            // that knows what its own runs have in common.
            // `pipeline::serve_options` is the only place in the product that
            // computes one.
            "--link-index-key" => link_index_key = Some(args.value("--link-index-key")?),
            "--extractor-bin" => bin = Some(args.value("--extractor-bin")?.into()),
            "--target" => target = Some(args.value("--target")?.into()),
            "--lake" => lake = Some(args.value("--lake")?.into()),
            // Refused by name rather than as "unknown argument": each is a real
            // flag of the program behind this one, so what a caller needs to
            // hear is why it is not offered.
            "--serve" | "--serve-dir" | "--serve-from" => {
                return usage(format!(
                    "{arg} is not an `extract` flag: residency is `litedoc4 incremental --serve`. \
                     A server that answers one request and stops is this command with a \
                     protocol in front of it — the environment is still imported once per \
                     extraction — so the only caller it can pay off for is the round loop, which \
                     owns the server for the whole run. `--serve-dir` is not offered anywhere: a \
                     server this process did not start is one whose olean generation it cannot \
                     vouch for, and that is where correctness comes from (measured)",
                ));
            }
            flag if FIXED_FLAGS.contains(&flag) => {
                return usage(format!(
                    "{arg} is not a flag here: it is always on. Those four are what \"IR schema \
                     5\" means, and an IR written without one of them parses and renders wrongly \
                     rather than failing. See this file's heading",
                ));
            }
            "--no-attrs" | "--no-inst-index" | "--no-member-extra" => {
                return usage(format!(
                    "{arg} is an ablation, not a product flag: it subtracts one of three \
                     extractor additions so its cost can be measured, and the resulting \
                     index.json carries an `ablations` list precisely because the tree is not \
                     renderable",
                ));
            }
            "--decl-profile" | "--pp-breakdown" | "--dump" | "--dump-modules" | "--dump-refs"
            | "--dump-tactics" | "--only" | "--open" | "--tag" | "--skip-analyze"
            | "--tactics-emulate" | "--tactics-probe" => {
                return usage(format!(
                    "{arg} is a measurement or inspection flag of the extractor, not a product \
                     one. Run `extractor/build/extract` directly for it — the command line is in \
                     `Extract.lean`'s header",
                ));
            }
            "--help" | "-h" => return crate::cli::help(),
            other => return crate::cli::unknown(other),
        }
    }

    let Some(modules) = modules else {
        return usage(
            "--modules <file> is required: the module list to extract, one name per line",
        );
    };
    let Some(ir_dir) = ir_dir else {
        return usage(
            "--ir-dir <dir> is required and has no default: the extractor's own default was one \
             session's scratchpad path and is gone. An IR tree written somewhere the caller did \
             not name is worse than none",
        );
    };
    let Some(timings) = timings else {
        return usage(
            "--timings <file> is required: it is the extractor's phase timers folded into one \
             JSON object, and `litedoc4 incremental` merges it into the run's record",
        );
    };
    if jobs == 0 {
        return usage("--jobs must be at least 1");
    }
    // Refused rather than ignored, although the extractor itself tolerates the
    // combination: a flag that does nothing is the shape of bug this project
    // keeps finding — the run looks right and the artefact is not the one that
    // was asked for.
    if link_index_omit.is_some() && link_index.is_none() {
        return usage(
            "--link-index-omit without --link-index does nothing: it names the modules whose \
             declaration groups are left out of the map, and no map is being written",
        );
    }
    // The same rule: with no map there is nothing to reuse and nothing to write
    // a `.key` sidecar beside, so the token would be accepted and dropped.
    if link_index_key.is_some() && link_index.is_none() {
        return usage(
            "--link-index-key without --link-index does nothing: it is the token that lets the \
             extractor leave an already-correct map alone, and no map is being written or read",
        );
    }
    // Flag, then environment, then nothing: no default path, because both of
    // these are absolute paths on somebody's machine.
    let bin = or_env(bin, "EXTRACT_BIN");
    let Some(bin) = bin else {
        return usage(
            "--extractor-bin <path> is required (or EXTRACT_BIN): the Lean extractor built by \
             `extractor/build.sh`, which is 171 MB and is therefore not committed. There is no \
             default — the binary is built against the target's toolchain, so a path baked in \
             here would be right on exactly one machine",
        );
    };
    let target = or_env(target, "TARGET_REPO");
    let Some(target) = target else {
        return usage(
            "--target <repo> is required (or TARGET_REPO): the Lean package being documented. \
             `lake env` runs inside it, which is how the extractor gets the oleans and the \
             search path without litedoc4 owning a toolchain",
        );
    };
    // `lake` does get a default because it is a name looked up on PATH, not a
    // path: elan installs a shim under that name, and the shim is what picks the
    // toolchain the target pins. Hard-coding `~/.elan/bin/lake` would be the
    // more specific and the more fragile of the two.
    let lake = or_env(lake, "LAKE").unwrap_or_else(|| PathBuf::from("lake"));

    let target = fs::canonicalize(&target).map_err(|source| Failure::Refused {
        code: crate::EXIT_REFUSED,
        message: format!("--target {}: {source}", target.display()),
    })?;
    // The child's own path, for the same reason as the three below: `lake env
    // ./extract` inside the target would look for it in the target.
    let bin = absolute(&bin);
    refuse_inside(&target, "--target", &ir_dir, "--ir-dir", "")?;
    // The same rule for the map, written by the same child with the same working
    // directory.
    if let Some(path) = &link_index {
        refuse_inside(&target, "--target", path, "--link-index", "")?;
    }

    let events = events.unwrap_or_else(|| events_beside(&timings));
    // **Every path handed to the child is made absolute first, and the guard
    // above is why** (measured 2026-08-15). `lake env` runs inside `--target`, so a
    // relative path on that command line resolves against the package being
    // documented: `--ir-dir out` passes the guard (it resolves against *this*
    // process's directory, which is not under the target) and the extractor then
    // writes the IR tree into `<target>/out` — a write into the target arriving
    // through the one command that says it never writes there.
    let ir_dir = absolute(&ir_dir);
    let modules = absolute(&modules);
    let events = absolute(&events);
    // Removed rather than truncated on open: the extractor appends, so a stale
    // file from an earlier round would be folded into this round's timings.
    let _ = fs::remove_file(&events);
    crate::pipeline::create_dir(&ir_dir)?;

    let link_index = link_index.as_deref().map(absolute);
    // Made absolute for the reason above, but **not** guarded against being
    // inside the target: the difference is the direction of the I/O. `--ir-dir`
    // and `--link-index` are written; this one is read, and a module list that
    // lives inside the package being documented is an odd place to keep it, not
    // a write into it.
    let link_index_omit = link_index_omit.as_deref().map(absolute);
    let mut command = Command::new(&lake);
    command
        .current_dir(&target)
        .arg("env")
        .arg(&bin)
        .arg(&modules)
        .arg(&events)
        .args(FIXED_FLAGS)
        .arg("--jobs")
        .arg(jobs.to_string())
        .arg("--ir-dir")
        .arg(&ir_dir);
    if let Some(path) = &link_index {
        if let Some(parent) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
            crate::pipeline::create_dir(parent)?;
        }
        command.arg("--link-index").arg(path);
        if let Some(omit) = &link_index_omit {
            command.arg("--link-index-omit").arg(omit);
        }
        if let Some(key) = &link_index_key {
            command.arg("--link-index-key").arg(key);
        }
    }
    command
        // The extractor's stdout is a human-readable phase report; the
        // machine-readable copy of the same numbers is the events file, which is
        // what the timings are folded from. stderr is inherited, so a Lean error
        // still reaches the caller.
        .stdout(Stdio::null());
    let status = command.status().map_err(|source| Failure::Refused {
        code: EXIT_EXTRACTOR,
        message: format!("{} env {}: {source}", lake.display(), bin.display()),
    })?;
    if !status.success() {
        return Err(Failure::Refused {
            code: EXIT_EXTRACTOR,
            message: format!(
                "the extractor exited {} for {}; the IR tree at {} is incomplete",
                status
                    .code()
                    .map_or_else(|| "on a signal".to_owned(), |code| code.to_string()),
                modules.display(),
                ir_dir.display(),
            ),
        });
    }

    let counted = fold_timings(&Folded {
        events: &events,
        modules: &modules,
        jobs,
        out: &timings,
    })?;
    println!(
        "extract {counted} module(s) -> {} (timings {})",
        ir_dir.display(),
        timings.display(),
    );
    Ok(())
}

/// An empty variable counts as unset: `TARGET_REPO=` in a wrapper script is how
/// a shell spells "I did not set this", and taking it literally would make the
/// target the filesystem root.
pub(crate) fn or_env(flag: Option<PathBuf>, name: &str) -> Option<PathBuf> {
    flag.or_else(|| {
        std::env::var_os(name)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
    })
}

/// Refuses `candidate` if it resolves inside `container`.
///
/// **The only copy of this decision** — [`crate::pipeline`], [`crate::resident`]
/// and [`crate::build`] all call it rather than restate it.
///
/// Resolved with [`resolve`], not compared as given: `/tmp/x` and
/// `/private/tmp/x` are one directory on this platform, and a guard that says
/// otherwise is a guard that can be walked around by spelling.
pub(crate) fn refuse_inside(
    container: &Path,
    container_flag: &str,
    candidate: &Path,
    what: &str,
    extra: &str,
) -> Result<(), Failure> {
    let resolved = resolve(candidate);
    if !resolved.starts_with(container) {
        return Ok(());
    }
    Err(Failure::Refused {
        code: crate::EXIT_REFUSED,
        message: format!(
            "{what} {} is inside {container_flag} {}: the package being documented is opened \
             read-only and nothing is ever written into it{extra}",
            resolved.display(),
            container.display(),
        ),
    })
}

/// `<timings without .json>-events.jsonl`.
///
/// **One spelling, and that is the point**: both extraction paths have to leave
/// the events file in the same place under the same name, or two records of the
/// same run stop being comparable.
pub(crate) fn events_beside(timings: &Path) -> PathBuf {
    let text = timings.to_string_lossy();
    PathBuf::from(format!(
        "{}-events.jsonl",
        text.strip_suffix(".json").unwrap_or(&text)
    ))
}

/// `path`, made absolute **without touching what it spells** — the one for a
/// command line, where [`resolve`] is the one for a comparison. Resolving
/// symlinks would hand the child a path the caller did not write (`/tmp/x`
/// becomes `/private/tmp/x` on this platform). Only the *relative* case has to
/// change, because the child's working directory is the target and a relative
/// path there means somewhere inside the package being documented.
pub(crate) fn absolute(path: &Path) -> PathBuf {
    if path.is_absolute() {
        return path.to_path_buf();
    }
    std::env::current_dir().map_or_else(|_| path.to_path_buf(), |cwd| cwd.join(path))
}

/// `path`, made absolute and with every existing component's symlinks resolved.
///
/// Not [`fs::canonicalize`], which needs the whole path to exist: the guard runs
/// **before** the IR directory is created, because creating it is already a
/// write and a write inside the target is the one thing the guard prevents. So
/// the deepest existing ancestor is canonicalised and the rest appended.
pub(crate) fn resolve(path: &Path) -> PathBuf {
    let full = absolute(path);
    let mut prefix = full.as_path();
    let mut tail: Vec<&std::ffi::OsStr> = Vec::new();
    loop {
        if let Ok(real) = fs::canonicalize(prefix) {
            let mut out = real;
            for part in tail.iter().rev() {
                out.push(part);
            }
            return out;
        }
        match (prefix.file_name(), prefix.parent()) {
            (Some(name), Some(parent)) => {
                tail.push(name);
                prefix = parent;
            }
            _ => return full,
        }
    }
}

pub(crate) struct Folded<'a> {
    pub events: &'a Path,
    pub modules: &'a Path,
    pub jobs: usize,
    pub out: &'a Path,
}

/// Folds the extractor's events into one timings record, and returns the module
/// count it also writes as `targetModules`.
///
/// ```text
/// {"phase":"stage4b.importModules","pid":83359,"us":2498376,"directImports":432}
///   -> {"importModules": 2.498376, "importModules:directImports": 432}
/// ```
///
/// The `stage4b.` prefix the extractor writes is dropped; `us` becomes seconds
/// under the phase's own name, so every duration in this project's records is in
/// one unit; every other key except `pid` becomes `<phase>:<key>` **with its
/// JSON value carried through untouched**, because the extractor emits a mixture
/// of numbers, booleans and strings there and re-typing any of them would make
/// two records of the same run disagree over the same measurement. A
/// `<phase>:<name>Us` key is a sub-phase duration, not a count.
pub(crate) fn fold_timings(folded: &Folded<'_>) -> Result<usize, Failure> {
    let Folded {
        events,
        modules,
        jobs,
        out,
    } = *folded;
    let text = fs::read_to_string(events).map_err(|source| Failure::io(events, &source))?;
    // `preserve_order` is on for the workspace, so this comes out in the order
    // the extractor emitted the phases.
    let mut record = serde_json::Map::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let event: serde_json::Value =
            serde_json::from_str(line).map_err(|source| Failure::io(events, &source))?;
        let Some(object) = event.as_object() else {
            return Err(Failure::Failed(format!(
                "{}: an event that is not a JSON object",
                events.display()
            )));
        };
        let phase = object
            .get("phase")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .replace("stage4b.", "");
        let micros = object.get("us").and_then(serde_json::Value::as_f64);
        record.insert(
            phase.clone(),
            serde_json::json!(micros.unwrap_or(0.0) / 1e6),
        );
        for (key, value) in object {
            if key != "phase" && key != "pid" && key != "us" {
                record.insert(format!("{phase}:{key}"), value.clone());
            }
        }
    }

    let listed = fs::read_to_string(modules).map_err(|source| Failure::io(modules, &source))?;
    // Blank once trimmed, or *starting* with `#` untrimmed. The asymmetry is
    // deliberate: this count is compared across records of the same run.
    let counted = listed
        .lines()
        .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
        .count();
    record.insert("targetModules".to_owned(), serde_json::json!(counted));
    record.insert("jobsRequested".to_owned(), serde_json::json!(jobs));

    // No trailing newline: nothing reads this file as bytes — `analyze.ts` and
    // `pipeline::write_timings` both parse it.
    let encoded = serde_json::to_string(&record).map_err(|source| Failure::io(out, &source))?;
    if let Some(parent) = out.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        crate::pipeline::create_dir(parent)?;
    }
    fs::write(out, encoded).map_err(|source| Failure::io(out, &source))?;
    Ok(counted)
}
