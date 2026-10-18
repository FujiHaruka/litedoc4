---
title: 複数バージョン
description: パッケージの複数のタグ、ブランチ、コミットを一つのサイトに収めます。
---

```sh
litedoc4 build --root <repo> --out <dir> --versions v0.4.0,v0.5.0,main [--lib <Name>]...
```

`--versions` には `--root` の git リポジトリのタグ、ブランチ、コミットをカンマ区切りで指定します。最新のものを最後に置きます。litedoc4 はそれらすべてを収めた一つのサイトを作ります。

## サイトの構成

- 各バージョンのページはバージョン名の下に置かれます。例: `v0.5.0/Foo/Bar.html`
- すべてのページにバージョン切り替えがあり、別のバージョンの同じページを開きます。そのバージョンにモジュールがなければ、そのバージョンのトップページを開き、モジュールがないことを示します。
- バージョンを含まない doc-gen4 形式のリンク `Foo/Bar.html#Foo.bar` は、最新バージョンの同じページに移動します。これには、存在しないパスにサイトの `404.html` を返すホストが必要です。GitHub Pages はそのように動きます。

## 各バージョンのビルド

各バージョンは `--out` の下にチェックアウトされます。elan がそのツールチェーンをインストールし、`lake build` がライブラリをビルドし、そのバージョンの Lean 用にビルドした抽出器がモジュールを抽出します。したがって `lake` は elan のものである必要があります (`--lake` で指定)。ツールチェーンが [`tools/lean-toolchains.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/tools/lean-toolchains.txt) にないバージョンは、何かを実行する前に拒否されます。

ストアに古いバージョンが一つもなく、最新バージョンが litedoc4 の対応する最新の Lean を使っている場合、古いバージョンはそれぞれの Lean ではなく最新バージョンの Lean で読み込まれます。こうして読んだ宣言は、表示が別の場所で宣言された記法や束縛子に依存する場合、本来の Lean での表示と異なることがあります。

## ストアを残す

`<out>/store` にはビルドしたすべてのバージョンが保存されます。`--store` で場所を変えられます。**実行のたびに残してください。**

- ストアが同じコミットで保持しているバージョンは、抽出し直しません
- サイトがすでに保持しているバージョンは、レンダリングし直しません

そのため、リストにリリースを一つ追加するコストはそのリリースの分だけです。

## GitHub Action では

`versions` 入力を使います。ストアを `<out>/store` 以外に置くなら `store` も指定します。Action はストアをほかの状態と一緒にキャッシュします。`actions/checkout` は既定で履歴もタグも取得しないので、`fetch-depth: 0` を指定してください。ワークフローは [GitHub Pages に公開する](/litedoc4/ja/getting-started/github-pages/#複数バージョン)にあります。

## サブパスの下に置く

GitHub Pages は、Pages サイト内の存在しないパスすべてにそのサイトのルートの `404.html` を返します。litedoc4 のサイトが大きな Pages サイトの一つのディレクトリである場合、応答するのは litedoc4 自身の `404.html` ではありません。そのときバージョンなしのリンクが動くのは、ホストのルートの `404.html` が、litedoc4 のディレクトリの下で見つからなかったパスを litedoc4 のリダイレクトに渡す場合だけです。

このドキュメントは[サンプル](https://fujiharuka.github.io/litedoc4/sample/)についてこれを行っています。`/litedoc4/sample/` の下で見つからないパスに対して、この 404 ページはサンプル自身の `404.html` を読み込み、それが読者を最新バージョンに送ります。

## すべてのパスを一つのページで

`--hash-urls` (Action では `hash-urls` 入力) を付けると、ページごとのファイルを作りません。ルートの `index.html` が URL のフラグメント `#/<version>/<module path>` からすべてのページを描画します。すべてのパスに一つのページを返せないホスト向けです。

## 実例

[mathlib.fuji.land](https://mathlib.fuji.land) はこの方法でビルドした Mathlib です。Mathlib の Releases ページにあるプレリリース以外のすべてのリリースを一つのサイトに収めています。ホスティングに必要なものは [`hosting/mathlib/`](https://github.com/FujiHaruka/litedoc4/tree/main/hosting/mathlib) にあります。
