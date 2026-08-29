//! The whole-package map delta: which pages a moved name makes stale.
//!
//! `--print-set` is the input to the incremental impact analysis. A module
//! missing from it keeps a page that links a name to the module it used to live
//! in, and **nothing downstream notices** — the site builds, every page is
//! well-formed, and the link is wrong; over-reporting only costs a re-render. So
//! both halves of this file err wide on purpose:
//! [`crate::facts::autolink_tokens`] over-approximates, and `changed` is taken
//! over the **union** of the two key sets, so that a name present on only one
//! side counts as a change.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use litedoc4_ir::cmp_utf16;
use serde::Serialize;

use crate::facts::ModuleFacts;

const WITNESS_LIMIT: usize = 20;

const CHANGED_SAMPLE: usize = 20;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Delta {
    pub before_names: usize,
    pub after_names: usize,
    /// Every name whose module differs between the two maps, **sorted in UTF-16
    /// code unit order**.
    pub changed: Vec<String>,
    /// The modules to re-render, sorted in UTF-16 code unit order.
    pub affected: Vec<String>,
    /// One token per affected module, for the first [`WITNESS_LIMIT`] of them in
    /// **index order** — diagnostics, not a contract. The token is the first of
    /// the module's sorted, deduplicated tokens that is in `changed`, which is
    /// not in general the first one its docstrings produced.
    pub witnesses: Vec<Witness>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Witness {
    pub module: String,
    pub name: String,
}

impl Delta {
    /// `before` is the map on disk, `after` **this run's map** rather than a
    /// re-read of `name-map.json`. `facts` must be in index order — that is the
    /// order `witnesses` is filled in.
    #[must_use]
    pub fn compute(
        before: &BTreeMap<String, String>,
        after: &BTreeMap<String, String>,
        facts: &[ModuleFacts],
    ) -> Self {
        let changed = Self::changed(before, after);
        Self::scan(before.len(), after.len(), changed, facts)
    }

    /// Split out of [`Delta::compute`] only so that the caller can time the two
    /// halves separately; they are one operation.
    #[must_use]
    pub fn changed(
        before: &BTreeMap<String, String>,
        after: &BTreeMap<String, String>,
    ) -> Vec<String> {
        let mut changed: BTreeSet<&str> = BTreeSet::new();
        for name in before.keys().chain(after.keys()) {
            if before.get(name) != after.get(name) {
                changed.insert(name);
            }
        }
        let mut changed: Vec<String> = changed.into_iter().map(str::to_owned).collect();
        changed.sort_by(|a, b| cmp_utf16(a, b));
        changed
    }

    /// The modules whose docstrings mention a changed name, scanned in index
    /// order.
    #[must_use]
    pub fn scan(
        before_names: usize,
        after_names: usize,
        changed: Vec<String>,
        facts: &[ModuleFacts],
    ) -> Self {
        let mut affected: Vec<String> = Vec::new();
        let mut witnesses: Vec<Witness> = Vec::new();
        // Only an optimisation, and it decides nothing: with an empty changed
        // set the loop finds nothing anyway, and removing it changes no output
        // and fails no test (measured, checked by removing it). It is here because
        // "nothing moved" is the pipeline's common case and the scan is the
        // second-most expensive thing in this file.
        if !changed.is_empty() {
            let lookup: HashSet<&str> = changed.iter().map(String::as_str).collect();
            for facts in facts {
                let Some(hit) = facts
                    .tokens
                    .iter()
                    .find(|token| lookup.contains(token.as_str()))
                else {
                    continue;
                };
                affected.push(facts.module.clone());
                if witnesses.len() < WITNESS_LIMIT {
                    witnesses.push(Witness {
                        module: facts.module.clone(),
                        name: hit.clone(),
                    });
                }
            }
        }
        affected.sort_by(|a, b| cmp_utf16(a, b));

        Self {
            before_names,
            after_names,
            changed,
            affected,
            witnesses,
        }
    }

    /// The `--print-set` file: one module per line.
    ///
    /// **An empty set is an empty file, with no newline.** The consumer counts
    /// lines, so a lone newline would be one module named by the empty string —
    /// and the renderer has to tell "no subset asked for" apart from "a subset
    /// that came out empty", which this file is how to spell.
    #[must_use]
    pub fn print_set(&self) -> String {
        if self.affected.is_empty() {
            return String::new();
        }
        let mut text = self.affected.join("\n");
        text.push('\n');
        text
    }

    /// The `--delta-json` file.
    ///
    /// **Nothing may assert on this file's bytes** — the three durations are
    /// wall clock, and a float's shortest round-trip form differs between V8 and
    /// `ryu` for values that happen to be integral (`100` against `100.0`).
    /// Assert on [`Delta`], or on `--print-set`, which has no floats in it.
    #[must_use]
    pub fn to_json(&self, timings: DeltaTimings) -> String {
        let record = DeltaRecord {
            command: "delta",
            before_names: self.before_names,
            after_names: self.after_names,
            changed_names: self.changed.len(),
            changed_sample: self.changed.iter().take(CHANGED_SAMPLE).collect(),
            affected: self.affected.len(),
            affected_modules: &self.affected,
            witnesses: &self.witnesses,
            diff_seconds: timings.diff_seconds,
            scan_seconds: timings.scan_seconds,
            total_seconds: timings.total_seconds,
        };
        let mut text =
            serde_json::to_string_pretty(&record).expect("the summary is strings and numbers");
        text.push('\n');
        text
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct DeltaTimings {
    pub diff_seconds: f64,
    pub scan_seconds: f64,
    pub total_seconds: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DeltaRecord<'a> {
    command: &'a str,
    before_names: usize,
    after_names: usize,
    changed_names: usize,
    changed_sample: Vec<&'a String>,
    affected: usize,
    affected_modules: &'a [String],
    witnesses: &'a [Witness],
    diff_seconds: f64,
    scan_seconds: f64,
    total_seconds: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(name, module)| ((*name).to_owned(), (*module).to_owned()))
            .collect()
    }

    fn facts(module: &str, tokens: &[&str]) -> ModuleFacts {
        ModuleFacts {
            module: module.to_owned(),
            content_hash: "0".repeat(16),
            imports: Vec::new(),
            tactics: 0,
            decls: Vec::new(),
            instances: Vec::new(),
            tokens: tokens.iter().map(|t| (*t).to_owned()).collect(),
            instances_for: Vec::new(),
            refs: BTreeMap::new(),
            summary: None,
        }
    }

    #[test]
    fn changed_is_the_union_of_both_key_sets() {
        let delta = Delta::compute(
            &map(&[("moved", "A"), ("gone", "A"), ("same", "A")]),
            &map(&[("moved", "B"), ("new", "A"), ("same", "A")]),
            &[],
        );
        assert_eq!(delta.changed, ["gone", "moved", "new"]);
        assert_eq!(delta.before_names, 3);
        assert_eq!(delta.after_names, 3);
    }

    #[test]
    fn nothing_changed_means_nothing_is_scanned() {
        let delta = Delta::compute(
            &map(&[("a", "A")]),
            &map(&[("a", "A")]),
            &[facts("Pkg.One", &["a"])],
        );
        assert!(delta.changed.is_empty());
        assert!(delta.affected.is_empty());
        assert_eq!(delta.print_set(), "");
    }

    #[test]
    fn affected_is_sorted_and_witnesses_are_in_index_order() {
        let delta = Delta::compute(
            &map(&[("x", "A"), ("y", "A")]),
            &map(&[("x", "B"), ("y", "B")]),
            &[
                facts("Pkg.Zed", &["unrelated", "y"]),
                facts("Pkg.Alpha", &["x", "y"]),
                facts("Pkg.None", &["nothing"]),
            ],
        );
        assert_eq!(delta.affected, ["Pkg.Alpha", "Pkg.Zed"]);
        assert_eq!(
            delta.witnesses,
            [
                Witness {
                    module: "Pkg.Zed".to_owned(),
                    name: "y".to_owned()
                },
                Witness {
                    module: "Pkg.Alpha".to_owned(),
                    name: "x".to_owned()
                },
            ]
        );
        assert_eq!(delta.print_set(), "Pkg.Alpha\nPkg.Zed\n");
    }
}
