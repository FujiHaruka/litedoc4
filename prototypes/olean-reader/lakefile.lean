import Lake
open Lake DSL

package u12 where
  moreLeancArgs := #["-O3"]

lean_lib Extract
lean_lib OleanReader
lean_lib Assemble
lean_lib PrintKey
lean_lib Snap
lean_lib Patch

@[default_target]
lean_exe extract where
  root := `ExtractMain
  supportInterpreter := true

@[default_target]
lean_exe hybrid where
  root := `HybridMain
  supportInterpreter := true

@[default_target]
lean_exe nativekeys where
  root := `NativeKeys
  supportInterpreter := true

@[default_target]
lean_exe oracle where
  root := `OracleMain
  supportInterpreter := true

@[default_target]
lean_exe contenthash where
  root := `ContentMain

@[default_target]
lean_exe patchrun where
  root := `PatchMain
  supportInterpreter := true
