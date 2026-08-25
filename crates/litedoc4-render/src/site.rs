//! The run: an IR tree in, a tree of module pages out.
//!
//! The name map has three sources and they are not commutative: the dependency
//! slices, then every declaration of every module — which **overwrites** — then
//! every reference the extractor resolved, which **fills gaps only**.
//! [`crate::autolink::NameIndexBuilder`] enforces the difference at the call
//! site; this module's job is to feed it in that order.
//!
//! Every module file is read even when only one page is being rendered. The
//! name map and [`Suppressed`] are site-wide, and a page rendered against a
//! partial map differs in the links it draws rather than failing — a byte
//! difference no error message announces. That is why [`ModuleSet`] filters
//! *pages*, not *reads*.

use std::collections::BTreeSet;
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use litedoc4_ir::IrTree;

use crate::autolink::NameIndex;
use crate::config::SiteConfig;
use crate::decl::UnplaceableName;
use crate::external::ExternalLinks;
use crate::frame::SiteMeta;
use crate::link_index::LinkIndex;
use crate::page::{Suppressed, page_html, page_path};

/// Which modules get a page written.
///
/// **`These(empty)` writes nothing.** The variant exists so that "the caller
/// computed a set and it came out empty" cannot be spelled the same way as
/// "the caller did not ask for a subset".
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ModuleSet {
    All,
    These(BTreeSet<String>),
}

impl ModuleSet {
    /// One module name per line, as the incremental pipeline's render set is
    /// written. Blank lines are dropped; **an empty file is an empty set**.
    #[must_use]
    pub fn from_lines(text: &str) -> Self {
        Self::These(
            text.lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(str::to_owned)
                .collect(),
        )
    }

    #[must_use]
    pub fn contains(&self, module: &str) -> bool {
        match self {
            Self::All => true,
            Self::These(names) => names.contains(module),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct RenderOptions<'a> {
    /// The IR tree: `index.json`, `modules/`, `deps/`.
    pub ir: &'a Path,
    /// Directories are created as needed.
    pub pages: &'a Path,
    /// The `https://host/owner/repo/blob/<rev>` prefix every `source` link is
    /// built from. Configuration, not IR — doc-gen4 reads it from lake plus
    /// git. Trailing slashes are stripped here.
    pub source_url: &'a str,
    /// Where each **dependency's** source lives. Configuration the IR does not
    /// carry — `litedoc4`'s `packages` module resolves it from the target's
    /// `lake-manifest.json` and its toolchain.
    ///
    /// An empty map (the [`ExternalLinks::default`]) leaves every link into a
    /// dependency a relative page link to a page this site never writes. It is
    /// an empty map rather than an `Option` because the two would mean the same
    /// thing and one of them can be misread as "the default".
    pub external_links: &'a ExternalLinks,
    /// What `<root>/litedoc4.toml` said, already read.
    ///
    /// A borrow rather than a path because **resolving it is not this
    /// function's job**: three commands render, and if each read the file for
    /// itself there would be three places that decide what "root" means. The
    /// binary reads it once (`litedoc4::site_config`) and hands the answer to
    /// whichever half is about to run.
    pub config: &'a SiteConfig,
    /// The dependency closure's `name -> module` map.
    ///
    /// `None` is a decision, not a default: without it 150 of the target
    /// package's 432 pages change bytes (measured). The product always passes one.
    pub link_index: Option<&'a Path>,
    pub only: &'a ModuleSet,
}

/// What a run did, in the units its inputs are counted in: every field is a
/// denominator something else can be quoted against.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RenderSummary {
    pub modules_in_ir: usize,
    pub declarations_in_ir: usize,
    /// Names that are some declaration's member, over the whole site.
    pub declarations_suppressed: usize,
    pub pages_written: usize,
    /// Blocks on the pages that were written, not in the IR.
    pub declarations_rendered: usize,
    pub module_docs_rendered: usize,
    pub known_entries: usize,
    pub link_index_entries: usize,
    pub known_modules: usize,
    pub bytes_written: u64,
    /// Math spans that could not be converted to MathML and were written back
    /// as their LaTeX source.
    ///
    /// Zero is the number to expect: the target package's three spans and
    /// 99.58% of Mathlib's 2,123 convert (measured 2026-08-22 →
    /// `benchmarks/results/mathml-2026-08-22.txt`). A non-zero value is a
    /// docstring to look at, not a bug in the build.
    pub math_failures: usize,
}

pub fn render_site(options: &RenderOptions<'_>) -> Result<RenderSummary, Error> {
    let source_url = options.source_url.trim_end_matches('/');
    let tree = IrTree::open(options.ir)?;

    let mut builder = NameIndex::builder();
    for dep in tree.load_dep_maps()? {
        builder.dep_map(&dep);
    }
    let modules = tree.load_modules()?;
    for module in &modules {
        builder.module(module);
    }
    let links = match options.link_index {
        Some(path) => LinkIndex::read(path).map_err(|source| Error::Io {
            path: path.to_owned(),
            source,
        })?,
        None => LinkIndex::default(),
    };
    let index = builder.build(links, options.external_links.clone());

    let suppressed = Suppressed::of_site(&modules);
    // Over **every** module of the IR, not the subset being rendered: an
    // incremental round that re-renders one page must not retitle the site.
    let site = SiteMeta::of(
        options.config,
        None,
        modules.iter().map(|module| module.module.as_str()),
    );

    let mut summary = RenderSummary {
        modules_in_ir: modules.len(),
        declarations_in_ir: modules.iter().map(|m| m.declarations.len()).sum(),
        declarations_suppressed: suppressed.len(),
        known_entries: index.len(),
        link_index_entries: index.link_index_len(),
        known_modules: index.known_module_count(),
        ..RenderSummary::default()
    };

    for module in &modules {
        if !options.only.contains(&module.module) {
            continue;
        }
        let page = page_html(module, &index, source_url, &suppressed, &site).map_err(|source| {
            Error::Unplaceable {
                module: module.module.clone(),
                source,
            }
        })?;
        let html = page.html;
        summary.math_failures += page.math_failures;
        let path = options.pages.join(page_path(&module.module));
        write_page(&path, &html)?;
        summary.pages_written += 1;
        summary.bytes_written += html.len() as u64;
        summary.module_docs_rendered += module.module_docs.len();
        summary.declarations_rendered += module
            .declarations
            .iter()
            .filter(|d| !suppressed.contains(&d.name))
            .count();
    }
    Ok(summary)
}

/// The two calls fail with different paths — the directory that could not be
/// made, and the file that could not be written — and [`Error::Io`] carries
/// whichever it was, which is the whole reason this is not `fs::write` alone.
fn write_page(path: &Path, html: &str) -> Result<(), Error> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|source| Error::Io {
            path: dir.to_owned(),
            source,
        })?;
    }
    fs::write(path, html).map_err(|source| Error::Io {
        path: path.to_owned(),
        source,
    })
}

#[derive(Debug)]
pub enum Error {
    Ir(litedoc4_ir::Error),
    Io {
        path: PathBuf,
        source: io::Error,
    },
    /// A name that has to be linked and is in no module. doc-gen4 panics here;
    /// the page is not written instead, because a plausible `href` would be a
    /// wrong byte that costs a bisection to find.
    Unplaceable {
        module: String,
        source: UnplaceableName,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Ir(source) => write!(f, "{source}"),
            Self::Io { path, source } => write!(f, "{}: {source}", path.display()),
            Self::Unplaceable { module, source } => write!(f, "rendering {module}: {source}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Ir(source) => Some(source),
            Self::Io { source, .. } => Some(source),
            Self::Unplaceable { source, .. } => Some(source),
        }
    }
}

impl From<litedoc4_ir::Error> for Error {
    fn from(source: litedoc4_ir::Error) -> Self {
        Self::Ir(source)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use litedoc4_testutil::TempDirs;

    const TEMP: TempDirs = TempDirs::prefixed("litedoc4-site");

    #[test]
    fn an_empty_module_set_is_not_the_absence_of_one() {
        let empty = ModuleSet::These(BTreeSet::new());
        assert!(!empty.contains("Pkg.One"));
        assert!(ModuleSet::All.contains("Pkg.One"));
        assert_eq!(ModuleSet::from_lines(""), empty);
        assert_eq!(ModuleSet::from_lines("\n  \n"), empty);
        assert_eq!(
            ModuleSet::from_lines("Pkg.One\nPkg.Two\n"),
            ModuleSet::These(["Pkg.One".to_owned(), "Pkg.Two".to_owned()].into())
        );
        assert!(ModuleSet::from_lines("Pkg.One\n").contains("Pkg.One"));
        assert!(!ModuleSet::from_lines("Pkg.One\n").contains("Pkg.Two"));
    }

    #[test]
    fn a_page_is_written_under_directories_that_did_not_exist() {
        let dir = TEMP.reserve("nested");
        let path = dir.path().join("Pkg").join("Sub").join("M.html");

        write_page(&path, "<html></html>").expect("the directories are made first");

        assert_eq!(
            fs::read_to_string(&path).expect("the page is there"),
            "<html></html>"
        );
    }

    /// The blocked parent is this crate's own `Cargo.toml`, so the test writes
    /// nothing anywhere: `create_dir_all` refuses before any file is opened.
    #[test]
    fn a_directory_that_cannot_be_made_is_the_path_the_error_names() {
        let blocked = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("Cargo.toml")
            .join("Pkg");
        let path = blocked.join("M.html");

        match write_page(&path, "<html></html>") {
            Err(Error::Io { path: named, .. }) => assert_eq!(named, blocked),
            other => panic!("a file in the way of a directory is an Io error: {other:?}"),
        }
    }
}
