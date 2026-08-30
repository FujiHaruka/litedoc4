# Handoff — 2026-08-30 (Rust 半分を pure Lean に置き換える調査。**完了**)

## Relay control
- Mode: DONE
- Goal: pure Lean 置き換えの速度インパクトと CI 総合時間の変化を実測する。**達成**
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion
- Progress ledger:
  - r1: 5 本の実測（下限 / 下限最適化 / レンダラ / Markdown / 増分）+ CI 3 run + probe 4 run。
    レポート `benchmarks/purelean-report.md`。`8ac9673`〜`210e0d1`

## 答え（全部 measured。詳細は `benchmarks/purelean-report.md`）

| | Rust 現行 | pure Lean | |
|---|---:|---:|---|
| render 422 モジュール 逐次 | 0.39s | 1.07s | **2.74x** |
| 同 4 スレッド | 並列化していない | 0.52s | 1.33x |
| 出力 | — | **420/422 ページがバイト一致** | 差は数式 3 span = 1,464 B |
| 増分コア（impact+ownership+merge）逐次 | 0.31s | 0.60s | 1.9x |
| 同 4 スレッド | 並列化していない | **0.20s** | **0.65x — Lean が速い** |
| CI キャッシュ冷、release あり | 2.9s | 9.25s | +6.4s |
| CI キャッシュ冷、release なし（Windows / Intel Mac） | 23.6〜27.6s | 9.25s | **−14〜18s** |
| CI キャッシュ温 | 0s | 0s | 0 |
| 配布バイナリ | 3.4 MB | **5.3 MB** | Lean フロントエンドを import しなければ小さい |

- **CI ジョブ全体は 146〜182s なので CI は ±4%。判断材料にならない**
- **遅さは 1 箇所ではない**。link index（12%）でも Markdown（+3.4%）でもなく、
  **約 10 サイクル/バイトが全体に薄く広がっている**。3 回別々に犯人を探して 3 回とも外した
- **増分の方がレンダラより Lean に有利**。パースしない部分（merge のコピー）は 1.10x、
  メモリは impact が 10.4 MB 対 Rust 56.2 MB
- **増分のコストは bimodal**（ownership の IR 読みが 2 回 or 423 回、421 倍差）。
  平均増分ビルド時間は 2 つのモードの平均

## 成果物
- `benchmarks/purelean-report.md` — レポート本体
- `benchmarks/results/purelean-{microbench,microbench-optimised,renderer,markdown,incremental,ci-baseline,ci-runs,ci-probe}-2026-08-30.txt` — 実測 8 本
- `benchmarks/lean-prototype/` — Lean 実装（Render.lean 1,866 行 / Incr.lean 1,079 行 /
  Main.lean 1,070 行のベンチ）。`lake build bench render incr` で全部建つ
- 測定ブランチ（**main にマージしない**）: litedoc4 の `purelean-ci-probe`、
  information-theory の `purelean-ci-bench`

## 残っている未測定（レポートの "Not measured" 節）
1. **並列化した Rust**。0.39s は 1 スレッドで、`render_site` は素の `for`、rayon 依存なし。
   **4 スレッドの Lean と 1 スレッドの Rust を比べているので、1.33x / 0.65x は公平ではない**
2. `math-core` 相当（LaTeX→MathML）の置き換え — 手つかず
3. 検索インデックス、`watch`（Lean 4.31 に `Std.Async.TCP` があるので書けることは確認済み）
4. **本物の pure Lean litedoc4 を CI で端から端まで**。CI の数字は実測部品の手合成

## 作業領域（残してある。消してよい）
`/private/tmp/lean-doc-relay/purelean/` 399 MB — IR（422 モジュール）、link-index、
Rust の出力 `pages/`、Lean の出力 `lp/` `lmd/`、増分の fixtures。
`/private/tmp/lean-doc-relay/purelean-incr/` 288 KB — 名前が動く inc ツリー。
再生成は `extractor/build.sh` → `litedoc4 modules` → `litedoc4 extract --link-index`。

## 測定で踏んだ罠（このリポジトリの既存の教訓と同じ形が 3 つ増えた）
1. **Lean の遅延評価、3 形**: `timeIt (pure (f x))` は thunk 確保を測る /
   値が後で forced されて別フェーズに乗る / `do let x := pureFn y; return (x,n)` は
   **どのフェーズにも計上されない**。**対策はフェーズ合計をプロセス wall と突き合わせること**
2. **`uses: ./litedoc4`（ローカル action）は本番と別物**: `actions/cache` が
   `Invalid pattern` の警告だけ出して一切保存せず、`github.action_ref` が空なので
   release ではなく `cargo build` が走る。どちらも exit code に出ない
3. **`lake build` は `defaultTargets` しか作らない**: Render.lean を一度もコンパイルせずに
   「レンダラのビルド時間」を報告した。**ステップに成果物の一覧を出させる**のが対策
4. **ベンチが容器自身のキーで引くと測っているのはポインタ等価**（`lidx.lookup` が 0.1049 →
   実際は 0.1442）。逆に**合成アクセスパターンの下限は高すぎることもある**
   （実際のレンダラの traffic は 8 分の 1 だった）
