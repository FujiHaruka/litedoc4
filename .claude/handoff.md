# Handoff — 2026-08-30

## State

- Branch: main
- Uncommitted: clean
- Active phase / 作業中の文脈: **pure Lean 置き換えの調査は完了** (`4903423`)。
  次は「移行するかの判断を詰める」段。実装は捨てプロトタイプで、製品コードは無傷
- 計測環境: 作業領域 `/private/tmp/lean-doc-relay/purelean/` (399 MB) に IR 422 モジュール /
  link-index / Rust の出力 `pages/` / Lean の出力 `lmd/` / 増分 fixtures が残っている。
  消してよい。再生成は `extractor/build.sh` → `litedoc4 modules` → `litedoc4 extract --link-index`

## Where we are

調査は完遂した。速度 **2.74x（逐次）/ 1.33x（4 スレッド）**、出力は **420/422 ページが
Rust とバイト一致**、CI は **±4%**、増分コアは 4 スレッドで Rust の逐次より速い。
結論と判断材料は `benchmarks/purelean-report.md`、実測 8 本は `benchmarks/results/purelean-*.txt`。
推奨は「**今は移行しない。ただし Rust を維持する積極的な理由も、もう無い**」。
**判断を左右するのに未検証のものが 2 つ残っている** — Windows の release アセットが作れるか、
並列化した Rust が何秒か。

## Next step

**Windows の release アセットが作れるかを確かめる。** これが移行の動機の大半を消すか残すかを決める。

- `.github/workflows/release.yml` の matrix に `x86_64-pc-windows-msvc` / `windows-latest` を
  足したブランチを切り、**`push:` トリガーでそのブランチを名指しして**走らせる
  （`workflow_dispatch` は default branch に無いワークフローには効かない → CLAUDE.md）
- 確かめるのは 2 つだけ: `cargo build --release` が MSVC で通るか、
  `crates/litedoc4-md/vendor/md4c` の C が MSVC で通るか
- 通るなら `lakefile.lean` の `releaseTargets`、`action.yml` の `RUNNER_OS-$(uname -m)` case、
  `tools/lake-download-gate.sh` も**同時に**足す（4 箇所そろえる、CLAUDE.md に明記）
- 次に安いのは **Rust の `render_site` を std::thread で分割して測る**こと。
  製品コードを触る実験なので commit しない（scratch copy か stash で）

## Files to read first

- `benchmarks/purelean-report.md` — 調査の結論と判断材料。まずこれ
- `.github/workflows/release.yml` L49-70 — matrix と、Intel Mac を外した理由。
  **Windows を外した理由はどこにも書かれていない**
- `CLAUDE.md` の「Releases carry three triples」— 4 箇所そろえる根拠
- `benchmarks/results/purelean-incremental-2026-08-30.txt` — 増分が Lean に有利な理由と、
  §5.6 の 4.00 vs 3.00 の分解

## Load-bearing context

- **Windows が release に無い理由は無言**。Intel macOS には `decided 2026-08-29, user's call`
  があるが Windows には無い。単に追加されていないだけの可能性が高い。
  `windows-latest` は `ci-browser-windows.yml` で既に動いている（ランナーは使える）
- **並列化した Rust は未測定**。`render_site` は素の `for` で workspace に rayon なし。
  今の 1.33x / 0.65x は「4 スレッドの Lean 対 1 スレッドの Rust」で公平ではない
- 測定ブランチ 2 本を意図的に残してある。**main にマージしない**:
  litedoc4 `purelean-ci-probe`、information-theory `purelean-ci-bench`
- 今回踏んだ罠 4 つは results に記録済み。特に効くのは
  **`lake build` は `defaultTargets` しか作らない**（Render.lean を一度もコンパイルせずに
  「レンダラのビルド時間」を報告した）と、**ローカル `uses: ./action` は cache も release も
  効かない**（どちらも exit code 0）
