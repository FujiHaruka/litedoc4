# Handoff — 2026-08-23 (リファクタリング)

## Relay control
- Mode: ON
- Goal: `docs/plans/refactoring.md` を段 0 から段 8 まで完遂する。各項目は**テストを先に書いてから直す**。
  1 commit = 1 項目 (絡んでいるものは `X2+X6` のように 2 項目 1 コミットにしてよい。
  **ただしビルドが通らない中間コミットを作るくらいなら束ねる**)。各段の終わりで下の 5 つを緑に戻す。
- Leg: 4 / cap 8
- Predecessor: refactor-r3   # 走り出しを確認したら `tmux kill-session -t refactor-r3`
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: 段 0 (15 件) 完了 / 段 1 (R1〜R9) 完了 / 段 2 は S1・S3〜S5 完了、S2 は「やらない」で決着
  - r2: **段 2 完了** / **段 3 完了** / 段 4 は U1+U2 まで (`95c7902`)
  - r3: **段 4 完了** (U3a `d885082` / U3b `04927ef` / U5+U6 `d5b9f94` / U4 `c3e8051`) →
    **段 5 は T1+T2 完了** (`5262070`)、**T3 の前提を実測で否定して計画に記録** (`bd8f0e6`)

## State

- Branch: **`main`** / clean / push 済み
- `cargo test --workspace --no-fail-fast` = **41 バイナリ / 499 passed / 0 failed / 22 ignored**
- fmt / clippy / doc / machete / corpus-gate すべて緑。`tools/watch-gate.sh` も緑 (12 checks)
- `git stash@{0}` の leg 1「S2 の RootHref」は**捨てて良い** (S2 は「やらない」で決着済)

### 検証コマンド (これを使う。素で回すと doc が赤くなる。`cargo test` は **10 分超**なので background で)

```sh
mise exec -- cargo test --workspace --no-fail-fast
mise exec -- cargo fmt --check
mise exec -- cargo clippy --workspace --all-targets -- -D warnings
RUSTDOCFLAGS='-D warnings -A rustdoc::private_intra_doc_links' \
  mise exec -- cargo doc --workspace --no-deps --document-private-items
mise exec -- cargo machete
tools/corpus-gate.sh --verify-list        # 2 分超
```

## Next step

**段 5 の T3。** ただし**計画の T3 本文は前提が崩れている** — `bd8f0e6` で
`#### 着手前の実測【2026-08-23】` を T3 の直後に足したので、**本文より先にそれを読む**。要点:
`*-reference.sh` 3 本は生きている (crate の doc が「in-process で再演する」と名指し、
`merge-reference.sh` は `LITEDOC4_MERGE_FIXTURES` の実体を作る)。消す候補は `*-compare.sh` 側だけ。

**T3 で最初に直すのは 1 つの実行できない指示**: `crates/litedoc4-incr/tests/merge.rs` の
`path_built_by("tools/merge-reference.sh --impl ts")` — **`--impl` はもう無い**。
正しくは `tools/merge-reference.sh --out <dir>` (fixtures は `<dir>/fixtures`)。
`litedoc4-testutil/src/corpus.rs` のテスト 2 箇所が綴りを固定しているので一緒に直す。

その後 T4 (**環境記録ブロックが最も価値が高い**) → T5 (`tools/lib/common.sh`) → T6 →
段 6 (C1〜C3) → 段 7 (L1〜L3) → 段 8 (E1〜E4)。

## Files to read first

- `docs/plans/refactoring.md` — **2,464 行あるが §1 が読み方を書いている** (§1・§2・§12〜§16 と
  自分の段だけ)。**`/compact-plan` をかけない**【判断、leg 3】 — 各項目の
  `#### 結果` が「予測と何が食い違ったか」の記録そのもので、圧縮すると
  【実測/外挿/仮定】ラベルと前提から先に落ちる (CLAUDE.md「docs の衛生」)。
  600 行超で圧縮対象なのは `docs/plans/feature-sweep.md` (829) で、それは段 8 の E1
- **各項目の `#### 結果【2026-08-23】`** — 段 4・段 5 で計画の件数・前提が外れた記録が全部そこ
- `tools/lib/target.sh` — 段 5 で作った唯一の共有ライブラリ。T5 の `common.sh` はこの隣
- `crates/litedoc4-testutil/src/` — 段 4 の成果 (`temp` / `corpus` / `text` / `cli` / `hash` / `tree`)

## Load-bearing context

1. **計画の件数と前提を信じない。leg 3 で 6 回外れた。**
   `DEFAULT_IR` 4 → **10**、`show` 4 → **5**、`Case::index` 4 だが一致は **2**、
   `copy_tree` 同名 3 本だが同一は **2**、T2 の「7 本上書き不能」は **4 本が上書き可・3 本はガード**、
   T3 の「参照されない 6 本」は **11 本あり crate の doc から参照されている**。**着手前に数え直す。**
2. **名前を与えられなかったフォークは、名前を数えても出てこない**【実測、leg 3】。
   `stdout` は `fn` が 1 本だけだったが同じ式が 2 箇所に直書きされていた。
   計画の件数はすべて `fn`/定数の**定義数**なので、T4 以降にも同じ死角がある。
3. **`tools/*.sh` 35 本のうち 11 本が `set -uo pipefail` (`-e` 無し)。**
   そこでは `source` の失敗が**印字されるだけで先に進む** — 実際に `watch-gate.sh` が
   壊れたライブラリで `WATCH GATE: ok` と出して exit 0 した【実測 leg 3】。
   **`tools/lib/` を source する行は必ず `… || exit 1`。** T5 で `common.sh` を作るときも同じ。
4. **`shellcheck` はこの機材に無く、CI も回していない。** `# shellcheck source=` は誰も検査していない。
   **CI は段 5 が触る 7 本を 1 本も呼ばない**ので、段 5 の変更に CI の信号は付かない。
5. **subagent の結果は必ず自分で差分を読んでから commit する。** leg 3 では 5 体すべて品質が高かったが、
   `corpus.rs` の散文が 2 箇所間違っていた (「ファイルである入力は 2 つ」→ 実際は 3 + `raw()` の 1)。
   **報告の数字ではなく差分を読む。**
6. **`target/release/litedoc4` は 8/22 のビルド。** 段 5 のゲートを回すときは、
   検査しているのが「スクリプトが走るか」なのか「製品の今の挙動か」を区別する。
