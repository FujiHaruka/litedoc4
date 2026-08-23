//! `ledger build` / `ledger check` / `ledger touch`.
//!
//! The three answer "which modules must be re-extracted" without starting Lean.
//! [`LEDGER_FLAGS`] is why they are one subcommand with three names rather than
//! three that share a parser: the flags do not overlap, and one flat parse
//! accepted every flag for all three and read it for one.

use std::path::PathBuf;

use litedoc4_incr::{
    Algorithm, BuildOptions, CheckOptions, TouchOptions, build_ledger, check_ledger,
    read_module_list, touch_ledger,
};

use crate::{Failure, grouped, refused, resolve_external_links, usage, with_dependency_docs};

/// The `detect` stage: the olean hash ledger (plan §6, milestone M3-a).
///
/// Three subcommands rather than three top-level ones, because they share the
/// ledger file and nothing else in the CLI does. `touch` is here for the same
/// reason it is in the library: the measurement target must not be modified, so
/// "module M changed" is injected into the ledger instead.
/// Which `ledger` subcommand accepts which flag.
///
/// `ledger` parses one flat set of flags and then dispatches on the subcommand,
/// so without this table every flag is accepted by all three and read by one:
/// `ledger touch --concurrency 9` used to run, ignore the number, and say
/// nothing. **A flag that does nothing is the shape this project keeps
/// finding** — `extract` refuses it by name for the same reason
/// (`--link-index-omit` without `--link-index`): the run looks right and the
/// artefact is not the one that was asked for.
///
/// `--help` is not here because it is not a subcommand's: every one answers it.
const LEDGER_FLAGS: [(&str, &[&str]); 17] = [
    ("--modules", &["build", "check"]),
    ("--target", &["build"]),
    ("--out", &["build", "touch"]),
    ("--ledger", &["check", "touch"]),
    ("--ir", &["build", "check"]),
    ("--source-url", &["build", "check"]),
    ("--link-index", &["build", "check"]),
    ("--root", &["build", "check"]),
    ("--lake", &["build", "check"]),
    ("--deps-docs-map", &["build", "check"]),
    ("--algorithm", &["build", "check"]),
    ("--concurrency", &["build", "check"]),
    ("--module", &["touch"]),
    ("--changed-out", &["check"]),
    ("--removed-out", &["check"]),
    ("--render-all-out", &["check"]),
    ("--timings", &["build", "check"]),
];

pub fn ledger(args: &[String]) -> Result<(), Failure> {
    let mut modules: Option<PathBuf> = None;
    let mut target: Option<String> = None;
    let mut out: Option<PathBuf> = None;
    let mut ledger: Option<PathBuf> = None;
    let mut ir: Option<PathBuf> = None;
    let mut source_url = String::new();
    let mut link_index: Option<PathBuf> = None;
    let mut package: Option<PathBuf> = None;
    let mut lake: Option<PathBuf> = None;
    let mut deps_docs_map: Option<PathBuf> = None;
    let mut algorithm: Option<Algorithm> = None;
    let mut concurrency: usize = 1;
    let mut module: Option<String> = None;
    let mut changed_out: Option<PathBuf> = None;
    let mut removed_out: Option<PathBuf> = None;
    let mut render_all_out: Option<PathBuf> = None;
    let mut timings: Option<PathBuf> = None;

    let Some(command) = args.first().map(String::as_str) else {
        return usage("ledger needs a subcommand: build, check or touch");
    };
    let mut args = crate::cli::Args::new(&args[1..]);
    while let Some(arg) = args.next() {
        if let Some((_, accepted)) = LEDGER_FLAGS.iter().find(|(flag, _)| *flag == arg.as_str())
            && !accepted.contains(&command)
        {
            let belongs: Vec<String> = accepted.iter().map(|s| format!("`ledger {s}`")).collect();
            return usage(format!(
                "{arg} is not a flag of `ledger {command}`: it belongs to {}",
                belongs.join(" / "),
            ));
        }
        match arg.as_str() {
            "--modules" => modules = Some(args.value("--modules")?.into()),
            "--target" => target = Some(args.value("--target")?),
            "--out" => out = Some(args.value("--out")?.into()),
            "--ledger" => ledger = Some(args.value("--ledger")?.into()),
            "--ir" => ir = Some(args.value("--ir")?.into()),
            "--source-url" => source_url = args.value("--source-url")?,
            // M5-b: the dependency map joins the render key, so `ledger build`
            // and `ledger check` have to be able to name it. Absent, and a path
            // that does not exist, both leave the key out.
            "--link-index" => link_index = Some(args.value("--link-index")?.into()),
            // M7-c. **Not `--target`**, even though on a real package the two
            // are the same directory: `--target` is the tree whose oleans are
            // hashed, and this is the package whose manifest and toolchain pin
            // the dependencies. Keeping them apart is what lets `ledger build`
            // over a hashed tree with no package behind it — every test in this
            // repository — go on producing the key it produced before M7.
            "--root" => package = Some(args.value("--root")?.into()),
            "--lake" => lake = Some(args.value("--lake")?.into()),
            // A-1, and it is here for exactly the reason `--link-index` and
            // `--root` are: the resolved documentation map is part of the render
            // key, so a `ledger` run that cannot see it computes a different key
            // from the one `build` recorded and then reports "changed" or
            // "unchanged" for a reason that is not true.
            "--deps-docs-map" => deps_docs_map = Some(args.value("--deps-docs-map")?.into()),
            "--algorithm" => algorithm = Some(Algorithm::new(args.value("--algorithm")?)),
            "--concurrency" => concurrency = args.number("--concurrency")?,
            "--module" => module = Some(args.value("--module")?),
            "--changed-out" => changed_out = Some(args.value("--changed-out")?.into()),
            "--removed-out" => removed_out = Some(args.value("--removed-out")?.into()),
            "--render-all-out" => render_all_out = Some(args.value("--render-all-out")?.into()),
            "--timings" => timings = Some(args.value("--timings")?.into()),
            "--help" | "-h" => return crate::cli::help(),
            other => return crate::cli::unknown(other),
        }
    }

    match command {
        "build" => {
            let (Some(modules), Some(target), Some(out)) = (modules, target, out) else {
                return usage(
                    "ledger build needs --modules <file>, --target <repo> and --out <ledger.json>",
                );
            };
            let names = read_module_list(&modules).map_err(refused)?;
            let algorithm = algorithm.unwrap_or_else(Algorithm::sha256);
            let external = with_dependency_docs(
                resolve_external_links(package.as_deref(), lake.as_deref()),
                deps_docs_map.as_deref(),
            )?;
            let summary = build_ledger(&BuildOptions {
                modules: &names,
                target: &target,
                out: &out,
                ir: ir.as_deref(),
                source_url: &source_url,
                link_index: link_index.as_deref(),
                external_links: Some(&external.digest()),
                algorithm: &algorithm,
                concurrency,
                timings: timings.as_deref(),
            })
            .map_err(refused)?;
            println!(
                "build {} modules, {} olean file(s), {} B hashed in {:.4} s -> {} ({} B)",
                summary.modules,
                summary.files,
                grouped(summary.hashed_bytes),
                summary.hash_seconds,
                out.display(),
                summary.ledger_bytes,
            );
        }
        "check" => {
            let Some(path) = ledger else {
                return usage("ledger check needs --ledger <ledger.json>");
            };
            let names = match modules {
                Some(list) => Some(read_module_list(&list).map_err(refused)?),
                None => None,
            };
            let external = with_dependency_docs(
                resolve_external_links(package.as_deref(), lake.as_deref()),
                deps_docs_map.as_deref(),
            )?;
            let summary = check_ledger(&CheckOptions {
                ledger: &path,
                algorithm: algorithm.as_ref(),
                modules: names.as_deref(),
                ir: ir.as_deref(),
                source_url: &source_url,
                link_index: link_index.as_deref(),
                external_links: Some(&external.digest()),
                concurrency,
                changed_out: changed_out.as_deref(),
                removed_out: removed_out.as_deref(),
                render_all_out: render_all_out.as_deref(),
                timings: timings.as_deref(),
            })
            .map_err(refused)?;
            // The counts first, then the reasons, then the names: a run that
            // re-extracts everything has to say which key did it.
            println!(
                "check {} modules ({}, concurrency {}): {} changed, {} added, {} removed",
                summary.modules,
                summary.algorithm.name(),
                concurrency,
                summary.changed.len(),
                summary.added.len(),
                summary.removed.len(),
            );
            if summary.extract_invalidated() {
                println!(
                    "  extract key changed ({}) -> all {} re-extracted",
                    summary.extract_key_changed.join(","),
                    summary.re_extract.len(),
                );
            }
            if summary.render_all() {
                println!(
                    "  render key changed ({}) -> re-render all, re-extract {}",
                    summary.render_key_changed.join(","),
                    summary.re_extract.len(),
                );
            }
            for module in &summary.changed {
                println!("  changed  {module}");
            }
            for module in &summary.added {
                println!("  added    {module}");
            }
            for module in &summary.removed {
                println!("  removed  {module}");
            }
        }
        "touch" => {
            let (Some(path), Some(module)) = (ledger, module) else {
                return usage("ledger touch needs --ledger <ledger.json> and --module <Module>");
            };
            let out = out.unwrap_or_else(|| path.clone());
            let bytes = touch_ledger(&TouchOptions {
                ledger: &path,
                module: &module,
                out: &out,
            })
            .map_err(refused)?;
            println!(
                "touched {module} in {} ({bytes} B; injected change, the olean is untouched)",
                out.display(),
            );
        }
        other => return usage(format!("unknown ledger subcommand `{other}`")),
    }
    Ok(())
}
