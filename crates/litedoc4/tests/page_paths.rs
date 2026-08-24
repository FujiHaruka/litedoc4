//! Four spellings of one page-path rule, compared here because no other test
//! crate reaches all four: `litedoc4-global`'s manifest names `-ir`, `-md` and
//! `-render`, and nothing in the workspace depends on `litedoc4-incr` except
//! this crate.
//!
//! The three consumers are a writer (the renderer), a remover (`prune`) and an
//! index. A writer and a remover that disagree leave the dead page behind; a
//! writer and an index that disagree are dead links. Neither is visible in a
//! byte comparison of either side, so the agreement has to be asserted rather
//! than observed.
//!
//! `litedoc4_render::page_path` returns a `PathBuf`, so this compares its
//! `to_string_lossy()` — a statement about platforms whose separator is `/`,
//! which is every platform `cargo test` runs on here. Building that `PathBuf`
//! from the `String` would move it to `/` on Windows too, and no test here or
//! in CI would see the difference: that is why the renderer keeps its own
//! construction.

const MODULES: &[&str] = &[
    "Pkg",
    "Pkg.One",
    "Pkg.A.B.C.D",
    "InformationTheory.Shannon.TimeBandLimiting.Count",
    "Pkg.\u{1D49C}",
    "Pkg.A<B&C\"D",
    "Alpha.«Odd-Name»",
    "Alpha.«a.b».C",
    "«..».Foo",
];

#[test]
fn every_spelling_of_the_page_path_is_the_same_rule() {
    for module in MODULES {
        let rule = litedoc4_ir::page_path(module);
        assert_eq!(litedoc4_global::page_path(module), rule, "global: {module}");
        assert_eq!(litedoc4_incr::page_of(module), rule, "incr: {module}");
        assert_eq!(
            litedoc4_render::page_path(module).to_string_lossy(),
            rule,
            "render: {module}"
        );
    }
}

#[test]
fn the_cases_are_not_all_plain_names() {
    let escaped = MODULES.iter().filter(|module| module.contains('«')).count();
    assert!(escaped >= 3, "no escaped component reaches the rule");
    assert!(
        MODULES
            .iter()
            .any(|module| litedoc4_ir::page_path(module).contains("..")),
        "no case reaches the path a `PageRoot` has to refuse"
    );
}
