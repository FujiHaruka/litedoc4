namespace Litedoc4

def extractorSource : String := include_str "../extractor/Extract.lean"

def leanToolchainsTable : String := include_str "../tools/lean-toolchains.txt"

def readerSources : Array (String × String) := #[
  ("OleanReader/Writers.lean", include_str "../extractor/reader/OleanReader/Writers.lean"),
  ("OleanReader/Read.lean", include_str "../extractor/reader/OleanReader/Read.lean"),
  ("OleanReader/Entries.lean", include_str "../extractor/reader/OleanReader/Entries.lean"),
  ("OleanReader/Module.lean", include_str "../extractor/reader/OleanReader/Module.lean"),
  ("OleanReader/Serialize.lean", include_str "../extractor/reader/OleanReader/Serialize.lean"),
  ("OleanReader/Oracle.lean", include_str "../extractor/reader/OleanReader/Oracle.lean"),
  ("OleanReader/Assemble.lean", include_str "../extractor/reader/OleanReader/Assemble.lean"),
  ("OleanReader/Check.lean", include_str "../extractor/reader/OleanReader/Check.lean"),
  ("OleanReader/Patch.lean", include_str "../extractor/reader/OleanReader/Patch.lean"),
  ("OleanReader/PrintKey.lean", include_str "../extractor/reader/OleanReader/PrintKey.lean"),
  ("OleanReader/Hybrid.lean", include_str "../extractor/reader/OleanReader/Hybrid.lean"),
  ("OleanReader/Main.lean", include_str "../extractor/reader/OleanReader/Main.lean")]

end Litedoc4
