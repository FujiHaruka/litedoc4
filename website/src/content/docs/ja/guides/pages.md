---
title: ページに表示されるもの
description: モジュール一覧、数式、sorry の表示、引用。
---

## モジュール一覧

トップページには、パッケージのすべてのモジュールが 1 行の説明付きで並び、モジュールツリーも表示されます。説明は、モジュール docstring の冒頭の見出しです。

```lean
/-!
# Strong typicality (Cover-Thomas)

Three main theorems for the strongly typical set …
-/
```

`Strong typicality (Cover-Thomas)` がトップページでのそのモジュールの行になります。見出しの下の文章は、モジュール自身のページに残ります。docstring が文章で始まるモジュールは、名前だけが並びます。

## 検索とリンク

検索の対象はパッケージの宣言です。各ページには、パッケージ内でのインスタンスの一覧、"Imported by"、"Used by" が表示されます。シグネチャの中の依存先の名前は、すべて固定したリビジョンの GitHub 上のソースにリンクします。

## 数式

`$…$` と `$$…$$` は、サイトのビルド時に MathML になります。描画のためにブラウザで読み込むものはありません。MathJax も KaTeX も数式用 Web フォントも使わず、現在のブラウザが MathML を自分でレイアウトします。変換できない数式は、ソースのまま表示します。

## `sorry`

- **uses `sorry`**: 宣言自身の主張か証明に `sorry` がある。
- **depends on `sorry`**: 自身の証明は完全だが、その下にある宣言が `sorry` を使っている。

判定はコンパイル済みの環境 (宣言の公理) から行うので、依存がどれだけ深くても成り立ちます。どちらの印もない宣言の下には `sorry` はありません。

Lean が `@[ext]` から作った宣言には **realized by `@[ext]` from …** と表示し、元の宣言にリンクします。

## 引用

パッケージの `docs/references.bib` に BibTeX ファイルを置くと、どの docstring からもその項目を引用できます。

```lean
/-- The entropy bound of [CoverThomas2006], proved as in [chapter 2][CoverThomas2006]. -/
```

- `[Key]` は項目のタグを表示するリンクになります。`[text][Key]` は書いたテキストをそのまま使います。
- どちらも `references.html` にリンクします。このページはすべての項目をアンカー `#ref_Key` 付きで並べ、各項目の末尾に、それを引用しているすべての場所への番号付きリンクを置きます。
- タグと項目の本文は doc-gen4 と同じライブラリ BibtexQuery が作るので、doc-gen4 のサイトと一致します。
- ファイルにないキーの角括弧は、書いたまま残ります。
- BibtexQuery は `@string`、`@comment`、`@preamble`、note の中の単独の `@` を読めず、最初に出てきたところで止まります。その項目とそれ以降の項目はすべて除かれるので、ビルドはファイルと行を示して警告を出します。
