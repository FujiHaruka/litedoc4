import Lean
open Lean

namespace OleanReader

structure StoredReducibility where
  writerName : String
  meaning : ReducibilityStatus
  deriving Inhabited

def privName (mod : Name) (n : Name) : Name := Name.mkNum (`_private ++ mod) 0 ++ n

def namespacesExtName : Name := privName `Lean.Namespace `Lean.namespacesExt

structure RenamedExt where
  writtenAs : Name
  registeredAs : Name

inductive SimpTheoremFlags where
  | postPermRfl
  | postPermRflBackwardRfl
  deriving Inhabited

def SimpTheoremFlags.count : SimpTheoremFlags → Nat
  | .postPermRfl => 3
  | .postPermRflBackwardRfl => 4

structure WriterVersion where
  leanVersion : String
  githash : String
  coreHeaderVersion : String := leanVersion
  absentExts : List String
  renamedExts : List RenamedExt
  reducibility : Array StoredReducibility
  simpTheorem : SimpTheoremFlags

instance : Inhabited WriterVersion := ⟨⟨"", "", "", [], [], #[], default⟩⟩

def WriterVersion.writesHeader (w : WriterVersion) (headerVersion : String) : Bool :=
  headerVersion == w.leanVersion || headerVersion == w.coreHeaderVersion

def WriterVersion.absent (w : WriterVersion) : List String :=
  w.absentExts ++ w.renamedExts.map (·.registeredAs.toString)

def WriterVersion.registeredName (w : WriterVersion) (written : Name) : Name :=
  ((w.renamedExts.find? (·.writtenAs == written)).map (·.registeredAs)).getD written

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

def absentV431 : List String := absentBeforeV433 ++ [
  "Lean.Compiler.LCNF.monoTypeExt", "Lean.Meta.Tactic.BVDecide.bvNormalizeExt",
  "_private.Lean.Compiler.LCNF.MonoTypes.0.Lean.Compiler.LCNF.trivialStructureInfoExt",
  "_private.Lean.Compiler.LCNF.ToImpureType.0.Lean.Compiler.LCNF.ctorLayoutExt",
  "_private.Lean.Compiler.LCNF.ToImpureType.0.Lean.Compiler.LCNF.impureTrivialStructureInfoExt",
  "_private.Lean.Compiler.LCNF.ToImpureType.0.Lean.Compiler.LCNF.impureTypeExt", "envLinterSnapshotExt",
  "internalSpecMap"]

def absentV430 : List String := absentV431 ++ [
  "Lean.Elab.Tactic.Grind.symDSimprocElabAttribute", "Lean.Elab.Tactic.noFallbackAttr",
  "Lean.Elab.deprecatedSyntaxExt", "Lean.Linter.EnvLinter.envLinterExt", "Lean.Linter.lintLogExt",
  "Lean.Meta.eqnOptionsExt", "Lean.backwardDefeqAttr", "Lean.deprecatedModuleExt",
  "_private.Lean.Compiler.LCNF.Specialize.0.Lean.Compiler.LCNF.Specialize.specCacheExt",
  "_private.Lean.Compiler.LCNF.ToImpure.0.Lean.Compiler.LCNF.taggedReturnAttr",
  "_private.Lean.Elab.Tactic.Grind.Annotated.0.Lean.Elab.Tactic.Grind.grindAnnotatedExt",
  "_private.Lean.Elab.Tactic.Grind.Lint.0.Lean.Elab.Tactic.Grind.muteExt",
  "_private.Lean.Elab.Tactic.Grind.Lint.0.Lean.Elab.Tactic.Grind.skipExt",
  "_private.Lean.Elab.Tactic.Grind.Lint.0.Lean.Elab.Tactic.Grind.skipSuffixExt",
  "_private.Lean.ExtraModUses.0.Lean.extraModUses", "_private.Lean.ExtraModUses.0.Lean.isExtraRevModUseExt",
  "_private.Lean.LibrarySuggestions.SineQuaNon.0.Lean.LibrarySuggestions.SineQuaNon.triggerDenyListExt",
  "_private.Lean.Meta.MethodSpecs.0.Lean.methodSpecsAttr",
  "_private.Lean.Meta.MethodSpecs.0.Lean.methodSpecsSimpExtension", "symDSimpVariantExtension"]

def absentV429 : List String := absentV430 ++ [
  "Lean.Compiler.LCNF.postponedCompileDeclsExt", "Lean.Compiler.weakSpecializeAttr",
  "Lean.Elab.Tactic.Do.SpecAttr.specInvariantAttr", "Lean.Elab.Tactic.Grind.symDischargerElabAttribute",
  "Lean.Elab.Tactic.Grind.symSimprocElabAttribute", "Lean.Elab.deprecatedArgExt",
  "Lean.Meta.Sym.Simp.symSimpExtension", "Lean.Meta.Tactic.Cbv.cbvSimprocDeclExt",
  "Lean.Meta.matcherLikeExt", "_private.Lean.Util.CollectAxioms.0.Lean.exportedAxiomsExt", "cbvSimprocExt",
  "symSimpVariantExtension"]

def renamedBeforeV430 : List RenamedExt := [⟨`Lean.namespacesExt, namespacesExtName⟩]

def writers : List WriterVersion := [
  { leanVersion := "4.29.0", githash := "98dc76e3c0a9b856c9b98726b713fb04fab16740"
    absentExts := absentV429
    renamedExts := renamedBeforeV430
    reducibility := storedBeforeV433
    simpTheorem := .postPermRfl },
  { leanVersion := "4.29.1", githash := "f72c35b3f637c8c6571d353742168ab66cc22c00", coreHeaderVersion := "4.29.0"
    absentExts := absentV429
    renamedExts := renamedBeforeV430
    reducibility := storedBeforeV433
    simpTheorem := .postPermRfl },
  { leanVersion := "4.30.0", githash := "d024af099ca4bf2c86f649261ebf59565dc8c622"
    absentExts := absentV430
    renamedExts := []
    reducibility := storedBeforeV433
    simpTheorem := .postPermRfl },
  { leanVersion := "4.31.0", githash := "68218e876d2a38b1985b8590fff244a83c321783"
    absentExts := absentV431
    renamedExts := []
    reducibility := storedBeforeV433
    simpTheorem := .postPermRflBackwardRfl },
  { leanVersion := "4.32.0", githash := "8c9756b28d64dab099da31a4c09229a9e6a2ef35"
    absentExts := absentBeforeV433
    renamedExts := []
    reducibility := storedBeforeV433
    simpTheorem := .postPermRflBackwardRfl },
  { leanVersion := "4.32.1", githash := "f054605aea4b840552cca2e725580bffd1e1b704"
    absentExts := absentBeforeV433
    renamedExts := []
    reducibility := storedBeforeV433
    simpTheorem := .postPermRflBackwardRfl },
  { leanVersion := "4.32.2", githash := "f3b06c705e6c85f5314019d5d3baab0fec5b580c"
    absentExts := absentBeforeV433
    renamedExts := []
    reducibility := storedBeforeV433
    simpTheorem := .postPermRflBackwardRfl },
  { leanVersion := "4.33.0", githash := "d8b18978322de05a8f3dba51ef03cf5461676c17"
    absentExts := absentV433
    renamedExts := []
    reducibility := storedFromV433
    simpTheorem := .postPermRflBackwardRfl },
  { leanVersion := "4.33.1", githash := "819816b2e0a3bf405af45ae5c7af2491d8f5bee6"
    absentExts := absentV433
    renamedExts := []
    reducibility := storedFromV433
    simpTheorem := .postPermRflBackwardRfl },
  { leanVersion := "4.34.0", githash := "293d5d0c0c3f3dded4688b3ccd6a33939ac5102b"
    absentExts := []
    renamedExts := []
    reducibility := storedFromV433
    simpTheorem := .postPermRflBackwardRfl },
  { leanVersion := "4.34.1", githash := "5045d0056413266e57c625dcd7c365b10e377c52"
    absentExts := []
    renamedExts := []
    reducibility := storedFromV433
    simpTheorem := .postPermRflBackwardRfl }]

def WriterVersion.describe (w : WriterVersion) : String :=
  let red := w.reducibility.toList.zipIdx.map fun (r, i) => s!"{i}={r.writerName}"
  s!"{w.leanVersion} {w.githash} core-header={w.coreHeaderVersion} absent-extensions={w.absent.length} renamed-extensions={w.renamedExts.length} \
    simp-theorem-flags={w.simpTheorem.count} reducibility={",".intercalate red}"

def checkWriters (registered : Array String) : Except String Unit := do
  for w in writers do
    for r in w.renamedExts do
      if registered.contains r.writtenAs.toString then
        throw s!"the record for Lean {w.leanVersion} renames {r.writtenAs}, and the running Lean registers {r.writtenAs} itself"
      unless registered.contains r.registeredAs.toString do
        throw s!"the record for Lean {w.leanVersion} renames {r.writtenAs} to {r.registeredAs}, which the running Lean does not register"
    for e in w.absent do
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
  let githashes := writers.map (·.githash)
  unless githashes.eraseDups.length == githashes.length do
    throw "two records share a githash"

end OleanReader
