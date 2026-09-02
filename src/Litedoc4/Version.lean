/-
A literal and not a generated file: Lake has no way to hand a string to a module
without a code-generating build step, and a generated `Version.lean` is a file
that is either committed and stale or missing and unbuildable. This is the one
place the version is *decided*; the six that repeat it are
`tools/version-sites.txt`, and `tools/version-gate.sh` is what stops a release
moving this literal and leaving them saying the release before it.
-/
namespace Litedoc4

def version : String := "1.4.0"

end Litedoc4
