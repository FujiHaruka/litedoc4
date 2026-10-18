---
title: クイックスタート
description: Lean パッケージに litedoc4 を追加して、ドキュメントサイトをビルドします。
---

必要なのは `elan` と、`lake build` が通るパッケージです。

## 依存を追加する

`lakefile.lean` に 1 行追加します。`lakefile.toml` なら同じ内容の `[[require]]` を書きます。

```lean
require «litedoc4» from git "https://github.com/FujiHaruka/litedoc4" @ "v2.0.0"
```

## サイトをビルドする

```sh
lake run docs -- --out ../mypkg-docs
```

サイトは `../mypkg-docs/site` に書き出されます。ページはスクリプトで描画され、ディスクから直接開いたページではブラウザがそのスクリプトを実行しません。HTTP で配信し、サーバーが表示するアドレスを開いてください。

```sh
python3 -m http.server -d ../mypkg-docs/site
```

サイトには 1 つのバージョンが入り、コミットの先頭 12 桁の 16 進数がその名前になります。複数のバージョンを一つのサイトに入れるには[複数バージョン](/litedoc4/ja/guides/versions/)を参照してください。

## 初回に起きること

何もダウンロードしません。`require` の 1 行がインストールのすべてです。Lake が `litedoc4` と抽出器の 2 つの実行ファイルを、固定したリビジョンからあなたのツールチェーンでビルドします。所要時間は約 1 分で (measured、GitHub のランナーで計測。[パフォーマンス](/litedoc4/ja/performance/)を参照)、最初の 1 回だけです。以降は再利用されます。Markdown パーサーが必要とする C コードは Lean ツールチェーン付属の `clang` がコンパイルするので、C コンパイラも Rust も node も要りません。

`lake run docs` は `--root`、`--lib`、`--extractor-bin` を自動で渡します。`lakefile.lean` のパッケージでも同じです。

## `--out` を残す

- `--out` は必須で、パッケージの外に置く必要があります。相対パスはパッケージのディレクトリから解釈されるので、`../mypkg-docs` がいちばん短い書き方です。
- `--out` は実行のたびに残してください。次の実行では olean が変わったモジュールだけを抽出し直します。
- `--full` はすべてのモジュールを抽出し直します。

## 次に読むもの

- GitHub Action で [GitHub Pages に公開する](/litedoc4/ja/getting-started/github-pages/)
- [作業しながら確認する](/litedoc4/ja/guides/watch/): ビルドしながら変更を見る
- [コマンドとフラグ](/litedoc4/ja/reference/commands/): `lake run docs` が渡さないフラグ
