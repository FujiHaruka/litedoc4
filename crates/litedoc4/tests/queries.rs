//! The five stages that answer a question about a tree without writing a site:
//! `links`, `ownership`, `merge`, `impact` and `prune`.
//!
//! **What is new here is the command line, not the answers.** `litedoc4-incr`'s
//! own tests are the thick ones — they hold the curated branch inventories for
//! `ownership`, `merge`, `impact` and `prune` and compare a corpus run against
//! the frozen prototype. What none of them can reach is the layer
//! `crates/litedoc4/src/queries.rs` adds on top: which flags each subcommand
//! reads, what it prints, which files it writes, and what the shell is then
//! told. So every case below **starts the real binary** and asserts on stdout,
//! stderr and the exit code.
//!
//! Two exits are the reason this file starts a process at all, because neither
//! exists inside the library:
//!
//! - **`Failure::Answered` is exit 1 with an empty stderr.** `merge --verify`
//!   that finds a difference has *answered* the question it was asked; a caller
//!   that read stderr for an error message would be reporting a working
//!   comparison as a broken one.
//! - **`Failure::Refused` is exit 3.** The world and the files disagree — a
//!   module list that does not describe the merged tree, a page name that would
//!   leave `--pages` — and a pipeline that treats that the same as "the disk is
//!   full" retries the wrong thing.
//!
//! # Why the world is built here and not shared with `incremental.rs`
//!
//! `crates/litedoc4/tests/incremental.rs` has a `World` / `write_world` pair
//! that writes an IR tree, and it was the first candidate. It is **not** moved
//! into `tests/common/mod.rs`, for two reasons that are both about what it
//! carries:
//!
//! - It is shaped for the fake extractor and the ledger, not for a question
//!   about an IR tree. `write_world` writes a second copy of every index entry
//!   under `entries/` for the fake extractor to splice, and `ModuleSpec` holds
//!   an `olean` string that exists only so `write_target` can write a
//!   repository for `litedoc4 ledger` to hash. Nothing on this page needs a
//!   repository, an olean or a spliceable entry.
//! - Moving it would put dead code in every binary in this directory.
//!   `mod common;` compiles the whole module into each test binary that
//!   declares it, so `ModuleSpec::olean` would be "never read" here and
//!   `write_ir` below would be "never used" in `build.rs` — and this tree
//!   refuses to silence that: `litedoc4-testutil` pins that the workspace holds
//!   **exactly one** inner `#![allow]`, and `#[expect]` cannot be used for it
//!   because whether an item is dead depends on which binary is compiling it.
//!
//! What is shared instead is the *shape*: the declaration object below has the
//! same keys as `incremental.rs`'s `decl_json` and `litedoc4-incr`'s `decl`,
//! because `litedoc4_ir`'s model is `deny_unknown_fields` and there is exactly
//! one set of keys that parses.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use litedoc4_testutil::TempDirs;
use litedoc4_testutil::cli::{Cli, code, message, stderr, stdout};
use litedoc4_testutil::hash::fnv1a64;
use serde_json::{Value, json};

const TEMP: TempDirs = TempDirs::prefixed("litedoc4-queries");

const LITEDOC4: Cli = Cli::at(env!("CARGO_BIN_EXE_litedoc4"));

// ------------------------------------------------------------------ the world

/// One declaration: its name, and the `(defining module, name)` pairs its IR
/// records as references.
///
/// The pair is what makes `ownership` a stage at all — it is a fact about where
/// a name lives, and it goes stale when the name moves even though nothing
/// about the referring module changed.
struct Decl<'a> {
    name: &'a str,
    refs: &'a [(&'a str, &'a str)],
}

/// One module of the synthetic package.
struct Module<'a> {
    name: &'a str,
    imports: &'a [&'a str],
    decls: &'a [Decl<'a>],
}

/// The package every case below starts from.
///
/// Three relationships are load-bearing, and each is used by a different
/// subcommand:
///
/// - `Pkg.B` **refers to** `Pkg.A.moved` while `Pkg.A` defines it, so
///   re-extracting `Pkg.A` without that declaration makes `Pkg.B` stale through
///   a reference and through nothing else — `ownership`'s whole subject.
/// - `Pkg.B` **imports** `Pkg.A` and `Pkg.C` imports neither, so a change to
///   `Pkg.A` reaches exactly one other module under `--mode importers` and none
///   under `--mode self`. Two modes, one changed set, different answers.
/// - `Pkg.B` refers to `Dep.elsewhere`, which no module of the package defines,
///   so `deps/Dep.json` is non-empty and `merge --verify` has a dependency
///   mapping to compare rather than two empty ones.
fn package() -> Vec<Module<'static>> {
    vec![
        Module {
            name: "Pkg",
            imports: &[],
            decls: &[Decl {
                name: "Pkg.core",
                refs: &[],
            }],
        },
        Module {
            name: "Pkg.A",
            imports: &["Pkg"],
            decls: &[
                Decl {
                    name: "Pkg.A.moved",
                    refs: &[],
                },
                Decl {
                    name: "Pkg.A.stay",
                    refs: &[],
                },
            ],
        },
        Module {
            name: "Pkg.B",
            imports: &["Pkg", "Pkg.A"],
            decls: &[Decl {
                name: "Pkg.B.b",
                refs: &[("Pkg.A", "Pkg.A.moved"), ("Dep.Home", "Dep.elsewhere")],
            }],
        },
        Module {
            name: "Pkg.C",
            imports: &["Pkg"],
            decls: &[Decl {
                name: "Pkg.C.c",
                refs: &[],
            }],
        },
    ]
}

/// `Pkg.A` re-extracted with `Pkg.A.moved` gone: the partial tree a round hands
/// to `ownership` and `merge`.
fn reextracted_a() -> Vec<Module<'static>> {
    vec![Module {
        name: "Pkg.A",
        imports: &["Pkg"],
        decls: &[Decl {
            name: "Pkg.A.stay",
            refs: &[],
        }],
    }]
}

/// One declaration with every key the schema-5 reader requires, and no other:
/// `litedoc4_ir::Decl` is `deny_unknown_fields`, so a spare key is a parse
/// failure rather than a field nobody reads.
fn decl_json(decl: &Decl<'_>) -> Value {
    json!({
        "binderCode": [], "binders": [], "col": 0, "doc": Value::Null,
        "endCol": 1, "endLine": 1, "equationCode": [], "equations": [],
        "implicits": [], "index": 0, "kind": "def", "line": 1, "members": [],
        "modifiers": [], "name": decl.name,
        "refs": decl.refs.iter().map(|(module, name)| json!([module, name])).collect::<Vec<_>>(),
        "type": "Prop", "typeCode": [],
    })
}

/// Writes the IR tree `modules` describes at `root`, the way a full extraction
/// of exactly those modules would leave it.
///
/// The dependency slices are derived rather than declared: a reference whose
/// defining module is not one of `modules` is a dependency, which is the rule
/// `litedoc4_incr::merge` recomputes with. A fixture that listed them by hand
/// could disagree with the merge and the test would be checking the fixture.
fn write_ir(root: &Path, modules: &[Module<'_>]) {
    let own: Vec<&str> = modules.iter().map(|module| module.name).collect();
    let mut index_entries: Vec<Value> = Vec::new();
    let mut declarations = 0usize;
    // name -> defining module, for every reference into something not ours.
    let mut dep: BTreeMap<String, String> = BTreeMap::new();

    for module in modules {
        let file = format!("modules/{}.json", module.name);
        let body = serde_json::to_string(&json!({
            "declarations": module.decls.iter().map(decl_json).collect::<Vec<_>>(),
            "imports": module.imports,
            "module": module.name,
            "moduleDocs": [],
            "schemaVersion": 5,
            "tactics": [],
        }))
        .expect("serialises");
        put(&root.join(&file), body.as_bytes());
        declarations += module.decls.len();
        index_entries.push(json!({
            "bytes": body.len(),
            "contentHash": fnv1a64(body.as_bytes()),
            "declarations": module.decls.len(),
            "file": file,
            "module": module.name,
        }));
        for decl in module.decls {
            for (owner, name) in decl.refs {
                if !own.contains(owner) {
                    dep.insert((*name).to_owned(), (*owner).to_owned());
                }
            }
        }
    }

    let mut by_root: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for (name, module) in &dep {
        by_root
            .entry(module.split('.').next().unwrap_or("").to_owned())
            .or_default()
            .insert(name.clone(), module.clone());
    }
    let mut dependency_maps: Vec<Value> = Vec::new();
    for (package, names) in &by_root {
        let body = serde_json::to_string(&json!({
            "declarations": names, "package": package, "schemaVersion": 5,
        }))
        .expect("serialises");
        let file = format!("deps/{package}.json");
        put(&root.join(&file), body.as_bytes());
        dependency_maps.push(json!({
            "bytes": body.len(), "entries": names.len(),
            "file": file, "package": package,
        }));
    }
    fs::create_dir_all(root.join("deps")).expect("writable");

    put(
        &root.join("index.json"),
        serde_json::to_string(&json!({
            "declarationCount": declarations,
            "dependencyMaps": dependency_maps,
            "generator": "litedoc4/crates/litedoc4/tests/queries.rs",
            "hashAlgorithm": "lean-string-hash-64/hex16",
            "leanVersion": "4.31.0",
            "moduleCount": modules.len(),
            "modules": index_entries,
            "schemaVersion": 5,
        }))
        .expect("serialises")
        .as_bytes(),
    );
}

fn put(path: &Path, body: &[u8]) {
    fs::create_dir_all(path.parent().expect("a parent")).expect("writable");
    fs::write(path, body).expect("writable");
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|source| panic!("{}: {source}", path.display()))
}

/// The lines of stdout that are table rows: `links` separates its columns with
/// tabs and everything else it prints is prose.
fn rows(output: &std::process::Output) -> Vec<Vec<String>> {
    stdout(output)
        .lines()
        .filter(|line| line.contains('\t'))
        .map(|line| line.split('\t').map(str::to_owned).collect())
        .collect()
}

// ------------------------------------------------------------------- `links`

/// A dependency pinned at forty hex digits, because `packages.rs` refuses
/// anything else — a tag or a branch is not a version-pinned link.
const DEP_REV: &str = "89abcdef0123456789abcdef0123456789abcdef";

/// A package with two dependencies on disk: one with a version-pinned URL and
/// one without.
///
/// The second is not a broken fixture — it is the resolver's third state, "a
/// dependency, and there is no URL to link it at". Its roots reach the map with
/// an **empty base** so that pages stop linking into it, and `links` is the one
/// command that can be pointed at the difference.
fn write_repo(repo: &Path) {
    put(
        &repo.join("lake-manifest.json"),
        serde_json::to_string(&json!({
            "version": "1.1.0",
            "packagesDir": ".lake/packages",
            "packages": [
                {
                    "name": "dep", "type": "git",
                    "url": "https://example.invalid/pkg", "rev": DEP_REV,
                },
                {
                    "name": "loose", "type": "git",
                    "url": "https://example.invalid/loose", "rev": "main",
                },
            ],
        }))
        .expect("serialises")
        .as_bytes(),
    );
    put(&repo.join(".lake/packages/dep/Dep.lean"), b"-- a root\n");
    put(
        &repo.join(".lake/packages/loose/Loose.lean"),
        b"-- a root\n",
    );
}

/// A `--lake` whose `lean` is not there.
///
/// `packages::lean_beside` turns `<dir>/lake` into `<dir>/lean`, and Lean core's
/// revision is that program's answer to `--githash`. Pointed at nothing, core
/// contributes no roots and the run **still succeeds**: a partial map renders a
/// partial improvement, and refusing would trade a site with some dead links for
/// no site at all. Naming a real toolchain here would make these cases depend on
/// the machine, which is the line between a test and a gate.
fn lake_that_is_not_there(dir: &Path) -> PathBuf {
    dir.join("no-toolchain/lake")
}

/// The map, printed: one row per root, with the two source columns filled from
/// the renderer's own `url_for`.
///
/// The row that judges the path building is `Dep`'s **deep** one. A root module
/// is a single component, so `Dep` -> `Dep.lean` exercises no dot and no
/// nesting; `Dep.Inner.Deep` -> `Dep/Inner/Deep.lean` does.
#[test]
fn links_prints_a_row_per_root_and_a_deep_sample_only_with_a_link_index() {
    let work = TEMP.make("links-rows");
    let repo = work.path().join("repo");
    write_repo(&repo);
    let lake = lake_that_is_not_there(work.path());
    let lidx = work.path().join("closure.lidx");
    put(&lidx, b"#lidx2\n@Dep\n@Dep.Inner.Deep\n@Loose.Inner\n");

    let bare = LITEDOC4.run(&[
        "links".as_ref(),
        "--root".as_ref(),
        repo.as_os_str(),
        "--lake".as_ref(),
        lake.as_os_str(),
    ]);
    assert_eq!(code(&bare), 0, "{}", stderr(&bare));
    let bare_rows = rows(&bare);
    assert_eq!(
        bare_rows
            .iter()
            .map(|row| row[0].clone())
            .collect::<Vec<_>>(),
        ["Dep", "Loose"],
        "one row per module root, in the manifest's order",
    );
    assert!(
        bare_rows.iter().all(|row| row[3] == "-" && row[4] == "-"),
        "without --link-index there is no module to sample, so both deep columns are `-`: {:?}",
        bare_rows,
    );
    assert!(
        !stdout(&bare).contains("root(s) with a deeper module"),
        "the sampled count is a claim about an index that was not given: {}",
        stdout(&bare),
    );

    let sampled = LITEDOC4.run(&[
        "links".as_ref(),
        "--root".as_ref(),
        repo.as_os_str(),
        "--lake".as_ref(),
        lake.as_os_str(),
        "--link-index".as_ref(),
        lidx.as_os_str(),
    ]);
    assert_eq!(code(&sampled), 0, "{}", stderr(&sampled));
    let by_root = |name: &str| -> Vec<String> {
        rows(&sampled)
            .into_iter()
            .find(|row| row[0] == name)
            .unwrap_or_else(|| panic!("no row for {name} in {}", stdout(&sampled)))
    };
    assert_eq!(
        by_root("Dep"),
        [
            "Dep".to_owned(),
            format!("https://example.invalid/pkg/blob/{DEP_REV}"),
            format!("https://example.invalid/pkg/blob/{DEP_REV}/Dep.lean"),
            "Dep.Inner.Deep".to_owned(),
            format!("https://example.invalid/pkg/blob/{DEP_REV}/Dep/Inner/Deep.lean"),
            "-".to_owned(),
            "-".to_owned(),
        ],
        "the deep sample's dots became slashes; the two documentation columns are empty \
         without --deps-docs-map",
    );
    assert_eq!(
        by_root("Loose"),
        ["Loose", "-", "-", "-", "-", "-", "-"],
        "a root with no version-pinned URL gets no URL in any column, and no deep sample \
         either — that URL would be an absolute path on whoever serves the site",
    );
    assert!(
        stdout(&sampled).contains("external  1/2 root(s) with a deeper module"),
        "only Dep could be sampled — `Loose.Inner` is in the index and its root has no base, \
         so there is no URL to sample with: {}",
        stdout(&sampled),
    );
}

/// `--out` is the same answer as a file, and `--deps-docs-map` is what fills the
/// two documentation columns.
///
/// The columns mirror the source ones **module for module**: one says where a
/// reader of that exact module is sent. A single column that meant the source
/// URL sometimes and the documentation URL other times would be this command
/// reporting two facts in one place.
#[test]
fn links_writes_the_rows_to_out_and_the_documentation_columns_come_from_the_map() {
    let work = TEMP.make("links-out");
    let repo = work.path().join("repo");
    write_repo(&repo);
    let lake = lake_that_is_not_there(work.path());
    let lidx = work.path().join("closure.lidx");
    put(&lidx, b"#lidx2\n@Dep\n@Dep.Inner.Deep\n");
    let map = work.path().join("deps-docs.json");
    put(
        &map,
        serde_json::to_string(&json!({
            "version": 1,
            "roots": [{
                "root": "Dep",
                "base": "https://docs.invalid/dep",
                "requestedNames": 1,
                "declarations": {},
                "modules": {
                    "Dep": "Dep.html",
                    "Dep.Inner.Deep": "Dep/Inner/Deep.html",
                },
            }],
        }))
        .expect("serialises")
        .as_bytes(),
    );
    // Two levels that do not exist: `--out` creates the directories it needs.
    let out = work.path().join("reports/nested/links.json");

    let output = LITEDOC4.run(&[
        "links".as_ref(),
        "--root".as_ref(),
        repo.as_os_str(),
        "--lake".as_ref(),
        lake.as_os_str(),
        "--link-index".as_ref(),
        lidx.as_os_str(),
        "--deps-docs-map".as_ref(),
        map.as_os_str(),
        "--out".as_ref(),
        out.as_os_str(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));

    let dep = rows(&output)
        .into_iter()
        .find(|row| row[0] == "Dep")
        .expect("a row for Dep");
    assert_eq!(
        (dep[5].as_str(), dep[6].as_str()),
        (
            "https://docs.invalid/dep/Dep.html",
            "https://docs.invalid/dep/Dep/Inner/Deep.html"
        ),
        "the two documentation columns mirror the two source ones module for module",
    );
    assert!(
        stdout(&output).contains(
            "external  1/2 root(s) whose own documentation site answers for their root module"
        ),
        "the documented count is printed only with a map, and only Dep has one: {}",
        stdout(&output),
    );

    let record: Value = serde_json::from_str(&read(&out)).expect("--out is JSON");
    assert_eq!(record["roots"], json!(2));
    assert_eq!(record["pinned"], json!(1), "Loose has no URL");
    assert_eq!(record["sampled"], json!(1));
    assert_eq!(record["documented"], json!(1));
    let written = record["rows"]
        .as_array()
        .expect("rows is an array")
        .iter()
        .find(|row| row["root"] == json!("Dep"))
        .expect("a row for Dep")
        .clone();
    assert_eq!(
        (
            written["url"].as_str(),
            written["module"].as_str(),
            written["moduleDocsUrl"].as_str(),
        ),
        (
            Some(dep[2].as_str()),
            Some(dep[3].as_str()),
            Some(dep[6].as_str()),
        ),
        "the file and the table are one answer written twice, not two answers",
    );
}

/// The two refusals `links` words itself.
#[test]
fn links_refuses_a_missing_root_and_a_missing_index() {
    let work = TEMP.make("links-refusals");

    let bare = LITEDOC4.run(&["links"]);
    assert_eq!(code(&bare), 2, "{}", stderr(&bare));
    assert_eq!(message(&bare), "litedoc4: --root <repo> is required");

    // Exit 1 and not 3: a file that will not open is "this run did not finish",
    // which is a different thing to retry from "the world and the files
    // disagree". The refusal names the file so the reader is not left guessing
    // which of the paths on the line was wrong.
    let missing = work.path().join("nowhere.lidx");
    let unreadable = LITEDOC4.run(&[
        "links".as_ref(),
        "--root".as_ref(),
        work.path().as_os_str(),
        "--link-index".as_ref(),
        missing.as_os_str(),
    ]);
    assert_eq!(code(&unreadable), 1, "{}", stderr(&unreadable));
    assert!(
        message(&unreadable).contains("nowhere.lidx"),
        "the refusal names the file: {}",
        message(&unreadable),
    );
}

/// The two arms every one of the five shares, checked on all five at once.
///
/// They are the mechanism `cli::help` and `cli::unknown` exist for, and the
/// reason they exist is that the `--help` arm **had already drifted into three
/// spellings** before there was one function. Written once here rather than
/// five times beside each subcommand's own refusals, so that a sixth spelling
/// cannot appear in whichever of the five nobody looked at.
#[test]
fn every_query_answers_help_with_the_usage_and_refuses_an_unknown_flag_by_name() {
    for subcommand in ["links", "ownership", "merge", "impact", "prune"] {
        for spelling in ["--help", "-h"] {
            let output = LITEDOC4.run(&[subcommand, spelling]);
            assert_eq!(
                code(&output),
                0,
                "{subcommand} {spelling}: {}",
                stderr(&output)
            );
            assert_eq!(
                stdout(&output),
                format!("{}\n", litedoc4::USAGE),
                "{subcommand} {spelling} printed something other than the usage",
            );
        }

        let unknown = LITEDOC4.run(&[subcommand, "--colour"]);
        assert_eq!(code(&unknown), 2, "{subcommand}: {}", stderr(&unknown));
        assert_eq!(
            message(&unknown),
            "litedoc4: unknown argument `--colour`",
            "{subcommand} did not refuse an unknown flag by name",
        );
    }
}

// --------------------------------------------------------------- `ownership`

/// The stage's whole subject, through the command line: `Pkg.A` was
/// re-extracted without `Pkg.A.moved`, so `Pkg.B` — which nothing else touched —
/// is pointing at a name its owner no longer defines.
#[test]
fn ownership_names_the_module_whose_reference_lost_its_owner() {
    let work = TEMP.make("ownership-lost");
    let base = work.path().join("base");
    let inc = work.path().join("inc");
    write_ir(&base, &package());
    write_ir(&inc, &reextracted_a());
    let set = work.path().join("stale.txt");
    let summary = work.path().join("ownership.json");

    let output = LITEDOC4.run(&[
        "ownership".as_ref(),
        "--base".as_ref(),
        base.as_os_str(),
        "--inc".as_ref(),
        inc.as_os_str(),
        "--print-set".as_ref(),
        set.as_os_str(),
        "--json".as_ref(),
        summary.as_os_str(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(
        stdout(&output).starts_with(
            "ownership: 1 name(s) lost, 0 gained across 1 re-extracted module(s) -> 1 module(s) \
             need re-extraction"
        ),
        "the counts line: {}",
        stdout(&output),
    );
    assert!(
        stdout(&output).contains("lostOwner       Pkg.B  (ref Pkg.A :: Pkg.A.moved)"),
        "the witness says which reference gave the module away: {}",
        stdout(&output),
    );
    assert_eq!(
        read(&set),
        "Pkg.B\n",
        "--print-set is the next round's input, and `Pkg.A` is not in it: it was just \
         re-extracted",
    );
    let summary: Value = serde_json::from_str(&read(&summary)).expect("--json is JSON");
    assert_eq!(summary["staleModules"], json!(["Pkg.B"]));
    assert_eq!(summary["lostNames"], json!(1));
}

/// The same mechanism with the other input: a module that is gone lost every
/// name it defined, and `--removed` alone is enough to ask.
///
/// `--inc` is absent here on purpose — a pure deletion re-extracts nothing, so a
/// round that required a partial tree could not ask this question at all.
#[test]
fn ownership_answers_for_a_deletion_with_no_incremental_tree() {
    let work = TEMP.make("ownership-removed");
    let base = work.path().join("base");
    write_ir(&base, &package());
    let removed = work.path().join("removed.txt");
    put(&removed, b"Pkg.A\n");
    let set = work.path().join("stale.txt");

    let output = LITEDOC4.run(&[
        "ownership".as_ref(),
        "--base".as_ref(),
        base.as_os_str(),
        "--removed".as_ref(),
        removed.as_os_str(),
        "--print-set".as_ref(),
        set.as_os_str(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(
        stdout(&output).starts_with("ownership: 2 name(s) lost, 0 gained"),
        "both of Pkg.A's declarations were lost: {}",
        stdout(&output),
    );
    assert_eq!(
        read(&set),
        "Pkg.B\n",
        "the deleted module must not report itself as needing re-extraction",
    );
}

/// Without a tree to diff against and without a deletion list there is no
/// question to answer, and `--base` on its own is not one.
#[test]
fn ownership_refuses_a_base_with_neither_an_inc_tree_nor_a_removal_list() {
    let work = TEMP.make("ownership-refusal");
    let base = work.path().join("base");
    write_ir(&base, &package());

    let output = LITEDOC4.run(&["ownership".as_ref(), "--base".as_ref(), base.as_os_str()]);
    assert_eq!(code(&output), 2, "{}", stderr(&output));
    assert_eq!(
        message(&output),
        "litedoc4: ownership needs --base <ir> and at least one of --inc <ir> / --removed <file>",
    );
}

// ------------------------------------------------------------------- `merge`

/// The fold: the partial tree's module replaces the base's, the base is not
/// written to, and the dependency slice is recomputed from the merged files.
#[test]
fn merge_folds_the_partial_tree_into_out_and_leaves_the_base_alone() {
    let work = TEMP.make("merge-fold");
    let base = work.path().join("base");
    let inc = work.path().join("inc");
    let out = work.path().join("out");
    write_ir(&base, &package());
    write_ir(&inc, &reextracted_a());
    let before = read(&base.join("modules/Pkg.A.json"));

    let output = LITEDOC4.run(&[
        "merge".as_ref(),
        "--base".as_ref(),
        base.as_os_str(),
        "--inc".as_ref(),
        inc.as_os_str(),
        "--out".as_ref(),
        out.as_os_str(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(
        stdout(&output).starts_with("merged 1 module(s) into "),
        "the count line: {}",
        stdout(&output),
    );
    assert!(
        stdout(&output).contains("IR content hash moved for 1 of 1 re-extracted module(s): Pkg.A"),
        "the second line says which module's bytes actually moved: {}",
        stdout(&output),
    );

    assert_eq!(
        read(&base.join("modules/Pkg.A.json")),
        before,
        "the base tree is never written to unless the caller asks for it by name",
    );
    assert_eq!(
        read(&out.join("modules/Pkg.A.json")),
        read(&inc.join("modules/Pkg.A.json")),
        "the merged module file is the partial extraction's, copied",
    );
    assert!(
        !read(&out.join("modules/Pkg.A.json")).contains("Pkg.A.moved"),
        "the declaration that moved away survived the merge",
    );
    let index: Value = serde_json::from_str(&read(&out.join("index.json"))).expect("an index");
    let names: Vec<&str> = index["modules"]
        .as_array()
        .expect("modules is an array")
        .iter()
        .map(|entry| entry["module"].as_str().expect("a name"))
        .collect();
    assert_eq!(names, ["Pkg", "Pkg.A", "Pkg.B", "Pkg.C"]);
    assert_eq!(
        read(&out.join("deps/Dep.json")),
        read(&base.join("deps/Dep.json")),
        "Pkg.B still refers to Dep.elsewhere, so the recomputed slice is the base's",
    );
}

/// A pure deletion, with no `--inc` and no `--out`.
///
/// Two things are being checked and both are about a tree nobody named. **The
/// default `--out` is `<base>.merged`**, so a caller who wanted the base
/// rewritten has to say so by name — a merge that defaulted to the base would
/// destroy the only copy of the tree it was reading. And a deletion needs no
/// partial extraction: a module that is gone was not re-extracted, so requiring
/// `--inc` would make the commonest deletion impossible to express.
#[test]
fn merge_deletes_without_an_inc_tree_and_defaults_out_to_the_base_plus_merged() {
    let work = TEMP.make("merge-remove");
    let base = work.path().join("base");
    write_ir(&base, &package());
    let remove = work.path().join("remove.txt");
    put(&remove, b"Pkg.C\n");
    let default_out = work.path().join("base.merged");

    let output = LITEDOC4.run(&[
        "merge".as_ref(),
        "--base".as_ref(),
        base.as_os_str(),
        "--remove".as_ref(),
        remove.as_os_str(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(
        stdout(&output).starts_with("merged 0 module(s), removed 1 into 3:"),
        "nothing was re-extracted, one module left, three remain: {}",
        stdout(&output),
    );
    assert!(
        stdout(&output).contains(&format!("-> {}", default_out.display())),
        "the default output tree is the base's name plus `.merged`: {}",
        stdout(&output),
    );
    assert!(
        base.join("modules/Pkg.C.json").is_file(),
        "the base tree was written to without being named",
    );
    assert!(
        !default_out.join("modules/Pkg.C.json").exists(),
        "the deleted module's IR file survived into the merged tree",
    );
    let index: Value =
        serde_json::from_str(&read(&default_out.join("index.json"))).expect("an index");
    let names: Vec<&str> = index["modules"]
        .as_array()
        .expect("modules is an array")
        .iter()
        .map(|entry| entry["module"].as_str().expect("a name"))
        .collect();
    assert_eq!(
        names,
        ["Pkg", "Pkg.A", "Pkg.B"],
        "a module that no longer exists has to leave the index, or it keeps a page and \
         keeps feeding names to the global maps",
    );
}

/// `--verify` on two trees written the same way: exit **0**, and the answer is
/// on stdout.
///
/// Two directories rather than one path twice — the comparison is over bytes and
/// index fields, and pointing it at a single tree would pass for a comparator
/// that only checked the argument.
#[test]
fn merge_verify_agrees_on_two_separately_written_trees() {
    let work = TEMP.make("verify-ok");
    let one = work.path().join("one");
    let two = work.path().join("two");
    write_ir(&one, &package());
    write_ir(&two, &package());

    let output = LITEDOC4.run(&[
        "merge".as_ref(),
        "--verify".as_ref(),
        one.as_os_str(),
        "--against".as_ref(),
        two.as_os_str(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(
        stdout(&output).contains("module files byte-identical: 4/4")
            && stdout(&output).contains("dependency map entries: 1 vs 1, mismatches 0")
            && stdout(&output).ends_with("VERIFY OK\n"),
        "the report: {}",
        stdout(&output),
    );
}

/// **`Failure::Answered` — exit 1, and stderr stays empty.**
///
/// The command line was right and the comparison ran; what it found is a "no".
/// A caller that printed this as an error message would be reporting a working
/// comparison as a broken one, so the whole answer is on stdout and the usage
/// is not printed either.
#[test]
fn merge_verify_answers_no_with_exit_1_an_empty_stderr_and_the_report_on_stdout() {
    let work = TEMP.make("verify-differs");
    let base = work.path().join("base");
    let inc = work.path().join("inc");
    let out = work.path().join("out");
    write_ir(&base, &package());
    write_ir(&inc, &reextracted_a());
    let merged = LITEDOC4.run(&[
        "merge".as_ref(),
        "--base".as_ref(),
        base.as_os_str(),
        "--inc".as_ref(),
        inc.as_os_str(),
        "--out".as_ref(),
        out.as_os_str(),
    ]);
    assert_eq!(code(&merged), 0, "{}", stderr(&merged));

    let output = LITEDOC4.run(&[
        "merge".as_ref(),
        "--verify".as_ref(),
        out.as_os_str(),
        "--against".as_ref(),
        base.as_os_str(),
    ]);
    assert_eq!(code(&output), 1, "{}", stderr(&output));
    assert_eq!(
        stderr(&output),
        "",
        "an answer of `no` is not an error message",
    );
    // The four are one module's file plus the three index fields that describe
    // it. They are counted separately on purpose: an index entry that still
    // claims the old byte count is a different fault from a file that changed.
    for line in [
        "FAIL index.bytes Pkg.A: ",
        "FAIL index.declarations Pkg.A: 1 vs 2",
        "FAIL index.contentHash Pkg.A: ",
        "FAIL bytes differ: Pkg.A",
        "module files byte-identical: 3/4",
    ] {
        assert!(
            stdout(&output).contains(line),
            "`{line}` is missing from the report: {}",
            stdout(&output),
        );
    }
    assert!(
        stdout(&output).ends_with("VERIFY FAILED (4 problems)\n"),
        "the last line is the verdict: {}",
        stdout(&output),
    );
}

/// **`Failure::Refused` — exit 3, with the output tree never created.**
///
/// `--modules` is the package's own module list, and the set the merge is about
/// to produce is known before anything is written. A list that does not describe
/// it is the world and the files disagreeing, which is a different thing for a
/// pipeline to retry than a run that could not finish.
#[test]
fn merge_refuses_a_module_list_that_does_not_describe_the_merged_tree_with_exit_3() {
    let work = TEMP.make("merge-list");
    let base = work.path().join("base");
    let inc = work.path().join("inc");
    let out = work.path().join("out");
    write_ir(&base, &package());
    write_ir(&inc, &reextracted_a());
    let modules = work.path().join("modules.txt");
    put(&modules, b"Pkg\nPkg.A\nPkg.B\nPkg.Ghost\n");

    let output = LITEDOC4.run(&[
        "merge".as_ref(),
        "--base".as_ref(),
        base.as_os_str(),
        "--inc".as_ref(),
        inc.as_os_str(),
        "--out".as_ref(),
        out.as_os_str(),
        "--modules".as_ref(),
        modules.as_os_str(),
    ]);
    assert_eq!(code(&output), 3, "{}", stderr(&output));
    assert!(
        message(&output).contains("Pkg.Ghost") && message(&output).contains("Pkg.C"),
        "the refusal names both sides of the disagreement — the list has a module the tree \
         does not, and the tree has one the list does not: {}",
        message(&output),
    );
    assert!(
        !out.exists(),
        "the list is checked before anything is written, so a refused merge leaves no \
         half-updated tree",
    );
}

/// `--verify` is a two-flag question, and half of it is not one.
#[test]
fn merge_refuses_verify_without_against_and_a_base_with_nothing_to_fold() {
    let work = TEMP.make("merge-refusals");
    let base = work.path().join("base");
    write_ir(&base, &package());

    let half = LITEDOC4.run(&["merge".as_ref(), "--verify".as_ref(), base.as_os_str()]);
    assert_eq!(code(&half), 2, "{}", stderr(&half));
    assert_eq!(
        message(&half),
        "litedoc4: merge --verify <ir> needs --against <ir>"
    );

    let alone = LITEDOC4.run(&["merge".as_ref(), "--base".as_ref(), base.as_os_str()]);
    assert_eq!(code(&alone), 2, "{}", stderr(&alone));
    assert_eq!(
        message(&alone),
        "litedoc4: merge needs --base <ir> and at least one of --inc <ir> / --remove <file>",
    );
}

// ------------------------------------------------------------------ `impact`

/// One changed module, two modes, two answers.
///
/// `--mode` is not a preference: `self` is what an olean-hash ledger already
/// knows, and `importers` is the sound transitive bound that also re-renders the
/// pages naming the changed module. A run that returned the same set for both
/// would make one of the two flags a lie.
#[test]
fn impact_selects_the_importers_of_the_changed_module_and_self_alone_under_self() {
    let work = TEMP.make("impact-modes");
    let ir = work.path().join("ir");
    write_ir(&ir, &package());
    let summary_of = |args: &[&std::ffi::OsStr]| -> Value {
        let output = LITEDOC4.run(args);
        assert_eq!(code(&output), 0, "{}", stderr(&output));
        serde_json::from_str(&stdout(&output)).expect("the summary is printed as JSON")
    };

    let importers = summary_of(&[
        "impact".as_ref(),
        "--ir".as_ref(),
        ir.as_os_str(),
        "--changed".as_ref(),
        "Pkg.A".as_ref(),
    ]);
    assert_eq!(importers["mode"], json!("importers"), "the default mode");
    assert_eq!(importers["self"], json!(1));
    assert_eq!(
        importers["importersTransitive"],
        json!(1),
        "Pkg.B imports Pkg.A; Pkg and Pkg.C do not",
    );
    assert_eq!(importers["selected"], json!(2));

    let only_self = summary_of(&[
        "impact".as_ref(),
        "--ir".as_ref(),
        ir.as_os_str(),
        "--changed".as_ref(),
        "Pkg.A".as_ref(),
        "--mode".as_ref(),
        "self".as_ref(),
    ]);
    assert_eq!(only_self["mode"], json!("self"));
    assert_eq!(
        only_self["selected"],
        json!(1),
        "`self` selects the changed module and nothing that imports it",
    );
}

/// The three files: the changed set comes **in** through `--changed-file`, and
/// the selection and the census go **out**.
#[test]
fn impact_reads_the_changed_set_from_a_file_and_writes_the_set_the_census_and_the_summary() {
    let work = TEMP.make("impact-files");
    let ir = work.path().join("ir");
    write_ir(&ir, &package());
    let changed = work.path().join("changed.txt");
    // A comment and a blank line, because the file is written by a previous
    // stage and read by this one — both are dropped rather than being modules.
    put(&changed, b"# the round's changed set\n\nPkg.A\n");
    let set = work.path().join("render.txt");
    let census = work.path().join("census.tsv");
    let summary = work.path().join("impact.json");

    let output = LITEDOC4.run(&[
        "impact".as_ref(),
        "--ir".as_ref(),
        ir.as_os_str(),
        "--changed-file".as_ref(),
        changed.as_os_str(),
        "--print-set".as_ref(),
        set.as_os_str(),
        "--census".as_ref(),
        census.as_os_str(),
        "--json".as_ref(),
        summary.as_os_str(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(
        stdout(&output).contains("census -> ") && stdout(&output).contains("(4 modules)"),
        "the census line names the file and its module count: {}",
        stdout(&output),
    );
    assert_eq!(
        read(&set),
        "Pkg.A\nPkg.B\n",
        "--print-set is what the renderer is then given",
    );
    assert_eq!(
        read(&census).lines().count(),
        5,
        "the census is a header row plus one row per module of the package",
    );
    let summary: Value = serde_json::from_str(&read(&summary)).expect("--json is JSON");
    assert_eq!(
        summary["changed"],
        json!(["Pkg.A"]),
        "the comment and the blank line are not modules",
    );
    assert_eq!(summary["selected"], json!(2));
}

/// An empty changed set writes **no `--print-set` at all**, and prints nothing.
///
/// A missing file is the empty set, and the next stage reads it as one. Writing
/// an empty file instead would be the same answer — but writing a *blank line*
/// would not, and the shape that cannot make that mistake is the one that writes
/// nothing.
#[test]
fn impact_with_nothing_changed_writes_no_print_set_and_says_nothing() {
    let work = TEMP.make("impact-empty");
    let ir = work.path().join("ir");
    write_ir(&ir, &package());
    let set = work.path().join("render.txt");

    let output = LITEDOC4.run(&[
        "impact".as_ref(),
        "--ir".as_ref(),
        ir.as_os_str(),
        "--print-set".as_ref(),
        set.as_os_str(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert_eq!(stdout(&output), "", "there was nothing to report");
    assert!(
        !set.exists(),
        "a file that is there is a claim about what to re-render, and there is none",
    );

    // `--mode all` is the one mode that is valid with an empty changed set: the
    // renderer's own input moved, so no module IR is stale and every page is.
    let all = LITEDOC4.run(&[
        "impact".as_ref(),
        "--ir".as_ref(),
        ir.as_os_str(),
        "--mode".as_ref(),
        "all".as_ref(),
        "--print-set".as_ref(),
        set.as_os_str(),
    ]);
    assert_eq!(code(&all), 0, "{}", stderr(&all));
    assert_eq!(read(&set), "Pkg\nPkg.A\nPkg.B\nPkg.C\n");
}

/// The two refusals: a stage with no tree to read, and a mode nobody recognises.
///
/// The second is **exit 2 rather than 3**, which is the library's own choice —
/// a `--mode` that is not one of the four is a command line to re-read, not a
/// world that disagrees with the files.
#[test]
fn impact_refuses_a_missing_ir_and_an_unrecognised_mode() {
    let work = TEMP.make("impact-refusals");
    let ir = work.path().join("ir");
    write_ir(&ir, &package());

    let bare = LITEDOC4.run(&["impact"]);
    assert_eq!(code(&bare), 2, "{}", stderr(&bare));
    assert_eq!(message(&bare), "litedoc4: --ir is required");

    let bad_mode = LITEDOC4.run(&[
        "impact".as_ref(),
        "--ir".as_ref(),
        ir.as_os_str(),
        "--changed".as_ref(),
        "Pkg.A".as_ref(),
        "--mode".as_ref(),
        "everything".as_ref(),
    ]);
    assert_eq!(code(&bad_mode), 2, "{}", stderr(&bad_mode));
    assert!(
        message(&bad_mode).contains("everything"),
        "the refusal quotes the mode that was given: {}",
        message(&bad_mode),
    );
}

// ------------------------------------------------------------------- `prune`

/// The page tree a deletion is asked of, plus one page no module claims.
fn write_pages(pages: &Path) {
    for page in ["Pkg.html", "Pkg/A.html", "Pkg/B.html", "Pkg/C.html"] {
        put(&pages.join(page), page.as_bytes());
    }
}

/// **`--dry-run` computes the whole answer and writes nothing.**
///
/// This is the third guard, and the only one shaped like a flag: "what would
/// this remove" has to be a question that can be asked of a tree nobody is
/// willing to lose. A dry run that reported nothing would be useless; one that
/// deleted anything would be the opposite of the flag.
#[test]
fn prune_dry_run_reports_the_pages_it_would_delete_and_deletes_none_of_them() {
    let work = TEMP.make("prune-dry");
    let pages = work.path().join("pages");
    write_pages(&pages);
    let remove = work.path().join("remove.txt");
    put(&remove, b"Pkg.A\nPkg.Never\n");

    let output = LITEDOC4.run(&[
        "prune".as_ref(),
        "--pages".as_ref(),
        pages.as_os_str(),
        "--remove".as_ref(),
        remove.as_os_str(),
        "--dry-run".as_ref(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(
        stdout(&output).starts_with(
            "prune-pages (dry run): deleted 1/2 requested, 0 orphan(s), \
                                     0 empty dir(s)"
        ),
        "one of the two had a page; a module deleted before it was ever rendered is not an \
         error: {}",
        stdout(&output),
    );
    for page in ["Pkg.html", "Pkg/A.html", "Pkg/B.html", "Pkg/C.html"] {
        assert!(
            pages.join(page).is_file(),
            "--dry-run deleted {page}, which is the one thing it may not do",
        );
    }
}

/// The real run: the page goes, and so does the directory the deletion emptied.
///
/// The empty directory is harmless to leave — but then the page tree is not
/// equal to a from-scratch one, and byte equality with a from-scratch build is
/// the only oracle this project trusts.
#[test]
fn prune_deletes_the_pages_and_the_directory_the_deletions_emptied() {
    let work = TEMP.make("prune-real");
    let pages = work.path().join("pages");
    write_pages(&pages);
    let remove = work.path().join("remove.txt");
    put(&remove, b"Pkg.A\nPkg.B\nPkg.C\n");

    let output = LITEDOC4.run(&[
        "prune".as_ref(),
        "--pages".as_ref(),
        pages.as_os_str(),
        "--remove".as_ref(),
        remove.as_os_str(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(
        stdout(&output).starts_with(
            "prune-pages: deleted 3/3 requested, 0 orphan(s), 1 empty \
                                     dir(s)"
        ),
        "the count line, with no `(dry run)`: {}",
        stdout(&output),
    );
    assert!(
        !pages.join("Pkg").exists(),
        "the directory the three deletions emptied is still there",
    );
    assert!(
        pages.join("Pkg.html").is_file(),
        "a page nobody asked to remove was deleted",
    );
}

/// `--ir`: a page with no module in the tree is an orphan, and is deleted.
#[test]
fn prune_deletes_a_page_the_ir_no_longer_names() {
    let work = TEMP.make("prune-orphan");
    let ir = work.path().join("ir");
    write_ir(&ir, &package());
    let pages = work.path().join("pages");
    write_pages(&pages);
    put(
        &pages.join("Pkg/Ghost.html"),
        b"a page of a module that left",
    );
    let summary = work.path().join("prune.json");

    let output = LITEDOC4.run(&[
        "prune".as_ref(),
        "--pages".as_ref(),
        pages.as_os_str(),
        "--ir".as_ref(),
        ir.as_os_str(),
        "--json".as_ref(),
        summary.as_os_str(),
    ]);
    assert_eq!(code(&output), 0, "{}", stderr(&output));
    assert!(
        stdout(&output).contains("1 orphan(s)")
            && stdout(&output).contains("  orphan  Pkg/Ghost.html"),
        "the orphan is named, not just counted: {}",
        stdout(&output),
    );
    assert!(!pages.join("Pkg/Ghost.html").exists());
    for page in ["Pkg.html", "Pkg/A.html", "Pkg/B.html", "Pkg/C.html"] {
        assert!(
            pages.join(page).is_file(),
            "{page} has a module in the IR and was deleted anyway",
        );
    }
    let summary: Value = serde_json::from_str(&read(&summary)).expect("--json is JSON");
    assert_eq!(summary["orphans"], json!(1));
    assert_eq!(summary["orphanPages"], json!(["Pkg/Ghost.html"]));
}

/// **Nothing outside `--pages` is ever deleted, and the attempt is exit 3.**
///
/// `«..».Foo` is a legal Lean name — the guillemets are Lean's own escape and
/// their contents are not split on `.` — so it reaches [`page_path`] as
/// `../Foo.html`. No run over the measurement target has ever produced one,
/// which is exactly why the guard needs a test rather than a witness.
#[test]
fn prune_refuses_a_page_name_that_would_leave_the_page_tree_and_deletes_nothing() {
    let work = TEMP.make("prune-escape");
    let pages = work.path().join("pages");
    write_pages(&pages);
    // A sibling of the page tree: what the escaping name resolves to.
    let outside = work.path().join("Foo.html");
    put(&outside, b"not this program's file");
    let remove = work.path().join("remove.txt");
    // The escaping name **first**, so that the run is refused with nothing
    // unlinked yet: the guard is lexical and runs before the path is used for
    // anything, and a list that had already deleted a page by the time it was
    // reached would not show that.
    put(&remove, "«..».Foo\nPkg.A\n".as_bytes());

    let output = LITEDOC4.run(&[
        "prune".as_ref(),
        "--pages".as_ref(),
        pages.as_os_str(),
        "--remove".as_ref(),
        remove.as_os_str(),
    ]);
    assert_eq!(code(&output), 3, "{}", stderr(&output));
    assert!(
        message(&output).contains("../Foo.html"),
        "the refusal names the path that would have left the tree: {}",
        message(&output),
    );
    assert!(
        outside.is_file(),
        "the file outside --pages was deleted, which is the failure this guard exists for",
    );
    assert!(
        pages.join("Pkg/A.html").is_file(),
        "the refusal happened after a deletion the rest of the list asked for",
    );
}

/// A page tree with neither a deletion list nor an IR has nothing to do, and
/// doing nothing quietly is how a deleted module's page survives.
#[test]
fn prune_refuses_a_page_tree_with_nothing_to_delete_by() {
    let work = TEMP.make("prune-refusal");
    let pages = work.path().join("pages");
    write_pages(&pages);

    let output = LITEDOC4.run(&["prune".as_ref(), "--pages".as_ref(), pages.as_os_str()]);
    assert_eq!(code(&output), 2, "{}", stderr(&output));
    assert_eq!(
        message(&output),
        "litedoc4: prune needs --pages <dir> and at least one of --remove <file> / --ir <dir>",
    );
}
