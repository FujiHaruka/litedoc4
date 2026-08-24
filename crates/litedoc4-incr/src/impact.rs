//! A changed module set in, the set of pages that have to be rewritten out.
//!
//! Two closures, because they answer different questions.
//!
//! **IMPORTERS(M)** is the reverse *transitive* import closure of `M`, cut down
//! to the package's own modules. It is the **sound** bound: a module that does
//! not transitively import `M` cannot observe anything `M` declares — not a
//! constant, not notation, not an instance. Nothing in Lean reaches further.
//!
//! **REFERRERS(M)** is the modules with at least one `refs` entry whose defining
//! module is `M`. It is a *subset* of IMPORTERS(M) — to name `M`'s constant you
//! must import `M` — and it is the set whose **printed text** mentions something
//! of `M`'s.
//!
//! Neither is "the answer" on its own, which is why `--mode` exists and why
//! nothing here picks a default for the caller.
//!
//! The pages whose docstring links went stale because a name moved somewhere
//! else entirely are the other half of the render set, and **this stage never
//! reads that half**: the caller unions the two *after* both have been computed,
//! which is the point of deriving them separately.
//!
//! **When the changed set is empty and `--mode` is not `all`, this stage writes
//! no `--print-set` at all** ([`ImpactRun::summary`] is `None`), so the caller
//! has to read a missing file as the empty set.

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::path::Path;

use litedoc4_ir::{IrTree, sort_utf16};
use serde::Serialize;

use crate::error::Error;
use crate::io::write;

/// [`Mode::Unrecognised`] is carried rather than refused at parse time, because
/// the mode is only ever consulted when there is something to select: `--mode
/// nonsense` with an empty changed set **exits 0 having done nothing**.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    SelfOnly,
    /// self + REFERRERS, **direct only**. The transitive count is reported
    /// beside it but is not what this mode selects.
    Referrers,
    /// self + IMPORTERS, transitively: the sound bound.
    #[default]
    Importers,
    /// Every module of the package, whatever changed — **and valid with an empty
    /// changed set**. Not a wider closure over the same graph: it is the answer
    /// when the *renderer's* input moved rather than any module's, so no module
    /// IR is stale and every page is.
    All,
    Unrecognised(String),
}

impl Mode {
    #[must_use]
    pub fn parse(text: &str) -> Self {
        match text {
            "self" => Self::SelfOnly,
            "referrers" => Self::Referrers,
            "importers" => Self::Importers,
            "all" => Self::All,
            other => Self::Unrecognised(other.to_owned()),
        }
    }

    #[must_use]
    pub fn name(&self) -> &str {
        match self {
            Self::SelfOnly => "self",
            Self::Referrers => "referrers",
            Self::Importers => "importers",
            Self::All => "all",
            Self::Unrecognised(text) => text,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ImpactOptions<'a> {
    /// Its `index.json` is what defines the package's modules.
    pub ir: &'a Path,
    /// The changed modules, **in the order they were given** — the `--changed`
    /// flags first, then the lines of `--changed-file`. The order reaches the
    /// summary's `changed` array, and repeats are kept.
    pub changed: &'a [String],
    pub mode: &'a Mode,
    /// A per-module census (TSV). Written whatever the changed set is, and
    /// **before** the selection.
    pub census: Option<&'a Path>,
    /// The selected modules, one name per line — the render set's first half.
    pub print_set: Option<&'a Path>,
    pub json: Option<&'a Path>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImpactRun {
    pub census_modules: Option<usize>,
    /// `None` when the changed set was empty and the mode was not
    /// [`Mode::All`]: no `--print-set` is written at all.
    pub summary: Option<ImpactSummary>,
}

/// **`PartialEq`**, unlike the other stages' summaries: nothing in it is a
/// clock. Every number here is a denominator something else gets quoted
/// against, so tests are meant to assert on all of them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImpactSummary {
    /// The argument as it was given, not a resolved path.
    pub ir: String,
    pub changed: Vec<String>,
    pub mode: String,
    pub own_modules: usize,
    /// Distinct changed modules.
    pub self_modules: usize,
    pub referrers_direct: usize,
    pub referrers_transitive: usize,
    pub importers_transitive: usize,
    /// In **UTF-16 order**: this list is what `--print-set` writes and what the
    /// renderer is then asked for.
    pub selected: Vec<String>,
    /// Summed from the **module files**, not from `index.json`'s `declarations`
    /// column.
    pub selected_declarations: usize,
    /// Summed from `index.json`'s `bytes` column over the selected entries, so a
    /// repeated index entry counts twice.
    pub selected_ir_bytes: u64,
}

/// Computes the two closures and selects a module set.
pub fn impact(options: &ImpactOptions<'_>) -> Result<ImpactRun, Error> {
    let tree = IrTree::open_unvalidated(options.ir).map_err(Error::Ir)?;
    let index = tree.index();
    let own: HashSet<&str> = index
        .modules
        .iter()
        .map(|entry| entry.module.as_str())
        .collect();

    // One pass over the IR: the import edges, the reference edges and the
    // declaration counts all come out of the same read.
    let mut direct_imports: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut ref_modules: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut decl_count: HashMap<&str, usize> = HashMap::new();
    let mut loaded: Vec<litedoc4_ir::ModuleFile> = Vec::with_capacity(index.modules.len());
    for entry in &index.modules {
        loaded.push(tree.module(entry).map_err(Error::Ir)?);
    }
    for module in &loaded {
        let name = module.module.as_str();
        direct_imports.insert(
            name,
            module
                .imports
                .iter()
                .map(String::as_str)
                .filter(|import| own.contains(import))
                .collect(),
        );
        decl_count.insert(name, module.declarations.len());
        // Each named module once, however many declarations name it.
        let mut named: Vec<&str> = Vec::new();
        let mut seen: HashSet<&str> = HashSet::new();
        for decl in &module.declarations {
            for reference in &decl.refs {
                let owner = reference.module.as_str();
                if own.contains(owner) && owner != name && seen.insert(owner) {
                    named.push(owner);
                }
            }
        }
        ref_modules.insert(name, named);
    }

    // Reverse both graphs. Every own-package module gets a list, so a module
    // nobody imports is an empty list rather than an absent key.
    let mut imported_by: HashMap<&str, Vec<&str>> = own.iter().map(|m| (*m, Vec::new())).collect();
    for (module, imports) in &direct_imports {
        for import in imports {
            imported_by
                .get_mut(import)
                .expect("the imports were filtered to own-package modules")
                .push(module);
        }
    }
    let mut referred_by: HashMap<&str, Vec<&str>> = own.iter().map(|m| (*m, Vec::new())).collect();
    for (module, named) in &ref_modules {
        for owner in named {
            referred_by
                .get_mut(owner)
                .expect("the references were filtered to own-package modules")
                .push(module);
        }
    }

    let census_modules = match options.census {
        Some(path) => {
            let mut rows = String::from(CENSUS_HEADER);
            for entry in &index.modules {
                let module = entry.module.as_str();
                rows.push('\n');
                write!(
                    rows,
                    "{module}\t{}\t{}\t{}\t{}\t{}",
                    decl_count.get(module).copied().unwrap_or(0),
                    direct_imports.get(module).map_or(0, Vec::len),
                    imported_by.get(module).map_or(0, Vec::len),
                    closure(&[module], &imported_by).len(),
                    referred_by.get(module).map_or(0, Vec::len),
                )
                .expect("writing to a String cannot fail");
            }
            rows.push('\n');
            write(path, &rows)?;
            Some(index.modules.len())
        }
        None => None,
    };

    // With nothing changed and a mode that is not `all` there is no question.
    if options.changed.is_empty() && *options.mode != Mode::All {
        return Ok(ImpactRun {
            census_modules,
            summary: None,
        });
    }

    for module in options.changed {
        if !own.contains(module.as_str()) {
            return Err(Error::NotAModule {
                module: module.clone(),
            });
        }
    }
    let seeds: Vec<&str> = options.changed.iter().map(String::as_str).collect();
    let self_set: HashSet<&str> = seeds.iter().copied().collect();
    let importers = closure(&seeds, &imported_by);
    // Transitive over the reference edges: reported, never selected. `--mode
    // referrers` takes the direct set below, and the gap between the two counts
    // is the whole reason both are in the summary.
    let referrers_transitive = closure(&seeds, &referred_by);
    let mut referrers_direct: HashSet<&str> = HashSet::new();
    for module in &seeds {
        for referrer in referred_by.get(module).into_iter().flatten() {
            referrers_direct.insert(referrer);
        }
    }

    let selected: HashSet<&str> = match options.mode {
        Mode::SelfOnly => self_set.clone(),
        Mode::Referrers => self_set.union(&referrers_direct).copied().collect(),
        Mode::Importers => self_set.union(&importers).copied().collect(),
        Mode::All => own.clone(),
        Mode::Unrecognised(text) => {
            return Err(Error::UnknownMode { mode: text.clone() });
        }
    };

    // UTF-16 code unit order; this list decides `--print-set`'s.
    let mut list: Vec<String> = selected.iter().map(|m| (*m).to_owned()).collect();
    sort_utf16(&mut list);

    let summary = ImpactSummary {
        ir: options.ir.display().to_string(),
        changed: options.changed.to_vec(),
        mode: options.mode.name().to_owned(),
        own_modules: own.len(),
        self_modules: self_set.len(),
        referrers_direct: referrers_direct.len(),
        referrers_transitive: referrers_transitive.len(),
        importers_transitive: importers.len(),
        selected_declarations: list
            .iter()
            .map(|module| decl_count.get(module.as_str()).copied().unwrap_or(0))
            .sum(),
        selected_ir_bytes: index
            .modules
            .iter()
            .filter(|entry| selected.contains(entry.module.as_str()))
            .map(|entry| entry.bytes)
            .sum(),
        selected: list,
    };

    let body = summary.to_json();
    if let Some(path) = options.json {
        write(path, &(body + "\n"))?;
    }
    if let Some(path) = options.print_set {
        // **Not** [`crate::io::write_text`]: this writes one blank line where
        // that would write an empty file. Reaching the difference needs an IR
        // with no modules at all, and `--only-from` drops blank lines, so the
        // two spell the same set; the bytes here are what the frozen fixtures
        // compare against.
        write(path, &(summary.selected.join("\n") + "\n"))?;
    }
    Ok(ImpactRun {
        census_modules,
        summary: Some(summary),
    })
}

impl ImpactSummary {
    /// What `--json` holds, with the trailing newline added by the caller.
    #[must_use]
    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(&ImpactJson {
            ir: &self.ir,
            changed: &self.changed,
            mode: &self.mode,
            own_modules: self.own_modules,
            self_modules: self.self_modules,
            referrers_direct: self.referrers_direct,
            referrers_transitive: self.referrers_transitive,
            importers_transitive: self.importers_transitive,
            selected: self.selected.len(),
            selected_declarations: self.selected_declarations,
            selected_ir_bytes: self.selected_ir_bytes,
        })
        .expect("counts and strings serialise")
    }
}

const CENSUS_HEADER: &str =
    "module\tdeclarations\tdirectImports\timportedByDirect\timportersTransitive\treferrersDirect";

/// Field order is part of the summary file's bytes.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ImpactJson<'a> {
    ir: &'a str,
    changed: &'a [String],
    mode: &'a str,
    own_modules: usize,
    #[serde(rename = "self")]
    self_modules: usize,
    referrers_direct: usize,
    referrers_transitive: usize,
    importers_transitive: usize,
    selected: usize,
    selected_declarations: usize,
    selected_ir_bytes: u64,
}

/// Everything reachable from `seeds` along `edges`.
///
/// **The seeds are not in the result unless something leads back to them** —
/// the stack is seeded, the visited set is not — so `importersTransitive` counts
/// *other* modules and every caller unions the seeds back in itself. On an
/// acyclic import graph the two spellings differ by exactly the seeds; on a
/// cyclic reference graph they do not.
fn closure<'a>(seeds: &[&'a str], edges: &HashMap<&'a str, Vec<&'a str>>) -> HashSet<&'a str> {
    let mut seen: HashSet<&str> = HashSet::new();
    let mut stack: Vec<&str> = seeds.to_vec();
    while let Some(current) = stack.pop() {
        for next in edges.get(current).into_iter().flatten() {
            if seen.insert(next) {
                stack.push(next);
            }
        }
    }
    seen
}
