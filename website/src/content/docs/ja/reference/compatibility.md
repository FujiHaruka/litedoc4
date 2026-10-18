---
title: 互換性と動作要件
description: 2.x で変わらないもの、対応する Lean のバージョン、動作環境。
---

## 動作要件

- **ソースが GitHub にあること。** ソースリンクは GitHub の URL です。ほかのホストでは `--source-url` を指定してください。litedoc4 は推測しません。
- **Lean v4.31.0、v4.32.2、v4.33.0、v4.33.1、v4.34.1、v4.35.0 のいずれか。** ほかのバージョンは、何かを実行する前にバージョン名を挙げて拒否されます。一覧は [`tools/lean-toolchains.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/tools/lean-toolchains.txt) です。CI は抽出器かサンプルが変わるたびに一覧のすべてのバージョンを最初から最後まで実行し、出力を比べます。
- **Linux と macOS。** 生成側は macOS (Apple Silicon) と GitHub の `ubuntu-latest` でテストしています。サイトのブラウザ側は `windows-latest` でもテストしています。Windows で生成側を動かしたことはありません。

`lakefile.lean` のパッケージも使えます。コマンドラインは Lean のコードからライブラリ名を読まないので、`--lib` を自分で指定してください。`lake run docs` は自動で指定します。Action では `lib` 入力を指定します。

## 2.x で変わらないもの

2.x の間は、あなた自身のファイルに書かれうる名前を削除も改名もしません。

- Action の入力と出力
- `litedoc4.toml` のキー
- `build` と `watch` のフラグ
- サイトのページパスと宣言のアンカー

一覧は [`tools/public-surface.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/tools/public-surface.txt) で、そこにある名前が消えると CI が失敗します。

IR のスキーマ、レジャー、`.lidx` ファイルは内部のものです。自分で固定することはありません。Action と `lake run docs` は固定したリビジョンから 2 つの実行ファイルをビルドするので、両者は常に同じツリーから作られます。

## タグに固定する

Action と `require` はタグに固定してください。`@main` は動きます。

## バイナリは配布しない

どちらの実行ファイルもバイナリでは配布しません。Lake が固定したリビジョンから両方をビルドするので、そのリビジョンと揃えておくべきものがもう一つ増えることはありません。ビルドは約 1 分で (measured、[パフォーマンス](/litedoc4/ja/performance/)を参照)、CI でも Lake でもキャッシュされます。

このパッケージには意図して `lean-toolchain` を置いていません。置くと、それより高いバージョンならあなたの `lake update` があなた自身の `lean-toolchain` を書き換え、低いバージョンなら警告なしに無視されます。置かなければ、Lake はあなたのツールチェーンで両方の実行ファイルをビルドします。
