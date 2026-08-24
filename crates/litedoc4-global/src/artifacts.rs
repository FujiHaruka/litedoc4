//! The whole-package artifacts, derived from [`ModuleFacts`].
//!
//! **How many there are is [`ARTIFACT_PATHS`]'s answer.** A tenth needs a line in
//! three places: that array, [`Artifacts::files`] and [`Artifacts::derive`].
//!
//! `declarations/name-map.json` is the one with nothing to do with the UI — the
//! incremental pipeline reads it back as `--before` to compute the map delta, so
//! dropping it would leave the delta comparing the new map with nothing and
//! silently re-rendering too little.
//!
//! **Every sort here goes through [`cmp_utf16`]**, including in the files
//! nothing compares against anything: `Vec<String>::sort()` is UTF-8 byte order,
//! which agrees with UTF-16 throughout the BMP and inverts at U+10000 — `𝒜`
//! (U+1D49C) sorts *below* `ﬀ` (U+FB00) in UTF-16 and above it by code point —
//! and a site with two orders in it is a site whose order is nobody's.
//!
//! **`serde_json`'s `preserve_order` is load-bearing**: every JSON object here
//! is built by inserting into a `Map` in explicitly sorted order, and a
//! `BTreeMap` would re-sort by code point, undoing the paragraph above and
//! losing `name-map.json`'s interleaving of declaration and dependency names.
//! The feature is set on the workspace dependency, and the
//! `preserve_order_is_enabled` test fails if it is ever dropped as unused. (Not
//! a link: `#[cfg(test)]` items are invisible to rustdoc.)

use std::collections::{BTreeMap, HashMap, HashSet};

use litedoc4_ir::{DepMap, cmp_utf16};
use litedoc4_render::{SiteConfig, SiteMeta, css_kind};
use serde_json::{Map, Value};

use crate::entry;
use crate::facts::ModuleFacts;
use crate::search_index;

/// The renderer's path rule: dots become directory separators, and the result is
/// a **URL** path, so the separator is `/` on every platform.
///
/// A wrapper around [`litedoc4_ir::page_path`] rather than a second spelling of
/// it, because a disagreement here is not a wrong file but an index pointing at
/// pages that were never written — thousands of dead links that no byte
/// comparison of either side notices.
#[must_use]
pub fn page_path(module: &str) -> String {
    litedoc4_ir::page_path(module)
}

/// Held in memory rather than streamed: the largest is a few hundred kilobytes
/// 【実測】, and having them as values is what lets the tests compare them
/// without a filesystem.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Artifacts {
    pub name_map_json: String,
    pub index_html: String,
    pub not_found_html: String,
    pub search_html: String,
    pub foundational_types_html: String,
    /// What `app.js` draws the module tree and the "Imported by" block from.
    /// Fetched on **every** page, so it carries names and indices and nothing
    /// else.
    pub modules_json: String,
    /// What `app.js` searches, fetched on the first keystroke and never before.
    /// Carries the declarations and the kind vocabulary and nothing else —
    /// module names come from [`Artifacts::modules_json`], which is already on
    /// the page. Bytes rather than JSON: [`crate::search_index`] has the layout
    /// and the reason.
    pub search_index_bin: Vec<u8>,
    /// The two instance maps, fetched only when a reader opens one of the two
    /// `<details>` blocks.
    pub instances_json: String,
    /// **Which declarations of this package mention each of its declarations.**
    ///
    /// A file of its own, fetched only when a reader opens a `Used by` block,
    /// for the reason the instance maps are: it is the largest artifact here
    /// (730 KB on the target 【実測 2026-08-22】) and most readers never open
    /// one.
    ///
    /// Names this package does not declare are **not** keys: a reference into
    /// Mathlib has users here, but this package cannot know how many, so
    /// answering "used by 3" for it would be a wrong number rather than a
    /// partial one.
    pub used_by_json: String,
    /// The delta's `after` side — the same map [`Artifacts::name_map_json`] is
    /// the serialisation of, kept rather than read back off disk.
    ///
    /// A `BTreeMap` rather than an ordered one because nothing reads it in
    /// order: [`crate::delta::Delta`] wants membership and lookup, and does its
    /// own UTF-16 sorting on the way out.
    pub name_map: BTreeMap<String, String>,
    pub counts: Counts,
}

/// What the derivation counted on its way through, for [`crate::GlobalSummary`].
///
/// `the_counts_are_what_the_files_hold` holds these against the files they are
/// about, and **it destructures this struct**, so a field added here with no
/// file to hold it against does not compile. A test that reads the fields it
/// checks by name says nothing about the ones it does not.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    /// Distinct declaration names in the package.
    pub declarations: usize,
    /// Distinct names the dependency slices contribute.
    pub dependency_names: usize,
    /// Keys of `instances.json`'s `instances`.
    pub instance_classes: usize,
    /// Keys of `instances.json`'s `instancesFor`.
    pub instance_types: usize,
    /// Keys of `declarations/used-by.json`.
    pub used_by_targets: usize,
    /// Pairs in it. **Not** the number of references the IR holds: a reference
    /// into a dependency has no key here, and the target package's 54,424
    /// references reduce to 10,163 pairs 【実測 2026-08-22】.
    pub used_by_edges: usize,
}

pub const ARTIFACT_PATHS: [&str; 9] = [
    "declarations/name-map.json",
    "index.html",
    "404.html",
    "search.html",
    "foundational_types.html",
    "modules.json",
    "search-index.bin",
    "instances.json",
    "declarations/used-by.json",
];

impl Artifacts {
    /// **Index order is behaviour, twice.** Two modules declaring the same name
    /// leave the later one in the map, and a module's importer list is built in
    /// it (before being sorted). Passing the facts in any other order is a
    /// different answer.
    #[must_use]
    pub fn derive(
        facts: &[ModuleFacts],
        dep_maps: &[DepMap],
        config: &SiteConfig,
        intro: Option<&str>,
    ) -> Self {
        // name -> (module, kind). Last writer wins, which is why this is fed in
        // index order.
        let mut name_map: HashMap<&str, (&str, &str)> = HashMap::new();
        let mut instances: HashMap<&str, Vec<&str>> = HashMap::new();
        let mut instances_for: HashMap<&str, Vec<&str>> = HashMap::new();
        for facts in facts {
            for (name, kind) in &facts.decls {
                name_map.insert(name, (&facts.module, kind));
            }
            for (class, name) in &facts.instances {
                instances.entry(class).or_default().push(name);
            }
            for (ty, name) in &facts.instances_for {
                instances_for.entry(ty).or_default().push(name);
            }
        }

        let own: HashSet<&str> = facts.iter().map(|facts| facts.module.as_str()).collect();
        let mut imported_by: HashMap<&str, Vec<&str>> =
            own.iter().map(|module| (*module, Vec::new())).collect();
        for facts in facts {
            for import in &facts.imports {
                // Imports of packages outside this one are dropped: the artifact
                // is "who in *this* package imports me".
                if let Some(importers) = imported_by.get_mut(import.as_str()) {
                    importers.push(&facts.module);
                }
            }
        }

        // The module array both files index into. One order, computed once:
        // `modules.json`'s `i` and `search-index.bin`'s module column are
        // subscripts into it, and two orders would be two files agreeing by
        // accident.
        let own_sorted = sorted(own.iter().copied());
        let pages: Vec<(&str, String)> = own_sorted
            .iter()
            .map(|module| (*module, page_path(module)))
            .collect();
        let at: HashMap<&str, usize> = own_sorted
            .iter()
            .enumerate()
            .map(|(i, module)| (*module, i))
            .collect();

        // Later slices overwrite earlier ones.
        let mut deps: HashMap<&str, &str> = HashMap::new();
        for map in dep_maps {
            for (name, module) in &map.declarations {
                deps.insert(name, module);
            }
        }

        let sorted_names = sorted(name_map.keys().copied());
        let dep_names = sorted(deps.keys().copied());

        // The two lists are concatenated *before* sorting, so a name in both
        // appears twice and a declaration always wins over a dependency slice.
        let mut merged: Vec<&str> = sorted_names.clone();
        merged.extend(dep_names.iter().copied());
        merged.sort_by(|a, b| cmp_utf16(a, b));
        let mut flat_map: BTreeMap<String, String> = BTreeMap::new();
        let flat = object(merged.into_iter().map(|name| {
            let module = match name_map.get(name) {
                Some((module, _)) => *module,
                None => deps[name],
            };
            flat_map.insert(name.to_owned(), module.to_owned());
            (name.to_owned(), Value::String(module.to_owned()))
        }));

        let modules_json = Value::Object(
            [(
                "modules".to_owned(),
                Value::Array(
                    pages
                        .iter()
                        .map(|(module, page)| {
                            // Subscripts into this same array, and **the
                            // direction is the whole point**: `i` is who imports
                            // *this* module, so a page's "Imported by" block is a
                            // lookup rather than a scan of every module.
                            let mut importers: Vec<usize> =
                                sorted(imported_by[module].iter().copied())
                                    .into_iter()
                                    .map(|importer| at[importer])
                                    .collect();
                            importers.dedup();
                            Value::Object(
                                [
                                    ("n".to_owned(), Value::String((*module).to_owned())),
                                    ("p".to_owned(), Value::String(page.clone())),
                                    (
                                        "i".to_owned(),
                                        Value::Array(
                                            importers.into_iter().map(index_value).collect(),
                                        ),
                                    ),
                                ]
                                .into_iter()
                                .collect::<Map<String, Value>>(),
                            )
                        })
                        .collect(),
                ),
            )]
            .into_iter()
            .collect::<Map<String, Value>>(),
        );

        // The kind strings as the declaration headers spell them — `css_kind`
        // maps the IR's `definition` to `def` and `class_inductive` to `class` —
        // because a search result whose badge disagrees with the page it leads
        // to is a badge nobody trusts.
        let mut kinds: Vec<&str> = sorted_names
            .iter()
            .map(|name| css_kind(name_map[name].1))
            .collect();
        kinds.sort_by(|a, b| cmp_utf16(a, b));
        kinds.dedup();
        let kind_at: HashMap<&str, usize> = kinds
            .iter()
            .enumerate()
            .map(|(i, kind)| (*kind, i))
            .collect();

        // Every declared name, including the ones no page has an entry for
        // (constructors, and whatever `Suppressed` drops) — the same population
        // `name-map.json` has. Narrowing it here would make the search index and
        // the map two different answers to "what does this package declare".
        let entries: Vec<search_index::Entry<'_>> = sorted_names
            .iter()
            .map(|name| {
                let (module, kind) = name_map[name];
                search_index::Entry {
                    name,
                    kind: kind_at[css_kind(kind)],
                    module: at[module],
                }
            })
            .collect();

        // Inverted **after** `name_map` is complete, because the filter is "does
        // this package declare the target" and that is not known until every
        // module has contributed: a module early in index order refers to names
        // later ones declare.
        let mut used_by: HashMap<&str, Vec<&str>> = HashMap::new();
        for facts in facts {
            for (target, users) in &facts.refs {
                if !name_map.contains_key(target.as_str()) {
                    continue;
                }
                let entry = used_by.entry(target).or_default();
                for &user in users {
                    // Indexed rather than sliced: a hand-edited state file could
                    // put a subscript past the end, and panicking there would be
                    // a crash on corrupt input rather than a diagnosis.
                    if let Some((name, _)) = facts.decls.get(user as usize) {
                        entry.push(name);
                    }
                }
            }
        }

        let instances_out = name_lists(&instances);
        let instances_for_out = name_lists(&instances_for);
        let counts = Counts {
            declarations: sorted_names.len(),
            dependency_names: dep_names.len(),
            instance_classes: instances.len(),
            instance_types: instances_for.len(),
            used_by_targets: used_by.len(),
            // Counted the way the file spells it — after the per-key dedup that
            // `name_lists` does, not before. Two declarations of one module that
            // mention the same name are one user.
            used_by_edges: used_by
                .values()
                .map(|users| {
                    let mut users = users.clone();
                    users.sort_unstable();
                    users.dedup();
                    users.len()
                })
                .sum(),
        };

        // **No `modules` array here.** `modules.json` already carries one, in
        // the same order and with the same subscripts, and `app.js` fetches that
        // file on every page anyway. A second copy is 12.8% of this file 【実測
        // 2026-08-19: 51,975 of 405,402 B】and a second thing to disagree with.
        let search_index_bin = search_index::encode(&entries, &kinds);

        // Their own file because a search never reads either: carried in the
        // index, they made every first keystroke pay for a block most readers
        // never open.
        let instances_json = object([
            ("instances".to_owned(), instances_out),
            ("instancesFor".to_owned(), instances_for_out),
        ]);

        let site = SiteMeta::of(config, intro, own_sorted.iter().copied());
        Self {
            name_map_json: to_json(&flat),
            index_html: entry::index_html(&site, &pages, counts.declarations),
            not_found_html: entry::not_found_html(&site),
            search_html: entry::search_html(&site),
            foundational_types_html: entry::foundational_types_html(&site),
            modules_json: to_json(&modules_json),
            search_index_bin,
            instances_json: to_json(&instances_json),
            used_by_json: to_json(&name_lists(&used_by)),
            name_map: flat_map,
            counts,
        }
    }

    /// Paired with the paths they go to, in [`ARTIFACT_PATHS`] order.
    #[must_use]
    pub fn files(&self) -> [(&'static str, &[u8]); 9] {
        [
            (ARTIFACT_PATHS[0], self.name_map_json.as_bytes()),
            (ARTIFACT_PATHS[1], self.index_html.as_bytes()),
            (ARTIFACT_PATHS[2], self.not_found_html.as_bytes()),
            (ARTIFACT_PATHS[3], self.search_html.as_bytes()),
            (ARTIFACT_PATHS[4], self.foundational_types_html.as_bytes()),
            (ARTIFACT_PATHS[5], self.modules_json.as_bytes()),
            (ARTIFACT_PATHS[6], self.search_index_bin.as_slice()),
            (ARTIFACT_PATHS[7], self.instances_json.as_bytes()),
            (ARTIFACT_PATHS[8], self.used_by_json.as_bytes()),
        ]
    }
}

/// `{ key: [name, …] }` with both levels in UTF-16 order and the names
/// deduplicated.
///
/// **The deduplication is doc-gen4's rule**: it collects each list into an
/// `RBTree`, so an instance whose class application names the same type twice
/// appears once.
fn name_lists(map: &HashMap<&str, Vec<&str>>) -> Value {
    object(sorted(map.keys().copied()).into_iter().map(|key| {
        let mut names = sorted(map[key].iter().copied());
        names.dedup();
        (key.to_owned(), strings(names))
    }))
}

/// Named rather than inlined because it is what the two files' compactness rests
/// on: a module is written out once and referred to by number everywhere else,
/// which is the difference between `modules.json` being fetched on every page
/// and being too big to be.
fn index_value(i: usize) -> Value {
    Value::from(i)
}

fn sorted<'a>(items: impl IntoIterator<Item = &'a str>) -> Vec<&'a str> {
    let mut items: Vec<&str> = items.into_iter().collect();
    items.sort_by(|a, b| cmp_utf16(a, b));
    items
}

/// A JSON object whose key order is the order given.
fn object(pairs: impl IntoIterator<Item = (String, Value)>) -> Value {
    Value::Object(pairs.into_iter().collect::<Map<String, Value>>())
}

fn strings<'a>(items: impl IntoIterator<Item = &'a str>) -> Value {
    Value::Array(
        items
            .into_iter()
            .map(|item| Value::String(item.to_owned()))
            .collect(),
    )
}

fn to_json(value: &Value) -> String {
    serde_json::to_string(value).expect("a tree of objects, arrays and strings serialises")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserve_order_is_enabled() {
        let value = object([
            ("z".to_owned(), Value::Null),
            ("a".to_owned(), Value::Null),
            ("\u{1D49C}".to_owned(), Value::Null),
            ("\u{FB00}".to_owned(), Value::Null),
        ]);
        assert_eq!(
            to_json(&value),
            "{\"z\":null,\"a\":null,\"\u{1D49C}\":null,\"\u{FB00}\":null}",
            "serde_json re-sorted the keys: the `preserve_order` feature is off"
        );
    }

    /// The behaviour `name-map.json` leans on when a name is both declared and
    /// in a dependency slice.
    #[test]
    fn reinserting_a_key_keeps_its_place() {
        let mut map: Map<String, Value> = Map::new();
        map.insert("b".to_owned(), Value::String("1".to_owned()));
        map.insert("a".to_owned(), Value::String("2".to_owned()));
        map.insert("b".to_owned(), Value::String("3".to_owned()));
        assert_eq!(to_json(&Value::Object(map)), "{\"b\":\"3\",\"a\":\"2\"}");
    }

    #[test]
    fn page_paths_are_url_paths() {
        assert_eq!(page_path("Pkg"), "Pkg.html");
        assert_eq!(page_path("Pkg.A.B"), "Pkg/A/B.html");
        assert_eq!(page_path(""), ".html");
    }

    fn facts(module: &str, imports: &[&str]) -> ModuleFacts {
        ModuleFacts {
            module: module.to_owned(),
            content_hash: "0".repeat(16),
            imports: imports.iter().map(|s| (*s).to_owned()).collect(),
            tactics: 0,
            decls: Vec::new(),
            instances: Vec::new(),
            tokens: Vec::new(),
            instances_for: Vec::new(),
            refs: BTreeMap::new(),
        }
    }

    /// Three modules in a chain, so "imports" and "imported by" cannot be
    /// confused for each other by symmetry.
    ///
    /// **The references are load-bearing**: with none of them
    /// `declarations/used-by.json` is `{}`, the two `used_by` counts are 0, and
    /// every assertion about them holds whatever the derivation does. Hence a
    /// target two declarations mention, a target one does, a reference to a name
    /// this package does not declare, and `Pkg.dup` declared by **two** modules
    /// — the only way one target's user list holds the same name twice, and so
    /// the only way the per-key deduplication shows up in a count.
    fn chain() -> Vec<ModuleFacts> {
        let mut root = facts("Pkg", &[]);
        root.decls = vec![("Pkg.a".to_owned(), "definition".to_owned())];
        let mut middle = facts("Pkg.B", &["Pkg"]);
        middle.decls = vec![
            ("Pkg.B.inst".to_owned(), "instance".to_owned()),
            ("Pkg.dup".to_owned(), "theorem".to_owned()),
        ];
        middle.instances = vec![("Cls".to_owned(), "Pkg.B.inst".to_owned())];
        middle.instances_for = vec![
            ("Pkg.a".to_owned(), "Pkg.B.inst".to_owned()),
            ("Pkg.a".to_owned(), "Pkg.B.inst".to_owned()),
        ];
        // Both of this module's declarations mention `Pkg.a`.
        middle.refs = [("Pkg.a".to_owned(), vec![0, 1])].into_iter().collect();
        let mut leaf = facts("Pkg.C", &["Pkg", "Pkg.B"]);
        leaf.decls = vec![
            ("Pkg.C.t".to_owned(), "theorem".to_owned()),
            ("Pkg.dup".to_owned(), "theorem".to_owned()),
        ];
        leaf.refs = [
            // Subscript 1 is this module's `Pkg.dup` — the same *name* as
            // `Pkg.B`'s, so `Pkg.a` is mentioned by it twice.
            ("Pkg.a".to_owned(), vec![1]),
            ("Pkg.B.inst".to_owned(), vec![0]),
            // Declared by a dependency, so it is not a key of the artifact.
            ("Dep.outside".to_owned(), vec![0]),
        ]
        .into_iter()
        .collect();
        vec![root, middle, leaf]
    }

    fn parsed(body: &str) -> Value {
        serde_json::from_str(body).expect("the artifact is JSON")
    }

    /// Getting `modules[].i` backwards renders an "Imported by" block that lists
    /// the module's imports — markup that is well formed, styled, populated and
    /// wrong.
    #[test]
    fn the_module_index_lists_importers_not_imports() {
        let artifacts = Artifacts::derive(&chain(), &[], &SiteConfig::EMPTY, None);
        let json = parsed(&artifacts.modules_json);
        let modules = json["modules"].as_array().expect("an array of modules");
        let names: Vec<&str> = modules
            .iter()
            .map(|m| m["n"].as_str().expect("a name"))
            .collect();
        assert_eq!(names, ["Pkg", "Pkg.B", "Pkg.C"]);
        assert_eq!(modules[0]["p"], "Pkg.html");
        assert_eq!(modules[1]["p"], "Pkg/B.html");

        let importers = |i: usize| -> Vec<&str> {
            modules[i]["i"]
                .as_array()
                .expect("an array of subscripts")
                .iter()
                .map(|at| names[usize::try_from(at.as_u64().expect("a subscript")).expect("fits")])
                .collect()
        };
        // `Pkg` is imported by both of the others; `Pkg.C` imports both and is
        // imported by nobody. The two are not each other's mirror image, which
        // is what makes this test able to fail.
        assert_eq!(importers(0), ["Pkg.B", "Pkg.C"]);
        assert_eq!(importers(1), ["Pkg.C"]);
        assert_eq!(importers(2), Vec::<&str>::new());
    }

    #[test]
    fn the_search_index_is_the_shape_the_script_reads() {
        let artifacts = Artifacts::derive(&chain(), &[], &SiteConfig::EMPTY, None);
        let index = search_index::decode(&artifacts.search_index_bin)
            .expect("a file this crate just wrote");
        // The module array is `modules.json`'s, and only its. The subscripts
        // below index into it from the other file.
        let modules_json = parsed(&artifacts.modules_json);
        let modules = modules_json["modules"].as_array().expect("modules");
        assert_eq!(modules.len(), 3);

        assert_eq!(
            index.labels,
            ["def", "instance", "theorem"],
            "the IR's `definition` reaches the index as the badge the page shows"
        );
        assert_eq!(index.names.len(), index.kind_of.len());
        assert_eq!(index.names.len(), index.modules.len());
        for (kind, module) in index.kind_of.iter().zip(&index.modules) {
            assert!(*kind < index.labels.len());
            assert!(*module < modules.len());
        }
        // `Pkg.B.inst` lives in `Pkg.B`, which is module 1.
        let at = index
            .names
            .iter()
            .position(|name| name == "Pkg.B.inst")
            .expect("the instance is indexed");
        assert_eq!(index.modules[at], 1);
        assert_eq!(index.labels[index.kind_of[at]], "instance");

        let instances = parsed(&artifacts.instances_json);
        assert_eq!(
            instances["instances"]["Cls"],
            serde_json::json!(["Pkg.B.inst"])
        );
        assert_eq!(
            instances["instancesFor"]["Pkg.a"],
            serde_json::json!(["Pkg.B.inst"]),
            "a type named twice by one instance lists it once (doc-gen4's RBTree)"
        );
    }

    /// **Destructured rather than read field by field**, so that a count added
    /// to [`Counts`] stops this test compiling until it is checked here too. A
    /// test that names the fields it reads goes on passing when one is added.
    #[test]
    fn the_counts_are_what_the_files_hold() {
        let artifacts = Artifacts::derive(&chain(), &[], &SiteConfig::EMPTY, None);
        let Counts {
            declarations,
            dependency_names,
            instance_classes,
            instance_types,
            used_by_targets,
            used_by_edges,
        } = artifacts.counts;
        let instances = parsed(&artifacts.instances_json);
        assert_eq!(
            declarations,
            search_index::decode(&artifacts.search_index_bin)
                .expect("a file this crate just wrote")
                .names
                .len()
        );
        assert_eq!(
            instance_classes,
            instances["instances"].as_object().expect("instances").len()
        );
        assert_eq!(
            instance_types,
            instances["instancesFor"]
                .as_object()
                .expect("instancesFor")
                .len()
        );
        assert_eq!(dependency_names, 0);
        assert_eq!(declarations + dependency_names, artifacts.name_map.len());

        // Read off the parsed artifact rather than off `used_by`, because the
        // artifact is what the numbers are about.
        let used_by = parsed(&artifacts.used_by_json);
        let used_by = used_by.as_object().expect("used-by is an object");
        // An empty artifact would let the two assertions below hold with the
        // derivation counting anything at all. `>` rather than `>=` because a
        // target with two users is what makes the deduplication show in a count.
        assert!(
            used_by_edges > used_by_targets && used_by_targets > 0,
            "the fixture's used-by artifact holds these counts to nothing: \
             {used_by_targets} target(s), {used_by_edges} edge(s)"
        );
        assert_eq!(
            used_by_targets,
            used_by.len(),
            "used_by_targets is not the number of keys declarations/used-by.json has"
        );
        assert_eq!(
            used_by_edges,
            used_by
                .values()
                .map(|users| users.as_array().expect("a list of names").len())
                .sum::<usize>(),
            "used_by_edges is not the number of names declarations/used-by.json lists"
        );
    }

    #[test]
    fn the_file_list_and_the_paths_agree() {
        let artifacts = Artifacts::derive(&chain(), &[], &SiteConfig::EMPTY, None);
        let files = artifacts.files();
        assert_eq!(files.len(), ARTIFACT_PATHS.len());
        for (i, (path, body)) in files.iter().enumerate() {
            assert_eq!(*path, ARTIFACT_PATHS[i]);
            assert!(!body.is_empty(), "{path} is empty");
            assert!(!path.starts_with('/') && !path.contains(".."), "{path}");
        }
        let mut paths: Vec<&str> = ARTIFACT_PATHS.to_vec();
        paths.sort_unstable();
        paths.dedup();
        assert_eq!(
            paths.len(),
            ARTIFACT_PATHS.len(),
            "two artifacts share a path"
        );
    }

    /// The five files that existed only for doc-gen4's JavaScript, named so that
    /// bringing one back is a failure rather than a surprise in a deployment.
    #[test]
    fn the_doc_gen4_only_artifacts_are_gone() {
        let artifacts = Artifacts::derive(&chain(), &[], &SiteConfig::EMPTY, None);
        for dropped in [
            "declarations/declaration-data.bmp",
            "navbar.html",
            "tactics.html",
            "references.bib",
            "references.html",
        ] {
            assert!(
                !ARTIFACT_PATHS.contains(&dropped),
                "{dropped} is being written again"
            );
        }
        assert!(
            ARTIFACT_PATHS.contains(&"declarations/name-map.json"),
            "the map delta's `--before` file is not written any more"
        );
        assert!(!artifacts.name_map_json.is_empty());
    }

    #[test]
    fn the_new_files_sort_in_utf16_order_too() {
        let mut above = facts("Pkg.\u{1D49C}", &[]);
        above.decls = vec![("Pkg.\u{1D49C}.a".to_owned(), "definition".to_owned())];
        let mut inside = facts("Pkg.\u{FB00}", &[]);
        inside.decls = vec![("Pkg.\u{FB00}.a".to_owned(), "definition".to_owned())];
        let artifacts = Artifacts::derive(&[inside, above], &[], &SiteConfig::EMPTY, None);
        // The binary index carries its names as UTF-8, so the same search for
        // the two characters answers the same question about it.
        let index = String::from_utf8_lossy(&artifacts.search_index_bin).into_owned();
        for body in [&artifacts.modules_json, &index] {
            let astral = body.find("1D49C").or_else(|| body.find('\u{1D49C}'));
            let ligature = body.find("FB00").or_else(|| body.find('\u{FB00}'));
            assert!(
                astral < ligature,
                "the astral name did not sort first: {body}"
            );
        }
    }
}
