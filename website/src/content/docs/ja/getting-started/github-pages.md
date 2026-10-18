---
title: GitHub Pages に公開する
description: push のたびにドキュメントをビルドして GitHub Pages に公開するワークフロー。
---

次のファイルをパッケージの `.github/workflows/docs.yml` として保存し、**Settings → Pages → Source** を **GitHub Actions** にします。

```yaml
name: docs
on: { push: { branches: [main] } }
jobs:
  docs:
    runs-on: ubuntu-latest
    permissions: { contents: read, pages: write, id-token: write }
    environment: { name: github-pages }
    steps:
      - uses: actions/checkout@v7
      - uses: FujiHaruka/litedoc4@v2.0.0
        id: docs
        with:
          cache-get: true             # `lake exe cache get`。Mathlib を使わないなら削除
      - uses: actions/upload-pages-artifact@v5
        with: { path: "${{ steps.docs.outputs.site }}" }
      - uses: actions/deploy-pages@v5
```

Action は elan がなければインストールし、`lake build` とドキュメントのビルドを一つのジョブで実行します。次の実行に必要なものはキャッシュします。

- Mathlib の olean
- Lean の抽出器
- `litedoc4` のビルド
- 前回の実行のストアと抽出状態。これにより次の実行では変わったモジュールだけを抽出します

## 複数バージョン

複数のバージョンを一つのサイトに公開するには、`with:` の下に `versions` を追加し、`actions/checkout` に全履歴を取らせます。既定では履歴もタグも取得しないためです。

```yaml
      - uses: actions/checkout@v7
        with: { fetch-depth: 0 }
      - uses: FujiHaruka/litedoc4@v2.0.0
        id: docs
        with:
          versions: v0.4.0,v0.5.0,main
```

バージョンのビルドと保存のしかたは[複数バージョン](/litedoc4/ja/guides/versions/)を参照してください。

## 公開せずに保存する

最後の 2 ステップを `actions/upload-artifact` に置き換え、`permissions` と `environment` の行を削除します。

## そのほかの入力

パッケージがリポジトリのルートにないときの `root`、`lakefile.lean` のパッケージのための `lib` などは [GitHub Action](/litedoc4/ja/reference/action/) を参照してください。
