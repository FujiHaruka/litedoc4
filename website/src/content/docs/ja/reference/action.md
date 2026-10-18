---
title: GitHub Action
description: litedoc4 の GitHub Action の入力と出力。
---

Action はパッケージとそのドキュメントを一つのジョブでビルドします。公開はしません。出力の `site` を `actions/upload-pages-artifact` か `actions/upload-artifact` に渡してください。ワークフロー全体は [GitHub Pages に公開する](/litedoc4/ja/getting-started/github-pages/)にあります。

パッケージのビルドとドキュメントのビルドは一つのジョブにまとめてください。別のジョブではページキャッシュが冷えていて、抽出がずっと遅くなります。

## 入力

| 入力 | 既定値 | 内容 |
|---|---|---|
| `root` | `.` | Lean パッケージ。ワークスペースからの相対パス (または絶対パス) |
| `out` | `RUNNER_TEMP` の下のディレクトリ | ドキュメントの状態。`<out>/site` がサイト。`root` の外に置く必要がある |
| `cache-get` | `false` | 最初に `lake exe cache get` を実行する。Mathlib に依存するパッケージで使う |
| `lake-build` | `true` | 同じジョブで `lake build` を実行する。同じジョブの前のステップでパッケージをビルド済みのときだけ `false` にする |
| `jobs` | `4` | olean のハッシュ計算と抽出器のスレッド数 |
| `lib` | | `lakefile.toml` から読めないときのライブラリ名 (`lakefile.lean` では必要) |
| `source-url` | | `origin` が GitHub でないときの、ソースリンクのベース URL |
| `full` | `false` | すべてのモジュールを抽出し直す |
| `versions` | | リポジトリのタグ、ブランチ、コミットをカンマ区切りで指定し、最新を最後に置く。空なら、チェックアウトした作業ツリーが唯一のバージョン |
| `store` | `<out>/store` | `versions` と一緒に使い、ビルドしたバージョンの保存先を指定する。`versions` なしで指定するとステップは失敗する |
| `hash-urls` | `false` | すべてのページをルートの `index.html` から配信し、ルートを URL のフラグメントに置く |
| `install-elan` | `true` | `PATH` に `lake` がなければ elan をインストールする |
| `cache` | `true` | 抽出器、`litedoc4` のビルド、Mathlib の olean、ストアと抽出状態に `actions/cache` を使う |

## 出力

| 出力 | 内容 |
|---|---|
| `site` | 生成したサイト |
| `out` | 状態ディレクトリ (サイト、ストア、抽出状態)。実行のたびに残す |
| `timings` | フェーズごとの所要時間を記録した JSON のパス |
| `binary-source` | `litedoc4` 実行ファイルの作られ方。常に `lake` |

すべての入力は [`action.yml`](https://github.com/FujiHaruka/litedoc4/blob/main/action.yml) にも説明があります。
