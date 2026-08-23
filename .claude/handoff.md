# Handoff — 2026-08-23 (リファクタリング)

## Relay control
- Mode: ON
- Goal: `docs/plans/refactoring.md` を段 0 から段 8 まで完遂する。各項目は**テストを先に書いてから直す**。
  1 commit = 1 項目 (絡んでいるものは `X2+X6` のように 2 項目 1 コミットにしてよい。
  **ただしビルドが通らない中間コミットを作るくらいなら束ねる**)。各段の終わりで下の 5 つを緑に戻す。
- Leg: 3 / cap 8
- Predecessor: refactoring-r2   # 走り出しを確認したら `tmux kill-session -t refactoring-r2`
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: 段 0 (15 件) 完了 / 段 1 (R1〜R9) 完了 / 段 2 は S1・S3・S4・S5 完了、S2 は「やらない」で決着 (`bec6bef`)
  - r2: **段 2 完了** (S6 `399ab77` / S7 `bb7e158` / S8 `d07212a`) →
    **段 3 完了** (X1 `e32b1dd` / X8 `ea3a43c` / X2+X6 `2083cc1` / X4 `8b0b4a5` / X7 `9ca91bc` /
    X3+X5 `760796c`) → **段 4 は U1+U2 完了** (`95c7902`)。ほかに `fba8306`

## State

- Branch: **`main`** / clean / push 済み
- `cargo test --workspace --no-fail-fast` = **41 バイナリ / 457 passed / 0 failed / 22 ignored**
- fmt / clippy / doc / corpus-gate / assets-gate / provenance-gate / pinned-dep-gate / e2e-micro すべて緑
- `git stash@{0}` に leg 1 の「S2 の RootHref」が残っている。**S2 は「やらない」で決着済なので捨てて良い**

### 検証コマンド (これを使う。素で回すと doc が赤くなる)

```sh
mise exec -- cargo test --workspace --no-fail-fast
mise exec -- cargo fmt --check
mise exec -- cargo clippy --workspace --all-targets -- -D warnings
RUSTDOCFLAGS='-D warnings -A rustdoc::private_intra_doc_links' \
  mise exec -- cargo doc --workspace --no-deps --document-private-items
tools/corpus-gate.sh --verify-list
```

## Next step

**段 4 の残り U3 → U4 → U5 → U6。** 置き場所は **`crates/litedoc4-testutil`** (U1+U2 で作った、
依存ゼロ・`TempDirs::prefixed` / `make` / `reserve` が入っている)。dev-dependency は
`litedoc4` / `-render` / `-incr` / `-global` の 4 crate に既に足してある。

- **U6 の `fnv1a64` ×4 と `copy_tree` ×2 が最も安全**(byte 同一)。**独立オラクルは TS 側**なので
  Rust 側を 1 本にしても独立性は減らない — 計画がその判定を書いている
- **U3 の `Case::index()` (`page_parts.rs` と `autolink.rs` が 8 行のコメント含め 1 文字も違わない)** と
  **`DEFAULT_IR` の 4 重定義**が本命。後者は `/private/tmp/lean-doc-relay/…` の凍結パスで §14 の対象
- **段 3 の X3 が残した宿題も U3/U6 に入る**: `file_count` が **3 → 6 コピー**に増えている
  (U3 の表は 2 つしか挙げていない)。`global.rs` と `state_and_delta.rs` の `corpus_ir` /
  `corpus_reference` は**バイト同一のフォーク**。**畳むときに `corpus_dir` と `file_count` に
  割ってはいけない** — 割ると `is_dir()` 回帰が再び開く
- U4 の fake extractor 統合は「片方の IR 生成規則が変わっても比較が成立する」形なので U3 より重い

その後 段 5 (T1〜T6) → 段 6 (C1〜C3) → 段 7 (L1〜L3) → 段 8 (E1〜E4)。
**段 5 以降は機材が要る** — §13 の表と CLAUDE.md「この機材の罠」を先に読む。

## Files to read first

- `docs/plans/refactoring.md` — 冒頭に読み方がある。**§14「触らないもの」は着手前に必ず読む**。
  **2,143 行あるが、§1・§2・§12〜§16 と自分の段だけ読めばよい** (§1 がそう書いている)
- 各項目の `#### 結果【2026-08-23】` — **予測と食い違ったことが全部そこにある**。段 4 に入る前に
  U1/U2/X3 の結果は読む
- `crates/litedoc4-testutil/src/temp.rs` — 段 4 の残りが載る場所

## Load-bearing context

1. **計画の見出しに書いてある件数を信じない。** S7 は「render 22 件 / md 3 件」だったが実際の
   re-export は **68 / 18**。X7 は「上限 3〜4 個」だったが **6 個**。X3 は「4 箇所」だったが **6 箇所**。
   X5 の表は 4 点間違っていた。**着手前に数え直す。**
2. **判定は grep ではなくコンパイラに出させる。** S7 の grep 仮説は 5 件外していた
   (`escape_html` は render のではなく `litedoc4_md` の方が使われていた)。手順は
   「候補を落とす → `cargo check --workspace --all-targets --exclude <当該 crate>` →
   エラーが名乗り出たものだけ戻す」。**そのあと必ず full `cargo test` を回す** —
   **doctest は `--all-targets` に入らない**ので `cargo check` は最後まで緑のままになる。
3. **公開方針は S7 に揃えた**【決定、leg 2】。mod は `pub` のまま、`pub use` は
   (1) 他 crate が import するもの (2) 他に経路が無いもの (私有 mod) (3) 意味の SoT (理由 1 行付き)。
   計画 X5 の「mod を非公開にする」推奨は**採らない**。5 crate 全部に適用済み。
   **ただし方針を検査するものは無い** — 私有 mod 由来 11 件のうち `unreachable_pub` が守るのは 2 件だけ。
4. **「テストが緑」は「その枝を見ている」ではない。** この leg で 4 回出た:
   S8 の `write_page` を通る非 ignore テストは 0 本、X2 の台帳 insert 規則を見るテストは 0 本
   (計画が挙げた安全網 2 つはどちらも既に消えていた)、X4 のフィクスチャは `refs` を持たず
   `used-by.json` が `{}` で「空の成果物は無い」が 2 バイトで通っていた、
   U1 の `impact.rs` には `Drop` が無く **2,276 個 / 23 MB** 残していた。
   **新しい検査は必ず一度落としてから通す。**
5. **corpus-gate の 21 と `cargo test` の 22 の差は doctest** (`cli.rs` の ```` ```ignore ````)。
   `tools/corpus-tests.txt` の冒頭に書いた。**ゲート自体は両方向で落ちる** (1 行消して確認済)。
   **3 回目の subagent がまた疑ったら、この行を指す。**
6. **subagent の結果は必ず 5 種で検証してから commit する。** この leg では全部通ったが、
   diff を読まずに信じない (計画の予測と食い違った箇所こそ価値がある)。
