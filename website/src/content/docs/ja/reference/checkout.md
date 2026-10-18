---
title: チェックアウトから実行する
description: このリポジトリのクローンから litedoc4 をビルドし、パッケージを文書化します。
---

```sh
git clone https://github.com/FujiHaruka/litedoc4 && cd litedoc4
tools/ci-build.sh --root /path/to/your-package --out /path/to/docs
```

パッケージのツールチェーンで 2 つの実行ファイルをビルドしてから、パッケージを文書化します。`litedoc4` は `.lake/build/bin/` に、抽出器は `extractor/build/` に残ります。スクリプトをもう一度実行すると、どちらも再利用します。

このリポジトリには `lean-toolchain` がないので、リポジトリ自身の `lakefile.lean` の隣では `lake` が動きません。そのためスクリプトは、このチェックアウトを require する 1 行のパッケージを `.lake/host` の下に書き、パッケージの `lean-toolchain` をそこにコピーして、そこからビルドします。

チェックアウトから watch するには:

```sh
.lake/build/bin/litedoc4 watch --root /path/to/your-package --out /path/to/docs \
  --extractor-bin extractor/build/extract
```
