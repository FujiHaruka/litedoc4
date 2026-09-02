/- What a module file says, and what it does not say.

`selectionRange` has no invariant here because nothing reads it: the key exists
on the wire and neither half ever asked it a question — `naming_of` had no
caller outside its own crate's tests either. -/
import Litedoc4.Ir

namespace Litedoc4Test
open Litedoc4

/-- One declaration at `(10,0)-(14,20)` with the given extra keys appended, so
that a guard can put a shape on the wire that no writer would. -/
def declJson (name extra : String) : String :=
  "{\"name\":\"" ++ name ++ "\",\"kind\":\"theorem\",\"line\":10,\"col\":0"
    ++ ",\"endLine\":14,\"endCol\":20,\"index\":0" ++ extra ++ "}"

/-- A parse failure lands on the empty module, whose `decls` is empty — which is
why every guard below counts the declarations it expects. -/
def moduleOf (schema : Nat) (decls : List String) : Module :=
  let json := "{\"schemaVersion\":" ++ toString schema
    ++ ",\"module\":\"Pkg.M\",\"imports\":[],\"moduleDocs\":[],\"tactics\":[]"
    ++ ",\"declarations\":[" ++ ",".intercalate decls ++ "]}"
  match parseModule json with
  | .ok m => m
  | .error _ => {}

def theTwoSorryValuesAreReadBackAsTwoAndAnAbsentKeyIsClean : Bool :=
  let m := moduleOf 5 [declJson "Pkg.M.hole" ",\"sorry\":\"direct\"",
                        declJson "Pkg.M.uses" ",\"sorry\":\"transitive\"",
                        declJson "Pkg.M.clean" ""]
  m.decls.size == 3
    && m.sorryOf m.decls[0]! == .direct
    && m.sorryOf m.decls[1]! == .transitive
    && m.sorryOf m.decls[2]! == .clean

#guard theTwoSorryValuesAreReadBackAsTwoAndAnAbsentKeyIsClean

/-- The same bytes in both files; only the schema separates them. -/
def aSchema4ModuleSaysUnknownWhereASchema5OneSaysClean : Bool :=
  let older := moduleOf 4 [declJson "Pkg.M.clean" ""]
  let newer := moduleOf 5 [declJson "Pkg.M.clean" ""]
  older.decls.size == 1 && newer.decls.size == 1
    && older.sorryOf older.decls[0]! == .unknown
    && newer.sorryOf newer.decls[0]! == .clean

#guard aSchema4ModuleSaysUnknownWhereASchema5OneSaysClean

/-- The value this reader does not know is the one that must not read as
`clean`: `clean` is a claim that the package has no holes, and an unreadable
`sorry` is no evidence for it. Rust refuses the file outright
(`base_ir.rs::an_unknown_sorry_value_is_rejected`); until this reader can refuse
too, `unknown` is the honest answer and the wire value is kept so the refusal
has something to name. What would falsify the choice: the reader gaining an
error path, at which point this becomes a refusal and moves to the R tranche. -/
def anUnreadableSorryValueIsNotACleanOne : Bool :=
  let m := moduleOf 5 [declJson "Pkg.M.odd" ",\"sorry\":\"maybe\""]
  m.decls.size == 1 && m.sorryOf m.decls[0]! == .unknown

#guard anUnreadableSorryValueIsNotACleanOne

/-- The middle value is the one worth stating: `unclaimed` is **not** "the author
wrote it", because only `@[ext]` is ever named. The chain is one step and stops
where the key does, so `ext_iff` names the theorem and not the structure. -/
def aGeneratedKeyNamesItsOriginAndItsAbsenceIsNotADenial : Bool :=
  let m := moduleOf 5
    [declJson "Pkg.M.Pair.ext" ",\"generated\":[\"ext\",\"Pkg.M.Pair\"]",
      declJson "Pkg.M.Pair.ext_iff" ",\"generated\":[\"ext\",\"Pkg.M.Pair.ext\"]",
      declJson "Pkg.M.handwritten" ""]
  let older := moduleOf 4
    [declJson "Pkg.M.Pair.ext" ",\"generated\":[\"ext\",\"Pkg.M.Pair\"]"]
  m.decls.size == 3 && older.decls.size == 1
    && m.generatedBy m.decls[0]! == .realizedBy "ext" "Pkg.M.Pair"
    && m.generatedBy m.decls[1]! == .realizedBy "ext" "Pkg.M.Pair.ext"
    && m.generatedBy m.decls[2]! == .unclaimed
    && older.generatedBy older.decls[0]! == .unknown

#guard aGeneratedKeyNamesItsOriginAndItsAbsenceIsNotADenial

/-- One invariant where the Rust side had two: that the pair survives the wire
unsplit, and that printing it re-forms the one string schema 4 carried, are the
same claim seen from the reader's end and the writer's. -/
def anAttributeIsAPairAndItsTextIsTheStringSchema4Carried : Bool :=
  let m := moduleOf 5 [declJson "Pkg.M.f"
    ",\"attrs\":[[\"simp\",\"\"],[\"deprecated\",\"Pkg.M.g (since := \\\"2026-05-21\\\")\"]]"]
  m.decls.size == 1
    && m.decls[0]!.attrs
       == #[("simp", ""), ("deprecated", "Pkg.M.g (since := \"2026-05-21\")")]
    && m.decls[0]!.attrs.map attrText
       == #["simp", "deprecated Pkg.M.g (since := \"2026-05-21\")"]

#guard anAttributeIsAPairAndItsTextIsTheStringSchema4Carried

end Litedoc4Test
