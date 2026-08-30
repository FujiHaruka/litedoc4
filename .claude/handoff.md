# Handoff — 2026-08-30

## State

- **作業対象は別リポジトリ `../MathML4Lean`**。このリポジトリ (lean-doc/litedoc4) は
  **消費者であり、今回は基本的に触らない**。`git status` が clean なのは正常
- lean-doc: branch main, clean, `e251365` まで push 済み、CI 緑
- MathML4Lean: branch main, clean, `133f24a` まで push 済み
  (https://github.com/FujiHaruka/MathML4Lean, public)
- **Claude セッションは常に `/Users/haruka/dev/lean-doc` で作る**(ユーザー指示)。
  handoff / relay / carryon スキルがここにしか無いため。作業先へは `../MathML4Lean` で届く

## Where we are

litedoc4 の pure-Lean 化調査で**唯一「Lean にライブラリが存在しない」と判明したのが
LaTeX→MathML** (他は MD4Lean / UnicodeBasic / 素の Lean で埋まっている)。
そこをスクラッチで書く新規ライブラリ `MathML4Lean` を起こしたところ。

**計画は `../MathML4Lean/docs/plan.md` が SoT。** スコープ・テスト方法・M0〜M6・
完遂基準・反証条件が全部そこにある。**まずこれを読む。**

決まっていること (要点だけ。詳細は plan.md):
- **コーパスがスコープ定義でありオラクル** — Mathlib 8,169 ファイル → docstring 91,815 →
  数式を含む 651 → **span 2,123** (inline 1,946 / block 177、LaTeX 39,970 B)。
  math-core 0.7.0 は 2,113 を変換し 10 を落とす (measured 2026-08-22 →
  lean-doc `benchmarks/results/mathml-2026-08-22.txt`)
- **math-core はブラックボックスのオラクル。ソースを読まない**。表は W3C MathML Core
  operator dictionary と unicode-math から起こす (スクラッチ実装であること + provenance)
- 判定は **math-core が成功する 2,113 件でバイト一致**。落ちる 10 件は報告するだけ。
  **例外リストは作らない**。比較した行数と file の行数を突き合わせて 0 件緑を防ぐ

## Next step

**M0: コーパスとオラクルを凍結する。**

1. `../MathML4Lean/tools/` に span 抽出器を書く — Mathlib のソースは
   `/Users/haruka/dev/lean-projects/.lake/packages/mathlib/Mathlib` (8,169 ファイル、
   母数一致を確認済み)。docstring から `$…$` / `$$…$$` を取る。
   **2,123 という数を再現できるかが最初のチェック** — 合わなければ抽出条件が違う
2. math-core オラクルを作る — 小さな Rust バイナリ (`math-core = "0.7.0"`,
   `default-features = false`)。litedoc4 の `crates/litedoc4-md/src/math.rs` が
   **呼び方の参考**になる (`LatexToMathML::new` + `convert_with_local_state`、
   `ignore_unknown_commands: false`)。**中身の実装は読まない**
3. `corpus/mathlib-spans.jsonl` を生成してコミット。header に Mathlib の rev /
   math-core のバージョン / 日付を書く。`NOTICE` は既に両方の義務を書いてある
4. `tools/build-corpus.sh` として再生成手順を残す (これは gate であって test ではない)

その次は M1 (CI 4 toolchain + **わざと赤いゲート**)。

## Files to read first

- `../MathML4Lean/docs/plan.md` — **最初にこれ**。スコープ / テスト方法 / M0-M6 / 反証条件
- `../MathML4Lean/CLAUDE.md` — この新リポジトリの規律 (コーパスがスコープ、
  math-core を読まない、test と gate の境界、セッションは lean-doc で作る)
- `benchmarks/results/mathml-2026-08-22.txt` — 2,123 の内訳、math-core が落とす 10 件の
  正体、出力 MathML の要素構成 (munder 175 / mover 44 / accent 42 / mtext 16 / mtable 4)
- `crates/litedoc4-md/src/math.rs` — 消費者側の API 形状と、期待される出力の実例

## Load-bearing context

- **完遂基準は M5** — litedoc4 の `benchmarks/lean-prototype` がこのライブラリを
  `require` して、対象の 3 span を Rust 側とバイト一致で変換できること。
  **製品の extractor に配線するのは明示的にスコープ外** (IR schema を変える別判断)
- **反証条件を持っている**: math-core の恣意的な内部選択 (属性順 / 仕様に無い spacing /
  クラス名) を写さないと閉じない乖離が **3 クラス出たら**、バイト一致は間違ったゲート。
  構造的同値に差し替える — **それはユーザーに戻す判断**
- toolchain は v4.31.0〜v4.33.1 の 4 本 (`lean-toolchains.txt`)。**lean-toolchain は
  最低版に固定** — 依存側が上だと `lake update` が消費者の lean-toolchain を書き換え、
  下なら黙って無視される (measured)。新しい版にしか無い API は使えない
- ローカルに入っている toolchain は v4.31.0 / v4.32.2 / v4.33.0 の 3 本。**v4.33.1 は未導入**
- push は HTTPS + gh (ssh は通らない)。MathML4Lean の remote は HTTPS に直してある
- `lake new` が作った `.github/workflows/lean_action_ci.yml` が残っている。M1 で
  `lean-toolchains.txt` を読む matrix に置き換える

## Relay control
- Mode: ON
- Goal: MathML4Lean を書き上げ、litedoc4 から依存ライブラリとして使えるようにする (plan.md の M5)
- Leg: 1 / cap 12
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: (in progress) 計画・リポジトリ・NOTICE 作成 → MathML4Lean 133f24a
