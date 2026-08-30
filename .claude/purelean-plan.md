# pure Lean 移植 — リレーの計画

**これは実装計画であって docs ではない。** M10 完了時にこのファイルごと消す。
リポジトリの SoT はコードとゲート（CLAUDE.md）で、この文書が持つのは
**「まだコードになっていない部分の順序と、各段の完了判定」**だけ。

計測の根拠は `benchmarks/purelean-report.md` と `benchmarks/results/purelean-*.txt`。
**この計画はそれを前提にしており、数字を再掲しない**（再掲は腐る）。

## 確定した 4 つの判断（2026-08-30、ユーザー判断）

| | 決定 | 何が変わるか |
|---|---|---|
| 進め方 | **骨格先行** | 最小の pure Lean `build` を e2e/micro で通すのが最優先。以降 Rust バイナリを差分オラクルに機能を埋める |
| Rust の処遇 | **完了時に削除、`rust-frozen` タグで凍結** | 移植中は残す。M10 で `crates/` を HEAD から消す |
| 配布 | **バイナリ配布を廃止、`require` のみ** | `release.yml`・`resolveLitedoc4`・3 triple マトリクス・`lake-download-gate.sh`・`release-notes-gate.sh` が去る |
| ブランチ | **main 上で加算的に** | 切替（M9）まで既存ゲートは常に緑。leg ごとに push する |

私の裁量で決めたこと: **スレッド化は入れない**（順次実装でまず一致を取る。
性能は移植後の別問題）。**MathML4Lean の 107 件の意図的乖離は仕様どおりで欠陥としない**
（2026-08-30、ユーザー判断）。**TypeScript は移植対象外**、ビルド済み JS をリポジトリに置く。

## Approach

**3 つの構造的制約が設計を決めている。順序ではなく制約から入る。**

1. **`import Lean` した実行ファイルは 226 MB になる**（計測）。extractor は olean を読むので
   `import Lean` が要る。レンダラ側は要らず、5.3 MB で済む。
   → **2 つの `lean_exe` に分ける**。`extract`（現状のまま）と `litedoc4`（新規、`import Lean` 禁止）。
   今日 Rust CLI が extractor を subprocess で起動しているのと同じ関係を Lean 同士で維持する。
   **これは性能の話ではなく配布サイズの話**で、破ると配布モデルの決定（`require` のみ）が成立しない。

2. **root に `lean-toolchain` を置けない**（計測、`lake-package-probe-2026-08-18.txt` §1）。
   よって litedoc4 のディレクトリで `lake` が走らない。
   → **開発ワークスペースは `e2e/consumer`**。既に path require で litedoc4 を引き、
   `lean-toolchain: v4.31.0` を持つ。`cd e2e/consumer && lake build litedoc4` が
   ローカルのビルド手段になる。**消費者と同じ経路で開発する**ので、
   「開発では通るが消費者では通らない」という差が構造的に生まれない。

3. **Rust 実装が生きている間だけ差分オラクルが使える**。M9 で切り替えたら失われる。
   → **各マイルストーンの完了判定は「Rust とバイト一致」**。オラクルが消える前に
   全機能を突き合わせ終える。M8（対象リポジトリ全体で一致）が切替の前提条件。

**全体の形**: `src/Litedoc4/` に Lean 製品ツリーを新設し、Rust の crate 境界をそのまま
モジュール境界に写す（`Ir` / `Md` / `Render` / `Global` / `Incr` / `Cli`）。
写像を保つのは対応を追えるようにするためで、Lean らしい設計への作り替えは
**一致を取り終えてからにする**（同時にやると、差が実装の写し間違いなのか設計変更の
帰結なのか分離できない）。

## マイルストーン

各 M は **「Rust と何が一致したか」で完了する**。「書けた」では完了しない。

### M1 骨格 — `lean_exe litedoc4` が消費者からビルドでき、走る
- `src/Litedoc4/` を作り、root `lakefile.lean` に `lean_lib Litedoc4` + `lean_exe litedoc4` を足す
- vendor md4c + `csrc/` + libc shim をプロトタイプから製品ツリーへ（`getLeanCc` 経路ごと）
- `cd e2e/consumer && lake build litedoc4` が通る
- **完了判定**: `litedoc4 --version` が Rust 版と同じ文字列を出す。`tools/purelean-gate.sh` が
  ビルドと起動を確認する（**先に落として**から通す）

### M2 render — IR から Rust と同一の HTML
- プロトタイプの `Md.lean` / `Render.lean` を製品ツリーへ移し、エラー処理・設定・
  外部リンク・依存 docs を入れる
- **完了判定**: e2e/micro の IR から出したページが Rust の `pages/` とバイト一致

### M3 site — `litedoc4 site` が e2e/micro の 20 ファイルを出す

**M3 と M4 の境界は 2026-08-31 に実測で引き直した**（→
`benchmarks/results/purelean-micro-2026-08-31.txt` の追記節）。サイトの中身は:

| | | |
|---|---|---|
| モジュールページ 11 | `render_site` | **M2 で完了、バイト一致済み** |
| アセット 3 | `assets.rs` の `ASSETS` — `style.css` / `app.js` / `favicon.svg`。全部 `include_str!` のテキストで合計 45,229 B | 未着手 |
| アーティファクト 9 | `litedoc4-global` の `ARTIFACT_PATHS` — `index.html` / `404.html` / `search.html` / `foundational_types.html` / `modules.json` / `search-index.bin` / `instances.json` / `declarations/name-map.json` / `declarations/used-by.json` | 未着手 |

合計 23 ファイル / 215,116 B。**ランディングページ 4 枚は `render` ではなく `global` が書く**ので、
`global` 抜きにサイトは成立しない。よって**旧 M4（global）は M3 に畳む**。
`declaration-data.bmp` は書かれない（doc-gen4 のための 5 ファイルは意図的に落としてあり、
`artifacts.rs` のテストが復活を落とす）。`.lidx` は extractor が書くので Lean 側は既に持っている。

**アセット 3 つは M3 ではなく M4**（2026-08-31 に実測で引き直した →
`benchmarks/results/purelean-site-boundary-2026-08-31.txt`）。`write_assets` は
`build` の持ち物で、`litedoc4 site` は呼ばない — Rust の `site` が書くのは
**ページ 11 + アーティファクト 9 = 20 ファイル**（実測）。`site` は `render` と `global` の
合成でありそれ以外ではない、というのが `crates/litedoc4/tests/site.rs` が固定している不変量で、
Lean 側に assets を足すとその不変量ごと比較が崩れる。

その帰結として **`site-gate` も M4**（実測）: bare な `site` の木に対して
`check-dead-links.py` は `style.css` / `favicon.svg` を DEAD と数えて落ちる
（30 dead / 2 distinct / 15 pages）。`check-site-closure.py` の方は**緑**で、
これが M3 が判定に使うべき半分 — `global` のアーティファクトと `render` のページが
互いに整合するかを両方向に見る検査だから。

- **完了判定**: `litedoc4 site --ir … --out … --link-index …` の出力が Rust 版と
  **20/20 バイト一致**し、`benchmarks/tools/check-site-closure.py` と `usedby-gate` が
  Lean 実装のサイトで緑

**2026-08-31 に達成**。判定器は `tools/purelean-micro-gate.sh` の項目 6/7/8
（tree / summary / closure。**3 つとも個別に落としてから通した**）。

M3 で分かって**閉じていない**もの、次に触る人向け:

1. **`search-index.bin` のエンコーダは Rust が assert する所で黙って切り詰める**。
   kind 数 > 255 / モジュール数 > 65535 / 名前 > 64 KiB は Rust では `assert!`、
   Lean では `Nat.toUInt8` / `toUInt16` が巻き込む。実在のパッケージでは届かない
   （Mathlib 全体で 8,169 モジュール）が、**診断ではなく黙った切り詰め**なので M7 の
   診断メッセージと一緒に片付ける
2. **`name-map.json` の依存名の側を closure 検査は見ていない**（実測 2026-08-31 —
   末尾 1 件を落としても項目 8 は緑のまま、項目 6 だけが落ちた）。
   いまは Rust オラクルが捕まえるが、**M9 でオラクルが消えると誰も見なくなる**
3. **`Lower.lean` の 2 つの表に生成器が無い**。`gc.rs` / `v8_gc.rs` には `--check`
   付きの生成器が委譲されている（`src/Litedoc4/Md/Gc.lean` には無く、前例はある）。
   表は Rust std の答えを全コードポイント総当たりで突き合わせて作られている（実測）が、
   **再生成の手段がリポジトリに無い**
4. **Lean の `nameToLink` に `module_for_unescaped` の分岐が無い**
   （→ `benchmarks/results/purelean-guillemet-2026-08-31.txt`）。`--root` で露出する

### M4 build — `site` の周りのパイプライン
- **アセット 3 つ**（`style.css` 29,499 / `app.js` 15,370 / `favicon.svg` 360 = 45,229 B）を
  Lean バイナリに載せ、`build` が書く。Rust では `include_str!`；Lean 側の手段は**未計測**で、
  文字列リテラルで足りるかまず 1 ファイルで確かめる。`app.js` は `build.rs` が vite で作るので
  リポジトリに置いたビルド済み JS を読む（計画の「TypeScript は移植対象外」）。置き場所は M4 で決める
- `--lib` 解決と modules 列挙（`lake` を subprocess で起動する）/ `litedoc4.toml` /
  external links（`lake-manifest.json`）/ extractor 起動 / ledger / `litedoc4-build.json`
- **完了判定**: `litedoc4 build --root e2e/micro` の出力が Rust 版と **23/23 バイト一致**し、
  `site-gate` と `config-gate` が Lean 実装で緑

### M5 incremental — ledger / impact / ownership / merge / mode
- プロトタイプの `Incr.lean` が土台。**bimodal な `ownership`（423 読み vs 2 読み）を保つ**
- `onemod-gate.sh` は**ここ**（旧 M3 から移した）。引数が
  `<litedoc4-build.json> <serve.out>` で、1 モジュール編集後の
  `modulesExtracted` / `pagesRendered` を見るゲートなので、測っている対象は incremental
- **完了判定**: `incremental-compare.sh` / `impact-compare.sh` / `merge-compare.sh` /
  `ledger-compare.sh` / `onemod-gate.sh` が Lean 実装で緑

### M6 watch と HTTP サーバ（`Std.Async.TCP`）
- **完了判定**: `watch-gate.sh` が Lean 実装で緑

### M7 残り — CLI 全フラグ / 設定 / 診断メッセージ / deps-docs / packages / resident
- **完了判定**: `tools/public-surface.txt` の全名が Lean 実装に存在し、
  `public-surface-gate.sh` が Lean 側を見て緑

### M8 対象リポジトリ全体で一致
- **完了判定**: 432 モジュールで **422/422 バイト一致**、
  `build-gate.sh` / `corpus-gate.sh` / `lean-versions-gate.sh` が Lean 実装で緑

### M9 切替 — 配布モデルを変える（**ここから不可逆**）
- `action.yml` の binary 解決を廃止 / `lakefile.lean` の `resolveLitedoc4` 250 行削除 /
  `release.yml` 削除 / `lake-download-gate.sh`・`release-notes-gate.sh` 廃止 /
  `public-surface.txt` の更新（`binary-source` の去就）/ ビルド済み JS をリポジトリへ
- 2 つのライブサイト（`litedoc4` と `information-theory`）を新経路で再デプロイして確認
- **完了判定**: `e2e/consumer` が `require` だけでサイトを出す。C コンパイラも Rust も node も要らない

### M10 Rust 削除
- `crates/` を HEAD から削除、`rust-frozen` タグで凍結（`experiments-frozen` の前例）
- この計画ファイルを削除
- **完了判定**: `cargo` を名指しするワークフローが 0 本

## この計画が壊れる条件

- **M2 で e2e/micro のページが一致しない** → プロトタイプは対象リポジトリでしか
  突き合わせていない。e2e/micro は「対象が持たない宣言形状」を持つので、
  **ここで初めて出る差がある**。差が出たら M2 を分割する
- **`Std.Async.TCP` が watch の要求を満たさない**（M6）→ 満たさなければ配布モデルの
  決定に戻る（HTTP サーバだけ別手段、は `require` のみを壊す）
- **ビルド時間が消費者に受け入れられない** → 計測では extractor 11.65–16.82 s に対し
  1,612 行で 9.25 s。製品は 1 桁大きい。M3 の時点で消費者ワークスペースでの
  ビルド時間を計測し、記録する

## 各 leg の作法

- **既存ゲートを壊さない**。M9 まで Rust 実装と Rust のゲートは緑のまま
- **新しいゲートは必ず一度落としてから通す**（CLAUDE.md）
- **`cargo test --workspace` を判断に使い続ける**。「速い 5 段」で代用しない（前科あり）
- **Rust 側が帰属表示を持つファイルを Lean に転写したら、同じ表示を運ぶ**。
  `tools/provenance-files.txt` に行を足し、`docs/provenance.md` の表にも書く。
  転写は二次の派生であって免除ではない。**照合語は固有名詞にする**（`Jz Pan` /
  `Böving`）— `MD4Lean` や `doc-gen4` は本文中に何度も出るので、その語を探す検査は
  違う文で満たされてしまう。M2 で `Render.lean` を割るときは、ファイル単位で
  安全側に倒してある告知を passage 単位に落とし直す
- 各 leg は最低 1 commit。成果が無ければ台帳に理由を書く
