//! One rule, four spellings — and this is the only crate that can see all of
//! them.
//!
//! `litedoc4_ir::page_path` is the rule. `litedoc4_global::page_path` and
//! `litedoc4_incr::page_of` are wrappers over it, and
//! `litedoc4_render::page_path` builds the same path a second way, out of
//! `module_components` and into a `PathBuf`.
//!
//! **The three consumers are a writer, a remover and an index.** The renderer
//! writes `<pages>/<page>`; `prune` deletes it; the whole-package artifacts
//! link to it. A writer and a remover that disagree make `prune` report
//! "already absent" and leave the dead page behind — the failure M5-b hit. A
//! writer and an index that disagree are 4,750 dead links. **Neither is
//! visible in a byte comparison of either side**, so the agreement has to be
//! asserted rather than observed.
//!
//! It is asserted *here* because no other test crate reaches all three:
//! `litedoc4-global`'s manifest names `-ir`, `-md` and `-render`, and nothing
//! in the workspace depends on `litedoc4-incr` except this crate. Adding a
//! dev-dependency to widen the old two-way test would have been a dependency
//! bought for a test — this file costs none.
//!
//! The renderer's half is a `PathBuf`, so this compares its
//! `to_string_lossy()`. That makes the comparison a statement about platforms
//! whose separator is `/`, which is every platform `cargo test` runs on here
//! (`ci.yml`'s ubuntu-latest). Changing the renderer to build its `PathBuf`
//! from the `String` would move it to `/` on Windows too — and no test on this
//! machine or in CI would see the difference, which is why the renderer keeps
//! its own construction.

/// Module names that exercise every branch the rule has: a bare name, a
/// dotted one, the target package's real shape, a name above the BMP, one full
/// of characters HTML escapes, an escaped component holding a dot, and the
/// escaped component that spells a parent directory【実測 2026-08-23】.
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

/// The cases above are only worth their runtime if they are not all the same
/// case: without this, a list that had quietly collapsed to nine plain names
/// would still pass the test above.
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
