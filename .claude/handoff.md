# Handoff — 2026-08-30 (relay leg 2, terminal)

## State

**ゴール達成。MathML4Lean は書き上がり、litedoc4 から依存ライブラリとして使える。**
plan.md の完遂基準 M5 を満たし、M6 も「我々に閉じられる範囲」は全部済んでいる。

- MathML4Lean: main `48c53c6`、**tag `v0.1.0`**（commit `35a35fe`)、GitHub Release あり。
  CI は 4 toolchain green
  https://github.com/FujiHaruka/MathML4Lean/releases/tag/v0.1.0
- litedoc4: main `da08896`。触ったのは `benchmarks/lean-prototype/` だけ
- 両リポジトリとも clean、push 済み

## What was done in this leg

**M5（完遂基準）** — litedoc4 の `benchmarks/lean-prototype` が MathML4Lean を git 依存で
`require` し、対象の 3 span を変換して Rust 側とバイト一致:

```
mathml gate result: 3 / 3 match the Rust half byte for byte
```

- `benchmarks/lean-prototype/Mathml.lean` — consumer-spans の JSONL を読み、変換して突き合わせ、
  件数を突き合わせる。**逸脱ルール表は持たない**（この入力では両者一致するので、
  何も覆わないルールは無い方がよい。差が出たらそれは欠陥）
- `benchmarks/lean-prototype/mathml-gate.sh` — 両側を走らせて食い違えば落ちる。**手動ゲート**
- `benchmarks/lean-prototype/target-spans.jsonl` — Rust 側の答え（3 行）。ゲートが毎回書き直す
- MathML4Lean 側 `tools/corpus` を lib + 2 bin に分割し、`consumer-spans` を追加。
  **span finder と math-core 設定は 1 つのまま**（分ければ「span の定義」が消費者とずれる場所が 2 つできる）
- リファクタで答えは 1 バイトも動いていない（コーパスを scratch に再生成して `/usr/bin/diff` 一致）

**M6** — tag `v0.1.0` / GitHub Release / README を他人向けに更新（`rev = "v0.1.0"`)。
README の `#eval` の出力も「Use it」の手順も**実際に走らせて確認**（空ディレクトリから
v4.33.0 の消費者パッケージを作り、network 越しに require してビルド・実行が通る）。

## Reservoir — ここだけ他人に依存する（残り 1 件）

条件は 4 つで、**star 数だけ未達**（実測 2026-08-30、GitHub API）:

| 条件 | 状態 |
|---|---|
| public / non-fork / non-template | ○ |
| top-level `lake-manifest.json` | ○ |
| GitHub が認識する OSI ライセンス | ○ Apache-2.0 |
| **star 2 個以上** | **× 0 個** |

自動インデックス（申請不要、約 1 日ごと）。**star を作りに行くのは閉じ方ではない**。
plan.md のマイルストーン表の下と `docs/release-2026-08-30.txt` §3 に記録済み。

## Files to read first（続きをやるなら）

- `../MathML4Lean/docs/plan.md` — SoT。M6 の下に Reservoir の注記
- `../MathML4Lean/docs/consumption-2026-08-30.txt` — M5 の報告（何を証明し、何を証明していないか）
- `../MathML4Lean/docs/release-2026-08-30.txt` — M6 の報告

## 残っている「未検証」（"probably fine" と読まないこと）

- **v4.33.1 の消費者**は誰も走らせていない。CI はライブラリ本体を v4.33.1 で見ているが、
  「v4.33.1 の消費者が require する」経路は未実施（このマシンに v4.33.1 が無い）
- コーパスの 6 refusals は仕様側に語彙が無いもの。**拒否は正当な答え**（plan.md §0）
- `mathml-gate.sh` は `tools/gates.txt` に無い。litedoc4 の製品が MathML4Lean に依存していない
  ので意図的。製品 extractor が MathML を焼く日に `tools/` へ移して行を足す

## Relay control
- Mode: DONE
- Goal: MathML4Lean を書き上げ、litedoc4 から依存ライブラリとして使えるようにする (plan.md の M5)
- Leg: 2 / cap 12
- Predecessor: none
- Stop-on: completion
- Progress ledger:
  - r1: M0 コーパス凍結 2,123 span (49f41cf) / M1 骨組み+ゲート+CI 4 toolchain (e957aca) /
    センサス 136 コマンド (5b7edd1) / M2 字句・構文・直列化 1237 (a84602a) /
    判定設計をバイト一致から仕様基準へ (304046d) / M3 記号表+逸脱ルール 2104 (ba3f839) /
    M4 tex.web から導出、2107 説明済み・単体テスト 45 (a274a8d)
  - r2: **M5 達成** — corpus tool を lib 化 + consumer-spans (MathML4Lean f262589) /
    lean-prototype が require して 3/3 バイト一致 (litedoc4 65642b0) / M5 記録 (ebbe724) /
    **M6** README + Reservoir の残条件を記録 (35a35fe) / **tag v0.1.0 + Release** /
    prototype の pin をリリース commit へ (litedoc4 3a7e963, da08896) / M6 記録 (48c53c6)
