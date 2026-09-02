/- The command line one resident extractor is started with.

The server itself — one Lean environment for a whole run, a request per round,
the olean-generation guard — needs the target's toolchain and a 3 GB import;
`e2e/micro` GATE 5 and the refusal gate ask it those. What is here is the part
that reads nothing, and it reads nothing because `Serve.startArgv` was split out
of `Server.start`: inside the spawn the flags could only be inspected by running
Lean against a real package. -/
import Litedoc4.Incr.Resident

namespace Litedoc4Test
open Litedoc4 System

def serveSample : Serve :=
  { bin := "/bin/extract", lake := "/bin/lake", target := "/pkg", jobs := 3
    modulesFile := "/work/modules.txt", modules := #["Pkg", "Pkg.A"], work := "/work" }

/-- The start-up line, and the trap inside it: **`--ir-dir` names a directory no
request ever writes**. The extractor requires the flag at start-up and every
request carries its own IR directory, so the value here is a placeholder — and it
is a placeholder that has to be distinct from the modules file and the events
file, both of which are real and are written.

`--serve` is last because everything before it is configuration the loop builds
by appending; a flag added after it would be read as the serve loop's argument.
-/
def theStartUpLineCarriesAnIrDirNoRequestEverNames : Bool :=
  let argv := serveSample.startArgv
  argv[0]? == some "env"
    && argv[1]? == some "/bin/extract"
    && argv[2]? == some "/work/modules.txt"
    && argv[3]? == some "/work/serve-events.jsonl"
    && fixedFlags.all argv.contains
    && argv[argv.size - 1]? == some "--serve"
    && (match argv.findIdx? (· == "--jobs") with
        | some i => argv[i + 1]? == some "3"
        | none => false)
    && (match argv.findIdx? (· == "--ir-dir") with
        | some i => argv[i + 1]? == some "/work/serve-ir-unused"
        | none => false)
    && serveSample.unusedIrPath != serveSample.eventsPath
    && serveSample.unusedIrPath.toString != "/work/modules.txt"
    && !argv.contains "--link-index"

#guard theStartUpLineCarriesAnIrDirNoRequestEverNames

/-- The map's omit list is the **start-up** module list and not a request's. A
request's list is a subset — the round loop extracts what went stale — so an omit
set taken from it would make the map's bytes depend on which round happened to
write it, and the map's SHA-256 is in `renderKey`: every page would re-render on
the next round for no reason. -/
def theOmitListIsTheStartUpModuleListAndNotARequests : Bool :=
  let argv := ({ serveSample with linkIndex := some "/work/map.lidx"
                                  linkIndexKey := some "token" } : Serve).startArgv
  (match argv.findIdx? (· == "--link-index-omit") with
   | some i => argv[i + 1]? == some "/work/modules.txt"
   | none => false)
    && (match argv.findIdx? (· == "--link-index") with
        | some i => argv[i + 1]? == some "/work/map.lidx"
        | none => false)
    && (match argv.findIdx? (· == "--link-index-key") with
        | some i => argv[i + 1]? == some "token"
        | none => false)
    && argv[argv.size - 1]? == some "--serve"
    && !({ serveSample with linkIndexKey := some "token" } : Serve).startArgv.contains
      "--link-index-key"

#guard theOmitListIsTheStartUpModuleListAndNotARequests

end Litedoc4Test
