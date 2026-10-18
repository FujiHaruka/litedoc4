---
title: サイトの設定
description: litedoc4.toml と 4 つのキー。
---

lakefile の隣に `litedoc4.toml` を置きます。どのキーも省略できます。

```toml
title = "MyPkg"                 # top bar and page titles; default: your modules' shared prefix
index = "docs/index.md"         # Markdown at the top of the front page
footer = "docs/footer.md"       # Markdown at the bottom of every page
no_equations_under = ["MyPkg.Tactic"]   # namespaces whose definitions get no equations
```

## `title`

上部のバーと、各ページの `<title>` の後半に表示されます。省略すると、モジュールに共通する名前がタイトルになります (`Foo.*` なら `Foo`)。これは読者がパッケージを import するときに打つ名前です。

## `index` と `footer`

`litedoc4.toml` のあるディレクトリからの相対パスで指定する Markdown ファイルです。docstring と同じようにレンダリングされるので、バッククォートで囲んだ名前はその宣言にリンクします。

- `index` はサイトのトップページの先頭に入ります。
- `footer` はすべてのページの末尾に入ります。モジュールページ、トップページ、検索、参考文献、not-found ページのすべてです。ライセンスの一文や、サイトの公開者についての注記に使います。

## `no_equations_under`

タクティク、エラボレーター、メタプログラムなどの実装コード向けです。これらの等式は、コード自身の本体を補題として表示してしまいます。名前がここに挙げた名前空間の中にある定義には、等式を付けません。生成自体をしません。`MyPkg.Tactic.ring_nf` は `MyPkg.Tactic` の中にあります。`MyPkg.TacticX.foo` と `MyPkg.Tactic` 自身は中にありません。

シグネチャ、docstring、ソースリンクは残ります。リストを変えると、次のビルドですべてのモジュールを抽出し直します。

## エラーでビルドは止まる

形式が正しくないファイル、未知のキー、存在しないファイルを指す `index` や `footer` があると、ビルドは止まります。

## 自分で管理していないパッケージ

ファイルを別の場所に置き、`--config` で指定します (`build` と `watch`)。パッケージ自身の `litedoc4.toml` の代わりに読まれ、`--versions` のビルドではすべてのバージョンに使われます。その `index` と `footer` は、そのファイル自身のディレクトリからの相対パスです。`docs/references.bib` は引き続きパッケージから読みます。

タイトル、トップページ、フッターはサイトのレンダリング時に適用されるので、変更するとすべてのバージョンをレンダリングし直し、抽出はしません。`no_equations_under` を変更すると、すべてのバージョンを抽出し直します。存在しないファイルを指す `--config` はビルドを止めます。
