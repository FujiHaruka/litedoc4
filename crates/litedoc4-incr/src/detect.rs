//! `build`, `check` and `touch`: which modules must be re-extracted, answered
//! **without starting Lean**.
//!
//! `touch` is shipped rather than kept in a test because it is the honest fake
//! a measurement rests on. The measurement target must not be modified — its
//! `.lake/build` is the baseline for every number in this repository — so the
//! *fact* "module M changed" is injected by invalidating M's ledger entry, and
//! everything downstream stays real: the re-extraction, the merge, the page set,
//! the clocks.
//!
//! The two key diffs are reported separately on purpose: a changed `extractKey`
//! invalidates every module's IR, a changed `renderKey` invalidates **no** IR at
//! all, so folding the second into the re-extract set would re-extract a whole
//! target to change a URL prefix.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::Instant;

use litedoc4_ir::cmp_utf16;
use serde::Serialize;

use crate::error::Error;
use crate::io::{lines_file, write, write_json_line};
use crate::ledger::{
    Algorithm, LEDGER_SCHEMA, Ledger, ModuleEntry, extract_key, hash_module, link_index_digest,
    map_pool, read_to_string, render_key,
};

#[derive(Clone, Copy, Debug)]
pub struct BuildOptions<'a> {
    /// The modules to hash, in the order they will appear in the ledger.
    /// **From a glob over the sources, never from a walk of `.lake/build`** —
    /// the build tree carries 659 orphan oleans on the measurement target
    /// (measured).
    pub modules: &'a [String],
    /// The target repository. A trailing slash is stripped, because the string
    /// is a prefix of every recorded path.
    pub target: &'a str,
    pub out: &'a Path,
    /// An IR tree. Its `schemaVersion` and `generator` join the extract key;
    /// without it those two keys are absent, and an absent key is a change
    /// (see [`crate::ledger::KeySet::diff`]).
    pub ir: Option<&'a Path>,
    /// `--source-url`. Empty means the key is absent, which is loud rather than
    /// silent: the next `check` that passes one will re-render everything.
    pub source_url: &'a str,
    /// The dependency map the pages are rendered against; its bytes join the
    /// render key ([`render_key`]). `None`, and a path that does not exist, both
    /// leave the key absent — on a first `build` the ledger is computed *before*
    /// the extraction that writes the map.
    pub link_index: Option<&'a Path>,
    /// The digest of the dependency **link** map — where each dependency's
    /// source lives (`litedoc4_render::ExternalLinks::digest`). A path would be
    /// wrong here: the map is resolved from the target's manifest and its
    /// toolchain rather than read from a file, so its identity is all the ledger
    /// can record. `None` leaves the key absent.
    pub external_links: Option<&'a str>,
    pub algorithm: &'a Algorithm,
    pub concurrency: usize,
    pub timings: Option<&'a Path>,
}

#[derive(Clone, Debug)]
pub struct BuildSummary {
    pub ledger: Ledger,
    pub modules: usize,
    pub files: usize,
    /// Zero under `--algorithm lake`, which reads no olean at all.
    pub hashed_bytes: u64,
    pub ledger_bytes: usize,
    pub hash_seconds: f64,
}

/// A module in the list with no olean at all stops the run
/// ([`Error::NoOlean`]): at `build` time the list and the build tree are
/// supposed to agree, and a ledger that silently omits modules would report them
/// as *added* on the next `check` — the one direction that looks like progress.
pub fn build_ledger(options: &BuildOptions<'_>) -> Result<BuildSummary, Error> {
    let started = Instant::now();
    let target = options.target.trim_end_matches('/');
    let lib_dir = format!("{target}/.lake/build/lib/lean");

    let extract = extract_key(target, options.ir)?;
    let render = render_key(
        options.source_url,
        link_index_digest(options.link_index)?.as_deref(),
        options.external_links,
    );
    let key_done = started.elapsed();

    let hashed = map_pool(options.modules, options.concurrency, |module| {
        hash_module(target, &lib_dir, module, options.algorithm)
    });
    let hash_done = started.elapsed();

    // First by index rather than first to fail, so that two runs of a failing
    // build at different concurrencies report the same module.
    let mut entries: Vec<ModuleEntry> = Vec::with_capacity(hashed.len());
    let mut missing: Vec<String> = Vec::new();
    for (module, entry) in options.modules.iter().zip(hashed) {
        match entry? {
            Some(entry) => entries.push(entry),
            None => missing.push(module.clone()),
        }
    }
    if !missing.is_empty() {
        return Err(Error::NoOlean {
            lib_dir,
            modules: missing,
        });
    }

    let files = entries.iter().map(|entry| entry.files.len()).sum();
    let hashed_bytes = hashed_bytes(&entries);
    let ledger = Ledger {
        ledger_schema: LEDGER_SCHEMA,
        algorithm: options.algorithm.clone(),
        target: target.to_owned(),
        lib_dir,
        extract_key: extract,
        render_key: Some(render),
        modules: entries,
    };
    let body = ledger.to_json();
    write(options.out, &body)?;
    let total = started.elapsed();

    let summary = BuildSummary {
        modules: ledger.modules.len(),
        files,
        hashed_bytes,
        ledger_bytes: body.len(),
        hash_seconds: hash_done.saturating_sub(key_done).as_secs_f64(),
        ledger,
    };
    if let Some(path) = options.timings {
        let record = BuildTimings {
            command: "build",
            algorithm: options.algorithm.name(),
            concurrency: options.concurrency,
            modules: summary.modules,
            files: summary.files,
            hashed_bytes: summary.hashed_bytes,
            key_seconds: key_done.as_secs_f64(),
            hash_seconds: summary.hash_seconds,
            write_seconds: total.saturating_sub(hash_done).as_secs_f64(),
            total_seconds: total.as_secs_f64(),
        };
        write_json_line(path, &record)?;
    }
    Ok(summary)
}

#[derive(Clone, Copy, Debug)]
pub struct CheckOptions<'a> {
    pub ledger: &'a Path,
    /// `None` keeps the ledger's own algorithm, which is the usual case: the
    /// two hashes are not comparable, so changing it makes every module differ.
    pub algorithm: Option<&'a Algorithm>,
    /// **`None` and `Some(&[])` are different questions.** `None` re-reads the
    /// ledger's module list, which cannot see a module that appeared or vanished
    /// since `build`; `Some` is the current list, and an empty one says every
    /// module in the ledger is gone.
    pub modules: Option<&'a [String]>,
    pub ir: Option<&'a Path>,
    pub source_url: &'a str,
    /// See [`BuildOptions::link_index`] and [`render_key`]. This is the half of
    /// the question that can be answered *before* the run — "did somebody hand
    /// us a different map". The half that cannot is the map this run's own
    /// extraction rewrites, which the caller checks after the rounds.
    pub link_index: Option<&'a Path>,
    /// See [`BuildOptions::external_links`].
    pub external_links: Option<&'a str>,
    pub concurrency: usize,
    /// The re-extract set, one module per line. Empty file, not a blank line.
    pub changed_out: Option<&'a Path>,
    pub removed_out: Option<&'a Path>,
    /// The reasons the render key changed, one `renderKey:<name>` per line. An
    /// empty file means "the render set follows from the IR diff as usual",
    /// which is what the caller tests for.
    pub render_all_out: Option<&'a Path>,
    pub timings: Option<&'a Path>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CheckSummary {
    /// The algorithm actually used — the ledger's, unless overridden.
    pub algorithm: Algorithm,
    /// Modules that still have an olean.
    pub modules: usize,
    pub files: usize,
    pub hashed_bytes: u64,
    /// Names of the extract keys that differ, in UTF-16 order.
    pub extract_key_changed: Vec<String>,
    pub render_key_changed: Vec<String>,
    /// In the ledger, hash differs.
    pub changed: Vec<String>,
    /// In the list, not in the ledger.
    pub added: Vec<String>,
    /// In the list with no olean, or in the ledger and no longer in the list.
    pub removed: Vec<String>,
    /// What must be re-extracted: every present module when the extract key
    /// changed, otherwise `changed ∪ added`.
    pub re_extract: Vec<String>,
    /// **The ledger this check would leave behind if the run it licenses
    /// succeeds** — the hashes as they were *here*, before anything was
    /// extracted from them, and not written by this function: `check` answers a
    /// question, and a caller that stops on the answer must not have moved the
    /// ledger.
    ///
    /// Taken here rather than re-hashed afterwards because the race has one
    /// silent direction: an olean that moves *while* the run is in flight,
    /// re-hashed at the end, would be recorded as the one its IR came from, and
    /// that module is then never re-extracted again. Recording the hash the
    /// extraction was licensed by can only make a later run re-extract something
    /// it need not — wasteful, and loud in the next run's `changed` count.
    ///
    /// The module entries are the ones **that still have an olean**, in the
    /// order `--modules` named them: a removed module has to leave the ledger,
    /// or the next `check` reports it removed for ever. The two keys are this
    /// check's own; a caller whose run replaces the IR tree recomputes
    /// [`crate::extract_key`] against the tree that now exists.
    pub fresh: Ledger,
}

impl CheckSummary {
    /// Every module's IR is invalid, regardless of its own hash.
    #[must_use]
    pub fn extract_invalidated(&self) -> bool {
        !self.extract_key_changed.is_empty()
    }

    /// Every page has to be re-rendered, from IR that is still valid.
    #[must_use]
    pub fn render_all(&self) -> bool {
        !self.render_key_changed.is_empty()
    }
}

pub fn check_ledger(options: &CheckOptions<'_>) -> Result<CheckSummary, Error> {
    let started = Instant::now();
    let text = read_to_string(options.ledger)?;
    let ledger: Ledger = serde_json::from_str(&text).map_err(|source| Error::Json {
        path: options.ledger.to_owned(),
        source,
    })?;
    let read_done = started.elapsed();
    if ledger.ledger_schema < LEDGER_SCHEMA {
        return Err(Error::LedgerSchema {
            path: options.ledger.to_owned(),
            found: ledger.ledger_schema,
        });
    }
    let algorithm = options.algorithm.unwrap_or(&ledger.algorithm).clone();

    let extract = extract_key(&ledger.target, options.ir)?;
    let render = render_key(
        options.source_url,
        link_index_digest(options.link_index)?.as_deref(),
        options.external_links,
    );
    let key_done = started.elapsed();

    // One key invalidates the IR, the other only the pages rendered from it.
    let extract_key_changed = ledger.extract_key.diff(&extract);
    let render_key_changed = ledger.render_key_or_empty().diff(&render);

    // A repeated module keeps its first position and takes its last value.
    let mut previous: HashMap<&str, &ModuleEntry> = HashMap::new();
    let mut previous_order: Vec<&str> = Vec::new();
    for entry in &ledger.modules {
        if previous.insert(entry.module.as_str(), entry).is_none() {
            previous_order.push(entry.module.as_str());
        }
    }
    let from_list = options.modules.is_some();
    let owned_from_ledger: Vec<String>;
    let current: &[String] = match options.modules {
        Some(modules) => modules,
        None => {
            owned_from_ledger = previous_order.iter().map(|m| (*m).to_owned()).collect();
            &owned_from_ledger
        }
    };
    let now = map_pool(current, options.concurrency, |module| {
        hash_module(&ledger.target, &ledger.lib_dir, module, &algorithm)
    });
    let hash_done = started.elapsed();

    let mut present: Vec<ModuleEntry> = Vec::new();
    let mut changed: Vec<String> = Vec::new();
    let mut added: Vec<String> = Vec::new();
    let mut removed: Vec<String> = Vec::new();
    for (module, entry) in current.iter().zip(now) {
        let Some(entry) = entry? else {
            // In the list, no olean on disk.
            removed.push(module.clone());
            continue;
        };
        match previous.get(module.as_str()) {
            None => added.push(module.clone()),
            Some(was) if was.hash != entry.hash => changed.push(module.clone()),
            Some(_) => {}
        }
        present.push(entry);
    }
    let in_current: HashSet<&str> = current.iter().map(String::as_str).collect();
    let in_removed: HashSet<String> = removed.iter().cloned().collect();
    for module in &previous_order {
        if !in_current.contains(module) && !in_removed.contains(*module) {
            removed.push((*module).to_owned());
        }
    }

    // A changed extract key invalidates every module's IR. The set is then the
    // present modules in list order — what was just hashed — not the sorted
    // union.
    let re_extract = if extract_key_changed.is_empty() {
        let mut union: Vec<String> = changed.iter().chain(&added).cloned().collect();
        union.sort_by(|a, b| cmp_utf16(a, b));
        union
    } else {
        present.iter().map(|entry| entry.module.clone()).collect()
    };
    let compare_done = started.elapsed();

    if let Some(path) = options.changed_out {
        write(path, &lines_file(&re_extract))?;
    }
    if let Some(path) = options.removed_out {
        write(path, &lines_file(&removed))?;
    }
    if let Some(path) = options.render_all_out {
        let reasons: Vec<String> = render_key_changed
            .iter()
            .map(|name| format!("renderKey:{name}"))
            .collect();
        write(path, &lines_file(&reasons))?;
    }

    let summary = CheckSummary {
        modules: present.len(),
        files: present.iter().map(|entry| entry.files.len()).sum(),
        hashed_bytes: hashed_bytes(&present),
        extract_key_changed,
        render_key_changed,
        changed,
        added,
        removed,
        re_extract,
        // The algorithm is the one that produced these hashes — the ledger's
        // own unless `--algorithm` overrode it — because a ledger whose entries
        // and whose declared algorithm disagree compares every module as changed
        // for ever after.
        fresh: Ledger {
            ledger_schema: LEDGER_SCHEMA,
            algorithm: algorithm.clone(),
            target: ledger.target,
            lib_dir: ledger.lib_dir,
            extract_key: extract,
            render_key: Some(render),
            modules: present,
        },
        algorithm,
    };
    if let Some(path) = options.timings {
        let record = CheckTimings {
            command: "check",
            algorithm: summary.algorithm.name(),
            concurrency: options.concurrency,
            modules: summary.modules,
            module_list_source: if from_list { "list" } else { "ledger" },
            files: summary.files,
            hashed_bytes: summary.hashed_bytes,
            extract_key_changed: &summary.extract_key_changed,
            extract_invalidated: summary.extract_invalidated(),
            render_key_changed: &summary.render_key_changed,
            render_all: summary.render_all(),
            changed: summary.changed.len(),
            changed_modules: &summary.changed,
            added: summary.added.len(),
            added_modules: &summary.added,
            removed: summary.removed.len(),
            removed_modules: &summary.removed,
            re_extract: summary.re_extract.len(),
            read_ledger_seconds: read_done.as_secs_f64(),
            key_seconds: key_done.saturating_sub(read_done).as_secs_f64(),
            hash_seconds: hash_done.saturating_sub(key_done).as_secs_f64(),
            compare_seconds: compare_done.saturating_sub(hash_done).as_secs_f64(),
            total_seconds: started.elapsed().as_secs_f64(),
        };
        write_json_line(path, &record)?;
    }
    Ok(summary)
}

#[derive(Clone, Copy, Debug)]
pub struct TouchOptions<'a> {
    pub ledger: &'a Path,
    pub module: &'a str,
    pub out: &'a Path,
}

/// Invalidates one module's entry, so that the next `check` reports it as
/// **changed**. Invalidating rather than deleting is the point: a deleted entry
/// would be reported as *added*, and an added module is not what an edit
/// produces. The olean is not touched — the injected fact is about the ledger.
pub fn touch_ledger(options: &TouchOptions<'_>) -> Result<usize, Error> {
    let text = read_to_string(options.ledger)?;
    let mut ledger: Ledger = serde_json::from_str(&text).map_err(|source| Error::Json {
        path: options.ledger.to_owned(),
        source,
    })?;
    let Some(entry) = ledger
        .modules
        .iter_mut()
        .find(|entry| entry.module == options.module)
    else {
        return Err(Error::NoSuchModule {
            path: options.ledger.to_owned(),
            module: options.module.to_owned(),
        });
    };
    entry.hash = format!("injected-change:{}", entry.hash);
    let body = ledger.to_json();
    write(options.out, &body)?;
    Ok(body.len())
}

pub fn read_module_list(path: &Path) -> Result<Vec<String>, Error> {
    Ok(read_to_string(path)?
        .split('\n')
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(str::to_owned)
        .collect())
}

/// `-1` (the `lake` path, which reads no olean) clamps to zero.
fn hashed_bytes(entries: &[ModuleEntry]) -> u64 {
    entries
        .iter()
        .flat_map(|entry| &entry.files)
        .map(|file| u64::try_from(file.bytes).unwrap_or(0))
        .sum()
}

/// The durations are diagnostics — wall clock, different every run, and no test
/// may assert on them.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BuildTimings<'a> {
    command: &'a str,
    algorithm: &'a str,
    concurrency: usize,
    modules: usize,
    files: usize,
    hashed_bytes: u64,
    key_seconds: f64,
    hash_seconds: f64,
    write_seconds: f64,
    total_seconds: f64,
}

/// The four durations partition the run, so they subtract: read the ledger,
/// build the keys, hash the modules, compare the sets. The output files are
/// written after the last of them.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CheckTimings<'a> {
    command: &'a str,
    algorithm: &'a str,
    concurrency: usize,
    modules: usize,
    module_list_source: &'a str,
    files: usize,
    hashed_bytes: u64,
    extract_key_changed: &'a [String],
    extract_invalidated: bool,
    render_key_changed: &'a [String],
    render_all: bool,
    changed: usize,
    changed_modules: &'a [String],
    added: usize,
    added_modules: &'a [String],
    removed: usize,
    removed_modules: &'a [String],
    re_extract: usize,
    read_ledger_seconds: f64,
    key_seconds: f64,
    hash_seconds: f64,
    compare_seconds: f64,
    total_seconds: f64,
}
