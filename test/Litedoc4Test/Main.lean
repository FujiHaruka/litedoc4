/- Both ends of the same target: building it elaborates the `#guard`s, running
it answers the invariants that need the linked C, an `IO.Ref` or a tree on disk. -/
import Litedoc4Test

def main : IO UInt32 :=
  Litedoc4Test.run [
    Litedoc4Test.entitiesArePassedThroughRaw,
    Litedoc4Test.aParagraphIsWrappedAndATightItemIsNot,
    Litedoc4Test.inlineIsOneParagraphOrElseTheAuthorsOwnCharacters,
    Litedoc4Test.theShapesThatKillMd4LeanParseAndRenderHere,
    Litedoc4Test.noHostileOrGeneratedInputCrashesTheRenderer,
    Litedoc4Test.renderingIsDeterministicOverTheHostileCorpus,
    Litedoc4Test.theIrReadCountsAreByKindAndReset,
    Litedoc4Test.openUnvalidatedReadsExactlyWhatOpenRefuses,
    Litedoc4Test.aModuleDescriptionIsEscapedLikeEverythingElse,
    Litedoc4Test.everyClassTheEntryPagesEmitIsStyled,
    Litedoc4Test.theCountsAreWhatTheFilesHold,
    Litedoc4Test.theStateFileOnDiskIsTheBytesItSaysItIs,
    Litedoc4Test.theCacheSequenceAgreesWithAFromScratchBuild,
    Litedoc4Test.theSiteTreeIsExactlyTheWholePackageArtifacts,
    Litedoc4Test.neitherHalfOfPruneTakesAFileThatIsNotAModulePage,
    Litedoc4Test.pruneOnlyEverUnlinksInsideTheRootAndNeverThroughASymlink,
    Litedoc4Test.anInPlaceMergeSpelledAnotherWayStillMergesInPlace,
    Litedoc4Test.aRepeatedIndexEntryIsOneModuleAndTwoReads,
    Litedoc4Test.theLedgerAnswersEveryScenarioOnASyntheticPackage,
    Litedoc4Test.aDeclarationIsHeadAttributesSignatureDocAndExtra,
    Litedoc4Test.anInheritedFieldIsALinkAndAnAbsentKeyIsNotInherited,
    Litedoc4Test.thePageWrapsMainInTheFrame,
    Litedoc4Test.noRootAndNoFileAreTheSameAnswer,
    Litedoc4Test.everyClassTheRendererEmitsIsStyled,
    Litedoc4Test.writingTwiceLeavesTheSameBytes]
