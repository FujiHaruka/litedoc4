# Handoff — 2026-08-30 (pure Lean 置き換えの調査、leg 1 進行中)

## Relay control
- Mode: ON
- Goal: Rust 部分を pure Lean に置き換えたときの速度インパクトを実測する。
  (1) レンダリング + 増分を Lean で実装してベンチ比較（数式は両側除外）、
  (2) information-theory で別ブランチ + workflow_dispatch を回して CI 総合時間を実測。
  最後にレポートを出す。**調査であって移行そのものではない**（実装は捨てプロトタイプ）
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: `8ac9673` Lean の下限を実測 / `<次>` CI ベースラインを実測

## ユーザーが決めたこと（leg 1 冒頭に確認済み）
- **測定範囲はレンダリング + 増分**。全機能移植はしない
- **数式は両側とも除外**して測る（Lean 側に math-core 相当が無いため）
- **CI 実測は information-theory の別ブランチ + workflow_dispatch**。main と本番 Pages は触らない

## ここまでに分かったこと（すべて実測）

**1. Lean の「下限」は Rust の完成品の 1.67 倍**
→ `benchmarks/results/purelean-microbench-2026-08-30.txt`
- Rust `litedoc4 render` 全体 **0.40s** (warm, n=6, 422 モジュール, 24.5 MB HTML)
- Lean の下限（レンダリングロジックゼロ）**0.667s**。内訳:
  ir.read 0.050 / ir.parse 0.167 / lidx.read 0.028 / **lidx.parse 0.235** /
  lidx.lookup 0.105 / html.build 0.032 / html.write 0.050
- Rust の内訳（`--only` と `--no-link-index` で分離）: lidx 読み+パース ~0.09s、
  固定コスト ~0.14s、422 ページ ~0.26s
- **Lean の lidx.parse は素直な `String.splitOn` 実装**。ByteArray 走査でどこまで
  下がるかを subagent が測定中（leg 1 で起動済み）

**2. CI で Rust 半分が占めるのは 2.9 秒だけ**
→ `benchmarks/results/purelean-ci-baseline-2026-08-30.txt`
- information-theory `docs.yml` run 33255806841 = 182s。うち lean-action 109s /
  **litedoc4 action 44s**
- 44s の内訳: キャッシュ3種すべてミス 1.2s / **Rust バイナリ取得 2.9s**（release
  アセット DL + SHA-256）/ **extractor ビルド 20.2s**（Extract.lean 3,174 行）/
  抽出 17.5s / render+global 1.4s
- **`cargo build` は走っていない**（3 トリプルには release がある）
- pure Lean は 2.9s を Lean コンパイルに置き換える。extractor の 3,174 行 = 20.2s から
  移植対象 ~10,500 行を外挿すると **約 60s (extrapolated、外挿は弱い。要実測)**

**3. 技術的障害は思ったより低い**
- **Lean 4.31 に `Std.Async.TCP` / `Std.Internal.UV` がある** → `watch` の HTTP サーバ
  (`crates/litedoc4/src/httpd.rs` 577 行) は Lean で書ける
- **このターゲットに数式は実質無い**（422 ページ中 MathML を含むのは 2 枚、
  `math spans kept as LaTeX 0`）。Mathlib 形状のターゲットでは別（2,123 spans）
- Markdown は doc-gen4 と同じ md4c。Lean 側は MD4Lean を require すればよい（未検証）
- **残る本当の壁**: (a) `math-core` 相当（LaTeX→MathML）が Lean に無い、
  (b) サイトの JS は今 `build.rs` が vite を回して OUT_DIR に焼いている。pure Lean だと
  生成物をコミットする設計に反転する

**4. 移植対象の規模**（src のみ、テスト除く）
render 7,004 / incr 3,443 / md 3,865 / ir 2,678 / global 4,133 / CLI 8,127 = **約 29,250 行**

## 作業領域
`/private/tmp/lean-doc-relay/purelean/` に IR（422 モジュール / 15.2 MB）、
link-index.json（10.4 MB）、pages/（Rust の出力 24.5 MB）、rev.txt がある。
**再生成不要。消さないこと**（extractor ビルド + extract で 1 分以上かかる）。
ディスク残 17 GiB — CLAUDE.md の 24 GB 事故があるので測定のたびに掃除する。

Lean プロトタイプは `benchmarks/lean-prototype/`（独立した lake パッケージ、
lean-toolchain v4.31.0、Mathlib 非依存）。`lake build` → `.lake/build/bin/bench <workdir>`。

## 次の一手
1. **subagent の結果を受け取る** — Lean の lidx/IR パース最適化と Task 並列化。
   これで「Lean の実力」の下限が確定する
2. **Lean レンダラのプロトタイプを育てる** — 宣言のレンダリング（署名・docstring・
   アンカー・autolink）まで。ここで「実装込みの Lean」対「Rust」が出る
3. **Lean のコンパイル時間を実測** — プロトタイプが育った時点で行数と秒数を取る。
   CI の答えはここで決まる
4. **増分の比較** — `litedoc4 impact` は 0.07s（IR 全読みではない疑いあり、要確認）。
   `tools/incremental-reference.sh` が 7 シナリオの既存測定手順
5. **information-theory で CI A/B** — 別ブランチ + workflow_dispatch

## 落とし穴（この回で踏んだ / 気づいた）
- **Lean は遅延評価**。`timeIt (pure (f x))` は thunk 確保を測って 1 マイクロ秒と出る。
  最初の版が実際にそうなり、`lidx.parse 0.000001` と `html.build` 半額を報告した。
  **各フェーズは `IO` の中で `Nat` を計算して返し、それを印字する**形にしてある
- `litedoc4 ownership` の引数は `--base`（`--ir` ではない）
- Bash の cwd はツール呼び出しをまたいで残る。`cd` した後は絶対パスを使う
