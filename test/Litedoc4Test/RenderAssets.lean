/- The static files a page needs to look like a page, carried in the executable
rather than shipped beside it so that they cannot be a version behind the
renderer that names their classes.

Both are about the table itself, and both are closed.

**The scripted half is not here, and cannot be.** Every class `web/src/*.ts`
assigns must be styled too, and Lean has no `include_str!` — `Litedoc4.Assets`
carries the *bundle*, not the sources. `tools/assets-gate.sh` holds that half:
it globs the scripts and checks each class it finds against `style.css`, and it
is also what says whether `assets/` is what `web/src` bundles to. -/
import Litedoc4.Assets
import Litedoc4Test.Basis
import Litedoc4Test.RenderFrame

namespace Litedoc4Test
open Litedoc4

/-- An asset that was moved or emptied still compiles into the executable, and a
zero-byte `style.css` is a site that loads and has no styling. The paths are flat
and relative because they are URLs a page asks for: one that could climb out of
the site root would be written outside the tree the build owns. -/
def everyAssetHasADistinctPathAndABody : Bool :=
  (storeAssets.map (·.1)).toList.eraseDups.length == storeAssets.size
    && storeAssets.all fun (path, body) => !body.isEmpty && !emits path ".." && !emits path "/"

#guard everyAssetHasADistinctPathAndABody

/-- The assets ship inside the executable and land on every generated site, so
their size is a property of this project rather than of the package being
documented.

The limits are **round numbers above the current size, not the current size**: a
budget pinned to today's bytes fails on every edit, which teaches people to raise
it without looking. Raising a limit is allowed; raising it *without reading what
grew* is what this is here to make awkward — the answer to a large stylesheet is
to delete from it, not to adopt a framework. -/
def theAssetsStayWithinTheirBudget : Bool :=
  [("style.css", 32 * 1024), ("favicon.svg", 4 * 1024)].all
    fun (path, limit) => match storeAssets.find? (·.1 == path) with
      | some (_, body) => body.utf8ByteSize ≤ limit
      | none => false

#guard theAssetsStayWithinTheirBudget

end Litedoc4Test
