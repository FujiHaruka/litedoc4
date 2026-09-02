# Handoff — 2026-09-02 (relay leg 11 → DONE)

## State

**M10 is complete. The Rust half is gone and the port is finished.** `main` is clean at `7258af4`,
pushed. **CI is green on `0707f5e`** — the deletion commit — across all five workflows (CI / lake
package / sample site / Lean versions / action). `7258af4` is `CLAUDE.md` only.

- **The product is one Lean tree, `src/` (56 modules).** No Rust, no `cargo`, no `Cargo.toml`.
  `grep -l cargo .github/workflows/*.yml` returns nothing, from 9 files.
- **`rust-frozen` is tagged and pushed**, at `43aa176` — the last commit where `crates/` is
  complete (123 files). Every citation the sweep rewrote reads `git show rust-frozen:crates/…`
  and resolves. This is the `experiments-frozen` precedent, and the tag is **the only usable form
  of that history**.
- Gates, all reproduced by hand with `crates/` gone: `PROVENANCE GATE: ok` (50 claims) ·
  `DOCS GATE: 203 citations` · `WORKFLOW GATE: 30 gates, 23 from a workflow, 7 manual; 1 workflow
  reaches node and installs it` · `PUBLIC SURFACE` 10/4/16/13/2 · `FLAG TIE GATE: ok` ·
  `LEAN TEST GATE: ok — 222 compile-time, 31 run-time` · `PURELEAN MICRO GATE: ok (16/16, 49/49)` ·
  `PURELEAN GATE: ok — 3 items` · `REFUSAL GATE: ok (lean 208/208)` · `ASSETS GATE: ok` ·
  `ASSETS EMBED GATE: ok`.

## Relay control
- Mode: DONE
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（M1〜M10）— **達成**
- Leg: 11 / cap 40
- Stop-on: completion
- Progress ledger:
  - r1–r7: M1–M9, tag `v1.3.0`
  - r8: bucket I 316/316; both expiring oracle windows closed; 135 argv refusals frozen
  - r9: D done and CI-verified · Unicode oracles measured · the second tranche read
  - r10: the tranche's machinery and 58 rows · five Lean defects found by freezing
  - r11: **the tranche complete at 73 rows** (`6acb414`) · **a sixth Lean defect, the JSON parser's
    own sentence** · **B2** (`9899f32`) · a disk emergency survived without loss ·
    **M10 step E** (`413e99d`) · **F1 + tag `rust-frozen`** (`43aa176`) ·
    **F2, the Rust half removed** (`0707f5e`) · **CLAUDE.md made true again** (`7258af4`)

## What a future session must not misread

- **Four gates lost their oracle arm and say so in their own summary line.** `refusal-gate.sh`,
  `flag-tie-gate.sh`, `purelean-micro-gate.sh`, `purelean-render-gate.sh`; `purelean-gate.sh` went
  5 items to 3. **Their frozen answers must never be re-minted from the Lean half** — that
  replaces the answer with the thing being checked. The `--mint` paths were deleted for that
  reason; do not add them back.
- **"0 workflows name cargo" is not the completion criterion**, and the plan said so in the same
  breath it stated it. It is satisfied by deleting text. What actually judged this was the eleven
  gate summary lines plus **two counts reconciled against a checklist**: provenance 62 → 50 claims
  against a 12-line `MISSING FILE` list, and gates 31 → 30 against the one deleted row.
- **`rust-differs` in `tools/refusals-on-disk.txt` has changed meaning.** It marked 25 rows where
  two implementations worded a refusal differently; **8 exist only because the Rust side named
  `crates/…` paths in messages a user reads**. No code will ever produce that wording again, so
  the field is now a record of a disagreement already settled in the Lean half's favour.

## Known gaps — a list of defects not yet known, not a list of work remaining

1. **C leak checking has no successor.** `ci-leak.yml` (LeakSanitizer) left with `fuzz/`, but the
   C it covered — `vendor/md4c/md4c.c` and `csrc/md_events.c` — is **still linked into the Lean
   executable**. Restoring it means a Lean-side harness over `hostileInputs`
   (`test/Litedoc4Test/MdParse.lean`). This is a real loss, not a tidy-up.
2. **Five corpus questions have no surviving home**, and **three of them are the only checks in
   the tree holding litedoc4 against an implementation nobody here wrote** (doc-gen4):
   `pages::pages_carry_the_doc_gen4_trees_declarations`,
   `packages::every_root_matches_doc_gen4s_own_blob_urls`,
   `packages::every_lidx_entry_matches_doc_gen4s_declaration_urls`. Their oracle is alive today at
   `/Users/haruka/dev/lean-projects/.lake/build/doc` (6,080 pages) — but **doc-gen4 is no longer in
   the target's manifest, so a `lake update` there destroys it permanently.** The reasoning is in
   `docs/verification-log.md` ("M10 step E").
3. **`web/test/fixtures/search-index.bin` has a reader and no writer.** Its successor writer is
   `searchCases` in `test/Litedoc4Test/GlobalSearchIndex.lean`, which reproduces those 761 B
   exactly (measured 2026-08-31), but **nothing automates the regeneration**.
4. **`tools/oracle/gen-docgen4-expected.ts` / `gen-md4lean-expected.ts` still produce fixtures
   nothing consumes.** Their `--check` still asks "is the committed file what the oracle says
   today"; nothing grades a parser against them any more.
5. **`fixtures/**` is a record, not a check.** Each `PROVENANCE.md` now carries a banner saying so.
   Nothing was deleted: two of the trees are named in `NOTICE` as doc-gen4's output, and deleting
   them would delete what an attribution points at.

## The lesson worth carrying past this milestone

**A frozen answer proves the two halves agreed; it never proved either was right.** That is how
the sixth Lean defect was found this leg — `Json.pVal` said `byte {c} begins none`, which is false
for the four bytes that begin `true` / `false` / `null` / a number, and **no row failed**, because
both arms read the same wrong sentence from the same parser. Three earlier legs had frozen it
unquestioned. **Now there is no second reader at all**, so a sentence of that shape has nothing
left to catch it but being read as a claim.

## Files to read first

1. `CLAUDE.md` — swept this leg; it describes the tree that exists
2. `docs/verification-log.md` "M10 step E" — the 21 corpus questions and where each survives
3. `tools/gates.txt` — 30 gates, the inventory `tools/workflow-gate.sh` checks both ways
