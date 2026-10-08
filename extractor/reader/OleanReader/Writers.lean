import Lean
open Lean

namespace OleanReader

structure StoredReducibility where
  writerName : String
  meaning : ReducibilityStatus
  deriving Inhabited

structure WriterVersion where
  leanVersion : String
  githash : String
  absentExts : List String
  reducibility : Array StoredReducibility

instance : Inhabited WriterVersion := ⟨⟨"", "", [], #[]⟩⟩

def WriterVersion.toolchain (w : WriterVersion) : String := s!"leanprover/lean4:v{w.leanVersion}"

def storedBeforeV433 : Array StoredReducibility := #[
  ⟨"reducible", .reducible⟩, ⟨"semireducible", .semireducible⟩, ⟨"irreducible", .irreducible⟩,
  ⟨"implicitReducible", .instanceReducible⟩]

def storedFromV433 : Array StoredReducibility := #[
  ⟨"reducible", .reducible⟩, ⟨"semireducible", .semireducible⟩, ⟨"irreducible", .irreducible⟩,
  ⟨"implicitReducible", .implicitReducible⟩, ⟨"instanceReducible", .instanceReducible⟩]

def absentBeforeV433 : List String := [
  "Lean.Doc.DeferredCheck.handlerExt", "Lean.Doc.deferredCheckExt", "Lean.Doc.docBlockMdExt",
  "Lean.Doc.docInlineMdExt", "Lean.Elab.Tactic.Do.Internal.VCGen.frameProcExt",
  "Lean.Linter.CodeQuality.packageCheckExt", "Lean.Meta.Grind.homoExt", "Lean.Meta.Grind.homoPredExt",
  "Lean.Meta.Grind.homoSourceTypesExt", "Lean.Meta.Grind.liaExt",
  "Lean.Meta.Tactic.BVDecide.metaIntToBitVecExt", "Lean.Meta.Tactic.BVDecide.symIntToBitVecExt",
  "Lean.bool_to_prop", "Std.Internal.treeTacExt"]

def absentV433 : List String := [
  "Lean.Linter.CodeQuality.packageCheckExt", "Lean.Meta.Grind.homoExt", "Lean.Meta.Grind.homoPredExt",
  "Lean.Meta.Grind.homoSourceTypesExt"]

def writers : List WriterVersion := [
  { leanVersion := "4.31.0", githash := "68218e876d2a38b1985b8590fff244a83c321783"
    absentExts := absentBeforeV433 ++ [
      "Lean.Compiler.LCNF.monoTypeExt", "Lean.Meta.Tactic.BVDecide.bvNormalizeExt",
      "_private.Lean.Compiler.LCNF.MonoTypes.0.Lean.Compiler.LCNF.trivialStructureInfoExt",
      "_private.Lean.Compiler.LCNF.ToImpureType.0.Lean.Compiler.LCNF.ctorLayoutExt",
      "_private.Lean.Compiler.LCNF.ToImpureType.0.Lean.Compiler.LCNF.impureTrivialStructureInfoExt",
      "_private.Lean.Compiler.LCNF.ToImpureType.0.Lean.Compiler.LCNF.impureTypeExt",
      "envLinterSnapshotExt", "internalSpecMap"]
    reducibility := storedBeforeV433 },
  { leanVersion := "4.32.0", githash := "8c9756b28d64dab099da31a4c09229a9e6a2ef35"
    absentExts := absentBeforeV433
    reducibility := storedBeforeV433 },
  { leanVersion := "4.32.2", githash := "f3b06c705e6c85f5314019d5d3baab0fec5b580c"
    absentExts := absentBeforeV433
    reducibility := storedBeforeV433 },
  { leanVersion := "4.33.0", githash := "d8b18978322de05a8f3dba51ef03cf5461676c17"
    absentExts := absentV433
    reducibility := storedFromV433 },
  { leanVersion := "4.33.1", githash := "819816b2e0a3bf405af45ae5c7af2491d8f5bee6"
    absentExts := absentV433
    reducibility := storedFromV433 },
  { leanVersion := "4.34.1", githash := "5045d0056413266e57c625dcd7c365b10e377c52"
    absentExts := []
    reducibility := storedFromV433 }]

def WriterVersion.describe (w : WriterVersion) : String :=
  let red := w.reducibility.toList.zipIdx.map fun (r, i) => s!"{i}={r.writerName}"
  s!"{w.leanVersion} {w.githash} absent-extensions={w.absentExts.length} reducibility={",".intercalate red}"

def checkWriters (registered : Array String) : Except String Unit := do
  for w in writers do
    for e in w.absentExts do
      unless registered.contains e do
        throw s!"the record for Lean {w.leanVersion} lists {e} as absent, and the running Lean does not register it either"
    let meanings := w.reducibility.map (·.meaning)
    for i in [0:meanings.size] do
      for j in [i+1:meanings.size] do
        if meanings[i]! == meanings[j]! then
          throw s!"the record for Lean {w.leanVersion} gives stored reducibility {i} and {j} one meaning"
  let versions := writers.map (·.leanVersion)
  unless versions.eraseDups.length == versions.length do
    throw "two records share a Lean version"

end OleanReader
