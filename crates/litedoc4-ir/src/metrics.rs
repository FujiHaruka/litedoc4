//! How much of the IR one process read — a **counter, not a clock**.
//!
//! A wall clock decides nothing here: the oleans are `mmap`ed, so the same run's
//! environment load moves by 5x with the page cache (2.5 s ↔ 13 s (measured)).
//! File reads do not move, so every number here is an integer.
//!
//! Counted: IR files opened and parsed, wherever that happens — including the
//! three callers outside this crate (`litedoc4_incr`'s merge, ledger and prune)
//! that read `index.json` directly, without which the count under-reports every
//! incremental run (measured 2026-08-16). Not counted: `fs::copy` of a module
//! file, which transfers bytes without parsing them.
//!
//! One full pass over a package is `modules` module-file reads, so
//! `module / modules` is a run's number of full passes; the incremental pipeline
//! still leaves five in place (measured →
//! `benchmarks/results/mathlib-scale-summary.txt`).
//!
//! The counters are `static`, so they are the *process's*, not a run's — hence
//! [`reset`].

use std::sync::atomic::{AtomicU64, Ordering};

/// Split because only the module count divides into a number of full passes:
/// `index.json` and the dependency slices are read a fixed number of times per
/// run, the module files once *per module per pass*.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IrFile {
    Index,
    Module,
    DepMap,
}

static INDEX: AtomicU64 = AtomicU64::new(0);
static MODULE: AtomicU64 = AtomicU64::new(0);
static DEP_MAP: AtomicU64 = AtomicU64::new(0);

/// Called **before** the read: a read that fails still opened the file and
/// still cost the work, and counting on the way out would let an early return
/// be the one path that does not count.
///
/// `Relaxed` is the whole ordering requirement: nothing else is published
/// through these counters, and a reader only ever wants the sum.
pub fn record(kind: IrFile) {
    let counter = match kind {
        IrFile::Index => &INDEX,
        IrFile::Module => &MODULE,
        IrFile::DepMap => &DEP_MAP,
    };
    counter.fetch_add(1, Ordering::Relaxed);
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct IrReads {
    pub index: u64,
    pub module: u64,
    pub dep_map: u64,
}

impl IrReads {
    pub fn total(&self) -> u64 {
        self.index + self.module + self.dep_map
    }

    /// A float on purpose: a run that reads a *subset* lands between two
    /// integers, and rounding it would turn "half a pass" into either "none" or
    /// "a whole one". `None` for an empty package, where the question has no
    /// answer.
    #[expect(
        clippy::cast_precision_loss,
        reason = "both counts are module reads; f64 is exact below 2^53"
    )]
    pub fn full_passes(&self, modules: usize) -> Option<f64> {
        (modules > 0).then(|| self.module as f64 / modules as f64)
    }
}

/// Not atomic **as a group**: the three loads are three instructions, so a
/// snapshot taken while another thread is reading the IR can straddle one file.
/// Every caller in this workspace reads it between stages, on the thread that
/// ran them, where there is nothing to straddle.
pub fn snapshot() -> IrReads {
    IrReads {
        index: INDEX.load(Ordering::Relaxed),
        module: MODULE.load(Ordering::Relaxed),
        dep_map: DEP_MAP.load(Ordering::Relaxed),
    }
}

/// `build` calls this even though nothing could have run before it, because
/// "nothing else ran first" is an assumption and resetting is a fact.
pub fn reset() {
    INDEX.store(0, Ordering::Relaxed);
    MODULE.store(0, Ordering::Relaxed);
    DEP_MAP.store(0, Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **One test, deliberately**: the counters are process-wide, so two tests
    /// in this binary would race each other rather than test anything. That the
    /// *readers* increment them is asserted through the whole pipeline instead.
    #[test]
    fn counts_by_kind_and_resets() {
        reset();
        assert_eq!(snapshot(), IrReads::default());
        assert_eq!(snapshot().total(), 0);

        for _ in 0..4 {
            record(IrFile::Module);
        }
        record(IrFile::Index);
        record(IrFile::DepMap);
        record(IrFile::DepMap);

        let reads = snapshot();
        assert_eq!(reads.index, 1);
        assert_eq!(reads.module, 4);
        assert_eq!(reads.dep_map, 2);
        assert_eq!(reads.total(), 7);

        assert_eq!(reads.full_passes(2), Some(2.0));
        assert_eq!(reads.full_passes(8), Some(0.5));
        assert_eq!(reads.full_passes(0), None);

        reset();
        assert_eq!(snapshot(), IrReads::default());
    }
}
