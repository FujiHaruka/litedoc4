# Handoff — 2026-08-29 (v1 へ: 約束とその番人)

## Relay control
- Mode: ON
- Goal: `docs/plans/v1.md` の B〜D を完遂し、**`v1.0.0` を打つ**。
  v1 の定義は「**作者以外が、作者の助けなしに、使い続けられる**」。
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - (leg 1 開始時点) A 束は完了済み — `v0.2.0` 公開 (`aca5067`)、B1 完了 (`62a7505`)

## ユーザー判断は 4 件とも取得済み【2026-08-29】

**これ以上聞き直さない。** 迷ったらこの 4 つに戻る:

1. **実例サイト (D3) は両方やる** — 対象リポジトリ `information-theory` の `docs.yml` の
   pin を `v0.2.0` に上げて再生成し、**加えて** litedoc4 自身の Pages に `e2e/micro` を
   HEAD から出す
2. **1.x で固定するのは「外から見えるもの」だけ** — サイトの URL / アンカー形、
   `action.yml` の入出力 (10+4)、`litedoc4.toml` のキー、`build` と `watch` の CLI。
   **IR schema / ledger / `.lidx` は内部扱い** (pin で抽出器とバイナリの版が揃うので
   利用者は直接読まない)
3. **Lean は実測 3 版 + `v4.33.1`** をマトリクスゲートに載せる。**README にはゲートが
   守っている版だけを書く**。最新 stable の自動追随はしない
4. **完了後に `v1.0.0` を打つ**

## この機械の今の状態【実測 2026-08-29】

- **空きディスク 11 GiB。** 2026-08-17 の枯渇事故 (24 GB の作業領域で対象の olean が欠けた)
  の再演が現実的な水準。**計測のたびに `df -h` を見て、終わったら即 `rm -rf` する**
- `/private/tmp/lean-doc-relay` は無し。`litedoc4 watch` の残骸も無し
- 対象リポジトリ `/Users/haruka/dev/lean-projects` の `.lake` は 12 GB (健在)

## 残っている項目 — SoT は `docs/plans/v1.md`

| | 項目 | 状態 |
|---|---|---|
| C1 | Lean 複数版のマトリクスゲート | **未着手。最大の穴** |
| C2 | `build-gate.sh` を実物で回す | 未着手。`REF_MODULES` / `REF_IR` の復元が先。**ディスク注意** |
| C3 | README の性能表を `v0.2.0` で測り直す | 未着手。warm n≥5、cold と混ぜない。**ディスク注意** |
| C4 | CLAUDE.md の「8 ワークフローが setup-node」→ 7 | 未着手 (1 行) |
| B2/B3 | 約束を README に書き、守るゲートを付ける | 未着手 |
| B4 | Lean 版の方針 (C1 が番人) | C1 と同時 |
| D2 | issue テンプレート | 未着手 |
| D3 | 実例サイト 2 本 | 未着手 |
| — | `v1.0.0` | 最後 |

## 最初に読むファイル

1. `docs/plans/v1.md` — 項目の SoT。A / B1 / D1 は決着済み
2. `tools/e2e-micro.sh` と `.github/workflows/ci-extractor-portability.yml` の X5
   (toolchain を差し替えて回す既存の形。C1 はこれの一般化)
3. `crates/litedoc4/src/lib.rs` の `SUMMARY` / `USAGE` と `usage_tests`
