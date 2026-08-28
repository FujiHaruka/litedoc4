# Handoff — 2026-08-28 (見張っていなかったゲート 4 件)

## Relay control
- Mode: DONE
- Goal: 2026-08-24 の handoff が「見つけたが直していないもの」として残した 7 件を潰す。**達成**。
- Leg: 1 / cap 8
- Predecessor: `2026-08-24 (コメント削減)`
- Stop-on: completion
- Progress ledger:
  - r1: 全 7 件。commit `12687b9`〜`fd87775` (5 本)

## State

- Branch: **`main`** / push 済み (`fd87775`)
- **この計画でやることは残っていない**
- ローカル `cargo test --workspace --no-fail-fast`: **564 passed / 0 failed / 22 ignored**
  (doctest 12 本)、EXIT=0。**着手前と同じ数**なので挙動は動いていない。
  **exit code はパイプを外してファイルに落として取った** — `| tail` の先で読むと
  `tail` の 0 を見ることになる (CLAUDE.md の罠。この回、実際に一度読み違えた)
- 検証 (runner 上で実際に走ったもの):
  - `ci.yml` 4 ジョブ緑 — ブランチで run 33180485902、main で run 33180856819
    (`cargo test --workspace` / `assets-gate.sh` / 新設の `benchmarks-ts` / e2e)
  - `ci-action.yml` 緑 (run 33180856811) / `ci-lake.yml` 緑 (run 33180856903)
  - probe 2 ジョブ緑 (run 33180479986) — `uses:` のローカルパス 2 形を両方実測
- **composite を使う 7 ワークフローのうち 4 本は runner で未実走** —
  `ci-browser-windows` / `ci-extractor-portability` / `ci-placement` / `release`。
  いずれも workflow_dispatch か release 契機。ただし `ci-placement` が要る
  `./litedoc4/...` の形は probe が直接測った

## 何をしたか — 前回の 7 件の決着

| | 項目 | 決着 |
|---|---|---|
| 1 | `build-gate.sh` の `EXPECT_BASE=443` が死んでいた | **直した**。分母を「比較する片辺」から**記録済みモジュール一覧**に移した |
| 2 | `search-gate.sh` が存在しない | **穴ではなかった**。`index-format.ts` / `score.ts` は vitest 23 件が見ていて、それを `assets-gate.sh` が回し、`ci.yml` が回している |
| 3 | `assets.rs` の `from_scripts >= 8` の余裕が 1 | **直した**。オカレンス数の閾値をやめ、**相異なる 8 名の台帳**と突き合わせる |
| 4 | node の説明が 6 ワークフロー 11 箇所にコピペ | **直した**。`.github/actions/setup-node` 1 本にし、版は `mise.toml` から**読む** |
| 5 | `--jobs` 拒否メッセージの重複 | **前セッションで解決済み**だった (`pipeline.rs:916` の 1 箇所のみ) |
| 6 | `benchmarks/tools/*.ts` が型検査されていない | **直した**。`deno.json` + `tools/benchmarks-ts-gate.sh`、`ci.yml` が回す |
| 7 | `extractor/README.md` が実験期の枠組み | **直した**。腐った事実 2 件を含めて書き直した |

**数字と、それがどう動いたかは `benchmarks/results/gate-honesty-2026-08-28.txt`。**
4 件とも「落ちていなかった」ではなく「**落ちる形になっていなかった**」ので、
すべて**一度落としてから**通した。

## この回で分かった一般形

- **印字された分母の出所を疑う。** 4 件のうち 3 件で、分母が**測っている対象そのもの**から
  来ていた (`files_in "$REF_IR"` / `from_scripts >= 8` / 13 個のコピーを突き合わせる node 版)。
  出所が対象の中にあると、**両辺が同じだけ壊れた**ときに必ず通る
- **閾値ではなく台帳にする。** `>= 8` は実体 9 オカレンス / 8 名で、偶然一致していただけ。
  台帳なら「消えた名前」「増えた名前」が名指しで出る
- **コピーを突き合わせるゲートは、次のコピーを足す人がゲートを知っている間しかもたない。**
  出所を 1 つにして「**コピーが増えたら落ちる**」に反転させるほうが強い
- **`deno run` は型を剥がすだけで検査しない。** 走っている ≠ 検査されている

## 腐っていたので直した事実 (`extractor/README.md`)

- `Extract.lean` は **3,687 行ではなく 3,174 行**
- 「`--serve` は製品側から配線するのが M4-c」→ **配線済み** (`resident.rs:445` が spawn する)
- 解決しない計画 ID (`M5-a` `M5-b` `M4-a`〜`M4-c` `M3-d2` `M7-a` `段 C` `段 D` `計画 §4`) を全廃
- 撤去済プロトタイプとの移行差分の節をまるごと落とし、**今効いている約束**の一覧に置き換えた

## 残っている確認 (次に拾うならここ)

- **`build-gate.sh` は実物で回していない** — 対象リポジトリと `REF_IR` /
  `REF_MODULES` (`/private/tmp/lean-doc-relay/m3d4/shared/`) が要り、**どちらも今は無い**。
  合成フィクスチャで `compare` を関数ごと抽出して 5 ケース通した (旧実装との差も実測) が、
  **実走はしていない**。回すなら `REF_MODULES` の復元が先
- **CLAUDE.md の「8 ワークフローが `setup-node` を持つ」は 7 が正しい** (probe を消した後)。
  ルール文書なので触っていない

## 意図的にやらなかったこと

- `benchmarks/results/**` と `crates/*/tests/data/**` は凍結。触っていない
- `extractor/README.md` は日本語のまま (CLAUDE.md の言語規則: 翻訳はしない)。
  新しい計測記録 `gate-honesty-2026-08-28.txt` は英語で書いた
  (`benchmarks/results/` は「日本語のまま」の一覧に入っていない)

## 最初に読むファイル

1. `benchmarks/results/gate-honesty-2026-08-28.txt` — この回の数字と、何をどう落としたか
2. `tools/build-gate.sh` の `compare` / `phase_gate1` / `phase_gate4`
3. `.github/actions/setup-node/action.yml` と `tools/assets-gate.sh` の node の段
4. `tools/benchmarks-ts-gate.sh`
