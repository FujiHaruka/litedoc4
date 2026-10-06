# Differential rebuild of multi-version Mathlib documentation — design memo

Date: 2026-10-06. Branch `multi-version`. Design only: nothing was measured, run or changed for this
memo. Every number carries one of (measured) / (extrapolated) / (assumed) / (theoretical) and names
the log it comes from. Logs are in `benchmarks/results/`:

- **patch log** = `mathlib-environment-patch-2026-10-05.txt`
- **consecutive log** = `mathlib-consecutive-release-reuse-2026-10-05.txt`
- **levers log** = `mathlib-build-host-levers-2026-10-05.txt`
- **runner log** = `mathlib-build-host-runner-2026-10-05.txt`
- **full-extraction log** = `mathlib-hybrid-full-extraction-2026-10-05.txt`
- **sharing log** = `mathlib-release-sharing-2026-10-04.txt`

Prototype sources read: `PrintKey.lean`, `Patch.lean`, `PatchMain.lean`, `Assemble.lean`,
`Extract.lean`, `OleanReader.lean` under `/private/tmp/lean-doc-relay/u13-host/hybrid/`. Lean
v4.34.1 sources read: `Lean/Environment.lean`, `Lean/ResolveName.lean`, `Lean/Meta/Eqns.lean`,
`Lean/Elab/PreDefinition/Eqns.lean`, `Lean/Meta/Basic.lean`, `Lean/PrettyPrinter/Delaborator/
{Builtins,FieldNotation}.lean`.

## 0. The one thing to take from this memo

**No single lever reaches the target.** The key pass (97 s) and reprinting (111 s) are 75% of a
patched version today (measured, patch log R1), and the target is 72 s for the whole version on the
M1. The design has to (1) make the key pass incremental *and* reuse more, (2) make each reprint
cheaper, and (3) cut the fixed costs — and it has to deal with a cost the target does not mention:
**on the runner, every version's workspace setup is ≈ 1.7 min (measured, runner log), which at 51
versions is ≈ 85 of the 120 budgeted minutes.** Section 2 does that arithmetic; the compute target
that survives it is ≈ 1.9 min per version on the runner *with setup moved off the critical path*.

With every lever at its central estimate the composition (section 5) lands at **≈ 2.0–2.4 h for 51
versions on the runner (theoretical)** — at or over the budget, not under it. The budget is met at
the optimistic end of every lever, or with one more structural lever: either equations become
latest-only for old versions (a D8 candidate), or the ceiling of reuse (95.99% printed-output equal,
measured) is approached more closely than the key design here promises (92–94%, theoretical).

Ranked options (section 3): **1.** incremental key pass with carried memos, shared records and a
narrower structure-data rule (no fork); **2.** equations computed without `addDecl` /
`inferDefEqAttr` (no fork; a 60-line mirror of Lean code); **3.** fixed-cost cuts: hash-first
decode in C, incremental placement, finalize audit, manifest-only IR writing, setup overlap (no
fork); **4.** exact read recording — needs a fork, and even a fork cannot hook the kernel; deferred.
Rejected with reasons (section 4): statements-only equations, zero-copy mmap of old oleans, patching
extension states through Lean's interface, per-declaration read sets without a fork.

Recommended first experiment (section 7, E1): profile the key pass by component — one afternoon,
and it decides which memo to carry first.

## 1. Where a patched version's time goes today

Second version along the patch path, M1, 4 jobs, instrumentation removed (measured, patch log R1
with R3's 4-thread decode; the log's own composition):

| phase | M1 s | of 278 | CPU (threads summed) | runner factor used by the patch log | runner s (theoretical) |
|---|---|---|---|---|---|
| closure | 3.6 | 1% | — | 1.47 (with decode) | 5 |
| decode v4.32.0 (4 threads) | 25.7 | 9% | decoding 39.9, content hash 33.0, sharing 3.0, content map 2.8 | 1.47 — but taken **single-threaded** (57.2 s) | 84 |
| delta + patch | 19.1 | 7% | delta 1.4, consts 4.9, placement 6.2, dirty 3.4, merge 3.2 | 0.86 | 16 |
| finalizeImport | 11.7 | 4% | — | 0.86 | 10 |
| key pass G7 + own (4 threads, private memos) | 97.1 | 35% | ≈ 390 (4 × 97; single-threaded it is 100–104) | 1.6 (by subtraction) | 155 |
| extraction | 111.1 | 40% | printing 137.6, equations 151.2 | 2.12 | 236 |
| of which analysis (55,390 printed, 260,835 reused) | 87.9 | | | | |
| of which writeIR | 18.2 | | serialize 15.0–15.5, hash 0.1, write 1.9 (measured, `events.jsonl` of h4310 / s4320) | | |
| bookkeeping | ≈ 10 | 4% | | | 10 |
| **total** | **≈ 278** | | | | **≈ 506 (8.4 min)** |

Memory: peak footprint 10.08 GB with the realization map emptied after each extraction; 7.45 →
9.02 GB at round ends over five rounds; a from-scratch H(32) is 4.14 GB after assembly (measured,
patch log). What the patch path keeps that a from-scratch run does not: the previous version's
printed output (all 311k `DeclOut`, tagged code included), its content map, the newest index, and
the allocator's retained pages (inferred there, not separated).

Reuse today: key-equal 83.90% of 310,899 shared declarations; printed-output equal 95.99% (the
ceiling for any rule on this pair); 74.6% of lost reuse is one component, SSTR (field/parent data
of a referenced structure: Ring 8,730, Field 8,551, Monoid 5,126, …) (measured, consecutive log).

Equation share: the reprinted 17.5% took 151.2 of the full version's 254.3 s of equation CPU (59%)
and 137.6 of 591.0 s of printing CPU (23%) (measured, patch log). The split of equation time into
generation (`getEqnsFor?` + `inferType`) and printing was **never recorded in a full run** — the
events of h4310 / s4320 carry `eqGenUs 0` because the breakdown probe runs only with
`--decl-profile`; the levers log's profiled run reports shares by declaration, not that split.

## 2. The budget, and what the target leaves out

D7 (decided 2026-10-06): all versions from nothing in ≤ 2 h on one machine (ubuntu-latest, 2 cores,
16 GB, ≈ 1.8× the M1), processed in order in one process, difference only. The plan's arithmetic:
120 min / 51 versions ≈ 2.2 min per extra version on the runner, ≈ 1.2 min on the M1.

Four things that arithmetic does not contain:

1. **Per-version workspace setup on the runner** (measured, runner log, one run each): toolchain
   install 11.3–12.0 s, `lake update` 46.8 / 45.7 s, `lake exe cache get` 42.7 / 47.8 s → ≈ 100–108
   s ≈ 1.7 min. 50 old versions × 1.7 min ≈ **85 min**. It is not in the 2.2 min, and it alone is
   77% of it. Section 3.3e moves it off the critical path (overlap with the previous version's
   compute) or shrinks it (read the reader's 6.1 GB straight from the 0.45 GB of archives).
2. **Fixed costs off the top** (theoretical from measured parts): the newest version natively ≈ 8.0
   min + ≈ 2.5 min setup and build (runner log); the first old version in the patch process ≈ 13.4 +
   1.5 min (patch log's composition). ≈ **25 min**. That leaves 95 min for the 49 patch rounds of a
   51-version set: **1.94 min ≈ 116 s per round on the runner ≈ 65 s of M1 time at 1.8×**, and only
   if setup is fully overlapped.
3. **Decode on the runner was composed single-threaded** (57.2 × 1.47 = 84 s) because 4-thread
   decoding on 2 physical cores was never measured (patch log COMPOSITION says so). The 4-thread M1
   figure (25.7 s) scaled by 1.47 would be 38 s; the truth on 2 cores is between.
4. **Minor pairs and patch pairs are different workloads.** Of the 10 transitions among today's 11
   releases, 5 are minor (x.y → x.(y+1).0) and 5 are patch (x.y.0 → x.y.1 → x.y.2). A patch pair
   shares 99.9994% of rendered declarations (measured, sharing log) against 97.89% for a minor pair;
   **its cost along the patch path is unmeasured** (the patch log says so). Every composition below
   gives the two separately; an average needs (assumed) weights — U10's 25 + 25 for 51 versions.

## 3. Options, ranked

The options combine. Each states the mechanism to the structure and hook, the time it starts from
and arrives at, memory, the soundness condition with its silent failure mode and falsifier, and the
cost — including whether a Lean fork is needed.

### Option 1 — The key pass: carried memos with explicit invalidation, shared records, and a narrower structure-data rule (no fork)

**Why first.** It is the single largest phase (97 s) and the only lever that *also* raises reuse,
which shrinks the second largest phase.

**What the key reads today** (read in `PrintKey.lean`): for a declaration `d`, `keyOf` computes own
components from `ci(d)` (name/kind/levels, type, type-as-shown via `hashSkel`, value, value-as-shown,
stored equation data via `eqnData`), the member set via `memberConsts` (structure info of `d` and
its ancestors, projection functions), then for every constant `c` in the shown set `S(d)` a
`record(c)` (type, skeleton, shape, levels, reducibility, projection info, structure info, coercion
info, instance priority, pp attributes, matcher info, protected, values, flattened layout of a
projection's structure and ancestors) and, for each namespace in `spaces(d)` (the declaration's and
its members'), `resolution(ns, c)` (every reverse alias and every suffix resolved with
`ResolveName.resolveGlobalName`). Two memos exist, `recs` by `c` and `res` by `(ns, c)`; in
`keysPar` each of 4 threads has its own and `res` is **emptied when it exceeds 1,000,000 entries**
— so 4 threads with private memos cost ≈ 390 s of CPU for 97 s of wall, against 100–104 s on one
thread (measured, patch log): the threads recompute each other's records and the resets recompute
resolutions. The number of distinct `(ns, c)` pairs and the number of resets were never counted.

**Mechanism, in four steps that each stand alone:**

1a. *Shared records.* Compute `record(c)` once for the referenced-constant set (169,119 records on
each side of the pair, measured, consecutive log) in a parallel pre-pass partitioned by name, then
read it read-only from the key threads. Resolutions likewise, keyed `(ns, c)`, in one shared map
with no cap (its size is E1's first number). Also: `getRevAliases env c` is a fold over the *whole*
alias state on every call (read in `ResolveName.lean:95`); memoize it per `c`, not per `(ns, c)`.
Expected: CPU back to ≈ 100 s, wall ≈ 25–30 s at 4 threads (theoretical: the single-threaded cost
divided by the threads, no carry-over yet).

1b. *Carried memos with explicit invalidation.* Keep `recs`, `res` and the rev-alias memo across
rounds. `Patch.build` already computes, by pointer after sharing, the changed / added / removed
constants (73,825 / 13,806 / 14,075 over the closure of v4.31.0 → v4.32.0, measured) and the
extension entries that changed or flipped key membership (72,235 flips, measured). The invalidation
rules, one per memo kind — the inputs are enumerated from the key code and the Lean helpers it calls:

   - `record(c)` is stale iff `ci(c)` is not the same pointer, **or** any decoded entry keyed by `c`
     changed in: reducibility (`reducibilityCoreExt`, `reducibilityExtra`), `projectionFnInfoExt`,
     `structureExt`, coercions (`coeExt`, a state extension whose entries carry the name),
     `instanceExtension`, the pp tag attributes, `matcherExt`, `protectedExt`, `classExtension`;
     **or** any structure in the ancestor set its layout walked (`structLayout` /
     `projStructLayout` — record the ancestor names when computing) had its `structureExt` entry
     changed; **or** — a second-order read — any constant *applied in `c`'s type* changed, because
     the skeleton hash reads `binderInfos env c'` for each applied `c'` (record the `bis` memo's
     keys as inputs). Marking: constructor-ness of `c'` is read from `ci(c')` — same input.
   - `resolution(ns, c)` is stale iff the presence (`contains` / reserved) of any *probe name*
     flipped, or an alias or protected entry on a probe name changed, or the reverse aliases of `c`
     changed. The probe set is finite and read off `ResolveName.lean`: `resolveQualifiedName` probes
     `ns' ++ id` for every prefix `ns'` of `ns` (`resolveUsingNamespace` walks prefixes), and
     `resolveGlobalName`'s loop also strips trailing components of `id` as projections — so every
     probe is `q ++ p'` with `q` a prefix of a namespace in `spaces(d)` (anonymous included) and `p'`
     a prefix of a suffix of `c` or of one of its reverse aliases. `isReservedName`'s predicates probe
     *prefixes* of the probed name (e.g. `declFromEqLikeName`), so invalidate on a presence flip of
     any prefix of a probe as well. `mkPrivateName` reads `env.mainModule`, constant across rounds.
     Implementation: for each flipped name `n` (≈ 28k per minor pair, measured), enumerate its
     splits `n = q ++ p'`, look `p'` up in a suffix → constants index, and mark `(·, c)` stale for
     those `c` (over-approximation, sound).
   - the rev-alias memo of `c` is stale iff any alias entry whose target list contains `c` changed;
     simplest sound rule: any change to the alias extension's entries invalidates all rev-alias
     memos (aliases change rarely; count per release is E1's second number).

1c. *Skip declarations whose inputs are all unchanged.* A shown-by reverse index (`c` → declarations
with `c ∈ S(d)`; ≈ 311k × |S(d)| entries, |S(d)| unmeasured — E1's third number) turns "which keys
must be recomputed" into a set union: declarations whose own `ci` changed, whose own-keyed entries
changed (`eqnsAttribute`, `eqnInfoExt`s, presence of `d.eq_<i>` / `d.eq_def` — probe names), that
show a constant whose *recomputed* record differs, or whose resolutions changed. Everything else
keeps last round's key. Note the short-circuit: a stale record that recomputes to the same value
invalidates nothing downstream. One dependence that the trigger list does not spell out but the
code covers: `memberConsts` pushes the documented structure itself, every ancestor and every
projection function into `S(d)`, so a change to their `structureExt` entries arrives through "a
shown constant whose recomputed record differs" — a reader implementing 1c from the trigger list
alone should know that is where it is caught.

1d. *The narrower structure-data rule (SSTR).* Today `record(c).struct` (fields and parents of `c`)
is mixed in for every shown `c` — so a declaration with a binder `[Ring R]` loses reuse when Ring's
fields move, though nothing printed depends on them: 28,039 declarations alone (measured,
consecutive log). In core's delaborator, one search over the four delaborator files found three
sites that read structure field data (read in v4.34.1; Mathlib's 22 hand-written `app_delab`s were
**not** read, and the soundness table carries that risk): `FieldNotation.lean:36–39` (the structure of the *projection being printed* — already
covered by SPSTR on the projection constant), `Builtins.lean:601–606` (`getStructureFields env
s.induct` when a **constructor** application prints as `{ … }`), `Builtins.lean:643` (the anonymous
constructor), plus the extractor's own member printing of the documented structure. Rule: mix
`struct(c)` (and its ancestors' layout) only when `c`'s constructor is in `S(d)`, or `c` is `d`
itself or a parent reached by `memberConsts`. This is the mechanism behind the consecutive log's
"92–94%, theoretical" (bounded by F7 84.89% and F8 94.17%, both measured); F8's five extra holes
are structure instances printing a renamed field — their constructor *is* shown, so the rule keeps
SSTR exactly there.

1e. *(Optional refinement, fork-free) instance and reduction queries recorded from the Meta cache.*
The extractor runs every declaration with a fresh Meta state and discards it (`job.toIO coreCtx {
env := env } {} {}`, read in `Extract.lean`). Returning `Meta.Cache` (`synthInstance`, `whnf`,
`inferType`, `defEqPerm`, read in `Meta/Basic.lean:415`) gives the exact instance-synthesis and
reduction problems that declaration's print posed. Re-validating a declaration = re-running each
recorded `synthInstance?` / `whnf` in the new environment and comparing results. This is a precise
fix for hole class H1 (`⊔` vs `max`: the delaborator synthesizes an order instance — 2 of 308k at 3
apart, 0 on the consecutive pair, measured, levers log) and makes the reducibility dependence G7
dropped (SRED, 25,905 output-equal declarations separated by it) exact instead of absent.
Extension-state reads (structure, projection, coe, pp) are not in that cache; it is a refinement,
not the mechanism.

**Time (theoretical).** 1a alone: 97 → ≈ 25–30 s M1. 1a + 1b + 1c: records recomputed ≈ 10–12%
(17,289 of 169,119 records differ in type between the versions, 4,182 are new — measured,
consecutive log); resolutions recomputed bounded by the probe flips (unmeasured fraction);
declaration keys recomputed for the affected set, whose size is bounded below by the 50,064
key-different and above by the declarations showing any changed constant (unmeasured; E1). Estimate
**10–20 s M1, 15–30 s runner** at 4 threads. 1d: key-equal 83.90% → 92–94%, reprinted 55,390 →
≈ 27,000 (21,800 key-different of 310,899 + 5,326 added) (theoretical from the measured bounds).

**Memory.** The carried memos: 169k records × 17 words ≈ 25 MB; the resolution map — size unknown
(E1), bounded by the thread caps today at 4 M entries ≈ a few hundred MB; the shown-by index ≈ 5 M
entries (assumed |S(d)| ≈ 15) ≈ 100–200 MB. Total ≈ 0.3–0.8 GB (assumed) on top of today's 10 GB.

**Soundness.** *Condition:* the carried key of every declaration equals the key a full pass would
compute, which holds iff every memo entry is invalidated whenever one of its enumerated inputs
changed. *What makes it silently wrong:* a read the enumeration missed — a Lean helper that consults
an extension or a name not in the lists above (the enumeration in 1b was done by reading the key
code and the helpers' sources once; it is an argument, not a proof). The consequence is a stale key
that says "equal" for a changed print — a reuse hole. *Falsifier:* a check mode that runs the full
pass beside the carried one every round and compares all keys (311k × 2 components; the comparison
is seconds, the full pass is the 97 s it costs today) on the five rounds of the v4.31.0 ⇄ v4.32.0
pair — any differing key is a missed input; then the existing IR oracle (patched IR = from-scratch IR
byte for byte; references `run/h4310/ir.sha256`, `run/s4320/ir.sha256` are on disk, the trees must
be regenerated ≈ 6 min each). For 1d: holes on the pair must stay at 0 (today 0 under G7 + own
record, measured) and the five F8 holes must be caught; a hole appearing is the rule reading the
delaborator wrong.

**Cost.** PrintKey.lean and Patch.build: ≈ 300–500 lines of Lean, 3–5 days including the check
mode. **No fork.** The soundness argument lives in the enumeration; each Lean release may add a read
to a helper, which the check mode (run once per Lean release, like `tools/lean-toolchains.txt`)
catches.

### Option 2 — Cheaper reprinting: equations without `addDecl`, and the 59% question (no fork)

**Why second.** After Option 1 the reprinted set is ≈ 27k declarations whose equations are, by the
measured skew, more than half of their cost.

**Mechanism.** Today `computeEquations` calls `getEqnsFor?`, which *realizes* the equation lemmas:
for a recursive definition `mkEqns` computes the types with `mkEqnTypes`, then for each type
`realizeConst` runs `doRealize`, which builds the proof (`mkEqnProof`), **rewrites the type using the
proof** (`removeUnusedEqnHypotheses type value`), `addDecl`s the theorem (kernel type checking) and
runs `inferDefEqAttr` (a Meta `isDefEq` deciding whether the lemma is `@[defeq]`); the extractor
then `inferType`s the new constant and prints it. For a non-recursive definition `mkSimpleEqThm`
does the same with a `rfl` proof. (All read in v4.34.1 `Lean/Elab/PreDefinition/Eqns.lean:351–397`,
`Lean/Meta/Eqns.lean:183–200`.) `unfoldThmType`, `mkEqnTypes`, `mkEqnProof`,
`removeUnusedEqnHypotheses` and `inferDefEqAttr` are all public.

The product path becomes: compute `unfoldThmType → mkEqnTypes → mkEqnProof →
removeUnusedEqnHypotheses` (or the simple theorem's type and `rfl`) in the extractor's own code and
print the resulting type directly. What is skipped: `addDecl` (the kernel re-checking a proof the
elaborator just built), `inferDefEqAttr` (read in `DefEqAttrib.lean:159`: for an equation with a
`rfl` proof, an `isDefEq lhs rhs` at implicit transparency and a second one inside
`validateDefEqAttr` at default transparency — two Meta defeq checks whose answer no page shows),
`realizeConst`'s bookkeeping, the environment growing by 58k lemmas per version, and the
realization map — the memory-growth source the patch log had to empty by hand disappears.
Sub-realizations inside `mkEqnProof` (matcher splitters, unfold lemmas) still go through Lean's
`realizeConst`; they are shared auxiliaries and far fewer.

The mirror has to reproduce `getEqnsFor?Core`'s **dispatch**, not only `mkEqns`: first
`shouldGenerateEqnThms`, then `alreadyGenerated?` (the lemmas stored in the old data — 22.86% of
definitions, measured, `mathlib-equation-sources-2026-10-04.txt`), then the registered getters in
`getEqnsFnsRef`, most recently registered first — Mathlib's `eqns`-attribute getter (which
`irreducible_def` uses) before Lean's generic one. Both `getEqnsFnsRef` and `shouldGenerateEqnThms`
are `private` (read in `Meta/Eqns.lean:110,144`), so the mirror cannot iterate the registry; it has
to know the two getters and copy `shouldGenerateEqnThms`'s body — one more thing E5's string
equality holds it to. PrintKey already reads the `eqnsAttribute` state by name, so the Mathlib
getter's inputs are reachable.

Two subtleties to hold against the oracle: the extractor prints `inferType
(mkConstWithFreshMVarLevels eq)` — level *mvars* — while the held type carries level *params*; if
the printed text differs, instantiate the held type with fresh level mvars the same way. And the
options `withEqnOptions` sets for the declaration must wrap the new path too.

**Time.** The split of the 254 s of equation CPU (full version) into generation / proof / kernel /
defeq-attribute / printing is **unmeasured** (section 1). If proof + kernel + `inferDefEqAttr` are
half (assumed) → ≈ 75 s of the reprinted set's 151 s CPU saved today, ≈ 20 s of wall at 4 jobs;
after Option 1 proportionally less in absolute terms. E5 measures it before anything is believed.

**The 59% question.** Whether the reprinted 17.5% take 59% of equation time because they *are* the
expensive declarations (the SSTR refactor changed instances, which are definitions with equations;
the realization map held 60,943 entries after the full version and ≈ 19–20k after a patch round —
one third of the realizations for one sixth of the declarations, measured, patch log) or because
fixed costs of shared auxiliaries (splitters, unfold lemmas) land on fewer declarations
(amortization) decides whether reuse alone can shrink it. `--decl-profile` on R0 and R1 answers it
per declaration (E2). If it is selection, only more reuse or cheaper equations help; if
amortization, pre-realizing the shared auxiliaries once per round is the lever.

**Equation key separate from the signature key (secondary).** A declaration whose signature key
changed but whose value, stored equation data and the records of the constants shown *in its
equations* did not could reuse last round's equations and reprint only the signature. Its share is
sizeable only if the SSTR rule (1d) leaves it so; size it from the component data of E3 before
building it.

**Soundness.** *Condition:* the held type equals the type the realized theorem would have carried.
By construction it does, except where the kernel would have **rejected** the proof: today that is
`eqFailed` (printed as "no equations"), tomorrow it is an equation the elaborator believed. 79 / 80
equation failures occur in the full runs of v4.31.0 / v4.32.0 (measured, `events.jsonl`), the
hybrid's class G among them (meta code over Qq); how many fail *in the kernel* is unknown — E5
classifies them first. *Silent failure:* a kernel-rejected equation shown as true. *Falsifier:*
total and cheap, no hybrid needed — all ≈ 58k eligible definitions of Mathlib v4.34.1 natively,
equation strings from both paths must be identical, failures classified by stage. If the kernel
rejects are not 0, the decision is a product one: keep the kernel check behind a flag for those, or
accept the elaborator's answer and count it.

**Cost.** ≈ 60 lines mirroring Lean's `mkEqns` / `mkSimpleEqThm`, 1–2 days with the oracle run.
**No fork** — but a mirror of Lean code that must be re-diffed against each Lean release (a row in
the same gate that already pins the toolchains).

### Option 3 — Cut the fixed per-version costs (no fork)

Each item is independent; together they are ≈ 65 s of the 278 s on the M1 and a larger share on
the runner, where decode and writeIR scale worst.

**3a. Hash-first decode, in C with a flat memo.** Today `decodeOne` walks every module's object graph
*twice* — `decModuleData` (rebuilding Lean objects, recomputing Name / Level / Expr hashes as
validation, with `HashMap`-by-address memos) then `hashModule` (`rawHash`, another `HashMap` memo) —
and only then replaces 88.58% of constants and 94.12% of entries by the previous version's objects,
freeing the decoded copies (measured, patch log). Hash CPU (33.0 s) is nearly as large as decoding
CPU (39.9 s). Mechanism: one pass per module over the raw bytes computing per-object content hashes
into an array indexed by object offset (no `HashMap`, no recursion), emitting per-constant and
per-entry hashes plus the entry keys the placement needs; then **decode only the objects whose hash
is absent from the previous version's map** (≈ 11% of constants, ≈ 6% of entries). The pass belongs
in `csrc/` (the tree already compiles C there); a thread per module. One premise could not be
checked — the C++ `compact.cpp` is not in the toolchain's sources — and must be probed on one
`.olean` before anything is built: *children precede parents in a compacted region*, which makes the
offset-ordered pass work with no stack. If false, an explicit stack with the same offset-indexed
memo still avoids the hash maps.

*Time (theoretical):* 7 GB per version at memory speed with ≈ 20–50 ns per object ≈ 7–14 s on one
thread, 2–4 s on 4; decoding the unmatched objects ≈ 4–5 s CPU; **decode phase 25.7 → ≈ 8–12 s
M1.** On the runner the floor is I/O: 6.1 GB of `.olean` / `.olean.server` / `.olean.private` /
`.ir` at the disk's 300–500 MB/s (assumed, from leantar unpacking 5.17 GiB there in 14.4–14.5 s of
wall — measured, `ci-warmstart-summary.txt`; reads were not measured) ≈ 12–20 s unless the page
cache still holds what `cache get` wrote. Reading straight from the 0.45 GB of `.ltar` archives
(levers log) trades that I/O for decompression CPU (≈ 7 s (assumed, at ≈ 1 GB/s of zstd output))
and removes the unpack step from setup; it needs the archive format read, a secondary lever. *Memory:* no decode-then-discard churn (today decoding the next version adds ≈
0.4–0.8 GB over the previous round's end, measured, patch log). *Soundness:* the sharing rule is
today's — equal 64-bit raw-graph hash under the writer's reducibility seed ⇒ same object; a matched
decode is discarded today anyway, so skipping it changes nothing; validation checks for an undecoded
object ran when its bytes were first decoded (by induction over rounds, given a collision-free
hash). *Silent failure:* a C pass that hashes a different graph than `rawHash` (a field skipped, a
tag misread) and so shares a changed object. *Falsifier:* the sharing decision sets (which
constants and entries are shared, both directions) must equal today's Lean pass on the pair; then
the IR oracle. *Cost:* 2–3 days of C plus the Lean glue.

**3b. Incremental placement.** `placement` is a pass over all 2.1 M entries every round (6.2 s,
measured); only entries whose key's module changed or whose extension's key set flipped move.
Theoretical 6.2 → ≈ 1 s. Soundness: the oracle `compareStates` already compares the placed state
pointer by pointer against `rewriteMerge` (ran on the sample, 0 of 10,745 modules differ, perturbed
once, measured); run it on the full data once. Cost: half a day.

**3c. finalizeImport: audit, not delta.** `finalizeImport` rebuilds the constant maps and runs
every persistent extension's `addImportedFn` over all modules' entries (`finalizePersistentExtensions`,
read in `Environment.lean:1975`); `setImportedEntries` is private and the states are opaque, so
nothing here can be patched through the API — the patch log's finding about `erased` sets stands.
What can be measured: of the 15 whole-state extensions the hybrid decodes (instances, classes,
coercions, **simp**, ext, default instances, unification hints, aliases, namespaces, matchers,
eqns, csimp, congr, tactic tags, reducibilityExtra), empty one at a time, diff the IR and time
finalize. Simp's discrimination trees over Mathlib's lemma set are the obvious candidate: whether
equation generation reads them (`simpMatch?` uses matcher equations, not the simp set — read in
`Eqns.lean`, inferred, to be confirmed by the diff) decides. Theoretical saving: unknown, perhaps a
few seconds and memory. Soundness: an emptied extension cannot answer with newest data, so a read
that matters shows up as an IR difference (the full-extraction log's rule). Cost: half a day.

**3d. IR writing in D5's shape.** `writeIRTree` re-serializes every declaration every round: 15.0–
15.5 s of serialization in 16–18 s (measured, `events.jsonl`). D5 is decided content-addressed, the
IR schema is internal (CLAUDE.md), and the differential process already knows which declarations are
reused: write each declaration's version-independent content once as a blob keyed by its hash, and
per version only the manifest (module → declarations in order → blob hash) with the
version-specific fields (positions, index, module of each ref, `generated`). Theoretical 18.2 →
≈ 3–5 s M1 (manifest + the ≈ 27k new blobs); runner 38 → ≈ 8 s. Without the format change,
serializing modules in parallel is a smaller lever (15 → ≈ 4–5 s on 4 threads, theoretical).
Soundness: the blob of a reused declaration is byte-identical by construction; the renderer's
consumer side changes with it. *Falsifier:* an adapter that assembles today's per-module JSON from
blobs + manifest, compared byte for byte with the from-scratch IR — kept only for the gate. Cost:
1–2 days on the writer, more on the renderer (part of D5's work anyway).

**3e. Setup off the critical path (runner).** While version k prints (CPU-bound on both cores), fetch
and unpack version k+1's toolchain and cache in a background process: the download is I/O, the
unpack ≈ 15 s of wall (measured, leantar on CI; its CPU share was not separated), the disk holds
two workspaces (≈ 15 GB of 86 GB
free, measured, runner log), and the previous workspace is deleted when its round ends. The ≈ 1.7
min per version (section 2) then costs ≈ 0 of wall except for the first version. `lake update` (46
s) can be replaced by shallow clones at the manifest's revisions, since the reader needs oleans and
sources only to let `cache get` compute its hashes. Soundness: none — setup is independent of the
compute. Cost: a day of shell in the workflow. **This item is a precondition for the budget, not an
optimization.**

**3f. Previous output held as serialized blobs, not `DeclOut` graphs (memory).** With 3d the
"previous output" needed for reuse is a map name → blob hash plus the blobs on disk; the ≈ 1–2 GB
(assumed; the patch log did not separate it) of `DeclOut` objects with tagged code leaves the heap.
Only reused declarations' *members' docstrings* and refs are re-read from the blob when needed.

**3g. Pipelining on the runner.** After 3a the hash pass of version k+1 is I/O-bound and the
extraction of version k is CPU-bound; overlapping them hides the decode wall (≈ 12–20 s per round on
the runner, theoretical) at the price of the next version's hash tables and decoded delta (≈ 0.5
GB, assumed) alongside the running round. Memory on the runner is the constraint to check first.

### What actually parallelizes on the 2-core runner

The task's question, answered phase by phase. Decode and hashing: I/O plus CPU, 2.2× at 4 threads
on the M1 (25.7 vs 57.2 s, measured, patch log), **unmeasured on 2 physical cores** — the patch
log's runner composition took it single-threaded. The key pass: today's 4 threads buy nothing
(97–113 s against 100–104 s single-threaded, measured) because every thread recomputes the shared
records; it parallelizes only after 1a's shared memo. Extraction: CPU-bound — 4 jobs over 2 jobs
buys 8% on 2 cores, 1 job is 1.8× slower (measured, runner log); after 1a the 4 analysis threads
are the only phase that keeps both cores busy. writeIR: serialization per module, parallelizable
today, moot after 3d. `finalizeImport` and the patch are sequential Lean code. Conclusion: on 2
cores the lever is **less work**, not more threads — and overlapping the I/O-bound phases (setup
3e, decode 3g) with the CPU-bound extraction, which is where the remaining wall clock sits.

### Option 4 — Exact read recording (fork) — deferred

**The idea.** Per declaration, record every environment query the print made (constants found *and*
names looked up but absent, extension-state reads, instance syntheses, options) with the answer's
hash; reuse iff every recorded answer is unchanged.

**Why it cannot be fork-free for the reads that matter.** `Environment.find?` (`Environment.lean:839`)
reads `env.base.get env |>.constants.map₁[n]?` then `findAsyncCore?`; `contains` goes through
`findAsync?`; extension states through `getStateImpl` on an array (`Environment.lean:1371`). They
are pure functions on a structure, reached through `getEnv`; there is no injection point in v4.34.1.
Recording them means a fork with a global recorder behind a flag inside `find?` / `contains` /
`getState` — and **a Lean-side recorder is not enough**: `addDecl` type-checks equation proofs in
C++ against the C++ environment, so completeness needs a second hook in the kernel's `find` as well.
The MetaM caches (Option 1e) cover instance synthesis and reduction fork-free; they do not cover
constant and extension reads.

**What it would cost and buy.** Re-validation is cheap: a few hundred recorded reads per declaration
× 311k ≈ 30–150 M hash lookups ≈ 3–15 s (theoretical), replacing the key pass; reuse precision
approaches the 95.99% ceiling because the read set is exact rather than approximated. Recording
slows every print (unmeasured). The maintenance price is a patched toolchain for every Lean release
the set uses (6 today, ≈ 20 in two years), rebuilt and re-verified each time.

**When to take it.** If Option 1's refinements keep leaving holes that the 1% re-print sample
(section 8) catches release after release. Not before: Option 1 reaches ≈ 92–94% without a fork,
and the holes seen so far are 1 in 310,899 on the consecutive pair (closed by the own record) and 6
in 308,089 at 3 apart (measured).

## 4. Rejected, with the reason

- **Statements-only equations** (compute `mkEqnTypes` and skip the proofs). Unsound as byte-equal:
  `mkEqns.doRealize` calls `removeUnusedEqnHypotheses type value`, which **rewrites the type using
  the proof** (read in v4.34.1 `Elab/PreDefinition/Eqns.lean:319–397`). The statement the page shows
  depends on which hypotheses the proof used. What survives is Option 2: compute the proof, skip the
  kernel.
- **Equations keyed by the definition's own content.** F8's five extra holes are equations printing
  a structure instance whose field was renamed (`smul_vsub_vadd_mem` → `smul_vsub_vadd_mem'`,
  measured, consecutive log): the equation *text* depends on the records of the constants shown in
  it, exactly as a signature does, not on the definition's value alone. An equation key has to be a
  shown-set key over the equation terms (Option 2's "separate equation key"), never the own content.
- **Zero-copy mmap of the old `.olean`s** (no decoding at all; constants are layout-identical
  across all 10 version pairs, measured, layout log). The module name determines a module's base
  address (`saveModuleDataParts`, `Environment.lean:1770`), so the newest import already occupies
  every old module's address; mapping elsewhere needs relocation, which under MAP_PRIVATE is a
  dirty copy of everything touched — the levers log's 6.9 GB of malloc. What survives is 3a:
  hash the raw bytes, decode only what changed.
- **Patching extension states by delta through Lean's interface.** `attribute [-instance]` /
  `[-simp]` add to an `erased` set and leave the discrimination tree as it is; the from-scratch
  structure is not reproduced (read in v4.34.1 by the patch log; stands).
- **Per-declaration read sets without a fork.** No hook (Option 4).
- **One runner per version in parallel.** Decided against (D7: "one machine").
- **Hashing whole `.olean` files to skip modules.** Only 11.19% of Mathlib modules are equal in
  everything and 26.29% in constants + decoded entries (measured, consecutive log); the compiler's
  extensions differ in most of the rest. The object-level hash is the unit that pays.

## 5. Composition (theoretical; premises named)

Premises: Option 1 at 1a–1d (keys 10–20 s M1, reprints ≈ 27k), Option 2 saving half of the
reprinted set's equation CPU (assumed), 3a (decode 8–12 s), 3b, 3d (writeIR 3–5 s), finalize
unchanged (3c unknown), analysis time proportional to the reprinted count with the measured skew
carried (45–55 s before Option 2, 35–45 s after — the central values below take the midpoints),
bookkeeping ≈ 8 s; runner factors as the patch log used them (decode I/O-bound 12–20 s there, patch
and finalize 0.86×, keys 1.6×, extraction 2.12×). A patch pair reprints ≈ the few hundred changed
declarations (sharing log: 99.9994% rendered-identical at v4.33.0 → v4.33.1) and pays the fixed
phases only.

| phase | today M1 | after, minor pair, M1 | after, patch pair, M1 | after, minor, runner | after, patch, runner |
|---|---|---|---|---|---|
| closure | 3.6 | 3.6 | 3.6 | 5 | 5 |
| decode | 25.7 | 8–12 | 8–12 | 12–20 | 12–20 |
| patch | 19.1 | 12–14 | 10–12 | 11–12 | 9–10 |
| finalize | 11.7 | 8–12 | 8–12 | 7–10 | 7–10 |
| keys | 97.1 | 10–20 | 5–10 | 16–32 | 8–16 |
| analysis | 87.9 | 35–45 | ≈ 5 | 75–95 | ≈ 10 |
| writeIR | 18.2 | 3–5 | 2–3 | 6–10 | 4–6 |
| other extraction + bookkeeping | ≈ 15 | ≈ 13 | ≈ 13 | ≈ 18 | ≈ 18 |
| **total** | **≈ 278** | **≈ 95–125 (1.6–2.1 min)** | **≈ 55–70 (0.9–1.2 min)** | **≈ 150–200 (2.5–3.3 min)** | **≈ 75–95 (1.3–1.6 min)** |

Against the targets: the M1 target of 1.2 min per extra version is met by patch pairs and missed by
minor pairs (1.6–2.1 min). On the runner, with setup overlapped (3e) and the 25 fixed minutes off
the top, 51 versions = 25 min + 25 minor rounds × 2.5–3.3 min + 24 patch rounds × 1.3–1.6 min =
**≈ 2.0–2.4 h** (118–146 min). **It lands at the budget only at the optimistic end of every lever;
at the central estimates (≈ 132 min) it is over by ≈ 10–25 min.** Without 3e it is over by a further ≈ 85 min regardless of
the compute levers.

What closes the gap if the central estimates hold, in order of what it gives up:

1. *Pipelining* (3g): hides ≈ 12–20 s per round on the runner (≈ 10–15 min at 49 rounds). Gives up
   nothing; costs memory headroom that is not measured on the runner.
2. *Reuse closer to the ceiling* (Option 1e, the equation key split, or Option 4): every point of
   reuse between 93% and 95.99% is ≈ 3,100 fewer reprints ≈ 5–7 s of runner time per minor round.
3. *Equations latest-only for old versions* — a D8 candidate the plan already lists. Equations are
   254 of 845 s of a full version's printing CPU and 151 of 289 s in the reprinted set (measured,
   patch log); dropping them for old versions roughly halves the reprint cost (minor round ≈ 2.0–2.6
   min on the runner, theoretical) and removes the realization machinery entirely. It is a product
   cut, and the cheapest certain one.

The 11-version set is not the problem: 9 patch rounds (≈ 5 minor, 4 patch) → 25 min + 5 × 3 +
4 × 1.5 ≈ 46 min on the runner (theoretical), well inside 2 h, as is today's path at ≈ 1.9 h
(patch log).

## 6. Soundness summary

| reuse / skip | correct iff | silently wrong when | falsifier (exists / to build) |
|---|---|---|---|
| print reuse by key (today) | key-equal ⇒ every delaborator read equal | a read the key does not model (H1 instance synthesis, H3 projection paths) | IR oracle on the pair (exists); 1% re-print sample per round (to build, §8) |
| carried key memos (1b, 1c) | every memo entry invalidated when an enumerated input changed | a helper read outside the enumeration | full pass beside carried pass, all keys equal, every round (to build); IR oracle |
| SSTR rule (1d) | structure field data is read only where the delaborator reads it (ctor shown, own members, projection's structure) | a fourth read site in the delaborator or in Mathlib's delaborators | holes on the pair stay 0; the five F8 holes caught (to run) |
| Meta-cache re-validation (1e) | recorded synth/whnf problems re-run give the same answers | a problem posed outside MetaM's cache (none known) | IR oracle; H1 cases must become key-different |
| equations without `addDecl` (2) | the kernel would have accepted | kernel-rejected equation shown | string equality over all 58k definitions natively; failures classified by stage (to run) |
| hash-first sharing (3a) | equal seeded raw-graph hash ⇒ identical bytes (today's rule) | the C pass hashes a different graph than `rawHash` | sharing sets equal to today's pass both directions; IR oracle (to run) |
| incremental placement (3b) | placed state pointer-equal to `rewriteMerge`'s | a key whose module moved and was not re-placed | `compareStates` on full data (exists, ran on the sample) |
| emptied extension (3c) | nothing printed reads it | a rare read | IR diff on the full version (the full-extraction log's rule) |
| manifest-only IR (3d) | blob identity ⇒ content identity | version-specific field left in the blob | adapter rebuilds today's JSON, byte-equal to from-scratch (to build) |

## 7. Experiment order

Smallest first; each names its falsifier and rough effort. Every program runs on the 20-module
sample before the full data (CLAUDE.md).

- **E1 — Profile the key pass by component** (records / resolution / skeleton + assembly), count
  distinct `(ns, c)` pairs and `res` resets at the 1 M cap, |S(d)| distribution, alias-entry changes
  per release. Instrument `keysPar` with the existing probe pattern; one run per version on the
  pair, keys-only (≈ 4 min each). *Kills:* if the key pass is dominated by skeleton hashing (which
  no memo carries), Option 1's 10–20 s is wrong and the lever is parallel assembly only. *Effort:*
  an afternoon.
- **E2 — `--decl-profile` on R0 and R1**, compare the reprinted set's per-declaration `eqNs` between
  the full run and the reuse run. *Decides:* selection vs amortization for the 59% (section 3,
  Option 2). *Falsifier of the amortization hypothesis:* the same declarations cost the same in
  both runs. *Effort:* one patch-process run with the flag (≈ 15 min) plus a script, half a day.
- **E3 — The SSTR rule (1d)** as a new key variant in `keysPar`; keys for both versions;
  `keycmp3.py` against regenerated IR (the trees were deleted; references are hash lists on disk,
  regeneration ≈ 6 min per version). *Falsifier:* holes > 0 under the new variant; key-equal below
  F7's 84.89% means the rule is wrong somewhere. *Effort:* one day.
- **E4 — Carried memos (1a–1c) with the check mode**, five rounds on the pair, all keys compared
  with the full pass each round, then the IR oracle. *Falsifier:* one differing key. *Effort:* 3–5
  days.
- **E5 — Equations without `addDecl`**, natively on v4.34.1: both paths over all eligible definitions,
  strings equal; the 79/80 failures classified by stage (Meta / kernel); the time split generation /
  proof / kernel / `inferDefEqAttr` / print measured for the first time. *Falsifier:* any differing
  string that fresh level mvars do not explain; kernel rejects > 0 forces the product decision.
  *Effort:* 1–2 days.
- **E6 — Children-before-parents probe** on one `.olean` (10 minutes), then the C hash pass:
  sharing sets equal to the Lean pass on the pair, both directions; then the IR oracle. *Effort:*
  2–3 days.
- **E7 — Finalize audit**: empty one whole-state extension at a time (simp first), IR diff and
  finalize time. *Effort:* half a day.
- **E8 — A patch pair on the patch path**: v4.33.0 → v4.33.1 is the natural choice, and it is also
  the first real test of the reducibility-rename seed (v4.33.0 changed the meaning of a stored
  value; the seed's handling is untested on real data — patch log). Needs a v4.33.x workspace and
  reader record. *Falsifier:* the IR oracle on both versions. *Effort:* one day plus runs.
- **E9 — The runner**: one patch process over 3 versions with setup overlapped (3e), decode threads
  at 2 and 4, memory sampled; this is where "plausible, not measured" (patch log) gets a number.

## 8. Standing checks for production

- **Re-print a seeded 1% of reused declarations each round and compare.** Does not make reuse sound;
  turns a hole into a counted, dated number instead of a wrong page (≈ 3 s per round, theoretical).
  Reported as `<checked> of <declared>`, made to fail once with a planted stale key.
- **The from-scratch oracle as a scheduled job**, not per release: the pair on disk is the fixture;
  any new Lean release re-runs E4's check mode once (the enumeration of reads is what a Lean release
  can break).
- Every reuse count, hole count and the split minor/patch per version are written to the build's
  summary, so a release where reuse drops (a refactor like Monoid's `npow`) is visible as a number,
  not as a slow build.

## 9. What this memo does not know

- The split of the key pass by component, and the distinct resolution count (E1).
- The split of equation time (E5) and whether the 59% is selection or amortization (E2).
- The patch-pair cost along the patch path, and the seed across the v4.33.0 rename (E8).
- Decode at 4 threads on 2 physical cores; memory on the runner without compression (E9).
- Whether children precede parents in a compacted region (E6's probe).
- The size of the carried memos and the shown-by index (E1, E4).
- Whether the 2.0–2.4 h composition is pessimistic or optimistic: every per-lever figure above is
  theoretical, and the ones that carry the result are Option 1's key time and the reprinted set's
  analysis time after the SSTR rule.
