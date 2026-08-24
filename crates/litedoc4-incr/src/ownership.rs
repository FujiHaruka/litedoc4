//! Which modules point at a name that has moved.
//!
//! The IR stores every reference as a `(defining module, name)` pair, because
//! the printed token and the constant it links to often have no textual relation
//! (`ℕ` -> `Nat`). That pair goes stale when the name moves, even though nothing
//! about the referring module changed — and no other layer can see it: moving a
//! declaration from A to X leaves the referring module C's `.olean` **byte
//! identical** (and Lake's hash unmoved)【実測】, so [`crate::detect`] cannot
//! see it, and widening the *render* set cannot fix it either, because the stale
//! bytes are in C's IR and C has to be re-**extracted**. Renaming, by contrast,
//! does change C's olean, because the new name is embedded in C's terms.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;
use std::time::Instant;

use litedoc4_ir::{IrTree, sort_utf16};
use serde::Serialize;

use crate::detect::read_module_list;
use crate::error::Error;
use crate::io::{write, write_text};

#[derive(Clone, Copy, Debug)]
pub struct OwnershipOptions<'a> {
    /// The IR as it was before this round.
    pub base: &'a Path,
    /// The partial extraction's tree. `None` is a real case, not a misuse: a
    /// pure deletion re-extracts nothing.
    pub inc: Option<&'a Path>,
    /// Modules that no longer exist, one per line.
    pub removed: Option<&'a Path>,
    /// Modules already scheduled for re-extraction, one per line. They are fresh
    /// by definition and are never reported.
    pub exclude: Option<&'a Path>,
    /// The stale modules, one per line — the next round's input.
    pub print_set: Option<&'a Path>,
    pub json: Option<&'a Path>,
}

/// Field order is part of the summary file's bytes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Witness {
    pub module: String,
    /// [`RULE_LOST_OWNER`] or [`RULE_MOVED_ELSEWHERE`].
    pub rule: &'static str,
    /// `[defining module, name]`.
    #[serde(rename = "ref")]
    pub reference: [String; 2],
}

pub const RULE_LOST_OWNER: &str = "lostOwner";
pub const RULE_MOVED_ELSEWHERE: &str = "movedElsewhere";

/// **No `PartialEq`**: the three `*Seconds` are wall clock, and a summary that
/// compares equal to another one would be asserting on them.
#[derive(Clone, Debug)]
pub struct OwnershipSummary {
    pub inc_modules: usize,
    pub removed_modules: usize,
    /// Base modules minus excluded ones, or 0 when nothing was watched.
    /// **Signed**, because the two counts are not nested: the exclude file may
    /// name modules the base IR never had, and the negative is reported as it
    /// falls out rather than clamped away.
    pub scanned_base_modules: i64,
    /// Occurrences, not distinct names: one per (name, module) pair.
    pub lost_names: usize,
    pub gained_names: usize,
    pub lost_names_distinct: usize,
    pub gained_names_distinct: usize,
    pub stale_by_lost_owner: usize,
    pub stale_by_moved_elsewhere: usize,
    /// The union of the two rules, in **UTF-16 order**: the order reaches
    /// `--print-set`, which the next round re-extracts.
    pub stale_modules: Vec<String>,
    /// In scan order, at most one per (module, rule). The summary file keeps the
    /// first [`WITNESSES_IN_SUMMARY`], the log the first [`WITNESSES_IN_LOG`].
    pub witnesses: Vec<Witness>,
    pub diff_seconds: f64,
    pub scan_seconds: f64,
    pub total_seconds: f64,
}

pub const WITNESSES_IN_SUMMARY: usize = 20;
pub const WITNESSES_IN_LOG: usize = 10;

/// Diffs the re-extracted modules against the base IR and scans every other
/// module's references for names that moved.
pub fn ownership(options: &OwnershipOptions<'_>) -> Result<OwnershipSummary, Error> {
    let started = Instant::now();
    let base = IrTree::open_unvalidated(options.base).map_err(Error::Ir)?;
    let base_file_of: HashMap<&str, &litedoc4_ir::IndexEntry> = base
        .index()
        .modules
        .iter()
        .map(|entry| (entry.module.as_str(), entry))
        .collect();

    let inc = match options.inc {
        Some(dir) => Some(IrTree::open_unvalidated(dir).map_err(Error::Ir)?),
        None => None,
    };
    let inc_entries: &[litedoc4_ir::IndexEntry] =
        inc.as_ref().map_or(&[], |tree| &tree.index().modules);
    let fresh: HashSet<&str> = inc_entries
        .iter()
        .map(|entry| entry.module.as_str())
        .collect();

    // A module the base IR never had cannot have lost anything, so `--removed`
    // naming one is dropped rather than refused.
    let removed_modules: Vec<String> = match options.removed {
        Some(path) => read_module_list(path)?
            .into_iter()
            .filter(|module| base_file_of.contains_key(module.as_str()))
            .collect(),
        None => Vec::new(),
    };

    /// name -> the modules that lost it, or the modules that gained it.
    type Owners = HashMap<String, HashSet<String>>;
    let mut lost_owners: Owners = HashMap::new();
    let mut gained_owners: Owners = HashMap::new();
    let mut lost_count = 0usize;
    let mut gained_count = 0usize;

    for entry in inc_entries {
        let inc = inc
            .as_ref()
            .expect("there are entries only when there is a tree");
        let now: HashSet<String> = inc
            .module(entry)
            .map_err(Error::Ir)?
            .declarations
            .into_iter()
            .map(|decl| decl.name)
            .collect();
        // A module absent from the base IR is new: nothing can be pointing at it
        // wrongly yet.
        let was: HashSet<String> = match base_file_of.get(entry.module.as_str()) {
            Some(base_entry) => base
                .module(base_entry)
                .map_err(Error::Ir)?
                .declarations
                .into_iter()
                .map(|decl| decl.name)
                .collect(),
            None => HashSet::new(),
        };
        for name in &was {
            if !now.contains(name) {
                lost_owners
                    .entry(name.clone())
                    .or_default()
                    .insert(entry.module.clone());
                lost_count += 1;
            }
        }
        for name in &now {
            if !was.contains(name) {
                gained_owners
                    .entry(name.clone())
                    .or_default()
                    .insert(entry.module.clone());
                gained_count += 1;
            }
        }
    }

    // A deleted module is one whose whole name set was lost: the same
    // computation with an empty "gained" side.
    //
    // Walked as the **array** the file holds, not as a set, so a module that
    // declared one name twice counts twice in `lostNames`. The distinct count
    // beside it is the set.
    for module in &removed_modules {
        let entry = base_file_of[module.as_str()];
        for decl in base.module(entry).map_err(Error::Ir)?.declarations {
            lost_owners
                .entry(decl.name)
                .or_default()
                .insert(module.clone());
            lost_count += 1;
        }
    }
    let diff_done = started.elapsed();

    let mut exclude: HashSet<String> = match options.exclude {
        Some(path) => read_module_list(path)?.into_iter().collect(),
        None => HashSet::new(),
    };
    exclude.extend(fresh.iter().map(|module| (*module).to_owned()));
    // A removed module must not be reported as needing re-extraction: it is gone.
    exclude.extend(removed_modules.iter().cloned());

    let mut stale_lost_owner: BTreeSet<String> = BTreeSet::new();
    let mut stale_moved_elsewhere: BTreeSet<String> = BTreeSet::new();
    let mut witnesses: Vec<Witness> = Vec::new();

    // Nothing moved and nothing was deleted: no module can be pointing anywhere
    // wrong, so the base IR is not read at all.
    let watching = !lost_owners.is_empty() || !gained_owners.is_empty();
    if watching {
        for entry in &base.index().modules {
            if exclude.contains(&entry.module) {
                continue;
            }
            let module = base.module(entry).map_err(Error::Ir)?;
            for decl in &module.declarations {
                for reference in &decl.refs {
                    let (owner, name) = (&reference.module, &reference.name);
                    if lost_owners
                        .get(name)
                        .is_some_and(|owners| owners.contains(owner))
                    {
                        if !stale_lost_owner.contains(&entry.module) {
                            witnesses.push(Witness {
                                module: entry.module.clone(),
                                rule: RULE_LOST_OWNER,
                                reference: [owner.clone(), name.clone()],
                            });
                        }
                        stale_lost_owner.insert(entry.module.clone());
                    } else if gained_owners
                        .get(name)
                        .is_some_and(|owners| !owners.contains(owner))
                    {
                        if !stale_moved_elsewhere.contains(&entry.module) {
                            witnesses.push(Witness {
                                module: entry.module.clone(),
                                rule: RULE_MOVED_ELSEWHERE,
                                reference: [owner.clone(), name.clone()],
                            });
                        }
                        stale_moved_elsewhere.insert(entry.module.clone());
                    }
                }
            }
        }
    }
    let scan_done = started.elapsed();

    let mut stale: Vec<String> = stale_lost_owner
        .union(&stale_moved_elsewhere)
        .cloned()
        .collect();
    sort_utf16(&mut stale);

    let summary = OwnershipSummary {
        inc_modules: inc_entries.len(),
        removed_modules: removed_modules.len(),
        scanned_base_modules: if watching {
            i64::try_from(base.index().modules.len()).unwrap_or(i64::MAX)
                - i64::try_from(exclude.len()).unwrap_or(i64::MAX)
        } else {
            0
        },
        lost_names: lost_count,
        gained_names: gained_count,
        lost_names_distinct: lost_owners.len(),
        gained_names_distinct: gained_owners.len(),
        stale_by_lost_owner: stale_lost_owner.len(),
        stale_by_moved_elsewhere: stale_moved_elsewhere.len(),
        stale_modules: stale,
        witnesses,
        diff_seconds: diff_done.as_secs_f64(),
        scan_seconds: scan_done.saturating_sub(diff_done).as_secs_f64(),
        total_seconds: scan_done.as_secs_f64(),
    };

    if let Some(path) = options.json {
        let record = OwnershipJson {
            base: &options.base.display().to_string(),
            // The empty string, not a null, is what lands in the file when no
            // tree was given.
            inc: &options
                .inc
                .map(|dir| dir.display().to_string())
                .unwrap_or_default(),
            inc_modules: summary.inc_modules,
            removed_modules: summary.removed_modules,
            scanned_base_modules: summary.scanned_base_modules,
            lost_names: summary.lost_names,
            gained_names: summary.gained_names,
            lost_names_distinct: summary.lost_names_distinct,
            gained_names_distinct: summary.gained_names_distinct,
            stale_by_lost_owner: summary.stale_by_lost_owner,
            stale_by_moved_elsewhere: summary.stale_by_moved_elsewhere,
            stale: summary.stale_modules.len(),
            stale_modules: &summary.stale_modules,
            witnesses: &summary.witnesses[..summary.witnesses.len().min(WITNESSES_IN_SUMMARY)],
            diff_seconds: summary.diff_seconds,
            scan_seconds: summary.scan_seconds,
            total_seconds: summary.total_seconds,
        };
        let body = serde_json::to_string_pretty(&record)
            .expect("counts, strings and durations serialise")
            + "\n";
        write(path, &body)?;
    }
    if let Some(path) = options.print_set {
        write_text(path, &summary.stale_modules)?;
    }
    Ok(summary)
}

/// Field order is part of this file's bytes. The three `*Seconds` are
/// diagnostics — wall clock, different every run, and no test may assert on
/// them.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OwnershipJson<'a> {
    base: &'a str,
    inc: &'a str,
    inc_modules: usize,
    removed_modules: usize,
    scanned_base_modules: i64,
    lost_names: usize,
    gained_names: usize,
    lost_names_distinct: usize,
    gained_names_distinct: usize,
    stale_by_lost_owner: usize,
    stale_by_moved_elsewhere: usize,
    stale: usize,
    stale_modules: &'a [String],
    witnesses: &'a [Witness],
    diff_seconds: f64,
    scan_seconds: f64,
    total_seconds: f64,
}
