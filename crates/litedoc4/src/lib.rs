//! The `litedoc4` command line tool.
//!
//! **The product's command is [`build`]**: a package in, a site out, in one
//! command — it reads the lakefile for the libraries, globs the sources for the
//! modules, derives `--source-url` from git, chooses between full generation and
//! the incremental pipeline, and writes the ledger back. Everything else here is
//! a **stage of it**, kept on the surface because the gates are stated against
//! them one at a time.
//!
//! Three flags are deliberately awkward:
//!
//! - **`--only` and `--only-from` are the same option in two spellings, and
//!   `--only-from` an empty file renders nothing** — a regeneration set is
//!   usually empty, so "no flags means every module" would put that hole on the
//!   common path.
//! - **One of `--link-index` and `--no-link-index` is required**: leaving the
//!   dependency map out costs 150 of 432 pages their correct bytes, silently.
//! - **`--root` on a stage command is the package, not the output.** It is what
//!   the dependency link map is resolved from, optional because a stage command
//!   may be pointed at an IR tree with no package next to it, and leaving it out
//!   is a *different site* — every link into a dependency stays a relative link
//!   to a page nothing writes. So the run says which of the two it did on its own
//!   line, rather than letting the answer be read off the pages. [`build`] has a
//!   package by construction and never asks.
//!
//! **It is a library with a binary on top, and that is what makes the parsers
//! testable**: an integration test of a `bin` target can only start a process.

use std::path::PathBuf;

use litedoc4_global::GlobalSummary;
use litedoc4_render::RenderSummary;

pub mod build;
pub(crate) mod cli;
pub mod deps_docs;
pub mod extract;
pub mod httpd;
pub mod lakefile;
pub mod ledger;
pub mod packages;
pub mod pipeline;
pub mod queries;
pub mod resident;
pub mod stages;
pub mod watch;

pub const USAGE: &str = "\
usage: litedoc4 build  --root <repo> --out <dir> [--link-index <file>]
                       [--lib <Name>]... [--source-url <url>] [--full]
                       [--deps-docs-url <Root>=<url>]...
                       [--deps-docs-index <Root>=<url|path>]...
                       (--extractor-bin <path> [--lake <path>] [--jobs <n>]
                        | --extractor <program> [--extractor-arg <arg>]...)
                       [--mode self|referrers|importers|all] [--max-rounds <n>]
                       [--timings <file>]
       litedoc4 incremental --ir <dir> --pages <dir> --ledger <file> --work <dir>
                       --modules <file> --source-url <url> --link-index <file>
                       --state <dir> [--make-link-index] [--root <repo>]
                       [--deps-docs-map <file>]
                       (--extractor <program> [--extractor-arg <arg>]...
                        | --serve --extractor-bin <path> --target <repo>
                          [--lake <path>] [--jobs <n>])
                       [--mode self|referrers|importers|all] [--max-rounds <n>]
                       [--timings <file>]
       litedoc4 watch  --root <repo> --out <dir> [--port <n>] [--interval <ms>]
                       [--lib <Name>]... [--source-url <url>]
                       (--extractor-bin <path> [--lake <path>] [--jobs <n>]
                        | --extractor <program> [--extractor-arg <arg>]...)
                       [--mode self|referrers|importers|all] [--max-rounds <n>]
       litedoc4 modules --root <repo> [--lib <Name>]... [--out <file>]
       litedoc4 extract --modules <file> --ir-dir <dir> --timings <file>
                       [--extractor-bin <path>] [--target <repo>] [--lake <path>]
                       [--events <file>] [--jobs <n>]
                       [--link-index <file> [--link-index-omit <file>]
                        [--link-index-key <token>]]
       litedoc4 site   --ir <dir> --out <dir> --source-url <url>
                       (--link-index <file> | --no-link-index)
                       [--root <repo>] [--lake <path>] [--deps-docs-map <file>]
                       [--state <dir>] [--timings <file>]
       litedoc4 render --ir <dir> --pages <dir> --source-url <url>
                       (--link-index <file> | --no-link-index)
                       [--root <repo>] [--lake <path>] [--deps-docs-map <file>]
                       [--only <Module>]... [--only-from <file>]
       litedoc4 global --ir <dir> --out <dir> [--state <dir>] [--root <repo>]
                       [--before <map.json>] [--print-set <file>]
                       [--delta-json <file>] [--timings <file>]
       litedoc4 ledger build --modules <file> --target <repo> --out <ledger.json>
                       [--algorithm sha256|lake] [--concurrency <n>]
                       [--ir <dir>] [--source-url <url>] [--link-index <file>]
                       [--root <repo>] [--lake <path>] [--deps-docs-map <file>]
                       [--timings <file>]
       litedoc4 ledger check --ledger <ledger.json> [--modules <file>]
                       [--algorithm sha256|lake] [--concurrency <n>] [--ir <dir>]
                       [--source-url <url>] [--link-index <file>]
                       [--root <repo>] [--lake <path>] [--deps-docs-map <file>]
                       [--changed-out <file>]
                       [--removed-out <file>] [--render-all-out <file>]
                       [--timings <file>]
       litedoc4 ledger touch --ledger <ledger.json> --module <Module> [--out <file>]
       litedoc4 ownership --base <ir> [--inc <ir>] [--removed <file>]
                       [--exclude <file>] [--print-set <file>] [--json <file>]
       litedoc4 merge --base <ir> [--inc <ir>] [--out <ir>] [--remove <file>]
                       [--modules <file>] [--changed-out <file>] [--timings <file>]
       litedoc4 merge --verify <ir> --against <ir>
       litedoc4 impact --ir <dir> [--changed <Module>]... [--changed-file <file>]
                       [--mode self|referrers|importers|all] [--census <file>]
                       [--print-set <file>] [--json <file>]
       litedoc4 prune --pages <dir> [--remove <file>] [--ir <dir>] [--dry-run]
                       [--json <file>]
       litedoc4 links  --root <repo> [--lake <path>] [--link-index <file>]
                       [--deps-docs-map <file>] [--out <file>]

  --root         (`build`, `modules`) the Lean package: the sources are globbed
                 under it, its oleans are hashed, `lake env` runs inside it, and
                 for `build` its git HEAD is where --source-url comes from.
                 (`site`, `render`, `global`, `incremental`, `ledger`)
                 optional, and for two things. One is the dependency link map:
                 with it, every link into a dependency is that package's
                 version-pinned GitHub blob URL, read out of its
                 lake-manifest.json plus `lean --githash`; without it
                 those links stay relative to pages this site does not write.
                 The other is <root>/litedoc4.toml, which sets the site's title
                 and the Markdown on its index page — the same file for every
                 command, so the four that write HTML cannot disagree about
                 what the package is called. It is **not** --target: that names the
                 tree whose oleans are hashed. A ledger and the run it licenses
                 have to agree about this flag, or the render key moves and
                 every page is re-rendered. `build` has one by construction, so
                 its sites always carry the links.
  --out          (`build`) the directory this command owns: <out>/site is the
                 site, <out>/{ir,state,work} the caches, <out>/ledger.json the
                 ledger. Required, with no default — <root>/.lake/build/doc is
                 doc-gen4's own output tree — and it may not be inside --root
  --port         (`watch`) the port the site is served on (default 8484). A
                 port that is taken is refused by name, never moved to the next
                 free one: an address that changes between runs leaves the tab
                 you already have open pointing at nothing.
  --interval     (`watch`) how often the loop asks the ledger, in milliseconds
                 (default 1000, minimum 100). `watch` **does not run `lake
                 build`** — run that in another window and it notices the oleans
                 it writes. It acts only after one quiet interval, so a build
                 still writing oleans is never extracted mid-flight, and it says
                 so while it waits.
  --full         (`build`) regenerate everything, ignoring what is under --out.
                 The escape hatch for an input no ledger key covers. The
                 dependency map is not one: its bytes are in renderKey, so a
                 map that moved re-renders on its own.
  --ir           an IR tree written by the extractor (schema 5)
  --ir-dir       (`extract`) where the extractor writes that tree. Required,
                 with no default
  --pages        where the pages go; directories are created
  --source-url   https://host/owner/repo/blob/<40-hex-rev>. `incremental`
                 checks the 40 hex digits; `render` and `site` do not.
  --link-index   the dependency closure's name -> module map (.lidx). Its
                 SHA-256 is part of renderKey: a map that moved re-renders every
                 page (150 of the target's 432 change bytes).
                 For `build` it is optional — left out, the map is this
                 command's own <out>/link-index.lidx, written by the extractor
                 from the environment it imported anyway. Given, it is an
                 input and is never written to. For `extract` it asks the
                 extractor to write one.
  --deps-docs-url  (`build`) <Root>=<url>: link that dependency's declarations
                 at the documentation site it already publishes, e.g.
                 Mathlib=https://leanprover-community.github.io/mathlib4_docs.
                 Repeatable, off by default, and **verified**: a name that site's
                 declaration table holds gets the docs page, one it does not
                 keeps the version-pinned source, and a table that will not read
                 sends the whole root to the source. There is no fallback on a
                 404 — a build cannot see one. A <Root> that is not a dependency
                 of --root is exit 3.
  --deps-docs-index  (`build`) <Root>=<url|path>: where that site's declaration
                 table is. Default <url>/declarations/declaration-data.bmp. A
                 local path is read as a file, which is how a run with no
                 outbound network uses this.
  --deps-docs-map  (`site`, `render`, `incremental`, `ledger`, `links`) the
                 resolved map `build` wrote under <out>/work. It carries the base
                 URL and the verified names, so the commands that render cannot
                 disagree about the links (the reason there is no --title).
                 Nothing here reads a table or the network.
                 It is an input to renderKey, so `ledger build` and `ledger
                 check` need it for the same reason --root and --link-index are
                 theirs: without it they compute a different key from the one the
                 run that wrote the pages recorded, and then report a changed or
                 unchanged key for a reason that is not true.
  --link-index-omit  (`extract`, with --link-index) the modules whose own
                 declaration groups are left out of that map, one name per
                 line — normally the package's own module list. The renderer
                 answers those names out of the IR before it reads the map, so
                 the site is byte-identical; what changes is that the map stops
                 moving when the package is edited, and with it renderKey.
                 Module names still appear in the map's `@` section.
                 `incremental --serve` passes its own --modules here.
  --link-index-key  (`extract`, with --link-index) an opaque token standing for
                 everything about that map the extractor cannot see: the oleans
                 behind the imported modules, and the omit list's bytes. With
                 it, a map whose sidecar <file>.key holds the same token and
                 whose `@` section still matches the environment is left
                 untouched — no scan, no write (1.20-1.81 s of a 6.2 s one-module
                 incremental build on the measurement target). Anything less than
                 a full match rewrites both. `build` and `incremental --serve`
                 compute their own; here it is passed through verbatim.
  --make-link-index  (`incremental --serve`) the resident extractor writes
                 --link-index instead of reading it
  --work         (`incremental`) the round's scratch directory. Everything in
                 it is a diagnostic: the pipeline writes it and reads none of
                 it back.
  --extractor    (`incremental`) the extraction program, called as
                 `<program> [<extractor-arg>...] --modules <list>
                 --ir-dir <dir> --timings <file>`. No default, and the seam is
                 what lets the pipeline be tested without Lean. Exclusive with
                 --serve.
  --extractor-arg  one argument for it, before those three; repeatable
  --serve        (`incremental`) one resident Lean environment for the whole
                 run instead of one process per round: imported at the first
                 round that extracts, released on the way out of the loop.
                 There is no --serve-dir — a server this run did not start is
                 one whose olean generation it cannot vouch for.
  --max-rounds   how many extract/ownership/merge rounds may run (default 5).
                 Reaching it with modules still stale is exit 5.
  --root         (`modules`) the repository the sources are globbed under
  --lib          (`build`, `modules`) a library root: <Name>.lean and <Name>/;
                 repeatable. Left out, the names come from <root>/lakefile.toml's
                 [[lean_lib]] blocks; a lakefile.lean is refused by name, because
                 reading it honestly means elaborating it with Lake
  --extractor-bin  (`extract`, `incremental --serve`) the Lean extractor built
                 by extractor/build.sh, or $EXTRACT_BIN. No default: it is built
                 against the target's toolchain, so a baked-in path would be
                 right on one machine
  --target       (`extract`, `incremental --serve`) the Lean package to run
                 inside, or $TARGET_REPO. It is opened read-only: an --ir-dir
                 under it is refused, and its oleans are the generation every
                 resident request is checked against
  --lake         (`extract`, `incremental --serve`) the lake executable, or
                 $LAKE (default: `lake`). Also (`build`, `site`, `render`,
                 `ledger`) where the `lean` that answers `--githash` is looked
                 for: its **sibling**, so `--lake ~/.elan/bin/lake` means
                 `~/.elan/bin/lean`. That revision is Lean core's, the one
                 dependency the manifest does not pin
  --events       (`extract`) the extractor's phase events JSONL. Defaults to
                 <timings without .json>-events.jsonl, which is what
                 `incremental` relies on: it passes only --timings
  --jobs         (`extract`, `incremental --serve`) extractor threads
                 (default 1). It is the resident server's start-up
                 configuration, so there is no per-request job count
  --only         render only this module; repeatable
  --only-from    render only the modules named in this file, one per line.
                 An empty file renders nothing.
  --out          the site root the six whole-package artifacts go under — for
                 `site` the module pages go under it too — or the ledger file
                 `ledger build` writes
  --state        directory holding the contentHash cache (global-state.json).
                 Without it every module is read: the from-scratch build.
  --before       a previous declarations/name-map.json. Turns the delta on.
  --print-set    the modules to re-render, one per line. An affected set that
                 came out empty is an empty file, not a blank line.
  --delta-json   the delta's diagnostic summary
  --timings      one JSON line of counts and durations
  --modules      the module list, one name per line; # comments are skipped.
                 `ledger check` without it re-reads the ledger's own list and
                 cannot see a module that appeared or vanished since `build`.
                 For `merge` it is the order the merged index.json's modules
                 come out in — a from-scratch extraction's, which is the order
                 the extractor was handed the list in. A list that names other
                 modules than the merged tree holds is exit 3, not a guess.
  --target       the repository whose .lake/build/lib/lean holds the oleans.
                 **Not** where the dependency link map comes from — that is
                 --root, even for `ledger`, where on a real package the two name
                 the same directory but on a hashed tree with no package behind
                 it only one of them exists
  --ledger       a ledger.json written by `ledger build`. `incremental` reads
                 it and never rewrites it; `build` writes it back, after the
                 last step that could fail.
  --algorithm  sha256 hashes the olean bytes; lake reads the <file>.hash Lake
                 already wrote. Defaults to sha256, and for `check` to the
                 ledger's own.
  --concurrency  olean reads in flight (default 1). The ledger's bytes do not
                 depend on it.
  --changed-out  the modules to re-extract, one per line
  --removed-out  the modules that no longer have an olean, one per line
  --render-all-out  why every page has to be re-rendered, one reason per line.
                 Empty means the render set follows from the IR diff as usual.
  --module       the module `ledger touch` invalidates
  --base         the IR as it was before this round
  --inc          the partial extraction's IR tree. Absent is a real case: a pure
                 deletion re-extracts nothing.
  --removed      modules that no longer exist, one per line (`ownership`)
  --remove       the same list, spelled as the prototype spells it for `merge`
  --exclude      modules already scheduled for re-extraction, one per line.
                 They are fresh by definition and are never reported.
  --verify       compare two IR trees; --against names the second
  --changed      a module that changed; repeatable (`impact`)
  --changed-file the same list in a file, one name per line
  --mode         which modules the change reaches: self, referrers (direct),
                 importers (the sound transitive bound, the default), or all —
                 which is valid with an empty changed set and is what a moved
                 render key selects
  --census       a per-module TSV of |IMPORTERS| / |REFERRERS| / declarations
  --pages        (`prune`) the page tree; nothing outside it is ever deleted
  --dry-run      report what would be deleted and delete nothing
";

/// What `litedoc4` with no arguments prints. [`USAGE`] is behind `--help-all`
/// and behind every subcommand's own `--help`, because a reader who has already
/// typed `site` is past the front door.
///
/// Two commands rather than fourteen: the other twelve are invoked by
/// `tools/*-gate.sh` and by `build` itself, and by nothing a consumer runs —
/// `action.yml` and `lakefile.lean`'s `docs` script call `build` and nothing
/// else (measured 2026-08-29). Listing all fourteen as equals said the opposite.
pub const SUMMARY: &str = "\
usage: litedoc4 build  --root <repo> --out <dir> --extractor-bin <path>
                       [--lib <Name>]... [--jobs <n>] [--source-url <url>]
                       [--full]
       litedoc4 watch  --root <repo> --out <dir> --extractor-bin <path>
                       [--lib <Name>]... [--jobs <n>] [--port <n>]

  `build` writes the site once. `watch` rebuilds it whenever the package's
  oleans change and serves it, without ever running `lake build` itself.

  Twelve more subcommands exist — extract, modules, links, incremental, site,
  render, global, ledger, ownership, merge, impact, prune. They are the stages
  `build` runs and the queries the gates ask of them, not a second way to use
  this tool, and each answers its own --help.

  litedoc4 --help-all    every command line and every flag
  litedoc4 --version
";

/// `Debug` so that a `Result<_, Failure>` can be `expect`ed in a test; nothing
/// prints one to a user, which is what the three arms of `main` are for.
#[derive(Debug)]
pub enum Failure {
    /// The command line is wrong. Exit 2.
    Usage(String),
    Failed(String),
    /// The command ran to completion and answered "no" — `merge --verify` with
    /// differences, **exit 1**. The answer is already on stdout, so nothing goes
    /// to stderr: a caller that prints this as an error message would be
    /// reporting a working comparison as a broken one.
    Answered(u8),
    /// The run stopped because the world and the files disagree — a ledger too
    /// old, a module with no olean. **Exit 3**: a pipeline that treats "the
    /// ledger is stale" the same as "the disk is full" retries the wrong thing.
    Refused {
        code: u8,
        message: String,
    },
}

impl Failure {
    /// An I/O failure, named by the path it happened to.
    /// [`Failure::Failed`] and not [`Failure::Refused`]: a file that will not
    /// open is exit 1, "this run did not finish". Exit 3 is for a world that
    /// disagrees with the files, which is a thing a caller can act on
    /// (→ [`EXIT_REFUSED`]).
    pub(crate) fn io(path: &std::path::Path, source: &impl std::fmt::Display) -> Self {
        Self::Failed(format!("{}: {source}", path.display()))
    }
}

pub fn usage<T>(message: impl Into<String>) -> Result<T, Failure> {
    Err(Failure::Usage(message.into()))
}

/// The map that says where each **dependency's** source lives, resolved **once
/// per run** and then handed to both the renderer and the render key.
///
/// A `root` of `None` is a real case rather than an oversight: `render` and
/// `site` are pointed at an *IR tree*, which need not sit next to any checkout,
/// and with no package there is no manifest, no revisions, and nothing to link a
/// dependency at. The map comes out empty and every dependency link stays a
/// relative page link. The run says which of the two happened, because the
/// difference is invisible in the exit code and visible on every page.
///
/// **Problems do not stop the run**: a package missing from disk, a manifest
/// that will not parse, a `lake` that will not run — each costs the roots it
/// would have contributed and is printed. Refusing would trade a site with some
/// dead links for no site at all.
fn resolve_external_links(
    root: Option<&std::path::Path>,
    lake: Option<&std::path::Path>,
) -> litedoc4_render::ExternalLinks {
    let Some(root) = root else {
        println!(
            "external  no package named (--root), so links into a dependency stay relative to \
             pages this site does not write"
        );
        return litedoc4_render::ExternalLinks::default();
    };
    let lake = lake.map_or_else(
        || extract::or_env(None, "LAKE").unwrap_or_else(|| PathBuf::from("lake")),
        std::path::Path::to_path_buf,
    );
    let resolved = packages::external_links(root, &lake);
    println!(
        "external  {} root(s) from {}/{} package(s) + core",
        resolved.links.len(),
        resolved.resolved,
        resolved.declared,
    );
    // The roots in that count that carry no URL: they are in the map so that the
    // pages stop linking into them, which is the opposite of what the line above
    // reads like on its own.
    if resolved.unpinned_roots > 0 {
        println!(
            "external  note: {} of those root(s) have no version-pinned URL, so names in them \
             render without a link rather than linking at a page this site does not write",
            resolved.unpinned_roots,
        );
    }
    // Counted and printed, not folded into the line above: a collision means the
    // map holds one of two candidates, which is a different answer from "a
    // package contributed nothing".
    for line in resolved.collisions.iter().chain(&resolved.problems) {
        println!("external  note: {line}");
    }
    resolved.links
}

/// The same map with the **resolved documentation map** `build` wrote applied to
/// it, or unchanged when no `--deps-docs-map` was named.
///
/// `render` and `site` do not resolve one of their own: a flag repeated on three
/// rendering commands is one that gets forgotten on one of them, after which two
/// of the three link somewhere different, silently. This reads an answer instead
/// of re-deriving one, and nothing here fetches anything — the artifact holds
/// the verified names.
fn with_dependency_docs(
    links: litedoc4_render::ExternalLinks,
    map: Option<&std::path::Path>,
) -> Result<litedoc4_render::ExternalLinks, Failure> {
    let Some(path) = map else {
        return Ok(links);
    };
    Ok(deps_docs::attach(&links, deps_docs::read_map(path)?))
}

/// **One string, three call sites** (`render`, `site`, `incremental`), so that
/// they cannot drift apart: without the dependency map **150 of the target
/// package's 432 pages change bytes** (measured), and it fails silently — a
/// docstring name that did not become a link looks exactly like a name that was
/// never linkable — so the guard is in the shape of the flags, not in a default.
const LINK_INDEX_COST: &str =
    "without the dependency map 150 of the target package's 432 pages change bytes";

/// `render` and `site` offer `--no-link-index` as the way to say "no map, on
/// purpose"; `incremental` does not (see [`pipeline`]).
fn link_index_required() -> String {
    format!("pass --link-index <file>, or --no-link-index to say so on purpose: {LINK_INDEX_COST}")
}

/// One string for three commands, because it is one rule: the URL is
/// configuration no IR carries, and a page written without it links every
/// declaration to `/`.
pub(crate) const SOURCE_URL_REQUIRED: &str =
    "--source-url is required: doc-gen4 reads it from lake plus git, and it is not in the IR";

/// What `site` and `render` both need before they can render anything.
///
/// Shared rather than read twice because **no gate can see a disagreement
/// between them**: the gates compare the trees they write, so handing both
/// halves the same wrong interpretation produces two identical wrong trees.
/// [`stages::generate_site`] is the same idea on the output side.
pub(crate) struct RenderInputs {
    pub(crate) source_url: String,
    pub(crate) external: litedoc4_render::ExternalLinks,
    pub(crate) config: litedoc4_render::SiteConfig,
}

/// `link_index.is_some() == no_link_index` is an exclusive-or written as an
/// equality: both given and neither given are the same mistake, and
/// [`link_index_required`] says what it costs rather than which one happened.
pub(crate) fn render_inputs(
    source_url: Option<String>,
    link_index: Option<&std::path::Path>,
    no_link_index: bool,
    root: Option<&std::path::Path>,
    lake: Option<&std::path::Path>,
    deps_docs_map: Option<&std::path::Path>,
) -> Result<RenderInputs, Failure> {
    let Some(source_url) = source_url.filter(|url| !url.is_empty()) else {
        return usage(SOURCE_URL_REQUIRED);
    };
    if link_index.is_some() == no_link_index {
        return usage(link_index_required());
    }
    let external = with_dependency_docs(resolve_external_links(root, lake), deps_docs_map)?;
    let config = site_config(root)?;
    Ok(RenderInputs {
        source_url,
        external,
        config,
    })
}

/// `<root>/litedoc4.toml`, read **here and nowhere else in this binary**.
///
/// Four commands put HTML on disk (`build`, `site`, `render`, `global`) and
/// every one has to end up with the same title, so the file is read once and the
/// value handed on. Each command calling `SiteConfig::read` for itself would be
/// four places deciding what "the package root" means.
fn site_config(root: Option<&std::path::Path>) -> Result<litedoc4_render::SiteConfig, Failure> {
    litedoc4_render::SiteConfig::read(root).map_err(|e| Failure::Failed(e.to_string()))
}

/// `lead` is what each line starts with: empty for `render`, which has one
/// stage, and the stage's name for `site`, which has two.
fn print_render_summary(lead: &str, summary: &RenderSummary) {
    println!(
        "{lead}modules {}/{}  declarations {}/{} ({} suppressed)  module docs {}  bytes {}",
        summary.pages_written,
        summary.modules_in_ir,
        summary.declarations_rendered,
        summary.declarations_in_ir,
        summary.declarations_suppressed,
        summary.module_docs_rendered,
        summary.bytes_written,
    );
    println!(
        "{lead}known {}  link index {}  known modules {}",
        summary.known_entries, summary.link_index_entries, summary.known_modules,
    );
    // Printed even when it is zero: it reports a *silent* fallback — a formula
    // that stayed `$…$` still renders a valid page — so a line that appears only
    // on failure cannot be told from a line that stopped being printed.
    println!("{lead}math spans kept as LaTeX {}", summary.math_failures);
}

fn print_global_summary(lead: &str, summary: &GlobalSummary) {
    println!(
        "{lead}modules {}  declarations {} + {} dependency names  instance classes {}  \
         instance types {}  tactic docs {}",
        summary.modules,
        summary.declarations,
        summary.dependency_names,
        summary.instance_classes,
        summary.instance_types,
        summary.tactic_docs,
    );
    println!(
        "{lead}name map {} B  module index {} B  search index {} B",
        summary.name_map_bytes, summary.modules_json_bytes, summary.search_index_bytes,
    );
    // The hit/miss counts are what the cache's oracle reads, and it reads them
    // twice: here and out of `--timings`. A cache that is silent about how often
    // it hit is one nobody notices has stopped hitting.
    println!(
        "{lead}cache {} hit / {} miss  state {} B",
        summary.cache_hits, summary.cache_misses, summary.state_bytes,
    );
    if let Some(delta) = &summary.delta {
        println!(
            "{lead}delta: {} name(s) moved in or out of the map ({} -> {}) -> {} page(s) to \
             re-render",
            delta.changed.len(),
            delta.before_names,
            delta.after_names,
            delta.affected.len(),
        );
        for witness in delta.witnesses.iter().take(10) {
            println!("{lead}  {}  (mentions `{}`)", witness.module, witness.name);
        }
    }
}

/// "The world and the files disagree" — the widest of the four exit codes, and
/// the one every refusal that is not a usage error uses.
pub(crate) const EXIT_REFUSED: u8 = 3;

/// Carries the library's exit code out to the process, so that "the ledger is
/// too old" (3) stays distinguishable from "the file would not read" (1).
#[expect(
    clippy::needless_pass_by_value,
    reason = "it is a `map_err` argument, which is handed the error by value"
)]
pub(crate) fn refused(error: litedoc4_incr::Error) -> Failure {
    Failure::Refused {
        code: error.exit_code(),
        message: error.to_string(),
    }
}

/// Thousands separators, for the one place a byte count is printed to a human.
fn grouped(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, digit) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

#[cfg(test)]
mod usage_tests {
    //! Does [`USAGE`] describe the command line the parsers actually accept?
    //!
    //! Nothing else keeps the two together: `USAGE` is one long string literal
    //! and the flags are `match` arms in eight files, so a flag could be added to
    //! one and not the other and every test would still pass.

    use super::{SUMMARY, USAGE};
    use std::collections::BTreeSet;
    use std::sync::LazyLock;

    /// Every flag named in a `match` arm, across the crate. The sources are read
    /// rather than the constants listed, because a list of constants would be a
    /// third place to keep in step.
    static PARSED: LazyLock<BTreeSet<String>> = LazyLock::new(|| {
        const SOURCES: [&str; 14] = [
            include_str!("build.rs"),
            include_str!("cli.rs"),
            include_str!("deps_docs.rs"),
            include_str!("extract.rs"),
            include_str!("httpd.rs"),
            include_str!("lakefile.rs"),
            include_str!("ledger.rs"),
            include_str!("lib.rs"),
            include_str!("packages.rs"),
            include_str!("pipeline.rs"),
            include_str!("queries.rs"),
            include_str!("resident.rs"),
            include_str!("stages.rs"),
            include_str!("watch.rs"),
        ];
        let mut out = BTreeSet::new();
        for source in SOURCES {
            // Each `=>` is read backwards through the literals in front of it.
            // An arm may span lines (`"--a" | "--b"` then `| "--c" => …`), so
            // taking one line at a time misses eight of the flags (measured
            // 2026-08-23).
            for (before, _) in source.split_once("=>").into_iter().chain(
                source
                    .match_indices("=>")
                    .map(|(at, _)| (&source[..at], "")),
            ) {
                arm_flags(before, &mut out);
            }
        }
        out
    });

    /// Stops at the first thing that is not `"-…"` or `|`, so an arm with a
    /// binding (`flag if FIXED_FLAGS.contains(&flag)`) or an expression
    /// contributes nothing rather than half of something.
    fn arm_flags(before: &str, out: &mut BTreeSet<String>) {
        let mut rest = before.trim_end();
        loop {
            let Some(close) = rest.rfind('"') else { return };
            let Some(open) = rest[..close].rfind('"') else {
                return;
            };
            let name = &rest[open + 1..close];
            if !name.starts_with('-') {
                return;
            }
            if let Some(name) = name.strip_prefix("--") {
                out.insert(format!("--{name}"));
            }
            rest = rest[..open].trim_end();
            let Some(stripped) = rest.strip_suffix('|') else {
                return;
            };
            rest = stripped.trim_end();
        }
    }

    /// Every flag [`USAGE`] or [`SUMMARY`] spells as a flag: in a synopsis line
    /// or as the subject of a description. `SUMMARY` is read too because it is
    /// the text most readers see, and a flag only it names would otherwise be
    /// checked by nothing. **Not prose** — `USAGE` mentions
    /// `lean --githash` and "there is no --title", and neither is a flag of this
    /// tool.
    fn documented() -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        for line in USAGE.lines().chain(SUMMARY.lines()) {
            let trimmed = line.trim_start();
            if let Some(rest) = trimmed.strip_prefix("--") {
                let name = rest.split([' ', ',', ')', '.', ':']).next().unwrap_or(rest);
                out.insert(format!("--{name}"));
            }
            // Synopsis lines and their continuations, indented under one.
            if trimmed.starts_with("usage:") || trimmed.starts_with('[') || trimmed.starts_with('(')
            {
                for word in trimmed.split_whitespace() {
                    let word = word.trim_matches(['[', ']', '(', ')', '|']);
                    if word.starts_with("--") {
                        out.insert(word.to_owned());
                    }
                }
            }
        }
        out
    }

    /// One direction only. The other — "every flag the parsers accept is in
    /// `USAGE`" — cannot be asked here, because [`PARSED`] reads source text and
    /// cannot tell a `match` arm from the same characters in a comment, so its
    /// set is a superset. A superset only makes *this* direction pass more
    /// easily on the parser side, and what it asserts is about `USAGE`. The
    /// other direction is [`crate::ledger::LEDGER_FLAGS`]'s.
    #[test]
    fn every_documented_flag_is_parsed() {
        let documented = documented();
        let missing: Vec<&String> = documented.difference(&PARSED).collect();
        assert!(
            missing.is_empty(),
            "USAGE names flags no parser accepts: {missing:?}"
        );
    }
}
