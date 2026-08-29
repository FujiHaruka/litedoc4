//! The `contentHash` cache: `--state <dir>` keeps `<dir>/global-state.json`.
//!
//! A hit is decided on the IR's own hash, never on the caller's idea of what
//! changed, so a driver that passes a wrong changed-set cannot corrupt this
//! cache.
//!
//! **Everything that can go wrong loads as "empty", silently** — a missing file,
//! a file that does not parse, any of the four version keys disagreeing with the
//! index. A cold cache is the normal first run, and a `--state` directory left
//! behind by another tool is not an error the caller can act on: the only
//! correct response is to rebuild, which is what happens. Being wrong this way
//! costs time, where trusting a foreign entry costs a wrong artifact that nobody
//! reports.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use litedoc4_ir::Index;
use serde::{Deserialize, Serialize, Serializer};

use crate::facts::ModuleFacts;
use crate::site::Error;

pub const STATE_FILE: &str = "global-state.json";

/// Bumped when the *file format* changes. Kept apart from
/// [`STATE_DERIVATION`], which is bumped when the *facts* change, because the
/// two rot for different reasons.
pub const STATE_VERSION: u64 = 1;

/// Which rule built the facts in the file. **Bump it whenever a field of
/// [`ModuleFacts`] or the way one is derived changes**: bumping makes every
/// entry a miss, which is correct and slow, where keeping entries built by an
/// older rule is fast and wrong — every module that hits then derives its
/// artifacts from a fact that is silently absent.
///
/// **Deliberately not the prototype's `"stage7h/global.ts facts v1"`.** The
/// string names an implementation, and this crate derives [`ModuleFacts`] with
/// its own code — same intent, a different tokeniser in one documented place
/// ([`crate::facts::autolink_tokens`]) — so a state written by the TypeScript
/// prototype has to miss on every module here, and one written here has to miss
/// over there. Matching the strings would make the two caches interchangeable,
/// which is exactly the claim nobody has checked.
pub const STATE_DERIVATION: &str = "litedoc4-global facts v4";

/// The facts a previous run left behind, already checked against this run's
/// index. Empty is a complete and valid value: every module will be read.
#[derive(Clone, Debug, Default)]
pub struct State {
    modules: HashMap<String, ModuleFacts>,
}

impl State {
    #[must_use]
    pub fn empty() -> Self {
        Self::default()
    }

    /// The four version keys are checked against `index` here rather than at the
    /// hit test, so a foreign state costs one parse and not one comparison per
    /// module.
    #[must_use]
    pub fn load(dir: Option<&Path>, index: &Index) -> Self {
        let Some(dir) = dir else {
            return Self::empty();
        };
        let Ok(raw) = fs::read_to_string(dir.join(STATE_FILE)) else {
            return Self::empty();
        };
        let Ok(state) = serde_json::from_str::<StateFile>(&raw) else {
            return Self::empty();
        };
        if state.state_version != STATE_VERSION
            || state.derivation != STATE_DERIVATION
            || state.schema_version != index.schema_version
            || state.generator != index.generator
        {
            return Self::empty();
        }
        Self {
            modules: state.modules,
        }
    }

    /// The stored facts for a module, **whatever hash they were built for** —
    /// the hash test is the caller's ([`crate::facts_for`]), so that this type
    /// has no opinion about what a hit is.
    #[must_use]
    pub fn get(&self, module: &str) -> Option<&ModuleFacts> {
        self.modules.get(module)
    }

    /// How many modules the file offered — not how many will hit.
    #[must_use]
    pub fn len(&self) -> usize {
        self.modules.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.modules.is_empty()
    }

    /// Writes `<dir>/global-state.json` and returns its size in bytes, or 0
    /// when there is no state directory.
    ///
    /// **Only modules the index still lists are written, in index order.** An
    /// entry for a module that has left the package has to disappear with it:
    /// keeping it would leave a name in `name-map.json` and a module in
    /// `importedBy` that no IR file backs, and a cache that only ever grows
    /// passes every other test. Index order rather than hash order so that two
    /// runs over the same module set write the same bytes.
    pub fn save(dir: Option<&Path>, index: &Index, facts: &[ModuleFacts]) -> Result<usize, Error> {
        let Some(dir) = dir else {
            return Ok(0);
        };
        fs::create_dir_all(dir).map_err(|source| Error::Io {
            path: dir.to_owned(),
            source,
        })?;
        // Keying on the facts' own module name is keying on the index entry's:
        // `IrTree::module` refuses a file that disagrees with the index about
        // which module it holds.
        let by_module: HashMap<&str, &ModuleFacts> = facts
            .iter()
            .map(|facts| (facts.module.as_str(), facts))
            .collect();
        let kept: Vec<&ModuleFacts> = index
            .modules
            .iter()
            .filter_map(|entry| by_module.get(entry.module.as_str()).copied())
            .collect();

        let body = serde_json::to_string(&StateOut {
            state_version: STATE_VERSION,
            derivation: STATE_DERIVATION,
            schema_version: index.schema_version,
            generator: &index.generator,
            modules: Modules(&kept),
        })
        .expect("module facts are strings, numbers and arrays of them");

        let path = dir.join(STATE_FILE);
        fs::write(&path, &body).map_err(|source| Error::Io {
            path: path.clone(),
            source,
        })?;
        Ok(body.len())
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StateFile {
    state_version: u64,
    derivation: String,
    schema_version: u32,
    generator: String,
    #[serde(default)]
    modules: HashMap<String, ModuleFacts>,
}

/// The file as written. **The field order below is the key order, and the key
/// order is the bytes** — `tests/state_and_delta.rs` compares this file with one
/// the prototype wrote, byte for byte.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StateOut<'a> {
    state_version: u64,
    derivation: &'a str,
    schema_version: u32,
    generator: &'a str,
    modules: Modules<'a>,
}

/// The module map, serialised in the order given rather than through a
/// `serde_json::Map`: a map's *serialisation* order is the iterator's, so this
/// needs no `preserve_order` — unlike the artifacts, which build `Value` trees.
struct Modules<'a>(&'a [&'a ModuleFacts]);

impl Serialize for Modules<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_map(self.0.iter().map(|facts| (facts.module.as_str(), *facts)))
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use litedoc4_ir::IndexEntry;

    fn facts(module: &str) -> ModuleFacts {
        ModuleFacts {
            module: module.to_owned(),
            content_hash: "0".repeat(16),
            imports: Vec::new(),
            tactics: 0,
            decls: Vec::new(),
            instances: Vec::new(),
            tokens: Vec::new(),
            instances_for: Vec::new(),
            refs: BTreeMap::new(),
            summary: None,
        }
    }

    fn index(modules: &[&str]) -> Index {
        Index {
            schema_version: 4,
            generator: "test".to_owned(),
            lean_version: "4.31.0".to_owned(),
            hash_algorithm: "lean-string-hash-64/hex16".to_owned(),
            module_count: u32::try_from(modules.len()).expect("a test index is small"),
            declaration_count: 0,
            ablations: Vec::new(),
            modules: modules
                .iter()
                .map(|module| IndexEntry {
                    module: (*module).to_owned(),
                    file: format!("modules/{module}.json"),
                    bytes: 0,
                    declarations: 0,
                    content_hash: "0".repeat(16),
                })
                .collect(),
            dependency_maps: Vec::new(),
        }
    }

    /// The whole-package tests cannot make this non-vacuous: they only ever hand
    /// [`State::save`] facts that came from the index it is passed, so the
    /// filter is unreachable from there and dropping it would pass every one of
    /// them.
    #[test]
    fn only_the_index_survives_into_the_file() {
        let dir = std::env::temp_dir().join(format!("litedoc4-state-save-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let index = index(&["Pkg.A", "Pkg.B"]);
        // Out of index order, and one module the index does not list.
        let facts = [facts("Pkg.B"), facts("Pkg.Gone"), facts("Pkg.A")];
        let bytes = State::save(Some(&dir), &index, &facts).expect("the state is writable");

        let body = fs::read_to_string(dir.join(STATE_FILE)).expect("the state was written");
        assert_eq!(body.len(), bytes);
        let written: serde_json::Value = serde_json::from_str(&body).expect("the state is JSON");
        let modules: Vec<&String> = written["modules"]
            .as_object()
            .expect("a module map")
            .keys()
            .collect();
        assert_eq!(modules, ["Pkg.A", "Pkg.B"], "in index order, index only");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn without_a_directory_nothing_is_written() {
        assert_eq!(
            State::save(None, &index(&["Pkg.A"]), &[facts("Pkg.A")]).expect("no io happens"),
            0
        );
        assert!(State::load(None, &index(&["Pkg.A"])).is_empty());
    }
}
