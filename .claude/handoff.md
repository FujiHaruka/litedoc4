# Handoff — 2026-08-31 (relay leg 3 → leg 4)

## State

**M3 完了。** `litedoc4 site` が Rust と **20/20 バイト一致**し、closure と used-by が
Lean のサイトで緑。計画は `.claude/purelean-plan.md`（このリレーの SoT）。

- litedoc4: main `8b038b0`、clean、push 済み
- `cargo test --workspace` 緑（46 バイナリ、exit 0）
- `tools/purelean-micro-gate.sh` **8/8 緑**。CI（`lake package (self-test)`）の
  `purelean-micro` ジョブも `ab32c35` で **8/8 緑**、同じ 20 ファイル / 151,828 バイト
  （x86_64 Linux。サイトのバイトはこの機械の性質ではない）
- `tools/docs-gate.sh` 207 引用すべて解決 / `tools/provenance-gate.sh` 56 claims 緑 /
  `tools/workflow-gate.sh` 緑

| | |
|---|---|
| `litedoc4 site` の 20 ファイル | Rust とバイト一致（ページ 11 + アーティファクト 9） |
| 合成 IR（`«Odd-Name»`）の 20 ファイル | 同じくバイト一致 |
| Lean 側 cold build | 3,887 行 26 モジュールで **6.2 s に収束** |

## What was done in leg 3（5 commits）

**M3 の境界を実測で引き直した**（`d91c3d9`）。`litedoc4 site` が書くのは **20 ファイル**で
23 ではない — `write_assets` は `build` からしか呼ばれず、
`crates/litedoc4/tests/site.rs` が「`site` は `render` と `global` の合成でありそれ以外では
ない」を不変量として固定している。bare な `site` の木は `site-gate` の dead-link 側が
必ず落ちる（`style.css` / `favicon.svg`）が **closure 側は全項目緑**なので、M3 の判定は
closure + used-by にした（→ `benchmarks/results/purelean-site-boundary-2026-08-31.txt`）。

**`litedoc4-global` を Lean に転写**（`53d4f51` / `8f641ce` / `ab32c35`）。
`cmpUtf16` / JSON writer / `Facts` / `Artifacts` / `Entry`（landing page 4 枚）/
`SearchIndex` / `Lower`（`str::to_lowercase`）、そして `site` サブコマンド。

**ゲートを 5 → 8 項目に**（`ab32c35`）。6 = `site` の木（`render-compare.sh --all` を新設。
JSON 4 つとバイナリ 1 つを見ないと「ページは同じで検索インデックスが違う」を見逃す）/
7 = `site` の要約 / 8 = closure + used-by。**3 つとも個別に落としてから通した**。

**帰属表示を払った**（`ab32c35`）。`src/Litedoc4/Lower.lean` は Rust std の
`str::to_lowercase` の答えを総当たりした表なので、`NOTICE` に節を足し、
`docs/provenance.md` §7 に行と理由を足し、`tools/provenance-files.txt` に 3 行足した。
**新しい行が本当に検査されていることを、1 行を存在しない文字列に変えて確認した**。

**消費者のビルド時間を計測した**（`8b038b0`、計画が M3 に課していた項目）。

## 見つかったことで、記録しておく価値のあるもの

1. **M2 のレンダラに乖離が残っていた（塞いだ）。** Rust は名前の分割器を **2 つ**持ち、
   呼び出し箇所ごとに使い分ける — `module_components`（`«…»` の内側では割らず剥がす。
   `page_path` / `module_link` / `page_root` / `module_source_url` / サイトタイトル）と
   素の `split('.')`（`cmp_name` / tail match / `echoes_the_name`）。Lean は 1 つしか
   持っていなかった。**対象 432 モジュールにも e2e/micro の 11 にも `«…»` の
   モジュール名が無いので両コーパスが素通ししていた**。合成 IR で発火させると
   塞ぐ前は 3 つの出力がずれる（→ `benchmarks/results/purelean-guillemet-2026-08-31.txt`）。
   **一般形**: 「1 つに寄せる」は、Rust 側が意図して 2 つ持っている所では退行になる。
   転写のとき、対応する Rust 関数を呼び出し箇所ごとに引き当てること
2. **項目 8 は最初 `site_ok` で守られていて、独立に落ちられない形だった。**
   6 が緑のときだけ走るなら、それは Rust のサイトの整合性を言い直すだけで自分では
   落ちない。ガードを外して初めて落ちた（宣言を 1 つ落として
   `pages -> search-index: 56 checked, 1 failed`）。**新項目は「落とせるか」を
   1 つずつ確かめる** — 3 つまとめて落ちたのは 1 つが落ちたのと同じ情報しかない
3. **`name-map.json` の依存名の側は closure 検査が見ていない**（実測）。末尾 1 件を
   落としても項目 8 は緑のまま、項目 6 だけが落ちた。**M9 でオラクルが消えると
   誰も見なくなる**
4. **subagent の報告は今回も 1 件だけ実物と食い違った** — 「`components` を
   `module_components` に寄せればよい」という報告。実際は上の 1 のとおり 2 つ要る。
   報告の「未計測」「未実装」の申告自体は正確だった

## Files to read first

1. `.claude/purelean-plan.md` — M3 は達成として書き直し、**閉じていない 4 件**も
   そこに書いてある。まずここ
2. `tools/purelean-micro-gate.sh` — leg 4 の採点器。項目 6/7/8 の形をそのまま伸ばす
3. `crates/litedoc4/src/build.rs`（1,378 行）— M4 の仕様
4. `crates/litedoc4-render/src/assets.rs` / `crates/litedoc4-render/build.rs` — assets の
   現状。**`build.rs` は「checked-in bundle への fallback は意図的に無い」と書いてある**
5. `crates/litedoc4/src/{lakefile,packages,extract,ledger}.rs` — `--lib` / external links /
   extractor 起動 / ledger

## Next step — M4 build

**完了判定は `litedoc4 build --root e2e/micro` の 23/23 バイト一致 + `site-gate` と
`config-gate` が Lean のサイトで緑。**

leg 3 で決めた M4 の判断（leg 4 はここから始めてよい。ただし**まず 1 ファイルで
計測**してから）:

1. **`assets/` をリポジトリ直下に作り、3 つの正本をそこに置く。**
   `style.css` と `favicon.svg` は `crates/litedoc4-render/assets/` から**移す**
   （Rust の `include_str!` を張り替える。`tools/provenance-files.txt` の
   `crates/litedoc4-render/assets/style.css` の 2 行も追随させること）。
   `app.js` は**リポジトリに新規に置く** — vite の出力を commit する。
   Lean 側に vite は持ち込まない（計画の「TypeScript は移植対象外」）
2. **`src/Litedoc4/Assets.lean` は生成物**。`assets/` の 3 ファイルを Lean の
   文字列リテラルとして持つ。**29 KB のリテラルが通るかは未計測 — まず
   `style.css` 1 つで確かめる**。通らなければ代案を発明する前に報告すること。
   エスケープは `\` と `"`（minify 済み JS は両方大量に含む）
3. **生成器は `--check` を持ち、新しいゲート `tools/assets-embed-gate.sh` が
   (a) vite の出力と `assets/app.js` の一致 (b) 生成器の `--check` を見る。**
   `tools/gates.txt` に行を足し、ワークフローから届かせる。
   **これは `crates/litedoc4-render/build.rs` の「fallback は 2 つの答えを作るので
   取らない」に正面から向き合う場所** — M4〜M8 のあいだ答えは実際に 2 つある
   （Rust は vite、Lean は commit 済み）ので、**一致を見る場所を 1 か所に名前付きで
   作る**。M9 で vite の側が消えて答えは 1 つに戻る
4. `writeAssets` は Rust と同じく **`build` だけが呼ぶ**（`site` は呼ばない）

やる順に: (1) assets（上の 1〜3。**ここが唯一の未計測**）→ (2) `litedoc4.toml` と
`--root` → (3) `--lib` 解決と modules 列挙（`lake` を subprocess で起動）→
(4) external links（`lake-manifest.json`）→ (5) extractor 起動 → (6) ledger と
`litedoc4-build.json` → (7) micro ゲートに `build` の 23 ファイル比較と `site-gate` /
`config-gate`（**先に一度落とす。1 項目ずつ**）。

**作法**（計画の「各 leg の作法」に加えて）: Rust 側が帰属表示を持つファイルを
転写・移動したら `tools/provenance-files.txt` と `docs/provenance.md` を追随させる。
照合語は固有名詞にする。

## 環境の注意

- **disk の空きが 9.1 GiB**（228 GiB 中 160 GiB 使用、95%）。対象リポジトリの計測を
  回す前に `df -h` を見ること
- `/private/tmp/lean-doc-relay/purelean`（398 MB）は**対象の IR と .lidx で、
  `purelean-render-gate.sh` が要る**。消さないこと
- `/private/tmp/lean-doc-relay/purelean-m3` に **leg 3 のオラクルが残っている**:
  `build/`（IR + link index + Rust の 23 ファイルのサイト）/ `site-only/`（Rust の
  `site` 20 ファイル）/ `ir-guillemet` と `g-rust`（`«Odd-Name»` の合成 IR とその
  Rust 出力）。**M4 の突き合わせにそのまま使える**
- e2e/micro の extractor は `e2e/micro/.lake/e2e-extract/extract` にある。
  ビルド判断は `tools/lib/common.sh` の `micro_extractor` 1 か所に集約済み
- **Lean のビルドは `cd e2e/consumer && ~/.elan/bin/lake build litedoc4/litedoc4`**、
  バイナリは `.lake/build/bin/litedoc4`

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 4 / cap 40
- Predecessor: purelean-r3
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: 計画 + 4 判断 (1c3d7ce) / M1 骨格 (8294e56) / 帰属表示 (129ea01) /
    M2 レンダラ移設・分割 422/422 (bd505f4) / docs-gate の穴 184→199 (3ee806d) /
    MathML4Lean v0.1.1 + pin (542303e)
  - r2: **M2 完了**。IR 読み込みを index.json 起点へ (b715912) / extractor ビルドを 1 か所へ
    (d47f9c1) / 不在の名前でレンダを止める (b0e16f7) / math フォールバックを要約に
    (6a7084a) / CI ゲート purelean-micro 5 項目 + render ゲート項目 6 (91f0c11) /
    Linux CI も同バイト (b765a2c) / M3-M4 境界を実測で引き直し (5dc900c)
  - r3: **M3 完了**。M3 の境界を実測で再確定 20 ファイル (d91c3d9) / global の JSON 4 種 +
    名前分割器の乖離を塞ぐ (53d4f51) / landing page 4 枚 (8f641ce) /
    search-index.bin + ゲート 5→8 項目 + 帰属表示 (ab32c35) /
    消費者ビルド時間 6.2 s (8b038b0)。CI も 8/8 緑
