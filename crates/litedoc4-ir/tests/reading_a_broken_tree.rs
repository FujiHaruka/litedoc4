//! The five refusals `litedoc4_ir::Error` names, reached **from an input**
//! rather than constructed by hand.
//!
//! Before this file every variant of that enum was unreachable from
//! `cargo test`: the `Display` bodies ran zero times, and so did the branches
//! in `reader.rs` that build them. That matters more than "an error type is
//! not covered" usually does, because these messages are the whole of what a
//! user is given. `Error::Schema` names the next thing to do
//! (`re-extract with --tagged-code`), and `Error::ModuleMismatch`'s own
//! docstring says an incremental merge that copied the wrong file looks like
//! this — so a test that only checked the variant, and not that the message
//! carries the file and both module names, would leave the useful half
//! unchecked.

use std::error::Error as _;
use std::fs;
use std::path::Path;

use litedoc4_ir::{Error, IrTree, MIN_SCHEMA_VERSION, read_module_file};
use litedoc4_testutil::TempDirs;

const TEMP: TempDirs = TempDirs::prefixed("litedoc4-ir-broken");

const MODULE: &str = "Micro.Basic";

/// `index.json` with as little as the reader accepts, so that what a test
/// changes is the only thing under examination.
fn index_json(schema: u32, ablations: &[&str], entries: &[(&str, &str)]) -> String {
    let ablations: Vec<String> = ablations.iter().map(|a| format!("\"{a}\"")).collect();
    let modules: Vec<String> = entries
        .iter()
        .map(|(module, file)| {
            format!(
                "{{\"module\":\"{module}\",\"file\":\"{file}\",\"bytes\":0,\
                 \"declarations\":0,\"contentHash\":\"0000000000000000\"}}"
            )
        })
        .collect();
    format!(
        "{{\"schemaVersion\":{schema},\"generator\":\"test\",\"leanVersion\":\"4.31.0\",\
         \"hashAlgorithm\":\"lean-string-hash-64/hex16\",\"moduleCount\":{count},\
         \"declarationCount\":0,\"ablations\":[{ablations}],\"modules\":[{modules}],\
         \"dependencyMaps\":[]}}",
        count = entries.len(),
        ablations = ablations.join(","),
        modules = modules.join(","),
    )
}

/// One module file, likewise minimal.
fn module_json(schema: u32, module: &str) -> String {
    format!(
        "{{\"schemaVersion\":{schema},\"module\":\"{module}\",\"imports\":[],\
         \"moduleDocs\":[],\"tactics\":[],\"declarations\":[]}}"
    )
}

/// A tree whose index and whose one module file can be told apart.
fn write_tree(root: &Path, index: &str, module_file: Option<(&str, &str)>) {
    fs::create_dir_all(root.join("modules")).expect("the modules directory");
    fs::write(root.join("index.json"), index).expect("index.json");
    if let Some((name, body)) = module_file {
        fs::write(root.join("modules").join(name), body).expect("the module file");
    }
}

/// The refusal as a user would see it.
fn shown(error: &Error) -> String {
    error.to_string()
}

/// An IR the reader is too new for is refused **by name and by number**, not
/// rendered into a page missing the half the newer keys carry.
#[test]
fn an_index_older_than_the_reader_is_refused_with_both_versions_and_the_way_out() {
    let dir = TEMP.make("old-index");
    let old = MIN_SCHEMA_VERSION - 1;
    write_tree(dir.path(), &index_json(old, &[], &[]), None);

    let error = IrTree::open(dir.path()).expect_err("an old index is refused");
    let Error::Schema {
        what,
        found,
        required,
    } = &error
    else {
        panic!("expected a schema refusal, got {error:?}");
    };
    assert_eq!(what, "index.json");
    assert_eq!(*found, old);
    assert_eq!(*required, MIN_SCHEMA_VERSION);
    let message = shown(&error);
    assert!(
        message.contains("re-extract with --tagged-code"),
        "the refusal says what to do next: {message}"
    );
}

/// An ablated IR is a *refusal marker*: it is deliberately incomplete, and a
/// page made from it would look fine and be wrong. The names have to reach the
/// message, because which ablation was on is what tells the reader whose
/// stopwatch run they picked up.
#[test]
fn an_ablated_index_is_refused_and_names_every_ablation() {
    let dir = TEMP.make("ablated");
    write_tree(
        dir.path(),
        &index_json(MIN_SCHEMA_VERSION, &["no-docstrings", "no-refs"], &[]),
        None,
    );

    let error = IrTree::open(dir.path()).expect_err("an ablated index is refused");
    let Error::Ablated { ablations } = &error else {
        panic!("expected an ablation refusal, got {error:?}");
    };
    assert_eq!(ablations, &["no-docstrings", "no-refs"]);
    let message = shown(&error);
    for ablation in ["no-docstrings", "no-refs"] {
        assert!(message.contains(ablation), "{ablation} is missing: {message}");
    }
    assert!(
        message.contains("stopwatch"),
        "the refusal says what such a tree is for: {message}"
    );
}

/// `open_unvalidated` is the way in for a tool that wants to *look at* a tree
/// `open` refuses. Both refusals have to be the difference between them —
/// otherwise one of the two doors is decoration.
#[test]
fn open_unvalidated_reads_exactly_what_open_refuses() {
    for (what, index) in [
        ("old", index_json(MIN_SCHEMA_VERSION - 1, &[], &[])),
        ("ablated", index_json(MIN_SCHEMA_VERSION, &["no-refs"], &[])),
    ] {
        let dir = TEMP.make(what);
        write_tree(dir.path(), &index, None);
        IrTree::open(dir.path()).expect_err(what);
        let tree = IrTree::open_unvalidated(dir.path()).expect("unvalidated opens it");
        assert_eq!(tree.root(), dir.path());
        assert_eq!(tree.index().modules.len(), 0);
    }
}

/// The mismatch `Error::ModuleMismatch`'s docstring names: an incremental merge
/// that copied the wrong file. **Both** names have to be in the message — one
/// of them alone leaves the reader unable to tell which side moved.
#[test]
fn a_module_file_that_disagrees_with_the_index_names_both_sides() {
    let dir = TEMP.make("mismatch");
    write_tree(
        dir.path(),
        &index_json(
            MIN_SCHEMA_VERSION,
            &[],
            &[(MODULE, "modules/Micro.Basic.json")],
        ),
        Some((
            "Micro.Basic.json",
            &module_json(MIN_SCHEMA_VERSION, "Micro.Other"),
        )),
    );

    let tree = IrTree::open(dir.path()).expect("the index itself is fine");
    let entry = &tree.index().modules[0];
    let error = tree.module(entry).expect_err("the file is not that module");
    let Error::ModuleMismatch {
        path,
        expected,
        found,
    } = &error
    else {
        panic!("expected a module mismatch, got {error:?}");
    };
    assert!(path.ends_with("modules/Micro.Basic.json"), "{path:?}");
    assert_eq!(expected, MODULE);
    assert_eq!(found, "Micro.Other");
    let message = shown(&error);
    assert!(message.contains(MODULE), "{message}");
    assert!(message.contains("Micro.Other"), "{message}");
}

/// **The index's version does not vouch for the modules'.** An incremental tree
/// is a merge of files from several extractor runs, so a new index over an old
/// module file is a real state — and the one this catches.
#[test]
fn a_module_file_older_than_the_reader_is_refused_even_under_a_new_index() {
    let dir = TEMP.make("old-module");
    let old = MIN_SCHEMA_VERSION - 1;
    write_tree(
        dir.path(),
        &index_json(
            MIN_SCHEMA_VERSION,
            &[],
            &[(MODULE, "modules/Micro.Basic.json")],
        ),
        Some(("Micro.Basic.json", &module_json(old, MODULE))),
    );

    let tree = IrTree::open(dir.path()).expect("the index is new enough");
    let error = tree
        .module(&tree.index().modules[0])
        .expect_err("the module file is not");
    let Error::Schema {
        what,
        found,
        required,
    } = &error
    else {
        panic!("expected a schema refusal, got {error:?}");
    };
    assert!(what.ends_with("Micro.Basic.json"), "{what}");
    assert_eq!(*found, old);
    assert_eq!(*required, MIN_SCHEMA_VERSION);

    // The same file through the funnel the merger uses, which has no index to
    // check against: the version refusal is the reader's, not the index's.
    let direct = read_module_file(&dir.path().join("modules/Micro.Basic.json"))
        .expect_err("read_module_file refuses it too");
    assert!(matches!(direct, Error::Schema { .. }), "{direct:?}");
}

/// A build reads 436 files. **An error that does not say which one costs a
/// bisection** — so the path is asserted, and so is the underlying error being
/// kept as `source()` rather than flattened into a string.
#[test]
fn a_file_that_is_not_there_names_the_path_and_keeps_the_io_error() {
    let dir = TEMP.make("no-index");
    let error = IrTree::open(dir.path()).expect_err("there is no index.json");
    let Error::Io { path, .. } = &error else {
        panic!("expected an io failure, got {error:?}");
    };
    assert!(path.ends_with("index.json"), "{path:?}");
    assert!(shown(&error).contains("index.json"), "{}", shown(&error));
    assert!(error.source().is_some(), "the io::Error is kept");
}

/// A JSON file that stops in the middle — a write that was interrupted, which
/// is what a killed run leaves behind.
#[test]
fn a_truncated_file_names_the_path_and_keeps_the_parse_error() {
    let dir = TEMP.make("truncated");
    let whole = index_json(
        MIN_SCHEMA_VERSION,
        &[],
        &[(MODULE, "modules/Micro.Basic.json")],
    );
    write_tree(dir.path(), &whole[..whole.len() / 2], None);

    let error = IrTree::open(dir.path()).expect_err("half a JSON file is not one");
    let Error::Json { path, .. } = &error else {
        panic!("expected a parse failure, got {error:?}");
    };
    assert!(path.ends_with("index.json"), "{path:?}");
    assert!(shown(&error).contains("index.json"), "{}", shown(&error));
    assert!(error.source().is_some(), "the serde_json::Error is kept");
}
