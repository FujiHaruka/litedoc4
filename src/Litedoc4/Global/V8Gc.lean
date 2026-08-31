/-
The table holds the answers of V8 (BSD-3-Clause, Copyright 2006-2011 the V8
project authors), by way of `Litedoc4.Global.V8GcTable`; see this repository's
NOTICE.
-/
import Litedoc4.Md.Gc
import Litedoc4.Global.V8GcTable

namespace Litedoc4

/-- V8's `\p{Z}\p{C}` — the separator set the frozen prototype tokenises code
spans on.

**Nothing may use this alone, and nothing that produces bytes may use it at
all.** `autolinkTokens` splits on it united with `isZC`, which is UnicodeBasic's
answer and the one `autoLinkInline` uses — and the renderer's split is what
doc-gen4's output is compared against. -/
def v8ZcRanges : Array (UInt32 × UInt32) := gcRanges v8ZcTable

def isV8ZC (c : UInt32) : Bool := inGcRanges v8ZcRanges c

end Litedoc4
