/-
A literal and not a generated file: Lake has no way to hand a string to a module
without a code-generating build step, and a generated `Version.lean` is a file
that is either committed and stale or missing and unbuildable. This is the one
place the version is written, so nothing reconciles it against anything.
-/
namespace Litedoc4

def version : String := "1.3.0"

end Litedoc4
