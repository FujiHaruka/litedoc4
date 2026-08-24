//! `litedoc4 build` — a Lean package in, a documentation site out, in one
//! command: the libraries, the module list, the source URL, the choice between
//! the full path and the incremental one, and the layout under `--out` that lets
//! a second run find what the first one left.
//!
//! # When the ledger is written — the one ordering that has a silent failure
//!
//! The ledger's claim is "**the IR was built from these oleans, and the pages
//! were rendered from that IR**". Two ways to get its timing wrong, and they are
//! not symmetric:
//!
//! * **Write it early** (before the pages) and a run that dies in the renderer
//!   leaves a ledger saying every module is up to date. The next run re-extracts
//!   nothing, re-renders nothing, and the site is permanently half-old **with no
//!   diagnostic anywhere**. This is the failure mode that matters.
//! * **Write it late but with hashes read late** and the same silence arrives by
//!   a different road: an olean rebuilt *while* this run was extracting gets
//!   recorded as the one its IR came from, and that module is never re-extracted
//!   again.
//!
//! So the rule is one sentence — **hash before extracting, write after
//! rendering** — and it is implemented as: the module hashes come from
//! [`litedoc4_incr::CheckSummary::fresh`] (or, on the first run, from a
//! `ledger build` that runs *before* the extractor), and the file is written by
//! [`write_ledger`] as the last thing a successful run does. Every failure
//! before that point leaves the previous ledger in place and the next run redoes
//! the work. **Redoing work is the safe direction**; it is loud (the next run's
//! `changed` count says so) and it is finite.
//!
//! The two keys are the exception, and deliberately so: `extractKey` is
//! recomputed against the IR tree that now exists, not the one `detect` looked
//! at. They describe *the tree on disk*, and after a successful run that is the
//! merged tree. Writing back `detect`'s copy would leave a ledger claiming the
//! IR was written by whatever wrote the old one, and if the two differ every
//! later run re-extracts all 432 modules for ever.
//!
//! # What `renderKey` covers, and what `--full` is still for
//!
//! The key holds `renderer`, `sourceUrl`, the `.lidx`'s digest and the
//! **dependency link map's** ([`Request::external_links`]), so a bumped
//! dependency — which moves a `rev` and therefore every href into that package —
//! re-renders on its own. Without the last two a run whose dependency map moved
//! and whose IR did not went undetected, and that map reaches 150 of the
//! measurement target's 432 pages' bytes 【実測】.
//!
//! `--full` remains the escape hatch for whatever is *not* in the key — a set
//! that cannot be closed, because it is every input the ledger does not name.
//! The key has a mirror-image cost worth stating: a run whose resolution
//! **degraded** (a package gone from disk, `lake` not on the path) produces a
//! smaller map, a different digest, and therefore a full re-render. That is the
//! right direction — the links really would have changed — but it means an
//! environment that half-works re-renders 432 pages rather than reporting
//! nothing.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use litedoc4_incr::{
    Algorithm, BuildOptions, Ledger, Mode, build_ledger, extract_key, link_index_digest, render_key,
};

use crate::extract::absolute;
use crate::pipeline::{
    Extractor, Incremental, check_source_url, module_names, write_file, write_lines,
};
use crate::resident::Resident;
use crate::{Failure, LINK_INDEX_COST, USAGE, refused, usage};

/// The layout under `--out`. Bumped when a directory written by an older
/// `build` can no longer be continued by this one.
const LAYOUT: u64 = 1;

/// The marker file. Not inside `<out>/site`, because the site's file count is a
/// denominator this project quotes and a stray file in it would change that
/// number.
const MARKER: &str = "litedoc4-build.json";

pub(crate) const DEFAULT_MAX_ROUNDS: usize = 5;

pub(crate) struct Layout {
    out: PathBuf,
    pub(crate) site: PathBuf,
    /// The IR tree, carried between runs.
    pub(crate) ir: PathBuf,
    state: PathBuf,
    work: PathBuf,
    /// Which oleans the IR was built from.
    pub(crate) ledger: PathBuf,
    marker: PathBuf,
    /// Where the dependency map goes when this command derives it. Overridden by
    /// `--link-index`, which names one somebody else made.
    link_index: PathBuf,
    /// The resolved documentation map, which `litedoc4 site --deps-docs-map` and
    /// `litedoc4 render --deps-docs-map` read back.
    ///
    /// Under `work` because it is **one run's answer**: it holds the names that
    /// run verified against the table that run fetched, and a stale one would
    /// link at a page the site no longer documents. Written only when
    /// `--deps-docs-url` was passed.
    deps_docs_map: PathBuf,
}

impl Layout {
    fn new(out: &Path) -> Self {
        Self {
            out: out.to_owned(),
            site: out.join("site"),
            ir: out.join("ir"),
            state: out.join("state"),
            work: out.join("work"),
            ledger: out.join("ledger.json"),
            marker: out.join(MARKER),
            link_index: out.join("link-index.lidx"),
            deps_docs_map: out.join("work").join("deps-docs-map.json"),
        }
    }

    /// Whether every file a continuation reads is there.
    ///
    /// The name map is in the list because the incremental round's map delta
    /// compares against it, and a site tree without one runs with the delta off —
    /// a *correct* run that re-renders too little the first time the map moves.
    /// So is the dependency map: an incremental round renders a *subset*, so a
    /// missing map produces pages whose links are gone, mixed into a tree of
    /// pages that still have theirs. A full generation writes the map again,
    /// which is why a missing one is answered by taking that path rather than by
    /// refusing.
    fn carries_a_previous_run(&self, link_index: &Path) -> bool {
        self.ledger.is_file()
            && self.ir.join("index.json").is_file()
            && self.state.join("global-state.json").is_file()
            && link_index.is_file()
            && self
                .site
                .join("declarations")
                .join("name-map.json")
                .is_file()
    }
}

enum Plan {
    Full(&'static str),
    Incremental,
}

pub fn build(args: &[String]) -> Result<(), Failure> {
    run(&parse(args, None)?)?;
    Ok(())
}

/// The command line of `build` — **and of `watch`**, which is the same request
/// asked over and over.
///
/// One parser, not two: a second would be a second place for `--out` to mean
/// something, and the first thing to drift would be one of the by-name refusals
/// below, which are the part a caller reads only when they are already confused.
/// `None` for `watch` means its own two flags are refused by name here, which is
/// the same treatment every other misplaced flag gets.
pub(crate) fn parse(
    args: &[String],
    mut watch: Option<&mut crate::watch::Flags>,
) -> Result<Request, Failure> {
    let watching = watch.is_some();
    let mut root: Option<PathBuf> = None;
    let mut out: Option<PathBuf> = None;
    let mut libs: Vec<String> = Vec::new();
    let mut link_index: Option<PathBuf> = None;
    let mut source_url: Option<String> = None;
    let mut extractor: Option<String> = None;
    let mut extractor_args: Vec<String> = Vec::new();
    let mut extractor_bin: Option<PathBuf> = None;
    let mut lake: Option<PathBuf> = None;
    let mut jobs: usize = 1;
    let mut mode: Option<String> = None;
    let mut max_rounds = DEFAULT_MAX_ROUNDS;
    let mut timings: Option<PathBuf> = None;
    let mut full = false;
    let mut deps_docs_urls: Vec<String> = Vec::new();
    let mut deps_docs_indexes: Vec<String> = Vec::new();

    let mut args = crate::cli::Args::new(args);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = Some(args.value("--root")?.into()),
            "--out" => out = Some(args.value("--out")?.into()),
            "--lib" => libs.push(args.value("--lib")?),
            "--link-index" => link_index = Some(args.value("--link-index")?.into()),
            "--source-url" => source_url = Some(args.value("--source-url")?),
            "--extractor" => extractor = Some(args.value("--extractor")?),
            "--extractor-arg" => extractor_args.push(args.value("--extractor-arg")?),
            "--extractor-bin" => extractor_bin = Some(args.value("--extractor-bin")?.into()),
            "--lake" => lake = Some(args.value("--lake")?.into()),
            "--jobs" => jobs = args.number("--jobs")?,
            "--mode" => mode = Some(args.value("--mode")?),
            "--max-rounds" => max_rounds = args.number("--max-rounds")?,
            "--timings" => timings = Some(args.value("--timings")?.into()),
            // `watch`'s own two, refused by name on `build`: each is a real flag
            // of a command next door, so what the caller needs to hear is which
            // command owns it.
            "--port" => {
                let raw = args.value("--port")?;
                match watch.as_deref_mut() {
                    Some(flags) => flags.port = Some(raw),
                    None => {
                        return usage(
                            "--port is a `watch` flag: `build` writes a site and exits, so there \
                             is nothing left running to serve it. `litedoc4 watch --root … --out \
                             … --port <n>` is the one that serves",
                        );
                    }
                }
            }
            "--interval" => {
                let raw = args.value("--interval")?;
                match watch.as_deref_mut() {
                    Some(flags) => flags.interval = Some(raw),
                    None => {
                        return usage(
                            "--interval is a `watch` flag: it is how often the loop asks the \
                             ledger, and `build` asks once",
                        );
                    }
                }
            }
            "--full" => {
                only_in_build(
                    watching,
                    "--full",
                    "it means \"regenerate everything, ignoring what is under --out\", and a loop \
                     that did that every pass would never do anything else. Run `litedoc4 build \
                     --full` once, then start watching",
                )?;
                full = true;
            }
            "--deps-docs-url" => {
                only_in_build(watching, "--deps-docs-url", DEPS_DOCS_IN_WATCH)?;
                deps_docs_urls.push(args.value("--deps-docs-url")?);
            }
            "--deps-docs-index" => {
                only_in_build(watching, "--deps-docs-index", DEPS_DOCS_IN_WATCH)?;
                deps_docs_indexes.push(args.value("--deps-docs-index")?);
            }
            // Refused by name: it is `site` and `render`'s flag, and it names
            // the file *this* command writes. Accepting it here would let a run
            // render against a map another run resolved, which is the one thing
            // the artifact exists to make impossible.
            "--deps-docs-map" => {
                return usage(
                    "--deps-docs-map is not a `build` flag: this command resolves the \
                     documentation map itself, from --deps-docs-url, and writes it under \
                     <out>/work for `litedoc4 site` and `litedoc4 render` to read. A build that \
                     rendered against somebody else's resolved map would record its own map's \
                     digest in the ledger",
                );
            }
            // Refused by name: every one is a real flag of a subcommand this one
            // drives, so what the caller needs to hear is which decision `build`
            // has taken over.
            "--ir" | "--pages" | "--ledger" | "--work" | "--state" => {
                return usage(format!(
                    "{arg} is not a `build` flag: this command owns the layout under --out \
                     (<out>/ir, <out>/site, <out>/state, <out>/work, <out>/ledger.json) so that a \
                     second run can find what the first one left. Name the pieces yourself with \
                     `litedoc4 incremental`",
                ));
            }
            "--modules" => {
                return usage(
                    "--modules is not a `build` flag: the list is the source glob over the \
                     libraries (`litedoc4 modules`), and the same list has to reach detect, the \
                     extractor and merge or the merged index.json comes out in an order a \
                     from-scratch run would not have written. Choose the libraries with --lib",
                );
            }
            "--target" => {
                return usage(
                    "--target is not a `build` flag: the package being documented is --root, and \
                     it is the same repository the sources are globbed from, the oleans are hashed \
                     in and `lake env` runs inside",
                );
            }
            "--no-link-index" => {
                return usage(format!(
                    "--no-link-index is not a `build` flag: {LINK_INDEX_COST}, and a build command \
                     whose ordinary output is silently wrong on a third of its pages is not worth \
                     having. `litedoc4 render --no-link-index` still says it on purpose",
                ));
            }
            "--serve" | "--serve-dir" | "--serve-from" => {
                return usage(format!(
                    "{arg} is not a `build` flag: with --extractor-bin this command *is* the \
                     resident path — one Lean environment for the whole run, started here and \
                     released after the last round (see crates/litedoc4/src/resident.rs). There is \
                     nothing to switch on, and a server this run did not start is one whose olean \
                     generation it cannot vouch for",
                ));
            }
            // **`Answered(0)`, not `Ok(())`**: this function's `Ok` is a request
            // to run, and `--help` is not one.
            "--help" | "-h" => {
                println!("{USAGE}");
                return Err(Failure::Answered(0));
            }
            other => return crate::cli::unknown(other),
        }
    }

    let Some(root) = root else {
        return usage("--root <repo> is required: the Lean package to document");
    };
    let Some(out) = out else {
        return usage(
            "--out <dir> is required and has no default: it is where the site, the IR, the cache \
             and the ledger go. The obvious default would be <root>/.lake/build/doc, which is \
             doc-gen4's own output tree — a default that overwrites another tool's output is a \
             data-loss bug with a friendly face",
        );
    };
    // Left out, the map is this command's own artefact: `<out>/link-index.lidx`,
    // written by the resident extractor out of the environment it imported for
    // the extraction. Given, it is an input somebody else made and this command
    // does not touch it. The one shape that cannot work is `--extractor
    // <program>` without `--link-index`: that program's contract is three flags,
    // so nothing here can make it write a map.
    if link_index.is_none() && extractor.is_some() {
        return usage(format!(
            "--extractor <program> needs --link-index <file>: the dependency map is written by the \
             Lean extractor out of the environment it imports, and --extractor names a program \
             whose interface is `--modules --ir-dir --timings` and nothing else. Either pass a map \
             (`litedoc4 extract --link-index <file>` writes one) or use --extractor-bin, where \
             this command owns the extractor and derives the map itself. {LINK_INDEX_COST}",
        ));
    }
    if max_rounds == 0 {
        return usage("--max-rounds must be at least 1: round 1 is where deletions are folded in");
    }
    if jobs == 0 {
        return usage("--jobs must be at least 1");
    }
    if extractor.is_some() {
        for (flag, given) in [
            ("--extractor-bin", extractor_bin.is_some()),
            ("--lake", lake.is_some()),
        ] {
            if given {
                return usage(format!(
                    "{flag} and --extractor are exclusive: one names the Lean extractor this run \
                     keeps resident, the other names a program to call once per round. How that \
                     program finds its own binary is its own business",
                ));
            }
        }
        if jobs != 1 {
            return usage(
                "--jobs is a flag of the resident path: a resident extractor fixes its job count \
                 at start-up. Behind --extractor, pass it through with `--extractor-arg --jobs \
                 --extractor-arg <n>`",
            );
        }
    }
    let mode = match mode {
        // What makes `self` enough is that the render set is a **union** with the
        // whole-package map delta: a change that reaches another module's page
        // without moving a name is a change ownership already re-extracted the
        // other module for.
        None => Mode::SelfOnly,
        Some(text) => match Mode::parse(&text) {
            Mode::Unrecognised(text) => {
                return usage(format!(
                    "--mode takes self|referrers|importers|all, not `{text}`"
                ));
            }
            parsed => parsed,
        },
    };

    // Canonicalised **before** anything is compared against it: `--out` under a
    // symlinked `--root` is still under `--root`.
    let root = fs::canonicalize(&root).map_err(|source| Failure::Refused {
        code: crate::EXIT_REFUSED,
        message: format!("--root {}: {source}", root.display()),
    })?;
    let out = absolute(&out);
    crate::extract::refuse_inside(
        &root,
        "--root",
        &out,
        "--out",
        " — `litedoc4 extract` refuses an --ir-dir there for the same reason. Copy <out>/site \
         into the repository afterwards if that is where the pages belong",
    )?;

    // Checked here, before the `lake` below: a usage error that arrives after a
    // subprocess has run is one the caller waited for.
    if let Some(flags) = watch {
        flags.check()?;
    }

    let layout = Layout::new(&out);
    let derived = link_index.is_none();
    let link_index = absolute(&link_index.unwrap_or_else(|| layout.link_index.clone()));
    // Before anything is written, and once: `lake env lean --githash` starts a
    // process inside the target, and the digest it feeds has to be the same one
    // on both sides of this run.
    let external_links = crate::resolve_external_links(Some(&root), lake.as_deref());
    // **Before the marker, before the work directory, before Lean**: the two
    // answers this can give — "that root is not a dependency" and "that flag is
    // not a pair" — are both things to say while nothing has been written.
    let deps_docs = crate::deps_docs::parse(&deps_docs_urls, &deps_docs_indexes)?;
    crate::deps_docs::check_roots(&deps_docs, &external_links)?;
    Ok(Request {
        root,
        layout,
        libs,
        external_links,
        deps_docs,
        link_index,
        derived_link_index: derived,
        source_url,
        extractor,
        extractor_args,
        extractor_bin,
        lake,
        jobs,
        mode,
        max_rounds,
        timings,
        full,
    })
}

/// Why `watch` does not resolve a dependency's documentation site, stated once
/// because two flags say it.
///
/// The resolution is one fetch of a 5.7 MB declaration table verified against the
/// IR tree 【実測 2026-08-19,
/// `benchmarks/results/deps-docs-2026-08-19.txt` §3】.
const DEPS_DOCS_IN_WATCH: &str = "it resolves a dependency's declaration table over the network, \
     once, against the IR tree of that run. A loop would either re-fetch 5.7 MB on every rebuild \
     or serve pages resolved against an IR tree that has moved since. Use `litedoc4 build` for a \
     site with documentation links";

fn only_in_build(watching: bool, flag: &str, why: &str) -> Result<(), Failure> {
    if watching {
        return usage(format!("{flag} is not a `watch` flag: {why}"));
    }
    Ok(())
}

/// One `build` invocation, after the command line has been checked.
///
/// **`watch` holds one of these for the whole session and calls [`run`] with it
/// over and over**, so nothing in here is derived per run: the libraries and the
/// source URL are pinned by [`crate::watch`] at start-up, or the loop's trigger
/// and the run it triggers could disagree about what they are looking at.
pub(crate) struct Request {
    pub(crate) root: PathBuf,
    pub(crate) layout: Layout,
    pub(crate) libs: Vec<String>,
    /// Where each **dependency's** source lives, resolved **once** — in
    /// [`build`], from `--root`'s manifest and toolchain — and then used by both
    /// the renderer and `renderKey.externalLinks`. Resolving it twice is how the
    /// two would come to disagree, and a disagreement there re-renders every page
    /// on every run for ever.
    pub(crate) external_links: litedoc4_render::ExternalLinks,
    deps_docs: Vec<crate::deps_docs::Site>,
    /// Absolute.
    pub(crate) link_index: PathBuf,
    /// Whether this run *writes* that file or only reads it.
    derived_link_index: bool,
    pub(crate) source_url: Option<String>,
    extractor: Option<String>,
    extractor_args: Vec<String>,
    extractor_bin: Option<PathBuf>,
    lake: Option<PathBuf>,
    jobs: usize,
    mode: Mode,
    max_rounds: usize,
    timings: Option<PathBuf>,
    full: bool,
}

/// One whole run: the plan, the two paths, the assets, the ledger, the record.
///
/// Returns [`Ran`] because `watch` calls this in a loop and has to say what each
/// pass did, out of [`WorkCounts`]' own numbers — the same values the `work` line
/// and the marker carry — so the two reports cannot drift.
pub(crate) fn run(request: &Request) -> Result<Ran, Failure> {
    let started = Instant::now();
    let layout = &request.layout;
    // The IR read counters are the *process's*, and this command is one run per
    // process — so this changes nothing today and says what `work.irReads` means
    // tomorrow, when something else in the process has read an IR first.
    litedoc4_ir::metrics::reset();

    let libs = if request.libs.is_empty() {
        let declared = crate::lakefile::read_libraries(&request.root)?;
        println!(
            "lib     {} (from {})",
            declared.names.join(", "),
            declared.file.display(),
        );
        declared.names
    } else {
        println!("lib     {} (--lib)", request.libs.join(", "));
        request.libs.clone()
    };

    // One list, written down, and handed to every stage that takes one: its order
    // is the ledger's `modules` array order and the merged `index.json`'s, so two
    // derivations of it are two different files.
    let modules = module_names(&request.root, &libs)?;
    if modules.is_empty() {
        return Err(Failure::Refused {
            code: crate::EXIT_REFUSED,
            message: format!(
                "no modules under {} for {}: an empty list would build an empty site and report \
                 success",
                request.root.display(),
                libs.join(", "),
            ),
        });
    }
    println!("modules {}", modules.len());

    let source_url = match &request.source_url {
        Some(url) => url.clone(),
        None => derive_source_url(&request.root)?,
    };
    check_source_url(&source_url)?;
    println!("source  {source_url}");

    // **Before anything is written**, and that ordering is load-bearing: the
    // question `plan_of` asks is "is `--out` empty, and if not, did this command
    // write it", and creating the work directory first would make every answer
    // "not empty, and yes".
    let plan = plan_of(request, &libs)?;
    match &plan {
        Plan::Full(why) => println!("plan    full generation ({why})"),
        Plan::Incremental => println!("plan    incremental (continuing {})", layout.out.display()),
    }
    write_marker(request, &libs, &source_url, modules.len(), None)?;
    crate::pipeline::create_dir(&layout.work)?;
    let modules_file = layout.work.join("modules.txt");
    write_lines(&modules_file, &modules)?;

    let mut extractor = open_extractor(request, &modules_file, &modules)?;
    let outcome = match plan {
        Plan::Full(_) => full_generation(
            request,
            &modules,
            &modules_file,
            &source_url,
            &mut extractor,
        ),
        Plan::Incremental => {
            incremental_generation(request, modules.clone(), &source_url, &mut extractor)
        }
    };
    // Not a `?` above, exactly as `incremental` does it: the resident environment
    // is released on the failing path too, and doing it here puts the stop
    // *before* the error reaches the caller rather than after.
    extractor.release();
    let done = outcome?;

    // The assets on both paths, every run, whether or not a page was re-rendered.
    // They are **not** in `renderKey` — a page's bytes do not depend on them, so
    // keying on them would re-render 432 pages for a moved CSS rule — and the
    // price of leaving them out is this line: the tree is rewritten from the
    // binary every time rather than trusted to be current. Before the ledger,
    // whose claim is about a *finished* tree.
    litedoc4_render::write_assets(&layout.site)
        .map_err(|source| Failure::Failed(source.to_string()))?;
    println!(
        "assets  {} file(s) -> {}",
        litedoc4_render::ASSETS.len(),
        layout.site.display(),
    );
    // Counted here rather than in the two paths: this is the first point at which
    // the site holds everything a run puts in it, and `pagesInSite` is a
    // denominator quoted elsewhere (432 pages + 7 artifacts + 3 assets = 442 on
    // the measurement target).
    let pages_in_site = count_files(&layout.site);

    // The ledger last: everything that could have failed has now succeeded, so
    // the claim "the IR was built from these oleans and the pages from that IR"
    // is true when it is written and not before.
    let bytes = write_ledger(
        done.detected,
        &layout.ledger,
        &layout.ir,
        &source_url,
        &request.link_index,
        &done.external_links,
    )?;
    println!(
        "ledger  {} module(s) -> {} ({bytes} B)",
        done.ledger_modules,
        layout.ledger.display(),
    );

    // Taken **here**, after the last stage that touches the IR: `write_ledger`'s
    // `extractKey` reads `index.json`, so a snapshot one line earlier would
    // report a number the next run's would not reproduce.
    let work = WorkCounts {
        modules_extracted: done.extracted,
        pages_rendered: done.pages_rendered,
        math_fallbacks: done.math_fallbacks,
        extractor_requests: extractor.requests(),
        cache_hits: done.cache_hits,
        cache_misses: done.cache_misses,
        ir_reads: litedoc4_ir::metrics::snapshot(),
    };
    println!("{}", work.line(modules.len()));
    write_marker(request, &libs, &source_url, modules.len(), Some(&work))?;

    let total = started.elapsed().as_secs_f64();
    println!(
        "build   {} in {total:.4} s -> {}",
        done.what,
        layout.site.display(),
    );
    if let Some(path) = &request.timings {
        let record = serde_json::json!({
            "command": "build",
            "path": done.what,
            "modules": modules.len(),
            "extracted": done.extracted,
            "rounds": done.rounds,
            "work": work.to_json(),
            "pagesRendered": done.pages_rendered,
            "pagesInSite": pages_in_site,
            "ledgerModules": done.ledger_modules,
            "ledgerBytes": bytes,
            "extractSeconds": done.extract_seconds,
            "renderSeconds": done.render_seconds,
            "globalSeconds": done.global_seconds,
            "totalSeconds": total,
        });
        let line = serde_json::to_string(&record).expect("counts and durations serialise") + "\n";
        write_file(path, &line)?;
        println!("{}", line.trim_end());
    }
    Ok(Ran {
        what: done.what,
        modules_extracted: work.modules_extracted,
        pages_rendered: work.pages_rendered,
        extractor_requests: work.extractor_requests,
        seconds: total,
    })
}

/// What one call to [`run`] did, for a caller that makes many of them. The clock
/// is the one field a gate may not assert on — this workload's wall clock moves
/// 5x with the page cache.
pub(crate) struct Ran {
    pub what: &'static str,
    pub modules_extracted: usize,
    pub pages_rendered: usize,
    pub extractor_requests: usize,
    pub seconds: f64,
}

struct Done {
    what: &'static str,
    /// Modules handed to the extractor, summed over the rounds.
    extracted: usize,
    rounds: usize,
    pages_rendered: usize,
    math_fallbacks: usize,
    ledger_modules: usize,
    cache_hits: usize,
    cache_misses: usize,
    extract_seconds: f64,
    render_seconds: f64,
    global_seconds: f64,
    /// The ledger this run licensed, with the hashes read **before** the
    /// extraction.
    detected: Ledger,
    /// **The map the pages were rendered with.**
    ///
    /// It comes out of the path rather than in on [`Request`] because the two
    /// paths resolve it at different moments, both "as soon as there is an IR
    /// tree to read": a full generation has none until it has extracted, and an
    /// incremental round has to know its render key before `detect` compares it
    /// with the ledger's. Carrying it back here is what makes [`write_ledger`]
    /// record the map the pages actually got.
    external_links: litedoc4_render::ExternalLinks,
}

/// **How much work one run did, as integers that do not depend on the machine.**
///
/// This project's product is speed, and a wall clock cannot judge speed here: the
/// oleans are `mmap`ed, so the same unchanged run's environment load moves by 5x
/// with the page cache (2.5 s ↔ 13 s 【実測】). A CI threshold over seconds is
/// either loose enough to pass a regression or tight enough to fail a cold
/// runner, and both are worse than no gate because they look like one. So the
/// gate is over **work**: the same input does the same amount, on every machine,
/// in every cache state. `tools/e2e-micro.sh`'s GATE 5 reads these numbers rather
/// than `grep`ping a log line, which passes silently the day the wording changes.
///
/// **Not one field is counted here** — every one is the stage's own value. Re-
/// deriving any of them for the record would create a second truth, and the
/// failure mode of two truths is that the log stays right while the gate goes
/// quietly wrong (or the reverse, which is worse).
///
/// `irReads` is here because the outer half's limit is not rendering but
/// **reading the whole IR** 【実測 →
/// `benchmarks/results/mathlib-scale-summary.txt`】: `irReads.module / modules`
/// makes that a number every run reports, so a change to it can be argued in the
/// units the claim is stated in instead of in seconds nobody can reproduce.
struct WorkCounts {
    /// Modules handed to the extractor, summed over the rounds.
    modules_extracted: usize,
    pages_rendered: usize,
    /// Math spans written back as their LaTeX source rather than as MathML. In
    /// the record because the fallback leaves a **valid page**: no other number
    /// here moves when a formula fails.
    math_fallbacks: usize,
    /// Extractions asked for: processes on `--extractor`, requests on the
    /// resident path.
    extractor_requests: usize,
    cache_hits: usize,
    cache_misses: usize,
    ir_reads: litedoc4_ir::IrReads,
}

impl WorkCounts {
    fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "modulesExtracted": self.modules_extracted,
            "pagesRendered": self.pages_rendered,
            "mathFallbacks": self.math_fallbacks,
            "extractorRequests": self.extractor_requests,
            "globalCacheHits": self.cache_hits,
            "globalCacheMisses": self.cache_misses,
            // Split by kind, because only the module files divide into a number
            // of full passes: `index.json` and the dependency slices are read a
            // fixed number of times per run whatever the package's size.
            "irReads": {
                "index": self.ir_reads.index,
                "module": self.ir_reads.module,
                "depMap": self.ir_reads.dep_map,
                "total": self.ir_reads.total(),
            },
        })
    }

    /// The same numbers on stdout, so that the log and the marker cannot drift.
    ///
    /// `irPasses` is `irReads.module / modules`, printed rather than stored: it
    /// is a quotient of two values the record already holds, and a float in the
    /// marker would be a third spelling of a number that is already there twice.
    fn line(&self, modules: usize) -> String {
        let passes = match self.ir_reads.full_passes(modules) {
            Some(passes) => format!("{passes:.2}"),
            None => "n/a".to_owned(),
        };
        format!(
            "work    extract {} / render {} / math-fallback {} / requests {} / \
             cache {} hit {} miss / \
             ir {} file(s) ({} module read(s) = {passes} full pass(es))",
            self.modules_extracted,
            self.pages_rendered,
            self.math_fallbacks,
            self.extractor_requests,
            self.cache_hits,
            self.cache_misses,
            self.ir_reads.total(),
            self.ir_reads.module,
        )
    }
}

/// The first run: hash, extract everything, render everything.
///
/// The extraction is one request for the whole package, and the site is
/// [`crate::stages::generate_site`], which is `litedoc4 site`'s own body — so the
/// tree this writes is the tree that command writes.
fn full_generation(
    request: &Request,
    modules: &[String],
    modules_file: &Path,
    source_url: &str,
    extractor: &mut Extractor,
) -> Result<Done, Failure> {
    let layout = &request.layout;
    // The hashes, **before** the extraction they license. Written into `--work`
    // as a diagnostic; the file that counts is written at the end of the run.
    let detected = build_ledger(&BuildOptions {
        modules,
        target: &request.root.to_string_lossy(),
        out: &layout.work.join("ledger-detect.json"),
        // No IR and, on a first run, no map yet: both keys are filled in from the
        // tree this run is about to write, by [`write_ledger`].
        ir: None,
        source_url,
        link_index: Some(&request.link_index),
        // The map this run renders with, so the ledger's claim and the pages
        // agree by construction. A bumped dependency moves a `rev`, which moves
        // the href of every link into it, and this is the key that makes the next
        // run notice.
        external_links: Some(&request.external_links.digest()),
        algorithm: &Algorithm::sha256(),
        // The ledger's bytes do not depend on this; its speed does.
        concurrency: crate::pipeline::hash_concurrency(),
        timings: Some(&layout.work.join("ledger-timings.json")),
    })
    .map_err(refused)?
    .ledger;
    println!("detect  {} module(s) hashed", detected.modules.len());

    // The page tree is removed rather than written over: the renderer only ever
    // writes, so a module that vanished since the tree was made would keep its
    // page and the site would hold a file no from-scratch run produces. The
    // marker is what says this command made it.
    if layout.site.exists() {
        fs::remove_dir_all(&layout.site).map_err(|source| Failure::io(&layout.site, &source))?;
    }
    // Same for the IR: a partial tree from an interrupted run would be merged
    // with, not replaced by, this extraction.
    if layout.ir.exists() {
        fs::remove_dir_all(&layout.ir).map_err(|source| Failure::io(&layout.ir, &source))?;
    }

    let at = Instant::now();
    extractor.run(
        modules_file,
        &layout.ir,
        &layout.work.join("extract-timings-1.json"),
    )?;
    let extract_seconds = at.elapsed().as_secs_f64();
    // The 3 GB environment is not held across the render: the loop is the only
    // thing that extracts, which on this path is one request.
    extractor.release();
    println!(
        "extract {} module(s) in {extract_seconds:.4} s",
        modules.len()
    );

    // **The documentation map, now that there is an IR to ask about.** Not before
    // the extraction: on this path the tree does not exist yet, and the set of
    // dependency names to verify is exactly what it holds. Nothing has compared a
    // render key on this path — `write_ledger` recomputes the one that reaches
    // the file — so resolving here costs no consistency.
    let external_links = resolve_docs(request, &layout.ir)?;

    let config = crate::site_config(Some(&request.root))?;
    let site = crate::stages::generate_site(
        &layout.ir,
        &layout.site,
        source_url,
        &external_links,
        Some(&request.link_index),
        Some(&layout.state),
        &config,
    )?;
    Ok(Done {
        what: "full",
        extracted: modules.len(),
        rounds: 1,
        pages_rendered: site.rendered.pages_written,
        math_fallbacks: site.rendered.math_failures,
        ledger_modules: detected.modules.len(),
        cache_hits: site.derived.cache_hits,
        cache_misses: site.derived.cache_misses,
        extract_seconds,
        render_seconds: site.render_seconds,
        global_seconds: site.global_seconds,
        detected,
        external_links,
    })
}

/// Every later run: the six-stage pipeline, over the tree the last one left.
fn incremental_generation(
    request: &Request,
    modules: Vec<String>,
    source_url: &str,
    extractor: &mut Extractor,
) -> Result<Done, Failure> {
    let layout = &request.layout;
    // **Before the round, from the tree the round starts on.** `detect` is about
    // to compare this map's digest with the ledger's, and the render uses the
    // same value, so it has to be resolved once and here. The cost is that a
    // dependency name a module starts referring to *during* this round is
    // verified on the next run rather than this one — at which point the map
    // moves, the render key moves, and every page is re-rendered with it.
    let external_links = resolve_docs(request, &layout.ir)?;
    let config = crate::site_config(Some(&request.root))?;
    let run = crate::pipeline::run_incremental(
        &Incremental {
            config: &config,
            ir: &layout.ir,
            pages: &layout.site,
            ledger: &layout.ledger,
            work: &layout.work,
            modules,
            source_url,
            link_index: &request.link_index,
            external_links: &external_links,
            state: &layout.state,
            mode: request.mode.clone(),
            max_rounds: request.max_rounds,
        },
        extractor,
    )?;
    Ok(Done {
        what: "incremental",
        extracted: run.summary.changed + run.summary.stale_found,
        rounds: run.summary.rounds,
        pages_rendered: run.summary.pages_rendered,
        math_fallbacks: run.summary.math_fallbacks,
        ledger_modules: run.detected.modules.len(),
        cache_hits: run.summary.cache_hits,
        cache_misses: run.summary.cache_misses,
        extract_seconds: run.timings.extract,
        render_seconds: run.timings.render,
        global_seconds: run.timings.global,
        detected: run.detected,
        external_links,
    })
}

/// `--root`'s source map with every configured documentation site verified
/// against `ir` and attached.
///
/// **One function, two call sites, and they are the same rule**: resolve as soon
/// as there is an IR tree whose render key this run is about to record. Without
/// `--deps-docs-url` it is the identity — no fetch, no artifact, no line.
fn resolve_docs(request: &Request, ir: &Path) -> Result<litedoc4_render::ExternalLinks, Failure> {
    let resolved =
        crate::deps_docs::resolve(&request.deps_docs, ir, Some(&request.layout.deps_docs_map))?;
    Ok(crate::deps_docs::attach(&request.external_links, resolved))
}

/// Full or incremental, and the reason, which is printed.
///
/// The refusal in the middle is the important one: this command removes and
/// overwrites things under `--out`, so it does that only to a directory whose
/// marker says it made it.
fn plan_of(request: &Request, libs: &[String]) -> Result<Plan, Failure> {
    let layout = &request.layout;
    if !layout.out.exists() || is_empty_dir(&layout.out) {
        return Ok(Plan::Full("nothing there yet"));
    }
    // **`--full` is answered after the ownership checks, not before them.** A
    // full generation *deletes* `<out>/site` and `<out>/ir`, so a `--full` that
    // short-circuited this would be the one way to make this command remove a
    // directory whose marker it never looked at.
    let Some(marker) = read_marker(&layout.marker)? else {
        return Err(Failure::Refused {
            code: crate::EXIT_REFUSED,
            message: format!(
                "{} is not empty and has no {MARKER}: this command deletes and overwrites inside \
                 --out, so it will only do that to a directory it can see it wrote. Name an empty \
                 directory, or remove this one yourself",
                layout.out.display(),
            ),
        });
    };
    let was = marker
        .get("root")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    if was != request.root.to_string_lossy() {
        return Err(Failure::Refused {
            code: crate::EXIT_REFUSED,
            message: format!(
                "{} was built from {was}, not from {}: the ledger under it stores the target whose \
                 oleans it hashed, and continuing here would compare one package's build tree with \
                 another package's hashes. Use a different --out",
                layout.out.display(),
                request.root.display(),
            ),
        });
    }
    if request.full {
        return Ok(Plan::Full("--full"));
    }
    let layout_version = marker.get("layout").and_then(serde_json::Value::as_u64);
    if layout_version != Some(LAYOUT) {
        return Ok(Plan::Full("the layout under --out is from another version"));
    }
    let declared: Vec<&str> = marker
        .get("libs")
        .and_then(serde_json::Value::as_array)
        .map(|libs| {
            libs.iter()
                .filter_map(serde_json::Value::as_str)
                .collect::<Vec<&str>>()
        })
        .unwrap_or_default();
    if declared != libs.iter().map(String::as_str).collect::<Vec<&str>>() {
        // Not a refusal: a package that gained a library has more modules, and
        // a full run is the correct answer to "the question changed".
        return Ok(Plan::Full("the libraries changed"));
    }
    if marker.get("complete") != Some(&serde_json::Value::Bool(true)) {
        return Ok(Plan::Full("the previous run did not finish"));
    }
    if !layout.carries_a_previous_run(&request.link_index) {
        return Ok(Plan::Full("the previous run's files are not all there"));
    }
    // **The IR under `--out` has to be one this binary can read.** A CI cache
    // restores the *previous* binary's state, so a schema bump arrives here as a
    // tree every reader below refuses 【実測 2026-08-23】. `detect` is not this
    // guard and cannot be: it answers "re-extract every module" correctly, and
    // the round then reads the **base** IR — the tree the re-extraction is about
    // to replace — to answer ownership, and dies there with the site left as it
    // was.
    //
    // Only the index is read, which is a **lower bound and not a proof**: `merge`
    // writes the weakest schema under the tree into the index, so a tree *this*
    // version merged cannot overstate, but a tree an older binary merged can,
    // because it copied its own older modules in and kept the newer index number
    // it found. That tree still fails on the first module the round reads. What
    // the guard buys is the case that reaches CI: a whole tree from one older
    // binary, which a cache restores as a unit.
    if !ir_is_readable(&layout.ir) {
        return Ok(Plan::Full(
            "the IR under --out is not one this version reads",
        ));
    }
    Ok(Plan::Incremental)
}

/// Whether the IR tree under `--out` is one this binary reads.
///
/// A tree it cannot open at all counts as unreadable too: the question is "can
/// this run continue from what is there", and an index that will not parse
/// answers it the same way an old one does.
fn ir_is_readable(ir: &Path) -> bool {
    litedoc4_ir::IrTree::open_unvalidated(ir)
        .is_ok_and(|tree| tree.index().schema_version >= litedoc4_ir::MIN_SCHEMA_VERSION)
}

/// The extractor, in the same two shapes [`crate::pipeline`] offers.
///
/// **The resident one is the default**, and `--extractor` is the seam: the
/// product's own extraction is a Lean environment this run owns, and a caller who
/// wants something else — a wrapper, a recording, a fake in a test that has no
/// Lean at all — names a program instead. Neither has a default *path*:
/// `--extractor-bin` falls back to `$EXTRACT_BIN` and then to a refusal, because
/// the binary is 171 MB and built against the target's own toolchain.
fn open_extractor(
    request: &Request,
    modules_file: &Path,
    modules: &[String],
) -> Result<Extractor, Failure> {
    if let Some(program) = &request.extractor {
        return Ok(Extractor::OneShot {
            program: program.clone(),
            args: request.extractor_args.clone(),
            requests: 0,
        });
    }
    Ok(Extractor::Resident(Box::new(Resident::new(
        crate::pipeline::serve_options(crate::pipeline::ServeRequest {
            bin: request.extractor_bin.clone(),
            target: Some(request.root.clone()),
            lake: request.lake.clone(),
            jobs: request.jobs,
            modules_file,
            modules,
            work: &request.layout.work,
            // The resident extractor writes the map when this command owns it.
            // With `--link-index` it is somebody else's file and is not
            // overwritten.
            link_index: request
                .derived_link_index
                .then_some(request.link_index.as_path()),
        })?,
    )?)))
}

/// `https://github.com/<owner>/<repo>/blob/<40-hex>`, from the checkout itself.
///
/// **Only `github.com` remotes are read.** The `/blob/<rev>/<path>` shape is
/// GitHub's; GitLab spells the same thing `/-/blob/`, Gitea and sr.ht differ
/// again. Guessing a host's URL scheme produces links that are *plausible* and
/// 404, on every declaration of every page, so anything else is refused by name
/// with `--source-url` as the answer.
///
/// The revision is `HEAD`, and an uncommitted working tree is reported rather
/// than refused: the pages will link to the last commit, which is a fact worth
/// one line of output and is not this command's to fix.
pub(crate) fn derive_source_url(root: &Path) -> Result<String, Failure> {
    let rev = git(root, &["rev-parse", "HEAD"])?;
    let remote = git(root, &["config", "--get", "remote.origin.url"])?;
    let Some(path) = github_path(&remote) else {
        return Err(Failure::Refused {
            code: crate::EXIT_REFUSED,
            message: format!(
                "cannot derive --source-url from `{remote}`: only github.com remotes have a \
                 /blob/<rev>/<path> shape this can be sure of, and a guessed one 404s on every \
                 declaration of every page. Pass --source-url \
                 https://<host>/<owner>/<repo>/blob/{rev}",
            ),
        });
    };
    if let Ok(dirty) = git(root, &["status", "--porcelain"]) {
        let count = dirty.lines().filter(|line| !line.trim().is_empty()).count();
        if count > 0 {
            println!(
                "source  note: {count} uncommitted change(s) in {} — the pages will link to HEAD",
                root.display(),
            );
        }
    }
    Ok(format!("https://github.com/{path}/blob/{rev}"))
}

/// `<owner>/<repo>` when the remote is a github.com one, in any of the spellings
/// git writes.
fn github_path(remote: &str) -> Option<String> {
    let remote = remote.trim();
    let rest = [
        "https://github.com/",
        "http://github.com/",
        "git@github.com:",
        "ssh://git@github.com/",
    ]
    .iter()
    .find_map(|prefix| remote.strip_prefix(prefix))?;
    let rest = rest.trim_end_matches('/');
    let rest = rest.strip_suffix(".git").unwrap_or(rest);
    let (owner, repo) = rest.split_once('/')?;
    if owner.is_empty() || repo.is_empty() || repo.contains('/') {
        return None;
    }
    Some(format!("{owner}/{repo}"))
}

fn git(root: &Path, args: &[&str]) -> Result<String, Failure> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .map_err(|source| Failure::Refused {
            code: crate::EXIT_REFUSED,
            message: format!("git {}: {source}", args.join(" ")),
        })?;
    if !output.status.success() {
        return Err(Failure::Refused {
            code: crate::EXIT_REFUSED,
            message: format!(
                "git {} in {} failed: {}. --source-url is a git question — pass it explicitly if \
                 the package is not a checkout",
                args.join(" "),
                root.display(),
                String::from_utf8_lossy(&output.stderr).trim(),
            ),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// The ledger, with the keys taken from the tree that now exists.
///
/// See the module heading: the module hashes are `detect`'s, taken before the
/// extraction, while the two keys are recomputed here because they describe the
/// IR on disk. Returns the file's size, which is the only number a caller can
/// check the write by.
fn write_ledger(
    mut ledger: Ledger,
    path: &Path,
    ir: &Path,
    source_url: &str,
    link_index: &Path,
    external_links: &litedoc4_render::ExternalLinks,
) -> Result<usize, Failure> {
    ledger.extract_key = extract_key(&ledger.target, Some(ir)).map_err(refused)?;
    // **The map as it is now, not as `detect` saw it**, for exactly the reason
    // `extractKey` is recomputed here: both keys describe *the tree on disk*.
    // Writing back the pre-run digest would leave a ledger claiming the pages
    // were rendered against a map that no longer exists, and the next run would
    // compare the new map with the old digest and re-render everything, for ever.
    ledger.render_key = Some(render_key(
        source_url,
        link_index_digest(Some(link_index))
            .map_err(refused)?
            .as_deref(),
        // Not re-resolved after the run, unlike the two above: the dependency
        // link map comes from the manifest and the toolchain, and this command
        // writes into neither — so the value it rendered with is still the value
        // that describes the tree on disk.
        Some(&external_links.digest()),
    ));
    let body = ledger.to_json();
    write_file(path, &body)?;
    Ok(body.len())
}

/// The marker, written twice per run — `complete: false` on the way in and
/// `complete: true` after the ledger — and the file [`plan_of`] reads to decide
/// whether this directory is one this command may overwrite.
///
/// A fixed set of keys in a fixed order, with **no timestamp**: two runs of this
/// command over an unchanged package have to be able to produce identical trees.
///
/// **`work: None` *is* `complete: false`**, and it writes `"work": null` rather
/// than a record of zeros. A half-finished run has done some amount of work and
/// this file does not know how much — and zeros would be **the exact shape a
/// successful second run has**, so a gate reading a marker left by a crashed
/// first run would see "re-extracted nothing, rendered nothing" and pass. `null`
/// makes that read fail instead.
fn write_marker(
    request: &Request,
    libs: &[String],
    source_url: &str,
    modules: usize,
    work: Option<&WorkCounts>,
) -> Result<(), Failure> {
    let record = serde_json::json!({
        "tool": "litedoc4 build",
        "layout": LAYOUT,
        "root": request.root.to_string_lossy(),
        "libs": libs,
        "sourceUrl": source_url,
        "modules": modules,
        "complete": work.is_some(),
        "work": work.map(WorkCounts::to_json),
    });
    let body = serde_json::to_string(&record).expect("paths and counts serialise") + "\n";
    write_file(&request.layout.marker, &body)
}

/// The marker as JSON, or `None` when there is none.
///
/// A marker that will not parse is **not** treated as absent: it was written by
/// something, and deleting a site on the strength of a file this cannot read is
/// the failure the marker exists to prevent.
fn read_marker(path: &Path) -> Result<Option<serde_json::Value>, Failure> {
    let Ok(text) = fs::read_to_string(path) else {
        return Ok(None);
    };
    let record: serde_json::Value =
        serde_json::from_str(&text).map_err(|source| Failure::Refused {
            code: crate::EXIT_REFUSED,
            message: format!(
                "{}: {source}. This file says which directory `litedoc4 build` owns; one that will \
                 not parse is not one to overwrite a site on the strength of",
                path.display(),
            ),
        })?;
    Ok(Some(record))
}

fn is_empty_dir(path: &Path) -> bool {
    fs::read_dir(path).is_ok_and(|mut entries| entries.next().is_none())
}

/// Every file under `root`, recursively. The site's file count is a denominator
/// this project quotes, so the run reports its own.
fn count_files(root: &Path) -> usize {
    let mut total = 0;
    let mut stack = vec![root.to_owned()];
    while let Some(dir) = stack.pop() {
        let Ok(listing) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in listing.flatten() {
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => stack.push(entry.path()),
                Ok(_) => total += 1,
                Err(_) => {}
            }
        }
    }
    total
}
