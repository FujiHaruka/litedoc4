---
title: litedoc4
description: Mathlib の上に立つ Lean 4 パッケージのための HTML ドキュメント生成ツール。速く、すべてのバージョンを一つのサイトに収めます。
template: splash
hero:
  tagline: Mathlib の上に立つ Lean 4 パッケージのための HTML ドキュメント。速く、すべてのバージョンを一つのサイトに収めます。
  image:
    light: ../../../../../docs/images/site-light.png
    dark: ../../../../../docs/images/site-dark.png
    alt: 実例サイトのモジュールページ。モジュールの docstring、完全なシグネチャ付きの定理、モジュールツリー、検索ボックスが表示されている。
  actions:
    - text: クイックスタート
      link: /litedoc4/ja/getting-started/quickstart/
      icon: right-arrow
    - text: GitHub
      link: https://github.com/FujiHaruka/litedoc4
      icon: external
      variant: minimal
---

litedoc4 が文書化するのはあなたのパッケージだけです。Mathlib、Batteries、Lean core など `lake-manifest.json` が固定している依存先のページは生成し直しません。依存先への参照はすべて、ビルドに使ったリビジョンそのものの GitHub 上のソースにリンクします。出力は静的サイトです。

## 動いているサイト

- [information-theory](https://fujiharuka.github.io/information-theory/): Mathlib に依存する約 420 モジュールのパッケージ
- [mathlib.fuji.land](https://mathlib.fuji.land): Mathlib そのもの。12 リリースを一つのサイトに収めたもの
- [サンプル](https://fujiharuka.github.io/litedoc4/sample/): ページがとりうる形をすべて見せる小さなパッケージ

## なぜ速いのか

- **Mathlib ではなく、あなたのパッケージだけ。** doc-gen4 は import するものすべてのページを書きます。litedoc4 はあなたのパッケージのページだけを書き、残りにはリンクします。
- **変わったものだけ。** 再ビルドで抽出し直すのは、olean が変わったモジュールだけです。
- **Lean の環境は一つ。** モジュールは一つの環境の中で並列スレッドで抽出します。モジュールごとにプロセスを起こして import を読み直すことはしません。

| | doc-gen4 | litedoc4 |
|---|---:|---:|
| Mathlib に依存する 419 モジュールのパッケージ | Mathlib 全体も文書化する | **14 s** |
| Batteries | 80 s | **8.5 s** |
| Mathlib | 1 h 53 min | **9.4 min** |

すべて GitHub の `ubuntu-latest` ランナーで 2026-10-17 に計測した値です (measured)。Lean は 1 行目が v4.31.0、ほかは v4.35.0。doc-gen4 の時間には、Lean core と依存先についても書くページの分が含まれます。条件とログは[パフォーマンス](/litedoc4/ja/performance/)のページにあります。

## すべてのバージョンを一つのサイトに

タグ、ブランチ、コミットを指定すると、litedoc4 はそれらすべてを収めた一つのサイトを作ります。バージョンごとにパスが分かれ、各ページのバージョン切り替えは同じページのまま移動します。ビルド済みのバージョンは保存されるので、新しいリリースのコストはそのリリースの分だけです。mathlib.fuji.land に Mathlib の 12 個目のリリースを追加したときは約 12 分でした (measured)。詳しくは[複数バージョン](/litedoc4/ja/guides/versions/)を参照してください。
