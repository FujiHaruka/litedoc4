# Handoff — 2026-08-31 (relay leg 2 → leg 3)

## State

**M2 完了。** Lean の `render` と Rust の `render` が **両コーパスでバイト一致**し、
拒否も要約も一致する。計画は `.claude/purelean-plan.md`（このリレーの SoT）。

- litedoc4: main `5dc900c`、clean、push 済み。CI（`CI` / `lake package (self-test)` 6 ジョブ）緑
- `cargo test --workspace` 緑

| | |
|---|---|
| e2e/micro `--link-index` | 11/11、129,450 B |
| e2e/micro `--no-link-index` | 両者 exit 1・7 ページ後・stderr 121 B 一致 |
| 要約 3 行 | 一致（`math spans kept as LaTeX 1`） |
| 対象 422 モジュール | `purelean-render-gate` 6/6、24,546,639 / 24,547,048 B |
| Linux x86_64 CI | 同じ 129,450 B（バイトはこの機械の性質ではない） |

## What was done in leg 2（7 commits）

**新しい CI ゲート `tools/purelean-micro-gate.sh`**（5 項目、`ci-lake.yml` の
`purelean-micro` ジョブ）。**先に一度落として**から通した。
`purelean-render-gate.sh` にも要約比較の項目 6 を足した（同じく一度落として確認）。

**閉じた欠陥 3 件。どれも対象リポジトリの 422 ページでは緑だった**:

1. **IR をディレクトリ列挙で読んでいた**。`index.json` の `modules` / `dependencyMaps`
   配列ではなく `modules/*.json` のソート。載っていない `Stray.json` が 12 ページ目になり、
   `ablations` / schema 4 / モジュール名不一致を全部受理していた。今は 4 つの拒否メッセージが
   `crates/litedoc4-ir/src/error.rs` と**逐語一致**
2. **どのモジュールも知らない名前でレンダを止めていなかった**。`Ok(None)`（既知だがページが無い
   → リンク無しで描く）と `Err`（どのマップも知らない → 止まる）を 1 つに潰していた
3. **沈黙するフォールバックを報告していなかった**（`math spans kept as LaTeX`）。
   **対象では検出できない** — 対象の count は 422 ページで 0、サンプルは意図的な `\colim` の 1

**M3/M4 の境界を実測で引き直した**（下記）。

## 見つかったことで、記録しておく価値のあるもの

1. **subagent の調査報告は額面で受け取ってはいけない。** M3 の地図を作らせた報告の §1 と §5 が
   **実物と食い違っていた** — 「41 ファイル / 6.4 MB」「`app.js` 1,935,414 B」
   「`declaration-data.bmp` が 2 か所に重複」。実際は **23 ファイル / 215,116 B**、
   `app.js` は 15,370 B、`declaration-data.bmp` は**どこにも書かれない**
   （`artifacts.rs` の `the_doc_gen4_only_artifacts_are_gone` が復活を落とす）。
   バイナリを 1 回走らせれば分かることで、**「走らせた」と書いてあっても確かめる**
2. **ページだけ比べるゲートは、嘘をつく要約を見られない。** 欠陥 3 は 422/422 一致のまま
   通り抜けていた。これが `purelean-render-gate.sh` の項目 6 を足した理由
3. **`FilePath./` は区切りを二重にする**（`Path::join` はしない）。`--ir …/tree/` で Lean の拒否が
   `tree//modules/X.json` と言い、Rust は `tree/modules/X.json` と言った（計測）。
   `Ir.lean` の `irPath` で塞いだが、**ユーザーに見えるパスを `/` で組む他の箇所は同じ穴**
4. **Lean の `IO` エラーと JSON 失敗は Rust に合わせられない**（計測）。
   `No such file or directory (os error 2)` に対し
   `no such file or directory (error code: 4294967294)`（errno ではなく −2 の `UInt32`）。
   `src/Litedoc4/Json.lean` は不正 JSON で `panic!` する。
   **stderr を比べるゲートに、存在しないファイルや壊れた JSON を食わせてはいけない**

## M3 の実測（`benchmarks/results/purelean-micro-2026-08-31.txt` 末尾）

サイトは **23 ファイル / 215,116 B**、所有者は 3 つに分かれる:

| | ファイル | バイト | 書くのは |
|---|---|---|---|
| モジュールページ | 11 | 146,728 | `litedoc4-render::site`（**M2 完了**） |
| アセット | 3 | 45,229 | `litedoc4-render::assets` の `ASSETS`。`style.css` / `app.js` / `favicon.svg`、全部 `include_str!` の**テキスト** |
| アーティファクト | 9 | 23,159 | `litedoc4-global` の `ARTIFACT_PATHS` |

**ランディングページ 4 枚（`index.html` / `404.html` / `search.html` /
`foundational_types.html`）は `render` ではなく `global` が書く。** だから `global` 抜きに
サイトは成立せず、旧 M4 を M3 に畳んだ。`onemod-gate.sh` は incremental を測るゲート
（引数が `<litedoc4-build.json> <serve.out>`）なので M5 に移した。

**146,728 B は 129,450 B と並べてはいけない** — こちらは `--root` 付きで依存へのリンクが
外部 URL に解決される分だけ長い。同じレンダラの違う設定。

## Files to read first

1. `.claude/purelean-plan.md` — M3 は書き直してある。まずここ
2. `tools/purelean-micro-gate.sh` — leg 3 の採点器。**`site` の比較もここに足すのが素直**
   （新しい比較の形を発明しない。両バイナリを 1 セッションで走らせる形は既にある）
3. `crates/litedoc4-global/src/artifacts.rs` — 9 アーティファクトの中身と
   **UTF-16 順**（`cmp_utf16`。UTF-8 バイト順と U+10000 で逆転する）
4. `crates/litedoc4-render/src/assets.rs` — `ASSETS` 3 つと `write_assets` の冪等性
5. `crates/litedoc4/src/site.rs` — `litedoc4 site` の引数と段取り

## Next step — M3

**完了判定は `litedoc4 site` の 23/23 バイト一致 + `site-gate` / `usedby-gate` が Lean のサイトで緑。**

やる順に:

1. **アセット 3 つを Lean バイナリに載せる**。45 KB のテキストなので Rust の `include_str!` の
   置き換えは Lean の文字列リテラルで足りる見込み（**未計測 — まず 1 ファイルで確かめる**）。
   `csrc/` の C 配列 + FFI という既存機構もあるが、45 KB のテキストにそれを使う理由は
   今のところ無い。`app.js` は `build.rs` が vite で作るので、**リポジトリに置いたビルド済み JS を
   読む**（計画の「TypeScript は移植対象外」）。どこに置くかは決めること
2. **`litedoc4-global` を転写**。9 アーティファクト。UTF-16 順が全体に効いている
3. **`litedoc4 site` サブコマンド**を足し、micro ゲートに `site` の 23 ファイル比較を足す
   （**先に一度落とす**）
4. `site-gate.sh` / `usedby-gate.sh` を Lean のサイトに当てる

**作法**（計画の「各 leg の作法」に加えて）: Rust 側が帰属表示を持つファイルを転写したら
`tools/provenance-files.txt` と `docs/provenance.md` に行を足す。照合語は固有名詞。

## 環境の注意

- **disk の空きが 10 GiB**（228 GiB 中 160 GiB 使用、95%）。リポジトリ側の寄与は 3.5 GB で
  主因ではないが、対象リポジトリの計測を回す前に `df -h` を見ること。
  過去にディスクが埋まって**対象リポジトリの olean が欠けた**事故がある
- `/private/tmp/lean-doc-relay/purelean`（398 MB）は**対象の IR と .lidx で、
  `purelean-render-gate.sh` が要る**。消さないこと
- e2e/micro の extractor は `e2e/micro/.lake/e2e-extract/extract` に既にある。
  ビルド判断は `tools/lib/common.sh` の `micro_extractor` 1 か所に集約済み

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 3 / cap 40
- Predecessor: purelean-r2
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: 計画 + 4 判断 (1c3d7ce) / M1 骨格 (8294e56) / 帰属表示 (129ea01) /
    M2 レンダラ移設・分割 422/422 (bd505f4) / docs-gate の穴 184→199 (3ee806d) /
    MathML4Lean v0.1.1 + pin (542303e)
  - r2: **M2 完了**。IR 読み込みを index.json 起点へ (b715912) / extractor ビルドを 1 か所へ
    (d47f9c1) / 不在の名前でレンダを止める (b0e16f7) / math フォールバックを要約に
    (6a7084a) / CI ゲート purelean-micro 5 項目 + render ゲート項目 6 (91f0c11) /
    Linux CI も同バイト (b765a2c) / M3-M4 境界を実測で引き直し (5dc900c)
