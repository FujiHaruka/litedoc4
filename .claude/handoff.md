# Handoff — 2026-08-24 (テストの穴を埋める)

## Relay control
- Mode: DONE
- Goal: テストの穴を埋める計画を全 30 項目決着まで完遂する。**達成**。
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion
- **結果**: **全 30 項目決着**。**新しく書いたテストは 57 本**、本体カバレッジは
  **86.9% → 92.4%**、**製品の欠陥を 1 件出して直した** (`litedoc4 ledger --help` だけが
  使い方を出さず exit 2 で拒否していた)。**`ci.yml` に watch gate を載せた** —
  ブランチで実走して緑を確認してから main へ入れ、**main でも 3 ジョブ緑**
  ([run 32656489911](https://github.com/FujiHaruka/litedoc4/actions/runs/32656489911))。
- Progress ledger:
  - r1: 段 0〜7 のすべて。commit `c7df7a5`〜`5c34fbf`

## State

- Branch: **`main`** / clean / push 済み
- **計画は全 30 項目決着。この計画でやることは残っていない**
- 数字の SoT は
  [`benchmarks/results/coverage-2026-08-24.txt`](../benchmarks/results/coverage-2026-08-24.txt)、
  (計画文書と実装ログは 2026-08-24 に削除した — 経緯は git 履歴)
- **検証は全部緑**【実測 2026-08-24】 — `cargo test --workspace --no-fail-fast` が
  **46 バイナリ / 564 passed / 0 failed / 22 ignored**、fmt / clippy / doc / machete /
  `corpus-gate.sh --verify-list` も 0。検証スクリプトは
  `/private/tmp/lean-doc-relay/testcov/verify.sh` (各段のログと終了コードを別々に残す。
  **パイプを使わない**)
- **`#[ignore]` は 22 のまま**なので `tools/corpus-tests.txt` は触っていない
- ディスク: 空き **17 GiB**。`cargo llvm-cov clean --workspace` 済み (869 → 112 MB)

## やらないと決めたもの (再検討するなら同じ測り方をやり直すこと)

- **`litedoc4-md/src/parse.rs` の未カバー 52 行** — 50 行が `Error::Malformed` 系の
  防御分岐で、入力から到達できない
- **段 6 の P2〜P5** — 残り 724 行は `?` の伝播 / getter / `--serve` の常駐経路
  (機材が要る = ゲートの領分) / 診断用フラグ (ゲートが既に読んでいる)
- **`extractor/Extract.lean` の単体テスト** — e2e のゲート 7/8/9 が実 IR を名前レベルで
  検査している。**「テストが 1 本も無い」は「検査が無い」ではない**
- **カバレッジのしきい値を CI のゲートにすること** — 壁時計をゲートにしないのと同じ理由
- **`cargo-mutants` を網羅的に回すこと** — 代わりに**テスト 1 本ごとに 3〜4 通りの変異を
  手で当てた** (計 26 通り)。**それで「何をしても通るテスト」を 1 件捕まえた**

## この leg で踏んだもの (繰り返さない)

1. **`cargo fmt --all` を回さずに commit して、HEAD の `cargo fmt --check` を赤くした**
   (`ci.yml:121`)。→ **commit の前に必ず `fmt --check` を回す**
2. **カバレッジの行の数え方を自作して間違えた。** `--json` の segments は 1 行に複数
   リージョンが乗る (`?` のエラー経路)。最小を取れば 81.6%、最大なら 87.3%、
   llvm-cov 自身の per-file 値はその間。→ **`--lcov` を使う** (1 行に 1 つの count)。
   確定値は **本体 86.9%** (`#[cfg(test)]` より手前だけ)
3. **`rg -oh` は `--help` を出す** — ripgrep の `-h` は `--no-filename` ではない (`-I` がそれ)
4. **subagent の「CI で走らないゲート」報告が誤りだった。** `e2e-micro.sh` が
   `site`/`usedby`/`config`/`onemod` の 4 本を内部で呼ぶ。**呼び出しは 2 段ある**

## 計測コマンド (再計測はこれ)

```sh
mise exec -- cargo llvm-cov --workspace --no-fail-fast --lcov --output-path cov.lcov
# 本体だけ数える: 各 src ファイルの最初の `#[cfg(test)]` より手前の DA: 行を数える
# 集計スクリプトはスクラッチにある (セッションが変わったら書き直す。20 行程度)
```

**`target/llvm-cov-target` は 880 MB、空きは 16 GiB。段 7 F1 で `cargo llvm-cov clean` する
— 掃除の主体はそこ。** このリポジトリは満杯のディスクで対象リポジトリを一度壊している。

## 作業領域

`/private/tmp/lean-doc-relay/testcov/` — e2e の出力 (6.6 MB)、検証ログ、
falsify 用のバックアップ。**段 7 が終わったら消す。**
