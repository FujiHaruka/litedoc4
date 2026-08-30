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

**A. 速度 — Lean レンダラは書けて、逐次 2.6 倍 / 4 スレッド 1.26 倍**
→ `benchmarks/results/purelean-renderer-2026-08-30.txt`
- `benchmarks/lean-prototype/Render.lean` 1,612 行。Lean core のみ、依存ゼロ
- **同じ仕事の確認済み**: ページ 422/422、`<a href=` 29,563 対 29,560、宣言アンカー
  4,394/4,584 が両側一致、出力 24,191,054 B = Rust の 98.6%
- Rust 0.40s / Lean 逐次 1.05s / Lean 4 ワーカー 0.50s（4 ワーカー出力は逐次とバイト一致）
- CPU は 2.7〜3.3 倍。**Rust 側は並列化していない**（素の `for`、rayon なし）
- 遅さは 1 箇所ではない。レンダリング 0.63s = フレーム/エスケープ/組み立て 47% /
  コード片走査 21% / docstring 20% / 定数リンク解決 12%。**約 10 サイクル/バイトが
  全体に薄く広がっている**
- 前の測定の 2 つの誤りを訂正した: link index は主犯ではない（12%）、
  `lidx.lookup 0.1442` はレンダラの下限ではない（実際の traffic は 8 分の 1）

**B. Lean の下限（ロジックゼロ）**
→ `purelean-microbench-2026-08-30.txt` と `-optimised-` の 2 本
- 素直な実装 0.667s → 書き直して **0.506s 逐次 / 0.388s 4 ワーカー**
- lidx.parse 0.233→0.088（バイト走査 + 容量指定）、ir.parse 0.167→0.107（手書きパーサ）
- **効かなかったもの**（数字つきで記録済み。再挑戦しないこと）: ByteArray 化、Nat ビット詰め、
  skipWs 除去、フィールドの間引き

**C. CI — ±4%。判断材料にならない**
→ `purelean-ci-runs-2026-08-30.txt` と `purelean-ci-probe-2026-08-30.txt`
- information-theory `docs.yml`: キャッシュヒット **4.0s** / ミス **44.0s**（extractor
  ビルド 20.2 + release DL 2.9 + 抽出 17.5）。ジョブ全体は 146〜182s
- CI 上の Lean ビルド: **Render.lean 1,612 行で 9.25s**（n=3、ubuntu-latest）、
  extractor 3,174 行で 11.65〜16.82s（**ばらつき 44%**）
- **正味 +6.4s**（release がある環境）/ **−14〜18s**（Windows・Intel Mac = cargo build 経路）
- **バイナリサイズの発見**: `render` は **5.3 MB**（`Std.Data.HashMap` のみ）、
  `bench` は 118 MB（`Lean.Data.Json`）、extractor は 226 MB（`import Lean`）。
  **レンダラは Lean フロントエンドを要らないので Rust の 3.4 MB と同オーダーで配布できる**

**D. 技術的な壁**
- Lean 4.31 に `Std.Async.TCP` / `Std.Internal.UV` → `watch` の HTTP サーバは書ける
- Markdown は MD4Lean（doc-gen4 が require している実物）で md4c に届く — **測定中**
- 数式はこのターゲットに実質無い（422 ページ中 2 枚）。Mathlib 形状では別
- pure Lean 化で消える: `release.yml` 332 行 / `resolveLitedoc4` 約 250 行 /
  `action.yml` のバイナリ取得 / `lake-download-gate.sh` / 15 ワークフロー中 11 の cargo 一式

## 測定で踏んだ罠（全部「緑だが測っていない」形）
1. **Lean の遅延評価、3 形**: `timeIt (pure (f x))` は thunk 確保を測る /
   値が後で forced されると別フェーズに計上される / `do let x := pureFn y; return (x,n)` は
   **どのフェーズにも計上されない**（`do` クロージャの外で走る）。
   **対策はフェーズ合計をプロセス wall と突き合わせること**
2. **`uses: ./litedoc4`（ローカル action）は本番と別物**: `actions/cache` が
   `Invalid pattern` の警告だけ出して一切保存せず、`github.action_ref` が空なので
   release ではなく `cargo build` が走る。どちらも exit code に出ない
3. **`lake build` は `defaultTargets` しか作らない**: Render.lean を一度もコンパイルせずに
   「レンダラのビルド時間 4.79s」を報告した。**ステップに成果物の一覧を出させる**のが対策

## 作業領域
`/private/tmp/lean-doc-relay/purelean/` — IR（422 モジュール / 15.2 MB）、link-index.json、
`pages/`（Rust の出力）、`lp/`（Lean の出力）、rev.txt。**再生成不要、消さないこと**。
worktree が 2 つある: `it-wt`（information-theory の `purelean-ci-bench` ブランチ）、
`ld-wt`（litedoc4 の `purelean-ci-probe` ブランチ）。**どちらも main にマージしない**。
ディスク残 16 GiB。

## 次の一手
1. **Markdown の結果を受け取る**（subagent 進行中）— MD4Lean を入れた Lean レンダラの
   時間と、MD4Lean を足したときの `lake build` の変化。**現在の 2.6 倍は Markdown 抜きの下限**
2. **増分の実測** — `tools/incremental-reference.sh` の 7 シナリオ
   (`nochange` / `self-one` / `importers-hub` / `referrers-two` / `renderall` /
   `removed-one` / `added-one`)。`--only nochange` で 1 つだけ回せる。
   Rust のベースラインを取り、Lean 側は IR 全読みの回数（無変更 1.00 / 1 モジュール変更 4.00 /
   フル 2.00、→ `docs/approach-pillars.md` §5.6）と 1 回あたりのコスト
   （Rust 0.105s / Lean 0.156s 逐次・0.050s 4 スレッド）から合成する
3. **最終レポート** — `benchmarks/purelean-report.md`（英語）。
   ユーザーの問いは「速度インパクト」と「CI 総合時間の変化」の 2 つ
