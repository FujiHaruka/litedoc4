/- How much of the IR one process read — a counter, not a clock.

A wall clock decides nothing here: the oleans are `mmap`ed, so the same run's
environment load moves by 5× with the page cache (2.5 s ↔ 13 s (measured)). File
reads do not move, so every number here is an integer, and one full pass over a
package is `modules` module-file reads.

The counters are process-wide rather than threaded through the readers because
the two stages that read the IR — `renderSite` and `buildGlobal` — are called
from four commands and none of them would carry a counter for the one that
reports it. -/

namespace Litedoc4

/-- Split because only the module count divides into a number of full passes:
`index.json` and the dependency slices are read a fixed number of times per run,
the module files once per module per pass. -/
structure IrReads where
  index : Nat := 0
  module : Nat := 0
  depMap : Nat := 0
  deriving Inhabited

def IrReads.total (r : IrReads) : Nat := r.index + r.module + r.depMap

initialize irReadsRef : IO.Ref IrReads ← IO.mkRef {}

inductive IrFile where
  | index
  | module
  | depMap

/-- Called **before** the read: a read that fails still opened the file and
still cost the work, and counting on the way out would let a failure be the one
path that does not count. -/
def recordIrRead : IrFile → IO Unit
  | .index => irReadsRef.modify fun r => { r with index := r.index + 1 }
  | .module => irReadsRef.modify fun r => { r with module := r.module + 1 }
  | .depMap => irReadsRef.modify fun r => { r with depMap := r.depMap + 1 }

def irReads : IO IrReads := irReadsRef.get

def resetIrReads : IO Unit := irReadsRef.set {}

end Litedoc4
