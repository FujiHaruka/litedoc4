import Litedoc4

namespace Litedoc4

def usage : String :=
"usage: litedoc4 build  --root <repo> --out <dir> [--lib <Name>]...
                       [--source-url <url>] [--full] [--hash-urls]
                       [--extractor-bin <path>] [--lake <path>]
                       [--jobs <n>] [--timings <file>]
       litedoc4 build  --root <repo> --out <dir> --versions <ref>,<ref>...
                       [--store <dir>] [--hash-urls] [--lib <Name>]...
                       [--lake <path>] [--jobs <n>]
       litedoc4 watch  --root <repo> --out <dir> [--port <n>] [--interval <ms>]
                       [--lib <Name>]... [--source-url <url>] [--hash-urls]
                       [--extractor-bin <path>] [--lake <path>] [--jobs <n>]
       litedoc4 modules --root <repo> [--lib <Name>]... [--out <file>]
       litedoc4 extract --modules <file> --ir-dir <dir> --timings <file>
                       [--extractor-bin <path>] [--target <repo>] [--lake <path>]
                       [--events <file>] [--jobs <n>]
                       [--link-index <file> [--link-index-omit <file>]
                        [--link-index-key <token>]]
       litedoc4 ledger build --modules <file> --target <repo> --out <ledger.json>
                       [--algorithm sha256|lake] [--concurrency <n>]
                       [--ir <dir>] [--source-url <url>] [--link-index <file>]
                       [--root <repo>] [--lake <path>] [--timings <file>]
       litedoc4 ledger check --ledger <ledger.json> [--modules <file>]
                       [--algorithm sha256|lake] [--concurrency <n>] [--ir <dir>]
                       [--source-url <url>] [--link-index <file>]
                       [--root <repo>] [--lake <path>] [--changed-out <file>]
                       [--removed-out <file>] [--render-all-out <file>]
                       [--timings <file>]
       litedoc4 ledger touch --ledger <ledger.json> --module <Module> [--out <file>]
       litedoc4 links  --root <repo> [--lake <path>] [--link-index <file>]
                       [--out <file>]
       litedoc4 store put --store <dir> --version <name> --from <dir>
                       [--lake <path>]
       litedoc4 store read --store <dir> --version <name> [--out <dir>]
       litedoc4 store list --store <dir>
       litedoc4 store remove --store <dir> --version <name>
       litedoc4 store check-stale --store <dir> --extractor-bin <path>
                       --root <repo>
       litedoc4 store measure --store <dir> --versions <name>,<name>...
                       --candidate a|b|c [--chunk-bytes <n>] [--out <dir>]
       litedoc4 store render --store <dir> --versions <name>,<name>...
                       --out <dir> [--hash-urls]

  --root         (`build`, `modules`) the Lean package: the sources are globbed
                 under it, its oleans are hashed, `lake env` runs inside it, and
                 for `build` its git HEAD is where --source-url comes from.
                 (`ledger`) optional, and for two things, both in renderKey.
                 One is the dependency link map: with it, every link into a
                 dependency is that package's version-pinned GitHub blob URL,
                 read out of its lake-manifest.json plus `lean --githash`. The
                 other is <root>/docs/references.bib. It is **not** --target:
                 that names the tree whose oleans are hashed. A ledger and the
                 run it licenses have to agree about this flag, or the render
                 key moves. `build` has one by construction.
                 (`links`) the package whose dependency link map is printed.
  --out          (`build`) the directory this command owns: <out>/site is the
                 site, rendered from the store; <out>/ir, <out>/link-index.lidx
                 and <out>/work are --root's extraction, <out>/ledger.json its
                 ledger, and <out>/store the store (--store moves it only with
                 --versions).
                 Required, with no default — <root>/.lake/build/doc is doc-gen4's
                 own output tree — and it may not be inside --root. Without
                 --versions the working tree at --root is one version, named by
                 the first 12 hex digits of the commit its source links name:
                 its IR is brought up to date in place (a module whose olean did
                 not move is not extracted again), put into the store, every
                 other version removed from it, and the site rendered from the
                 store with that version alone. Prints
                 `versions extracted: <n> of 1 (<name>)`, 1 when a module was
                 extracted, which <out>/litedoc4-build.json records too
  --port         (`watch`) the port the site is served on (default 8484). A
                 port that is taken is refused by name, never moved to the next
                 free one: an address that changes between runs leaves the tab
                 you already have open pointing at nothing.
  --interval     (`watch`) how often the loop asks the ledger, in milliseconds
                 (default 1000, minimum 100). `watch` **does not run `lake
                 build`** — run that in another window and it notices the oleans
                 it writes. It acts only after one quiet interval, so a build
                 still writing oleans is never extracted mid-flight, and it says
                 so while it waits.
  --versions     (`build`) the versions of --root's git repository that one site
                 shows, comma-separated tags, branches or commits, each named as
                 given, the last the newest. Each version the store lacks, holds
                 stale or holds at another commit is checked out at
                 <out>/checkout, its toolchain installed by elan (one with no row
                 in tools/lean-toolchains.txt is refused before anything runs),
                 its libraries built by `lake build`, its IR extracted by an
                 extractor built for its Lean under <out>/extractors and put into
                 the store, and the checkout deleted before the next. Then the
                 site is rendered from the store into <out>/site, as `store
                 render` writes it. The extraction flags come from --root's
                 litedoc4.toml; the title, front page and bibliography from each
                 version's own. --lake has to be elan's, which picks each
                 checkout's toolchain. Prints `versions extracted: <n> of <m>
                 (<names>)`, which <out>/litedoc4-build.json records too
  --full         (`build`) extract every module again, ignoring the IR under
                 --out. The escape hatch for an input no ledger key covers.
  --ir           an IR tree written by the extractor (schema 5)
  --ir-dir       (`extract`) where the extractor writes that tree. Required,
                 with no default
  --source-url   https://host/owner/repo/blob/<40-hex-rev>. `build` and `watch`
                 check the 40 hex digits; the revision is the version's commit,
                 and left out, it is derived from --root's HEAD and its
                 github.com remote.
  --link-index   the dependency closure's name -> module map (.lidx). Its
                 SHA-256 is part of renderKey: a map that moved re-renders every
                 page (150 of the target's 432 change bytes).
                 For `extract` it asks the extractor to write one.
  --link-index-omit  (`extract`, with --link-index) the modules whose own
                 declaration groups are left out of that map, one name per
                 line — normally the package's own module list. The renderer
                 answers those names out of the IR before it reads the map, so
                 the site is byte-identical; what changes is that the map stops
                 moving when the package is edited, and with it renderKey.
                 Module names still appear in the map's `@` section.
                 `build` passes its own module list here.
  --link-index-key  (`extract`, with --link-index) an opaque token standing for
                 everything about that map the extractor cannot see: the oleans
                 behind the imported modules, and the omit list's bytes. With
                 it, a map whose sidecar <file>.key holds the same token and
                 whose `@` section still matches the environment is left
                 untouched — no scan, no write (1.20-1.81 s of a 6.2 s one-module
                 incremental build on the measurement target). Anything less than
                 a full match rewrites both. `build` computes its own; here it
                 is passed through verbatim.
  --root         (`modules`) the repository the sources are globbed under
  --lib          (`build`, `modules`) a library root: <Name>.lean and <Name>/;
                 repeatable. Left out, the names come from <root>/lakefile.toml's
                 [[lean_lib]] blocks; a lakefile.lean is refused by name, because
                 reading it honestly means elaborating it with Lake
  --extractor-bin  (`extract`) the Lean extractor built
                 by extractor/build.sh, or $EXTRACT_BIN. No default: it is built
                 against the target's toolchain, so a baked-in path would be
                 right on one machine. (`build`, `watch`) optional, or
                 $EXTRACT_BIN: left out, the extractor is built for the Lean
                 --root's lean-toolchain pins, under <out>/extractors, and a
                 toolchain with no row in tools/lean-toolchains.txt is refused
  --target       (`extract`) the Lean package to run inside, or $TARGET_REPO.
                 It is opened read-only: an --ir-dir under it is refused
  --lake         (`extract`) the lake executable, or $LAKE (default: `lake`).
                 Also (`build`, `ledger`, `links`) where the `lean` that
                 answers `--githash` is looked
                 for: its **sibling**, so `--lake ~/.elan/bin/lake` means
                 `~/.elan/bin/lean`. That revision is Lean core's, the one
                 dependency the manifest does not pin
  --events       (`extract`) the extractor's phase events JSONL. Defaults to
                 <timings without .json>-events.jsonl
  --jobs         (`extract`) extractor threads (default 1)
  --out          the ledger file `ledger build` writes
  --timings      one JSON line of counts and durations
  --modules      the module list, one name per line; # comments are skipped.
                 `ledger check` without it re-reads the ledger's own list and
                 cannot see a module that appeared or vanished since `build`.
  --target       the repository whose .lake/build/lib/lean holds the oleans.
                 **Not** where the dependency link map comes from — that is
                 --root, even for `ledger`, where on a real package the two name
                 the same directory but on a hashed tree with no package behind
                 it only one of them exists
  --ledger       a ledger.json written by `ledger build`
  --algorithm  sha256 hashes the olean bytes; lake reads the <file>.hash Lake
                 already wrote. Defaults to sha256, and for `check` to the
                 ledger's own.
  --concurrency  olean reads in flight (default 1). The ledger's bytes do not
                 depend on it.
  --changed-out  the modules to re-extract, one per line
  --removed-out  the modules that no longer have an olean, one per line
  --render-all-out  why every page has to be re-rendered, one reason per line.
                 Empty means the render set follows from the IR diff as usual.
  --module       the module `ledger touch` invalidates
  --store        (`store`, and `build --versions`, where it defaults to
                 <out>/store) the kept versions, one directory per version:
                 <store>/<name>/entry.pack.gz (the IR tree, the dependency link
                 index, the bibliography and the index page's Markdown, packed
                 and gzipped) and record.json (commit, Lean, dependencies, each
                 dependency module root's version-pinned source URL or that it
                 has none, the title, the extractor identity the IR was written
                 under, and the pack's SHA-256, which `read` checks before it
                 decompresses anything)
  --version      (`store`) the entry's name: letters, digits, `.`, `_`, `+`
                 and `-`, starting with a letter or a digit, without `..`
  --from         (`store put`) a directory `build --out` finished. Its ir/ and
                 link-index.lidx are stored, and a build that wrote no link
                 index is refused; the commit, the dependencies, their source
                 URLs, Lean core's revision and the site configuration
                 (litedoc4.toml's title and index, docs/references.bib) come
                 from the checkout its marker names, which has to still be at
                 the commit the pages link to. Putting the same directory again
                 rewrites the entry without re-extracting anything.
                 `store read --out` unpacks an entry into an empty directory
                 laid out as `build --out` lays out those two, with the site
                 configuration under site/; without it the entry is only
                 verified. `store check-stale` asks
                 --extractor-bin for its identity with the flags `build`
                 passes, which --root's litedoc4.toml decides, and says fresh,
                 stale (an identity field other than the Lean version and
                 revision differs, which a version's commit pins), or needs
                 re-put (a record an older put wrote, without the source map
                 or the site configuration, which `store measure` and `store
                 render` refuse) per entry; it exits 3 when an entry needs
                 re-put or is unreadable
  --versions     (`store measure`, `store render`) the entries to lay out,
                 comma-separated, in the order a site would have added them:
                 the last is the newest. `store render` writes the site into
                 an empty --out, one version at a time: every data file once
                 under d/, gzipped and named by the address of its bytes, so a
                 file two versions share is one file; a shell per page under
                 <version>/; versions.json, the root index.html, which sends the
                 reader on to the newest version, and 404.html, which sends an
                 unversioned path on to the newest version's page. It prints
                 one JSON line of counts (per version and in total) and exits 3
                 on an entry that needs re-put or two different files under one
                 address
  --hash-urls    (`store render`, `build`, `watch`) no shells: the root
                 index.html draws every page from a route in the fragment,
                 #/<version>/<module path>, with a declaration as ?id=<name>;
                 each version gets a routes file in d/, named by versions.json
  --candidate    (`store measure`) how declaration content is stored: a, one
                 file per module per version; b, per-module segments appended
                 by each version; c, packs read by byte range. It prints one
                 JSON line of counters (hosted bytes and files, bytes and files
                 each version adds, fetches and bytes per module page view);
                 --out writes the hosted files into an empty directory
  --chunk-bytes  (`store measure --candidate c`) the raw bytes after which a
                 pack's compressed chunk is cut (default 16384)
"

/-- What `litedoc4` with no arguments prints. `usage` is behind `--help-all` and
behind every subcommand's own `--help`, because a reader who has already typed
`store` is past the front door.

Two commands rather than seven: the other five are invoked by
`tools/*-gate.sh` and by nothing a consumer runs — `action.yml` and
`lakefile.lean`'s `docs` script call `build` and nothing else (measured
2026-08-29). Listing all seven as equals said the opposite. -/
def summary : String :=
"usage: litedoc4 build  --root <repo> --out <dir> [--lib <Name>]...
                       [--jobs <n>] [--source-url <url>] [--full]
       litedoc4 watch  --root <repo> --out <dir> [--lib <Name>]...
                       [--jobs <n>] [--port <n>]

  `build` writes the site once. `watch` rebuilds it whenever the package's
  oleans change and serves it, without ever running `lake build` itself.

  Five more subcommands exist — extract, modules, links, ledger, store. They are
  the stages `build` runs and the queries the gates ask of them, not a second way
  to use this tool, and each answers its own --help.

  litedoc4 --help-all    every command line and every flag
  litedoc4 --version
"

def refuse (message : String) : IO UInt32 := do
  IO.eprintln s!"litedoc4: {message}"
  IO.eprintln ""
  IO.eprintln usage
  return 2

/-- Exit 3 and no usage text: the command line was fine and the *world* is a
shape this cannot work with, which is a thing a caller can act on. -/
def refusedWith (code : UInt32) (message : String) : IO UInt32 := do
  IO.eprintln s!"litedoc4: {message}"
  return code

/-- **One string, five call sites**, so that they cannot drift apart: the map is
what turns a name in a signature into a link, and it fails silently — a docstring
name that did not become a link looks exactly like a name that was never
linkable — so the guard is in the shape of the flags, not in a default. -/
def linkIndexCost : String :=
  "without the dependency map 150 of the target package's 432 pages change bytes"

structure LedgerArgs where
  modules : Option String := none
  target : Option String := none
  out : Option String := none
  ledger : Option String := none
  ir : Option String := none
  sourceUrl : String := ""
  linkIndex : Option String := none
  root : Option String := none
  lake : Option String := none
  algorithm : Option String := none
  concurrency : Nat := 1
  module : Option String := none
  changedOut : Option String := none
  removedOut : Option String := none
  renderAllOut : Option String := none
  timings : Option String := none
  help : Bool := false
  deriving Inhabited

/-- Which `ledger` subcommand accepts which flag.

One flat parse followed by a dispatch on the subcommand accepts every flag for
all three and reads it for one: `ledger touch --concurrency 9` would run, ignore
the number, and say nothing. **A flag that does nothing is the shape this project
keeps finding** — the run looks right and the artefact is not the one that was
asked for. -/
def ledgerFlags : List (String × List String) :=
  [("--modules", ["build", "check"]),
   ("--target", ["build"]),
   ("--out", ["build", "touch"]),
   ("--ledger", ["check", "touch"]),
   ("--ir", ["build", "check"]),
   ("--source-url", ["build", "check"]),
   ("--link-index", ["build", "check"]),
   ("--root", ["build", "check"]),
   ("--lake", ["build", "check"]),
   ("--algorithm", ["build", "check"]),
   ("--concurrency", ["build", "check"]),
   ("--module", ["touch"]),
   ("--changed-out", ["check"]),
   ("--removed-out", ["check"]),
   ("--render-all-out", ["check"]),
   ("--timings", ["build", "check"])]

def ledgerFlagRefusal (command flag : String) : Option String :=
  match ledgerFlags.find? (·.1 == flag) with
  | some (_, accepted) =>
    if accepted.contains command then none
    else some s!"{flag} is not a flag of `ledger {command}`: it belongs to \
      {" / ".intercalate (accepted.map (s!"`ledger {·}`"))}"
  | none => none

partial def parseLedger (command : String) :
    List String → LedgerArgs → Except String LedgerArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} needs a value"
    match ledgerFlagRefusal command flag with
    | some message => .error message
    | none =>
    if flag == "--modules" then do
      let (v, more) ← value; parseLedger command more { acc with modules := some v }
    else if flag == "--target" then do
      let (v, more) ← value; parseLedger command more { acc with target := some v }
    else if flag == "--out" then do
      let (v, more) ← value; parseLedger command more { acc with out := some v }
    else if flag == "--ledger" then do
      let (v, more) ← value; parseLedger command more { acc with ledger := some v }
    else if flag == "--ir" then do
      let (v, more) ← value; parseLedger command more { acc with ir := some v }
    else if flag == "--source-url" then do
      let (v, more) ← value; parseLedger command more { acc with sourceUrl := v }
    else if flag == "--link-index" then do
      let (v, more) ← value; parseLedger command more { acc with linkIndex := some v }
    else if flag == "--root" then do
      let (v, more) ← value; parseLedger command more { acc with root := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseLedger command more { acc with lake := some v }
    else if flag == "--algorithm" then do
      let (v, more) ← value; parseLedger command more { acc with algorithm := some v }
    else if flag == "--concurrency" then do
      let (v, more) ← value
      match v.toNat? with
      | some n => parseLedger command more { acc with concurrency := n }
      | none => .error s!"--concurrency wants a number, not {v}"
    else if flag == "--module" then do
      let (v, more) ← value; parseLedger command more { acc with module := some v }
    else if flag == "--changed-out" then do
      let (v, more) ← value; parseLedger command more { acc with changedOut := some v }
    else if flag == "--removed-out" then do
      let (v, more) ← value; parseLedger command more { acc with removedOut := some v }
    else if flag == "--render-all-out" then do
      let (v, more) ← value; parseLedger command more { acc with renderAllOut := some v }
    else if flag == "--timings" then do
      let (v, more) ← value; parseLedger command more { acc with timings := some v }
    else if flag == "--help" || flag == "-h" then
      parseLedger command rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

/-- `--concurrency` is accepted and its value is recorded, and a run that took it
must not read as though it had used it: this build hashes one module at a time. -/
def sequentialNote (concurrency : Nat) : IO Unit := do
  if concurrency > 1 then
    IO.println s!"ledger  --concurrency {concurrency} was asked for; this build hashes one module \
      at a time, and the timings record keeps the number that was asked for"

def jsonNames (out : String) (names : Array String) : String := Id.run do
  let mut o := out.push '['
  let mut first := true
  for name in names do
    if !first then o := o.push ','
    first := false
    o := jsonStr o name
  return o.push ']'

/-- The `build` timing record. **The key order is part of the bytes**, and
every value but the durations is compared against a recording of it. -/
def buildTimingsJson (algorithm : String) (concurrency modules files hashedBytes : Nat)
    (keyNanos hashNanos writeNanos totalNanos : Nat) : String :=
  jsonStr "{\"command\":\"build\",\"algorithm\":" algorithm
    ++ s!",\"concurrency\":{concurrency},\"modules\":{modules},\"files\":{files}"
    ++ s!",\"hashedBytes\":{hashedBytes},\"keySeconds\":{seconds keyNanos 9}"
    ++ s!",\"hashSeconds\":{seconds hashNanos 9},\"writeSeconds\":{seconds writeNanos 9}"
    ++ s!",\"totalSeconds\":{seconds totalNanos 9}" ++ "}\n"

/-- `CheckTimings`, under the rule `buildTimingsJson` states. -/
def checkTimingsJson (concurrency : Nat) (s : CheckSummary) (totalNanos : Nat) : String :=
  let p := s.phases
  let o := jsonStr "{\"command\":\"check\",\"algorithm\":" s.algorithm.name
  let o := o ++ s!",\"concurrency\":{concurrency},\"modules\":{s.modules},\"moduleListSource\":"
  let o := jsonStr o (if s.fromList then "list" else "ledger")
  let o := o ++ s!",\"files\":{s.files},\"hashedBytes\":{s.hashedBytes},\"extractKeyChanged\":"
  let o := jsonNames o s.extractKeyChanged
  let o := o ++ s!",\"extractInvalidated\":{s.extractInvalidated},\"renderKeyChanged\":"
  let o := jsonNames o s.renderKeyChanged
  let o := o ++ s!",\"renderAll\":{s.renderAll},\"changed\":{s.changed.size},\"changedModules\":"
  let o := jsonNames o s.changed
  let o := o ++ s!",\"added\":{s.added.size},\"addedModules\":"
  let o := jsonNames o s.added
  let o := o ++ s!",\"removed\":{s.removed.size},\"removedModules\":"
  let o := jsonNames o s.removed
  o ++ s!",\"reExtract\":{s.reExtract.size}"
    ++ s!",\"readLedgerSeconds\":{seconds (p.readDone - p.started) 9}"
    ++ s!",\"keySeconds\":{seconds (p.keyDone - p.readDone) 9}"
    ++ s!",\"hashSeconds\":{seconds (p.hashDone - p.keyDone) 9}"
    ++ s!",\"compareSeconds\":{seconds (p.compareDone - p.hashDone) 9}"
    ++ s!",\"totalSeconds\":{seconds totalNanos 9}" ++ "}\n"

/-- `--root`'s map. It is an input to `renderKey`, so `ledger build` and `ledger
check` need it for the same reason `--link-index` is theirs: without it they
compute a different key from the one the run that wrote the pages recorded. -/
def ledgerExternal (a : LedgerArgs) : IO ExternalLinks :=
  resolveExternal a.root a.lake

/-- `--root`'s bibliography digest, for the same reason as `ledgerExternal`. -/
def ledgerBibliography (a : LedgerArgs) : IO (Option String) := do
  match a.root with
  | some root => return (← readBibliography ⟨root⟩).digest
  | none => return none

def ledgerBuildRun (a : LedgerArgs) (modules target out : String) : IO UInt32 := do
  let names ← readModuleList ⟨modules⟩
  let external ← ledgerExternal a
  let algorithm : Algorithm := match a.algorithm with
    | some name => { name }
    | none => Algorithm.sha256
  let result ← buildLedger
    { modules := names, target := target, ir := a.ir.map (⟨·⟩), sourceUrl := a.sourceUrl
      linkIndex := a.linkIndex.map (⟨·⟩), externalLinks := some external.digest
      bibliography := ← ledgerBibliography a, algorithm }
  match result with
  | .error message => refusedWith 3 message
  | .ok (ledger, phases) =>
    let body := ledger.toJson
    writeFile ⟨out⟩ body
    let files := fileCountOf ledger.modules
    let hashed := hashedBytesOf ledger.modules
    if let some path := a.timings then
      let total ← IO.monoNanosNow
      writeFile ⟨path⟩ (buildTimingsJson algorithm.name a.concurrency ledger.modules.size files
        hashed (phases.keyDone - phases.started) (phases.hashDone - phases.keyDone)
        (total - phases.hashDone) (total - phases.started))
    sequentialNote a.concurrency
    IO.println s!"build {ledger.modules.size} modules, {files} olean file(s), \
      {grouped hashed} B hashed \
      in {seconds (phases.hashDone - phases.keyDone) 4} s -> {out} ({body.utf8ByteSize} B)"
    return 0

def ledgerCheckRun (a : LedgerArgs) (path : String) : IO UInt32 := do
  let names ← match a.modules with
    | some list => pure (some (← readModuleList ⟨list⟩))
    | none => pure none
  let external ← ledgerExternal a
  let result ← checkLedger
    { ledger := ⟨path⟩, algorithm := a.algorithm.map ({ name := · }), modules := names
      ir := a.ir.map (⟨·⟩), sourceUrl := a.sourceUrl, linkIndex := a.linkIndex.map (⟨·⟩)
      externalLinks := some external.digest
      bibliography := ← ledgerBibliography a
      changedOut := a.changedOut.map (⟨·⟩), removedOut := a.removedOut.map (⟨·⟩)
      renderAllOut := a.renderAllOut.map (⟨·⟩) }
  match result with
  | .error (code, message) => refusedWith code message
  | .ok summary =>
    if let some timings := a.timings then
      writeFile ⟨timings⟩
        (checkTimingsJson a.concurrency summary ((← IO.monoNanosNow) - summary.phases.started))
    sequentialNote a.concurrency
    IO.println s!"check {summary.modules} modules ({summary.algorithm.name}, concurrency 1): \
      {summary.changed.size} changed, {summary.added.size} added, {summary.removed.size} removed"
    if summary.extractInvalidated then
      IO.println s!"  extract key changed ({",".intercalate summary.extractKeyChanged.toList}) \
        -> all {summary.reExtract.size} re-extracted"
    if summary.renderAll then
      IO.println s!"  render key changed ({",".intercalate summary.renderKeyChanged.toList}) \
        -> re-render all, re-extract {summary.reExtract.size}"
    for module in summary.changed do
      IO.println s!"  changed  {module}"
    for module in summary.added do
      IO.println s!"  added    {module}"
    for module in summary.removed do
      IO.println s!"  removed  {module}"
    return 0

def ledgerTouchRun (path module out : String) : IO UInt32 := do
  match readLedger path (← readTextFile path) >>= touchLedger path module with
  | .error (code, message) => refusedWith code message
  | .ok ledger =>
    let body := ledger.toJson
    writeFile ⟨out⟩ body
    IO.println s!"touched {module} in {out} ({body.utf8ByteSize} B; injected change, the olean is \
      untouched)"
    return 0

def ledgerRun (command : String) (a : LedgerArgs) : IO UInt32 := do
  if command == "build" then
    let missing := "ledger build needs --modules <file>, --target <repo> and --out <ledger.json>"
    let some modules := a.modules | refuse missing
    let some target := a.target | refuse missing
    let some out := a.out | refuse missing
    ledgerBuildRun a modules target out
  else if command == "check" then
    let some path := a.ledger | refuse "ledger check needs --ledger <ledger.json>"
    ledgerCheckRun a path
  else
    let missing := "ledger touch needs --ledger <ledger.json> and --module <Module>"
    let some path := a.ledger | refuse missing
    let some module := a.module | refuse missing
    ledgerTouchRun path module (a.out.getD path)

structure ModulesArgs where
  root : Option String := none
  libs : Array String := #[]
  out : Option String := none
  help : Bool := false
  deriving Inhabited

partial def parseModules : List String → ModulesArgs → Except String ModulesArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} needs a value"
    if flag == "--root" then do
      let (v, more) ← value; parseModules more { acc with root := some v }
    else if flag == "--lib" then do
      let (v, more) ← value; parseModules more { acc with libs := acc.libs.push v }
    else if flag == "--out" then do
      let (v, more) ← value; parseModules more { acc with out := some v }
    else if flag == "--help" || flag == "-h" then
      parseModules rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

def modulesRun (a : ModulesArgs) (root : String) : IO UInt32 := do
  let libs ← if !a.libs.isEmpty then pure (Except.ok a.libs) else
    match ← readLibraries ⟨root⟩ with
    | .error message => pure (.error message)
    | .ok declared => do
      -- **On stderr**: this command's stdout is the module list itself when
      -- `--out` is absent, and a caller redirecting it into a file would
      -- otherwise get a diagnostic as its first module.
      IO.eprintln s!"lib     {", ".intercalate declared.names.toList} (from {declared.file})"
      pure (.ok declared.names)
  match libs with
  | .error message => refusedWith 3 message
  | .ok libs =>
    match ← moduleNames ⟨root⟩ libs with
    | .error message => refusedWith 3 message
    | .ok names =>
      match a.out with
      | some path => do
        writeLines ⟨path⟩ names
        IO.println s!"{names.size} modules -> {path}"
        return 0
      | none => do
        for name in names do
          IO.println name
        return 0

def modules (args : List String) : IO UInt32 := do
  match parseModules args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let some root := a.root | refuse "--root <repo> is required"
    try
      modulesRun a root
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

structure BuildArgs where
  root : Option String := none
  out : Option String := none
  libs : Array String := #[]
  sourceUrl : Option String := none
  extractorBin : Option String := none
  lake : Option String := none
  jobs : Nat := 1
  timings : Option String := none
  full : Bool := false
  versions : Option String := none
  store : Option String := none
  hashUrls : Bool := false
  /-- `watch`'s own two, as text, so that the refusal for `--port banana` is
  written next to what a port means. Never filled in for `build`, which refuses
  them by name. -/
  port : Option String := none
  interval : Option String := none
  help : Bool := false
  deriving Inhabited

def storeOfOneVersion : String :=
  "a site of one version keeps only that version, in <out>/store, which this command owns. A \
    store of several versions is `litedoc4 build --versions <ref>,<ref>... --store <dir>`"

def versionsInWatch : String :=
  "a site of several versions is built from their store, one checkout at a time, and `watch` \
    rebuilds one working tree. Use `litedoc4 build --versions`"

/-- Flags `build` and `watch` refuse by name because each is a real flag of a
subcommand this one drives: what a caller needs to hear is which decision this
command has taken over, not that they misspelled something. -/
def buildRefusal (watching : Bool) (flag : String) : Option String :=
  let command := if watching then "watch" else "build"
  if ["--ir", "--pages", "--ledger", "--work", "--state"].contains flag then
    some s!"{flag} is not a `{command}` flag: this command owns the layout under --out \
      (<out>/ir, <out>/site, <out>/store, <out>/work, <out>/ledger.json) so that a second run can \
      find what the first one left"
  else if flag == "--modules" then
    some s!"--modules is not a `{command}` flag: the list is the source glob over the libraries \
      (`litedoc4 modules`), and the same list has to reach detect, the extractor and merge or the \
      merged index.json comes out in an order a from-scratch run would not have written. Choose \
      the libraries with --lib"
  else if flag == "--target" then
    some s!"--target is not a `{command}` flag: the package being documented is --root, and it is \
      the same repository the sources are globbed from, the oleans are hashed in and `lake env` \
      runs inside"
  else if flag == "--no-link-index" then
    some s!"--no-link-index is not a `{command}` flag: {linkIndexCost}, and a build command whose \
      ordinary output is silently wrong on a third of its pages is not worth having"
  else if ["--serve", "--serve-dir", "--serve-from"].contains flag then
    some s!"{flag} is not a `{command}` flag: with --extractor-bin this command *is* the resident \
      path — one Lean environment for the whole run, started here and released after the last \
      round. There is nothing to switch on, and a server this run did not start is one whose \
      olean generation it cannot vouch for"
  else none

/-- The command line of `build` — **and of `watch`**, which is the same request
asked over and over.

One parser, not two: a second would be a second place for `--out` to mean
something, and the first thing to drift would be one of the by-name refusals
below, which are the part a caller reads only when they are already confused.
`watching` decides which of the flags that belong to exactly one of the two
commands is the one being refused. -/
partial def parseBuild (watching : Bool) :
    List String → BuildArgs → Except String BuildArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} needs a value"
    if flag == "--root" then do
      let (v, more) ← value; parseBuild watching more { acc with root := some v }
    else if flag == "--out" then do
      let (v, more) ← value; parseBuild watching more { acc with out := some v }
    else if flag == "--lib" then do
      let (v, more) ← value; parseBuild watching more { acc with libs := acc.libs.push v }
    else if flag == "--source-url" then do
      let (v, more) ← value; parseBuild watching more { acc with sourceUrl := some v }
    else if flag == "--extractor-bin" then do
      let (v, more) ← value; parseBuild watching more { acc with extractorBin := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseBuild watching more { acc with lake := some v }
    else if flag == "--jobs" then do
      let (v, more) ← value
      match v.toNat? with
      | some n => parseBuild watching more { acc with jobs := n }
      | none => .error s!"--jobs wants a number, not {v}"
    else if flag == "--timings" then do
      let (v, more) ← value; parseBuild watching more { acc with timings := some v }
    else if flag == "--port" then do
      let (v, more) ← value
      if watching then parseBuild watching more { acc with port := some v }
      else .error "--port is a `watch` flag: `build` writes a site and exits, so there is nothing \
        left running to serve it. `litedoc4 watch --root … --out … --port <n>` is the one that \
        serves"
    else if flag == "--interval" then do
      let (v, more) ← value
      if watching then parseBuild watching more { acc with interval := some v }
      else .error "--interval is a `watch` flag: it is how often the loop asks the ledger, and \
        `build` asks once"
    else if flag == "--full" then
      if watching then
        .error "--full is not a `watch` flag: it means \"regenerate everything, ignoring what is \
          under --out\", and a loop that did that every pass would never do anything else. Run \
          `litedoc4 build --full` once, then start watching"
      else parseBuild watching rest { acc with full := true }
    else if flag == "--versions" then do
      let (v, more) ← value
      if watching then .error s!"--versions is not a `watch` flag: {versionsInWatch}"
      else parseBuild watching more { acc with versions := some v }
    else if flag == "--store" then do
      let (v, more) ← value
      if watching then .error s!"--store is not a `watch` flag: {storeOfOneVersion}"
      else parseBuild watching more { acc with store := some v }
    else if flag == "--hash-urls" then
      parseBuild watching rest { acc with hashUrls := true }
    else if flag == "--help" || flag == "-h" then
      parseBuild watching rest { acc with help := true }
    else match buildRefusal watching flag with
      | some message => .error message
      | none => .error s!"unknown argument `{flag}`"

/-- What the command line says once every flag has been read. -/
def buildChecks (a : BuildArgs) : Option String :=
  if a.jobs == 0 then some "--jobs must be at least 1" else none

def versionedChecks (a : BuildArgs) : Option String :=
  match a.versions with
  | none =>
    if a.store.isSome then
      some s!"--store is not a flag of `build` without --versions: {storeOfOneVersion}"
    else none
  | some _ =>
    let refused : List (String × Bool × String) := [
      ("--source-url", a.sourceUrl.isSome,
        "each version links to its own commit, under the checkout's github.com remote"),
      ("--extractor-bin", a.extractorBin.isSome, s!"each version's extractor is built against \
        the Lean its commit pins, under <out>/{Versions.extractorsName}"),
      ("--full", a.full, "a version the store holds fresh is kept and every other is extracted \
        from nothing; `litedoc4 store remove` has one extracted again"),
      ("--timings", a.timings.isSome, "it is one build's record; this command prints and marks \
        which versions it extracted")]
    refused.findSome? fun (flag, given, why) =>
      if given then some s!"{flag} is not a flag of `build --versions`: {why}" else none

/-- One request, for the two commands that ask it: `build` once and `watch` over
and over. Resolved in one place because the two would otherwise be two places for
`--out` to be canonicalised and for the external-link digest to be taken. -/
def buildRequestOf (a : BuildArgs) (root out : String) : BuildM BuildRequest := do
  -- Canonicalised **before** anything is compared against it: `--out` under a
  -- symlinked `--root` is still under `--root`.
  let rootPath ← match ← (IO.FS.realPath ⟨root⟩).toBaseIO with
    | .error e => throw (3, s!"--root {root}: {e}")
    | .ok path => pure path
  let outPath ← absolutePath ⟨out⟩
  refuseInside rootPath "--root" outPath "--out" " — `litedoc4 extract` refuses an --ir-dir there \
    for the same reason. Copy <out>/site into the repository afterwards if that is where the \
    pages belong"
  -- Before anything is written, and once: `lake env lean --githash` starts a
  -- process inside the target, and the digest it feeds has to be the same one on
  -- both sides of this run.
  let external ← resolveExternal (some rootPath.toString) a.lake
  return { root := rootPath, layout := layoutOf outPath, libs := a.libs, external
           sourceUrl := a.sourceUrl, extractorBin := a.extractorBin.map (⟨·⟩)
           lake := a.lake.map (⟨·⟩), jobs := a.jobs, timings := a.timings.map (⟨·⟩)
           full := a.full }

def storePutOrigin (from_ : System.FilePath) (lake : System.FilePath) :
    IO (Except String Store.Origin) := do
  match ← readMarker (from_ / markerName) with
  | .absent => return .error s!"{from_} has no {markerName}: `store put --from` takes a \
      directory `litedoc4 build --out` wrote"
  | .broken why => return .error s!"{from_ / markerName}: {why}"
  | .fields kv =>
    if !markerIsTrue kv "complete" then
      return .error s!"{from_}: the build there did not finish"
    let root : System.FilePath := ⟨markerString kv "root"⟩
    let sourceUrl := markerString kv "sourceUrl"
    let commit ← match ← (git root #["rev-parse", "HEAD"]).run with
      | .error why => return .error why
      | .ok commit => pure commit
    if (sourceUrl.splitOn s!"/blob/{commit}").length < 2 then
      return .error s!"{root} is at {commit} and the build in {from_} linked to {sourceUrl}: \
        the checkout moved since the build, or --source-url named another revision"
    let sources ← resolveExternal (some root.toString) (some lake.toString)
    Versions.originOf root lake sources commit sourceUrl

def answered (code : UInt32) (message : String) : IO UInt32 :=
  if code == 2 then refuse message else refusedWith code message

def buildRun (a : BuildArgs) (root out : String) : IO UInt32 := do
  match ← (do
      let request ← buildRequestOf a root out
      discard <| Versions.buildOne request a.hashUrls).run with
  | .ok () => return 0
  | .error (code, message) => answered code message

def versionsRun (a : BuildArgs) (root out list : String) : BuildM Unit := do
  let names ← match Store.versionList list with
    | .error message => throw (2, message)
    | .ok names => pure names
  let rootPath ← match ← (IO.FS.realPath ⟨root⟩).toBaseIO with
    | .error e => throw (3, s!"--root {root}: {e}")
    | .ok path => pure path
  let repo ← match ← Versions.repositoryOf rootPath with
    | .error message => throw (3, message)
    | .ok repo => pure repo
  let outPath ← absolutePath ⟨out⟩
  refuseInside repo.top "the repository of --root" outPath "--out" ""
  let store ← absolutePath ((a.store.map (⟨·⟩)).getD (layoutOf outPath).store)
  refuseInside repo.top "the repository of --root" store "--store" ""
  let planned ← match ← Versions.plan repo names Versions.supportedToolchains with
    | .error message => throw (3, message)
    | .ok planned => pure planned
  Versions.checkOwnership outPath rootPath
  let noEquationsUnder := (← readConfigKeys rootPath).noEquationsUnder
  let lake : System.FilePath := (← envOr (a.lake.map (⟨·⟩)) "LAKE").getD ⟨"lake"⟩
  let elan := Versions.elanBeside lake
  let marker := outPath / markerName
  IO.FS.createDirAll outPath
  writeFile marker (Versions.versionsMarkerJson rootPath.toString store.toString names none)
  IO.FS.createDirAll store
  let extractors := outPath / Versions.extractorsName
  Versions.pruneExtractors extractors
  let current ← IO.mkRef (none : Option Store.ExtractorIdentity)
  let identity : BuildM Store.ExtractorIdentity := do
    if let some known ← current.get then return known
    let cached ← planned.reverse.findM? fun p =>
      isRegularFile (Versions.extractorPath extractors p.toolchain)
    let some source := cached <|> planned.back? | throw (2, "--versions names no version")
    let bin ← Versions.extractorFor elan extractors source.toolchain
    let known ← Store.currentIdentity bin noEquationsUnder
    IO.println s!"identity {known.text} (asked of the extractor for {source.toolchain})"
    current.set (some known)
    return known
  let mut toExtract : Array Versions.Planned := #[]
  for p in planned do
    let judged ← if !(← (Store.entryDir store p.name).isDir) then pure Versions.Judgement.absent
      else match ← (Store.readRecord store p.name).toBaseIO with
        | .error e => pure (.unreadable (toString e))
        | .ok r => match Versions.judgeRecord r p.commit with
          | some judged => pure judged
          | none => pure (Versions.judgeIdentity r (← identity))
    IO.println s!"version {p.name.text}: {judged.text}"
    if !judged.keeps then toExtract := toExtract.push p
  let checkout := outPath / Versions.checkoutName
  let scratch := outPath / Versions.scratchName
  for p in toExtract do
    IO.println s!"version {p.name.text}: extracting {p.commit} on {p.toolchain}"
    let bin ← Versions.extractorFor elan extractors p.toolchain
    try
      let (package, libs) ← Versions.prepare repo checkout elan lake a.libs p
      if ← scratch.pathExists then IO.FS.removeDirAll scratch
      let args : BuildArgs :=
        { root := some package.toString, out := some scratch.toString, libs
          lake := some lake.toString, jobs := a.jobs }
      let request ← buildRequestOf args package.toString scratch.toString
      let e ← runExtraction { request with noEquationsUnder := some noEquationsUnder } (pure bin)
      let origin ← match ← Versions.originOf package lake request.external p.commit e.sourceUrl with
        | .error message => throw (3, s!"version {p.name.text}: {message}")
        | .ok origin => pure origin
      let layout := layoutOf scratch
      let s ← Store.put store p.name origin layout.ir layout.linkIndex
      IO.println s!"put     {p.name.text}: {s.record.irFiles} IR file(s) -> {s.record.packBytes} B \
        ({s.record.extractorIdentity.text})"
    finally
      if ← scratch.pathExists then IO.FS.removeDirAll scratch
      Versions.removeCheckout repo.top checkout
  let extracted := toExtract.map (·.name)
  IO.println (Versions.extractedLine names extracted)
  let site := outPath / Versions.siteName
  if ← site.pathExists then IO.FS.removeDirAll site
  match ← (Data.Site.renderStore store site names a.hashUrls).run with
  | .error why => throw (3, why)
  | .ok counts => IO.println counts.json
  writeFile marker (Versions.versionsMarkerJson rootPath.toString store.toString names
    (some extracted))
  IO.println s!"build   {names.size} version(s) -> {site}"

def rootRequired : String := "--root <repo> is required: the Lean package to document"

def outRequired : String :=
  "--out <dir> is required and has no default: it is where the site, the IR, the cache and the \
    ledger go. The obvious default would be <root>/.lake/build/doc, which is doc-gen4's own \
    output tree — a default that overwrites another tool's output is a data-loss bug with a \
    friendly face"

def build (args : List String) : IO UInt32 := do
  match parseBuild false args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let some root := a.root | refuse rootRequired
    let some out := a.out | refuse outRequired
    if let some message := versionedChecks a then return ← refuse message
    if let some message := buildChecks a then return ← refuse message
    try
      match a.versions with
      | none => buildRun a root out
      | some list => match ← (versionsRun a root out list).run with
        | .ok () => pure (0 : UInt32)
        | .error (code, message) => answered code message
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

/-- The same request as `build`, asked every `--interval` ms, with a file server
on `--port` for what it writes. -/
def watch (args : List String) : IO UInt32 := do
  match parseBuild true args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let some root := a.root | refuse rootRequired
    let some out := a.out | refuse outRequired
    if let some message := buildChecks a then return ← refuse message
    -- Both refusals before the first `lake`: a usage error that arrives after a
    -- subprocess has run is one the caller waited for.
    let port ← match parsePort a.port with
      | .error message => return ← refuse message
      | .ok port => pure port
    let interval ← match parseInterval a.interval with
      | .error message => return ← refuse message
      | .ok interval => pure interval
    try
      match ← (do
          let request ← buildRequestOf a root out
          watchRun request a.hashUrls port interval).run with
      | .ok () => return 0
      | .error (code, message) => answered code message
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

structure LinksArgs where
  root : Option String := none
  lake : Option String := none
  out : Option String := none
  linkIndex : Option String := none
  help : Bool := false
  deriving Inhabited

partial def parseLinks : List String → LinksArgs → Except String LinksArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} needs a value"
    if flag == "--root" then do
      let (v, more) ← value; parseLinks more { acc with root := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseLinks more { acc with lake := some v }
    else if flag == "--out" then do
      let (v, more) ← value; parseLinks more { acc with out := some v }
    else if flag == "--link-index" then do
      let (v, more) ← value; parseLinks more { acc with linkIndex := some v }
    else if flag == "--help" || flag == "-h" then
      parseLinks rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

/-- One row of `links`.

**The deep sample is what judges the path building.** A root module is a single
component, so `Mathlib` -> `Mathlib.lean` exercises no dot, no nesting and no
guillemet; `Mathlib.Order.Basic` -> `Mathlib/Order/Basic.lean` does. Every URL
here comes from the renderer's own `ExternalLinks.urlFor` rather than from
joining strings, because a checker that built the URL its own way would agree
with a renderer that built it wrongly. -/
structure LinkRow where
  root : String
  base : String
  url : Option String
  docsUrl : Option String
  deep : Option (String × String)
  deepDocsUrl : Option String

/-- The lexicographically first module of `root` below the root itself — first
rather than longest, so that the sample does not move when the index gains a
module. -/
def sampleModule (index : Lidx) (root : String) : Option String := Id.run do
  let below := root ++ "."
  let mut best : Option String := none
  for module in index.modules do
    if module.startsWith below then
      match best with
      | none => best := some module
      | some seen => if byteLt module seen then best := some module
  return best

def linkRows (links : ExternalLinks) (index : Option Lidx) : Array LinkRow := Id.run do
  let mut rows : Array LinkRow := Array.mkEmpty links.roots.size
  for entry in links.roots do
    let sample := index.bind (sampleModule · entry.name)
    let deep := sample.bind fun module => (links.urlFor module none).map (module, ·)
    rows := rows.push
      -- A root is a top-level `Foo.lean`, so the root module's own file is the
      -- one file every resolved root is known to have.
      { root := entry.name, base := entry.base, url := links.urlFor entry.name none
        docsUrl := links.docsUrlFor entry.name none, deep
        deepDocsUrl := sample.bind (links.docsUrlFor · none) }
  return rows

def orDash : Option String → String
  | none => "-"
  | some s => s

def jsonOrNull (out : String) : Option String → String
  | none => out ++ "null"
  | some s => jsonStr out s

/-- `serde_json::to_string_pretty`: two spaces a level, and no space before a
`:`. -/
def linksJson (root : String) (rows : Array LinkRow) (pinned sampled documented : Nat) :
    String := Id.run do
  let mut o := jsonStr "{\n  \"root\": " root
  o := o ++ s!",\n  \"roots\": {rows.size},\n  \"pinned\": {pinned}"
    ++ s!",\n  \"sampled\": {sampled},\n  \"documented\": {documented},\n  \"rows\": "
  if rows.isEmpty then return o ++ "[]\n}\n"
  o := o ++ "["
  let mut first := true
  for row in rows do
    if !first then o := o.push ','
    first := false
    o := jsonStr (o ++ "\n    {\n      \"root\": ") row.root
    o := jsonStr (o ++ ",\n      \"base\": ") row.base
    o := jsonOrNull (o ++ ",\n      \"url\": ") row.url
    o := jsonOrNull (o ++ ",\n      \"docsUrl\": ") row.docsUrl
    o := jsonOrNull (o ++ ",\n      \"module\": ") (row.deep.map (·.1))
    o := jsonOrNull (o ++ ",\n      \"moduleUrl\": ") (row.deep.map (·.2))
    o := jsonOrNull (o ++ ",\n      \"moduleDocsUrl\": ") row.deepDocsUrl
    o := o ++ "\n    }"
  return o ++ "\n  ]\n}\n"

/-- The dependency link map, as the renderer will see it.

doc-gen4's reference tree documents only the target's import closure, so most
roots have no oracle — **12 of 39 had one, 27 did not** (measured 2026-08-16).
The other 27 are URLs a server will answer for, so this prints the rows for
something to check.

It reads; it writes nothing but `--out`. `lake` runs (core's revision comes from
`lake env lean --githash`), so this needs the target's toolchain. -/
def linksRun (a : LinksArgs) (root : String) : IO UInt32 := do
  let index ← match a.linkIndex with
    | none => pure none
    | some path => pure (some (parseLidx (← readTextFile ⟨path⟩)))
  let external ← resolveExternal (some root) a.lake
  let rows := linkRows external index
  let count (p : LinkRow → Bool) : Nat := rows.foldl (fun n row => if p row then n + 1 else n) 0
  let pinned := count (·.url.isSome)
  let sampled := count (·.deep.isSome)
  let documented := count (·.docsUrl.isSome)
  for row in rows do
    -- Tab-separated, `-` for "nothing here" — the shape `cut` and `awk` read
    -- without a parser. Only rows go to stdout here; the counts are below.
    let (module, deep) := match row.deep with
      | none => ("-", "-")
      | some (module, url) => (module, url)
    IO.println s!"{row.root}\t{if row.base.isEmpty then "-" else row.base}\t\
      {orDash row.url}\t{module}\t{deep}\t{orDash row.docsUrl}\t{orDash row.deepDocsUrl}"
  if index.isSome then
    IO.println s!"external  {sampled}/{rows.size} root(s) with a deeper module"
  if let some path := a.out then
    writeFile ⟨path⟩ (linksJson root rows pinned sampled documented)
  return 0

def linksCmd (args : List String) : IO UInt32 := do
  match parseLinks args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    let some root := a.root | refuse "--root <repo> is required"
    try
      linksRun a root
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

def ledger (args : List String) : IO UInt32 := do
  match args with
  | [] => refuse "ledger needs a subcommand: build, check or touch"
  | command :: rest =>
    -- Before the subcommand, because that is where a person types it: this is the
    -- only command with a subcommand in front of its flag loop, so without this
    -- arm `litedoc4 ledger --help` is refused as an unknown subcommand *named*
    -- `--help`.
    if command == "--help" || command == "-h" then do
      IO.println usage
      return 0
    else if command != "build" && command != "check" && command != "touch" then
      refuse s!"unknown `ledger` subcommand `{command}`"
    else match parseLedger command rest {} with
      | .error message => refuse message
      | .ok a =>
        if a.help then
          IO.println usage
          return 0
        try
          ledgerRun command a
        catch e =>
          IO.eprintln s!"litedoc4: {e}"
          pure (1 : UInt32)

structure ExtractArgs where
  modules : Option String := none
  irDir : Option String := none
  timings : Option String := none
  events : Option String := none
  linkIndex : Option String := none
  linkIndexOmit : Option String := none
  linkIndexKey : Option String := none
  jobs : Nat := 1
  bin : Option String := none
  target : Option String := none
  lake : Option String := none
  help : Bool := false
  deriving Inhabited

/-- Flags of the program behind this one, refused by name rather than as "unknown
argument": each is real, so what a caller needs to hear is why it is not offered
here. -/
def extractRefusal (flag : String) : Option String :=
  if flag == "--serve" || flag == "--serve-dir" || flag == "--serve-from" then
    some s!"{flag} is not an `extract` flag: residency is what `litedoc4 build` and `watch` do. A \
      server that answers one request and stops is this command with a protocol in front of it — \
      the environment is still imported once per extraction — so the only caller it can pay off \
      for is the round loop, which owns the server for the whole run. `--serve-dir` is not offered \
      anywhere: a server this process did not start is one whose olean generation it cannot vouch \
      for, and that is where correctness comes from (measured)"
  else if fixedFlags.contains flag then
    some s!"{flag} is not a flag here: it is always on. Those four are what \"IR schema 5\" means, \
      and an IR written without one of them parses and renders wrongly rather than failing"
  else if ["--no-attrs", "--no-inst-index", "--no-member-extra"].contains flag then
    some s!"{flag} is an ablation, not a product flag: it subtracts one of three extractor \
      additions so its cost can be measured, and the resulting index.json carries an `ablations` \
      list precisely because the tree is not renderable"
  else if ["--decl-profile", "--pp-breakdown", "--dump", "--dump-modules", "--dump-refs",
      "--dump-tactics", "--only", "--open", "--tag", "--skip-analyze", "--tactics-emulate",
      "--tactics-probe"].contains flag then
    some s!"{flag} is a measurement or inspection flag of the extractor, not a product one. Run \
      `extractor/build/extract` directly for it — the command line is in `Extract.lean`'s header"
  else none

partial def parseExtract : List String → ExtractArgs → Except String ExtractArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} needs a value"
    match extractRefusal flag with
    | some message => .error message
    | none =>
    if flag == "--modules" then do
      let (v, more) ← value; parseExtract more { acc with modules := some v }
    else if flag == "--ir-dir" then do
      let (v, more) ← value; parseExtract more { acc with irDir := some v }
    else if flag == "--timings" then do
      let (v, more) ← value; parseExtract more { acc with timings := some v }
    else if flag == "--events" then do
      let (v, more) ← value; parseExtract more { acc with events := some v }
    else if flag == "--link-index" then do
      let (v, more) ← value; parseExtract more { acc with linkIndex := some v }
    else if flag == "--link-index-omit" then do
      let (v, more) ← value; parseExtract more { acc with linkIndexOmit := some v }
    else if flag == "--link-index-key" then do
      let (v, more) ← value; parseExtract more { acc with linkIndexKey := some v }
    else if flag == "--extractor-bin" then do
      let (v, more) ← value; parseExtract more { acc with bin := some v }
    else if flag == "--target" then do
      let (v, more) ← value; parseExtract more { acc with target := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseExtract more { acc with lake := some v }
    else if flag == "--jobs" then do
      let (v, more) ← value
      match v.toNat? with
      | some n => parseExtract more { acc with jobs := n }
      | none => .error s!"--jobs wants a number, not {v}"
    else if flag == "--help" || flag == "-h" then
      parseExtract rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

/-- One extractor process over a module list, and its phase timers folded into
one JSON object.

**A subcommand and not a library call**, unlike every other stage: the Lean
extractor cannot be linked in — it is 171 MB, built against the *target's*
toolchain, and it has to run with that target as its working directory, so a
process boundary exists whatever this command does. -/
def extractRun (a : ExtractArgs) : BuildM Unit := do
  let some modules := a.modules
    | throw (2, "--modules <file> is required: the module list to extract, one name per line")
  let some irDir := a.irDir
    | throw (2, "--ir-dir <dir> is required and has no default: an IR tree written somewhere the \
        caller did not name is worse than none")
  let some timings := a.timings
    | throw (2, "--timings <file> is required: it is the extractor's phase timers folded into one \
        JSON object")
  if a.jobs == 0 then throw (2, "--jobs must be at least 1")
  -- Refused rather than ignored, although the extractor itself tolerates the
  -- combination: a flag that does nothing is the shape of bug this project keeps
  -- finding — the run looks right and the artefact is not the one that was asked
  -- for.
  if a.linkIndexOmit.isSome && a.linkIndex.isNone then
    throw (2, "--link-index-omit without --link-index does nothing: it names the modules whose \
      declaration groups are left out of the map, and no map is being written")
  if a.linkIndexKey.isSome && a.linkIndex.isNone then
    throw (2, "--link-index-key without --link-index does nothing: it is the token that lets the \
      extractor leave an already-correct map alone, and no map is being written or read")
  let some bin ← envOr (a.bin.map (⟨·⟩)) "EXTRACT_BIN"
    | throw (2, "--extractor-bin <path> is required (or EXTRACT_BIN): the Lean extractor built by \
        `extractor/build.sh`, which is 171 MB and is therefore not committed. There is no \
        default — the binary is built against the target's toolchain, so a path baked in here \
        would be right on exactly one machine")
  let some target ← envOr (a.target.map (⟨·⟩)) "TARGET_REPO"
    | throw (2, "--target <repo> is required (or TARGET_REPO): the Lean package being documented. \
        `lake env` runs inside it, which is how the extractor gets the oleans and the search path \
        without litedoc4 owning a toolchain")
  -- `lake` does get a default because it is a name looked up on PATH, not a
  -- path: elan installs a shim under that name, and the shim is what picks the
  -- toolchain the target pins.
  let lake := (← envOr (a.lake.map (⟨·⟩)) "LAKE").getD ⟨"lake"⟩
  let target ← match ← (IO.FS.realPath target).toBaseIO with
    | .error e => throw (3, s!"--target {target}: {e}")
    | .ok path => pure path
  let bin ← absolutePath bin
  refuseInside target "--target" ⟨irDir⟩ "--ir-dir" ""
  if let some path := a.linkIndex then
    refuseInside target "--target" ⟨path⟩ "--link-index" ""
  -- **Every path handed to the child is made absolute first, and the guard above
  -- is why** (measured 2026-08-15). `lake env` runs inside the target, so a
  -- relative path on that command line resolves against the package being
  -- documented: the guard passes (the path resolves against *this* process's
  -- directory) and the extractor then writes the IR tree inside the target.
  let irDir ← absolutePath ⟨irDir⟩
  let modulesPath ← absolutePath ⟨modules⟩
  let events ← absolutePath
    ((a.events.map (⟨·⟩ : String → System.FilePath)).getD (eventsBeside ⟨timings⟩))
  clearEvents events
  IO.FS.createDirAll irDir
  let linkIndexPath ← match a.linkIndex with
    | none => pure none
    | some path => do
      let path ← absolutePath ⟨path⟩
      if let some dir := path.parent then
        if !dir.toString.isEmpty then IO.FS.createDirAll dir
      pure (some path)
  -- Made absolute for the reason above, but **not** guarded against being inside
  -- the target: the difference is the direction of the I/O. The map is written;
  -- this one is read, and a module list that lives inside the package being
  -- documented is an odd place to keep it, not a write into it.
  let omitPath ← match a.linkIndexOmit with
    | none => pure none
    | some path => pure (some (← absolutePath ⟨path⟩))
  let args := extractArgv bin modulesPath events irDir a.jobs
    (← readConfigKeys target).noEquationsUnder linkIndexPath omitPath a.linkIndexKey
  -- The extractor's stdout is a human-readable phase report; the
  -- machine-readable copy of the same numbers is the events file, which is what
  -- the timings are folded from. stderr is inherited, so a Lean error still
  -- reaches the caller.
  let child ← match ← (IO.Process.spawn
      { cmd := lake.toString, cwd := some target, args
        stdin := .inherit, stdout := .null, stderr := .inherit }).toBaseIO with
    | .error e => throw (4, s!"{lake} env {bin}: {e}")
    | .ok child => pure child
  let code ← child.wait
  if code != 0 then
    throw (4, s!"the extractor exited {code} for {modulesPath}; the IR tree at {irDir} is \
      incomplete")
  let counted ← foldTimings { events, modules := modulesPath, jobs := a.jobs, out := ⟨timings⟩ }
  IO.println s!"extract {counted} module(s) -> {irDir} (timings {timings})"

def extract (args : List String) : IO UInt32 := do
  match parseExtract args {} with
  | .error message => refuse message
  | .ok a =>
    if a.help then
      IO.println usage
      return 0
    try
      match ← (extractRun a).run with
      | .ok () => pure (0 : UInt32)
      | .error (code, message) => if code == 2 then refuse message else refusedWith code message
    catch e =>
      IO.eprintln s!"litedoc4: {e}"
      pure (1 : UInt32)

structure StoreArgs where
  store : Option String := none
  version : Option String := none
  from_ : Option String := none
  out : Option String := none
  extractorBin : Option String := none
  root : Option String := none
  lake : Option String := none
  versions : Option String := none
  candidate : Option String := none
  chunkBytes : Option String := none
  hashUrls : Bool := false
  help : Bool := false
  deriving Inhabited

def storeCommands : List String :=
  ["put", "list", "read", "remove", "check-stale", "measure", "render"]

/-- Per subcommand for `ledgerFlags`' reason: a flag one of them takes and
ignores is a run that looks right. -/
def storeFlags : List (String × List String) :=
  [("--store", storeCommands),
   ("--version", ["put", "read", "remove"]),
   ("--from", ["put"]),
   ("--lake", ["put"]),
   ("--out", ["read", "measure", "render"]),
   ("--extractor-bin", ["check-stale"]),
   ("--root", ["check-stale"]),
   ("--versions", ["measure", "render"]),
   ("--candidate", ["measure"]),
   ("--chunk-bytes", ["measure"]),
   ("--hash-urls", ["render"])]

def storeFlagRefusal (command flag : String) : Option String :=
  match storeFlags.find? (·.1 == flag) with
  | some (_, accepted) =>
    if accepted.contains command then none
    else some s!"{flag} is not a flag of `store {command}`: it belongs to \
      {" / ".intercalate (accepted.map (s!"`store {·}`"))}"
  | none => none

partial def parseStore (command : String) : List String → StoreArgs → Except String StoreArgs
  | [], acc => .ok acc
  | flag :: rest, acc =>
    let value : Except String (String × List String) :=
      match rest with
      | v :: more => .ok (v, more)
      | [] => .error s!"{flag} needs a value"
    match storeFlagRefusal command flag with
    | some message => .error message
    | none =>
    if flag == "--store" then do
      let (v, more) ← value; parseStore command more { acc with store := some v }
    else if flag == "--version" then do
      let (v, more) ← value; parseStore command more { acc with version := some v }
    else if flag == "--from" then do
      let (v, more) ← value; parseStore command more { acc with from_ := some v }
    else if flag == "--out" then do
      let (v, more) ← value; parseStore command more { acc with out := some v }
    else if flag == "--extractor-bin" then do
      let (v, more) ← value; parseStore command more { acc with extractorBin := some v }
    else if flag == "--root" then do
      let (v, more) ← value; parseStore command more { acc with root := some v }
    else if flag == "--lake" then do
      let (v, more) ← value; parseStore command more { acc with lake := some v }
    else if flag == "--versions" then do
      let (v, more) ← value; parseStore command more { acc with versions := some v }
    else if flag == "--candidate" then do
      let (v, more) ← value; parseStore command more { acc with candidate := some v }
    else if flag == "--chunk-bytes" then do
      let (v, more) ← value; parseStore command more { acc with chunkBytes := some v }
    else if flag == "--hash-urls" then
      parseStore command rest { acc with hashUrls := true }
    else if flag == "--help" || flag == "-h" then
      parseStore command rest { acc with help := true }
    else
      .error s!"unknown argument `{flag}`"

def storePutJson (s : Store.PutSummary) : String :=
  let r := s.record
  jsonStr "{\"command\":\"store put\",\"version\":" r.version.text
    ++ s!",\"files\":{r.irFiles},\"rawBytes\":{r.irBytes}"
    ++ s!",\"linkIndexBytes\":{r.linkIndexBytes},\"packedBytes\":{s.packedBytes}"
    ++ s!",\"compressedBytes\":{r.packBytes},\"readSeconds\":{seconds s.readNanos 9}"
    ++ s!",\"packSeconds\":{seconds s.packNanos 9}"
    ++ s!",\"compressSeconds\":{seconds s.compressNanos 9}"
    ++ s!",\"digestSeconds\":{seconds s.digestNanos 9}"
    ++ s!",\"writeSeconds\":{seconds s.writeNanos 9}" ++ "}"

def storeReadJson (s : Store.ReadSummary) (writeNanos : Nat) : String :=
  let r := s.record
  jsonStr "{\"command\":\"store read\",\"version\":" r.version.text
    ++ s!",\"files\":{r.irFiles},\"rawBytes\":{r.irBytes}"
    ++ s!",\"linkIndexBytes\":{r.linkIndexBytes},\"packedBytes\":{s.packedBytes}"
    ++ s!",\"compressedBytes\":{r.packBytes},\"readSeconds\":{seconds s.readNanos 9}"
    ++ s!",\"verifySeconds\":{seconds s.verifyNanos 9}"
    ++ s!",\"decompressSeconds\":{seconds s.decompressNanos 9}"
    ++ s!",\"unpackSeconds\":{seconds s.unpackNanos 9}"
    ++ s!",\"writeSeconds\":{seconds writeNanos 9}" ++ "}"

def versionOf (a : StoreArgs) (command : String) : Except String Store.VersionName :=
  match a.version with
  | none => .error s!"store {command} needs --version <name>"
  | some name => Store.VersionName.parse name

def storePut (a : StoreArgs) (store : System.FilePath) : IO UInt32 := do
  let v ← match versionOf a "put" with
    | .error message => return ← refuse message
    | .ok v => pure v
  let some from_ := a.from_ | refuse "store put needs --from <dir>: a directory `litedoc4 build \
      --out` finished"
  let lake := (← envOr (a.lake.map (⟨·⟩)) "LAKE").getD ⟨"lake"⟩
  let origin ← match ← storePutOrigin ⟨from_⟩ lake with
    | .error message => return ← refusedWith 3 message
    | .ok origin => pure origin
  let layout := layoutOf ⟨from_⟩
  let s ← Store.put store v origin layout.ir layout.linkIndex
  IO.println s!"put     {v.text}: {s.record.irFiles} IR file(s), {s.record.irBytes} B + link \
    index {s.record.linkIndexBytes} B -> {s.record.packBytes} B ({s.record.extractorIdentity.text})"
  IO.println (storePutJson s)
  return 0

def storeRead (a : StoreArgs) (store : System.FilePath) : IO UInt32 := do
  let v ← match versionOf a "read" with
    | .error message => return ← refuse message
    | .ok v => pure v
  let s ← Store.read store v
  let started ← IO.monoNanosNow
  if let some out := a.out then Store.unpackTo ⟨out⟩ s.files
  let writeNanos := (← IO.monoNanosNow) - started
  let where_ := match a.out with
    | some out => s!" -> {out}"
    | none => " (verified, not written)"
  IO.println s!"read    {v.text}: {s.record.packBytes} B -> {s.record.irFiles} IR file(s), \
    {s.record.irBytes} B + link index {s.record.linkIndexBytes} B{where_}"
  IO.println (storeReadJson s writeNanos)
  return 0

def storeList (store : System.FilePath) : IO UInt32 := do
  let listing ← Store.list store
  for (v, record) in listing.entries do
    match record with
    | .ok r =>
      let reput := match Store.checkoutOf r with
        | .error _ => " (needs re-put)"
        | .ok _ => ""
      IO.println s!"{v.text} {r.commit} lean {r.leanVersion} {r.fill.name} \
        {r.irFiles} IR file(s) {r.irBytes} B + link index {r.linkIndexBytes} B -> \
        {r.packBytes} B{reput}"
    | .error why => IO.println s!"{v.text} unreadable: {why}"
  for name in listing.strays do
    IO.eprintln s!"litedoc4: {store / name} is not a version name and is not read"
  IO.println s!"list    {listing.entries.size} entr{if listing.entries.size == 1 then "y" else "ies"}"
  return 0

def storeCheckStale (a : StoreArgs) (store : System.FilePath) : IO UInt32 := do
  let some bin := a.extractorBin | refuse "store check-stale needs --extractor-bin <path>: the \
      extractor whose identity every entry is compared with"
  let some root := a.root | refuse "store check-stale needs --root <repo>: its litedoc4.toml \
      sets the extractor flags `build` passes, and so the identity"
  let bin ← absolutePath ⟨bin⟩
  let current ← Store.currentIdentity bin (← readConfigKeys ⟨root⟩).noEquationsUnder
  let listing ← Store.list store
  let mut fresh := 0
  let mut stale := 0
  let mut needsReput := 0
  let mut unreadable := 0
  for (v, record) in listing.entries do
    match record with
    | .ok r =>
      let isStale := Store.stale r current
      match Store.checkoutOf r with
      | .error why =>
        needsReput := needsReput + 1
        let also := if isStale then "; it is stale as well, and a build with the current extractor \
          followed by a put repairs both" else ""
        IO.println s!"{v.text} needs re-put: {why}{also}"
      | .ok _ =>
        if isStale then
          stale := stale + 1
          IO.println s!"{v.text} stale"
        else
          fresh := fresh + 1
          IO.println s!"{v.text} fresh"
    | .error why =>
      unreadable := unreadable + 1
      IO.println s!"{v.text} unreadable: {why}"
  IO.println s!"check-stale {listing.entries.size} entr\
    {if listing.entries.size == 1 then "y" else "ies"}: {fresh} fresh, {stale} stale, \
    {needsReput} needs re-put, {unreadable} unreadable ({current.text})"
  return if needsReput == 0 && unreadable == 0 then 0 else 3

def isAbsentOrEmpty (dir : System.FilePath) : IO Bool := do
  return !(← dir.pathExists) || (← isEmptyDir dir)

def measureLayout (candidate : String) (chunkBytes : Nat) (vs : Array Data.VersionData) :
    Except String Data.Layout :=
  let compress := Gzip.compress 6
  if candidate == "a" then Data.CandidateA.layout compress vs
  else if candidate == "b" then Data.CandidateB.layout compress vs
  else Data.CandidateC.layout compress chunkBytes vs

def storeMeasure (a : StoreArgs) (store : System.FilePath) : IO UInt32 := do
  let some list := a.versions | refuse "store measure needs --versions <name>,<name>..."
  let names ← match Store.versionList list with
    | .error message => return ← refuse message
    | .ok names => pure names
  let some candidate := a.candidate | refuse "store measure needs --candidate a|b|c"
  if !["a", "b", "c"].contains candidate then
    return ← refuse s!"--candidate is `{candidate}`, not a, b or c"
  let chunkBytes ← match a.chunkBytes, candidate with
    | none, _ => pure Data.CandidateC.defaultChunkBytes
    | some _, "a" | some _, "b" => return ← refuse "--chunk-bytes is a flag of --candidate c"
    | some n, _ => match n.toNat? with
      | some k => if k == 0 then return ← refuse "--chunk-bytes is 0" else pure k
      | none => return ← refuse s!"--chunk-bytes is `{n}`, not a whole number"
  if let some out := a.out then
    if !(← isAbsentOrEmpty ⟨out⟩) then return ← refusedWith 3 s!"{out} is not an empty directory"
  let mut vs : Array Data.VersionData := #[]
  for v in names do
    let s ← Store.read store v
    match Data.inputOf s.record s.files with
    | .error why => return ← refusedWith 3 s!"store entry {v.text}: {why}"
    | .ok input => vs := vs.push (Data.versionData input)
  let layout ← match measureLayout candidate chunkBytes vs with
    | .error why => return ← refusedWith 3 why
    | .ok layout => pure layout
  if let some out := a.out then
    for f in layout.files do
      let target := System.FilePath.mk out / f.path
      if let some parent := target.parent then IO.FS.createDirAll parent
      IO.FS.writeBinFile target f.stored
  IO.println ((Data.counts vs layout).json candidate
    (if candidate == "c" then some chunkBytes else none))
  return 0

def storeRender (a : StoreArgs) (store : System.FilePath) : IO UInt32 := do
  let some list := a.versions | refuse "store render needs --versions <name>,<name>..."
  let names ← match Store.versionList list with
    | .error message => return ← refuse message
    | .ok names => pure names
  let some out := a.out | refuse "store render needs --out <dir>"
  if !(← isAbsentOrEmpty ⟨out⟩) then return ← refusedWith 3 s!"{out} is not an empty directory"
  match ← (Data.Site.renderStore store ⟨out⟩ names a.hashUrls).run with
  | .error why => refusedWith 3 why
  | .ok counts =>
    IO.println counts.json
    return 0

def storeRun (command : String) (a : StoreArgs) : IO UInt32 := do
  let some store := a.store | refuse s!"store {command} needs --store <dir>"
  let store : System.FilePath := ⟨store⟩
  if command == "put" then storePut a store
  else if command == "measure" then storeMeasure a store
  else if command == "render" then storeRender a store
  else if command == "read" then storeRead a store
  else if command == "list" then storeList store
  else if command == "check-stale" then storeCheckStale a store
  else
    let v ← match versionOf a "remove" with
      | .error message => return ← refuse message
      | .ok v => pure v
    Store.remove store v
    IO.println s!"remove  {v.text}"
    return 0

def storeCmd (args : List String) : IO UInt32 := do
  match args with
  | [] => refuse s!"store needs a subcommand: {", ".intercalate storeCommands}"
  | command :: rest =>
    if command == "--help" || command == "-h" then do
      IO.println usage
      return 0
    else if !storeCommands.contains command then
      refuse s!"unknown `store` subcommand `{command}`"
    else match parseStore command rest {} with
      | .error message => refuse message
      | .ok a =>
        if a.help then
          IO.println usage
          return 0
        try
          storeRun command a
        catch e =>
          IO.eprintln s!"litedoc4: {e}"
          pure (1 : UInt32)

end Litedoc4
