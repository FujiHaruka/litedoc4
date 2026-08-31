# The second tranche: refusals that need something on disk

Investigation only — nothing was implemented, edited or committed.

Method: every candidate test body was read (plus the *producers* of each refusal in
`crates/*/src/`, which is what caught the rows no test drives). The producer sweep matters
because the test list under-counts in one direction and over-counts in the other:
`page_parts.rs` / `pages.rs` / `impact.rs` assert no refusal at all, while `queries.rs`,
`extract.rs`, `ledger.rs` and `cli_surface.rs` — none of them on the candidate list — hold
several.

Inclusion: running the `litedoc4` binary with some on-disk input makes it refuse (non-zero
exit + a message on stderr). Excluded: everything whose `@case` is already in
`tools/refusals.txt` (135 checked by name), pure internal invariants with no CLI path, and
byte-comparison fixture tests.

---

## 1. Counts

**59 rows.** By fixture kind:

| kind | rows |
|---|---|
| crafted IR tree | 17 |
| ledger JSON / a target's oleans | 7 |
| `--root` package files (`lakefile.toml`, `litedoc4.toml`, sources) | 12 |
| `--deps-docs-map` artifact | 8 |
| `--out` build directory + its marker | 4 |
| page tree + removal list | 1 |
| a `--target` directory / a child extractor process | 7 |
| a git checkout | 2 |
| `--deps-docs-url` against a resolved dependency set | 1 |

How they were counted: one row per **distinct message a user can be shown**, not one per
test. `merge --modules` disagreeing in the two directions is **one** row (one
`ModuleListMismatch` message reports both sides), while `a_file_that_is_wrong_is_an_error_and_not_a_default`
is **three** rows (three different messages in one `#[test]`).

Sub-counts worth carrying forward:

- **10 of the 59 cannot be frozen byte-for-byte** — the message embeds an OS `strerror`
  or a JSON library's parse text, which differ between Rust and Lean and between platforms.
  Marked **[OS/PARSER TEXT]** below. Freeze them by prefix, or leave them out.
- **11 of the 59 have no test at all** (found by reading the producer, not a test). Marked
  **[NO TEST]**: A9, A10, A11, A12, B4, C7, C12, D8, E4, G2, H2.
- **5 rows show a Rust/Lean wording or ordering difference beyond the OS/parser tails.**
  Marked **[DIVERGES]**: C9, C10, D2, D5, E4. Collected with the tail families in §3.

---

## 2. The rows

Message text is quoted from the source (`Display` impl or `format!`), because that is what
a frozen table stores; the test is cited as the witness that the CLI reaches it.
`main` prints `litedoc4: <message>` and adds `\n\n<usage>` **only** for `Failure::Usage`.
Every exit-3/4/5 row below, and row 17, prints **no usage block**.

### A. Crafted IR tree (17)

Reader errors are `litedoc4_ir::Error`; the CLI wraps them as `Failure::Failed` → **exit 1**.
`MIN_SCHEMA_VERSION = 5`.

**A1 — `crates/litedoc4-ir/tests/reading_a_broken_tree.rs::an_index_older_than_the_reader_is_refused_with_both_versions_and_the_way_out`**
- disk: `<ir>/index.json` with `"schemaVersion":4` (anything `< 5`); no module entries needed.
- cli: `litedoc4 global --ir <ir> --out <anywhere>` (cheapest — `global` opens the tree with
  no `--source-url` / link-index choice). Also `site`, `render`, `impact`, `merge`, `prune`.
- exit 1 — `litedoc4: index.json is schema 4; this reader needs schema 5 or newer (re-extract with --tagged-code)`
  (`what` is the literal string `index.json`, not a path — the test asserts that).
- lean: `src/Litedoc4/Ir.lean:307`, same wording.

**A2 — `…::an_ablated_index_is_refused_and_names_every_ablation`**
- disk: `index.json` with `"ablations":["no-docstrings","no-refs"]`.
- cli: as A1.
- exit 1 — `litedoc4: this IR was written with ablations [no-docstrings, no-refs] and is incomplete on purpose; it is for the stopwatch only`
- lean: `src/Litedoc4/Ir.lean:310-311`, same wording.

**A3 — `…::a_file_that_is_not_there_names_the_path_and_keeps_the_io_error`** **[OS/PARSER TEXT]**
- disk: a directory with no `index.json`.
- cli: as A1.
- exit 1 — `litedoc4: reading <dir>/index.json: No such file or directory (os error 2)`
- lean: `src/Litedoc4/Ir.lean:333` `reading {path}: {e}` — same prefix, **different tail**
  (Lean's `IO.Error`, not Rust's `io::Error`).

**A4 — `…::a_truncated_file_names_the_path_and_keeps_the_parse_error`** **[OS/PARSER TEXT]**
- disk: `index.json` holding the first half of a valid index.
- cli: as A1.
- exit 1 — `litedoc4: parsing <dir>/index.json: <serde_json message>`
- lean: has its own JSON reader; the tail differs.

**A5 — `…::a_module_file_that_disagrees_with_the_index_names_both_sides`**
- disk: a valid `index.json` filing `Micro.Basic` under `modules/Micro.Basic.json`, and that
  file declaring `"module":"Micro.Other"`.
- cli: `litedoc4 render --ir <ir> --pages <out> --source-url <40-hex blob url> --no-link-index`
  (module files are read by the renderer, not by `IrTree::open`).
- exit 1 — `litedoc4: <dir>/modules/Micro.Basic.json declares module Micro.Other, but the index files it under Micro.Basic`
- lean: `src/Litedoc4/Ir.lean:315`, same wording.

**A6 — `…::a_module_file_older_than_the_reader_is_refused_even_under_a_new_index`**
- disk: `index.json` at schema 5, `modules/Micro.Basic.json` at schema 4.
- cli: as A5.
- exit 1 — `litedoc4: <…>/modules/Micro.Basic.json is schema 4; this reader needs schema 5 or newer (re-extract with --tagged-code)`
- lean: same producer as A1.

**A7 — `crates/litedoc4-render/src/decl.rs::an_inherited_field_with_no_module_fails_the_page`**
(and the two `decl_name_to_link` cases in `an_unplaceable_name_is_an_error_and_not_a_guess`
/ `a_field_inherited_from_outside_the_package_is_found_in_the_lidx`)
- disk: an IR tree with a `structure` declaration carrying a member
  `{"label":"field","name":"P.y","isDirect":false,…}` where `P.y` is in no `refs`, in no IR
  map and in no `.lidx`.
- cli: `litedoc4 render --ir <ir> --pages <out> --source-url <url> --no-link-index`
- exit 1 — `litedoc4: rendering <Module>: declNameToLink: no defining module for P.y (doc-gen4 would panic here)`
  (the outer `rendering <module>: ` comes from `litedoc4-render/src/site.rs:220`
  `Error::Unplaceable`.)
- lean: `src/Litedoc4/Render/Decl.lean`, same wording.
- note: **no existing test drives this from the CLI** — the three tests are library-level.
  Reachability is reasoned from `render_site` → `page.rs:123` → `decl.rs:86`, not witnessed.

**A8 — `crates/litedoc4-incr/tests/merge.rs` (inside `the_module_list_orders_the_index_or_is_refused` → `curated_module_list_branches`, ~line 2142)**
- disk: a base IR whose `index.json` is `{"schemaVersion":5,"modules":["Pkg.A"],"dependencyMaps":[]}`
  (an array of **strings**), plus an `--inc` tree.
- cli: `litedoc4 merge --base <base> --inc <inc> --out <dir>`
- exit 3 — `litedoc4: <base>/index.json: an index entry has no string \`module\``
- lean: `src/Litedoc4/Incr/Merge.lean`, same wording.

**A9 — `modules` is not an array** **[NO TEST]** (`litedoc4-incr/src/merge.rs:707`)
- exit 3 — `litedoc4: <index>: modules is not an array` · same CLI as A8 · lean: Merge.lean.

**A10 — `dependencyMaps` is not an array** **[NO TEST]** (`merge.rs:662`)
- exit 3 — `litedoc4: <index>: dependencyMaps is not an array`

**A11 — a `dependencyMaps` entry with no string `file`, or a slice whose `declarations` is not an object** **[NO TEST]** (`merge.rs:670`, `merge.rs:678`)
- exit 3 — `litedoc4: <index>: a dependencyMaps entry has no string \`file\`` /
  `litedoc4: <slice>: declarations is not an object`

**A12 — the same two shapes through `prune --ir`** **[NO TEST]** (`litedoc4-incr/src/prune.rs:268,280`)
- disk: a page tree plus an `--ir` whose `index.json` has a non-array `modules` or an entry
  with no string `module`.
- cli: `litedoc4 prune --pages <tree> --ir <ir>`
- exit 3 — `litedoc4: <index>: modules is not an array` / `… an index entry has no string \`module\``
- lean: `src/Litedoc4/Incr/Prune.lean`, same wording.

**A13 — `crates/litedoc4/tests/incremental.rs::the_merge_command_takes_a_module_list`**
and `crates/litedoc4/tests/queries.rs::merge_refuses_a_module_list_that_does_not_describe_the_merged_tree_with_exit_3`
- disk: a base IR + an inc IR + a `--modules` list naming a module nothing is behind
  (and/or omitting one the tree has).
- cli: `litedoc4 merge --base <base> --inc <inc> --out <dir> --modules <list>`
- exit 3 — `litedoc4: --modules and the merged IR name different modules: 1 in the list with nothing behind them (Pkg.Ghost), 1 in the merged tree the list does not name (Pkg.C). index.json's module order is this list's, so the odd ones out would have to be guessed at — and a wrong guess moves index.json alone, where no page byte follows it`
  (the two counts elide past ten names as `…, … and N more`).
- lean: `src/Litedoc4/Incr/Merge.lean`, same wording.

**A14 — `crates/litedoc4/tests/queries.rs::impact_refuses_a_changed_module_the_index_does_not_have`**
- disk: a valid IR tree.
- cli: `litedoc4 impact --ir <ir> --changed Pkg.Aa`
- exit 3 — `litedoc4: not a module of this package: Pkg.Aa`
- lean: `src/Litedoc4/Incr/Impact.lean:233`, same wording.

**A15 — `crates/litedoc4/tests/queries.rs::impact_refuses_a_missing_ir_and_an_unrecognised_mode`** — see §4
- disk: a valid IR tree whose index really names `Pkg.A`.
- cli: `litedoc4 impact --ir <ir> --changed Pkg.A --mode everything`
- **exit 2, and no usage block** (it is `Failure::Refused{code:2}`, not `Failure::Usage`) —
  `litedoc4: unknown --mode everything`
- lean: `src/Litedoc4/Incr/Impact.lean:140`, same wording; `refusedWith` also prints no usage.

*A-group arithmetic: A11 and A12 each carry **two** messages (a `dependencyMaps` entry with
no string `file` / a slice whose `declarations` is not an object; and `modules is not an
array` / `an index entry has no string \`module\`` through `prune`). So the group is
6 IR-reader + 1 renderer + 8 `IndexShape`-and-list + 2 impact = **17 rows** across 15
labels.*

### B. Ledger JSON and a target's oleans (7)

`LEDGER_SCHEMA = 2`.

**B1 — `crates/litedoc4-incr/tests/ledger.rs` (inside `the_curated_cases_cover_what_the_package_does_not`, ~line 1150-1178)**
- disk: a ledger JSON with `"ledgerSchema":1` — or with the key removed entirely.
- cli: `litedoc4 ledger check --ledger <old.json>`
- exit 3 — `litedoc4: <path> is ledgerSchema 1; this build needs 2 (the single envKey was split into extractKey/renderKey). Rebuild the ledger.`
- lean: `src/Litedoc4/Ledger.lean:380`, same wording.

**B2 — `crates/litedoc4/tests/ledger.rs::touch_makes_the_next_check_report_that_module_as_changed_and_leaves_the_olean_alone`**
- disk: a valid ledger JSON.
- cli: `litedoc4 ledger touch --ledger <ledger.json> --module Pkg.Ghost`
- exit 3 — `litedoc4: no such module in the ledger <path>: Pkg.Ghost`
- lean: `src/Litedoc4/Ledger.lean:538`, same wording.

**B3 — `crates/litedoc4/tests/cli_surface.rs::a_run_that_could_not_finish_costs_exit_1_and_prints_no_usage`** **[OS/PARSER TEXT]**
- disk: nothing — a path that is not there.
- cli: `litedoc4 ledger check --ledger <missing>`
- exit 1 — `litedoc4: <path>: No such file or directory (os error 2)`, **no usage block**
  (the test asserts the absence of the usage block, which is the interesting half).

**B4 — a ledger that is not JSON** **[NO TEST] [OS/PARSER TEXT]**
- exit 1 — `litedoc4: <path>: <serde_json message>`

**B5 — `crates/litedoc4-incr/tests/ledger.rs` (curated cases)**
- disk: a target with `.lake/build/lib/lean/` and a `lean-toolchain`, plus a `--modules`
  list naming a module with no olean under it.
- cli: `litedoc4 ledger build --modules <list> --target <repo> --out <ledger.json>`
- exit 3 — `litedoc4: no olean under <libDir> for: Pkg.A, Pkg.B`
- lean: `src/Litedoc4/Ledger.lean:286`, same wording.

**B6 — same test, `--algorithm lake` with no `<file>.olean.hash`** **[OS/PARSER TEXT]**
- exit 1 — `litedoc4: <…>.olean.hash: No such file or directory (os error 2)`
  (the test asserts `exit_code() == 1` explicitly: "a file that would not read is not a refusal").

**B7 — same test, a target with no `lean-toolchain`** **[OS/PARSER TEXT]**
- cli: `litedoc4 ledger build …` / `ledger check … --ir <tree>`
- exit 1 — message contains `lean-toolchain`; the tail is the OS error.

### C. `--root` package files (12)

**C1–C7 — `crates/litedoc4/tests/build.rs::the_lakefile_is_read_or_refused_by_name`.**
All exit 3, all via `litedoc4 modules --root <dir>` (also reached by `build` when `--lib` is
absent). All seven end in "Pass `--lib`", by design (`crates/litedoc4/src/lakefile.rs`).
The eighth shape — no lakefile at all — is **already frozen** as `modules-no-lakefile`.

| # | disk (under `--root`) | message |
|---|---|---|
| C1 | `lakefile.lean` present, no `lakefile.toml` | `<lean> is Lean code, not data: \`lean_lib\` there is a Lake DSL command whose argument can come from an \`open\`ed namespace or from any Lean expression, so reading it honestly means elaborating it with Lake — which this command does not do. Pass --lib <Name> (repeatable) and the glob will use it` |
| C2 | `lakefile.toml` = `name = "pkg"\n` | `<toml>: no [[lean_lib]] block. A package with no library has no modules to document; if it has one under another spelling, pass --lib <Name>` |
| C3 | `[[lean_lib]]\nleanOptions = {}\n` | `<toml>: the [[lean_lib]] block ending at line 2 has no \`name\` key. Lake fills that in from the package, and inventing the value here would glob a module root nobody wrote down. Pass --lib <Name>` |
| C4 | `[[lean_lib.extra]]\nname = "Pkg"\n` | `<toml>:1: \`[[lean_lib.extra]]\` mentions lean_lib in a spelling this does not read (only a bare \`[[lean_lib]]\` header is). Skipping it would document fewer libraries than the package has, silently. Pass --lib <Name>` |
| C5 | `[[lean_lib]]\nname = { from = "pkg" }\n` | `<toml>:2: \`name = { from = "pkg" }\` is a \`name\` this does not read — it wants \`name = "<Ident>"\`, one plain double-quoted string with no escapes. Pass --lib <Name>` |
| C6 | a `"""` or `'''` anywhere in the file | `<toml>: multi-line strings are not read — inside one, a line can be anything, and this recogniser reads a leading \`[\` as a table header. Pass --lib <Name>` |
| C7 **[NO TEST]** | two `name =` keys in one `[[lean_lib]]` | `<toml>:N: a second \`name\` in one [[lean_lib]] block. Pass --lib <Name>` |

lean: `src/Litedoc4/Lakefile.lean` implements all seven, wording matches (the strings are
line-wrapped with `\` continuations in both halves, which collapse the same way).

**C8 — `crates/litedoc4/tests/incremental.rs::the_module_glob_reads_the_sources` (→ `case_module_glob`)**
- disk: any existing directory. (Cheapest fixture in the tranche.)
- cli: `litedoc4 modules --root <dir> --lib Ghost`
- exit 3 — `litedoc4: no Ghost.lean and no Ghost/ under <root>: --lib names a library root, and an empty module list would look like a package whose every module was deleted`
- lean: `src/Litedoc4/Modules.lean:43`, same wording.

**C9 — `crates/litedoc4-render/src/config.rs::a_file_that_is_wrong_is_an_error_and_not_a_default`** **[DIVERGES]**
- disk: `<root>/litedoc4.toml` = `title = \n`
- cli: `litedoc4 global --ir <anything> --out <anything> --root <dir>` — `site_config` runs
  before `build_global`, so the IR need not exist.
- exit 1 — Rust: `litedoc4: <root>/litedoc4.toml: <basic_toml message>`
- lean: `src/Litedoc4/Config.lean` has a **hand-written TOML reader**; see §3.

**C10 — same test, `titel = "typo"` (an unknown key)** **[DIVERGES]**
- exit 1 — Rust: `litedoc4: <path>: unknown field \`titel\`, expected …` (serde `deny_unknown_fields`)
- lean: `litedoc4: <path>: line 1: unknown key \`titel\``

**C11 — same test + `…::the_error_names_the_path`, `index = "docs/nope.md"` with no such file**
- exit 1 — `litedoc4: <root>/docs/nope.md: No such file or directory (os error 2)`
  (the test asserts the path is absolute and names `nope.md`). **[OS/PARSER TEXT]** for the tail.

**C12 — a `--root` whose libraries glob to zero modules** **[NO TEST]** (`crates/litedoc4/src/build.rs:515`)
- cli: `litedoc4 build --root <pkg> --out <empty> …`
- exit 3 — `litedoc4: no modules under <root> for Pkg: an empty list would build an empty site and report success`
- lean: `src/Litedoc4/Build.lean`, same wording.

### D. The `--deps-docs-map` artifact (8)

All from `crates/litedoc4/src/deps_docs.rs::a_resolved_map_of_another_shape_is_refused`
(library-level; the CLI path is `crate::with_dependency_docs` → `read_map`). `MAP_VERSION = 1`.
**The map is read before the IR tree is opened**, so the whole fixture is one JSON file:

    litedoc4 render --ir /does/not/exist --pages /tmp/p \
      --source-url https://example.invalid/o/r/blob/0123456789abcdef0123456789abcdef01234567 \
      --no-link-index --deps-docs-map <file>

All exit 3, all `litedoc4: <path>: <why>`.

| # | file body | `<why>` |
|---|---|---|
| D1 **[OS/PARSER TEXT]** | (absent) | `<OS error>. \`litedoc4 build --deps-docs-url …\` writes it` |
| D2 **[DIVERGES]** | `not json` | Rust: serde's text; Lean: its own parser's text |
| D3 | `{"version":2,"roots":[]}` | `resolved documentation map version 2, and this build reads version 1. Rebuild it with \`litedoc4 build --deps-docs-url …\`` |
| D4 | `{"version":1}` | `no \`roots\` array` |
| D5 **[DIVERGES]** | `{"version":1,"roots":[{}]}` | Rust: `a root with no \`root\` string`; Lean: `a root with no \`requestedNames\` number` (field order) |
| D6 | `{"version":1,"roots":[{"root":"Dep","base":"https://x"}]}` | `a root with no \`requestedNames\` number` |
| D7 | `…,"requestedNames":0}]}` | `a root with no \`declarations\` object` |
| D8 **[NO TEST]** | a `declarations` value that is not a string | `\`declarations.<key>\` is not a string` |

### E. The `--out` build directory and its marker (4)

`MARKER = "litedoc4-build.json"`. All from
`crates/litedoc4/tests/build.rs::a_directory_this_command_did_not_write_is_refused` except E4.
Fixture shared: a `--root` whose libraries resolve (a `lakefile.toml` with one `[[lean_lib]]`
plus the matching `<Lib>.lean` and oleans), `--link-index <file>`, `--source-url <40-hex>`,
`--extractor /bin/sh`.

**E1** — `--out` non-empty and holding no `litedoc4-build.json` →
exit 3 — `litedoc4: <out> is not empty and has no litedoc4-build.json: this command deletes and overwrites inside --out, so it will only do that to a directory it can see it wrote. Name an empty directory, or remove this one yourself`

**E2** — the same with `--full` added. A separate row on purpose: `--full` is answered
*after* the ownership check, and it is the path that **deletes** `<out>/site` and `<out>/ir`.
Same message.

**E3** — a marker whose `root` names a different package →
exit 3 — `litedoc4: <out> was built from <was>, not from <root>: the ledger under it stores the target whose oleans it hashed, and continuing here would compare one package's build tree with another package's hashes. Use a different --out`

**E4 [NO TEST] [DIVERGES]** — a `litedoc4-build.json` that is not JSON →
Rust (`build.rs:1265`): `litedoc4: <marker>: <serde message>. This file says which directory \`litedoc4 build\` owns; one that will not parse is not one to overwrite a site on the strength of`
Lean (`src/Litedoc4/Build.lean:370`): `litedoc4: <marker> will not parse. This file says which directory \`litedoc4 build\` owns; one that cannot be read is not one to overwrite a site on the strength of`

### F. Page tree + removal list (1)

**F1 — `crates/litedoc4/tests/queries.rs::prune_refuses_a_page_name_that_would_leave_the_page_tree_and_deletes_nothing`**
- disk: a page tree (`Pkg.html`, `Pkg/A.html`, …) and a `--remove` list whose **first** line
  is the Lean-escaped name `«..».Foo`.
- cli: `litedoc4 prune --pages <tree> --remove <list>`
- exit 3 — `litedoc4: refusing to delete <pages>/../Foo.html — it is not under the page root <pages>`
- lean: `src/Litedoc4/Incr/Prune.lean:59`, same wording.
- the test also asserts the guard is **lexical and runs first**: `Pkg/A.html` survives.

### G. A `--target` directory / a child extractor process (7)

**G1 — `crates/litedoc4/tests/extract.rs::an_ir_dir_inside_the_target_is_refused`**
- disk: an existing `--target` directory (it is `canonicalize`d), a `--modules` file, an
  `--extractor-bin` path.
- cli: `litedoc4 extract --modules M --ir-dir <target>/build/ir --timings T --extractor-bin B --target <target>`
- exit 3 — `litedoc4: --ir-dir <p> is inside --target <t>: the package being documented is opened read-only and nothing is ever written into it`
- lean: `src/Litedoc4/Incr/Resident.lean:87-92` (`refuseInside`), same wording.
- **not** covered by `build-out-inside-root` / `watch-out-inside-root`, which are the
  `build`/`watch` spellings of the same rule and are already frozen.

**G2 [NO TEST]** — the same rule for `--link-index` under `--target` (`extract.rs:212`) →
`litedoc4: --link-index <p> is inside --target <t>: …`

**G3 — `crates/litedoc4/tests/extract.rs::a_failing_extractor_is_exit_4_and_says_the_tree_is_incomplete`**
- disk: a fake `lake`, an extractor script that writes to stderr and exits 1, a target dir,
  a modules file.
- cli: `litedoc4 extract --modules M --ir-dir D --timings T --extractor-bin <script> --target <t> --lake <fake>`
- **exit 4** — `litedoc4: the extractor exited 1 for <modules>; the IR tree at <dir> is incomplete`
- lean: `src/Litedoc4/Main.lean`, same wording.

**G4 — `crates/litedoc4/tests/build.rs::a_failed_run_does_not_move_the_ledger` / `a_first_run_that_fails_leaves_no_ledger`**
- disk: the full `build` world + an extractor that exits non-zero.
- cli: `litedoc4 incremental … --extractor <program>` (or `build --extractor <program>`)
- **exit 4** — `litedoc4: --extractor <program> exited 1 for <modules>; the IR was not updated and nothing was rendered`

**G5 — `crates/litedoc4/src/resident.rs::a_missing_extractor_binary_is_refused_before_anything_runs`**
(library-level; the CLI wrapping is `pipeline::incremental` → `Resident::new`)
- disk: an existing `--target` directory; an `--extractor-bin` path that is not a file.
- cli: `litedoc4 incremental --ir … --serve --extractor-bin <not a file> --target <dir> …`
- exit 3 — `litedoc4: --extractor-bin <p>: not a file. It is \`extractor/build.sh\`'s output, 171 MB, built against the target's toolchain and therefore not committed`

**G6 — `crates/litedoc4/tests/resident.rs::the_two_paths_may_come_from_the_environment_instead`** **[OS/PARSER TEXT]**
- disk: `--target` pointing at a path that does **not** exist.
- cli: `litedoc4 incremental … --serve` with `EXTRACT_BIN` / `TARGET_REPO` set, or the
  equivalent flags.
- exit 3 — `litedoc4: --target /tmp/no-such-repository: No such file or directory (os error 2)`

**G7 — `crates/litedoc4/tests/incremental.rs::the_round_bound_is_exit_five` (→ `case_round_bound`)**
- disk: a whole incremental world (IR + ledger + pages + work + a fake extractor that can
  move a declaration between modules), then `--max-rounds 1`.
- cli: `litedoc4 incremental … --extractor <script> --max-rounds 1`
- **exit 5** — `litedoc4: still 1 stale module(s) after 1 round(s): Pkg.B`
- lean: `src/Litedoc4/Incr/Pipeline.lean`, same wording.
- the only exit-5 row in the tranche.

### H. A git checkout (2)

**H1 — `crates/litedoc4/tests/build.rs::the_source_url_comes_from_git`**
- disk: a `--root` that is a git checkout with at least one commit and
  `remote.origin.url = https://gitlab.com/owner/repo.git`; **no** `--source-url` on the line.
- cli: `litedoc4 build --root <checkout> --out <empty> --link-index <f> --extractor /bin/sh`
- exit 3 — `litedoc4: cannot derive --source-url from \`https://gitlab.com/owner/repo.git\`: only github.com remotes have a /blob/<rev>/<path> shape this can be sure of, and a guessed one 404s on every declaration of every page. Pass --source-url https://<host>/<owner>/<repo>/blob/<rev>`
- lean: `src/Litedoc4/Build.lean`, same wording.
- note: the message ends with the checkout's real `HEAD`, so a frozen row has to normalise it.

**H2 [NO TEST] [OS/PARSER TEXT]** — a `--root` that is not a checkout (`build.rs:1171`) →
exit 3 — `litedoc4: git rev-parse HEAD in <root> failed: <git's stderr>. --source-url is a git question — pass it explicitly if the package is not a checkout`

### I. `--deps-docs-url` against a resolved dependency set (1)

**I1 — `crates/litedoc4/src/deps_docs.rs::a_root_that_is_not_a_dependency_is_refused_with_the_ones_that_are` — UNCERTAIN**
- cli: `litedoc4 build --root <pkg> --out <empty> … --deps-docs-url Mathib=https://x`
- exit 3 — `litedoc4: --deps-docs-url Mathib=…: \`Mathib\` is not a module root of any dependency this package resolves. The roots it does resolve are: Mathlib, Init. (\`litedoc4 links --root <repo>\` prints them with their sources.)`
- **why uncertain**: the tail of the message is the resolver's answer, and
  `resolve_external_links` shells out to `lake` and reads `lake-manifest.json`. What roots
  come back depends on the machine's toolchain and on whether `lake` is on `PATH`. I checked
  `crates/litedoc4/src/build.rs:406-411` (the call site is before the marker and before Lean)
  and `packages.rs`, but I did not run anything, so I cannot say what a bare fixture root
  yields. If it is the empty set the message reads `… The roots it does resolve are: none —
  no dependency could be resolved at all, so there is nothing to link.` — which *would* be
  freezable. **Settle this by running it once before writing the row.**
- lean: `src/Litedoc4/DepsDocs.lean:142-144`, same wording.

---

## 3. Where Rust and Lean clearly differ

These are the interesting ones — a frozen table minted from Rust would fail against Lean.

1. **`litedoc4.toml` parse errors (C9, C10).** Rust uses `basic_toml` + serde
   `deny_unknown_fields`; Lean (`src/Litedoc4/Config.lean`) has a **hand-written reader**
   with its own vocabulary: `line {n}: unknown key \`{k}\``, `line {n}: \`title\` is given
   twice`, `` `{key}` is not followed by `=` ``, `a string is not closed before the end of
   the line`, `an escape names a surrogate, which is not a character`. Nothing about these
   lines up with serde's. Lean also refuses a **repeated** key, which Rust's serde accepts.
2. **`--deps-docs-map` field order (D5).** Rust evaluates `root`, `base`, `requestedNames`,
   then `declarations`/`modules`; Lean checks `requestedNames` **before** the do-block that
   reads `root`/`base`. For `{"version":1,"roots":[{}]}` — the exact body the Rust test
   uses — Rust says `a root with no \`root\` string` and Lean says
   `a root with no \`requestedNames\` number`.
3. **The corrupt build marker (E4).** Rust: `<path>: <serde message>. … one that will not
   parse is not one to overwrite a site on the strength of`. Lean: `<path> will not parse.
   … one that cannot be read is not one to overwrite a site on the strength of`. Three
   differences in one line — no colon, no serde tail, and a reworded clause.
4. **Every JSON-parse tail (A4, B4, D2).** Rust prints `serde_json`'s message; Lean prints
   its own reader's.
5. **Every I/O tail (A3, B3, B6, B7, C11, D1, G6).** `std::io::Error` vs Lean's `IO.Error`.
6. **`git`'s stderr (H2)** is passed through verbatim by both, so it is a third party's text.

Everything else I compared — the seven lakefile refusals, the IR reader's five, the ledger's
three, `impact`'s two, `prune`'s one, `merge`'s `ModuleListMismatch` and `IndexShape`,
`refuseInside`, the build marker's ownership and `was built from` lines, the source-url
refusal, the extractor's exit-4 lines, the round bound — matches word for word.

---

## 4. `impact --mode <nonsense>`: the handoff is **correct**

Confirmed by reading, not by running.

`crates/litedoc4-incr/src/impact.rs:222` (and `src/Litedoc4/Incr/Impact.lean:228`, identical):

    // With nothing changed and a mode that is not `all` there is no question.
    if options.changed.is_empty() && *options.mode != Mode::All {
        return Ok(ImpactRun { census_modules, summary: None });
    }

`Mode::Unrecognised` is not `Mode::All`, so with an empty changed set the function returns
before the `match` at line 251 that produces `Error::UnknownMode`. `queries::impact` then
prints nothing (no census, `summary: None`) and returns `Ok(())` — **exit 0, silent**.

The refusal-gate header's other claim also holds: with no IR tree the run fails on the tree
first (`IrTree::open` is called before the early return), so `impact --ir <nothing> --mode
nonsense` is exit 1 `reading …/index.json: …`, not exit 2.

**The fixture that makes it observable** is an IR tree whose `index.json` really names the
module passed to `--changed`. It must be a *real* module: the `NotAModule` check at line 233
runs **before** the mode `match`, so `--changed Pkg.Typo --mode nonsense` gives exit 3
`not a module of this package: Pkg.Typo`, not exit 2. Minimum tree: an `index.json` at
`schemaVersion 5` with one module entry and the matching `modules/<M>.json`. Then:

    litedoc4 impact --ir <tree> --changed <M> --mode everything
    → exit 2, `litedoc4: unknown --mode everything`, and **no usage block**

That last detail is worth writing down: it is the only exit-2 row in the tranche that does
**not** print `--help-all` after the message, because it travels as `Failure::Refused{code:2}`
rather than `Failure::Usage`. A gate that reuses tranche 1's `<usage>` substitution would
mint this row wrong.

`incremental --mode sideways` and `build --mode sideways` are refused at parse time and are
already frozen (`incremental-bad-mode`, `build-bad-mode`); `impact` is the only subcommand
that carries the mode.

---

## 5. Corrections to the framing

1. **The candidate list is wrong at both ends.**
   - Over-counted: `crates/litedoc4-render/tests/page_parts.rs` (7) and
     `crates/litedoc4-render/tests/pages.rs` (9) are **pure F bucket** — frozen
     content-comparison against the prototype's output. Their `Err(...)` hits are the
     comparator's own diff type, not product refusals. `crates/litedoc4-incr/tests/impact.rs`
     (2) is one corpus comparison + one coverage-accounting test: **zero refusals**.
     `crates/litedoc4-incr/src/prune.rs` (2) is two happy-path deletion tests: **zero**.
     `crates/litedoc4-render/src/decl.rs` (21) contributes **one** row (A7), not 21.
     `crates/litedoc4/tests/site.rs` (11) contributes **zero** — every one of its refusals is
     argv-only and already frozen (`site-no-link-index-choice`, `site-both-link-index`,
     `site-only`, `site-only-from`, `site-before`, `site-print-set`, `site-delta-json`,
     `site-pages`, `site-ir-required`, `site-out-required`, `site-source-url-required`,
     `site-unknown-flag`); the synthetic IR those tests build is never read.
     `crates/litedoc4/tests/resident.rs` (8) contributes **one** (G6) — the other seven are
     argv/env refusals that fire before a process exists.
     `crates/litedoc4-incr/src/io.rs` (3) contributes **zero** rows I would freeze: they are
     generic "a file is in the way" `Error::Io`s whose whole message is an OS strerror.
   - Under-counted: **four files not on the list carry rows** —
     `crates/litedoc4/tests/queries.rs` (A14, A15, D-adjacent, F1, plus a `links` exit-1),
     `crates/litedoc4/tests/extract.rs` (G1, G3),
     `crates/litedoc4/tests/ledger.rs` (B2),
     `crates/litedoc4/tests/cli_surface.rs` (B3).
     And **eleven rows have no test at all** — they were found only by sweeping the
     `Failure::Refused` / `Failure::Failed` construction sites in `crates/litedoc4/src/`
     (152 sites) and the `Error` variants in `litedoc4-incr` / `litedoc4-ir` /
     `litedoc4-render`.

2. **`crates/litedoc4-ir/tests/reading_a_broken_tree.rs` holds 7 `#[test]`s but 6 rows.**
   `open_unvalidated_reads_exactly_what_open_refuses` is not a seventh refusal — it asserts
   that `open_unvalidated` *does not* refuse the two shapes `open` does. It is the I bucket.
   (So the "13 crafted trees" claim was wrong in the way the brief says, and "7" is also not
   the row count.)

3. **Two gaps in tranche 1, not tranche 2** (argv-only, no disk, but not in `refusals.txt`):
   - `litedoc4 site --ir A --out B --source-url` (flag at the end of the line) →
     `--source-url needs a value`. `crates/litedoc4/tests/site.rs::the_rest_of_the_command_line_is_checked`
     covers it; only `site-out-needs-a-value` and `links-*-needs-a-value` were frozen.
   - The whole `--serve` family in `crates/litedoc4/tests/resident.rs` is **env-sensitive**:
     `incremental --serve --target /tmp/repo` refuses with `EXTRACT_BIN … 171 MB` only when
     `EXTRACT_BIN` is unset, and `TARGET_REPO=` (empty) is its own exit-2 row. `refusals.txt`
     runs with the ambient environment and has no `env` column, so these four cases
     (`EXTRACT_BIN` required, `TARGET_REPO` required, empty-`TARGET_REPO`, and the env-supplied
     pair) are frozen nowhere. If the gate grows an `env` line they belong in tranche 1.

4. **"an on-disk `--only-from` list" is nearly empty as a fixture kind.** `ModuleSet::from_lines`
   cannot fail, so an *existing* list produces no refusal on `render`/`site`. The only
   `--only-from` refusal is the file being absent (exit 1, an OS message). The content-driven
   list refusals all live on other flags: `--modules` (A13, B5), `--changed`/`--changed-file`
   (A14), `--remove` (F1). I folded them into their own kinds rather than keeping
   `--only-from` as a category.

5. **`build-out-inside-root` and `watch-out-inside-root` are frozen; `extract`'s two are not.**
   The same `refuse_inside` rule has four CLI spellings and tranche 1 took two of them.

---

## 6. Corrections measured while freezing the first 20 rows (leg 10)

Groups D and C are frozen in `tools/refusals-on-disk.txt`. Everything below was measured
against both binaries on the exact fixture that is now committed, so it overrides §1–§5 where
they disagree.

**The row count moves 59 → 60, and 20 of them are frozen.** Group D is 8 of 8. Group C is 12,
but not the twelve §2 lists: a **fourth** `litedoc4.toml` message exists that nothing counted,
and **C12 is deferred** rather than approximated (below).

1. **§3.1 is wrong: Rust refuses a repeated key too.** `title = "a"` twice gives
   ``litedoc4: <path>: duplicate key: `title` at line 2 column 1``, exit 1 — it is not accepted.
   Lean says ``line 2: `title` is given twice``. So the `litedoc4.toml` test carries **four**
   distinct messages, not three; the fourth is frozen as `config-key-twice`.

2. **C3 diverges, and §3's closing claim is falsified.** "the seven lakefile refusals … match
   word for word" does not hold: for `[[lean_lib]]\nleanOptions = {}\n` Rust says
   `the [[lean_lib]] block ending at line 2` and Lean says `line 3`. Narrowed by measurement —
   they agree when the file has **no** trailing newline and when another table header follows,
   and diverge whenever the block runs to the end of a newline-terminated file, i.e. the
   ordinary shape. **Lean's splitter counts the empty final line.** A defect, not a wording
   choice; the fix belongs in `src/Litedoc4/Lakefile.lean`.

3. **C11 diverges structurally, not just in its OS tail.** Marked `[OS/PARSER TEXT]`, which
   implies a prefix freeze would do. It would not: Rust prints one line
   `litedoc4: root/docs/nope.md: No such file or directory (os error 2)`, Lean prints **two** —
   `litedoc4: no such file or directory (error code: 4294967294)` and `  file: root/docs/nope.md`
   — **losing the `litedoc4: <path>: ` framing entirely**. That is a user-visible regression in
   `src/Litedoc4/Config.lean`'s `index` read, and it needs a decision rather than an automatic
   fix. The row is frozen as Lean answers today.

4. **Do not assume the ten `[OS/PARSER TEXT]` rows share one shape.** D1 and C11 are both "a
   file that is not there" and Lean renders them differently: D1 keeps litedoc4's own
   `<path>: <err>` wrapper on one line, C11 surfaces the raw `IO.Error`
   (`fopenErrorToString` → `…\n  file: <fn>`). A wildcard is **per line** and cannot span that.
   So "10 rows can be handled by a prefix" has to be **measured row by row**; at least one of
   the ten cannot.

5. **D2 is a real divergence, not an OS tail.** Rust `expected ident at line 1 column 2`;
   Lean `a value was expected at 0, and byte 110 begins none`. Two independent JSON readers.

6. **D8's fixture is not `"declarations": []`.** An array is not an object, so that body gives
   D7's message. The fixture has to be an object holding a non-string value —
   `{"Dep.a":1}` → ``\`declarations.Dep.a\` is not a string``.

7. **C11's message does not force an absolute path.** §2 says "the test asserts the path is
   absolute", which is true of the test and not of the message: with a relative `--root`, Rust
   prints `root/docs/nope.md`. The frozen row uses that, so it stores no absolute path.

### C12 is deferred on purpose, and it decides the shape of E, F, G and H

`litedoc4 build` is the only route to `no modules under <root> for <libs>` — `modules --root`
with the same fixture exits **0 silently**. `build` prints four lines to stdout first,
including one naming whatever toolchain elan has, so the line count is the machine's, not the
program's.

That is the general problem, not C12's: **every route to a group-D refusal already prints
before it refuses** (`resolve_external_links` reports how the external links resolved, before
the map is opened), and **groups E, F, G and H are all `build` / `incremental` / `prune`
shaped**. The gate's answer so far is the per-row `stdout-not-frozen <why>` declaration — the
row freezes stderr only, an undeclared byte on stdout still fails, and the summary counts the
declaring rows. **Settle whether that is the policy for the remaining groups before minting
them**, or each stage will invent its own.

### A door the port lost, which earns rows of its own in group A

`crates/litedoc4-ir/src/model.rs:42-53` — `IndexEntry` requires `module`, `file`, `bytes`,
`declarations` and `contentHash`; an entry missing one is refused when the tree is opened
(measured: `litedoc4: parsing ir/index.json: missing field \`bytes\` at line 1 column 114`,
exit 1). `src/Litedoc4/Ir.lean:247-259` gives **every field a default** and accepts the same
tree.

It is not cosmetic. `contentHash` absent collapses to `""` on both sides of two comparisons:
`src/Litedoc4/Global.lean:77` reads that as a **cache hit** and serves stale `ModuleFacts`, and
`src/Litedoc4/Incr/Merge.lean:314` reads it as **not changed** and renders no page. `bytes`
absent makes `impact`'s reported cost silently 0. Reachable from any tree a user names —
`global --ir`, `merge --base`, `impact --ir`, `render --ir`.

`Incr/Merge.lean` already hand-checks ``an index entry has no string `module` `` (rows A9–A12)
while the reader path does not: one question, two answers, and only one of them was being
fixed. **Fix the reader before minting group A** — those fixtures are minted from Rust and
therefore already carry complete entries, so the fix makes the two halves agree at the door.

### Four Lean changes this leaves pending

1. `src/Litedoc4/DepsDocs.lean` — answer `root` before `requestedNames` (D5). Until then
   `deps-map-root-empty` and `deps-map-root-no-requested-names` freeze **identical bodies**,
   because Lean answers `requestedNames` for both; the reorder separates them.
2. `src/Litedoc4/Lakefile.lean` — the off-by-one of correction 2.
3. `src/Litedoc4/Config.lean` — the lost framing of correction 3 (a decision, not a fix).
4. `src/Litedoc4/Ir.lean` — the door above.

Each drops a `rust-differs` flag when it lands, and each needs a re-mint **while the Rust
binary still exists**.
