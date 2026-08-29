# Handoff — 2026-08-29 (v1.0.1 まで。腐り監査つき)

## Relay control
- Mode: DONE
- Goal: v1 の B〜D を完遂し `v1.0.0` を打つ。**達成**
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion
- Progress ledger:
  - r1: A 束 (`v0.2.0` 公開) → B1 → C1/B4 → B2/B3 → D2 → D3 → C3 → C2 → **`v1.0.0`**
    (`aca5067` 〜 `ca8766e`、tag `v0.2.0` / `v1.0.0`)
  - r2: **静かに壊れるものの監査** (`8a0104a`)。9 件、うち 4 件はその日書いたコード。
    新設 `tools/gates.txt` + `workflow-gate.sh` + `docs-gate.sh` + `site-artefacts.txt`
  - r3: **`v1.0.1`** (`e2569e6`) — リポジトリ根の下にあるパッケージのソースリンクが全部 404
    だった。単体テスト 2 本と `e2e-micro.sh` GATE 13 を置いた

## 状態

- Branch **`main`**、push 済み。tag **`v1.0.1`** (assets 3 点、`latest`)
- ローカル: `cargo test --workspace --no-fail-fast` **565 passed / 0 failed / 22 ignored**、
  fmt / clippy / `public-surface-gate.sh` / `workflow-gate.sh` / `docs-gate.sh` すべて 0、
  `litedoc4 1.0.1` (テストは 565 → **567**、`derive_source_url` の 2 本ぶん)
- CI: `ca8766e` で **7 ワークフロー全緑** (CI / action / lake / release(dry) /
  browser-windows / extractor-portability / Lean versions)。
  タグ後に `ci-action` の `uses:@v1.0.0` と `ci-lake` の download 経路も緑
- 実例 2 本とも公開中 (`information-theory` は `v1.0.0` の出力のまま。
  ルート直下のパッケージなので `v1.0.1` の修正は no-op で、再デプロイの必要が無い): <https://fujiharuka.github.io/information-theory/> と
  <https://fujiharuka.github.io/litedoc4/>
- **計画文書は削除した** (このリポジトリの慣行)。恒久的な判断は
  **CLAUDE.md の「v1.0.0 — what is promised」**、数字は `benchmarks/results/`、
  約束の実体は `tools/public-surface.txt` と `tools/lean-toolchains.txt`

## まだ番人が居ないと分かっているもの

- **`clone-gate.sh` の `move` / `delete` は再実走していない。** リテラルを導出に置き換えたが、
  実行には clone + 実編集 + `lake build` が 2 回要る。算術は `build-gate` の実測と一致する
  (422 + 12 = 434、移動後 435) が、通したわけではない

## 次に拾うならここ（v1 の範囲外として残したもの）

- **Linux/arm64 のバイナリ。** `release.yml` は「arm Linux ランナーがここに無い」と
  書いているが、**public リポジトリ向けの arm64 ランナーは現在ある可能性が高い**【未確認】。
  1 ジョブの `workflow_dispatch` (`runs-on: ubuntu-24.04-arm`) で決まる。
  2026-08-18 の「機材が無いのではなく持っている機材を使っていなかった」の再演を疑う対象。
  **コメントが腐っているなら、まずコメントを直す**
- **`release.yml` は今も `--generate-notes`。** リリースのたびにノートを手で
  最終状態に差し替えている (v0.2.0 / v1.0.0 の 2 回)。workflow 側で直すのが筋
- **Intel macOS。** `macos-13` は 2026-08-18 に「15 分待っても起動しない」と実測。
  再確認するなら同じ形で
- **小 RAM Linux での実走**はやらない【決定 2026-08-22】。外挿で答えが出ている

## 最初に読むファイル

1. `CLAUDE.md` の「v1.0.0 — what is promised, and what that costs to keep」
2. `tools/public-surface.txt` / `tools/lean-toolchains.txt` — 約束の実体
3. `benchmarks/results/build-gate-real-2026-08-29.txt` — 実物ゲートで出た欠陥 3 件と分母の話
4. `benchmarks/results/v0.2.0-numbers-2026-08-29.txt` — 整数は不動、壁時計は page cache で 3 倍
