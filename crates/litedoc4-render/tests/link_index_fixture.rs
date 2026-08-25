//! Reads the real `.lidx` of the target package's dependency closure — ~10 MB,
//! written by `litedoc4 build` itself.
//!
//! It lives outside the repository, so this test is `#[ignore]`d rather than
//! silently skipped: `cargo test` has to pass on a machine that has never run
//! the pipeline, and a run that reports it as ignored says out loud that it did
//! not run.
//!
//! **It asserts no entry counts, and must not.** The counts on record —
//! 258,760 entries / 5,775 modules (measured,
//! `benchmarks/results/stage7c-render-timings.jsonl`) — were measured over the
//! prototype's `.lidx`, derived from Mathlib's `declaration-data.bmp` by a
//! generator that exists only at tag `experiments-frozen`. The product derives
//! the same map by **walking the environment** instead: a different
//! construction and so a different tally, 255,809 entries over the same target
//! (measured 2026-08-16). A count here would be a claim about whichever file
//! happens to sit at the path rather than about the reader, so what is checked
//! instead is the reader against the **text** of the file it was handed.

use std::path::PathBuf;
use std::time::Instant;

use litedoc4_render::LinkIndex;
use litedoc4_render::link_index::FORMAT_MARKER;
use litedoc4_testutil::corpus;

/// **`LITEDOC4_M7A_LINK_INDEX` and not `LITEDOC4_LINK_INDEX`**: the variable is
/// the same one, but the default is the file
/// `benchmarks/tools/check-lidx-urls.sh` writes rather than the one the relay
/// directory holds, and this test is coupled to that driver.
fn fixture() -> PathBuf {
    corpus::LITEDOC4_M7A_LINK_INDEX.path()
}

#[test]
#[ignore = "corpus: needs LITEDOC4_LINK_INDEX (tools/corpus-gate.sh)"]
fn reads_the_dependency_closure_of_the_target_package() {
    let path = fixture();
    // The two halves are timed apart because they scale differently: the read
    // with the file's bytes, the parse with its entries.
    let start = Instant::now();
    let text = std::fs::read_to_string(&path).expect("readable");
    let read = start.elapsed();

    let start = Instant::now();
    let index = LinkIndex::parse(&text);
    let elapsed = start.elapsed();
    eprintln!(
        "{}: {} B / {} entries ({} with a line range) / {} modules / {} module names; \
         read {:.3} s, parse {:.3} s",
        path.display(),
        text.len(),
        index.len(),
        index.ranged_len(),
        index.module_count(),
        index.known_modules().len(),
        read.as_secs_f64(),
        elapsed.as_secs_f64(),
    );

    // Either marker is accepted: the reader branches on neither, so what this
    // checks is that the file has one at all.
    let marker = text.split('\n').next().unwrap_or_default();
    assert!(
        marker == FORMAT_MARKER || marker == "#lidx1",
        "format marker: {marker:?}"
    );
    for name in ["Nat.succ", "Nat.add_comm"] {
        let module = index.module_of(name).unwrap_or_else(|| panic!("{name}"));
        assert!(!module.is_empty(), "{name} landed in the empty module");
    }

    // Spot check against the file itself rather than against this reader.
    let (module, name) = last_entry(&text);
    assert_eq!(index.module_of(&name), Some(module.as_str()));
    assert!(
        index.is_known_module("Mathlib.Order.Basic"),
        "a module that is a link target in its own right"
    );
}

/// The final `\t` line of the file, and the group header above it. The name is
/// the first field: a line can carry two more.
fn last_entry(text: &str) -> (String, String) {
    let mut current = String::new();
    let mut last = (String::new(), String::new());
    for line in text.split('\n') {
        match line.as_bytes().first() {
            Some(b'\t') => {
                let name = line[1..].split('\t').next().unwrap_or_default();
                last = (current.clone(), name.to_owned());
            }
            Some(b'@' | b'#') | None => {}
            Some(_) => current = line.to_owned(),
        }
    }
    last
}
