# Handoff — 2026-08-24 (コメント削減)

## Relay control
- Mode: ON
- Goal: `CLAUDE.md` の新しい `## コードのコメント` 規則 (既定はコメントしない /
  非自明な why not だけ) に合わせて、**コード表面のコメントを全面的に削減する**。
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: `CLAUDE.md` の規則整備 (`c57f2df` `3ad2073`) + Rust 4 crate
    (`03e1ded` `fcc4b6a` `1934448` `ee173e1`)。**4289+2303 → 3867 行、−41%**

## この作業の規範

- **`CLAUDE.md` の `## コードのコメント`** が規範。
- **作業手順版は `/private/tmp/lean-doc-relay/comment-diet/policy.md`**
  — 消す 8 分類 / 残す a〜e / 絶対に消さない (provenance) / 触らない /
  言語ごとの追記 / 線引きの追記 / 検証は `cargo check` では足りない。
  **subagent には必ずこれを読ませる。** 消えていたら CLAUDE.md から再生成する。
- **プロンプト雛形は `/private/tmp/lean-doc-relay/comment-diet/prompt-template.md`**。
  実際に投げた完全版は git 履歴ではなく、この handoff の下の「進め方」に要点がある。

## 進め方 (確立済み。この形で回す)

1. crate / ディレクトリ単位で subagent に dispatch (**同時 1 体**、**commit させない**)
2. 戻ってきたら **`git diff -U0 <範囲> | grep -E '^[-+]' | grep -vE '^[-+]{3}' |
   grep -vE '^[-+]\s*(//|/\*|\*)' | grep -vE '^[-+]\s*$'`** で
   **コメント以外の変更**を洗い出して読む (毎回 1〜2 行は出る。妥当なら通す)
3. **`/private/tmp/lean-doc-relay/comment-diet/verify.sh --fast`** を回す
   (fmt / clippy / doc / provenance / doctest の 5 段。**パイプ無し**、
   各段のログは `logs/<段>.log`)。引数なしで CI の 8 段全部 (`cargo test` を含むので遅い)
4. 緑なら `git add <範囲> && git commit && push`

**subagent プロンプトに必ず入れる 3 点** (これが無いと緩くなる / 壊れる):

- **判定基準**: 「名前が言っているか」「本体を 3 秒読めば分かるか」— **どちらか yes なら消す**。
  「あると親切」は残す理由にならない
- **`cargo check` では足りない。`cargo clippy --workspace --all-targets -- -D warnings` を回せ**
  (折り返した doc 行の行頭が `+` / `-` になると `clippy::doc_lazy_continuation` で落ちる【実測】)
- **そのバッチに含まれる provenance 対象ファイルと必要文字列の表**

## 済んだもの

| 範囲 | before → after | | commit |
|---|---|---|---|
| `CLAUDE.md` の規則整備 | — | | `c57f2df` `3ad2073` |
| `crates/litedoc4-ir` | 1098 → 526 | −52% | `03e1ded` |
| `crates/litedoc4-md` | 1271 → 766 | −40% | `fcc4b6a` |
| `crates/litedoc4-global` | 1920 → 1154 | −40% | `1934448` |
| `crates/litedoc4-incr` | 2303 → 1421 | −38% | `ee173e1` |

## 残っている範囲

| 範囲 | ファイル | コメント行 | 状態 |
|---|---|---|---|
| `crates/litedoc4-render/src` + `build.rs` | 14 | 2564 | **r1 で subagent 実行中** |
| `crates/litedoc4-render/tests` | 10 | 1234 | 未 |
| `crates/litedoc4/src` | ? | 大 | 未 (`pipeline.rs` 703 / `build.rs` 553 / `resident.rs` 374) |
| `crates/litedoc4/tests` | ? | 大 | 未 (crate 合計 5210) |
| `crates/litedoc4-testutil` | 7 | 689 | 未 |
| `tools/*.sh` (+ `tools/lib`) | ~30 | 3396 | 未 |
| `extractor/Extract.lean` + `lakefile.lean` | 2 | 511 | 未 |
| TS (`crates/litedoc4-render/web/src`, `**/tests/oracle/*.ts`) | ~12 | 806 | 未 |
| `benchmarks/tools/*` | ~20 | 1353 | 未 (**最後**。計測条件は残す) |
| `.github/workflows/*.yml` | 8 | ? | 未 (**最後**) |

着手前の合計は **22,388 行**。

## ベースライン (着手前、8 段すべて緑)

`fmt` / `clippy` / `doc` / `machete` / `test` (46 バイナリ・**564 passed / 0 failed /
22 ignored**、**doctest 12 本** = 11 passed + 1 ignored) / `corpus --verify-list` /
`provenance` (31 claims) / `assets` (biome 48/48、`app.js` 15370 B)。
記録は `/private/tmp/lean-doc-relay/comment-diet/baseline.txt`。

## 罠 (この作業固有。全部踏んだ or 確認済み)

- **`tools/provenance-files.txt` が指す attribution 文字列を消すと `provenance-gate.sh` が落ちる。**
  残りの担当範囲では **`extractor/Extract.lean` (`Böving` / `Apache`) と
  `crates/litedoc4-render/assets/style.css` (`Böving` / `Apache 2.0` / `math-core` /
  `Charles Edward Gagnon`)** が該当。policy.md に全一覧がある
- **`cargo check` では `clippy::doc_lazy_continuation` を捕まえられない**【実測】
- **doctest はテスト**。```` ``` ```` (言語指定なし) を消すとテストが減る。
  ```text / ```no_run / ```ignore は走らない
- **走っているシェルスクリプトを書き換えると実行が壊れる**【実測】 — bash はバイト位置で
  読み進める。`verify.sh` を回している最中に編集して `line 24: eps: command not found` になった
- **生きている docs と死んだ計画を混同しない** — `docs/approach*.md` (§5 / §6) /
  `verification-log.md` / `provenance.md` は**生きている**。`plan §6` / `実装計画 §4` /
  `M3-d2 の債務` は**削除済み**
- **subagent は 529 で途中終了することがある**【実測】 — 編集は残るが検証は回っていない。
  `git status` で範囲を見て、同じ agent に SendMessage で再開させる

## 次にやると出てくるはずの宿題 (subagent の報告から)

- `tools/ledger-reference.sh` / `ledger-compare.sh` / `impact-reference.sh` が説明している
  **`--impl ts` の半分は `experiments/` と一緒に消えている可能性**がある。
  tools バッチで**スクリプト自体がまだ動くか**を確かめる (半分死んだゲートを指す doc は、
  削除済み計画を指すのと同じ腐り方)
- `.github/workflows/ci.yml` の Rustdoc links ステップが
  「this repository's doc comments are where the reasoning lives」と書いている。
  **新規則と食い違うので最後に直す**
- `extractor/Extract.lean` のヘッダのブロックコメントは **`--help` の usage を兼ねている**。
  usage は残し、「段 D」のような作業単位ラベルと `§6.1` のような節番号を落とす
