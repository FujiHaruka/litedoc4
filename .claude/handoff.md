# Handoff — 2026-08-23 (リファクタリング)

## Relay control
- Mode: ON
- Goal: `docs/plans/refactoring.md` を段 0 から段 8 まで完遂する。各項目は**テストを先に書いてから直す**。
  1 commit = 1 項目。各段の終わりで下の 4 つを緑に戻す。
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: **段 0 (D0〜D14) 15 件すべて完了** + **段 1 の R1〜R6・R8 完了**。`e2b0d2c` まで push 済み

## State

- Branch: **`main`** / clean / **`e2b0d2c`** まで push 済み
- `cargo test --workspace` = **38 バイナリ / 439 passed / 0 failed / 21 ignored**
- fmt / clippy / doc / corpus-gate / provenance-gate すべて緑

### 検証コマンド (これを使う。素で回すと doc が赤くなる)

```sh
mise exec -- cargo test --workspace --no-fail-fast
mise exec -- cargo fmt --check
mise exec -- cargo clippy --workspace --all-targets -- -D warnings
RUSTDOCFLAGS='-D warnings -A rustdoc::private_intra_doc_links' \
  mise exec -- cargo doc --workspace --no-deps --document-private-items
tools/corpus-gate.sh --verify-list
```

## 済んだもの

**段 0 — 15 件すべて** (`bdad7d2`〜`f3507e4`)。詳細は計画 §3 の「結果」表。
最重要は D0 (`merge` が `--base ./ir --out ir` で IR を空にしていた) で、
**落ちるテストを先に書いて再現してから直した**。

**段 1 — 9 項目中 7 つ**:
| | 内容 | commit |
|---|---|---|
| R1 | `main.rs` 1,773 → 57 行。`lib.rs`/`stages`/`queries`/`ledger` に分割 | `5ec473c` |
| R2 | CLI パーサ 13 本を `cli.rs` に (+181/-324) | `18d5a18` |
| R3 | containment ガード 5 箇所を `refuse_inside` に | `5f22ed1` |
| R6 | `EXIT_REFUSED` (22 箇所) と `Failure::io` (29 箇所) | `26bc455` |
| R4 | `site`/`render` の入り口を `render_inputs` に | `864ce35` |
| R5 | `write_file` 5 綴り・定数 2 重定義・`events_beside` 2 実装 | `dec8e17` |
| R8 | `fold_timings` を構造体引数に、`write_timings` を enum に | `e2b0d2c` |

## Next step

**段 1 の残り 2 つ。**

- **R7** — `pipeline.rs:431` `run_incremental` (387 行) から**非本質の 3 つだけ**抜く
  (各段の `Instant` 積算 / 診断ファイルの書き出し / ログ行の組み立て)。
  **順序そのものが関数の内容なので、段の本体は割らない**。計画 §4 の R7 を読むこと
- **R9** — `USAGE` (254 行) と各サブコマンドのフラグの一致を検査する `#[test]`。
  **D1 で作った `main.rs` … 今は `ledger.rs` の `LEDGER_FLAGS` が土台**。
  **作る前に必ず一度落とす**

その後 段 2 (S1〜S8) → 段 3 (X1〜X8) → 段 4 (U1〜U6) → 段 5〜8。

## Files to read first

- `docs/plans/refactoring.md` — 冒頭に読み方がある。**§14「触らないもの」は着手前に必ず読む**
- 各段の「結果」節に、その段で分かったこと (踏んだ罠) が書いてある

## Load-bearing context

- **`cargo doc` は上のコマンドで回す。** 素で回すと intra-doc link 5 件で赤くなる
  (CI は `--document-private-items -A rustdoc::private_intra_doc_links`)
- **`#[expect]` は「発火しなくなったら落ちる」** — `cli.rs` で
  `clippy::should_implement_trait` が private 項目に発火せず落とされた。理由はコメントに移した
- **`--fix` の結果は読む** — R6 で使ったが、`needless_borrow` 6 箇所だけであることを
  `git diff` で確かめてからコミットした
- **推測で値を書かない** — D12 で `generator` を推測して間違えた
  (正しくは `"lean-doc/experiments/stage4b"`、`Extract.lean:2838`)。corpus が無いと落ちない
- **「当時の記録」と「現在の記述」を分ける** — D14 で `facts.rs:30` の見出しは残し、
  本文だけ直した。`merge.rs:46` / `facts.rs:348` の【実測 2026-08-12】は触らない
