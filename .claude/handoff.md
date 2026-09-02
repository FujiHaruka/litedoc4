# Handoff — 2026-09-02 (relay leg 1 → leg 2)

## State

**C2 and B1+B2 are done, pushed, CI green, and `v1.4.0` is released.** `main` is clean at
`3cc0d6e`, which carries the tag. A1 and C1 remain.

- `3dd37e3` **C2** — the two Markdown oracles get a Lean reader
- `abaf743` **B2 + the 1.4.0 bump** — the version inventory and its gate
- `3cc0d6e` — the gate needs tags and `actions/checkout` brings none
- tag **`v1.4.0`** at `3cc0d6e`, release published, and
  `FujiHaruka/information-theory` bumped to `@v1.4.0` (`95a7a76`). Its `docs.yml` fires on a
  tag push, so a pin bump alone would leave the live site built by v1.3.0; it was dispatched
  by hand (run 33618936007), finished green, and
  `https://fujiharuka.github.io/information-theory/` answers 200. **B1 is closed.**

Gates after this leg: `LEAN TEST GATE: ok — 223 compile-time, 33 run-time` ·
`MD ORACLE GATE: ok` · `VERSION GATE: ok — 1.4.0` ·
`WORKFLOW GATE: 32 gates, 25 from a workflow, 7 manual` · `DOCS GATE: 205 citations` ·
`PROVENANCE GATE: ok (50 claims)` · `FLAG TIE GATE: ok` · `PUBLIC SURFACE` 10/4/16/13/2.

## Relay control
- Mode: ON
- Goal: the four follow-ups after the pure-Lean port, in order — **C2** (a Lean reader for
  the two external Markdown oracles) → **B1+B2** (release v1.4.0 and close the version
  reconciliation hole) → **A1** (run the doc-gen4 comparison once, before its oracle dies,
  and record it) → **C1** (a successor for the C leak checking that left with `fuzz/`)
- Leg: 2 / cap 8
- Predecessor: none (leg 1 was the user's own session and has no tmux name — do not kill)
- Stop-on: completion
- Progress ledger:
  - r1: **C2 done** (`3dd37e3`) · **B2 + 1.4.0** (`abaf743`, `3cc0d6e`) · **v1.4.0 tagged
    and released** · information-theory pin bumped and its site rebuilt green ·
    two silent-green holes closed on the way

## Next step — A1, and it is cheaper than leg 1 assumed

Run the three homeless doc-gen4 comparisons **once**, as a recorded verification rather than
a standing gate, then write the result into `docs/verification-log.md`.

**Why a one-shot and not a gate** (decided with the user): doc-gen4 byte reproduction was
retired at M8, so a standing comparator would grow an exception list — the shape CLAUDE.md
forbids. What survives the retirement is one live 1.x promise in `tools/public-surface.txt`:
"Page paths and declaration anchors keep doc-gen4's shape". Today that promise is held only
by `e2e/micro-expected`, which is minted from litedoc4's own output and therefore cannot say
the shape was doc-gen4's to begin with. A1 answers exactly that, at 422 modules instead of a
49-file toy.

**The oracle is alive and cannot be rebuilt.** `/Users/haruka/dev/lean-projects/.lake/build/doc`
— 6,080 html pages, 736 MB, present 2026-09-02. doc-gen4 is **not** in that target
(9 packages in `lake-manifest.json`, 10 under `.lake/packages/`, neither is doc-gen4), so
`lake update` or a `.lake` wipe destroys it for good. Disk was 47 GB free.

**What each comparison asks** — read the bodies, they are precise:

    git show rust-frozen:crates/litedoc4-render/tests/pages.rs      # line 583
    git show rust-frozen:crates/litedoc4/src/packages.rs            # lines 775, 896

1. `pages_carry_the_doc_gen4_trees_declarations` — render the target's IR to a site, then for
   every page doc-gen4 also has: the declaration anchor ids (`<div class="decl" id="` theirs,
   `<section class="decl" id="` ours) as a set **and in order**, with one allowed exception —
   doc-gen4's `Process.Module.members` ends in a non-stable qsort, so the real assertion is
   that both orders visit the same **source positions** (from the IR) in the same order;
   the module docstrings (`<div class="mod_doc">` vs `<div class="moddoc">`); and the source
   links' **file paths only** (`gh_link`/`gh_nav_link` vs `a.src`) — the tree is older than
   the IR so `#L…-L…` ranges have legitimately drifted. A module doc-gen4 has no page for is
   skipped by design. No `.lidx` is needed.
2. `every_root_matches_doc_gen4s_own_blob_urls` — every resolved root's URL is the
   version-pinned blob URL doc-gen4 put on that root's `gh_nav_link`. A root with no page is
   **counted**, not passed over.
3. `every_lidx_entry_matches_doc_gen4s_declaration_urls` — needs a `.lidx` and the ~41 MB TSV
   from `benchmarks/tools/extract-decl-source-urls.sh` (in HEAD).

**Cost.** The base IR is gone (`/private/tmp/lean-doc-relay/*` is empty) but is cheap to
rebuild: `benchmarks/results/purelean-build-gate-2026-08-31.txt`:20 records a 422-module
reference IR in **21.33 s**. Write the comparator in **Python** — CLAUDE.md: do not rewrite
an oracle in the same language with the same design, which is why the site check is Python.

Then **C1**: `vendor/md4c/md4c.c` and `csrc/md_events.c` are still linked into the Lean
executable and `ci.yml` has no sanitizer job at all. Inputs exist (`hostileInputs` in
`test/Litedoc4Test/MdParse.lean` carries all twelve `fixtures/md/fuzz/` shapes as literals).
The trap is measured and named: instrumentation through one language's flags does not reach
the C compiled beside it — **1023 → 2487 coverage when `CFLAGS` was added**. Confirm the
number moves with and without instrumentation, or the gate is watching nothing.

## What a future session must not misread

- **`docgen4-expected.json` is not doc-gen4's answer throughout.** It changed sides on
  2026-08-22 (`fixtures/md/PROVENANCE.md`) — it is this repository's own output on the five
  MathML cases. `md4lean-expected.json` never changed sides and **is** MD4Lean's throughout.
  The 533/533 result is the genuinely foreign one.
- **The 327th docgen4 case is meant to differ.** MathML4Lean differs from math-core "only
  where a named rule says so" and that was adopted as "a decision about output, not a gap to
  be closed" (decided 2026-08-30, user's call). It is asserted as a **set** —
  `docGen4CasesMathML4LeanAnswersDifferently` — so a second divergence and this one going
  away both fail. **Do not drop the case and do not re-bless it.**
- **Both `tools/oracle/gen-*.ts --check` are dead**, and the handoff before this one said
  otherwise. They reach their oracle through `lake env lean` in the target, and neither
  doc-gen4 nor MD4Lean is there any more (measured 2026-09-02). The frozen answers are all
  there is. `fixtures/md/PROVENANCE.md` now says so.
- **`tools/version-sites.txt`'s column 2 is the whole point.** `tracks` names the current
  release; `frozen` is a claim about *which tag first had a property* (`v1.3.0 or later: the
  first tag a machine with only elan on it can use`) and moving it makes it false. A bulk
  replace cannot tell them apart. `tools/purelean-render-expected/input.txt`'s
  `mintedBy litedoc4 1.3.0` is a frozen oracle's provenance and is outside the gate's scope
  on purpose.

## Files to read first

1. `docs/verification-log.md` "M10 step E" — the 21 corpus questions and where each survives
2. `test/Litedoc4Test/MdOracle.lean` — what C2 built, and why the one divergence is a set
3. `tools/version-sites.txt` — the inventory whose column 2 a release has to respect

Leg 1's working notes are at
`/private/tmp/claude-502/-Users-haruka-dev-lean-doc/add12f87-972a-400a-b82d-05c6d9798940/scratchpad/relay-notes.md`,
but that is `/private/tmp` and may be gone. Everything from it that matters is above.
