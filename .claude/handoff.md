# Handoff — 2026-08-31 (relay leg 1 → leg 2)

## State

**M1 完了、M2 は未完了**（完了判定の e2e/micro バイト一致が 10/11 で止まっている）。
計画は `.claude/purelean-plan.md`（このリレーの SoT）。

- litedoc4: main `542303e`、clean、push 済み
- MathML4Lean: main `6265363`、**tag `v0.1.1`** + GitHub Release、litedoc4 が pin 済み

## What was done in leg 1

**M1 骨格** — `src/Litedoc4/` 新設、root lakefile の target 再編（package の `srcDir` を
`.` に戻し各 target に持たせた）、vendor md4c + libc shim を製品ツリーへ、
`tools/purelean-gate.sh` 新設（5 項目、全部一度落として確認）。
バイナリ 2.16 MB → M2 後 3.66 MB。**`import Lean` はゲート項目 5 が禁じている**。

**M2 レンダラ** — プロトタイプの `Render.lean` を製品ツリーへ移し、17 モジュールに分割。
移設と分割を別々に計測。`litedoc4 render --ir --pages --source-url
(--link-index|--no-link-index)`。未実装フラグは**名指しで拒否**（黙って無視しない）。
対象リポジトリで **422/422 バイト一致**、`tools/purelean-render-gate.sh`（manual）。

**帰属表示** — `parse.rs` の MIT 表示が Lean 転写に運ばれていなかった。一般形に上げて
プロトタイプの `Md.lean` / `Render.lean` にも。分割後は passage 単位に落とし直し済み。
照合語は固有名詞（`Jz Pan` / `Böving`）。claims 35 → 53。

**MathML4Lean v0.1.1** — `\$` `\%` `\&` `\_` が拒否されていた（`\#` `\{` `\}` は通っていた）。
`\text{…}` の中は**書いていないバックスラッシュが出力に出ていた**（拒否より悪い）。
bare `&` は変換をやめて拒否に変えた（TeX の catcode 4、math-core も拒否、Rust 側とも一致する）。
Mathlib コーパスは不動（2000/107/6）、unit 45 → 64、3 toolchain 緑。

## 見つかった欠陥で、記録しておく価値のあるもの

1. **study の「422/422」は 6 時間古い参照と比べたものだった。**
   凍結 `pages/` は `25af76d`（`<div class="flags">` 追加）より前のビルド。
   **プロトタイプも同じ機能を欠いていたので両側が同じ穴を持ち緑だった。**
   → `benchmarks/results/purelean-render-move-2026-08-31.txt`。バイト総数は
   24,546,157 → **24,546,639**。並べてはいけない
2. **`lake build -v` はコンパイラを証明しない** — Lake は最新 target のログを再生する。
   `.o` を消して `Replayed` 行も拒む必要がある
3. **docs-gate に穴があった** — 正規表現が絶対形 `benchmarks/results/...` にしか当たらず、
   `benchmarks/` 内の文書が書く相対形 `results/...` を見ていなかった。
   `purelean-report.md` の 12 引用が全部ノーチェック。直して count 184 → **199**
4. **コーパスの沈黙はカバレッジではない** — Mathlib 2,113 span に `\&` `\$` `\%` `\_` は
   1 つも無い。見つけたのは e2e/micro という小さな手作りフィクスチャ

## Files to read first

1. `.claude/purelean-plan.md` — マイルストーンと完了判定、各 leg の作法
2. `benchmarks/results/purelean-render-move-2026-08-31.txt` — 「まだ一致していない」節が
   そのまま leg 2 の作業リスト
3. `src/Litedoc4/Main.lean` — CLI の現状（`render` のみ）
4. `tools/purelean-render-gate.sh` — manual ゲートの作り（両バイナリを 1 セッションで走らせる。
   保存済みツリーは自分の `--source-url` を焼き込んでいるので参照にできない）

## Next step — M2 を完了させる

**完了判定は e2e/micro でのバイト一致。** 4 件:

1. **e2e/micro の IR で Lean と Rust を突き合わせ、CI ゲートにする**（elan と micro だけで
   足りるので `ci`。対象リポジトリが要る render ゲートと違う）。
   MathML4Lean v0.1.1 で数式の差は消えたはずだが**未計測** — まず測る
2. **`UnplaceableName` のエラー経路が転写されていない** — `--no-link-index` で Rust は
   `declNameToLink: no defining module for Inhabited.default` と言って exit 1、
   Lean は 11 ページ黙って書く。対象では発火しないので 422 ページのゲートは跨いで緑
3. **モジュール順が `<ir>/modules/*.json` のソート**で、Rust の読む `index.json` の
   `modules` 配列ではない。両コーパスでバイト一致するがプロトタイプの近道
4. `render` の要約が Rust の 3 行目 `math spans kept as LaTeX N` を出していない

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 2 / cap 40
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: 計画 + 4 判断 (1c3d7ce) / M1 骨格 (8294e56) / 帰属表示 (129ea01) /
    M2 レンダラ移設・分割 422/422 (bd505f4) / docs-gate の穴 184→199 (3ee806d) /
    MathML4Lean v0.1.1 + pin (542303e)
