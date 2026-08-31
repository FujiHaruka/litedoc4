/- Both ends of the same target: building it elaborates the `#guard`s, running
it answers the invariants that need the linked C, an `IO.Ref` or a tree on disk. -/
import Litedoc4Test

def main : IO UInt32 :=
  Litedoc4Test.run [
    Litedoc4Test.entitiesArePassedThroughRaw,
    Litedoc4Test.theIrReadCountsAreByKindAndReset,
    Litedoc4Test.openUnvalidatedReadsExactlyWhatOpenRefuses]
