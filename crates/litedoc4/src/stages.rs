//! The stages that turn an IR tree into a site: `site`, `render`, `global`.
//!
//! `site` is both halves in one command and `render` is the first half alone;
//! [`generate_site`] is what keeps them from being two answers to one question.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::Instant;

use litedoc4_global::{GlobalOptions, GlobalSummary, build_global};
use litedoc4_render::{ModuleSet, RenderOptions, RenderSummary, render_site};

use crate::{Failure, print_global_summary, print_render_summary, site_config, usage};

/// Full generation: the module pages **and** the six whole-package artifacts,
/// into one tree, from one IR tree, in one command.
///
/// Five flags of the two subcommands it calls are deliberately **not** accepted:
///
/// - **`--only` / `--only-from`.** Full generation is every module; that is what
///   the word means. A subset is `render`'s job, and the page set here is
///   [`ModuleSet::All`] with no way to say otherwise.
/// - **`--before` / `--print-set` / `--delta-json`.** The map delta answers
///   "which pages can have gone stale", which only an incremental round asks. A
///   full run re-renders all of them, so a delta here would be a diagnostic
///   nobody reads — and one that quietly suggests the run was partial.
pub fn site(args: &[String]) -> Result<(), Failure> {
    let mut ir: Option<PathBuf> = None;
    let mut out: Option<PathBuf> = None;
    let mut source_url: Option<String> = None;
    let mut link_index: Option<PathBuf> = None;
    let mut no_link_index = false;
    let mut root: Option<PathBuf> = None;
    let mut lake: Option<PathBuf> = None;
    let mut deps_docs_map: Option<PathBuf> = None;
    let mut state: Option<PathBuf> = None;
    let mut timings: Option<PathBuf> = None;

    let mut args = crate::cli::Args::new(args);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--ir" => ir = Some(args.value("--ir")?.into()),
            "--out" => out = Some(args.value("--out")?.into()),
            "--source-url" => source_url = Some(args.value("--source-url")?),
            "--link-index" => link_index = Some(args.value("--link-index")?.into()),
            "--no-link-index" => no_link_index = true,
            "--root" => root = Some(args.value("--root")?.into()),
            "--lake" => lake = Some(args.value("--lake")?.into()),
            "--deps-docs-map" => deps_docs_map = Some(args.value("--deps-docs-map")?.into()),
            "--state" => state = Some(args.value("--state")?.into()),
            "--timings" => timings = Some(args.value("--timings")?.into()),
            // Refused by name rather than as "unknown argument": each of these
            // is a real flag of the subcommand `site` calls, so the answer a
            // caller needs is *why it is not here*, not that it was misspelled.
            "--only" | "--only-from" => {
                return usage(format!(
                    "{arg} is not a `site` flag: full generation renders every module, which \
                     is what makes it full. Use `litedoc4 render {arg} ...` for a subset",
                ));
            }
            "--before" | "--print-set" | "--delta-json" => {
                return usage(format!(
                    "{arg} is not a `site` flag: the map delta names the pages an incremental \
                     round has to re-render, and this command re-renders all of them. Use \
                     `litedoc4 global {arg} ...`",
                ));
            }
            "--pages" => {
                return usage(
                    "`site` writes the pages and the six whole-package artifacts into one tree: \
                     name it with --out",
                );
            }
            "--help" | "-h" => return crate::cli::help(),
            other => return crate::cli::unknown(other),
        }
    }

    let Some(ir) = ir else {
        return usage("--ir is required");
    };
    let Some(out) = out else {
        return usage("--out is required");
    };
    let inputs = crate::render_inputs(
        source_url,
        link_index.as_deref(),
        no_link_index,
        root.as_deref(),
        lake.as_deref(),
        deps_docs_map.as_deref(),
    )?;
    let (source_url, external, config) = (inputs.source_url, inputs.external, inputs.config);
    let site = generate_site(
        &ir,
        &out,
        &source_url,
        &external,
        link_index.as_deref(),
        state.as_deref(),
        &config,
    )?;
    let (rendered, derived) = (&site.rendered, &site.derived);

    if let Some(path) = timings {
        // `renderSeconds` / `globalSeconds` / `totalSeconds` are the incremental
        // round's names for the same two phases, so the two records subtract.
        let record = serde_json::json!({
            "command": "site",
            "pagesWritten": rendered.pages_written,
            "modulesInIr": rendered.modules_in_ir,
            "pageBytes": rendered.bytes_written,
            "cacheHits": derived.cache_hits,
            "cacheMisses": derived.cache_misses,
            "renderSeconds": site.render_seconds,
            "globalSeconds": site.global_seconds,
            "totalSeconds": site.render_seconds + site.global_seconds,
        });
        let line = serde_json::to_string(&record).expect("counts and durations serialise") + "\n";
        crate::pipeline::write_file(&path, &line)?;
    }
    Ok(())
}

pub(crate) struct Site {
    pub(crate) rendered: RenderSummary,
    pub(crate) derived: GlobalSummary,
    pub(crate) render_seconds: f64,
    pub(crate) global_seconds: f64,
}

/// **`site` and [`crate::build`] call this, and that is the point**: the gate is
/// "the tree `build` writes is byte-identical to the tree `litedoc4 site`
/// writes", and a shared function turns that from a thing to measure into a
/// thing to state. It is still measured — a shared function can be called with
/// different arguments — but the failure it removes is the two commands drifting
/// a flag apart until the comparison is of two different questions.
///
/// The order (render, then the whole-package derivation) is free here: the cache
/// `global` reads is keyed on the IR, and the two stages write disjoint files
/// (measured). The incremental round runs them the other way round because there
/// the map delta is half of the render set.
pub(crate) fn generate_site(
    ir: &std::path::Path,
    out: &std::path::Path,
    source_url: &str,
    external_links: &litedoc4_render::ExternalLinks,
    link_index: Option<&std::path::Path>,
    state: Option<&std::path::Path>,
    config: &litedoc4_render::SiteConfig,
) -> Result<Site, Failure> {
    let started = Instant::now();
    let rendered = render_site(&RenderOptions {
        ir,
        pages: out,
        source_url,
        external_links,
        link_index,
        config,
        // Not a parameter: full generation is every module.
        only: &ModuleSet::All,
    })
    .map_err(|e| Failure::Failed(e.to_string()))?;
    let render_done = started.elapsed();

    let mut options = GlobalOptions::new(ir, out);
    options.state = state;
    options.config = config;
    let derived = build_global(&options).map_err(|e| Failure::Failed(e.to_string()))?;
    let total = started.elapsed();

    // Labelled per stage: one merged line would lose which half of the tree a
    // number is about, and the two count different things under the same word
    // ("modules").
    print_render_summary("render  ", &rendered);
    print_global_summary("global  ", &derived);
    Ok(Site {
        rendered,
        derived,
        render_seconds: render_done.as_secs_f64(),
        global_seconds: total.saturating_sub(render_done).as_secs_f64(),
    })
}

/// The whole-package artifacts, the `contentHash` cache and the map delta.
///
/// No `--only`: the derivation is over the whole package by construction, and
/// the cache makes it cheap rather than partial. No `--source-url` either — none
/// of the seven artifacts carries a source link, which is why `index.html` has
/// no "repository" anchor. `--print-set` / `--delta-json` do nothing without
/// `--before`: the delta is off unless there is a map to compare against.
pub fn global(args: &[String]) -> Result<(), Failure> {
    let mut ir: Option<PathBuf> = None;
    let mut out: Option<PathBuf> = None;
    let mut state: Option<PathBuf> = None;
    let mut before: Option<PathBuf> = None;
    let mut print_set: Option<PathBuf> = None;
    let mut delta_json: Option<PathBuf> = None;
    let mut timings: Option<PathBuf> = None;
    // `--root` is here for one reason: this command writes `index.html`, and
    // `litedoc4.toml` decides what is on it. Without it, `litedoc4 global` and
    // `litedoc4 site` would put different titles on the same package.
    let mut root: Option<PathBuf> = None;

    let mut args = crate::cli::Args::new(args);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--ir" => ir = Some(args.value("--ir")?.into()),
            "--out" => out = Some(args.value("--out")?.into()),
            "--root" => root = Some(args.value("--root")?.into()),
            "--state" => state = Some(args.value("--state")?.into()),
            "--before" => before = Some(args.value("--before")?.into()),
            "--print-set" => print_set = Some(args.value("--print-set")?.into()),
            "--delta-json" => delta_json = Some(args.value("--delta-json")?.into()),
            "--timings" => timings = Some(args.value("--timings")?.into()),
            "--help" | "-h" => return crate::cli::help(),
            other => return crate::cli::unknown(other),
        }
    }

    let Some(ir) = ir else {
        return usage("--ir is required");
    };
    let Some(out) = out else {
        return usage("--out is required");
    };
    let config = site_config(root.as_deref())?;
    let mut options = GlobalOptions::new(&ir, &out);
    options.config = &config;
    options.state = state.as_deref();
    options.before = before.as_deref();
    options.print_set = print_set.as_deref();
    options.delta_json = delta_json.as_deref();
    options.timings = timings.as_deref();
    let summary = build_global(&options).map_err(|e| Failure::Failed(e.to_string()))?;

    print_global_summary("", &summary);
    Ok(())
}

pub fn render(args: &[String]) -> Result<(), Failure> {
    let mut ir: Option<PathBuf> = None;
    let mut pages: Option<PathBuf> = None;
    let mut source_url: Option<String> = None;
    let mut link_index: Option<PathBuf> = None;
    let mut no_link_index = false;
    let mut root: Option<PathBuf> = None;
    let mut lake: Option<PathBuf> = None;
    let mut deps_docs_map: Option<PathBuf> = None;
    // `None` until an `--only` of either spelling appears: "no subset asked for"
    // and "a subset that came out empty" are different answers.
    let mut only: Option<BTreeSet<String>> = None;

    let mut args = crate::cli::Args::new(args);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--ir" => ir = Some(args.value("--ir")?.into()),
            "--pages" => pages = Some(args.value("--pages")?.into()),
            "--source-url" => source_url = Some(args.value("--source-url")?),
            "--link-index" => link_index = Some(args.value("--link-index")?.into()),
            "--no-link-index" => no_link_index = true,
            "--root" => root = Some(args.value("--root")?.into()),
            "--lake" => lake = Some(args.value("--lake")?.into()),
            "--deps-docs-map" => deps_docs_map = Some(args.value("--deps-docs-map")?.into()),
            "--only" => {
                only.get_or_insert_with(BTreeSet::new)
                    .insert(args.value("--only")?);
            }
            "--only-from" => {
                let path = PathBuf::from(args.value("--only-from")?);
                let text =
                    std::fs::read_to_string(&path).map_err(|source| Failure::io(&path, &source))?;
                let ModuleSet::These(names) = ModuleSet::from_lines(&text) else {
                    unreachable!("from_lines always names a set")
                };
                only.get_or_insert_with(BTreeSet::new).extend(names);
            }
            "--help" | "-h" => return crate::cli::help(),
            other => return crate::cli::unknown(other),
        }
    }

    let Some(ir) = ir else {
        return usage("--ir is required");
    };
    let Some(pages) = pages else {
        return usage("--pages is required");
    };
    let inputs = crate::render_inputs(
        source_url,
        link_index.as_deref(),
        no_link_index,
        root.as_deref(),
        lake.as_deref(),
        deps_docs_map.as_deref(),
    )?;
    let (source_url, external, config) = (inputs.source_url, inputs.external, inputs.config);

    let only = match only {
        Some(names) => ModuleSet::These(names),
        None => ModuleSet::All,
    };
    let summary = render_site(&RenderOptions {
        ir: &ir,
        pages: &pages,
        source_url: &source_url,
        external_links: &external,
        link_index: link_index.as_deref(),
        config: &config,
        only: &only,
    })
    .map_err(|e| Failure::Failed(e.to_string()))?;

    print_render_summary("", &summary);
    Ok(())
}
