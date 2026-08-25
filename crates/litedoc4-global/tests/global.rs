//! Every expectation in this file was produced by the frozen TypeScript
//! prototype, not by the Rust code it checks. **The fixture
//! (`tests/data/global-expected.json`) is a frozen value and HEAD cannot
//! regenerate it** — the generator and the prototype it drove exist only at tag
//! `experiments-frozen`.
//!
//! Two oracles, because one of them is blind. `cases` ran the prototype **as a
//! program** over synthetic IR trees and record the files it wrote; the byte
//! comparison here is over the intersection with what this crate writes, which
//! is `declarations/name-map.json`. `factCases` called `factsOf` /
//! `autolinkTokens` / `headConst` **sliced out of the same file**, and that is
//! the oracle that sees [`litedoc4_global::facts::ModuleFacts::tokens`]: no
//! artifact carries it, so a port that dropped tokens entirely would pass every
//! byte comparison in the first oracle.
//!
//! Neither stands on the real corpus — that is [`artifacts_match_the_reference`]
//! and [`corpus_facts_match_the_prototype`], both `#[ignore]`d because the
//! corpus is not in this repository. The curated cases exist to reach the
//! corners the corpus has none of, and the fixture records which: fourteen of
//! its thirty-seven branches never fire on the target package (measured,
//! `branchTotals`), among them every branch the UTF-16 sort order depends on.
//!
//! [`artifacts_match_the_reference`]: artifacts_match_the_reference
//! [`corpus_facts_match_the_prototype`]: corpus_facts_match_the_prototype

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::PathBuf;

use litedoc4_global::artifacts::ARTIFACT_PATHS;
use litedoc4_global::facts::{ModuleFacts, PROTOTYPE_FACT_KEYS};
use litedoc4_global::state::State;
use litedoc4_global::{GlobalOptions, build_global, facts_for};
use litedoc4_ir::IrTree;
use litedoc4_testutil::corpus;
use litedoc4_testutil::hash::fnv1a64;
use litedoc4_testutil::{TempDir, TempDirs};
use serde::{Deserialize, Serialize};

/// The prefix names this file, so a directory a failed run leaves behind names
/// what made it.
const TEMP: TempDirs = TempDirs::prefixed("litedoc4-global");

const FIXTURE: &str = include_str!("data/global-expected.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Expected {
    oracle: String,
    ir_modules: usize,
    ir_declarations: usize,
    corpus_facts: CorpusFacts,
    /// `None` when the fixture was generated on a machine with no reference
    /// tree. Committed as `Some`.
    reference: Option<BTreeMap<String, Digest>>,
    /// How often each branch fires in one full run of the target package.
    branch_totals: BTreeMap<String, u64>,
    /// How many curated cases — of either kind — reach each branch.
    curated_branches: BTreeMap<String, u64>,
    /// The branches with a zero in `branch_totals`, as the generator listed
    /// them. Stored as well as derivable so a disagreement is itself a failure.
    never_fires: BTreeSet<String>,
    cases: Vec<Case>,
    fact_cases: Vec<FactCase>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CorpusFacts {
    modules: usize,
    bytes: usize,
    tokens: usize,
    fnv1a64: String,
    /// Module docstrings carrying the `doc` key the prototype reads. **Zero**,
    /// which is why the module docstring branch is dead — see
    /// [`module_docstrings_are_never_tokenised`].
    module_docs_with_doc_key: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Digest {
    bytes: usize,
    fnv1a64: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    what: String,
    /// The counters this case's own IR makes fire.
    branches: Vec<String>,
    /// The IR tree as bytes, keyed by path under its root.
    ir: BTreeMap<String, String>,
    /// The files the prototype wrote, keyed by path under the site root. Most
    /// have no counterpart here any more.
    artifacts: BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FactCase {
    what: String,
    branches: Vec<String>,
    note: Option<String>,
    content_hash: String,
    /// One module file, exactly as the prototype was handed it.
    module: String,
    facts: Facts,
}

/// [`ModuleFacts`] on the wire, in the key order `factsOf` returns it in.
/// [`corpus_facts_match_the_prototype`] re-serialises this to compare digests,
/// so the field order is load-bearing.
#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Facts {
    module: String,
    content_hash: String,
    imports: Vec<String>,
    tactics: usize,
    decls: Vec<(String, String)>,
    instances: Vec<(String, String)>,
    tokens: Vec<String>,
}

impl From<&ModuleFacts> for Facts {
    fn from(facts: &ModuleFacts) -> Self {
        Self {
            module: facts.module.clone(),
            content_hash: facts.content_hash.clone(),
            imports: facts.imports.clone(),
            tactics: facts.tactics,
            decls: facts.decls.clone(),
            instances: facts.instances.clone(),
            tokens: facts.tokens.clone(),
        }
    }
}

fn expected() -> Expected {
    serde_json::from_str(FIXTURE).expect("tests/data/global-expected.json is valid")
}

#[test]
fn fixture_is_the_prototypes_own_output() {
    let e = expected();
    assert!(e.oracle.contains("global.ts"), "{}", e.oracle);
    assert!(e.oracle.contains("run as a program"), "{}", e.oracle);
    assert!(e.oracle.contains("sliced out"), "{}", e.oracle);
    assert!(e.cases.len() >= 8, "only {} artifact cases", e.cases.len());
    assert!(
        e.fact_cases.len() >= 4,
        "only {} fact cases",
        e.fact_cases.len()
    );
}

/// Every artifact this crate **and** the prototype write, byte for byte. The
/// intersection is one file, and it is the one whose bytes another program reads
/// back as `--before`, so a disagreement there still means something.
#[test]
fn every_case_reproduces_the_prototypes_artifacts() {
    let e = expected();
    let shared: Vec<&str> = ARTIFACT_PATHS
        .iter()
        .copied()
        .filter(|path| {
            e.cases
                .iter()
                .all(|case| case.artifacts.contains_key(*path))
        })
        .collect();
    assert_eq!(
        shared,
        ["declarations/name-map.json"],
        "which artifacts the prototype and this crate both write has changed"
    );

    let mut failures = Vec::new();
    let mut compared = 0usize;
    for case in &e.cases {
        let work = TEMP.make(&case.what);
        let got = case.build(&work);
        let want: BTreeMap<String, String> = shared
            .iter()
            .map(|path| ((*path).to_owned(), case.artifacts[*path].clone()))
            .collect();
        let mine: BTreeMap<String, String> = shared
            .iter()
            .map(|path| ((*path).to_owned(), text(&got, path).to_owned()))
            .collect();
        if mine != want {
            failures.push(describe(&case.what, &want, &mine));
        }
        compared += want.len();
    }
    assert!(
        failures.is_empty(),
        "{} of {} cases differ from the prototype:\n{}",
        failures.len(),
        e.cases.len(),
        failures.join("\n")
    );
    assert_eq!(compared, e.cases.len() * shared.len());
}

/// The other side of the same run: every case writes every artifact, and none of
/// the five that existed only for doc-gen4's JavaScript. The dropped five are
/// named rather than counted — "seven files came out" would still pass if
/// `navbar.html` came back and something else went.
#[test]
fn every_case_writes_the_new_artifacts() {
    let e = expected();
    for case in &e.cases {
        let work = TEMP.make(&case.what);
        let got = case.build(&work);
        let written: Vec<&String> = got.keys().collect();
        let mut want: Vec<&str> = ARTIFACT_PATHS.to_vec();
        want.sort_unstable();
        assert_eq!(
            written, want,
            "{}: the site tree is not the seven artifacts",
            case.what
        );
        for dropped in [
            "declarations/declaration-data.bmp",
            "navbar.html",
            "tactics.html",
            "references.bib",
            "references.html",
        ] {
            assert!(
                !got.contains_key(dropped),
                "{}: {dropped} is being written again",
                case.what
            );
        }
    }
}

/// The two JSON indexes as the site's script reads them, over the curated IR
/// trees — including the ones with names above the BMP and names that need
/// escaping, which the unit tests in `src/artifacts.rs` have none of.
#[test]
fn the_indexes_are_well_formed_in_every_case() {
    let e = expected();
    for case in &e.cases {
        let work = TEMP.make(&case.what);
        let got = case.build(&work);
        let read = |path: &str| -> serde_json::Value {
            serde_json::from_str(text(&got, path))
                .unwrap_or_else(|err| panic!("{}: {path}: {err}", case.what))
        };

        let modules = read("modules.json");
        let list = modules["modules"].as_array().expect("an array of modules");
        for module in list {
            assert!(
                module["n"].is_string() && module["p"].is_string(),
                "{}",
                case.what
            );
            for at in module["i"].as_array().expect("an array of subscripts") {
                let at = usize::try_from(at.as_u64().expect("a subscript")).expect("fits");
                assert!(
                    at < list.len(),
                    "{}: a subscript points past the array",
                    case.what
                );
            }
        }

        // The index's module subscript has to index **this** array: a subscript
        // into an array that is no longer beside it is a link to the wrong page,
        // and nothing else would say so.
        let index = litedoc4_global::search_index::decode(&got["search-index.bin"])
            .unwrap_or_else(|| panic!("{}: search-index.bin is not a v2 index", case.what));
        assert_eq!(index.names.len(), index.kind_of.len(), "{}", case.what);
        assert_eq!(index.names.len(), index.modules.len(), "{}", case.what);
        for (kind, module) in index.kind_of.iter().zip(&index.modules) {
            assert!(
                *kind < index.labels.len() && *module < list.len(),
                "{}",
                case.what
            );
        }

        // Every declared name is in the map that names its module, and the
        // subscript agrees with it — what the two files sharing one array buys,
        // checked rather than assumed.
        let name_map = read("declarations/name-map.json");
        for (name, module) in index.names.iter().zip(&index.modules) {
            assert_eq!(
                name_map[name], list[*module]["n"],
                "{}: {name} is indexed under the wrong module",
                case.what
            );
        }

        let instances = read("instances.json");
        for key in ["instances", "instancesFor"] {
            for (_, names) in instances[key].as_object().expect("a map of name lists") {
                assert!(
                    names
                        .as_array()
                        .is_some_and(|names| names.iter().all(serde_json::Value::is_string)),
                    "{}: {key} is not a map of string arrays",
                    case.what
                );
            }
        }
    }
}

#[test]
fn every_fact_case_reproduces_the_prototypes_facts() {
    let e = expected();
    for case in &e.fact_cases {
        let module: litedoc4_ir::ModuleFile = serde_json::from_str(&case.module)
            .unwrap_or_else(|e| panic!("{}: the module file parses: {e}", case.what));
        let got = Facts::from(&ModuleFacts::of(&module, &case.content_hash));
        assert_eq!(got, case.facts, "{}", case.what);
    }
}

/// [`Facts`] is the prototype's seven keys and no others. It is a *projection*
/// onto them, so a new [`ModuleFacts`] field leaves it true, and
/// [`PROTOTYPE_FACT_KEYS`] is where that list is written down once.
///
/// Checked through `serde_json` rather than by reading the struct because it is
/// the *serialised* order that is load-bearing: `#[serde(rename_all)]` and any
/// future `rename` are part of the claim.
#[test]
fn the_shim_is_the_prototypes_keys() {
    let facts = Facts {
        module: String::new(),
        content_hash: String::new(),
        imports: Vec::new(),
        tactics: 0,
        decls: Vec::new(),
        instances: Vec::new(),
        tokens: Vec::new(),
    };
    let value = serde_json::to_value(&facts).expect("the shim serialises");
    let keys: Vec<&str> = value
        .as_object()
        .expect("a struct is an object")
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys, PROTOTYPE_FACT_KEYS,
        "the digest shim and the prototype's key order have parted company"
    );
}

/// The dead branch pinned from both sides: the corpus has no module docstring
/// with the key the prototype reads, and a curated module docstring full of
/// linkable names still yields no token.
#[test]
fn module_docstrings_are_never_tokenised() {
    let e = expected();
    assert_eq!(
        e.corpus_facts.module_docs_with_doc_key, 0,
        "a module docstring now carries the `doc` key the prototype reads: the branch \
         ModuleFacts::of leaves out is no longer dead"
    );

    let case = e
        .fact_cases
        .iter()
        .find(|c| c.what.contains("module docstring"))
        .expect("a fact case covers the module docstring branch");
    let module: litedoc4_ir::ModuleFile =
        serde_json::from_str(&case.module).expect("the module file parses");
    assert!(
        module.module_docs.len() >= 2,
        "the case has to have module docstrings for their absence to mean anything"
    );
    assert!(
        module
            .module_docs
            .iter()
            .any(|doc| doc.text.contains('`') && doc.text.contains("](")),
        "the case's module docstrings have to contain names a fixed version would harvest"
    );
    let facts = ModuleFacts::of(&module, &case.content_hash);
    for token in &facts.tokens {
        assert!(
            !token.starts_with("Mod."),
            "{token:?} came from a module docstring: the transcription was 'fixed'"
        );
    }
    assert_eq!(facts.tokens, case.facts.tokens);
}

/// What the corpus is, pinned so a number quoted elsewhere traces to a run of
/// the generator rather than to a memory of one. Every count is an event of
/// **one full run** of the target package.
#[test]
fn the_corpus_numbers_are_what_was_measured() {
    let e = expected();
    assert_eq!(e.ir_modules, 432);
    assert_eq!(e.ir_declarations, 4_750);
    assert_eq!(
        e.branch_totals,
        BTreeMap::from(
            [
                ("moduleFacts", 432),
                ("moduleWithTactics", 0),
                ("tacticDocs", 0),
                ("moduleWithoutImports", 0),
                ("importOwn", 2_031),
                ("importForeign", 1_904),
                ("moduleDocDropped", 1_515),
                ("moduleDocWithCodeSpan", 759),
                ("declFacts", 4_750),
                ("declWithDoc", 3_394),
                ("declWithoutDoc", 1_356),
                ("declWithEmptyDoc", 0),
                ("docWithCodeSpan", 3_057),
                ("docWithLinkTarget", 1),
                ("tokensTotal", 21_825),
                ("tokenWithDot", 1_295),
                ("tokenEmptyString", 16),
                ("instanceDecl", 91),
                ("instanceWithHeadConst", 91),
                ("instanceWithoutHeadConst", 0),
                ("instanceHeadNotFirstSpan", 0),
                ("namedNonConstSpan", 0),
                ("nameMapOverwrite", 0),
                ("instanceClassFirstSeen", 9),
                ("instanceClassAgain", 82),
                ("moduleImportedByNone", 1),
                ("depMapFiles", 3),
                ("depMapEntries", 533),
                ("depNameAlsoDeclared", 0),
                ("depNameOnly", 533),
                ("topLevelPagePath", 1),
                ("nestedPagePath", 431),
                ("moduleNameNeedsEscaping", 0),
                ("nameAboveBmp", 0),
                ("moduleNameAboveBmp", 0),
                ("runWithoutModules", 0),
                ("runWithoutDepMaps", 0),
            ]
            .map(|(k, n)| (k.to_owned(), n))
        ),
        "the branch profile of the corpus changed"
    );

    // Cross-checks between counters that have to agree by construction.
    assert_eq!(
        e.branch_totals["declWithDoc"] + e.branch_totals["declWithoutDoc"],
        e.ir_declarations as u64
    );
    assert_eq!(
        e.branch_totals["topLevelPagePath"] + e.branch_totals["nestedPagePath"],
        e.ir_modules as u64,
        "every module's page goes somewhere"
    );
    assert_eq!(
        e.branch_totals["instanceWithHeadConst"] + e.branch_totals["instanceWithoutHeadConst"],
        e.branch_totals["instanceDecl"]
    );
    assert_eq!(
        e.branch_totals["instanceClassFirstSeen"] + e.branch_totals["instanceClassAgain"],
        e.branch_totals["instanceWithHeadConst"],
        "every recorded instance lands under a class"
    );
    assert_eq!(
        e.branch_totals["depNameAlsoDeclared"] + e.branch_totals["depNameOnly"],
        e.branch_totals["depMapEntries"]
    );
    assert_eq!(e.corpus_facts.modules, e.ir_modules);
    assert_eq!(
        e.corpus_facts.tokens as u64, e.branch_totals["tokensTotal"],
        "the digest and the profile were taken from different runs"
    );
    // `a.` really does occur: 16 tokens of the corpus are the empty string,
    // which only `push`'s unconditional last component can produce.
    assert!(e.branch_totals["tokenEmptyString"] > 0);
}

#[test]
fn the_curated_cases_cover_what_the_package_does_not() {
    let e = expected();
    let never: BTreeSet<String> = e
        .branch_totals
        .iter()
        .filter(|(_, n)| **n == 0)
        .map(|(k, _)| k.clone())
        .collect();
    assert_eq!(
        never, e.never_fires,
        "the generator and the totals disagree about which branches are dead"
    );
    assert_eq!(
        never,
        BTreeSet::from(
            [
                // Not one name in the package is above the BMP, so a UTF-8 sort
                // anywhere is invisible to all 1.9 MB of real output.
                "nameAboveBmp",
                "moduleNameAboveBmp",
                // The package declares no tactics.
                "moduleWithTactics",
                "tacticDocs",
                // Every instance's printed type has a constant span, and it is
                // always the first one in the array.
                "instanceWithoutHeadConst",
                "instanceHeadNotFirstSpan",
                // The extractor names kind-1 spans and nothing else, so
                // `head_const`'s kind test is load-bearing only in theory.
                "namedNonConstSpan",
                // Every name is declared once, and no dependency slice names
                // something the package declares.
                "nameMapOverwrite",
                "depNameAlsoDeclared",
                // Shapes the extractor never produced here.
                "moduleWithoutImports",
                "moduleNameNeedsEscaping",
                "declWithEmptyDoc",
                // Degenerate runs.
                "runWithoutModules",
                "runWithoutDepMaps",
            ]
            .map(str::to_owned)
        ),
        "which branches the target package never reaches has changed"
    );
    for branch in &never {
        assert!(
            e.curated_branches.get(branch).copied().unwrap_or(0) > 0,
            "{branch} fires nowhere in the corpus and nowhere in the curated cases either"
        );
    }
    let all: BTreeSet<&String> = e.branch_totals.keys().collect();
    let curated: BTreeSet<&String> = e
        .curated_branches
        .iter()
        .filter(|(_, n)| **n > 0)
        .map(|(k, _)| k)
        .collect();
    assert_eq!(all, curated, "the curated cases stopped covering a branch");

    // `curatedBranches` is a tally of the per-case lists, so recompute it: a
    // summary that is not what it summarises is how a coverage claim rots.
    let mut tally: BTreeMap<String, u64> = BTreeMap::new();
    let per_case = e
        .cases
        .iter()
        .map(|case| &case.branches)
        .chain(e.fact_cases.iter().map(|case| &case.branches));
    for branches in per_case {
        for branch in branches {
            assert!(
                e.branch_totals.contains_key(branch),
                "case claims {branch}, which is not a counter"
            );
            *tally.entry(branch.clone()).or_default() += 1;
        }
    }
    assert_eq!(
        tally, e.curated_branches,
        "the tally and the per-case lists disagree"
    );
}

/// The sample has to keep reaching every shape, read off the **fixture's own
/// bytes** rather than off anything this crate produced: what is under test is
/// whether the curated IR trees reach a shape, and the prototype's output over
/// those trees is the record of it. Four of the five files read here are ones
/// this crate no longer writes, which is why the paths are spelled out rather
/// than taken from `ARTIFACT_PATHS`. The same shapes are asked of this crate's
/// own output by [`the_new_artifacts_reach_every_shape`].
///
/// [`the_new_artifacts_reach_every_shape`]: the_new_artifacts_reach_every_shape
#[test]
fn the_sample_reaches_every_shape() {
    let e = expected();
    let bmp = |what: &str, p: &dyn Fn(&str) -> bool| {
        any_artifact(&e.cases, "declarations/declaration-data.bmp", what, p);
    };
    let names = |what: &str, p: &dyn Fn(&str) -> bool| {
        any_artifact(&e.cases, "declarations/name-map.json", what, p);
    };
    let navbar = |what: &str, p: &dyn Fn(&str) -> bool| {
        any_artifact(&e.cases, "navbar.html", what, p);
    };
    let tactics = |what: &str, p: &dyn Fn(&str) -> bool| {
        any_artifact(&e.cases, "tactics.html", what, p);
    };

    // 𝒜 (U+1D49C) has to come out **before** ﬀ (U+FB00) everywhere.
    let astral_first = |body: &str| match (body.find('\u{1D49C}'), body.find('\u{FB00}')) {
        (Some(astral), Some(ligature)) => astral < ligature,
        _ => false,
    };
    bmp(
        "a name above the BMP sorted before one inside it",
        &astral_first,
    );
    names(
        "a name above the BMP sorted before one inside it",
        &astral_first,
    );
    navbar(
        "a module name above the BMP sorted before one inside it",
        &astral_first,
    );

    bmp("no declarations at all", &|body| {
        body.starts_with("{\"declarations\":{},")
    });
    bmp("an instance list", &|body| {
        body.contains("\"instances\":{\"Cls.B\":[\"Pkg.Inst.alsoB\",\"Pkg.Inst.reordered\"]")
    });
    bmp("an instance dropped for want of a head constant", &|body| {
        body.contains("Pkg.Inst.noConst") && !body.contains("[\"Pkg.Inst.noConst\"]")
    });
    bmp("an importedBy list", &|body| {
        body.contains("\"importedBy\":[\"Pkg.Deep.Down.Here\"]")
    });
    bmp("a duplicated name resolved to the later module", &|body| {
        body.contains(
            "\"Pkg.shared\":{\"docLink\":\"./Pkg/Second.html#Pkg.shared\",\"kind\":\"def\"}",
        )
    });
    names("a declaration beating a dependency slice", &|body| {
        body.contains("\"Shared.name\":\"Pkg.One\"")
    });
    names("a later dependency slice beating an earlier one", &|body| {
        body.contains("\"Dep.only\":\"Dep2.Wins\"")
    });
    // The apostrophe stays raw: `Html.escape` does not touch it, and every
    // general-purpose HTML escaper does.
    navbar("a module name that needs escaping", &|body| {
        body.contains(
            "<li><a href=\"./Pkg/A&lt;B&amp;C&quot;D'E.html\">Pkg.A&lt;B&amp;C&quot;D'E</a></li>",
        )
    });
    navbar("no modules at all", &|body| body.contains("<ul></ul>"));
    tactics("a package that declares tactics", &|body| {
        body.contains("(3 tactic docstrings across 3 modules)")
    });
    tactics("no modules at all", &|body| {
        body.contains("(0 tactic docstrings across 0 modules)")
    });

    let tokens: Vec<&String> = e
        .fact_cases
        .iter()
        .flat_map(|c| c.facts.tokens.iter())
        .collect();
    assert!(
        tokens.iter().any(|t| t.is_empty()),
        "no fact case has the empty token a part ending in a dot produces"
    );
    assert!(
        tokens.iter().any(|t| *t == "Bar.baz"),
        "no fact case tokenises a markdown link target"
    );
    assert!(
        e.fact_cases.iter().any(|c| c.note.is_some()),
        "the recorded disagreement lost its note"
    );
}

/// The same corners on **this crate's own output**: a case that reaches a shape
/// and an artifact that does nothing with it is the failure this pins.
#[test]
fn the_new_artifacts_reach_every_shape() {
    let e = expected();
    let mut astral = 0usize;
    let mut escaped = 0usize;
    let mut empty = 0usize;
    let mut instances = 0usize;
    let mut imported_by = 0usize;

    for case in &e.cases {
        let work = TEMP.make(&case.what);
        let got = case.build(&work);
        let modules: serde_json::Value =
            serde_json::from_str(text(&got, "modules.json")).expect("modules.json is JSON");
        // The index is bytes now; its names are UTF-8 inside it, which is all
        // the two questions below ask about.
        let index = String::from_utf8_lossy(&got["search-index.bin"]).into_owned();
        let names: Vec<&str> = modules["modules"]
            .as_array()
            .expect("modules")
            .iter()
            .map(|m| m["n"].as_str().expect("a name"))
            .collect();
        let front = text(&got, "index.html");

        // `𝒜` (U+1D49C) sorts *below* `ﬀ` (U+FB00) in UTF-16 and above it by
        // code point, in the array and on the page alike.
        let order = |body: &str| match (body.find('\u{1D49C}'), body.find('\u{FB00}')) {
            (Some(a), Some(b)) => Some(a < b),
            _ => None,
        };
        for body in [text(&got, "modules.json"), index.as_str(), front] {
            if let Some(first) = order(body) {
                assert!(first, "a name above the BMP did not sort first: {body}");
                astral += 1;
            }
        }
        // `Html.escape` covers `& < > "` and leaves `'` alone, and the module
        // list on the front page is HTML while the two indexes are not.
        if names.iter().any(|n| n.contains('<')) {
            assert!(
                front.contains("&lt;") && front.contains("&amp;") && front.contains("&quot;"),
                "a module name that needs escaping reached index.html raw: {front}"
            );
            escaped += 1;
        }
        if names.is_empty() {
            assert!(
                front.contains("<ul class=\"modlist\"></ul>"),
                "a package with no modules did not produce an empty list: {front}"
            );
            assert!(
                litedoc4_global::search_index::decode(&got["search-index.bin"])
                    .expect("a v2 index")
                    .names
                    .is_empty(),
                "a package with no modules indexed a declaration"
            );
            empty += 1;
        }
        let instance_maps: serde_json::Value =
            serde_json::from_str(text(&got, "instances.json")).expect("instances.json is JSON");
        if instance_maps["instances"]
            .as_object()
            .is_some_and(|map| !map.is_empty())
        {
            instances += 1;
        }
        if modules["modules"]
            .as_array()
            .expect("modules")
            .iter()
            .any(|m| !m["i"].as_array().expect("subscripts").is_empty())
        {
            imported_by += 1;
        }
    }

    for (what, seen) in [
        ("a name above the BMP", astral),
        ("a module name that needs escaping", escaped),
        ("a package with no modules", empty),
        ("an instance list", instances),
        ("an importer list", imported_by),
    ] {
        assert!(seen > 0, "no case reaches {what} in the new artifacts");
    }
}

/// The sizes the committed fixture records for the reference tree's six files,
/// pinned **whether or not the corpus is on this machine**. Split out of
/// [`artifacts_match_the_reference`], which needs the reference tree and is
/// therefore `#[ignore]`d, so that the numbers keep being checked on a machine
/// that has never seen the target package.
///
/// [`artifacts_match_the_reference`]: artifacts_match_the_reference
#[test]
fn the_recorded_reference_sizes_are_pinned_without_the_corpus() {
    let e = expected();
    let recorded = e
        .reference
        .as_ref()
        .expect("the committed fixture pins the real artifacts");
    assert_eq!(
        recorded["declarations/declaration-data.bmp"].bytes,
        1_216_017
    );
    assert_eq!(recorded["declarations/name-map.json"].bytes, 602_729);
    assert_eq!(recorded["navbar.html"].bytes, 57_949);
    assert_eq!(recorded["tactics.html"].bytes, 243);
    assert_eq!(recorded["references.bib"].bytes, 0);
    assert_eq!(recorded["references.html"].bytes, 186);
}

/// The artifacts of the target package that the prototype also writes, against
/// the files it wrote. Asserting the recorded size of each file first is what
/// says the reference tree on this machine is still the one the fixture came
/// from.
#[test]
#[ignore = "corpus: needs LITEDOC4_REFERENCE_GLOBAL + LITEDOC4_IR (tools/corpus-gate.sh)"]
fn artifacts_match_the_reference() {
    let e = expected();
    let recorded = e
        .reference
        .as_ref()
        .expect("the committed fixture pins the real artifacts");
    let reference = corpus_reference();
    let ir = corpus_ir();

    let work = TEMP.make("reference");
    let summary = build_global(&GlobalOptions::new(&ir, work.path())).expect("the corpus builds");
    assert_eq!(summary.modules, e.ir_modules);
    assert_eq!(summary.declarations, e.ir_declarations);
    assert_eq!(
        summary.dependency_names as u64,
        e.branch_totals["depMapEntries"]
    );
    assert_eq!(
        summary.instance_classes as u64,
        e.branch_totals["instanceClassFirstSeen"]
    );
    assert_eq!(summary.tactic_docs, 0);
    // The 91 instances of this package name 88 distinct types between them, and
    // each of the 59 that doc-gen4's own reference tree also has agrees with its
    // `instancesFor` entry exactly (measured 2026-08-16).
    assert_eq!(summary.instance_types, 88);

    let shared = ["declarations/name-map.json"];
    assert!(
        shared.iter().all(|path| ARTIFACT_PATHS.contains(path)),
        "the shared artifact is not one this crate writes"
    );
    for path in shared {
        let want = fs::read(reference.join(path)).expect("the reference artifact reads");
        let got = fs::read(work.path().join(path)).expect("the artifact was written");
        assert_eq!(
            recorded[path].bytes,
            want.len(),
            "{path}: the reference tree is not the one the fixture was taken from"
        );
        assert_eq!(fnv1a64(&want), recorded[path].fnv1a64, "{path}");
        assert_eq!(
            got.len(),
            want.len(),
            "{path}: {} bytes against the prototype's {}",
            got.len(),
            want.len()
        );
        assert!(
            got == want,
            "{path} differs from the prototype at byte {}",
            got.iter()
                .zip(&want)
                .position(|(a, b)| a != b)
                .unwrap_or(got.len())
        );
    }
}

/// The per-module facts over the whole corpus against the prototype's own
/// `factsOf` — [`ModuleFacts::tokens`] on 3,394 real docstrings rather than on
/// four curated ones. The two counts beside the digest are what a digest cannot
/// say when it disagrees.
#[test]
#[ignore = "corpus: needs LITEDOC4_IR (tools/corpus-gate.sh)"]
fn corpus_facts_match_the_prototype() {
    let e = expected();
    let ir = corpus_ir();
    let tree = IrTree::open(&ir).expect("the corpus opens");
    // No cache: this is the from-scratch read, so every module is a miss.
    let run = facts_for(&tree, &State::empty()).expect("the corpus reads");
    let facts = run.facts;
    assert_eq!(facts.len(), e.corpus_facts.modules);
    assert_eq!(run.cache_hits, 0);
    assert_eq!(run.cache_misses, facts.len());

    let lines: Vec<String> = facts
        .iter()
        .map(|facts| serde_json::to_string(&Facts::from(facts)).expect("the facts serialise"))
        .collect();
    let text = lines.join("\n");
    let tokens: usize = facts.iter().map(|facts| facts.tokens.len()).sum();
    assert_eq!(tokens, e.corpus_facts.tokens, "the token count moved");
    assert_eq!(
        text.len(),
        e.corpus_facts.bytes,
        "the serialised facts are a different size than the prototype's"
    );
    assert_eq!(
        fnv1a64(text.as_bytes()),
        e.corpus_facts.fnv1a64,
        "the facts differ from the prototype's somewhere in {} bytes",
        text.len()
    );
}

/// The generated IR of the target package, or a panic naming what to set.
///
/// Every caller is `#[ignore]`d, so reaching this at all means the corpus gate
/// asked for the test by name. Returning "not here, never mind" would be a green
/// result for a comparison that never ran.
fn corpus_ir() -> PathBuf {
    corpus::LITEDOC4_IR.path()
}

/// The reference tree the frozen prototype wrote, or a panic naming what to set.
fn corpus_reference() -> PathBuf {
    corpus::LITEDOC4_REFERENCE_GLOBAL.path()
}

fn any_artifact(cases: &[Case], path: &str, what: &str, predicate: &dyn Fn(&str) -> bool) {
    assert!(
        cases
            .iter()
            .filter_map(|case| case.artifacts.get(path))
            .any(|body| predicate(body)),
        "no {path} with {what}"
    );
}

impl Case {
    /// Reads back **the whole site tree** rather than [`ARTIFACT_PATHS`]: a file
    /// this crate stopped writing has to be absent, and a list of the files it
    /// does write cannot tell "gone" from "never looked for".
    fn build(&self, work: &TempDir) -> BTreeMap<String, Vec<u8>> {
        let ir = work.path().join("ir");
        for (name, text) in &self.ir {
            let path = ir.join(name);
            fs::create_dir_all(path.parent().expect("every IR file is under the root"))
                .expect("the temporary tree is writable");
            fs::write(&path, text).expect("the temporary tree is writable");
        }
        let site = work.path().join("site");
        build_global(&GlobalOptions::new(&ir, &site))
            .unwrap_or_else(|e| panic!("{}: {e}", self.what));

        let mut out = BTreeMap::new();
        read_tree(&site, "", &mut out);
        out
    }
}

fn text<'a>(got: &'a BTreeMap<String, Vec<u8>>, path: &str) -> &'a str {
    let body = got
        .get(path)
        .unwrap_or_else(|| panic!("{path} was not written"));
    std::str::from_utf8(body).unwrap_or_else(|_| panic!("{path} is not UTF-8"))
}

/// Every file under `dir`, keyed by its `/`-separated path beneath it.
fn read_tree(dir: &PathBuf, prefix: &str, out: &mut BTreeMap<String, Vec<u8>>) {
    for entry in fs::read_dir(dir)
        .expect("the site tree is readable")
        .flatten()
    {
        let name = entry.file_name().to_string_lossy().into_owned();
        let relative = if prefix.is_empty() {
            name
        } else {
            format!("{prefix}/{name}")
        };
        if entry.file_type().expect("a file type").is_dir() {
            read_tree(&entry.path(), &relative, out);
        } else {
            // Bytes, not text: `search-index.bin` is not UTF-8, and reading it
            // as a string would panic before any test could say anything.
            out.insert(
                relative,
                fs::read(entry.path()).expect("the artifact is readable"),
            );
        }
    }
}

fn describe(what: &str, want: &BTreeMap<String, String>, got: &BTreeMap<String, String>) -> String {
    let mut lines = vec![what.to_owned()];
    // The `collect` is not needless: `chain` yields a path present in both maps
    // twice, so iterating it directly reports every shared path a second time in
    // the message a failing assertion prints.
    #[expect(clippy::needless_collect, reason = "deduplicates the two key sets")]
    for path in want.keys().chain(got.keys()).collect::<BTreeSet<_>>() {
        match (want.get(path), got.get(path)) {
            (Some(a), Some(b)) if a == b => {}
            (Some(a), Some(b)) => {
                let at = a
                    .bytes()
                    .zip(b.bytes())
                    .position(|(x, y)| x != y)
                    .unwrap_or_else(|| a.len().min(b.len()));
                let from = at.saturating_sub(80);
                lines.push(format!(
                    "  {path} differs at byte {at}\n    want: …{}\n    got:  …{}",
                    &a[floor_char(a, from)..floor_char(a, (at + 120).min(a.len()))],
                    &b[floor_char(b, from)..floor_char(b, (at + 120).min(b.len()))],
                ));
            }
            (Some(_), None) => lines.push(format!("  {path} was not written")),
            (None, Some(_)) => lines.push(format!("  {path} should not exist")),
            (None, None) => unreachable!(),
        }
    }
    lines.join("\n")
}

/// The nearest char boundary at or below `at`, so slicing an artifact for a
/// failure message cannot itself panic.
fn floor_char(s: &str, mut at: usize) -> usize {
    while at > 0 && !s.is_char_boundary(at) {
        at -= 1;
    }
    at
}
