/- The inlined theme boot script and the import order — what every page carries
that is not the module's own content — and the substring helper the other render
tests share.

All closed. Nothing here touches a docstring, so nothing reaches `Md.events` and
every one is a `#guard`. -/
import Litedoc4.Assets
import Litedoc4.Data.Version

namespace Litedoc4Test
open Litedoc4

/-- Substring, spelled through `splitOn` because that is what the string API
gives: an assertion about markup is nearly always "does this fragment appear",
and the whole page in the failure would say less than the fragment does. -/
def emits (page needle : String) : Bool := (page.splitOn needle).length > 1

/-- `themeBootJs` is minifier output pasted between `<script>` and `</script>`
without escaping — which is correct, script content is not HTML — so a
`</script` anywhere inside it would close the tag early and spill the rest of the
bundle into the document as text. `<!--` opens an HTML comment inside a classic
script for the same historical reason and has the same "silently eats the rest"
failure. The minifier chooses the output and nobody reviews it. -/
def theInlinedBootScriptCannotCloseItsOwnTag : Bool :=
  !emits themeBootJs.toLower "</script" && !emits themeBootJs "<!--"

#guard theInlinedBootScriptCannotCloseItsOwnTag

/-- The boot script and the theme toggle agree about the storage key by
construction — both come from `web/src/theme-key.ts`. This is the half that
reaches Lean. -/
def theBootScriptCarriesTheStorageKey : Bool := emits themeBootJs "litedoc4-theme"

#guard theBootScriptCarriesTheStorageKey

/-- Deduplicated **before** the sort, which is why it keeps the first occurrence
and not any other. The order is `Name.lt` and not string order: it compares
parents first, so the one-component names lead. -/
def importsAreDeduplicatedBeforeBeingSortedByNameLt : Bool :=
  sortedImports #["Mathlib.Order", "Init", "Mathlib.Order", "Init.Core", "Zzz"]
    == #["Init", "Zzz", "Init.Core", "Mathlib.Order"]

#guard importsAreDeduplicatedBeforeBeingSortedByNameLt

end Litedoc4Test
