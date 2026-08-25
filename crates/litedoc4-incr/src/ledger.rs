//! The ledger file: what a module's inputs hash to, and the two global keys.
//!
//! What is hashed is the `.olean`, because that is the extractor's only view of
//! a module: `importModules` reads nothing else. The `.lean` source is one step
//! too early — it carries changes the olean does not (whitespace inside a proof)
//! and misses changes the olean has (anything a rebuild of a dependency puts
//! there) — and the IR's own `contentHash` is one step too late, because
//! computing it means running the extraction this stage exists to skip. That
//! hash has the other job: which *pages* to rewrite.
//!
//! Modules built with Lean's module system have up to three olean files and
//! **all present ones are hashed**: declaration ranges and docstrings live in
//! the server data, private declarations in the private one.

use std::collections::HashSet;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};

use litedoc4_ir::cmp_utf16;
use serde::{Deserialize, Deserializer, Serialize};
use sha2::{Digest, Sha256};

use crate::error::Error;
use crate::ordered::Ordered;

/// `1` had a single `envKey`; `2` splits it into `extractKey` and `renderKey`,
/// which do not invalidate the same thing. A schema-1 file on disk is refused
/// rather than reinterpreted.
pub const LEDGER_SCHEMA: u64 = 2;

/// `extractKey.extractor`: which implementation will run when the key says
/// "re-extract". The string names an implementation, so a ledger written by one
/// must never be trusted by another — the same rule
/// [`litedoc4_global::STATE_DERIVATION`] follows.
///
/// **Bump the version whenever a re-extraction can produce different IR bytes**,
/// including when `irSchemaVersion` cannot see the difference: the schema number
/// has stayed put across changes to what the IR's own keys hold, and then the
/// only thing separating two IRs is which extractor wrote them. The failure a
/// missed bump produces is silent — the reused IR renders today's bytes and is
/// simply missing what the new consumer wanted.
///
/// `extractKey.irGenerator` does **not** move with this: it carries whatever
/// wrote the IR (`lean-doc/experiments/stage4b`, which is what the extractor
/// writes), a fact about the tree on disk rather than about this crate.
///
/// [`litedoc4_global::STATE_DERIVATION`]: ../litedoc4_global/constant.STATE_DERIVATION.html
pub const EXTRACTOR_ID: &str = "litedoc4 extractor v3";

/// `renderKey.renderer`: which implementation will run when the key says
/// "re-render everything", under the same rule as [`EXTRACTOR_ID`].
///
/// **Bump the version whenever the renderer's output bytes can change with the
/// IR held fixed.** Nothing else can see such a change, so a missed bump leaves
/// an incremental build finding every page up to date, keeping the old bytes,
/// and reporting "0 pages rendered" as success.
pub const RENDERER_ID: &str = "litedoc4 renderer v4";

/// In the order they are hashed.
pub const OLEAN_SUFFIXES: [&str; 3] = [".olean", ".olean.server", ".olean.private"];

/// A string rather than an enum because the ledger stores it verbatim and
/// **anything that is not `lake` reads and hashes the bytes**, so an unknown
/// algorithm degrades to the reference one rather than to nothing.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Algorithm(String);

impl Algorithm {
    /// Read `<file>.hash`, the 64-bit content hash Lake already wrote next to
    /// every olean (`computeBinFileHash`, `Lake/Build/Common.lean`). A string
    /// read, no hashing: 6.9 KB instead of 227 MB on the target.
    pub const LAKE: &'static str = "lake";
    /// SHA-256 over the olean bytes. The reference: cryptographic, and not an
    /// undocumented implementation detail of the build tool.
    pub const SHA256: &'static str = "sha256";

    #[must_use]
    pub fn new(name: impl Into<String>) -> Self {
        Self(name.into())
    }

    #[must_use]
    pub fn sha256() -> Self {
        Self::new(Self::SHA256)
    }

    #[must_use]
    pub fn lake() -> Self {
        Self::new(Self::LAKE)
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.0
    }

    #[must_use]
    pub fn hashes_bytes(&self) -> bool {
        self.0 != Self::LAKE
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileEntry {
    /// Relative to the ledger's `target`.
    pub path: String,
    /// **`-1` under `--algorithm lake`**: nothing was read but the hash file, so
    /// there is no byte count to report and a zero would read as an empty
    /// olean. Every sum over this field clamps at zero.
    pub bytes: i64,
    pub hash: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModuleEntry {
    pub module: String,
    pub files: Vec<FileEntry>,
    /// Over the per-file hashes, so a missing or extra file shows up.
    pub hash: String,
}

/// How `extractKey` and `renderKey` are stored: ordered, because the key order
/// is part of the ledger's bytes, and with the values **in the clear rather
/// than hashed**, so that a mismatch names itself in a log.
pub type KeySet = Ordered<String>;

impl<'de> Deserialize<'de> for KeySet {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::deserialize_in_order(deserializer, "a map of strings to strings")
    }
}

impl Ordered<String> {
    /// The names, in UTF-16 order, of the keys **present in either set** whose
    /// values differ.
    ///
    /// The union is what makes a missing key loud: a key that vanished — an
    /// `--ir` that was not passed this time, a forgotten `--source-url` —
    /// compares `None != Some(_)` and counts as a change. Over-extracting and
    /// over-rendering are the safe directions; the failure this prevents is
    /// silently rendering too little, which nobody reports because the site
    /// still looks built.
    ///
    /// The [`cmp_utf16`] order reaches a file — the reason lines of
    /// `--render-all-out`.
    #[must_use]
    pub fn diff(&self, now: &Self) -> Vec<String> {
        let mut seen: HashSet<&str> = HashSet::new();
        let mut names: Vec<&str> = Vec::new();
        for (name, _) in self.iter().chain(now.iter()) {
            if seen.insert(name) {
                names.push(name);
            }
        }
        let mut changed: Vec<String> = names
            .into_iter()
            .filter(|name| self.get(name) != now.get(name))
            .map(str::to_owned)
            .collect();
        changed.sort_by(|a, b| cmp_utf16(a, b));
        changed
    }
}

/// Field order **is** the file's key order — `serde` emits a struct's fields as
/// declared, and `tests/ledger.rs` compares the result against frozen bytes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ledger {
    /// A file without the field is a schema-1 file, not a parse failure, so that
    /// `check` can name what is wrong with it.
    #[serde(default = "schema_before_the_split")]
    pub ledger_schema: u64,
    pub algorithm: Algorithm,
    pub target: String,
    pub lib_dir: String,
    pub extract_key: KeySet,
    /// Read as empty at the comparison, but **`None` stays absent on the way
    /// out**: `touch` rewrites the file it read, and a key this crate invented
    /// would be a byte nobody asked for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub render_key: Option<KeySet>,
    pub modules: Vec<ModuleEntry>,
}

fn schema_before_the_split() -> u64 {
    1
}

impl Ledger {
    #[must_use]
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("a ledger is strings, numbers and arrays of them") + "\n"
    }

    #[must_use]
    pub fn entry(&self, module: &str) -> Option<&ModuleEntry> {
        self.modules.iter().find(|entry| entry.module == module)
    }

    /// An absent render key reads as empty, which makes every current key a
    /// change rather than no change at all.
    #[must_use]
    pub fn render_key_or_empty(&self) -> KeySet {
        self.render_key.clone().unwrap_or_default()
    }
}

/// Everything that can change the IR bytes. Changed ⇒ re-extract everything;
/// which pages are then stale still follows from the IR diff, so a
/// re-extraction that lands byte-identical rewrites no page.
///
/// The split from [`render_key`] is not cosmetic. `--source-url` carries a
/// 40-hex git revision, so it changes on *every commit*, which is exactly when
/// an incremental build runs; under one key every real incremental build would
/// pay a full re-extraction — Lean started, 27 s (measured) — for an input Lean
/// cannot see. The test for which side an input belongs on is not "does it
/// change the output" (both do) but "can it change the IR".
pub fn extract_key(target: &str, ir: Option<&Path>) -> Result<KeySet, Error> {
    let mut key = KeySet::new();
    let root = Path::new(target);
    key.insert(
        "leanToolchain",
        read_to_string(&root.join("lean-toolchain"))?.trim(),
    );
    key.insert(
        "manifestSha256",
        // The manifest is hashed rather than stored: it is 20 KB, and unlike the
        // other values there is nothing in it a human reads out of a log.
        sha256_text(&read_to_string(&root.join("lake-manifest.json"))?),
    );
    key.insert("extractor", EXTRACTOR_ID);
    if let Some(ir) = ir {
        let path = ir.join("index.json");
        // Two fields of the index, read as plain JSON — but a read of an IR file
        // all the same, so it is counted like every other. Both `detect` and
        // `build`'s final ledger write come through here, which is why an
        // unchanged run still shows `index` reads with `module` at zero.
        litedoc4_ir::metrics::record(litedoc4_ir::IrFile::Index);
        let index: serde_json::Value = serde_json::from_str(&read_to_string(&path)?)
            .map_err(|source| Error::Json { path, source })?;
        key.insert("irSchemaVersion", js_string(index.get("schemaVersion")));
        key.insert("irGenerator", js_string(index.get("generator")));
    }
    Ok(key)
}

/// What changes the page bytes with the IR held fixed. Changed ⇒ re-extract
/// **nothing**, re-render **everything**. The renderer id stands in for the
/// configuration that has no flag of its own; everything that does have a flag
/// and reaches the output bytes belongs here beside it.
///
/// `linkIndex` is the dependency map: with the same IR and the same
/// `--source-url`, having it or not moves **150 of the measurement target's 432
/// pages' bytes** (measured). Its identity is the **SHA-256 of the file's bytes**,
/// not its path and not its size — the bytes are what the renderer reads, so two
/// maps that hash the same produce the same pages whoever wrote them.
///
/// `externalLinks` is where a **dependency's** source lives (`Mathlib` ->
/// `…/mathlib4/blob/<rev>`, and eighteen more). A bumped dependency moves a
/// `rev`, which moves the href of every link into it, on exactly the occasion an
/// incremental build runs. Its identity is
/// [`litedoc4_render::ExternalLinks::digest`], a function of what the map
/// *resolves* rather than of how it was built: a resolver that reorders its scan
/// must not re-render 432 pages for nothing.
///
/// `None` leaves either key absent, and [`KeySet::diff`] counts an appearing or
/// vanishing key as a change — the loud direction.
///
/// [`litedoc4_render::ExternalLinks::digest`]: ../litedoc4_render/struct.ExternalLinks.html#method.digest
#[must_use]
pub fn render_key(
    source_url: &str,
    link_index: Option<&str>,
    external_links: Option<&str>,
) -> KeySet {
    let mut key = KeySet::new();
    key.insert("renderer", RENDERER_ID);
    if !source_url.is_empty() {
        key.insert("sourceUrl", source_url.trim_end_matches('/'));
    }
    if let Some(digest) = link_index {
        key.insert("linkIndex", digest);
    }
    if let Some(digest) = external_links {
        key.insert("externalLinks", digest);
    }
    key
}

/// `Ok(None)` when the file is not there, which is a real state and not an
/// error — a first `build` computes the ledger's hashes *before* the extraction
/// that writes the map, and `litedoc4 render --no-link-index` never has one. Any
/// other I/O failure is an error: a map that exists and cannot be read is not a
/// map that is absent, and treating the two alike is how a key goes missing
/// without a word.
pub fn link_index_digest(path: Option<&Path>) -> Result<Option<String>, Error> {
    let Some(path) = path else {
        return Ok(None);
    };
    match fs::read(path) {
        Ok(bytes) => Ok(Some(sha256_hex(&bytes))),
        Err(source) if source.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(source) => Err(Error::Io {
            path: path.to_owned(),
            source,
        }),
    }
}

/// A missing key becomes the string `"undefined"`, which is what makes an IR
/// without a `schemaVersion` compare equal to another IR without one.
fn js_string(value: Option<&serde_json::Value>) -> String {
    match value {
        None => "undefined".to_owned(),
        Some(serde_json::Value::String(text)) => text.clone(),
        Some(other) => other.to_string(),
    }
}

/// The olean files a module actually has, in [`OLEAN_SUFFIXES`] order. A suffix
/// that is absent is not an error: this build simply does not use Lean's module
/// system for that module.
#[must_use]
pub fn module_paths(lib_dir: &str, module: &str) -> Vec<String> {
    // The olean is at the source's path, so the components are unescaped:
    // `Alpha.«Odd-Name»` is built from `Alpha/Odd-Name.lean` into
    // `Alpha/Odd-Name.olean`.
    let base = format!("{lib_dir}/{}", litedoc4_ir::module_path(module));
    OLEAN_SUFFIXES
        .iter()
        .map(|suffix| format!("{base}{suffix}"))
        .filter(|path| fs::metadata(path).is_ok_and(|meta| meta.is_file()))
        .collect()
}

/// **`None` is a real answer, not an error**: a module can be deleted between
/// `build` and `check`, and the deletion is exactly what the caller needs to
/// hear about.
///
/// A module that has an olean but whose `<file>.hash` is missing under
/// `--algorithm lake` is a different case and *is* an error: the file the
/// algorithm names is not there, and reporting the module as removed would
/// delete its pages.
#[expect(
    clippy::cast_possible_wrap,
    reason = "the field is i64 to carry the -1 sentinel; no olean approaches i64::MAX"
)]
pub fn hash_module(
    target: &str,
    lib_dir: &str,
    module: &str,
    algorithm: &Algorithm,
) -> Result<Option<ModuleEntry>, Error> {
    let mut files: Vec<FileEntry> = Vec::new();
    for path in module_paths(lib_dir, module) {
        if algorithm.hashes_bytes() {
            let bytes = fs::read(&path).map_err(|source| Error::Io {
                path: path.clone().into(),
                source,
            })?;
            files.push(FileEntry {
                path: relative_path(target, &path),
                bytes: bytes.len() as i64,
                hash: sha256_hex(&bytes),
            });
        } else {
            // Lake's own content hash of exactly this file, already on disk.
            let hash_path = format!("{path}.hash");
            files.push(FileEntry {
                path: relative_path(target, &path),
                bytes: -1,
                hash: read_to_string(Path::new(&hash_path))?.trim().to_owned(),
            });
        }
    }
    if files.is_empty() {
        return Ok(None);
    }
    let combined: Vec<String> = files
        .iter()
        .map(|file| format!("{} {}", file.path, file.hash))
        .collect();
    Ok(Some(ModuleEntry {
        module: module.to_owned(),
        files,
        hash: sha256_text(&combined.join("\n")),
    }))
}

/// Relative to the target repository. A path that does not begin with the
/// target — a `libDir` hand-edited to point outside it — is kept whole rather
/// than cut at an arbitrary offset; nothing `build` writes can reach that.
fn relative_path(target: &str, path: &str) -> String {
    path.strip_prefix(target)
        .and_then(|rest| rest.strip_prefix('/'))
        .unwrap_or(path)
        .to_owned()
}

/// The result is in input order whatever the scheduling, which is what lets the
/// ledger's bytes be independent of `--concurrency`.
pub(crate) fn map_pool<T: Send>(
    items: &[String],
    concurrency: usize,
    f: impl Fn(&str) -> T + Sync,
) -> Vec<T> {
    if concurrency <= 1 {
        return items.iter().map(|item| f(item)).collect();
    }
    let next = AtomicUsize::new(0);
    let workers = concurrency.min(items.len());
    let chunks: Vec<Vec<(usize, T)>> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..workers)
            .map(|_| {
                let next = &next;
                let f = &f;
                scope.spawn(move || {
                    let mut out = Vec::new();
                    loop {
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        let Some(item) = items.get(i) else { return out };
                        out.push((i, f(item)));
                    }
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|handle| handle.join().expect("a hashing worker panicked"))
            .collect()
    });
    let mut out: Vec<Option<T>> = (0..items.len()).map(|_| None).collect();
    for chunk in chunks {
        for (i, value) in chunk {
            out[i] = Some(value);
        }
    }
    out.into_iter()
        .map(|value| value.expect("every index was assigned exactly once"))
        .collect()
}

pub(crate) fn read_to_string(path: &Path) -> Result<String, Error> {
    fs::read_to_string(path).map_err(|source| Error::Io {
        path: path.to_owned(),
        source,
    })
}

#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut hex = String::with_capacity(digest.len() * 2);
    for byte in digest {
        // `write!` rather than `push_str(&format!(..))`: the corpus test hashes
        // about 4 GB, and a temporary `String` per byte is 32 allocations per
        // digest that nothing reads.
        write!(hex, "{byte:02x}").expect("writing to a String cannot fail");
    }
    hex
}

#[must_use]
pub fn sha256_text(text: &str) -> String {
    sha256_hex(text.as_bytes())
}
