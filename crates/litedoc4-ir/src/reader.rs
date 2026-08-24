//! Opening an IR tree and reading files out of it.
//!
//! [`IrTree::module`] is the single funnel every module read goes through —
//! including the ones [`IrTree::modules`] and [`IrTree::load_modules`] make — so
//! a `contentHash` cache in front of those reads has exactly one place to go.

use std::fs;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;

use crate::error::{Error, Result};
use crate::metrics::{self, IrFile};
use crate::model::{DepMap, DepMapEntry, Index, IndexEntry, ModuleFile};

/// A floor of 5 buys one meaning per absence: schema 5 adds `sorry`,
/// `selectionRange` and `generated`, and for each of them an *absent* key says
/// something — "no `sorry`", "not realized by an attribute" — that a schema-4
/// file cannot say, because there the key could not exist.
pub const MIN_SCHEMA_VERSION: u32 = 5;

/// Below it the key's absence says nothing; at or above it, it says "no
/// `sorry`". [`crate::ModuleFile::sorry_of`] is the only place this is applied.
pub(crate) const SORRY_SCHEMA_VERSION: u32 = 5;

/// The same number as [`SORRY_SCHEMA_VERSION`] and a constant of its own on
/// purpose: what each absence means is a fact about that key, and one shared
/// constant would have to be edited in two places the day they stop being the
/// same schema. [`crate::ModuleFile::naming_of`] and
/// [`crate::ModuleFile::generated_by`] are the only places this is applied.
pub(crate) const SELECTION_RANGE_SCHEMA_VERSION: u32 = 5;

/// An IR tree on disk: `index.json`, `modules/`, `deps/`.
#[derive(Debug)]
pub struct IrTree {
    root: PathBuf,
    index: Index,
}

impl IrTree {
    /// Only the index is read; module files are read on demand.
    pub fn open(root: impl Into<PathBuf>) -> Result<Self> {
        let tree = Self::open_unvalidated(root)?;
        tree.index.require_renderable()?;
        Ok(tree)
    }

    /// As [`IrTree::open`] without the refusals, for tools that want to look at
    /// an ablated or older tree rather than render it.
    pub fn open_unvalidated(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        let index: Index = read_json(&root.join("index.json"), IrFile::Index)?;
        Ok(Self { root, index })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn index(&self) -> &Index {
        &self.index
    }

    pub fn path(&self, relative: &str) -> PathBuf {
        self.root.join(relative)
    }

    /// The `schemaVersion` is checked here too: an incremental tree is a merge
    /// of files from several extractor runs, so the index's version does not
    /// vouch for the modules'.
    pub fn module(&self, entry: &IndexEntry) -> Result<ModuleFile> {
        let path = self.path(&entry.file);
        let module = read_module_file(&path)?;
        if module.module != entry.module {
            return Err(Error::ModuleMismatch {
                path,
                expected: entry.module.clone(),
                found: module.module,
            });
        }
        Ok(module)
    }

    pub fn modules(&self) -> impl Iterator<Item = Result<ModuleFile>> + '_ {
        self.index.modules.iter().map(|entry| self.module(entry))
    }

    pub fn load_modules(&self) -> Result<Vec<ModuleFile>> {
        self.modules().collect()
    }

    pub fn dep_map(&self, entry: &DepMapEntry) -> Result<DepMap> {
        read_json(&self.path(&entry.file), IrFile::DepMap)
    }

    pub fn load_dep_maps(&self) -> Result<Vec<DepMap>> {
        self.index
            .dependency_maps
            .iter()
            .map(|entry| self.dep_map(entry))
            .collect()
    }
}

/// The way in for the one caller that has no index to check the file against:
/// the **merger** reads the tree it is in the middle of writing, whose
/// `index.json` is written last.
pub fn read_module_file(path: &Path) -> Result<ModuleFile> {
    let module: ModuleFile = read_json(path, IrFile::Module)?;
    if module.schema_version < MIN_SCHEMA_VERSION {
        return Err(Error::Schema {
            what: path.display().to_string(),
            found: module.schema_version,
            required: MIN_SCHEMA_VERSION,
        });
    }
    Ok(module)
}

/// `kind` is a parameter rather than something derived from `path`: a caller
/// that adds a read has to say what it is reading, and a guess from the file
/// name would be a fourth spelling of the tree's layout that nothing checks.
fn read_json<T: DeserializeOwned>(path: &Path, kind: IrFile) -> Result<T> {
    metrics::record(kind);
    // Read the whole file, then parse, rather than `from_reader`: the largest
    // file in the tree is a few MB, and `serde_json` is documented as being
    // faster over a string than over a reader.
    let text = fs::read_to_string(path).map_err(|source| Error::Io {
        path: path.to_owned(),
        source,
    })?;
    serde_json::from_str(&text).map_err(|source| Error::Json {
        path: path.to_owned(),
        source,
    })
}
