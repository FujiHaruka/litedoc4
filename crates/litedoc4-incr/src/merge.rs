//! Folding a partial extraction back into the package IR.
//!
//! The extractor writes a *complete* IR tree for whatever module list it was
//! given, so a one-module run produces a one-module tree. Two things therefore
//! have to be repaired before that tree is usable as an update:
//!
//! 1. `index.json` must keep the other modules' entries. The entry for the
//!    re-extracted module is taken verbatim from the partial run — including its
//!    `contentHash`, which only Lean can compute (it is `String.hash` of the
//!    module JSON).
//!
//! 2. `deps/*.json` is **package-global and cannot be produced by a partial run
//!    at all.** The extractor decides "dependency" as "defining module not in
//!    the target list", so with a one-module target list the package's own other
//!    modules are misfiled as dependencies. The fix is not to merge that file
//!    but to recompute the slice from the merged module files, which is where
//!    the `refs` live anyway.
//!
//! "One module changed" stops being local here, and the reason is worth being
//! precise about: it is not a dependency of the *change*, it is an artefact of
//! the extractor's interface.
//!
//! **Nothing this module writes is ordered its own way** — every order in a
//! merged tree is the one Lean's from-scratch writer would have produced, so
//! that
//!
//! > every file an incremental build produces is byte for byte the one a
//! > from-scratch extraction would have written
//!
//! is an invariant a test can hold (`tests/merge.rs`) rather than a hope. That
//! means each `deps/<Root>.json` sorted (Lean's `Json.mkObj` is backed by a
//! sorted map), each `dependencyMaps` entry's keys alphabetical, and the
//! `dependencyMaps` array in **code point order** ([`str::cmp`]) — Lean compares
//! `String`s by their characters, which agrees with UTF-16 order throughout the
//! BMP and parts company at U+10000, so the choice is only visible on a name
//! carrying a supplementary scalar. `tests/merge.rs` builds one rather than
//! waiting for Mathlib to. The top-level key order is the base index's, which
//! [`JsonObject`] reproduces explicitly rather than inheriting from a map type.
//!
//! `index.json`'s **`modules` array** follows [`MergeOptions::modules`] when it
//! is given, because a from-scratch extraction's order is the order the
//! extractor was handed its module list in — the extractor does not sort
//! 【実測 2026-08-12: the target's `index.json` matches `find … | sort`'s locale
//! collation exactly and disagrees with `LC_ALL=C sort` at 163 of 432 entries】.
//! Without the list the order is the base index's with new modules appended, so
//! a merge that *added* a module leaves the same entries in a sequence no
//! extraction produces.
//!
//! That order reaches one more thing than the index: the dependency slice is
//! recomputed by walking the package's modules and letting the **last** writer
//! own a name, so two modules referencing the same dependency name from
//! different defining modules resolve it in module order.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use litedoc4_ir::{IrFile, read_module_file};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

use crate::error::Error;
use crate::io::{write, write_json_line, write_text};
use crate::ordered::Ordered;

#[derive(Clone, Copy, Debug)]
pub struct MergeOptions<'a> {
    /// The IR to update. **Never modified in place unless `out` says so.**
    pub base: &'a Path,
    /// The partial extraction's tree. `None` is a real case, not a misuse: a
    /// pure deletion re-extracts nothing.
    pub inc: Option<&'a Path>,
    /// Where the merged tree goes. Passing `base` merges in place.
    pub out: &'a Path,
    /// Modules that no longer exist. They leave the index and their module files
    /// are deleted.
    pub removed: &'a [String],
    /// The package's module list, in the order a from-scratch extraction would
    /// be handed it.
    ///
    /// **Given, it is the merged `index.json`'s `modules` order** and the order
    /// the dependency slice is recomputed in — see [`listed_order`]. **`None`
    /// keeps the base index's order with new modules appended**, which
    /// `merge --verify` compares as equal either way.
    pub modules: Option<&'a [String]>,
    /// The modules whose IR `contentHash` moved, one per line — the render set's
    /// input, and **not** the same as the re-extracted set.
    pub changed_out: Option<&'a Path>,
    pub timings: Option<&'a Path>,
}

/// **No `PartialEq`**: the three `*Seconds` are wall clock, and a summary that
/// compares equal to another one would be asserting on them.
#[derive(Clone, Debug)]
pub struct MergeSummary {
    /// Every module the partial extraction carried, in its index order.
    pub updated: Vec<String>,
    /// How many of `removed` were actually in the base index.
    pub removed: usize,
    /// The modules whose `contentHash` moved. A re-extracted module whose hash
    /// did not move produces the same page, so it does not enter the render set:
    /// this is the second ledger, and the one that decides what to re-render.
    pub ir_changed: Vec<String>,
    pub modules: usize,
    pub declarations: usize,
    /// One per `deps/<Root>.json` written, in the order they were written.
    pub dep_maps: Vec<DepMapRecord>,
    pub copy_seconds: f64,
    pub deps_seconds: f64,
    pub total_seconds: f64,
}

/// Field order **is** the file's key order, and it is Lean's alphabetical one.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct DepMapRecord {
    pub bytes: usize,
    pub entries: usize,
    pub file: String,
    pub package: String,
}

/// One `deps/<Root>.json`, in the order **Lean** writes it: `declarations` is a
/// [`BTreeMap`], whose iteration order is `str`'s `Ord` = code point order =
/// Lean's `String` comparison.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DepSlice<'a> {
    declarations: &'a BTreeMap<String, String>,
    package: &'a str,
    /// Carried through from the base index rather than assumed, and **omitted
    /// when the base index has none**.
    #[serde(skip_serializing_if = "Option::is_none")]
    schema_version: Option<&'a Value>,
}

/// The lower of two `schemaVersion` values. Keeps the base's whenever the two
/// cannot be compared as numbers, including the case where the base has none: a
/// tree without the key is a schema-1 file, and answering with the incremental
/// tree's number would invent a claim the base never made.
fn weakest_schema<'a>(base: Option<&'a Value>, inc: Option<&'a Value>) -> Option<&'a Value> {
    match (base, inc) {
        (Some(base), Some(inc)) => match (base.as_u64(), inc.as_u64()) {
            (Some(from_base), Some(from_inc)) if from_inc < from_base => Some(inc),
            _ => Some(base),
        },
        (base, _) => base,
    }
}

/// The merged `index.json` is the base index with four values replaced, so its
/// key order is the base file's — reproduced by [`Ordered`] rather than
/// inherited from `serde_json`'s `preserve_order` feature, which is a
/// dependency's build configuration.
///
/// The **values** are `serde_json::Value`s copied verbatim out of the base and
/// incremental indexes, and their nested key order *does* rely on
/// `preserve_order`; `tests/merge.rs` asserts a round trip rather than trusting
/// it.
pub type JsonObject = Ordered<Value>;

impl<'de> Deserialize<'de> for JsonObject {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::deserialize_in_order(deserializer, "a JSON object")
    }
}

/// Whether `base` and `out` name one tree, however each is spelled.
///
/// **Not `base == out`.** `Path`'s `PartialEq` compares components, and
/// `components()` normalises `.` away but not `..`, so `x/../x` and `x` are two
/// paths naming one directory. Reading that as "out is a separate tree" is not
/// a wasted write but a destructive one: [`fs::copy`] opens the destination
/// with `O_TRUNC` before it reads the source, so copying a file onto itself
/// returns `Ok(0)` and leaves it empty【実測 2026-08-23】. The files emptied
/// would be the modules the partial extraction did not touch — and when `--out`
/// names the base, that tree is the only copy there was.
///
/// Resolved rather than compared, which also answers the symlink spelling. A
/// side that does not resolve is not the other one: `out` exists by the time
/// this is asked, so the only unresolvable side is a `base` that is not there,
/// and the read that follows says so with a better message than a bool could.
#[must_use]
pub fn same_tree(base: &Path, out: &Path) -> bool {
    match (fs::canonicalize(base), fs::canonicalize(out)) {
        (Ok(base), Ok(out)) => base == out,
        _ => false,
    }
}

/// Folds `inc` into `base` and writes the result to `out`.
pub fn merge(options: &MergeOptions<'_>) -> Result<MergeSummary, Error> {
    let started = Instant::now();
    let base_index_path = options.base.join("index.json");
    let base_index: JsonObject = read_json(&base_index_path, IrFile::Index)?;
    let mut inc_schema: Option<Value> = None;
    let inc_modules: Vec<IndexEntry> = match options.inc {
        Some(dir) => {
            let path = dir.join("index.json");
            let index: JsonObject = read_json(&path, IrFile::Index)?;
            inc_schema = index.get("schemaVersion").cloned();
            index_entries(&index, &path)?
        }
        None => Vec::new(),
    };
    let base_modules = index_entries(&base_index, &base_index_path)?;

    let mut entries: HashMap<String, IndexEntry> = HashMap::new();
    let mut order: Vec<String> = Vec::with_capacity(base_modules.len());
    for entry in &base_modules {
        order.push(entry.module.clone());
        entries.insert(entry.module.clone(), entry.clone());
    }

    // A module that no longer exists has to leave the index, or it keeps a page
    // and keeps feeding names to the dependency slice and the global maps.
    let mut gone: Vec<String> = Vec::new();
    let mut dropped_files: Vec<String> = Vec::new();
    let mut gone_set: HashSet<String> = HashSet::new();
    for module in options.removed {
        if let Some(entry) = entries.get(module)
            && gone_set.insert(module.clone())
        {
            dropped_files.push(entry.file.clone());
            gone.push(module.clone());
        }
    }
    for module in &gone {
        entries.remove(module);
    }
    order.retain(|module| !gone_set.contains(module));

    // Decided **before anything is written**: the set the merge is about to
    // produce is already known — the base index minus the deletions, plus
    // whatever the partial extraction carried — so a list that does not describe
    // it is refused with the tree untouched rather than half updated.
    let listed = match options.modules {
        Some(list) => Some(listed_order(list, &order, &inc_modules)?),
        None => None,
    };

    fs::create_dir_all(options.out.join("modules")).map_err(|source| Error::Io {
        path: options.out.join("modules"),
        source,
    })?;
    fs::create_dir_all(options.out.join("deps")).map_err(|source| Error::Io {
        path: options.out.join("deps"),
        source,
    })?;

    let in_inc: HashSet<&str> = inc_modules
        .iter()
        .map(|entry| entry.module.as_str())
        .collect();
    if !same_tree(options.base, options.out) {
        // The cost of not updating in place; a caller that keeps one directory
        // rewrites only the changed files.
        for entry in &base_modules {
            if gone_set.contains(&entry.module) || in_inc.contains(entry.module.as_str()) {
                continue;
            }
            copy(
                &options.base.join(&entry.file),
                &options.out.join(&entry.file),
            )?;
        }
    } else {
        for file in &dropped_files {
            // A file that is already gone is the state this line wants.
            let _ = fs::remove_file(options.out.join(file));
        }
    }

    let mut updated: Vec<String> = Vec::with_capacity(inc_modules.len());
    let mut ir_changed: Vec<String> = Vec::new();
    for entry in &inc_modules {
        let inc = options
            .inc
            .expect("there are entries only when there is a tree");
        copy(&inc.join(&entry.file), &options.out.join(&entry.file))?;
        let before = entries.get(&entry.module);
        if before.is_none() {
            order.push(entry.module.clone());
        }
        if before.is_none_or(|was| was.raw.get("contentHash") != entry.raw.get("contentHash")) {
            ir_changed.push(entry.module.clone());
        }
        entries.insert(entry.module.clone(), entry.clone());
        updated.push(entry.module.clone());
    }
    // Before the dependency slice is recomputed, not after: the slice is walked
    // in this order and its last writer wins, so an order applied only to the
    // index would leave the two disagreeing about the same package.
    if let Some(listed) = listed {
        order = listed;
    }
    let modules_done = started.elapsed();

    // Recompute the dependency slice from the merged module files: a reference
    // is a dependency iff its defining module is not one of the package's.
    let own: HashSet<&str> = order.iter().map(String::as_str).collect();
    let mut dep: BTreeMap<String, String> = BTreeMap::new();
    let mut declarations = 0usize;
    for module in &order {
        let entry = &entries[module];
        let parsed = read_module_file(&options.out.join(&entry.file)).map_err(Error::Ir)?;
        declarations += parsed.declarations.len();
        for decl in &parsed.declarations {
            for reference in &decl.refs {
                if !own.contains(reference.module.as_str()) {
                    // Last writer wins, as `Map.prototype.set` does.
                    dep.insert(reference.name.clone(), reference.module.clone());
                }
            }
        }
    }

    let mut by_root: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for (name, module) in &dep {
        by_root
            .entry(module_root(module).to_owned())
            .or_default()
            .insert(name.clone(), module.clone());
    }
    // The roots become `index.json`'s `dependencyMaps` order, so they are sorted
    // the way Lean's writer sorts them: `str`'s `Ord` = code point order, not
    // UTF-16. Every root on the target is ASCII, where the two agree, so
    // `tests/merge.rs` builds a pair that does not and pins this side.
    let mut roots: Vec<&String> = by_root.keys().collect();
    roots.sort();

    // **The weakest claim any file under the merged tree makes**, which is not
    // always the base's: the incremental module files are copied in verbatim, so
    // a tree can hold two extractor runs' output at once, and an older binary
    // merging into a newer tree leaves modules below the index's number. The
    // index is what every cheap readability question asks, and one that
    // overstates is only found false when a reader dies on a module.
    let schema_version = weakest_schema(base_index.get("schemaVersion"), inc_schema.as_ref());
    let mut dep_maps: Vec<DepMapRecord> = Vec::with_capacity(roots.len());
    for root in roots {
        let declarations = &by_root[root];
        let body = serde_json::to_string(&DepSlice {
            declarations,
            package: root,
            schema_version,
        })
        .expect("a dependency slice is strings and one number");
        let file = format!("deps/{root}.json");
        write(&options.out.join(&file), &body)?;
        dep_maps.push(DepMapRecord {
            package: root.clone(),
            file,
            entries: declarations.len(),
            bytes: body.len(),
        });
    }

    // Drop dependency files that no longer belong (a package that stopped being
    // referenced, or the own-package slice a partial run wrongly produced).
    let kept: HashSet<&str> = dep_maps.iter().map(|record| record.file.as_str()).collect();
    let deps_dir = options.out.join("deps");
    let listing = fs::read_dir(&deps_dir).map_err(|source| Error::Io {
        path: deps_dir.clone(),
        source,
    })?;
    let mut stale: Vec<PathBuf> = Vec::new();
    for found in listing {
        let found = found.map_err(|source| Error::Io {
            path: deps_dir.clone(),
            source,
        })?;
        let name = found.file_name();
        let relative = format!("deps/{}", name.to_string_lossy());
        if !kept.contains(relative.as_str()) {
            stale.push(deps_dir.join(name));
        }
    }
    // Sorted so that a failure names the same file whatever the directory
    // listing's order was; the removal itself does not care.
    stale.sort();
    for path in stale {
        fs::remove_file(&path).map_err(|source| Error::Io { path, source })?;
    }

    let mut index = base_index.clone();
    if let Some(weakest) = schema_version {
        // Never *adds* the key: an index without one is a schema-1 file.
        index.insert("schemaVersion", weakest.clone());
    }
    index.insert("moduleCount", Value::from(order.len()));
    index.insert("declarationCount", Value::from(declarations));
    index.insert(
        "modules",
        Value::Array(order.iter().map(|m| entries[m].raw.clone()).collect()),
    );
    index.insert(
        "dependencyMaps",
        serde_json::to_value(&dep_maps).expect("counts and strings serialise"),
    );
    write(
        &options.out.join("index.json"),
        &serde_json::to_string(&index).expect("the index came from JSON"),
    )?;
    let total = started.elapsed();

    let summary = MergeSummary {
        updated,
        removed: gone.len(),
        ir_changed,
        modules: order.len(),
        declarations,
        dep_maps,
        copy_seconds: modules_done.as_secs_f64(),
        deps_seconds: total.saturating_sub(modules_done).as_secs_f64(),
        total_seconds: total.as_secs_f64(),
    };
    if let Some(path) = options.changed_out {
        write_text(path, &summary.ir_changed)?;
    }
    if let Some(path) = options.timings {
        write_json_line(
            path,
            &MergeTimings {
                command: "merge",
                updated: summary.updated.len(),
                removed: summary.removed,
                ir_changed: summary.ir_changed.len(),
                modules: summary.modules,
                copy_seconds: summary.copy_seconds,
                deps_seconds: summary.deps_seconds,
                total_seconds: summary.total_seconds,
            },
        )?;
    }
    Ok(summary)
}

/// The three `*Seconds` are diagnostics; no test may assert on them.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MergeTimings<'a> {
    command: &'a str,
    updated: usize,
    removed: usize,
    ir_changed: usize,
    modules: usize,
    copy_seconds: f64,
    deps_seconds: f64,
    total_seconds: f64,
}

/// First component of a module name. The empty name yields the empty root — a
/// root nobody can name, which is what a reference to a module with an empty
/// name would produce.
fn module_root(module: &str) -> &str {
    module.split('.').next().unwrap_or("")
}

/// The merged index's module order, taken from the package's own list.
///
/// `kept` is the base index's modules with the deletions already dropped, `inc`
/// the partial extraction's entries; together they are the set the merge is
/// about to write, before a single byte of it exists.
///
/// A repeated name is deduplicated, keeping its first position: a list that
/// names a module twice is one list, not two modules, and writing the entry
/// twice would produce an index no extraction can produce. A list that does not
/// describe the tree is [`Error::ModuleListMismatch`] — both ways of carrying on
/// are silent, and neither moves a page byte.
fn listed_order(
    list: &[String],
    kept: &[String],
    inc: &[IndexEntry],
) -> Result<Vec<String>, Error> {
    let mut in_tree: HashSet<&str> = kept.iter().map(String::as_str).collect();
    let mut merged: Vec<&str> = kept.iter().map(String::as_str).collect();
    for entry in inc {
        if in_tree.insert(entry.module.as_str()) {
            merged.push(entry.module.as_str());
        }
    }

    let mut in_list: HashSet<&str> = HashSet::new();
    let mut wanted: Vec<String> = Vec::with_capacity(list.len());
    for module in list {
        if in_list.insert(module.as_str()) {
            wanted.push(module.clone());
        }
    }

    let missing: Vec<String> = wanted
        .iter()
        .filter(|module| !in_tree.contains(module.as_str()))
        .cloned()
        .collect();
    let extra: Vec<String> = merged
        .iter()
        .filter(|module| !in_list.contains(*module))
        .map(|module| (*module).to_owned())
        .collect();
    if missing.is_empty() && extra.is_empty() {
        return Ok(wanted);
    }
    Err(Error::ModuleListMismatch { missing, extra })
}

/// The result of `merge --verify A --against B`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VerifyReport {
    /// One line per finding, in the order they were found.
    pub lines: Vec<String>,
    /// Zero is exit 0.
    pub problems: usize,
    pub module_files_identical: usize,
    pub modules_in_a: usize,
    pub dependency_entries_in_a: usize,
    pub dependency_entries_in_b: usize,
    pub dependency_mismatches: usize,
}

impl VerifyReport {
    #[must_use]
    pub fn to_text(&self) -> String {
        let mut text = String::new();
        for line in &self.lines {
            text.push_str(line);
            text.push('\n');
        }
        text
    }
}

/// Compares two IR trees: module files byte for byte, index entries field by
/// field, dependency slices **as name -> module maps**.
///
/// The slices could be compared byte for byte too — `tests/merge.rs` does — but
/// the mapping is what tells a caller that two trees *mean* the same thing, and
/// it is the only check that survives a future extractor emitting them in
/// another order.
pub fn verify(a: &Path, b: &Path) -> Result<VerifyReport, Error> {
    let mut lines: Vec<String> = Vec::new();
    let a_index_path = a.join("index.json");
    let b_index_path = b.join("index.json");
    let index_a: JsonObject = read_json(&a_index_path, IrFile::Index)?;
    let index_b: JsonObject = read_json(&b_index_path, IrFile::Index)?;
    let mut problems = 0usize;

    let map_a = module_map(&index_a, &a_index_path)?;
    let map_b = module_map(&index_b, &b_index_path)?;
    if map_a.len() != map_b.len() {
        lines.push(format!(
            "FAIL module count {} vs {}",
            map_a.len(),
            map_b.len()
        ));
        problems += 1;
    }
    let mut same = 0usize;
    for (name, entry_a) in map_a.iter() {
        let Some(entry_b) = map_b.get(name) else {
            lines.push(format!("FAIL missing in B: {name}"));
            problems += 1;
            continue;
        };
        for key in ["file", "bytes", "declarations", "contentHash"] {
            if entry_a.raw.get(key) != entry_b.raw.get(key) {
                lines.push(format!(
                    "FAIL index.{key} {name}: {} vs {}",
                    js_display(entry_a.raw.get(key)),
                    js_display(entry_b.raw.get(key)),
                ));
                problems += 1;
            }
        }
        let bytes_a = read(&a.join(&entry_a.file))?;
        let bytes_b = read(&b.join(&entry_b.file))?;
        if bytes_a == bytes_b {
            same += 1;
        } else {
            lines.push(format!("FAIL bytes differ: {name}"));
            problems += 1;
        }
    }
    lines.push(format!(
        "module files byte-identical: {same}/{}",
        map_a.len()
    ));

    // Dependency slices, compared as mappings.
    let dep_a = dep_mapping(a, &index_a, &a_index_path)?;
    let dep_b = dep_mapping(b, &index_b, &b_index_path)?;
    let lookup_b: HashMap<&str, &str> = dep_b
        .iter()
        .map(|(name, module)| (name, module.as_str()))
        .collect();
    let lookup_a: HashSet<&str> = dep_a.keys().collect();
    let mut dep_bad = 0usize;
    for (name, module) in dep_a.iter() {
        if lookup_b.get(name).copied() != Some(module.as_str()) {
            if dep_bad < VERIFY_DEP_FAILURES {
                lines.push(format!(
                    "FAIL dep {name}: {module} vs {}",
                    lookup_b.get(name).map_or("undefined", |found| *found)
                ));
            }
            dep_bad += 1;
        }
    }
    for name in dep_b.keys() {
        if !lookup_a.contains(name) {
            if dep_bad < VERIFY_DEP_FAILURES {
                lines.push(format!("FAIL dep only in B: {name}"));
            }
            dep_bad += 1;
        }
    }
    lines.push(format!(
        "dependency map entries: {} vs {}, mismatches {dep_bad}",
        dep_a.len(),
        dep_b.len()
    ));
    problems += dep_bad;
    lines.push(if problems == 0 {
        "VERIFY OK".to_owned()
    } else {
        format!("VERIFY FAILED ({problems} problems)")
    });

    Ok(VerifyReport {
        lines,
        problems,
        module_files_identical: same,
        modules_in_a: map_a.len(),
        dependency_entries_in_a: dep_a.len(),
        dependency_entries_in_b: dep_b.len(),
        dependency_mismatches: dep_bad,
    })
}

const VERIFY_DEP_FAILURES: usize = 10;

/// A repeated module keeps its first position and takes its last value —
/// [`Ordered::insert`]'s rule, which is why it is that type and not a `Vec` of
/// pairs with the rule written out again.
fn module_map(index: &JsonObject, path: &Path) -> Result<Ordered<IndexEntry>, Error> {
    let mut out = Ordered::new();
    for entry in index_entries(index, path)? {
        out.insert(entry.module.clone(), entry);
    }
    Ok(out)
}

/// Every dependency slice of a tree, flattened to `name -> module` in file
/// order. A tree with no `dependencyMaps` key is empty rather than a failure,
/// and a name two slices both carry follows [`Ordered::insert`]'s rule.
fn dep_mapping(root: &Path, index: &JsonObject, path: &Path) -> Result<Ordered<String>, Error> {
    let mut out = Ordered::new();
    let entries = match index.get("dependencyMaps") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(entries)) => entries.clone(),
        Some(_) => {
            return Err(Error::IndexShape {
                path: path.to_owned(),
                message: "dependencyMaps is not an array".to_owned(),
            });
        }
    };
    for entry in entries {
        let Some(Value::String(file)) = entry.get("file") else {
            return Err(Error::IndexShape {
                path: path.to_owned(),
                message: "a dependencyMaps entry has no string `file`".to_owned(),
            });
        };
        let slice_path = root.join(file);
        let slice: JsonObject = read_json(&slice_path, IrFile::DepMap)?;
        let Some(Value::Object(declarations)) = slice.get("declarations") else {
            return Err(Error::IndexShape {
                path: slice_path,
                message: "declarations is not an object".to_owned(),
            });
        };
        for (name, module) in declarations {
            let module = match module {
                Value::String(module) => module.clone(),
                other => other.to_string(),
            };
            out.insert(name.clone(), module);
        }
    }
    Ok(out)
}

/// The **raw object is what goes back out**, key order and unknown keys
/// included: the merged index carries the extractor's entries verbatim, so a
/// typed struct here would quietly rewrite them into this crate's field order.
#[derive(Clone, Debug, PartialEq, Eq)]
struct IndexEntry {
    module: String,
    file: String,
    raw: Value,
}

/// `index.modules`, refused rather than guessed at when it is not an array of
/// objects each carrying `module` and `file` as strings: no extraction produces
/// that shape, so there is nothing to recover.
fn index_entries(index: &JsonObject, path: &Path) -> Result<Vec<IndexEntry>, Error> {
    let shape = |message: &str| Error::IndexShape {
        path: path.to_owned(),
        message: message.to_owned(),
    };
    let Some(Value::Array(modules)) = index.get("modules") else {
        return Err(shape("modules is not an array"));
    };
    modules
        .iter()
        .map(|entry| {
            let string = |key: &str| match entry.get(key) {
                Some(Value::String(text)) => Ok(text.clone()),
                _ => Err(shape(&format!("an index entry has no string `{key}`"))),
            };
            Ok(IndexEntry {
                module: string("module")?,
                file: string("file")?,
                raw: entry.clone(),
            })
        })
        .collect()
}

/// A key that is not there prints as `undefined`.
fn js_display(value: Option<&Value>) -> String {
    match value {
        None => "undefined".to_owned(),
        Some(Value::String(text)) => text.clone(),
        Some(other) => other.to_string(),
    }
}

/// This stage's own reader, for the IR files it takes as **untyped JSON**: the
/// merged `index.json` is written back with keys this crate does not model (see
/// [`JsonObject`]), which [`litedoc4_ir::IrTree`] would drop. Being the one IR
/// read that does not go through the loader, it records the work itself, or
/// `metrics` would report a merge as costing nothing.
fn read_json<T: serde::de::DeserializeOwned>(path: &Path, kind: IrFile) -> Result<T, Error> {
    litedoc4_ir::metrics::record(kind);
    let text = fs::read_to_string(path).map_err(|source| Error::Io {
        path: path.to_owned(),
        source,
    })?;
    serde_json::from_str(&text).map_err(|source| Error::Json {
        path: path.to_owned(),
        source,
    })
}

/// Counted as a module read even though nothing is parsed: the bytes are pulled
/// in, which is the work the counter is about. The `fs::copy` in [`merge`] is
/// *not* counted.
fn read(path: &Path) -> Result<Vec<u8>, Error> {
    litedoc4_ir::metrics::record(IrFile::Module);
    fs::read(path).map_err(|source| Error::Io {
        path: path.to_owned(),
        source,
    })
}

fn copy(from: &Path, to: &Path) -> Result<(), Error> {
    fs::copy(from, to).map(|_| ()).map_err(|source| Error::Io {
        path: from.to_owned(),
        source,
    })
}
