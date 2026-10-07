import Litedoc4.Data.SiteLedger
import Litedoc4Test.Basis

namespace Litedoc4Test
namespace SiteLedgerTest
open Litedoc4 Litedoc4.Data Litedoc4.Data.Site Litedoc4.Data.SiteLedger

def row (v key : String) (routes : Option String := none) : Option Row :=
  (Store.VersionName.parse v).toOption.map fun name =>
    { name, key, data := s!"data-{v}", routes, modules := 3
      shells := { files := 7, raw := 70, stored := 70 }, referenced := 12
      added := { files := 5, raw := 500, stored := 120 }
      paths := #[s!"{v}/index.html", s!"d/{v}-\"quoted\".json.gz", "d/shared.json.gz"] }

def ledger (rows : Array (Option Row)) (hashUrls := false) : RenderLedger :=
  { renderer := "exe-1", hashUrls, rows := rows.filterMap id }

def requested (vs : Array String) : Array (Store.VersionName × String) :=
  vs.filterMap fun v => (Store.VersionName.parse v).toOption.map (·, s!"key-{v}")

def stepsOf : Decision → Option (Array String)
  | .everything _ => none
  | .reuse steps => some <| steps.map fun
    | .keep r => s!"keep {r.name.text}"
    | .render v key => s!"render {v.text} {key}"

def theRenderLedgerReadsBackAsTheLedgerItWrote : Bool :=
  let l := ledger #[row "v1" "key-v1", row "v2" "key-v2" (some "routes-v2")] true
  match RenderLedger.parse l.toJson with
  | .ok back => back.toJson == l.toJson && back.rows.size == 2
  | .error _ => false

#guard theRenderLedgerReadsBackAsTheLedgerItWrote

def aLedgerThatDoesNotReadOrNamesNoVersionIsRefused : Bool :=
  let good : String := (ledger #[row "v1" "key-v1"]).toJson
  (RenderLedger.parse (good.dropEnd 3).toString).toOption.isNone
    && (RenderLedger.parse (good.replace "\"v1\"" "\"..\"")).toOption.isNone
    && (RenderLedger.parse (good.replace "\"hashUrls\":false" "\"hashUrls\":0")).toOption.isNone

#guard aLedgerThatDoesNotReadOrNamesNoVersionIsRefused

def aLedgerHoldingPartOfTheListRendersOnlyTheRestInTheListsOrder : Bool :=
  let l := ledger #[row "v4" "key-v4", row "v1" "key-v1", row "v2" "key-v2"]
  stepsOf (decide (.ledger l) "exe-1" false (requested #["v1", "v2", "v3", "v4", "v5"]) none)
    == some #["keep v1", "keep v2", "render v3 key-v3", "keep v4", "render v5 key-v5"]
    && stepsOf (decide (.ledger l) "exe-1" false (requested #["v1", "v2", "v4"]) none)
      == some #["keep v1", "keep v2", "keep v4"]

#guard aLedgerHoldingPartOfTheListRendersOnlyTheRestInTheListsOrder

def everythingIsRenderedUnlessTheLedgerHoldsOnlyWhatIsAskedUnchanged : Bool :=
  let four := requested #["v1", "v2", "v3", "v4"]
  let held := ledger #[row "v1" "key-v1", row "v2" "key-v2"]
  let everything (d : Decision) := stepsOf d |>.isNone
  everything (decide .absent "exe-1" false four none)
    && everything (decide (.unreadable "no `renderer`") "exe-1" false four none)
    && everything (decide (.ledger held) "exe-2" false four none)
    && everything (decide (.ledger held) "exe-1" true four none)
    && everything (decide (.ledger (ledger #[row "v1" "key-v1", row "v5" "key-v5"])) "exe-1" false
      four none)
    && everything (decide (.ledger (ledger #[row "v1" "key-v1", row "v2" "key-v2-moved"])) "exe-1"
      false four none)
    && everything (decide (.ledger held) "exe-1" false four
      ((Store.VersionName.parse "v2").toOption.map (·, "v2/index.html")))
    && (decide (.ledger held) "exe-1" false four none |> stepsOf |>.isSome)

#guard everythingIsRenderedUnlessTheLedgerHoldsOnlyWhatIsAskedUnchanged

def renderingEverythingRendersEveryVersionInTheListsOrder : Bool :=
  let asked := requested #["v2", "v1"]
  (Decision.everything "x").steps asked |>.map (fun
    | .keep _ => "keep"
    | .render v key => s!"{v.text} {key}") == #["v2 key-v2", "v1 key-v1"]

#guard renderingEverythingRendersEveryVersionInTheListsOrder

end SiteLedgerTest
end Litedoc4Test
