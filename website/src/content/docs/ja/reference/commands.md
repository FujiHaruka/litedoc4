---
title: コマンドとフラグ
description: build と watch のコマンド、よく使うフラグ。
---

```
litedoc4 build  --root <repo> --out <dir> [--lib <Name>]... [--versions <list>]
                [--jobs <n>] [--source-url <url>] [--config <file>] [--full]
litedoc4 watch  --root <repo> --out <dir> [--lib <Name>]... [--jobs <n>] [--port <n>]
```

`build` はサイトを 1 回書き出します。`watch` はサイトを配信し、パッケージの olean が変わると再ビルドします ([作業しながら確認する](/litedoc4/ja/guides/watch/))。

`lake run docs` は `--root`、`--lib`、`--extractor-bin` を自動で渡します。`watch` や、`docs` が渡さないフラグを使うときは、コマンドを直接呼びます。最初の `lake run docs` の後、2 つの実行ファイルは `.lake/packages/litedoc4/.lake/build/bin/` にあります。`litedoc4 --help-all` はすべてのフラグを表示します。

## フラグ

| フラグ | コマンド | 内容 |
|---|---|---|
| `--root <repo>` | build, watch | 文書化する Lean パッケージ |
| `--out <dir>` | build, watch | litedoc4 が管理するディレクトリ。サイトは `<out>/site`。パッケージの外に置く必要があり、相対パスはパッケージのディレクトリから解釈される |
| `--lib <Name>` | build, watch | ライブラリのルート。繰り返し指定できる。`lakefile.toml` からライブラリを読めないとき (多くの `lakefile.lean` のパッケージ) に必要 |
| `--full` | build | すべてのモジュールを抽出し直す |
| `--jobs <n>` | build, watch | olean のハッシュ計算と抽出器のスレッド数 |
| `--source-url <url>` | build, watch | `origin` が GitHub でないときの、ソースリンクのベース URL |
| `--config <file>` | build, watch | パッケージの `litedoc4.toml` の代わりに読むファイル ([サイトの設定](/litedoc4/ja/guides/configuration/)) |
| `--versions <list>` | build | カンマ区切りのタグ、ブランチ、コミット。最新を最後に置く ([複数バージョン](/litedoc4/ja/guides/versions/)) |
| `--store <dir>` | build | `--versions` と一緒に使い、ビルドしたバージョンの保存先を指定する。既定は `<out>/store` |
| `--hash-urls` | build, watch | すべてのページをルートの `index.html` から配信し、ルートを URL のフラグメントに置く |
| `--extractor-bin <path>` | build, watch | ビルド済みの抽出器。省略すると、`--root` が固定する Lean 用に一つビルドする |
| `--lake <path>` | build, watch | 使う `lake` 実行ファイル |
| `--timings <file>` | build | 件数と所要時間を JSON 1 行で書き出す |
| `--port <n>` | watch | 配信するポート。既定は 8484 |
| `--interval <ms>` | watch | olean の変化を確認する間隔 (ミリ秒)。既定は 1000 |
