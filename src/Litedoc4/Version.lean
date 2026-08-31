/-
The literal is duplicated from `[workspace.package] version` in `Cargo.toml`
rather than generated from it: Lake has no way to hand a string to a module
without a code-generating build step, and a generated `Version.lean` is a file
that is either committed and stale or missing and unbuildable.
`tools/purelean-gate.sh` reconciles the two instead. The duplication ends when
`Cargo.toml` leaves the tree, and the gate's reconciliation goes with it.
-/
namespace Litedoc4

def version : String := "1.3.0"

end Litedoc4
