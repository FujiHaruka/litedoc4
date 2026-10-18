---
title: パフォーマンス
description: litedoc4 と doc-gen4 の所要時間、その条件、ログ。
---

| | doc-gen4 | litedoc4 |
|---|---:|---:|
| Mathlib に依存する 419 モジュールのパッケージ | Mathlib 全体も文書化する | **14 s** |
| Batteries | 80 s | **8.5 s** |
| Mathlib | 1 h 53 min | **9.4 min** |

すべて GitHub の `ubuntu-latest` ランナーで 2026-10-17 に計測した値です (measured)。行ごとに答えている問いが違うので、下の条件と合わせて読んでください。ログはすべて [`benchmarks/results/`](https://github.com/FujiHaruka/litedoc4/tree/main/benchmarks/results) にあります。

## Mathlib に依存する 419 モジュールのパッケージ

- **内容:** [information-theory](https://fujiharuka.github.io/information-theory/) パッケージの `InformationTheory` ライブラリ (419 モジュール) を、1 バージョン、空の `--out`、`--jobs 4` で `litedoc4 build` した。14.1 s、うち抽出が 10.8 s。
- **場所:** そのパッケージ自身の docs ワークフローで、litedoc4 v2.0.0 の Action を使用。Lean v4.31.0。パッケージは同じジョブの前のステップでビルドされており、olean は書き出されたか復元された直後だった。
- **含まないもの:** 抽出器のビルド (17.6 s) と `litedoc4` 実行ファイルのビルド (48.2 s)。どちらも初回だけで、以降はキャッシュされる。パッケージ自身の `lake build` も含まない。
- **ランナー:** `ubuntu-latest`。ログには CPU とメモリが出ていない。公開リポジトリのこのランナーは 4 vCPU、16 GB のクラス (assumed)。
- **1 回の実行。** 収束を確かめた値ではない。
- **doc-gen4** はこのパッケージでは実行していない。doc-gen4 は import の閉包全体を文書化するので、Mathlib 全体も文書化することになる。
- **ログ:** [`benchmarks/results/information-theory-ci-2026-10-17.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/benchmarks/results/information-theory-ci-2026-10-17.txt)

## Batteries

- **内容:** Batteries v4.35.0 を両方のツールで同じランナー上で文書化し、ラウンドごとにツールを交互に実行した。Batteries は Lean core 以外に依存しないので、両者は同じ 195 モジュールを文書化する。litedoc4 は既定値で `build`、doc-gen4 は `lake build Batteries:docs`。
- **値:** ウォームな 5 ラウンドの中央値、並列ジョブ 4: litedoc4 8.5 s、doc-gen4 80.5 s。プロセスツリーのピークメモリは litedoc4 198 MiB、doc-gen4 2,277 MiB。
- **doc-gen4 の時間には**、最後の HTML の工程が含まれる。この工程は Lean core の 2,505 ページも書く。doc-gen4 の利用者はこの工程を避けられない。
- **両方から除いたもの:** doc-gen4 とその Lean core のデータベースのビルド、litedoc4 の抽出器のビルド。
- **ランナー:** `ubuntu-latest`、AMD EPYC 7763、4 vCPU、16 GB。Lean v4.35.0、doc-gen4 v4.35.0。
- **ログ:** [`benchmarks/results/batteries-docgen4-litedoc4-2026-10-17.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/benchmarks/results/batteries-docgen4-litedoc4-2026-10-17.txt)

## Mathlib

- **内容:** Mathlib v4.35.0 のドキュメントを何もない状態から、同じランナー上で両方のツールを順に実行した。litedoc4 は `build --lib Mathlib`、1 バージョン、空の `--out`、`--jobs 4` で 565.7 s。doc-gen4 は `lake build Mathlib:docs` と `Mathlib:docsHeader` を Lake の既定の並列度 (4 ジョブ) で 6,773 s。
- **範囲が違う。** litedoc4 は `Mathlib` ライブラリの 8,625 モジュールを文書化し、依存先にはリンクする。doc-gen4 は依存先と Lean core も文書化する。HTML ファイル数は doc-gen4 の 11,548 に対し litedoc4 は 8,631 ページ。したがってこの比は同じ仕事の比ではない。
- **等式の扱いは litedoc4 に有利。** litedoc4 は `no_equations_under = ["Mathlib.Tactic", "Mathlib.Meta"]` で実行し、これらの名前空間の定義には等式を生成しなかった。doc-gen4 にはこの設定がなく、すべての定義について等式を計算する。
- **どちらにも含まないもの:** litedoc4 のビルド、doc-gen4 のビルド、`lake exe cache get`。
- **ランナー:** `ubuntu-latest`、AMD EPYC 7763、4 vCPU、16 GB。Lean v4.35.0、doc-gen4 v4.35.0。olean は `lake exe cache get` で書き出された直後だった。
- **各ツール 1 回の実行。**
- **ログ:** [`benchmarks/results/docgen4-runner-2026-10-17.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/benchmarks/results/docgen4-runner-2026-10-17.txt)

## 12 の Mathlib リリースを一つのサイトに

[mathlib.fuji.land](https://mathlib.fuji.land) には 12 の Mathlib リリースが入っており、`ubuntu-latest` (4 vCPU、16 GB) 上の一つのワークフローが `--jobs 4` でビルドとデプロイを行う。それぞれ 1 回の実行:

- **空のストアから 12 個すべて:** ビルド 84.6 min。
- **デプロイ済みの 11 個のサイトに 12 個目を追加:** ビルド 11.6 min。ジョブの開始から、デプロイしたサイトがチェックに通るまでが 18.5 min。ストアにあった 11 バージョンは抽出もレンダリングもし直さなかった。
- **ログ:** [`benchmarks/results/mathlib-site-first-run-2026-10-17.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/benchmarks/results/mathlib-site-first-run-2026-10-17.txt)、[`benchmarks/results/mathlib-site-add-one-2026-10-17.txt`](https://github.com/FujiHaruka/litedoc4/blob/main/benchmarks/results/mathlib-site-add-one-2026-10-17.txt)
