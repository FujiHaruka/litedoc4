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

**アセットは 2026-08-31 に済んだ**（`c47ee15`）。未計測だった 1 点は潰れた —
**Lean の文字列リテラルは 29 KB を運ぶ**（→
`benchmarks/results/purelean-assets-literal-2026-08-31.txt`）。4 ファイル 45,397 B が
バイト一致で往復し、モジュール単体の再ビルドは 0.47–0.50 s。**エスケープは `\` と `"` の
2 つで足りる**（CR も、`\n` `\t` 以外の制御文字も無い）。生成器は**見つけたものを
エスケープするのではなく、想定外の制御文字を見つけたら止まる** — Lean の `\x` / `\u` は
未計測で、間違ったエンコードは「CSS が微妙に CSS でないサイト」になるから。

**アセットは 3 つではなく 4 つだった**（実測）。`theme-boot.js` は vite の 4 つ目の出力で、
`frame.rs` が**ファイルに書かず全ページの `<head>` にインライン**する。Lean 側は M2 以来
`Frame.lean` に**手写しのリテラル**を持っていて、**誰も vite の出力と突き合わせていなかった**
（今日まで一致していた。だから黙って古くなる形だった）。今は `Assets.lean` の生成値を参照する。

正本は**リポジトリ直下の `assets/`** で、鎖は 3 リンク・各リンクを 1 か所だけが見る:

| リンク | 見る場所 | なぜそこか |
|---|---|---|
| vite → `assets/` | `assets.rs` の `the_committed_bundles_match_what_build_rs_bundled`（**テスト**） | `build.rs` がその時点で既に vite を走らせている。追加コストが無く、`cargo test --workspace` が毎回見る。**M9 で vite ごと去る**のが正しい |
| `assets/` → `Assets.lean` | `tools/assets-embed-gate.sh` 項目 2（`gen-assets.py --check`） | 木を読むだけ。node も toolchain も要らない |
| `assets/` → `assets.rs` | 同 項目 3 | 「正本が 2 つに割れた」を数で見る。**存在ではなく回数**を数える（2 つ目の `include_str!` は存在検査を素通りする） |

計画は当初これを 1 つのゲートに畳む形で書いていたが、vite の側をゲートにすると
**vite が 2 回走り、しかも M9 で消える検査が M9 まで残る**。3 項目とも個別に落としてから通した。

- **完了判定**: `litedoc4 build --root e2e/micro` の出力が Rust 版と **23/23 バイト一致**し、
  `site-gate` と `config-gate` が Lean 実装で緑

**2026-08-31 に達成。** 判定器は `tools/purelean-micro-gate.sh` の項目 10〜13
（build の 23 ファイル / site-gate / config-gate / marker。**4 つとも個別に落としてから通した**）。
サイトの外も一致する: `ledger.json` / `link-index.lidx`(+`.key`) / `work/modules.txt` /
`ir/` の木すべて、そして **`litedoc4-build.json` は `work.irReads` を含めてバイト一致**
（`{index:3, module:22, depMap:4, total:29}`。**Lean のリーダは Rust と同じ回数 IR を開く**ので、
未検証だった項目 13 の除外は要らなかった）。

#### 実測で分かった 3 つの訂正（2026-08-31。leg 3 の handoff は 3 つとも間違っていた）

1. **modules 列挙で `lake` は起動されない。** 実体は**ファイルシステムの glob**
   （`pipeline::module_names`）と**手書きの `lakefile.toml` 行認識器**（`lakefile.rs`。
   説明できない行はすべて exit 3）。`build` が起こすプロセスは `git` ×4 /
   `lean --githash` ×1 / `lake env <extractor> … --serve` ×1 の**計 6 つだけ**
2. **`build` は `--source-url .../blob/HEAD/...` を exit 2 で拒否する。**
   `check_source_url` が `/blob/` の後に **40 桁小文字 hex** を要求する
   （`render` と `site` は要求しない）。**M4 のゲート項目は両方のバイナリに
   40-hex の同一文字列を渡すこと**
3. **URL を git から導出させるのはリレーでは罠。** 調査中に HEAD が動き
   （並行 commit）、11 ページ全部が変わった。**ゲートは固定値を渡す**

#### 移植の単位と順序（Rust の該当箇所つき）

**バイトを動かすものが先**。1〜4 は `--root` をレンダラに通す塊で、
`site --root e2e/micro` が Rust と 20/20 一致すれば閉じる（`build` を書く前に検証できる）。

| # | 単位 | Rust | 備考 |
|---|---|---|---|
| 1 | `SiteConfig`（`title` / `index` の 2 キー） | `litedoc4-render/src/config.rs` | 未知キーは硬いエラー。**`renderSite` と `buildGlobal` の両方**が title を要る |
| 2 | `ExternalLinks` 型（`baseFor` / `urlFor` / `iter`） | `litedoc4-render/src/external.rs` | 純データ |
| 3 | `packages::externalLinks`（manifest 読み + root scan + `lean --githash`） | `litedoc4/src/packages.rs` | **すべて degrade する。例外を投げない**。core 4 件は `Init`/`Lean`/`Std` が `…/src`、**`Lake` だけ `…/src/lake`** |
| 4 | `linkTo` の問い 1 と 2 | `litedoc4-render/src/autolink.rs:361` | **ここが 11/11 ページを動かす**。問い 0（deps-docs）は e2e/micro に届かないので範囲外 |
| 5 | `escapeModule` / `needsNoEscape` | `litedoc4-ir/src/name.rs:55-102` | 6 が要る。`«Odd-Name»` の合成 IR が判定器 |
| 6 | `moduleNames`（ソースの glob） | `litedoc4/src/pipeline.rs:1401` | 順序は `read_dir` 順 → `sortUtf16` → dedup。**この 1 本のリストが ledger / extractor / omit すべてに渡る**ので段ごとに derive し直さない |
| 7 | `lakefile.toml` の `[[lean_lib]]` 認識器 | `litedoc4/src/lakefile.rs` | `--lib` を必須にすれば後回しにできるが、`e2e/consumer` の Lake script は導出側を使う |
| 8 | `deriveSourceUrl` / `checkSourceUrl` | `build.rs:1101` / `pipeline.rs:1211` | `git` 4 本。remote は github の 4 綴りだけ |
| 9 | `writeAssets` | `litedoc4-render/src/assets.rs:53` | `Litedoc4.assets` は済。20 → 23 ファイル |
| 10 | `Layout` / `planOf`（所有検査 1〜3 + 常に full）/ marker の読み書き | `build.rs:82-141, 955-1039, 1235` | marker は compact JSON + 末尾 `\n`、キー順固定、**タイムスタンプ無し** |
| 11 | ledger（`extractKey` / `renderKey` / `linkIndexDigest` / `buildLedger`） | `litedoc4-incr/src/ledger.rs` | sha256 が要る。**hash は抽出の前、書き出しは描画の後** |
| 12 | resident extractor ドライバ（spawn / `ready`・request・`ok` / `linkIndexKey`） | `litedoc4/src/resident.rs` | argv は仕様。`Generation` は M5 に送れるが**送るなら明示する** |
| 13 | `build` の組み立てと CLI と stdout の行 | `build.rs:148-654` | 最後 |

`fold_timings`（events JSONL → `extract-timings-<n>.json`）は **23 ファイルには不要**。

#### 単位 1〜4 は 2026-08-31 に済んだ（レンダラが `--root` を取る）

`render` と `site` が `--root` / `--lake` を取り、`litedoc4.toml`・`ExternalLinks`・
`linkTo` の問い 1・2 が入った。**4 通りすべて Rust とバイト一致 + stdout 一致**（実測）:

| | Lean vs Rust |
|---|---|
| `render` `--root` 無し | 11 ページ 131,862 B 一致 |
| `render --root e2e/micro` | 11 ページ **146,728 B** 一致（`--root` で +14,866 B、ページごと +137〜+3,945） |
| `site` `--root` 無し | 20 ファイル 154,240 B 一致 |
| `site --root e2e/micro` | 20 ファイル **169,887 B** 一致 |

**比較は空虚でない** — `--root` は 11/11 ページと 20 中 15 ファイルを動かす
（5 つの JSON/バイナリは title もリンクも運ばないので不変）。

ゲート側も強くした: 項目 5/7 は stdout の**先頭を切り落として**比べていた
（Lean が `external` ブロックを出せなかったから）。その理由が消えたので切り落としをやめ、
**stdout 全体**を比べる（3/7 行 → 4/8 行）。落としてから通した。

#### 単位 1〜4 で分かって、閉じていないもの

1. **`Json.lean` の `panic!` は止まらない。** `pArr` / `pObj` は説明できない入力で
   `panic!` を呼ぶが、Lean の `panic!` は既定値を返して**続行する**。
   壊れた IR 4 通り（index.json の切り詰め / モジュールファイルの切り詰め ×2 /
   閉じない配列）で **exit code もページ数も Rust と一致した**（実測 2026-08-31、
   どちらも rc=1・0 ページ）が、**一致は「panic のあとの空の値がたまたま後段の検証を
   落とす」ことに依存している**。落とさない壊れ方は探していない。
   Rust は `EOF while parsing a string at line 1 column 200` と言い、Lean は
   `PANIC at Litedoc4.JScan.pObj … backtrace:` を出す。**入口が増えたのは今日**で、
   `lake-manifest.json` は**ユーザーが書くファイル**（IR は extractor が書く）。
   直すなら `Json.lean` に `Except` を通す 10 関数の書き換えで、M7 の診断と一緒が安い
2. **エラーの文言は Rust と違う**（判定と exit code は一致）。OS エラーとパーサの
   メッセージを引用する場所すべて。**何もゲートしていない** → M7
3. **`litedoc4.toml` の読み手は Rust より狭い。** TOML のリテラル文字列（`title = 'x'`）と
   複数行文字列を Lean は拒否し、Rust（`basic_toml`）は受け入れる。**拒否は安全側**だが
   差であり、そう綴ったパッケージは壊れる。どのゲートも通っていない
4. **`--root` は 422 モジュールでは未検証。** `purelean-render-gate.sh` は `--root` を
   渡さないので、対象規模で確かめたのは `--root` 無しの経路だけ

#### 単位 12 の未計測も潰れた — Lean は resident extractor を駆動できる

2026-08-31 実測（→ `benchmarks/results/purelean-serve-probe-2026-08-31.txt`）。
core だけを import した Lean のドライバが `lake env <extractor> … --serve` を spawn し、
`ready` 行を読み、リクエスト行を書き、`ok 0 <ns>` を受け、子は exit 0 で終わった。
**書かれた IR は Rust が駆動したものとバイト一致**（2 モジュールで確認）。
別の仕組み（一時ファイル / ラウンドごとに 1 プロセス / ソケット）を発明する必要は無い。

**閉じていない**: **stdin を明示的に閉じる手段が無い**。Rust は `drop(stdin)` で閉じるが、
Lean のハンドルは GC が解放する。probe では動いた（ドライバが参照をやめた時点で子が終わった）
が、**本物のドライバはラウンドをまたいで子を構造体に持つ**ので同じにならない可能性があり、
そのときの症状は**返ってこない build**。

#### 単位 11 も済んだ — SHA-256 と ledger（2026-08-31）

Lean core にも Std にも SHA-256 は無かったので**純 Lean で書いた**（→
`benchmarks/results/purelean-sha256-2026-08-31.txt`）。しきい値は
「micro 2 秒 / 対象 60 秒」で、**どちらも大差で通った**:

| | Lean（順次） | Rust `ledger build` |
|---|---|---|
| e2e/micro 11 olean / 643,104 B | **0.01 s** | 0.0006–0.0012 s |
| 対象 422 モジュール / 228,439,544 B | **2.03–2.04 s** | `--concurrency 1` で 0.13 s |

**15.6 倍の差はスレッドではない** — Rust は 1 スレッドでも 1,765 MB/s 出る。
arm64 の SHA-256 命令を `sha2` が使っているから。Lean は 112 MB/s。
**C に移すならその命令を狙う必要があり、帰属表示の義務もつく**ので、
2 秒で足りるうちは Lean のままでよい。peak RSS 7.9 MB（最大 olean は 4.2 MB）なので
**チャンク読みは書いていない**（実測であって仮定ではない）。

`ledger.json` は **11 通りでバイト一致**（うち 4 通りは自分で再現。
bare / `--ir` / `--source-url` + `--link-index` / `--root` = 3180 / 3247 / 3435 / 3435 B、
`externalLinks` が `--root` の有無で `dea95501…` ↔ `8244901f…` と変わるので**空虚ではない**）。
olean が 1 つも無いモジュールは**両方が exit 3 で同じ行**を出す。

**ゲートを足した**: `purelean-micro-gate.sh` は **9 項目**になり、項目 9 が
両者の `ledger build` を丸ごとバイト比較する。**キー順は挿入順であってソート順ではない**ので、
両方をパースして比べる形にするとその性質が見えなくなる。
`rendererId` を v5 に変えて**単独で落としてから通した**（char 446 で違う、と 1 行で言う）。

**閉じていない**: `--algorithm lake` は未実装（`build` は常に sha256 なので M4 には要らない）/
ledger を**読み戻す**側（`check` / `touch` / schema 1 の拒否）が無い → M5 /
`bytes: -1` の番兵は `--algorithm lake` 専用なので Lean 側に存在しない。

#### M4 で足すゲート項目（`purelean-micro-gate.sh`、1 つずつ落としてから通す）

**全部足した。ゲートは 13 項目**（9 = ledger、10 = build の 23 ファイル、
11 = site-gate、12 = config-gate、13 = marker）。

**11 と 12 は「10 の比較が通ったとき」ではなく「Lean の build が site を書いたとき」に走る。**
最初は比較に従属させていて、それだと**10 が落ちると 11/12 は自分の理由で落ちられない** —
項目 8 が `site_ok` に守られていたのと同じ形。緩めたので、アセットを 1 つ落とすと
10 は「1 missing」、11 は「DEAD internal links: 15 (1 distinct destinations, 15 pages)」と
**別々の理由**を言う。

**壊したのに落ちなかったら、まず壊れたかを確かめる。** 項目 13 を落とそうとして
`"litedoc4 build"` を置換したが 0 箇所しか当たらず（Lean ソース中は `\"` でエスケープされている）、
**ゲートが弱いのではなく変更が入っていなかった**。

#### M4 で閉じなかったもの

1. ~~**`Generation` は移植していない**~~ **2026-08-31 に閉じた**（→ M5 の節）
2. ~~**`<out>/state/global-state.json` を書かない。**~~ **2026-08-31 に閉じた** —
   `Global/State.lean` を移植し、`site --state` と `build` に通した。
   `global-state.json` は cold も warm も **10,499 B でバイト一致**、
   `global  cache 0 hit / 11 miss` → warm で `11 hit / 0 miss` も一致。
   **壊れた state 10 通り**（4 つの version キーを 1 つずつ / 切り詰め / 非 JSON /
   空 / エントリ欠損 / 末尾の `}`）が**両方とも黙って cold に落ちる**ことも確認した
   （良い state での 11 hit を対照に置いてある）。
   対象規模でも確認: 422 モジュールの IR で state は **1,337,956 B バイト一致**、
   サイト 431 ファイルも stdout も一致。
   `tokens` が一番高くついた — Rust の規則は**意図的に UnicodeBasic と V8 の
   2 つの GC 表の和**なので、`Global/V8Gc.lean`（737 レンジ）を足して `Md/Gc.lean` と共有させた
3. **`work/extract-timings-1.json` と `work/ledger-timings.json` を書かない。**
   前者は `fold_timings` 未移植（events JSONL 自体は書かれる）
4. **config-gate のオラクルはまだ Rust。** ゲートは `global` サブコマンドを走らせ、
   Lean の CLI にはまだ無い（`--built` に Lean のサイトを渡す形で検証した）。
   `LITEDOC4` を Lean にするには `global` が要る → M7
5. **Lean の `panic!` する JSON リーダに入口が 1 つ増えた** — 壊れた `<ir>/index.json` が
   `extractKey` に届く。`lake-manifest.json` はテキストとしてハッシュするだけなので
   そちらは増えていない

#### `--source-url` の末尾スラッシュ（2026-08-31 に見つけて塞いだ）

**Rust は `…/e2e/micro/Example.lean`、Lean は `…/e2e/micro//Example.lean`** を書いていた。
`render` と `site` は `--source-url` を検査しない（`build` だけが 40-hex を要求する）ので、
**末尾スラッシュ付きの URL を渡すと 11/11 ページが乖離する**。

**一般形の関数は既にあった。** `trimTrailingSlash` は `External.lean` にあり、
Rust が剥がす 4 箇所のうち **3 箇所（ledger ×2 / packages / external）では呼ばれていて、
`renderSite` の 1 箇所だけが呼び忘れ**だった。「一般形に上げ忘れた」ではなく
「一般形はあったのに 1 箇所で使わなかった」— **検査は「関数があるか」ではなく
「呼ぶべき場所すべてで呼んでいるか」を見る必要がある**。

ゲートは**項目を増やさずに**塞いだ: **項目 3 を 2 つの綴り**（素、末尾スラッシュ付き）で走らせる。
同じ主張を別の入力で確かめるだけなので、項目にすると同じ欠陥を 2 回報告することになる。
落としたとき「with a trailing slash on --source-url: 11 differing」と**どちらの綴りで
落ちたか**を言う。

#### 項目 14 — build の transcript（2026-08-31）

**項目 10 はファイルしか比べていなかった**ので、`global … state 0 B` と Rust の
`state 10499 B` の差が**全項目緑のまま**残っていた。`build` が何を言ったかは誰も見ていなかった。

正規化は 3 つ（duration / `ready` のタイムスタンプ / 2 つの run の `--out`）で、
どれも「移植のせいではない理由で動く値」。**4 つ目の `, generation <hex>` は
例外リストではなく既知の欠落**として符号化した: 項目は
**「Rust は出す・Lean は出さない」を主張し、どちらかが崩れた日に落ちる**。
Lean が出すようになったら「Generation landed, so delete the normalisation」と言う。
両分岐とも実際に落として確認した。

#### 実測で分かった、もう 1 つの状態

`write_marker` は `open_extractor` の**前**に呼ばれる。つまり
**`--extractor-bin` が無くて失敗した `build` も `litedoc4-build.json` と
`work/modules.txt` を残す**（実測）。次の run はそれを所有物と認めて
`Full("the previous run did not finish")` と答える — 正しい。
だが「空の `--out`」と「失敗した run が触った `--out`」は**別の状態**で、
試行のあいだに `rm -rf` するゲートは後者を隠す。

### M5 incremental — ledger / impact / ownership / merge / mode
- ~~最初にやるのは `--state`~~ **2026-08-31 に済んだ**。`planOf` の検査 8 は通る
- ~~次は `Generation`~~ **2026-08-31 に済んだ**。両バイナリが同じ digest
  （`d78f65c3ecda6961`）を出し、`.hash` sidecar を書き換えると**両方が同じ新しい値**
  （`13e1737c29490fc3`）に変わる — 実際に Lake の sidecar を読んでいる。
  `Algorithm` は `.sha256` / `.lake` の 2 択になり、**walk は共有**（`modulePaths` は 1 つ）。
  予告どおり項目 14 が落ちたので**正規化を消した** — `serve ready` の digest まで
  比較対象に戻っている。
  照合が exit 3 で落ちることは **3 つの窓のうち 2 つ**で確認した
  （spawn 時 / リクエスト後。両バイナリがバイト同一のメッセージ）。
  **3 つ目（リクエスト前）は構成できていない** — `detect` の最中に世界が動く必要があり、
  フックが無かった。同じ `checkGeneration` を通るという議論はあるが、**議論であって計測ではない**

- **M5 で持ち越す設計上の注意**: Rust は**最初のリクエストで遅延して**サーバを起動する。
  何も抽出しない run が 3 GB と import を払わないためで、Lean 側は full path しか無いので
  常に起動している。**incremental を入れるときに遅延も一緒に持ってこないと、
  いちばん多い答え（「stale なものは無い」）がいちばん高くつく**
- プロトタイプの `Incr.lean` が土台。**bimodal な `ownership`（423 読み vs 2 読み）を保つ**
- `onemod-gate.sh` は**ここ**（旧 M3 から移した）。引数が
  `<litedoc4-build.json> <serve.out>` で、1 モジュール編集後の
  `modulesExtracted` / `pagesRendered` を見るゲートなので、測っている対象は incremental
- **完了判定**: `incremental-compare.sh` / `impact-compare.sh` / `merge-compare.sh` /
  `ledger-compare.sh` / `onemod-gate.sh` が Lean 実装で緑

#### 完了判定そのものを直す必要がある（実測 2026-08-31）

**5 つのうち 4 つは「ゲート」ではなく比較器で、Lean を指せない。**
`incremental` / `impact` / `merge` / `ledger` の `*-reference.sh` は 4 本とも
`RUST_BIN="$REPO/target/release/litedoc4"` を**ハードコード**していて、フラグも環境変数も無い
（実測）。`tools/gates.txt` にも 4 本とも載っていない — 載っているのは `onemod-gate.sh` だけ。
**U13 で `LITEDOC4` 環境変数を足す**（`purelean-*-gate.sh` と同じ綴りにする。
バイナリを `target/release/litedoc4` に置き換えるのは、Rust のオラクルを壊すので取らない）。

**`onemod-gate.sh` だけは本物のゲート**で、要求は 3 つ、うち 2 つは**等号ではなく不等号**:
`modulesExtracted >= 1`（0 は「速いビルド」ではなく「走らなかったビルド」）/
`1 <= pagesRendered < modules`（上限は `.lidx` が毎回動く退行を捕まえる。
その digest は `renderKey` の入力なので、1 宣言増えるだけで全ページ再描画になる）/
`serve.out` に extractor 自身の `linkIndex … reused` 行があること
（「動いていない」と「書かれていない」はバイトで区別できないので**ファイルではなく extractor に訊く**）。

#### 大きなヘッドスタートが 1 つある

**`benchmarks/lean-prototype/Incr.lean`（1,079 行、43 KB、core だけ）が
`impact` / `ownership` / `merge` を実装済み**で、422 モジュールの対象で Rust と
バイト一致を確認済み（→ `benchmarks/results/purelean-incremental-2026-08-30.txt`）。
**ただし無いものがそのファイル自身に書いてある**: `--census` / `--changed-file` /
`--exclude` / `--removed` / `--modules` / `--timings` / `merge --verify`、そして
拒否のほぼ全部。自前の JSON リーダと型も持っているので、`src/` に入れるには
`Litedoc4.Json` / `Litedoc4.Ir` に載せ替えが要る。**「1,079 行あるから終わり」ではない**。

#### オラクルの記録（2026-08-31 に 3 本取った）

`*-reference.sh` は**実装の答えを記録する**スクリプトで、`*-compare.sh` が 2 つの記録を
比べる。**Rust 側の記録は取ってある**ので、Lean 側は同じ引数で 2 本目を取るだけでよい。
`LITEDOC4` を渡す（U13 の前半、`62bab9b`）。**対象リポジトリは読むだけ。**

| 記録 | 入力 | 出力 |
|---|---|---|
| ledger | `--ir /private/tmp/lean-doc-relay/purelean/ir`（422 モジュール） | `m5-ledger/rust`（78 ファイル、1.1 MB） |
| merge / ownership | `--base-ir` 同上 | `m5-merge/rust`（3,961 ファイル、141 MB） |
| impact / prune | `--base-ir` 同上 / `--pages m5-impact/ref-pages` / `--site m5-impact/ref-site` | `m5-impact/rust`（3,585 ファイル、248 MB 込み） |

`m5-impact/ref-site` は `target/release/litedoc4 site` で作った 422 ページのサイト（26 MB）。

impact の記録は 2026-08-31 に**取り直した**。最初の記録は `--pages` に
`purelean-render-gate.sh` が残した木を渡していて、その木を掃除で消してしまった —
`prune` は木を `$OUT` に複製してから消すのでオラクル自体は自己完結していたが、
Lean 側が同じバイトを出すには**同じ `--pages` が要る**。今は `ref-pages` も `ref-site` も
`ref-site` と同じ固定 URL で `target/release/litedoc4` から作り直せる（上の表の入力）。
**一般形: 記録の入力は、記録と同じ寿命を持つ場所に置く。**
**`it-modules.txt` は 432 のまま動く** — 10 個の stale な olean が残っているので
`ledger build` は 432 モジュール全部にハッシュを付けられる（実測: `clean` シナリオが
432 モジュール 0 changed で通る）。

#### 移植の単位（U1〜U13）

| # | 単位 | Rust | 状態 |
|---|---|---|---|
| U1 | `openUnvalidated` / `Ordered α` | `ir/reader.rs`, `incr/ordered.rs` | 小 |
| U2 | ledger **リーダ** + `KeySet.diff` + `checkLedger` + 3 つの出力ファイル | `incr/detect.rs`, `ledger.rs` | **済み 2026-08-31** |
| U3 | `ledger touch` | `incr/detect.rs:409` | **済み 2026-08-31** |
| U4 | `impact`（4 つの mode） | `incr/impact.rs` | プロトタイプあり |
| U5 | `ownership` — **`watching` ガードを保つ** | `incr/ownership.rs` | **済み 2026-08-31** |
| U6 | `merge` + `--verify` | `incr/merge.rs` (773) | **済み 2026-08-31** |
| U7 | `prune` | `incr/prune.rs` (518) | **ゼロから** |
| U8 | `ModuleSet` + `--only` / `--only-from` | `render/site.rs` | ゼロから。**`purelean-render-gate.sh` 項目 5 が「`--only` を拒否する」を主張しているので同じ変更で直す** |
| U9 | global の delta（`--before` / `--print-set` / `--delta-json`） | `global/delta.rs` | `tokens` はある |
| U10 | `Resident`: **遅延起動** / リクエスト数 / 冪等な stop / `foldTimings` | `resident.rs`, `extract.rs` | 今は単発 |
| U11 | `incremental` パイプライン本体 | `pipeline.rs` (1,534) | **ゼロから**。`tests/incremental.rs` の 61 分岐が点検表 |
| U12 | `planOf` の検査 4〜9 + `incrementalGeneration` | `build.rs` | U11 の後なら小 |
| U13 | ゲート配線（4 本に `LITEDOC4`、micro ゲートを 14 → 16） | — | **4 本は済み 2026-08-31**（`62bab9b`）。micro ゲートの項目はまだ |

**`ownership` の bimodality の正体**（実測）: `lostOwners` も `gainedOwners` も空なら
**base の IR を 1 つも読まない**。空でなければ **exclude を除く全 base モジュールを読む**。
e2e/micro で `scannedBaseModules` が **10 と 0**、対象で **423 読み対 2 読み**。
**`watching` ガードは最適化ではなく、その 2 つを分ける唯一のもの** — 無条件にループする
移植は「正しくて 200 倍遅い」。

**`irReads` の実測値**（項目 13 が丸ごと比較するので、ここがずれると出る）:
full = `{3, 22, 4, 29}` / incremental で何も stale でない = `{5, 11, 2, 18}` /
1 モジュール編集 = `{10, 46, 4, 60}`。

#### U2 / U3 で分かったこと（2026-08-31）

`ledger-compare.sh` が **`IDENTICAL`**（66 ファイル: 台帳 9 本がバイト一致、
timings 19 本が持続時間を除いて一致、`.txt` 38 本がバイト一致）。
比較器は先に一度落とした — 台帳の 1 バイト / timings の `modules` / `.txt` の 1 行を
摂動して 3 つとも `DIFFERS`、持続時間の**値だけ**の摂動は `same counts` のまま。

- **Rust の `LedgerSchema` 拒否は本物の schema-1 ファイルには届かない**（実測）。
  `check_ledger` は `serde_json::from_str` を**先に**完走させるので、`envKey` しか持たない
  schema-1 は `missing field `extractKey`` で exit 1 になる。`ledger.rs` のコメントが約束する
  「schema-1 はパース失敗ではなく schema-1 として名指す」は**その約束のほうが正しい**ので、
  Lean 側は schema を先に見て exit 3 にした。schema-2 の全フィールドを持ちつつ
  `ledgerSchema: 1` のファイルでは両者が完全に一致する
- **`Algorithm` は `Ledger.lean` の外でも使われている** — `Build.lean` の `Generation.take` が
  `hashModule .lake` を呼ぶ（micro ゲート項目 14 が通る経路）。`grep Algorithm` では出ない
- 空集合の綴りを 1 か所に寄せた（`Fs.linesFile` / `writeLines`）。`modules --out` が
  同じ判断を別に持っていた
- **`--concurrency` は受け取って記録するが、ハッシュは逐次**。stdout は `concurrency 1`
  （やったこと）を出し、N > 1 なら別行で「逐次でやった」と言う。timings は Rust と同じく
  **要求値**を記録する。スレッドプールは別単位
- **`check` が遅いのは移植ではなくハッシュ**（実測 →
  `benchmarks/results/purelean-ledger-check-2026-08-31.txt`）。`--algorithm lake`
  （バイトを読まない）で比べると Lean は Rust の **1.3 倍**（0.0120 s 対 0.0093 s、432
  モジュール、暖機 5 回）で、`sha256` にすると **15.7 倍**（2.115 s 対 0.135 s）になる。
  差の全部が SHA-256 で、**これは M4 で既に決着している**
  （→ `purelean-sha256-2026-08-31.txt`: 112 MB/s、60 s 予算に対し 2 s、C は
  帰属義務ゆえに取らない）。**スレッドプールも C も 2.1 s では licence されない**

#### U5 / U6 で分かったこと（2026-08-31）

`merge-compare.sh` が **3,961/3,961 一致（`IDENTICAL`）**、9 シナリオ + `--verify` 3 本。
比較器は 1 文字の摂動で `DIFFERENT` になることを先に確認した。

**bimodality は保たれている**（実測、Rust と Lean が同値）:

| シナリオ | `scannedBaseModules` | モード |
|---|---|---|
| `rerun` / `modified` | **0** | base の IR を 1 つも読まない |
| `moved` | 417 | 全部読む（exclude 3 を除く） |
| `gained` / `added` / `removed` / `restored-1` | 421 | 全部読む |
| `copyout` / `restored-2` | 420 | 全部読む |

- **重複キーは深さを問わず畳む**。`serde_json` の `preserve_order` はパースの時点で
  重複キーを畳む（最初の位置・最後の値）ので、`modules[]` の生オブジェクトの中で
  両方残す実装は**手編集された index を Rust が落とすキーごと往復させてしまう**。
  `jvalCollapse` が入り口で再帰的に同じ規則を当てる（`"bytes":999999,"bytes":N` で
  両バイナリがバイト一致することを確認）
- **「最初の位置・最後の値」の綴りを 1 つにした** — `Incr/Ordered.lean` の
  `orderedInsert` / `orderedGet?` に台帳・マージ後 index・`moduleMap`・`depMapping` が
  全部乗る
- **`openUnvalidated` は U1 ではなく Ir.lean の分岐**。`ownership` / `merge` は
  「木について答える」ので、レンダできないほど古い木にも答えられる必要がある

**2 つのオラクルはパッケージの大きさについて食い違う**（気づき、U11 に効く）:
`it-modules.txt` は 432 で凍っていて ledger のシナリオは 432 モジュールをハッシュするが、
M5 のオラクルを記録した base IR は **422 モジュール**（merge のシナリオは `into 422`/`423`
と出る）。**台帳と IR index を突き合わせる段（U11）は、この 10 の差を「既知のドリフト」
ではなく diff として踏む**。U11 に入る前に、どちらの母数で回すかを決めること。

#### M5 に入る前に塞ぐもの: `Json.lean` は整数しか読まない → **2026-08-31 に塞いだ**

`JScan.digits` は小数点も指数も符号も読まなかった（実測）。**`incremental --timings` は
`work/*-timings*.json` を読み戻し、それらは `"copySeconds":0.000398834` を含む**ので、
Lean のパーサは `.` で `,` を期待していた。

**症状は「`panic!` で止まる」ではなかった**（実測）。IR の `index.json` に
`"copySeconds":0.000398834` を 1 つ入れて `render` を走らせると、パーサは
backtrace を stderr に吐いた**あと `.null` を返して先へ進み**、
`litedoc4: index.json is schema 0` と**別の原因を名乗って** exit 1 した。
Lean の `panic!` は abort ではなく既定値を返すので、
**`pArr` / `pObj` の 2 つの `panic!` はどちらも「止まる」ではなく「黙って木を差し替える」**。
M5 の入口（`--ledger` / marker / 古い IR）は**名前を言って止まる**必要があるので、
**パーサに誤りの経路を持たせた**（2026-08-31、次のコミット）:
`JVal.bad (why)` が `panic!` 2 か所を置き換えて上まで伝わり、`parseJson` だけがそれを見て
`Except String JVal` を返す。`Except` をスキャナ全体に通さないのは、IR が数十 MB の値で、
**値ごとに包むと唯一の熱い経路の割り当てが倍になる**ため。
ついでに寛容さも落とした（`:` の無いキー / `tru` / 数字の無い数 / 末尾のごみ）。

**同じ問いに答える 2 経路目を消した**: `Global/State.lean` は
`jsonComplete`（「パーサが `panic!` に達するか」を別実装で先読みする 7 関数）を持っていて、
その doc は「`pVal` より意図的に厳しい — 小数は `none`」と書いてあった。
**小数を読めるようにした時点でこの記述は嘘になり**、`State.load` だけが直って
他の読み手が直らない形になっていた。パーサ側に一本化して 7 関数を削除。

直し方は `JVal.real (lexeme : String)` — **値ではなく書かれたバイトを持つ**。
Lean には最短往復の `Float` 印字が無く、これらの数（抽出器のフェーズ時計）は
`write_timings` が**素通しでコピーするだけ**なので、変換しないのが往復の唯一の保証になる。
整数の速い経路は変えていない（桁の直後の 1 バイトを見るだけ）。
検査は `1.0` / `-0.5` / `1e-7` / `2.5E+10` / `-3.25e2` / 配列内の 3 つを
`index.json` に入れてページと stdout が**注入前と同一**であること — 走査の終端がずれると
次のキーが壊れるので、これが終端位置の検査でもある。`purelean-micro-gate.sh` 14/14。

そしてこれは、より大きな話の一部: **M1〜M4 で Lean が読んだ JSON は「同じ run で自分の
extractor が書いたもの」だけだった。M5 は自分より前から在るファイルを読み始める** —
`--ledger`（**任意のバージョンが書いた**、手編集もありうる。M5 が読む中で最も鋭い入口）/
marker（**壊れた run** が残したもの。Lean は既に `.malformed` を持つ）/
`<out>/ir/**`（**古い litedoc4** が書いた木を CI キャッシュが戻す）/
`name-map.json` を `--before` として。**どれもファイル名を言って止まる必要があり、
既定値を返して続けてはいけない**。

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
- **ビルド時間が消費者に受け入れられない** → **M3 で計測した。まだ天井は遠い**
  （→ `benchmarks/results/purelean-consumer-build-2026-08-31.txt`）:
  3,887 行 26 モジュールの cold build が **6.2 s に収束**（5 回連続、初回 9.65 s は
  ページキャッシュで、user+sys は全回 23.4 s）。extractor の 11.65–16.82 s より安い。
  **これは消費者の総額ではない** — 初回は MathML4Lean と C 2 つと extractor も払う。
  M8 まででこの数字を再measure すること

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
