//! The stages that turn an IR tree into a site: `site`, `render`, `global`.
//!
//! One IR tree in, pages or whole-package artifacts out. `site` is both halves
//! in one command and `render` is the first half alone; [`generate_site`] is
//! what keeps them from being two answers to one question (M4-d).

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::Instant;

use litedoc4_global::{GlobalOptions, GlobalSummary, build_global};
use litedoc4_render::{ModuleSet, RenderOptions, RenderSummary, render_site};

use crate::{
    Failure, link_index_required, print_global_summary, print_render_summary,
    resolve_external_links, site_config, usage, with_dependency_docs,
};

/// Full generation: the module pages **and** the six whole-package artifacts,
/// into one tree, from one IR tree, in one command.
///
/// **The prototype has no script for this.** `stage7h/run.sh:78-80`'s `render()`
/// is three lines of shell — `render.ts` and then `global.ts build` over the
/// same IR and the same output directory — and every reference site this project
/// owns was made by it. The order is kept because the comparison is stated
/// against it, not because the stages talk: the cache `global` reads is keyed on
/// the IR, and the two write disjoint files 【実測, plan §7, M2】.
///
/// **The incremental round runs the same two stages the other way round**
/// (`incremental.sh` steps 6 and 7), and that is not an inconsistency to tidy
/// away: there, `global`'s map delta is half of the render set, so it has to
/// precede the renderer (plan §6, constraint 2). Here there is no delta and no
/// set, so nothing constrains the order — which is exactly why M3-d2 must not
/// read this function as saying render comes first.
///
/// Five of the two subcommands' flags are deliberately **not** accepted:
///
/// - **`--only` / `--only-from`.** Full generation is every module; that is what
///   the word means. A subset is `render`'s job, and the page set here is
///   [`ModuleSet::All`] with no way to say otherwise.
/// - **`--before` / `--print-set` / `--delta-json`.** The map delta answers
///   "which pages can have gone stale", which only an incremental round (M3-d2)
///   asks. A full run re-renders all of them, so a delta here would be a
///   diagnostic nobody reads — and one that quietly suggests the run was
///   partial.
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
    let Some(source_url) = source_url.filter(|url| !url.is_empty()) else {
        return usage(
            "--source-url is required: doc-gen4 reads it from lake plus git, and it is not in the IR",
        );
    };
    if link_index.is_some() == no_link_index {
        return usage(link_index_required());
    }

    let external = with_dependency_docs(
        resolve_external_links(root.as_deref(), lake.as_deref()),
        deps_docs_map.as_deref(),
    )?;
    let config = site_config(root.as_deref())?;
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
        // `renderSeconds` / `globalSeconds` / `totalSeconds` are
        // `incremental.sh:416-419`'s names for the same two phases, so a full
        // run and an incremental one subtract.
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
        if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
            std::fs::create_dir_all(dir)
                .map_err(|e| Failure::Failed(format!("{}: {e}", dir.display())))?;
        }
        std::fs::write(&path, line)
            .map_err(|e| Failure::Failed(format!("{}: {e}", path.display())))?;
    }
    Ok(())
}

/// What full generation produced: both stages' counts and both stages' clocks.
pub(crate) struct Site {
    pub(crate) rendered: RenderSummary,
    pub(crate) derived: GlobalSummary,
    pub(crate) render_seconds: f64,
    pub(crate) global_seconds: f64,
}

/// Full generation, as a function.
///
/// **`site` and [`crate::build`] call this, and that is the point** 【判断】: the M4-d
/// gate is "the tree `build` writes is byte-identical to the tree `litedoc4
/// site` writes", and a shared function turns that from a thing to measure into
/// a thing to state. It is still measured — a shared function can still be
/// called with different arguments — but the failure mode it removes is the one
/// where the two commands drift a flag apart and the comparison quietly becomes
/// a comparison of two different questions.
///
/// The order (render, then the whole-package derivation) is the prototype's
/// three lines of shell, and it is free here: the cache `global` reads is keyed
/// on the IR, and the two stages write disjoint files 【実測, plan §7, M2】. The
/// incremental round runs them the other way round because there the map delta
/// is half of the render set (plan §6, constraint 2).
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
        // Not a parameter. See `site`'s own documentation.
        only: &ModuleSet::All,
    })
    .map_err(|e| Failure::Failed(e.to_string()))?;
    let render_done = started.elapsed();

    let mut options = GlobalOptions::new(ir, out);
    options.state = state;
    options.config = config;
    let derived = build_global(&options).map_err(|e| Failure::Failed(e.to_string()))?;
    let total = started.elapsed();

    // Both stages' counts, each labelled with the stage that produced it. One
    // merged line would lose which half of the tree a number is about, and the
    // two stages count different things under the same word ("modules").
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
/// the cache makes it cheap rather than partial. No `--source-url` either —
/// none of the seven carries a source link (which is why `index.html` has no
/// "repository" anchor; see `litedoc4_global::entry`).
///
/// `--print-set` / `--delta-json` do nothing without `--before`, exactly as in
/// the prototype: the delta is off unless there is a map to compare against.
pub fn global(args: &[String]) -> Result<(), Failure> {
    let mut ir: Option<PathBuf> = None;
    let mut out: Option<PathBuf> = None;
    let mut state: Option<PathBuf> = None;
    let mut before: Option<PathBuf> = None;
    let mut print_set: Option<PathBuf> = None;
    let mut delta_json: Option<PathBuf> = None;
    let mut timings: Option<PathBuf> = None;
    // `--root` is here for one reason: this command writes `index.html`, and
    // `litedoc4.toml` decides what is on it (feature-sweep C-3). Without it,
    // `litedoc4 global` and `litedoc4 site` would put different titles on the
    // same package — which is exactly the disagreement 決定 3 refuses.
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
    // `None` until an `--only` of either spelling appears: the distinction
    // between "no subset asked for" and "a subset that came out empty" is the
    // whole point (plan §5).
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
                let text = std::fs::read_to_string(&path)
                    .map_err(|e| Failure::Failed(format!("{}: {e}", path.display())))?;
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
    // The prototype refuses too: the source URL is configuration that no IR
    // carries, and a page written without it links every declaration to `/`.
    let Some(source_url) = source_url.filter(|url| !url.is_empty()) else {
        return usage(
            "--source-url is required: doc-gen4 reads it from lake plus git, and it is not in the IR",
        );
    };
    if link_index.is_some() == no_link_index {
        return usage(link_index_required());
    }

    let only = match only {
        Some(names) => ModuleSet::These(names),
        None => ModuleSet::All,
    };
    let external = with_dependency_docs(
        resolve_external_links(root.as_deref(), lake.as_deref()),
        deps_docs_map.as_deref(),
    )?;
    let config = site_config(root.as_deref())?;
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
