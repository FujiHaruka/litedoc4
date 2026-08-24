//! The stages that answer a question about an IR tree without writing a site:
//! `ownership`, `merge`, `impact`, `prune`, and `links`.
//!
//! Each is one call into [`litedoc4_incr`] with its command line in front of it.

use std::path::PathBuf;

use litedoc4_incr::{
    ImpactOptions, MergeOptions, Mode, ORPHANS_IN_LOG, OwnershipOptions, PruneOptions,
    WITNESSES_IN_LOG, impact as run_impact, merge as run_merge, ownership as run_ownership,
    prune as run_prune, read_module_list, verify as run_verify,
};

use crate::{Failure, refused, resolve_external_links, usage, with_dependency_docs};

/// One row of [`links`].
///
/// **The deep sample is what judges the path building.** A root module is a
/// single component, so `Mathlib` -> `Mathlib.lean` exercises no dot, no nesting
/// and no guillemet; `Mathlib.Order.Basic` -> `Mathlib/Order/Basic.lean` does.
/// Every URL here comes from the renderer's own calls
/// ([`litedoc4_render::ExternalLinks::url_for`],
/// [`litedoc4_render::ExternalLinks::docs_url_for`]) rather than from joining
/// strings, because a checker that builds the URL its own way would agree with a
/// renderer that builds it wrongly. The documentation columns mirror the source
/// ones module for module: one column meaning the source URL sometimes and the
/// documentation URL other times would report two facts in one place.
struct LinkRow {
    root: String,
    base: String,
    url: Option<String>,
    docs_url: Option<String>,
    deep: Option<(String, String)>,
    deep_docs_url: Option<String>,
}

/// The lexicographically first module of `root` below the root itself — first
/// rather than longest, so that the sample does not move when the index gains a
/// module.
fn sample_module(index: &litedoc4_render::LinkIndex, root: &str) -> Option<String> {
    let prefix = format!("{root}.");
    index
        .known_modules()
        .filter(|module| module.starts_with(&prefix))
        .min()
        .map(str::to_owned)
}

fn link_rows(
    links: &litedoc4_render::ExternalLinks,
    index: Option<&litedoc4_render::LinkIndex>,
) -> Vec<LinkRow> {
    links
        .iter()
        .map(|(root, base)| {
            let sample = index.and_then(|index| sample_module(index, root));
            let deep = sample
                .as_ref()
                .and_then(|module| links.url_for(module, None).map(|url| (module.clone(), url)));
            LinkRow {
                // A root is a top-level `Foo.lean`, so the root module's own file
                // is the one file every resolved root is known to have.
                url: links.url_for(root, None),
                docs_url: links.docs_url_for(root, None),
                deep_docs_url: sample
                    .as_deref()
                    .and_then(|module| links.docs_url_for(module, None)),
                root: root.to_owned(),
                base: base.to_owned(),
                deep,
            }
        })
        .collect()
}

/// The dependency link map, as the renderer will see it.
///
/// doc-gen4's reference tree documents only the target's import closure, so most
/// roots have no oracle — **12 of 39 had one, 27 did not** 【実測 2026-08-16】.
/// The other 27 are URLs a server will answer for, so this prints the rows for
/// something to check (`benchmarks/results/external-links-2026-08-18.txt`).
///
/// It reads; it writes nothing but `--out`. `lake` runs (core's revision comes
/// from `lake env lean --githash`), so this needs the target's toolchain.
pub fn links(args: &[String]) -> Result<(), Failure> {
    let mut root: Option<PathBuf> = None;
    let mut lake: Option<PathBuf> = None;
    let mut out: Option<PathBuf> = None;
    let mut link_index: Option<PathBuf> = None;
    let mut deps_docs_map: Option<PathBuf> = None;

    let mut args = crate::cli::Args::new(args);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = Some(args.value("--root")?.into()),
            "--lake" => lake = Some(args.value("--lake")?.into()),
            "--out" => out = Some(args.value("--out")?.into()),
            "--link-index" => link_index = Some(args.value("--link-index")?.into()),
            "--deps-docs-map" => deps_docs_map = Some(args.value("--deps-docs-map")?.into()),
            "--help" | "-h" => return crate::cli::help(),
            other => return crate::cli::unknown(other),
        }
    }
    let Some(root) = root else {
        return usage("--root <repo> is required");
    };
    let index = match link_index {
        Some(path) => Some(
            litedoc4_render::LinkIndex::read(&path)
                .map_err(|source| Failure::io(&path, &source))?,
        ),
        None => None,
    };

    let external = with_dependency_docs(
        resolve_external_links(Some(&root), lake.as_deref()),
        deps_docs_map.as_deref(),
    )?;
    let rows = link_rows(&external, index.as_ref());
    let pinned = rows.iter().filter(|row| row.url.is_some()).count();
    let sampled = rows.iter().filter(|row| row.deep.is_some()).count();
    let documented = rows.iter().filter(|row| row.docs_url.is_some()).count();

    for row in &rows {
        // Tab-separated, `-` for "nothing here" — the shape `cut` and `awk` read
        // without a parser. Only rows go to stdout here; the counts are below.
        let (module, deep) = row
            .deep
            .as_ref()
            .map_or(("-", "-"), |(module, url)| (module.as_str(), url.as_str()));
        println!(
            "{}\t{}\t{}\t{module}\t{deep}\t{}\t{}",
            row.root,
            if row.base.is_empty() { "-" } else { &row.base },
            row.url.as_deref().unwrap_or("-"),
            row.docs_url.as_deref().unwrap_or("-"),
            row.deep_docs_url.as_deref().unwrap_or("-"),
        );
    }
    if index.is_some() {
        println!(
            "external  {sampled}/{} root(s) with a deeper module",
            rows.len()
        );
    }
    // Printed only with a map, because without one the answer is 0 for every
    // root and a zero nobody asked for reads like a failure.
    if deps_docs_map.is_some() {
        println!(
            "external  {documented}/{} root(s) whose own documentation site answers for their \
             root module",
            rows.len(),
        );
    }

    if let Some(path) = out {
        let record = serde_json::json!({
            "root": root.display().to_string(),
            "roots": rows.len(),
            "pinned": pinned,
            "sampled": sampled,
            "documented": documented,
            "rows": rows.iter().map(|row| serde_json::json!({
                "root": row.root,
                "base": row.base,
                "url": row.url,
                "docsUrl": row.docs_url,
                "module": row.deep.as_ref().map(|(module, _)| module),
                "moduleUrl": row.deep.as_ref().map(|(_, url)| url),
                "moduleDocsUrl": row.deep_docs_url,
            })).collect::<Vec<_>>(),
        });
        let text = serde_json::to_string_pretty(&record).expect("strings serialise") + "\n";
        if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
            std::fs::create_dir_all(dir).map_err(|source| Failure::io(dir, &source))?;
        }
        std::fs::write(&path, text).map_err(|source| Failure::io(&path, &source))?;
    }
    Ok(())
}

/// Which modules point at a name that has moved.
///
/// Runs **before** `merge` in a round, and the reason is not a preference: merge
/// overwrites the base IR's idea of who owns each name.
pub fn ownership(args: &[String]) -> Result<(), Failure> {
    let mut base: Option<PathBuf> = None;
    let mut inc: Option<PathBuf> = None;
    let mut removed: Option<PathBuf> = None;
    let mut exclude: Option<PathBuf> = None;
    let mut print_set: Option<PathBuf> = None;
    let mut json: Option<PathBuf> = None;

    let mut args = crate::cli::Args::new(args);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--base" => base = Some(args.value("--base")?.into()),
            "--inc" => inc = Some(args.value("--inc")?.into()),
            "--removed" => removed = Some(args.value("--removed")?.into()),
            "--exclude" => exclude = Some(args.value("--exclude")?.into()),
            "--print-set" => print_set = Some(args.value("--print-set")?.into()),
            "--json" => json = Some(args.value("--json")?.into()),
            "--help" | "-h" => return crate::cli::help(),
            other => return crate::cli::unknown(other),
        }
    }

    // Without a tree to diff against and without a deletion list there is no
    // question to answer.
    let Some(base) = base.filter(|_| inc.is_some() || removed.is_some()) else {
        return usage(
            "ownership needs --base <ir> and at least one of --inc <ir> / --removed <file>",
        );
    };
    let summary = run_ownership(&OwnershipOptions {
        base: &base,
        inc: inc.as_deref(),
        removed: removed.as_deref(),
        exclude: exclude.as_deref(),
        print_set: print_set.as_deref(),
        json: json.as_deref(),
    })
    .map_err(refused)?;

    println!(
        "ownership: {} name(s) lost, {} gained across {} re-extracted module(s) -> {} module(s) \
         need re-extraction — {:.4} s",
        summary.lost_names,
        summary.gained_names,
        summary.inc_modules,
        summary.stale_modules.len(),
        summary.total_seconds,
    );
    for witness in summary.witnesses.iter().take(WITNESSES_IN_LOG) {
        println!(
            "  {:<15} {}  (ref {} :: {})",
            witness.rule, witness.module, witness.reference[0], witness.reference[1],
        );
    }
    Ok(())
}

/// Folds a partial extraction back into the package IR; `--verify` instead
/// compares two trees.
///
/// **`--modules` is what makes the merged `index.json`'s module order a
/// from-scratch extraction's**, which is the order of the list the extractor is
/// handed. Left out, the order is the base index's with new modules appended,
/// for callers that have no list.
pub fn merge(args: &[String]) -> Result<(), Failure> {
    let mut base: Option<PathBuf> = None;
    let mut inc: Option<PathBuf> = None;
    let mut out: Option<PathBuf> = None;
    let mut modules: Option<PathBuf> = None;
    let mut remove: Option<PathBuf> = None;
    let mut changed_out: Option<PathBuf> = None;
    let mut timings: Option<PathBuf> = None;
    let mut verify_tree: Option<PathBuf> = None;
    let mut against: Option<PathBuf> = None;

    let mut args = crate::cli::Args::new(args);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--base" => base = Some(args.value("--base")?.into()),
            "--inc" => inc = Some(args.value("--inc")?.into()),
            "--out" => out = Some(args.value("--out")?.into()),
            "--modules" => modules = Some(args.value("--modules")?.into()),
            "--remove" => remove = Some(args.value("--remove")?.into()),
            "--changed-out" => changed_out = Some(args.value("--changed-out")?.into()),
            "--timings" => timings = Some(args.value("--timings")?.into()),
            "--verify" => verify_tree = Some(args.value("--verify")?.into()),
            "--against" => against = Some(args.value("--against")?.into()),
            "--help" | "-h" => return crate::cli::help(),
            other => return crate::cli::unknown(other),
        }
    }

    if let Some(tree) = verify_tree {
        let Some(against) = against else {
            return usage("merge --verify <ir> needs --against <ir>");
        };
        let report = run_verify(&tree, &against).map_err(refused)?;
        print!("{}", report.to_text());
        return if report.problems == 0 {
            Ok(())
        } else {
            Err(Failure::Answered(1))
        };
    }

    let Some(base) = base.filter(|_| inc.is_some() || remove.is_some()) else {
        return usage("merge needs --base <ir> and at least one of --inc <ir> / --remove <file>");
    };
    // The base tree is never written to unless the caller asks for it by name.
    let out = out.unwrap_or_else(|| {
        let mut merged = base.clone().into_os_string();
        merged.push(".merged");
        PathBuf::from(merged)
    });
    let removed = match &remove {
        Some(path) => read_module_list(path).map_err(refused)?,
        None => Vec::new(),
    };
    let listed = match &modules {
        Some(path) => Some(read_module_list(path).map_err(refused)?),
        None => None,
    };
    let summary = run_merge(&MergeOptions {
        base: &base,
        inc: inc.as_deref(),
        out: &out,
        removed: &removed,
        modules: listed.as_deref(),
        changed_out: changed_out.as_deref(),
        timings: timings.as_deref(),
    })
    .map_err(refused)?;

    println!(
        "merged {} module(s){} into {}: modules {:.4} s, deps+index {:.4} s, total {:.4} s -> {}",
        summary.updated.len(),
        if summary.removed > 0 {
            format!(", removed {}", summary.removed)
        } else {
            String::new()
        },
        summary.modules,
        summary.copy_seconds,
        summary.deps_seconds,
        summary.total_seconds,
        out.display(),
    );
    println!(
        "IR content hash moved for {} of {} re-extracted module(s){}",
        summary.ir_changed.len(),
        summary.updated.len(),
        if summary.ir_changed.is_empty() {
            String::new()
        } else {
            format!(": {}", summary.ir_changed.join(", "))
        },
    );
    Ok(())
}

/// A changed module set in, the modules to re-render out.
///
/// **`global` runs before this** — but not into it: the whole-package map's
/// delta is the other half of the render set, and it reaches the renderer by
/// being *unioned* with this stage's `--print-set`, which is the pipeline's job.
/// A delta with no changes is a **0-byte file, not a blank line**, and this
/// command writes **no `--print-set` at all** when the changed set is empty and
/// the mode is not `all` — a missing file is the empty set.
pub fn impact(args: &[String]) -> Result<(), Failure> {
    let mut ir: Option<PathBuf> = None;
    let mut changed: Vec<String> = Vec::new();
    let mut changed_file: Option<PathBuf> = None;
    let mut mode: Option<String> = None;
    let mut census: Option<PathBuf> = None;
    let mut print_set: Option<PathBuf> = None;
    let mut json: Option<PathBuf> = None;

    let mut args = crate::cli::Args::new(args);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--ir" => ir = Some(args.value("--ir")?.into()),
            "--changed" => changed.push(args.value("--changed")?),
            "--changed-file" => changed_file = Some(args.value("--changed-file")?.into()),
            "--mode" => mode = Some(args.value("--mode")?),
            "--census" => census = Some(args.value("--census")?.into()),
            "--print-set" => print_set = Some(args.value("--print-set")?.into()),
            "--json" => json = Some(args.value("--json")?.into()),
            "--help" | "-h" => return crate::cli::help(),
            other => return crate::cli::unknown(other),
        }
    }

    let Some(ir) = ir else {
        return usage("--ir is required");
    };
    // The order reaches the summary's `changed` array, and repeats are kept
    // rather than folded.
    if let Some(path) = &changed_file {
        changed.extend(read_module_list(path).map_err(refused)?);
    }
    let mode = mode.as_deref().map_or_else(Mode::default, Mode::parse);
    let run = run_impact(&ImpactOptions {
        ir: &ir,
        changed: &changed,
        mode: &mode,
        census: census.as_deref(),
        print_set: print_set.as_deref(),
        json: json.as_deref(),
    })
    .map_err(refused)?;

    if let (Some(modules), Some(path)) = (run.census_modules, &census) {
        println!("census -> {} ({modules} modules)", path.display());
    }
    if let Some(summary) = &run.summary {
        println!("{}", summary.to_json());
    }
    Ok(())
}

/// **The one subcommand that deletes.** Two guards are in the library
/// (containment, and paths built by concatenation rather than
/// [`std::path::Path::join`]); the third is the shape of the flag — `--dry-run`
/// computes the whole answer and writes nothing, so "what would this remove" can
/// be asked of a tree nobody is willing to lose.
pub fn prune(args: &[String]) -> Result<(), Failure> {
    let mut pages: Option<PathBuf> = None;
    let mut remove: Option<PathBuf> = None;
    let mut ir: Option<PathBuf> = None;
    let mut json: Option<PathBuf> = None;
    let mut dry_run = false;

    let mut args = crate::cli::Args::new(args);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--pages" => pages = Some(args.value("--pages")?.into()),
            "--remove" => remove = Some(args.value("--remove")?.into()),
            "--ir" => ir = Some(args.value("--ir")?.into()),
            "--json" => json = Some(args.value("--json")?.into()),
            "--dry-run" => dry_run = true,
            "--help" | "-h" => return crate::cli::help(),
            other => return crate::cli::unknown(other),
        }
    }

    // A page tree with neither a deletion list nor an IR to call orphans against
    // has nothing to do, and doing nothing quietly is how a deleted module's
    // page survives.
    let Some(pages) = pages.filter(|_| remove.is_some() || ir.is_some()) else {
        return usage("prune needs --pages <dir> and at least one of --remove <file> / --ir <dir>");
    };
    let summary = run_prune(&PruneOptions {
        pages: &pages,
        remove: remove.as_deref(),
        ir: ir.as_deref(),
        dry_run,
        json: json.as_deref(),
    })
    .map_err(refused)?;

    println!(
        "prune-pages{}: deleted {}/{} requested, {} orphan(s), {} empty dir(s) — {:.4} s",
        if summary.dry_run { " (dry run)" } else { "" },
        summary.deleted.len(),
        summary.requested,
        summary.orphans.len(),
        summary.emptied.len(),
        summary.total_seconds,
    );
    for orphan in summary.orphans.iter().take(ORPHANS_IN_LOG) {
        println!("  orphan  {orphan}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{link_rows, sample_module};
    use litedoc4_render::{ExternalLinks, LinkIndex};

    /// `@Module` headers are what a `.lidx` calls a known module; the entries
    /// under them are declarations.
    fn index() -> LinkIndex {
        LinkIndex::parse(
            "#lidx2\n@Mathlib\n@Mathlib.Order.Basic\n@Mathlib.Algebra.Group\n@Init.Prelude\n",
        )
    }

    #[test]
    fn sample_module_takes_a_module_below_the_root() {
        assert_eq!(
            sample_module(&index(), "Mathlib").as_deref(),
            Some("Mathlib.Algebra.Group")
        );
    }

    #[test]
    fn sample_module_is_none_when_the_root_stands_alone() {
        // A root whose only module is itself must not sample itself: that URL is
        // already the row's `url`, and the deep column would become a duplicate
        // that looks like coverage.
        let index = LinkIndex::parse("#lidx2\n@Init\n");
        assert_eq!(sample_module(&index, "Init"), None);
    }

    #[test]
    fn sample_module_does_not_match_a_root_by_prefix() {
        // The separator is part of the prefix, so `MathlibTest.Foo` is not one.
        let index = LinkIndex::parse("#lidx2\n@MathlibTest.Foo\n");
        assert_eq!(sample_module(&index, "Mathlib"), None);
    }

    #[test]
    fn a_root_with_no_base_gets_no_url_in_either_column() {
        // The empty base is the resolver's third state — "a dependency, and there
        // is no version-pinned URL for it". Rendering `/Dep/M.lean` for it would
        // be an absolute path on whatever host serves the site.
        let links = ExternalLinks::new([("Dep", "")]);
        let index = LinkIndex::parse("#lidx2\n@Dep.Inner\n");
        let rows = link_rows(&links, Some(&index));
        assert_eq!(rows.len(), 1);
        assert!(rows[0].url.is_none());
        assert!(rows[0].deep.is_none());
    }

    #[test]
    fn both_columns_come_from_url_for() {
        let links = ExternalLinks::new([("Mathlib", "https://example.invalid/blob/deadbeef")]);
        let rows = link_rows(&links, Some(&index()));
        let (module, deep) = rows[0].deep.clone().expect("the index has Mathlib.*");
        assert_eq!(
            rows[0].url.as_deref(),
            Some("https://example.invalid/blob/deadbeef/Mathlib.lean")
        );
        assert_eq!(module, "Mathlib.Algebra.Group");
        assert_eq!(
            deep,
            "https://example.invalid/blob/deadbeef/Mathlib/Algebra/Group.lean"
        );
    }

    #[test]
    fn without_an_index_there_is_no_deep_column() {
        let links = ExternalLinks::new([("Mathlib", "https://example.invalid/blob/deadbeef")]);
        let rows = link_rows(&links, None);
        assert!(rows[0].url.is_some());
        assert!(rows[0].deep.is_none());
    }
}
