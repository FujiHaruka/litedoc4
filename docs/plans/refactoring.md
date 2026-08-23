# リファクタリング — 一度もやっていない木の棚卸し

起票 2026-08-23。**このリポジトリは検証段階 (approach.md §7) と移設 (M1〜M8) と機能スイープを
通してきたが、リファクタリングを一度もやっていない。** v0.1 を締め、残件掃きも決着した今が、
**「動いているものを動いたまま整える」**唯一の空きどころ。

**この文書の読み方**: §1〜§2 が前提と方針、§3 が「今壊れているもの」(段 0、**15 件**)、
§4〜§11 が段 1〜8 (**計 47 項目**)、§12〜§16 が順序・検証・触らないもの・撤退ライン。
**段は互いに独立しているので、実装するときは §1・§2・§12〜§16 と自分の段だけ読めばよい。**

| 段 | 中身 | 項目 |
|---|---|---:|
| 0 | 実際に壊れているもの (D0〜D14) | 15 |
| 1 | `crates/litedoc4` の構造 (R1〜R9) | 9 |
| 2 | `-render` / `-md` (S1〜S8) | 8 |
| 3 | `-incr` / `-global` / `-ir` (X1〜X8) | 8 |
| 4 | テストの共通化 (U1〜U6) | 6 |
| 5 | `tools/*.sh` (T1〜T6) | 6 |
| 6 | CI (C1〜C3) | 3 |
| 7 | Lean extractor (L1〜L3) | 3 |
| 8 | docs と掃除 (E1〜E4) | 4 |

## 1. 出発点 — 何を見たか

**木の全体を 4 系統に分けて調べた**。Rust は crate 別に 3 体の subagent へ、
shell / CI / Lean / web / 横断指標は自分で。**すべての指摘に `file:line` の根拠がある。**

| 系統 | 規模 | 調べ方 |
|---|---|---|
| `crates/litedoc4/` (bin) | src 10,699 (うちファイル内テスト 1,880) + tests 6,038 | subagent |
| `crates/litedoc4-render` / `-md` | src 11,766 + tests 6,810 + vendor (C) | subagent |
| `crates/litedoc4-incr` / `-global` / `-ir` | src 10,006 + tests 10,783 | subagent |
| `tools/*.sh` 35 本 | 9,740 行 | 自分 (同一行の機械検出) |
| `.github/workflows/` 13 本 | 3,248 行 | 自分 (同上) |
| `extractor/Extract.lean` | 3,687 行 (単一ファイル) | 自分 |
| `crates/litedoc4-render/web/` (TS) | 1,820 行 | 自分 |
| 横断 (公開 API / 関数長 / 重複) | — | 自分 (機械集計) |

### ベースライン — これが安全網【実測 2026-08-23】

```
cargo test --workspace --no-fail-fast   36 バイナリ / 437 passed / 0 failed / 21 ignored / exit 0
cargo fmt --check                       exit 0
cargo clippy --workspace --all-targets -- -D warnings   exit 0
```

**この 3 つは各段の終わりで必ず緑に戻す。** ゲート (`tools/*-gate.sh`) は機材を要るので、
CI の `ci.yml` が呼ぶ 6 本 — `corpus-gate.sh --verify-list` / `provenance-gate.sh` /
`assets-gate.sh` / `e2e-micro.sh` / `pinned-dep-gate.sh` / `browser-gate.sh` — を段の切れ目で回す。

### 木の規律は高い。問題は規律ではなく構造

先に書いておく。**outer `#[allow]` は木全体で 1 つも無く、TODO/FIXME も無い。**
`#[expect(reason = …)]` は 5 箇所で、すべて理由が読める。`cargo doc -D warnings` も
`cargo machete` も CI で緑。規則違反 (例外リストを持つ比較器 / skip での緑) はゼロ。

`unwrap()` / `expect()` は crate によって分かれる【実測】: `litedoc4` / `-render` / `-md` の
**src 本体はゼロ** (テストと doctest のみ)。一方 `-global` / `-incr` には本体側にある —
`search_index.rs` に 15、`incr` の impact / ledger / merge に各 4、ownership に 2。
**`search_index.rs` の 15 件はすべて境界チェック付きの数値変換で理由が書いてある**
(`u16::try_from(entry.module).expect("fewer than 65,536 modules")` など) が、
**`# Panics` 節が無い** (→ 段 3 の X7)。

**それでも「同じ判断の実装が 2 本ある」箇所が、3 crate すべてで見つかった。**

調査担当の 1 人がこう書いている:

> lint と `#[expect]` の強制は効いているが、**「判断は 1 箇所に集める」だけは機械的に検査する
> 手段が無く、そこだけが素通りしている。**

これがこの計画の中心にある事実。

## 2. Approach — 「動いているものを動いたまま整える」

### 2.1 3 つの原則

1. **振る舞いを変えない。出力バイトを動かさない。**
   `litedoc4-incr::RENDERER_ID` (現 `"litedoc4 renderer v4"`) と `EXTRACTOR_ID` は互換トークンで、
   **これを上げる必要がある変更はリファクタリングではない**。上げずに済む変更だけを入れる。
   調査 3 件が挙げた指摘のうち、**出力バイトを動かしうるものは 0 件**。

2. **「壊れているもの」と「整っていないもの」を分ける。**
   調査で**実際の欠陥が 15 件**見つかった (段 0)。**うち 1 件は IR を破壊する** (D0)。これはリファクタリングではなく修正なので、
   **先に、別のコミットで、テストを足してから直す**。整形と修正を混ぜると、
   どちらが振る舞いを変えたのか後から読めなくなる。

3. **1 commit = 1 種類の変更。**
   「関数を分けた」と「ついでに直した」を同じコミットに入れない。
   **各コミットの後で `cargo test` / `clippy` / `fmt` が緑**であること。

### 2.2 層と安全網 — 順序はこれで決まる

**安全網が厚い層から着手する。** 検証コストが安いほど、間違いに早く気づける。

| 層 | 安全網 | 1 回の検証コスト | 機材 |
|---|---|---|---|
| Rust 本体 | `cargo test` 437 本 + clippy + fmt + doc | 数十秒 | **不要** |
| テスト自身 | 同上 (テストがテストを検査する形は無い) | 同上 | 不要 |
| shell tools | CI の 6 ゲートのみ。**残り 29 本は手で回すしかない** | 分〜時間 | **対象リポジトリ** |
| CI workflows | 走らせるまで分からない | 分 | ブランチ push |
| Lean extractor | 対象の Lean 環境が要る。`lake-package-gate.sh` が 2 経路の一致を見る | 分 | **対象 + toolchain** |

**この表が段の順序そのもの。**

### 2.3 やらないと決めていること

- **doc-gen4 との byte 一致は追わない** (M8 で終了、再定義しない)。凍結フィクスチャとの比較テストは残る
- **依存を増やさない。** `tempfile` のような外部 crate を入れる誘惑があるが、
  依存は NOTICE の導出検査 (`provenance-gate.sh`) と `deny.toml` に効く。
  ワークスペース内の `publish = false` な crate なら NOTICE に影響しない (→ 段 4)
- **数を目標にしない。** 「N 行減らす」も「N 件の指摘を消す」も目標ではない。
  **落ちたときに何が壊れたか 1 行で言えるかどうか**が唯一の基準 (CLAUDE.md「品質ゲート」)

## 3. 段 0 — 実際に壊れているものを直す (リファクタリングではない)

**調査で見つかった「今すでに壊れているもの」15 件。整形より先に、テストを足してから直す。**
順序は独立なので任意 — **ただし D0 が最優先** (これだけがデータを壊す)。

### 結果 — **15 件すべて完了** 【2026-08-23】

| | 内容 | commit |
|---|---|---|
| D0 | `merge` の same-tree 判定を綴りから実体へ | `bdad7d2` |
| D1 | `ledger` のフラグ黙殺 | `eee3c9f` |
| D2 | 40 桁 hex の判定を 1 本に | `ad394dc` |
| D3 | "IR schema 4" → 5 | `50b8c89` |
| D4 | ゲート台帳の散文 | `d74d84f` |
| D5 | render のクレートドキュメント | `3cfa6e6` |
| D7 | docstring の入れ替え | `4933366` |
| D8 | `_` の受け皿 | `6a0a9ff` |
| D9 | `extractor/README.md` の行数 | `1ae1c40` |
| D11+D12 | `base_ir` の schema assert とフィクスチャ判定 | `06a0d02` |
| D13 | `..` の論証 3 箇所 | `d07ad7c` |
| D6 | `design/preview` の `app.js` | `5274516` |
| D14 / D10 | global の doc 8 箇所 / md の到達不能分岐 | 下記 |

**この段で分かったこと (次の段が同じ失敗をしないために)**:

- **D0 と D13 は「実測してから直した」** — `fs::copy` が同一実体を空にすることも、
  `«..».Foo` が `../Foo.html` になることも、**先に落ちるテストを書いて確かめた**。
  どちらも直す前は「そうなるはず」でしかなかった
- **推測で書いた値が 1 つ紛れた** — D12 の `MEASURED_FIXTURE` に `generator` を
  `"litedoc4/extractor"` と書いたが、実際は `"lean-doc/experiments/stage4b"`
  (`extractor/Extract.lean:2838`、`docs/plans/rename.md` 項目 4 の意図的な旧名)。
  **corpus が無い機材では落ちないので、grep で裏を取るまで気づけなかった**
- **「当時の記録」と「現在の記述」を分けた** — D14 で `facts.rs:30` の見出し
  「M8-d added a seventh field」は**残し** (M8-d 当時は 7 番目だった)、
  本文の「`search-index.json` が要る」だけを直した。
  `merge.rs:46` / `facts.rs:348` の【実測 2026-08-12】も触っていない
- **`cargo doc` は CI と同じ形で回さないと赤くなる** (→ §12 の完了条件を書き直した)

### D0 — `merge` が「out と base は同じツリーか」をパスの綴りで判定し、IR を破壊する【最優先】

- 場所: `crates/litedoc4-incr/src/merge.rs:348` (`if options.out != options.base`)、
  コピー実行は `:351-359` と `:916-921`。呼び出し口は `crates/litedoc4/src/main.rs:1398-1400`
  (`--base` と `--out` は**別々のユーザ入力**)
- **`options.out != options.base` は `Path` の `PartialEq` = components 比較。**
  `./ir` は `[CurDir, Normal("ir")]`、`ir` は `[Normal("ir")]` なので**不一致**になり、
  「out は別ツリー」と判断して未変更モジュールを `fs::copy(base/f, out/f)` する
- **同一実体への `fs::copy` は `Ok(0)` を返し、ファイルを空にする**
  【実測 2026-08-23、調査担当とこちらで**独立に 2 回**再現】:

```
paths equal? false
before: Ok("CONTENT-THAT-MUST-SURVIVE\n")
copy -> Ok(0)
after:  Ok("")
```

- **帰結**: `litedoc4 merge --base ./ir --inc <partial> --out ir` は、
  **部分抽出が触らなかった全モジュールファイルを 0 バイトに truncate する**。
  その後 `merge.rs:400` の `read_module_file` が最初の空ファイルでパース失敗し exit 1 になるが、
  **そのときには base ツリーが唯一のコピーだったまま壊れている**
- 既定経路は安全 (`main.rs:1384-1387` が `--out` 省略時に `base + ".merged"` を作る) が、
  **`--out` は公開フラグ**で、`pipeline.rs:576/578` が「in place なら同じ値を渡す」という
  規約に依存しているだけ
- **正しい判定が同じ crate の隣のファイルに既にある**: `prune.rs:206-222` の `PageRoot::contains` は
  `fs::canonicalize` してから比べる
- 直し方: `same_tree(base, out) -> Result<bool, Error>` を 1 本置いて `merge()` の冒頭で使う
  (存在しない `out` は `create_dir_all` 後に解決)。最小修正なら `copy()` (`:916`) に
  「解決後に from == to ならスキップ」。**先にテストを書く** —
  `--base ./x --out x` で中身が残ることを検査する
- 規模: 20〜30 行。**正常系の経路は変わらない** (変わるのは今壊れている入力だけ)

### D1 — `ledger` サブコマンドが他サブコマンドのフラグを黙って受理して捨てる【実害あり】

- 場所: `crates/litedoc4/src/main.rs:1071-1127`
- `ledger` は `build` / `check` / `touch` の 3 つを持つが、**1 本のフラグ集合を平らにパースしてから
  `match command` する**。結果 `litedoc4 ledger touch --concurrency 9 --ir /x --deps-docs-map /y` は
  **全部受理されて全部無視される**。`ledger build --changed-out` も同じ
- **同じ木が同じ形をわざわざ拒否している**: `extract.rs:204-215` は `--link-index-omit` を
  `--link-index` 無しで渡すと落とし、その理由をこう書いている —
  「a flag that does nothing is the shape of bug this project keeps finding: the run looks right
  and the artefact is not the one that was asked for」
- 直し方: `ledger` を 3 関数に割り、各関数が自分のフラグだけを受理して他は `unknown` に落とす。
  **先にテストを書く** (`litedoc4 ledger touch --concurrency 9` が exit 2 になること)

### D2 — 「40 桁 hex か」に答える経路が 2 本あり、答えが違う

- `crates/litedoc4/src/packages.rs:396-400` `is_revision` は `is_ascii_hexdigit()` = **大文字も真**。
  **docstring は "40 lower-case hex digits" と書いていて実装と食い違っている**
- `crates/litedoc4/src/pipeline.rs:1416-1439` `check_source_url` は
  `is_ascii_digit() || (b'a'..=b'f')` = 小文字のみ
- 帰結: 同じ 40 桁が `--source-url` では exit 2 で拒否され、`lake-manifest.json` の `rev` では受理される。
  `core_githash` (`packages.rs:514`) も `is_revision` 経由なので、大文字を返す toolchain は
  core のリンクを通す。**その値は `renderKey.externalLinks` に入る**
- **どちらが正か**: `docs/implementation-plan.md` §4 決定 1 が
  「`coverage.ts` の revless 正規化は `/blob/[0-9a-f]{40}/` のハードコード」と書いている。
  **`[0-9a-f]` = 小文字のみ。小文字に統一する**【この判断はユーザー確認不要 — 決定 1 が既に答えている】
- 直し方: `is_forty_hex` を 1 本にして 3 箇所を寄せる。**大文字が拒否されることをテストに書く**
- ※ `crates/litedoc4/tests/incremental.rs:342-352` の第 3 実装は
  「Plan 決定 1's rule, written a second time」と明記された**意図的なオラクル**。残す

### D3 — 利用者向けの拒否メッセージが "IR schema 4" と言う (実際は 5)

- `crates/litedoc4/src/extract.rs:152-158`。同じファイルの `:66` は
  「The six flags that spell "IR schema 5"」、`:45` は「`--tagged-code` is what makes it schema 5」
- `litedoc4-ir` は schema 4 と 5 を**実際に区別して読む** (`model.rs:280-306`) ので、
  これは誤字ではなく**実在する別の版を指している**
- `crates/litedoc4/tests/extract.rs:72` の関数名 `..._schema_4_flags` も同じ

### D4 — ゲート台帳が存在しないテスト 2 本を実在するものとして書いている

- `tools/corpus-tests.txt:52-55` が `docgen4::the_whole_corpus` と `md4lean::the_whole_corpus` を
  「ここに載せていないのは意図的」と書いているが、**どちらも存在しない**
  【実測: `crates/litedoc4-md/tests/` に `#[ignore]` は 1 件も無く、`the_whole_corpus` という
  名前のテストも無い。現存するのは `the_whole_corpus_matches_the_prototype` ×2 と
  `the_whole_corpus_carries_the_prototypes_content` ×1】
- `crates/litedoc4-md/tests/md4lean.rs:22-29` 自身が「They used to be … 【判断 2026-08-16】」と
  削除を記録している。`:13` の「two are called `the_whole_corpus`」も古い
- **なぜ残ったか**: `--verify-list` は `#[ignore]` の**テスト名しか照合せず、散文は照合しない**
- 直し方: 52-55 行を削除、13 行を現存する 3 本の名前に。
  加えて `tools/corpus-gate.sh` に「コメント中のバッククォート内の `target::test` 形も
  cargo の一覧と突き合わせる」を 1 行足す (**足すなら一度落としてから通す**)
- **調べた結果、grep の罠は無かった**【2026-08-23、実装を読んで確認】。
  調査担当は「`--verify-list` が素朴な grep なら doc comment 中の `#[ignore]` を拾う」と
  懸念したが、`tools/corpus-gate.sh:53-79` の `listed()` は
  **各テストバイナリを `--ignored --list` で直に叩いて属性を読んでいる**。
  台帳側の `entries()` (`:109-111`) も `s/#.*//` でコメントを落とすので、
  散文中のバッククォート内の名前は最初から数に入らない。
  **だから足す検査は要らない — 直すのは散文だけ**

### D5 — render のクレートドキュメントが存在しない型を仕様として書いている

- `crates/litedoc4-render/src/lib.rs:14-17` が
  「the set of modules to render is `Option<Vec<..>>`, and `Some(vec![])` means render nothing」
- 実際の型は `site.rs:54-60` の `pub enum ModuleSet { All, These(BTreeSet<String>) }`。
  **`Option<Vec` はこのワークスペースに存在しない**
- **規則そのもの (空集合 = 何も描かない) は生きている**ので、型名だけが腐っている。
  正しい版が `site.rs:24-31` にある
- 直し方: `lib.rs` 側は 1 行に畳んで `[`site::ModuleSet`]` へリンクする
  (同じ判断が 2 箇所に書かれている状態が腐りの原因)

### D6 — `design/preview/` が壊れている【実測: 実行して確認】

- `python3 design/preview/bundle.py` は **`FileNotFoundError: …/assets/app.js`** で落ちる
- `design/preview/bundle.py:24` が `crates/litedoc4-render/assets/app.js` を読むが、
  **assets には `favicon.svg` と `style.css` しか無い**。`app.js` は 2026-08-19 の
  TypeScript 化で `build.rs` が `OUT_DIR` に焼くものになった
- 同じ参照が `design/preview/index.html:20` / `module.html:27` /
  `benchmarks/tools/search-format-probe.ts` の 3 箇所にもある = **置き去りにされた 4 ファイル**
- 直し方: `bundle-site.py` は**生成済みサイトの** `site/app.js` を読むので動く。
  `bundle.py` と 2 つの html をどうするか (build.rs の `OUT_DIR` から拾う / 削除する) を決めて 1 箇所に寄せる

### D7 — docstring が隣の関数のものと入れ替わっている

- `crates/litedoc4/src/extract.rs:402-417`。`resolve` の説明 (「symlinks resolved」) が
  `absolute` に付き、**`resolve:425` には一行も説明が無い**
- 5 箇所の containment ガードが実際に呼ぶのは `resolve` の方 (→ 段 1 の R3)
- ついでに `resolve:426-430` は `absolute` の本体をインラインで複製している (呼べばよい)
- `cargo doc -D warnings` では検出できない (リンク切れではない)

### D8 — フラグ拒否が「文字列で再ディスパッチ」になっていて `_` が受け皿

- `crates/litedoc4/src/pipeline.rs:1082-1096`。配列に 4 つ目のフラグを足して `match` アームを
  忘れると、`_ => lake.is_some()` が発火して**メッセージは新しいフラグ名を名乗りつつ判定は
  `--lake` を見る**。テストは通る (既存 3 フラグは正しく動くので)
- **正しい対照が同じ木にある**: `build.rs:475-495` の `[(name, bool); N]` 形。3 行で揃う

### D9 — `extractor/README.md` の行数が古い

- `:16` の表が `Extract.lean` を **2,954 行**と書くが実際は **3,687 行**。`build.sh` は 39 → 46
- CLAUDE.md「docs の『未』は腐る」の数字版

### D10 — md の到達不能分岐と、検証前に変更するヘルパ

- `crates/litedoc4-md/src/parse.rs:221-230` `pop_frame` — `len() >= 2` を確認した直後の `pop()` は
  必ず `Some` = 到達不能。**同じメッセージ文字列が 2 回書かれている**ので失敗ログから枝が分からない
- `:243-252` `close_implicit_p` — `pop_frame` → `save` を**済ませてから**検査する
  (今は `with_builder` (`:461-467`) が latch するので無害)
- **この 2 つは今は無害**。ただし `parse.rs` は `wrapper.c` の**転写**であることが売りなので、
  原典に無い分岐と原典と違う検証順は次に読む人の調べ直しコストになる

### D11 — `base_ir.rs` の corpus テストは走れば必ず落ちる (schema 4 を要求しながら reader は 5 以上を要求)

- `crates/litedoc4-ir/tests/base_ir.rs:259` が `IrTree::open(&root).expect("the fixture is a schema-5 IR")`、
  **その 3 行下の `:262` が `assert_eq!(index.schema_version, 4)`**
- `IrTree::open` は `require_renderable()` を通す (`reader.rs:42` の `MIN_SCHEMA_VERSION = 5`)。
  **schema 4 なら 259 行目で panic、5 なら 262 行目で panic = 通る値が存在しない**
- **なぜ残ったか**: この assert は M1-a (`4eb53e7`) 以来触られておらず、`MIN_SCHEMA_VERSION` を 4→5 に
  上げたのは C-4 (`5101d15`)。**同じコミットで global 側の `schemaVersion` は 5 に揃っている**
  (`state_and_delta.rs:934/958/981`) ので、**この 1 件だけ取り残された**。
  `#[ignore]` + `LITEDOC4_BASE_IR` が要るので CI でも手元でも走らず、誰も気づけない
- **432 モジュール全読み・55,514 フラグメント・実測カウント 20 件を持つこの crate 唯一の corpus テスト**が、
  corpus を持つ機材で走らせた瞬間に無条件で赤になる。「未検証」ではなく「壊れている」の側
- 直し方: `assert!(index.schema_version >= litedoc4_ir::MIN_SCHEMA_VERSION)`
  (**定数を再定義して二重定義にしない**)。2 行

### D12 — フィクスチャの同一性をパス文字列で判定している (CLAUDE.md が名指しした形の再発)

- `crates/litedoc4-ir/tests/base_ir.rs:26` の `DEFAULT_IR = "/private/tmp/lean-doc-relay/w7h/base-ir"` と
  `:46-48` の `is_default_fixture` が `path == Path::new(DEFAULT_IR)`
- 偽なら `:304-310` で `eprintln!` して `return` し、**実測 20 件の検査を落として構造検査だけで緑になる**
- **CLAUDE.md が【実測 2026-08-16、`link_index_fixture`】として記録している形そのもの** —
  「既定パスに別物を置いた瞬間に主張の強さが黙って変わる」
- **しかも `/private/tmp/lean-doc-relay/` は再生成される作業領域**で、
  別世代の IR が同じパスに立つのが正常運用 (CLAUDE.md 自身が「誰も消さないので溜まる」と書いている)
- **逆向きにも壊れる**: 末尾スラッシュや symlink 経由のパスを渡すと、
  正しいフィクスチャなのに検査が弱い側へ黙って落ちる。`:375` の astral テストは同じ判定で
  `assert!(checked > 0)` を落とすので、**「UTF-16 とバイトオフセットを区別する span が
  1 つも無かった」を見逃す側に転ぶ**
- 直し方: **中身で判定する** — `index.generator` + `lean_version` + `module_count` +
  `declaration_count` の 4 つ組 (`:338-339` が既に個別に検査している値) を照合する。
  `crates/litedoc4-global/tests/global.rs:1094` の `fnv1a64` 方式でもよい

### D13 — 「`..` は通り抜けられない」という論証が実装と矛盾し、render 側にはガードが無い

- `crates/litedoc4-incr/src/prune.rs:133-135` が
  「A name cannot smuggle a `..` through it — the dots that would spell one are exactly the
  characters this replaces」と書く。**その 6 行下 (`:138-140`) で実装がそれを否定している**
  (「`litedoc4_ir::module_path`, not `replace('.', "/")` (M5-b)」)
- `module_path` は `module_components` 経由で **`«…»` の中のドットを分割せず**、
  `unescape_component` が括弧を剥がす。したがって
  **`«..».Foo` → components `["..", "Foo"]` → `page_of` = `"../Foo.html"`。ドットは残る**
- 同じ論証が `prune.rs:161-163` と `detect.rs:656-659` にもある (計 3 箇所)
- **帰結が非対称**: prune は `PageRoot::resolve` が `..` を見つけて exit 3 で拒否する (安全側)。
  **一方 render 側には同じガードが無い** — `render/src/site.rs:219` の
  `options.pages.join(page_path(m))` は `PathBuf::push("..")` が素通りするので、
  **`<pages>/../Foo.html` = サイトルートの外に書く**。
  **書く側は外に書き、消す側は拒否する**
- 入力は珍しい (`Foo/...lean` のようなソース名が要る) が、**M5-b 自体が
  「2 つ目の対象がこれで壊れた」から生まれた節**
- `tests/impact.rs:1934` の `page_of("../../etc/passwd")` は
  **Lean のモジュール名ではないので反例になっていない**
- 直し方: 3 つの doc を実測に合わせる (「ドットが消えるから届かない」→
  「`«…»` を経由すれば `..` は作れる。だから `PageRoot` はコメントではなく検査である」)。
  そのうえで **`«..»` を含むモジュール名を curated テストに足す**。
  **render 側にガードを入れるかは段 3 の X1** (`page_path` の共通化) で判断する —
  `litedoc4-ir` に 1 本置くとき、`..` を含む結果を作らないことをそこで検査できる

### D14 — `litedoc4-global` の doc が M8-d / search-v2 / C-2 の前で止まっている (8 箇所)

- `artifacts.rs:3-12` のファイル一覧が **8 件**。定義 (`:169-179`) は **9 件**で、
  `declarations/used-by.json` が抜けている。**これは新しいファイルを足すときに最初に読まれる表**で、
  1 件足りないと 10 件目を足す人が `ARTIFACT_PATHS` / `files()` / `derive` の 1 つを忘れる
- 他: `lib.rs:10` "seven files" / `lib.rs:25` / `site.rs:48` "the other six artifacts" /
  `site.rs:103` "`search-index.json`'s `instancesFor`" (**search-v2 P0 で `instances.json` に出た。
  同じ値の `artifacts.rs:157` は正しく書いている**) / `facts.rs:30` "M8-d added a seventh field"
  (`instances_for` は 8 番目) / `facts.rs:33` / `artifacts.rs:227`
- **同じ grep に引っかかるが触ってはいけないもの**: `merge.rs:46` の
  「six whole-package artifacts derived: 438 of 438 files byte-identical, 31,617,612 B」と
  `facts.rs:348` の「the six artifacts and the state file are byte for byte …」は
  **どちらも【実測 2026-08-12】の記録**で、当時の母数。
  CLAUDE.md「完走しなかった計測を完走したように書かない」により**更新してはいけない**
- 併せて `crates/litedoc4-ir/src/metrics.rs:27` — 「**every read of the IR is in this crate**」と
  太字で書くが、同じファイルの `:33-40` が「Three call sites are outside this crate」と書く。
  決着は `reader.rs:156-163` にある:
  「the claim as originally written … was **false**」【実測 2026-08-16】。
  **「予測と結果が食い違ったら結果が SoT」の未適用。`reader.rs` 側は正しいので触らない**


## 4. 段 1 — `crates/litedoc4` (bin) の構造

**最大のクレートで、最も安全網が厚い (テスト 6,038 行 + ファイル内 1,880 行)。ここから始める。**

### 結果 — **9 項目すべて決着**【2026-08-23】

| | 内容 | commit |
|---|---|---|
| R1 | `main.rs` 1,773 → 57 行 | `5ec473c` |
| R2 | CLI パーサ 13 本 → `cli.rs` (+181/-324) | `18d5a18` |
| R3 | containment ガード 5 箇所 → `refuse_inside` | `5f22ed1` |
| R6 | `EXIT_REFUSED` 22 箇所 + `Failure::io` 29 箇所 | `26bc455` |
| R4 | `site`/`render` の入り口 → `render_inputs` | `864ce35` |
| R5 | `write_file` 5 綴り・定数 2 重定義・`events_beside` | `dec8e17` |
| R8 | 構造体引数と `enum Ran` | `e2b0d2c` |
| R7 | **範囲を絞った** — `gaps` だけ | `25b990b` |
| R9 | **1 本入れて 1 本捨てた** | `428bd85` |

`cargo test --workspace` は **439 → 442 passed** (足したテスト 3 本)。

**2 つは計画どおりに入らなかった。どちらも「測ってから絞った」**:

- **R7** — `run_incremental` を測ったら 395 行中 115 行 (29%) が順序制約のコメントで、
  段は 1 つ 38 行しかなかった。切り出しても**その関数を単体でテストできない**
- **R9** — 両方向のうち片方は、**何を数えているか自分で説明できなかった**

**この段で 1 度も起きなかったこと**: 出力バイトが動く変更。
`RENDERER_ID` は `v4` のまま、凍結フィクスチャとの比較テストは全部緑。

### R1 — `lib.rs` を作る【この段の土台。他の R より先】

- **今**: クレートルートが `main.rs` で、`Failure` / `usage` / `USAGE` / `refused` /
  `LINK_INDEX_COST` がそこに定義され、**9 モジュール中 8 つが `use crate::{…}` で取りに行く**。
  逆に `build.rs:1053` は `crate::site_config`、`:1054` は `crate::generate_site`、
  `pipeline.rs:785` は `crate::print_render_summary` を**呼び返している**
- **帰結が 3 つ**:
  1. **サブコマンド 14 本のうち 9 本の本体が `main.rs` にあり、5 本だけがモジュールを持つ。**
     基準が無いので次のサブコマンドをどちらに書くかは毎回判断になる
  2. `packages.rs` が src 内に **718 行のテスト**を抱える (ファイルの 58%)。
     `read_manifest` / `module_roots` / `unquote` が `pub` でないので `tests/` から届かないため
  3. 統合テスト 6,038 行が**全部 `Command::new(BIN)` でプロセスを起こす**。
     パーサの単体テストすら 1 プロセスぶんのコストを払う
- **やること**: `src/lib.rs` を作り、`Failure` / `usage` / `refused` / `USAGE` / 定数 / 各 `mod` を移す。
  `main.rs` は `fn main()` と `run()` のディスパッチだけにする。
  `main.rs` に残る 9 本のサブコマンドは `stages.rs` (site/render/global) /
  `queries.rs` (ownership/merge/impact/prune/links) / `ledger.rs` に分ける
- **忘れると CI が落ちるもの**: `packages.rs` のテストを `tests/` に出すと
  `#[ignore]` 名が `litedoc4::packages::tests::…` から変わる。
  **`tools/corpus-tests.txt` の 3 行を同じコミットで更新する** (CI が `--verify-list` で両方向に見ている)
- 規模: **移動が中心で約 600 行。新規はほぼゼロ。** テストの書き換えは**やらなくてよい**

#### 結果【2026-08-23】

**`main.rs` は 1,773 行 → 57 行。** 分けた先は計画どおり `lib.rs` (569) /
`stages.rs` (387) / `queries.rs` (625) / `ledger.rs` (255)。

- **予告した罠は発火しなかった** — `tools/corpus-tests.txt` の
  `litedoc4::packages::tests::*` 3 行は**そのままで緑**だった。
  lib の test target 名は crate 名 `litedoc4` で、bin だったときと同じだったため。
  **`--verify-list` を実際に回して確かめた**のであって、読んで大丈夫だと判断したのではない
- **`pub` にした範囲は 14 項目**: `Failure` / `USAGE` / `usage` と、
  `run()` が呼ぶ 13 のサブコマンド。`pub(crate)` のままで済んだものは動かしていない
- **`build.rs:1054` の `crate::generate_site` が `crate::stages::generate_site` になった** —
  逆向きの依存 (モジュールが `main.rs` を呼び返す) は、これで 3 本とも消えた

### R2 — CLI 引数パーサを 1 本に (13 本 / 約 670 行 = src 実体の 8%)

- **今**: 13 箇所が同じ骨格を持ち、`value` クロージャは**バイト単位で同一**。
  `--help` アームが 12 回、unknown アームが 13 回、数値パースが 4 回
- **`--help` の綴りが既に 3 通りに割れている**: `main.rs` の 9 本は `Ok(())`、
  `build.rs:432-435` は `Err(Failure::Answered(0))`、`watch.rs:204-207` はパース前の事前スキャン
- **やること**: `crate::cli` に (a) `Args<'a>` — `next()` / `value(flag)` / `number(flag)` / `path(flag)` を
  持つ薄いイテレータラッパ、(b) `help_or(args)`、(c) `unknown(arg) -> Failure` を置く。
  各サブコマンドの `match` アームはそのまま残す
- **畳まないもの**: by-name refusal のメッセージ群
  (`main.rs:751-769` / `build.rs:377-427` / `pipeline.rs:961-1013` / `extract.rs:141-174`、計 200 行超)。
  **これは製品の出力そのもので、短縮は仕様変更**
- 規模: `cli` 約 80 行、13 箇所から約 200 行削減

#### 結果【2026-08-23】

`crates/litedoc4/src/cli.rs` (89 行) を置き、**7 ファイルで +181 / -324 = 正味 -143 行**
(`cli.rs` 自身を除けば -232)。

- `Args::new` / `value` / `number` / `help` / `unknown` の 5 つ。**`match` のアームは動かしていない**
- **`--help` は 11 箇所を揃え、3 箇所は揃えなかった**【判断】 —
  `build.rs:412-418` は `Err(Failure::Answered(0))` を返し、**その理由がすぐ上に書いてある**
  (「this function's `Ok` is a request to run, and `--help` is not one」)。
  `watch.rs:204` はパース前の事前スキャン。**「3 通りに割れている」は正しかったが、
  割れていること自体は意図的だった** — `cli.rs` の docstring にそう書いた
- `Args::next` を `Iterator` にはできない — `for arg in args` が全体を借りてしまい、
  ループの中で `value()` が呼べない。**最初 `#[expect(clippy::should_implement_trait)]` を
  付けたが、clippy が「この expectation は満たされない」で落とした** — この lint は
  公開項目にしか発火せず、`pub(crate)` には来ない。**`#[expect]` が仕事をした形**なので、
  理由はコメントに移した

### R3 — 「対象の中に書こうとしていないか」のガードを 1 本に (5 箇所)

- **今**: `extract.rs:266-277` / `extract.rs:280-293` / `pipeline.rs:1270-1287` /
  `resident.rs:727-741` / `build.rs:521-533` の 5 箇所が
  `resolve(p).starts_with(target)` → exit 3 を手書き。メッセージ文字列は 4 箇所でほぼ同文
- **これは M4-c で実際に漏れた経路の再発防止** = セキュリティ相当の不変条件。
  CLAUDE.md「修正を一般形に引き上げたか、毎回問う」がまさにこの形のために書かれている
- **やること**: `refuse_inside(container: &Path, candidate: &Path, what: &str) -> Result<(), Failure>` を
  1 本置いて 5 箇所を寄せる。**D7 の docstring 入れ替えを同時に直す**
- **同時に消える型の弱さ**: `resident.rs:727` の `guard_target(target: &Path, ir_dir: &Path)` は
  **引数を逆にすると「対象が IR ディレクトリの中にあるか」を聞くことになり、常に false を返して
  黙って通る**。`refuse_inside` に寄せれば引数名が役割で固定される
- 規模: 新関数 20 行、5 箇所で正味 -60 行

#### 結果【2026-08-23】

`crates/litedoc4/src/extract.rs` に `refuse_inside(container, container_flag, candidate, what, extra)`。
**5 ファイルで +59 / -62**。`build` の長い追記 (「Copy <out>/site into the repository afterwards」)
は `extra` で渡すので、文言は 1 バイトも変わっていない。

- **`resident::guard_target` の引数入れ替え問題も消えた** — 中身が
  `refuse_inside(target, "the target", ir_dir, …)` の 1 行になり、
  役割が引数名で固定された
- **`EXIT_REFUSED` を先に置いた** (R6 の項目) — `refuse_inside` が `code: 3` を書くので、
  そこだけ literal を残す理由がなかった。**残り 22 箇所は R6 で**

### R4 — `site` と `render` の入り口 60 行を共有する

- `main.rs:717-833` (`site`, 117 行) と `main.rs:1602-1693` (`render`, 92 行) が
  7 フラグを同一に解釈し、続く検証も同一。`--source-url` の拒否文は
  `main.rs:786` / `main.rs:1664` / `pipeline.rs:1042` の **3 箇所に同一リテラル**
- **なぜ危ないか**: M4-d ゲートは「site と render が同じ IR から同じバイトを書く」ことを
  出力ツリーの比較で見る。**両方に同じ間違ったフラグ解釈を渡せば一致してしまう。**
  `generate_site` (`main.rs:858`) は「a shared function turns that from a thing to measure into
  a thing to state」という理由で既に共有されている — **入り口の 60 行だけが取り残されている**
- やること: `RenderRequest` + `parse_render_request`。拒否文は `const SOURCE_URL_REQUIRED`

#### 結果【2026-08-23】

`lib.rs` に `SOURCE_URL_REQUIRED` と `RenderInputs` / `render_inputs(…)`。
**3 ファイルで +67 / -34** (新しい関数と doc を含む。`stages.rs` 単体では -14)。

- 寄せたのは**入力の検証と解決だけ** — `--source-url` の非空、`--link-index` の排他、
  `external` と `config` の解決。フラグの `match` アームは 2 つとも元のまま
- 拒否文の 3 つ目 (`pipeline.rs:1022`) も同じ定数に寄せた

### R5 — ファイル書き込み・定数・`events_beside` を 1 箇所に

- `write_file` が **5 綴り**: `build.rs:1473-1478` と `pipeline.rs:1751-1756` は**バイト単位で同一**、
  `main.rs:633/825` はインライン、`deps_docs.rs:709` と `extract.rs:537` は別綴り
- `EXIT_EXTRACTOR = 4` が `extract.rs:63` と `pipeline.rs:165` の **2 定義**。
  `pipeline.rs:160-165` の docstring は**この値が他と衝突しないこと**を根拠にしているので、
  2 定義はその根拠を 2 箇所で保つことを要求する
- `DEFAULT_MAX_ROUNDS = 5` が `build.rs:173` と `pipeline.rs:168` の 2 定義
- `events_beside` が `resident.rs:683-689` と `extract.rs:298-304` に同一式。
  **皮肉**: `resident.rs:253-256` のコメントが
  「both extraction paths have to leave the events file in the same place under the same name or
  two records of the same run stop being comparable」と書いている
- やること: `crate::fsx` に `write_file` / `create_dir` を集約。定数は `lib.rs` に 1 本ずつ。
  `events_beside` は `extract.rs` に置いて両方から呼ぶ

#### 結果【2026-08-23】

**`fsx` は作らなかった**【判断】 — `pipeline::write_file` / `create_dir` / `write_lines` が既にあり、
新しい住所を作るより**そこへ寄せる方が移動が少ない**。定数も同じで、`EXIT_EXTRACTOR` は
`extract.rs` に、`DEFAULT_MAX_ROUNDS` は `build.rs` に 1 本ずつ残して `pipeline` が `use` する。

4 種類とも 1 本になった【実測: `rg -c` が各 1 件】:
`write_file` (pipeline) / `EXIT_EXTRACTOR` (extract) / `DEFAULT_MAX_ROUNDS` (build) /
`events_beside` (extract)。`stages.rs` のインライン書き込みと `extract.rs` の
`create_dir_all` 3 箇所も同じ関数に寄せた。

### R6 — exit 3 に名前を与える

- `Failure::Refused { code: 3 }` が **27 箇所ハードコード**。定数を持っているのは 4 と 5 だけ
- exit 3 = 「世界とファイルが食い違っている」= **最大の分類なのに名前が無い**。
  `main.rs:355-359` に書かれた契約 (「a pipeline that treats "the ledger is stale" the same as
  "the disk is full" retries the wrong thing」) が grep でしか追えない
- `format!("{}: {source}", path.display())` が 27 箇所、束縛名が `|e|` 13 / `|source|` 43 に割れている
- やること: `const EXIT_REFUSED: u8 = 3;` + `Failure::refused()` / `Failure::io(path, source)`。
  機械置換で済む。**挙動不変**

#### 結果【2026-08-23】

`EXIT_REFUSED` は R3 で先に置いた。この段で **`code: 3` の残り 22 箇所**と、
**`Failure::io` に寄せた 29 箇所**。10 ファイルで +76 / -76 — 行数は変わらず、綴りが 1 つになった。

- `|e|` と `|source|` の 2 綴りは `|source|` に統一
- **`cargo clippy --fix` を使い、その差分を読んだ**【CLAUDE.md「--fix の結果を読まずに信じない」】 —
  変えたのは `&path` → `path` の `needless_borrow` 6 箇所だけで、
  診断にも制御フローにも触っていないことを `git diff` で確かめてからコミットした

### R7 — 巨大関数から「非本質」を抜く

上位 11 本で 1,875 行 (src 実体の 21%)。**ただし全部を割るのではない。**

| 行 | 場所 | 扱い |
|---:|---|---|
| 387 | `pipeline.rs:431` `run_incremental` | **順序そのものが関数の内容**。割らない。抜くのは下の 3 つ |
| 337 | `pipeline.rs:866` `incremental` | R2 で 1/3 短くなる |
| 319 | `extract.rs:69` `extract` | 同上 |
| 303 | `build.rs:272` `parse` | 同上 |
| 193 | `main.rs:1052` `ledger` | **D1 で 3 関数に割る** |
| 177 | `build.rs:641` `run` | 様子見 |
| 159 | `watch.rs:272` `run_loop` | 様子見 |

- `run_incremental` から抜くのは **(a) 各段の `Instant` 積算 (b) 診断ファイルの書き出し
  (c) ログ行の組み立て** の 3 つだけ。これらが段の判断の間に挟まっているので、
  6 つの順序制約を読み取るのに 387 行の通読が要る
- `struct Clocks` に `phase<T>(&mut self, name, f: impl FnOnce() -> T) -> T` を持たせて時計を 1 箇所に。
  段の本体を `detect` / `rounds` / `render_set` に切る。**順序は `run_incremental` に残す**

#### 結果【2026-08-23】— **範囲を絞った。予測より抜けるものが少なかった**

まず測った: `run_incremental` は **全 395 行のうちコメントが 115 行 (29%)**、実コードは 264 行。
そのコメントは「Constraint 2: this runs **before** the renderer because…」の類で、
**関数の内容そのもの**。7 段に分けると 1 段あたり実コード 38 行しかない。

入れたのは **`gaps` だけ**:

```rust
fn gaps<const N: usize>(marks: [Duration; N]) -> [f64; N]
```

`Timings` の組み立ては **6 つの `saturating_sub` がそれぞれ自分の前任を手で名指し**していた
(`prune_done.saturating_sub(rounds_done)` …)。順序は既に配列が持っているので、
**前任を書く場所を 6 つ消した**。単体テストを 2 本足している (機材ゼロ依存)。

**残る 3 つは入れなかった**【判断】:

- **段の本体を関数に切る** — 切っても**その関数を単体でテストできない** (すべて I/O を伴う)。
  §15 の撤退ライン 2「テストを書けない整形はやらない」に当たる
- **診断ファイルの書き出し / ログ行** — 段の判断と結びついている
  (prune のログは prune の結果を報告する)。抜くと呼び出し順の制約が増える

**`Clocks` は作らなかった** — `phase(name, f)` はクロージャで段を包む形になり、
`?` の伝播と借用が段ごとに違うので、包める段と包めない段が出る。
**「7 段のうち 4 段だけ包まれている」形は、時計が 1 箇所にある状態より読みにくい。**

### R8 — 型の弱さ

- `pipeline.rs:1377` `link_index_key(target: &Path, omit: &Path)` — 逆にすると token が別物になり
  `.lidx` の再利用判定が静かに壊れる
- `extract.rs:477` `fold_timings(events, modules, jobs, out)` — 第 1・2・4 が同型。
  `struct Timings<'a>` にする (このクレートは `RenderOptions` / `CheckOptions` で既にその流儀)
- `pipeline.rs:1464` `write_timings(…, serve: Option<&(usize, String)>)` — 匿名タプル。
  `enum ExtractorKind { OneShot, Resident { jobs, generation } }` にすれば `Extractor` enum の情報が落ちない
- `main.rs:469` `LinkRow.deep: Option<(String, String)>`
- **`Layout` (`build.rs:176`、9 個の `PathBuf`) は据え置き** — 生成が `Layout::new` 1 箇所に閉じていて
  費用対効果が低い

#### 結果【2026-08-23】

3 つ直した。**`Layout` は予告どおり触っていない。**

- `fold_timings(events, modules, jobs, out)` → `fold_timings(&Folded { … })`。
  同型 3 つが名前で区別されるようになった (`RenderOptions` / `CheckOptions` と同じ流儀)
- `write_timings(…, serve: Option<&(usize, String)>)` → `enum Ran { OneShot, Resident { jobs, generation } }`。
  **3 つの事実を 1 つの `Option` に畳んでいたのをやめた** — `Extractor` enum の形をそのまま写す
- `link_index_key(target, omit)` → `(package, omit_list)`。
  **最初は引数名だけ変えて本体で旧名に再束縛したが、それは名前を通したことにならない**ので、
  本体まで書き換えた。Rust の位置引数は名前で守られないので、これは読み手のための変更

### R9 — `USAGE` (254 行) とパーサ 13 本の一致を検査する

- **今日時点で乖離ゼロ**【調査担当が機械照合で実測】。ただし `USAGE:120` は `ledger touch` を
  3 フラグと宣言し、パーサは 18 フラグ受理 = **USAGE の方が正しくパーサが緩い** (= D1)
- `litedoc4 modules --help` が 254 行を吐く (受け付けるフラグは 3 つ)
- やること: 各サブコマンドが `const *_FLAGS: &[&str]` を持ち、`--help` は該当節だけ印字。
  `#[test]` で FLAGS と USAGE 節の一致を検査。
  **作る前に必ず一度落とす** — D1 を直す前なら `ledger` で落ちるはず
- **D1 で土台ができた**【2026-08-23】: `LEDGER_FLAGS`（今は `ledger.rs`）が
  「どのフラグをどのサブコマンドが受けるか」を持つ

#### 結果【2026-08-23】— **1 本入れて 1 本捨てた**

**`--help` の節分割はやらなかった**【判断】 — 出力が変わる = §2.1 の原則 1 に反する。
**各サブコマンドの `const *_FLAGS` も書かなかった** — 14 個の定数は
「一致させ続ける 3 つ目の場所」になる。

入れたのは `lib.rs` の `mod usage_tests` の **1 本**:

- **`every_documented_flag_is_parsed`** — `USAGE` が名前を挙げるフラグは、
  どこかの `match` アームに存在する。**`--nonesuch` を足して一度落としてから通した**

**捨てたのは逆方向**（「パーサにあって `USAGE` に無いものの件数を固定」）。
理由は**自分で数を説明できなかった**こと: 実装を変えるたび 18 → 20 → 33 と動き、
33 件には**この検査自身の docstring に書いた `"--a" | "--b"` という例**が入っていた。
**ソースの文字列パースは `match` アームとコメントを区別できない。**
CLAUDE.md「落ちたときに何が壊れたか 1 行で言えないゲートは足さない」に従って削り、
残した 1 本の docstring に**その限界**（`PARSED` は超集合であること、
だから片方向にしか使えないこと）を書いた。

**一般形**: 同じ「両方向を見る」でも、`corpus-gate.sh` が両方向を見られるのは
**cargo に実際のテスト名を聞いている**からで、ソースを読んでいないから。
データの出所が「実行時の事実」か「テキストの見た目」かで、検査の強さが決まる。

## 5. 段 2 — `litedoc4-render` / `litedoc4-md`

**調査担当の判定: この 2 crate の指摘 12 件はすべて出力バイトを動かさない。**
`unsafe` は md の FFI 境界に限定され、各ブロックが安全性を記述している。

### S1 — 1 つの宣言ブロックの中に「ページ root」の出所が 2 本ある【この段で最も重い】

- `crates/litedoc4-render/src/decl.rs:377-383` の `DeclRenderer` は `root: &'a str` を持つ
- ところが `decl.rs:603` の `decl_head_html` と `:604` の `decl_signature` は
  **中で `page_root(module)` を再計算する** (`decl.rs:298` / `:326`)
- 一方 `:646` (equations) / `:542` (継承フィールド) / `:530` (binder) は `self.root` を使う
- **つまり同じ `<section class="decl">` の中で、ヘッダと signature は片方の経路、
  equations とフィールドはもう片方の経路から root を取る。`DeclRenderer::new` は一致を検査しない**
- **同じ失敗形をこの crate は既に一度潰している**: `autolink.rs:744` の `PageLinks::renderer()` が
  「the root reaches the output through two paths … handing them different values would produce
  links that are half right」と書いて明示的に閉じている。**`decl.rs` 側に同じガードが無い**
- **今は壊れていない**【実測: `page-parts-expected.json` 216 ケース全件で両者一致、不一致 0】。
  壊れたときの症状は「ページの半分のリンクだけが違う階層を指す」で、リンク切れゲートが拾うまで無症状
- 副次: 宣言 1 件につき `page_root` が 2 回余分に呼ばれ `String` を 2 個割り当てる
  (422 ページ × 4,584 宣言)
- **やること**: 2 関数を `DeclRenderer` のメソッドにして `self.root` を読ませる。
  今これらが自由関数なのは `tests/page_parts.rs:178` の `head_and_signature()` が単体で呼ぶためなので、
  テスト側を `DeclRenderer` を組む形に寄せる。**最小手は `DeclRenderer::new` に `debug_assert_eq!`**

#### 結果【2026-08-23】— **メソッド化ではなく引数化で解けた**

`decl_head_html` / `decl_signature` に **`root` を引数として足した**。`DeclRenderer` は
`self.root` を渡し、2 つの関数は導出しない。**経路が 1 本になれば取り違えは起きない**ので、
メソッド化も `debug_assert_eq!` も要らなかった。

**副産物**: `decl_signature` から `module` 引数が落ちた — `page_root(module)` のためだけに
取っていたので、`root` を受け取ると使い道が無くなる。**clippy の `unused_variable` が教えた。**

### S2 — `PageRoot` の newtype を入れる (S1 の再発防止を兼ねる)

同型の `&str` が並ぶシグネチャが 7 箇所。**逆にしても型検査が何も守らない。**

| シグネチャ | 逆にしたときの症状 |
|---|---|
| `autolink.rs:447` `link_to(root, module, anchor)` | 全リンクが逆順パスに |
| `autolink.rs:90` `module_link(root, module)` | 同上 |
| `frame.rs:160` `head_html(module, root, site)` | `<title>` が `.././`、`href` が `Foo.Barstyle.css` |
| `frame.rs:144` `module_source_url(base, module)` | `Foo/Bar/https:/host….lean` |
| `decl.rs:113` `decl_name_to_link(name, root, …)` | 存在しない名前として `UnplaceableName` |
| `decl.rs:166` `fill_block(name, fill, summary)` | `data-fill` と `<summary>` が入れ替わる |
| `external.rs:147` `DepDocs::new(base, declarations, modules)` | **K/V 型引数を 2 引数で共有**していて型でも区別されない |

- `link_to` と `head_html` は**最も呼ばれる 2 本**。`link_to` は自ら「the only copy of the decision」と名乗る
- **やること**: `#[derive(Clone, Copy)] pub struct PageRoot<'a>(&'a str)` を `autolink.rs` に置き、
  `page_root` がそれを返す。**`decl_head_html` が `PageRoot` を要求すれば S1 の「導出し直す」が
  そもそも書けなくなる**

#### 結果【2026-08-23】— **やめた。見積もりを外した**

`RootHref<'a>(&'a str)` を入れ、`link_to` / `module_link` / `head_html` / `topbar_html` /
`sidebar_html` / `module_meta_html` / `const_link` / `fragment` / `PageLinks::root` /
`DeclRenderer::root` まで通した。**lib はコンパイルが通った** — 型で分ける価値も確認できた:
`external.rs` の `base_for(root: &str)` の `root` は**モジュールルート**で、
ページルートとは別物だった。

**壊れたのは呼び出し元のリテラルを包む段。** `"../"` を `RootHref::new("../")` に替える対象は
**文脈でしか判別できず、正規表現には文脈が無い**。`lean_quote("./")` のテストや
`trim_start_matches("./")` まで包み、エラーが 47 → 134 に増えたところで `git stash` に退避した。

**見積もりの誤り**: 計画は「80〜120 行」と書いたが、実際は**呼び出し元 60 箇所超を
1 つずつコンパイラに挙げさせて手で直す**規模。S1 が引数化で解けた以上、
**この型が今すぐ要る理由は無い** — 再開するなら段 2 の外で、独立した作業として。
退避した差分は `git stash list` の "S2 の RootHref" に残っている。
- `fill_block` は `enum Fill { InstancesFor, Instances, UsedBy }` にすれば
  `data-fill` と `<summary>` が 1 箇所で対になる
- `DepDocs::new` は K/V を 2 組に分けるか、builder メソッドを 2 本に分ける

### S3 — `decl_refs` が 1 宣言あたり 2〜3 回作り直される

- `decl.rs:602` (`decl_html`) が作った直後に `:327` (`decl_signature`) が作り直し、
  structure/class は `:418` で 3 本目、inductive は `:463` で 3 本目
- `decl_refs` は `HashMap::with_capacity(decl.refs.len())` を確保して全件挿入。
  Mathlib 依存では 1 宣言の `refs` が数十〜数百件。**422 ページ × 4,584 宣言 × 2〜3 回**
- **§6.4 が名指しする「やらなくてよい仕事」のカテゴリ**。加えて「同じ入力から同じ表を 3 回作る」は
  片方だけ入力が変わったときに気づけない形
- やること: `decl_html` で 1 回だけ作り `refs: &Refs<'_>` として渡す。
  公開関数は薄いラッパにして本体を `_with` 版に分ける (S1 と同じ関数を触る)

### S4 — `ctor_html` と `field_html` が同じマークアップを 2 回書いている

- `decl.rs:483-511` と `:581-596`。差は `class="ctor"` か `class="field"` かだけ
- **`ctor_html` の doc コメント自身が「Deliberately the same shape as [`Self::field_html`]'s
  second branch」と書いている** — 判断を宣言しておきながら、その形が 2 箇所に手書きされている
- `assets.rs:197` のスタイルシートゲートは「クラスが CSS にあるか」しか見ないので、
  片方の `<div class="field-sig">` を消してももう片方は緑
- やること: `member_li(…, li_class, id: Option<&str>, short, args, body, doc)` を 1 本置く。
  `decl.rs:37` の「Attribute order is byte identity」の注記は**継承分岐の `id` の有無**についてなので、
  `id: Option<&str>` を取る形なら維持できる
- **統合後は `tests/page_parts.rs` の凍結フィクスチャと `decl.rs:1144-1310` の単体テストを必ず走らせる**

#### 結果【2026-08-23】— **開始タグは共有しない。ゲートが教えた**

計画どおり `member_li(…, li_class, id, …)` を書いたら、**スタイルシートゲートが落ちた**:

```
the renderer writes classes the stylesheet says nothing about: [
    "decl.rs: .\");",
    "decl.rs: .out.push_str(\"",
    "decl.rs: .out.push_str(li_class);",
]
```

`class=\"` の直後がソース上で `");` になったため。**ゴミを拾ったことより重いのは、
`ctor` と `field` というクラス名がゲートから見えなくなったこと** —
`every_class_the_renderer_emits_is_styled` はこのファイルの**テキスト**を読むので、
パラメータの向こうにあるクラス名は検査できない。

**採った形**: 共有するのは `<li>` の**中身**だけ (`member_body`)。開始タグ
(`<li id="…" class="ctor">`) は呼び出し元に残す。
`ctor_html` の doc が言う「同じ形」は事実になり、クラス名のリテラルはゲートから見えたまま。
**15 行の重複を消すために、動いているゲートの目を潰さない。**

### S5 — スタイルシートゲートが TypeScript の付けるクラスを見ていない

- `assets.rs:196-233` は `frame.rs` / `page.rs` / `decl.rs` / `code.rs` の 4 ファイルの
  文字列リテラル中の `class=\"…\"` だけを集めて `style.css` と突き合わせる
- 実際には TS が実行時に **8 クラス**を付ける: `count` (`imported-by.ts:9`) /
  `search-empty` (`instances.ts:39`, `search-box.ts:37`) / `kind`,`where` (`result-item.ts:13,18`) /
  `row`,`twisty`,`twisty-spacer`,`node-name` (`tree.ts:47,57,68,81`)【実測: 8 件とも今は style.css にある】
- **このテストの存在理由は「失敗が沈黙する」こと** (クラス名を変えてもレンダリングは通り、
  検証も通り、スタイルだけ消える)。その沈黙は Rust 側と TS 側で完全に同じなのに片側しか見ていない。
  `assets.rs:193-195` は md を除外する理由を書いているが **web/ については何も言っていない = 漏れ**
- やること: TS 用に `className = "…"` / `classList.add("…")` を拾う 2 本目のスキャナ。
  **作った当日に一度落とす** (`.count` を CSS から消して赤くなるのを見てから戻す)

#### 結果【2026-08-23】

`assets.rs` に `scripted_classes` を足し、`web/src` の 5 ファイルを `include_str!` で読む。
**`x.className = "name"` の 1 形だけを見る** — `rg` で確認した結果その綴りしか無く、
**推測で広げると「見ている」と言えない範囲まで主張することになる**。
空振りしないことは `from_scripts >= 8` で固定した。

**予告どおり一度落とした。そこで計画の数字が 1 つ違っていたと分かった**:
`style.css` から `.count` を消すと、ゲートは

```
"frame.rs: .count",
"web/src/imported-by.ts: .count",
```

の**両方**を挙げた。`.count` は Rust 側 (`frame.rs`) も出していたので、
**未検査だったのは 8 クラスではなく 7 クラス** (`search-empty` / `kind` / `where` /
`row` / `twisty` / `twisty-spacer` / `node-name`)。**落としてみなければ分からなかった。**

### S6 — `PageLinks::name_to_link` が公開 API 上で panic する

- `autolink.rs:795-799` の `.expect("a declaration of this page is in the name index")`
- `PageLinks::new(index, root, decl_names)` は `decl_names` を任意の `&[&str]` として受けるので、
  **不変条件が呼び出し規約でしか守られていない**。`# Panics` 節も無い
- このクレートは全体として「推測せず `Err` を返す」方針 (`UnplaceableName` がその象徴、
  `decl.rs:31-33` が理由を書いている) なのに**ここだけ panic する**
- フィクスチャの `decl_names` に `known` へ入れ忘れた名前が 1 つ混じると、
  **バイト差分ではなく panic で落ちる** = 「ゲートが壊れた」に見えて壊れているのは入力
- やること (2 択): (a) `# Panics` を書き、`debug_assert!` を **`new` に置いて構築時に落とす** /
  (b) `NameIndex::page_links(root, module: &ModuleFile)` にして `decl_names` を内部で作る。
  合成ケース用に `new_unchecked` 相当は残す

#### 結果【2026-08-23】— **(a)。不変条件は本番でしか成立していなかった**

(a) を採った。(b) は `decl_names` を内部で作っても**そのモジュールが builder に入った
保証にはならない**ので、不変条件を立てられない。

**計画は「呼び出し規約でしか守られていない」と書いたが、実際にはそれより弱かった。**
`new` に検査を置いたら **9 本落ちた**:

- `decl.rs` のテスト 8 本は、`index(&[])` (空の索引) と `module_with(…)` を組んで
  **自分のモジュールが索引に無いページ**を描いていた。**run が作れない世界**なので
  ハーネス側 (`Page::new`) を直し、`render_site` と同じく自モジュールを builder に入れた。
  **出力バイトは動かない** (フィクスチャの型は `Nat` の平文、docstring に名前リテラルが無い)
- 残り 1 本は凍結オラクル (`tests/autolink.rs` / `tests/page_parts.rs` の `Case`)。
  こちらは**直せない、直すべきでもない**: フィクスチャの `known` は各 case の docstring が
  要る名前しか持たず、**`declNames` 2,492 件中 2,263 件が `known` の外**【実測 2026-08-23】。
  スライスはフィクスチャの形であって配線ミスではない

**だから計画が予告した `new_unchecked` が要る**、が理由は「合成ケース」ではなく
**「世界がスライスである」**こと。本番に該当は無い — `site.rs:172-174` が IR の全モジュールを
builder に入れてから 1 ページも描かない。

`# Panics` は `new` に書いた。`expect` は release 側の後退線として残る。

### S7 — 公開 API の棚卸し (render 22 件 / md 3 件)

- **`publish = false` なので「外部利用者のため」は成立しない** — ワークスペース内が全消費者
- **対称性が崩れている**: `decl::used_by_html` (`decl.rs:162`) **だけ**が re-export から漏れている。
  同じ `fill_block` を共有する `instances_for_html` / `class_instances_html` は両方出ている。
  3 つ書いて 2 つ出す理由がコード上どこにも無い
- **同じ判断の 2 本目**: `order::sort_names` は re-export 済みで未使用、一方 `frame.rs:362` は
  `out.sort_by(|a, b| cmp_name(a, b))` と手書き
- やること — **3 分類する**:
  (a) 定数で意味の SoT がここにあることに価値があるもの (`DIGEST_MARKER` / `DOCS_DIGEST_MARKER` /
      `EQUATION_LIMIT` / `CONFIG_FILE` / `PRIVATE_PREFIX`) → `lib.rs` に理由を 1 行ずつ書いて残す
  (b) `pub mod` 経由で到達可能なもの → `pub use` から外す (テストからは引き続き触れる)
  (c) `sorted_imports` → `frame.rs:362` を `sort_names` 呼び出しに替えてから `pub` を落とす。
      `used_by_html` は (a)(b) どちらに寄せるか決めて**兄弟 3 つを揃える**

#### 結果【2026-08-23】— **「他 crate が使うか」は grep では決まらない**

**見出しの「render 22 件 / md 3 件」が何を数えたのかは読み取れない。数えたのは re-export で、
render 68 件 / md 18 件**(結果が SoT)。判定は全部コンパイラに出させた — 候補を落として
`cargo check --workspace --all-targets --exclude <当該 crate>` を通し、
**他 package が要るものだけがエラーとして名乗り出る**形にした。

| | render 68 | md 18 |
|---|---|---|
| (a) 意味の SoT として残す (理由 1 行付き) | **5** | 0 |
| 他 crate が実際に import している | **16** | **5** |
| 私有モジュールなので re-export が唯一の経路 | 0 | **4** |
| (b) `pub use` から外した | **47** | **9** |

**grep 仮説が外したのは 5 件。4 件は同じ向きの外し方**: `NameIndex` / `is_letter_like` /
`escape_html` / `Suppressed` を「他 crate が使う」側に置いていたが、
**どの package も import していなかった**。`escape_html` がその典型で、
**`litedoc4-global` が使っているのは `litedoc4_md::escape_html` の方**。同じ名前が 2 crate に在る。

**5 件目は逆向きで、こちらが本命**: md の `parse_with_flags` は**落とせない**。
`mod parse` と `mod error` は**私有モジュール**なので、`pub use` が外部への唯一の経路であり、
外すと `unreachable_pub` が 4 件出る (`Error` / `Result` / `parse` / `parse_with_flags`。
warn → CI では `-D warnings` で error)。**`pub use` の理由は「他 crate が使う」だけではない** —
「他に経路が無い」がもう 1 つある。md の `lib.rs` にその 1 行を書いた。

**兄弟 3 つは揃った**: どの crate も使っていないので `instances_for_html` /
`class_instances_html` / `used_by_html` は**全部 (b)**。3 つ書いて 3 つとも `decl` に置いたままになり、
**re-export の有無で兄弟が割れている状態は消えた**。

**`sort_names` は書いた相手に届いた**: `frame.rs` の `out.sort_by(|a, b| cmp_name(a, b))` を
`sort_names(&mut out)` に替えた。どちらも `cmp_name` による安定 `sort_by` なのでバイト同値で、
**凍結プロトタイプとのバイト比較 `page_parts::frames_carry_the_same_content_as_the_prototype` が緑**。
`sorted_imports` は呼び出しが `module_meta_html` と自分のテストだけなので `pub` も落とした
(`unreachable_pub` を含め clippy は無言)。

**副産物 — intra-doc link 17 本が module パスに移った。うち 5 本は `cargo doc` だけが見つけた**
(4 本は `crate::CodeRenderer::…` のような CamelCase で、`crate::[a-z_]` の grep に映らない)。
**さらに 1 本は `cargo test` だけが捕まえた**: `md/src/math.rs` の doctest が
`litedoc4_md::to_mathml` を呼んでいた。**doctest は `--all-targets` に入らない**ので、
`cargo check --workspace --all-targets` は最後まで緑のままだった。

**直さなかったものが 3 種ある**【判断】: `render/assets/style.css:670` の
`litedoc4_md::to_mathml` は**出力バイト**なので触らない (パスは古くなる)。
`litedoc4/src/packages.rs` の `litedoc4_render::NameIndex::link_to` と
`litedoc4-md/src/html.rs` の `litedoc4_render::PageLinks` は**コードスパンでリンクではない**
(md は render に依存すらしていない) ので、この項目の範囲では触らない。

### S8 — `render_site` から I/O だけ抜く

- `site.rs:162-240` (79 行) が 5 責務を持つ。**ただし `NameIndex` の構築は
  「順序が振る舞い」と `site.rs:8-14` が明記しているので分解しない**
- 抜くのは `fs::write` + `create_dir_all` + `Error::Io` 包みの部分だけ。
  `assets.rs:99-105` に同型のコードがある (段 1 の R5 のこの crate 版)

#### 結果【2026-08-23】— **抜いた先にテストが無かったので 2 本書いた**

`site.rs` に `fn write_page(path, html) -> Result<(), Error>` を置き、`render_site` の
ループから 12 行を 1 行にした。**`assets.rs` とは共有しない**【判断】 — `write_assets` は
サイト直下を **1 回**作ってから N 個書くので、ファイルごとの `create_dir_all` は
既に在るディレクトリに対する syscall を資産の数だけ増やす。理由は `write_page` の doc に書いた。

**抜いてみて分かったのは、この 12 行を通るテストが `cargo test` に 1 本も無かったこと。**
`render_site` を呼ぶ非 ignore のテストは `pages.rs:208`
`an_empty_render_set_renders_nothing` だけで、これは**何も書かない**ことを見るもの。
残りは全部 corpus ゲート付き。だから 2 本足した:

- `a_page_is_written_under_directories_that_did_not_exist` — 成功経路。
  ページは**ドット付きモジュール名 1 つにつき 1 ファイル**なので、毎回まだ無いディレクトリに書く
- `a_directory_that_cannot_be_made_is_the_path_the_error_names` — **2 つの `map_err` が
  違うパスを持つ理由**そのもの。予告どおり一度落とした (`path: dir` を `path: path` に
  差し替えると赤くなる)。詰まらせる親には**このクレート自身の `Cargo.toml`** を使うので、
  この検査はどこにも書かない (`create_dir_all` がファイルを開く前に拒否する)

**副作用: 手書き `TempDir` が 14 → 15 になった** (`site.rs:323`)。下の U1 の数はそれで読む。

## 6. 段 3 — `litedoc4-incr` / `litedoc4-global` / `litedoc4-ir`

**この 3 crate は文書の密度が最も高く、規則違反 (`#[allow]` / 例外リスト付き比較器 / skip での緑) はゼロ。**
だから指摘は「**書いてある不変条件と、コードが今やっていることのズレ**」に集中する。
**段 0 の D0 / D11 / D12 / D13 / D14 はこの調査から出た** — それらを先に片付けてから入る。

### X1 — 「モジュール名 → ページのパス」の実装が 3 本、2 本しか突き合わされていない

- `incr/prune.rs:137-144` `page_of` (→ `String`) と `global/artifacts.rs:80-84` `page_path` (→ `String`) は
  **文字通り同一の 3 行** (`litedoc4_ir::module_path` + `push_str(".html")`)
- `render/page.rs:231-244` `page_path` (→ `PathBuf`) だけ `module_components` から組む別の書き方
- 突き合わせは `global/tests/global.rs:831-846` の `page_paths_agree_with_the_renderers` で
  **global↔render の 1 対だけ**。**`incr::page_of` はどれとも比較されていない**
- **ズレたときの症状**: 書く側は `render/site.rs:219`、**消す側は `prune.rs:238`**。
  ズレたら prune は「already absent」を報告して**死んだページを残す**
  (`prune.rs:138-140` のコメントが M5-b でまさにこれを踏んだと書いている)。
  global 側は `href` を出すので**4,750 本の死んだリンク**になる (`global.rs:827-829` が同じ理由を書いている)
- **やること**: `litedoc4-ir` に `pub fn page_path(module: &str) -> String` を 1 本置く
  (**incr の依存は `litedoc4-ir` だけ**なので、3 crate から届く唯一の場所)。
  `incr::page_of` と `global::page_path` はそこへの薄い再輸出に
- **render は触らない**【判断】— `PathBuf::from(String)` に変えると **Windows で `/` 区切りになる**
  (今は `\`)。`cargo test --workspace` は `ci.yml:50` の ubuntu-latest のみなので **CI では見えない**。
  代わりに `global.rs:831` の対比較テストを **3 本全部に広げる**

#### 結果【2026-08-23】— **広げられなかったので移した**

`litedoc4_ir::page_path` を 1 本置き、`incr::page_of` と `global::page_path` を
**その 1 行のラッパ**にした。**公開名は 3 つとも変えていないので呼び出し元は 1 箇所も動いていない。**
`render/page.rs:231` は予告どおり 1 バイトも触っていない。

**計画が外したのは住所**: 「`global.rs:831` の対比較テストを 3 本全部に広げる」は**その場ではできない** —
`litedoc4-global` の依存は `-ir` / `-md` / `-render` で **`-incr` が無い**。
**`litedoc4-incr` に依存しているのはワークスペース中 `litedoc4` (bin) だけ**なので、
3 本が同時に見える test crate はそこしかない。dev-dependency を足すのは
**テストのために依存を買う**ことなので取らず、**`crates/litedoc4/tests/page_paths.rs` を新設して移した**
【判断】。旧テストは消し、移設先を指すコメントを `global/tests/global.rs` に残した。

**一度落としてから通した** — `page_of` を M5-b 以前の `module.replace('.', "/")` に戻すと、
**まさに M5-b が踏んだ形**で落ちる:

```
assertion `left == right` failed: incr: Alpha.«Odd-Name»
  left: "Alpha/«Odd-Name».html"
 right: "Alpha/Odd-Name.html"
```

**`..` のガードは入れなかった**【判断、D13 が「X1 で判断する」と預けたもの】 —
`page_path` は `String` を返すだけで**何から逃げる path なのかを知らない**。
拒否できるのは木を持っている側 (`prune::PageRoot`) で、そこには既にある。
代わりに **`page_path("«..».Foo") == "../Foo.html"` をテストに固定した** (`ir/src/name.rs`) —
ガードの理由が黙って古くなることを防ぐのはこちら側の仕事。

**4 本目の綴りが見つかったが、これはオラクルなので触らない**:
`render/tests/ref_pages.rs:269` の test 内 `page_path(pages, module)` は `module.split('.')` の素朴形で、
**参照ツリーとの突き合わせのために独立に書かれている**。§16「潰す前に『これはオラクルか』を毎回問う」。

`cargo test --workspace` は **445 → 448 passed / バイナリ 38 → 39**
(新テスト 2 本 + `ir` の `page_path` 単体テスト 2 本、旧 global テスト 1 本を削除)。

### X2 — `KeySet` と `JsonObject` は同じ「順序を覚える map」を 2 回書いたもの (doc が自認している)

- `incr/ledger.rs:200-303` と `incr/merge.rs:214-277`。値の型 (`String` vs `serde_json::Value`) 以外は
  **`insert` の制御構造まで同一**。**`merge.rs:207-208` が自分で書いている**:
  「Same shape as [`crate::ledger::KeySet`], for the same reason」
- 約 50 行 × 2 の重複で、その中に**手書きの `Serialize` / `Deserialize` が 2 組**。
  **両方とも `ledger.json` / `index.json` のバイト列そのものを決めている** (片方だけ直る形)
- さらに `insert` の重複キー規則 (「最初の位置を保ち最後の値を取る」) が
  `merge.rs:773-782` (`module_map`) / `merge.rs:823-826` (`dep_mapping`) / `detect.rs:305-311` (`previous`) で
  **3 回別々に書かれている**
- やること: `incr/ordered.rs` に `pub struct Ordered<V>(Vec<(String, V)>)`。
  `pub type KeySet = Ordered<String>` / `pub type JsonObject = Ordered<Value>` で**再輸出名は保つ**。
  `KeySet::diff` は ledger 固有なので `impl Ordered<String>` に残す
- **これは「落として初めて意味がある」種の変更**なので、先に `Ordered` に置き換えて
  **既存の byte 比較テスト (`tests/ledger.rs` のプロトタイプ byte 比較、`tests/merge.rs` の round trip) が
  緑のままであることを確認する**

#### 結果【2026-08-23】— **壊してみたら、見たのは index 側だけだった**

`crates/litedoc4-incr/src/ordered.rs` に `Ordered<V>` を 1 本置き、
`pub type KeySet = Ordered<String>` を `ledger.rs` に、`pub type JsonObject = Ordered<Value>` を
`merge.rs` に置いた。**別名を元のファイルに残したので `lib.rs` の `pub use` 行は 1 文字も動いていない** —
`litedoc4_incr::KeySet` も `litedoc4_incr::ledger::KeySet` も従来どおりで、呼び出し元は 1 箇所も動いていない。
`KeySet::diff` は **`ledger.rs` の `impl Ordered<String>` に残した**【判断】 — doc が
`--render-all-out` / plan §5 M3 / `ledger.ts:213` / `cmp_utf16` と**台帳の語彙しか持っていない**ので、
台帳を知らない型の隣に置くとその語彙が `ordered.rs` に流れ込む。

**壊して確かめた。壊し方は 2 通りで、規則の 2 つの半分に対応する** 【実測】:

| 壊し方 | 赤くなったテスト |
|---|---:|
| A: **最初の値**を取る (後から来た値を捨てる) | **8 本** — `litedoc4/tests/build.rs` 2、`incremental.rs` 4、`incr/tests/merge.rs` 2 |
| B: 最後の値を取るが、**キーを末尾へ動かす** | **4 本** — `incremental.rs` 3、`incr/tests/merge.rs` 1 |

A は `index.json` の `modules` が差し替わらないので、消えたはずのモジュールが索引に残り
`reading …/ir/modules/Pkg.C.json: No such file or directory` で落ちる。B は
**「マージした IR は from-scratch と 1 バイト違わない」**が `index.json` **だけ**で落ちる
(`the merged IR is not a from-scratch one: ["index.json"]`)。
**どちらも出力を読めば何が壊れたか 1 行で言える。**

**計画が名指しした 2 つの安全網は、どちらも今は効いていない**(結果が SoT):

1. **「`tests/ledger.rs` のプロトタイプ byte 比較」は 2026-08-16 に削除済み** —
   ファイル自身の見出しが理由を書いている (オラクルの引退)。**指せるものが無い。**
2. **`tests/merge.rs` の round trip (`nested_json_keeps_its_key_order`) は `JsonObject` を通らない** —
   `serde_json::Value` の**入れ子**の順序を見るテストで、A でも B でも緑のまま。

つまり **台帳側 (`KeySet`) の insert 規則を見ているものは 1 本も無かった** — 12 本の赤は
全部 index 側と pipeline 側から出ている。だから 2 本足し、**足した順に一度落としてから通した**:

- `a_repeated_key_keeps_its_first_position_and_its_last_value` — A でも B でも赤くなる
- `a_key_set_that_is_not_a_map_says_what_it_wanted` — 下の判断を固定する

**`Deserialize` は `Ordered<V>` には付けない**【判断】。2 つの間で本当に違うのは
**拒否文だけ**で、台帳は "a map of strings to strings"、index は "a JSON object" と言う。
型は自分がどちらのファイルかを知らないので、`Ordered::deserialize_in_order(d, expecting)` を
共有して `impl Deserialize` は別名の側に置いた。1 文に統一すると
**片方のファイルについて間違ったことを言う拒否**が残る。

**5 綴りのうち 2 つは畳み、1 つは畳まなかった**:

- `merge.rs:773-782` の `module_map` → `Ordered<IndexEntry>`、`merge.rs:823-826` の
  `dep_mapping` → `Ordered<String>`。どちらも `Vec<(String, V)>` への同じ線形走査で、**計算量も同じ**
- **`detect.rs:305-311` の `previous` は同じ規則だが同じ判断ではない**【判断】 —
  これは**順序も覚えている lookup 表**で、`HashMap<&str, &ModuleEntry>` + 順序 `Vec` として書かれている。
  `Ordered` は連想リストなので、畳むと (a) 構築が O(n) → O(n²)、(b) `current` を回すループの中の
  `previous.get` が O(1) → O(n)、(c) 借用している `&str` キーの `String` clone、を同時に買う。
  対象は 432 モジュール、Mathlib 規模なら 8,169。**Lean を起動する前に走る段でこれを払う理由が無い。**
  §16 が言う「2 本必要だった」の形で、**規則は同じでもデータ構造の選択が別**。
  すぐ上の 2 行のコメントが既に規則を書いているので、**この項目では `detect.rs` を 1 行も触っていない**

`cargo test --workspace` は **450 → 452 passed / バイナリ 39 のまま** (足した `#[test]` が 2 本)。
テスト側の呼び出しを 8 箇所直した — `Ordered<V>::get` は `Option<&V>`、`iter` は `(&str, &V)` を返すので
`KeySet` では `&String` になる。`assert_eq!(…, Some("undefined"))` に `.map(String::as_str)` が
挟まっただけで、**主張は 1 つも変えていない**。


### X3 — 「corpus はこの機材にあるか」の述語が 5 綴り、うち 4 つは既に「間違い」と記録された `is_dir()`

- `incr/tests/impact.rs:1000-1012` に、この判定を直したときの記録が残っている:
  > an emptied `ref-pages` left its directory behind, `is_dir()` said yes, and the run reported
  > the corpus's own pages as "already absent" — a green-looking scenario failing for an environmental reason
- **その修正が `impact.rs` にしか適用されていない**。
  `global.rs:997/1009` / `state_and_delta.rs:2046` / `merge.rs:1180` は `is_dir()` のまま
- **`tools/corpus-tests.txt:59-63` が「`m1/ref-pages`, `w7h/base-state` は空でディレクトリだけ残っている」と
  明記していて、まさにその状態が今も続いている**
- 今の被害は限定的 (後段で panic するので緑にはならない) が、
  **メッセージが「set LITEDOC4_IR」ではなく serde のパスエラーになるので、環境の問題がコードの問題に見える**。
  CLAUDE.md が「壊れているのは環境」で 1 セッション溶かした記録を持っている形
- やること: `impact.rs:1018-1030` の `file_count` を共有モジュール (段 4) に移し、
  5 つのヘルパを `corpus_dir(var, default) -> PathBuf` 1 本に。
  **`base_ir.rs` の `index.json` 検査はそれより強いので残す**

### X4 — `Counts::used_by_targets` / `used_by_edges` は誰も読まない

- `global/artifacts.rs:155-164` (宣言) / `:372-384` (計算)。
  `rg` のヒットは **`artifacts.rs` の 4 行だけ** — `GlobalSummary` (`site.rs:249-263`) にも
  `TimingsRecord` (`site.rs:343-367`) にも無く、テストもツールも docs も参照しない
- `used_by_edges` の計算は無視できない仕事をしている: `used_by.values()` を `clone` して
  `sort_unstable` + `dedup` するが、**これは `name_lists` (`:445-451`) が `used_by_json` を作るときに
  既にやっている dedup の 2 周目**。対象パッケージの 54,424 refs / 10,163 pairs 分が
  誰にも読まれない数に消える
- **`Counts` の docstring (`:141-147`) は「derive が自分で数え、`the_counts_are_what_the_files_hold` が
  両者を正直に保つ」と言うが、C-2 で足されたこの 2 フィールドはそのテストが検査していない。**
  `used_by_edges` の doc に付いた【実測 2026-08-22: 10,163 pairs】を守るものが無い
- **`facts.rs:44-61` が `PROTOTYPE_FACT_KEYS` で解決したのと同型**の
  「テストが差分を手書きしていて、フィールドが増えると黙って偽になる」形
- やること (どちらか): **(1) 2 フィールドを `GlobalSummary` と `TimingsRecord` に通し、
  `the_counts_are_what_the_files_hold` に `used_by_json` の key 数と value 長の総和との突き合わせを
  2 行足す** ← 推奨 (`feature-sweep.md` C-2 がこの数を引く可能性がある) /
  (2) 使わないなら `Counts` から消し、実測値を `name_lists` 側のコメントに移す

#### 結果【2026-08-23】— **両方やった。本体は「空の成果物に対してテストが緑だった」こと**

**必須の半分から。** `the_counts_are_what_the_files_hold` を `Counts` の**分解束縛**で
書き直し、`used_by_json` を parse して **key 数**と **value 長の総和**に突き合わせる 2 本を
足した (`artifacts.rs:699-758`)。**新しい `#[test]` は 1 本も足していない** — 本数は 452 の
ままで、増えたのは 1 本のテストが見ている範囲。

**計画が書いていない段がもう 1 つあった**【実測】: `chain()` フィクスチャは `refs` を
1 つも持たず、`declarations/used-by.json` は **`{}` だった**。2 フィールドが検査されて
いなかっただけでなく、**検査する対象が空**で、`the_file_list_and_the_paths_agree` の
「どの成果物も空でない」も **2 バイトの `{}` で通っていた**。フィクスチャに参照を入れた
(`artifacts.rs:574-615`): 2 宣言が指す target、1 宣言が指す target、**このパッケージが
宣言していない名前** (逆引きが落とす)、そして `Pkg.dup` を **2 モジュールが宣言する** —
1 つの利用者リストに同じ名前が 2 回入る唯一の形で、**per-key の dedup が数に出る唯一の形**。
targets 2 / edges 3 (dedup しなければ 4)。

**壊して確かめた。3 通り、全部赤**【実測】:

| 壊し方 | 出た赤 |
|---|---|
| `used_by_edges` の dedup を外す (`values().map(Vec::len).sum()`) | `used_by_edges is not the number of names declarations/used-by.json lists` / `left: 4  right: 3` |
| `used_by_targets: used_by.len() - 1` | `used_by_targets is not the number of keys declarations/used-by.json has` / `left: 1  right: 2` |
| `Counts` に 7 つ目のフィールドを足す | **コンパイルが通らない** — `error[E0027]: pattern does not mention field ...` |

**3 つ目が X4 の一般形**。`facts.rs` の `PROTOTYPE_FACT_KEYS` は実行時にキー配列を
突き合わせるが、`Counts` は**同じ crate の struct** なので**分解束縛でコンパイル時に
強制できる**【判断】 — 手で並べる配列が要らず、腐る余地が無い。C-2 が 2 フィールドを
足したときにこのテストが黙って通った経路は、これで閉じた。

**任意の半分もやった。バイトを比較しているものは無かった**【実測】:
`GlobalSummary` (`site.rs:97-121`) は `Serialize` を持たず、構築箇所は `site.rs` の 1 つだけ。
`TimingsRecord` は `Serialize` だが、**HEAD でこのレコードを読むものは
`tests/state_and_delta.rs:625-630` の 3 キー (`cacheHits` / `cacheMisses` / `state`) だけ**。
`--timings` を渡す `tools/*.sh` は `build` / `extract` / `ledger` / `merge` の**別のレコード**を
書いていて、`global` に `--timings` を渡すものは 1 本も無い (`config-gate.sh:83` が
`global` を呼ぶ唯一の箇所で、渡していない)。docstring が名指しする `oracle.sh` は
`experiments/` と一緒に HEAD から消えている。

**2 キーは `delta` の後ろに足した**【判断】。`TimingsRecord` の docstring が
「キー順はプロトタイプのオブジェクトリテラル」と主張しているので、中に挿すとその主張が
偽になる。**`ModuleFacts::instances_for` が state ファイルで採ったのと同じ規則** —
プロトタイプのキー、その後ろに新しいもの。**推測でキー名を書かず、1 度出させた**【実測】:

```
{"command":"build",…,"totalSeconds":0.005733083,"delta":null,"usedByTargets":0,"usedByEdges":0}
```

(合成 IR は `refs` を持たないので 0。キーが在ることの確認であって、値の確認ではない。)

**2 フィールドの費用**: `used_by_edges` は `used_by.values()` を clone して `sort_unstable`
+ `dedup` する — **`name_lists` (`artifacts.rs:461`) が `used_by_json` を作るときにやる
dedup の 2 周目**で、対象パッケージでは 54,424 refs / 10,163 pairs 分【実測 2026-08-22】。
**これは畳まなかった**【判断】 — `Counts` の docstring が「derive が自分で数え、テストが
両者を正直に保つ」という設計を明記していて、`used_by_json` から数えると**テストが自分自身を
比較する**ことになる。払っているのは 2 周目の dedup 1 回、買っているのは
「数と成果物が食い違ったら赤くなる」こと。**今この 2 つを正直に保っているのは上の 3 つの赤**で、
それ以前は何も保っていなかった。

### X5 — 未使用 re-export 14 件の判定 — **死んでいるものは 1 つも無い**

| | 判定 |
|---|---|
| `ir::DepMapEntry` / `global::FactsRun` / `incr::DepMapRecord`,`FileEntry`,`ImpactSummary` | **必要** — 公開関数の引数型・戻り型・公開型のフィールド型。所属 mod が非公開なので re-export が唯一の経路 |
| `incr::RULE_LOST_OWNER` / `RULE_MOVED_ELSEWHERE` | **必要に近い** — 公開型 `Witness::rule` (`ownership.rs:78-80`) が取る 2 値 |
| `ir::escape_component`,`unescape_component` / `global::DeltaTimings` / `incr::OLEAN_SUFFIXES`,`ORPHANS_IN_SUMMARY` | **重複経路** — 所属 mod が `pub mod` なので re-export を消しても届く |
| `ir::SELECTION_RANGE_SCHEMA_VERSION` / `SORRY_SCHEMA_VERSION` | **過剰公開** — `mod reader` は非公開なので消せば crate 内に閉じる。しかも自分の doc (`reader.rs:47`, `:57-58`) が「適用されるのは `sorry_of` / `naming_of` / `generated_by` **だけ**」と書いていて、**root から見えていることが doc と矛盾する** |

- **別の問題が見つかった**: `incr/lib.rs:55-82` は **6 つの mod すべてが `pub`** なのに 40 名を root へ
  re-export している = `litedoc4_incr::merge::merge` と `litedoc4_incr::merge` の両方が有効で、
  **どちらが「正」かを言うものが無い**。`ir` の `name` は 6 名だけ re-export され、
  同じく公開の `is_letter_like` / `needs_no_escape` / `is_subscript_alnum` は**されていない** =
  **選び方の規則が無い**。`unreachable_pub` (workspace lint) はこの形を検出しない
- やること: 方針を 1 つ選んで 3 crate に適用する。勧めるのは
  **「非公開 mod + root への re-export」** (`global` が `site` で、`ir` が `model`/`reader` で既に採っている形)。
  **最小の一手は `SELECTION_RANGE_SCHEMA_VERSION` / `SORRY_SCHEMA_VERSION` を `pub(crate)` に (5 行)** —
  この 2 つだけは「重複経路」ではなく「消せば閉じる」

### X6 — `detect.rs` が crate 全体のエラー型と書き込みヘルパを抱えている

- `incr/detect.rs:582-761` の `enum Error` に **merge / prune / impact / ownership の variant** が入っている
  (`IndexShape`, `ModuleListMismatch`, `NotAModule`, `UnknownMode`, `OutsidePageRoot`)。
  `litedoc4_incr::Error` の正体は `detect::Error`
- `detect.rs:500-529` の `write_text` / `write` / `write_json_line` を **5 stage 全部が使う**
- **`Error::exit_code` (`:669-681`) が 5 stage 分を 1 つの match で決めているので、判断は 1 箇所に
  集まっており、そこは正しい。問題は住所だけ**
- 放置すると: 新しい stage が variant を足すときに `detect.rs` を開く必然性が無いので、
  **別の場所に 2 つ目の Error が生えやすい**
- やること: `incr/error.rs` と `incr/io.rs` (あるいは 1 本 `common.rs`) に移す。
  `lib.rs` の re-export 名は変えない。250 行の移動

#### 結果【2026-08-23】— **`common.rs` にしなかった。名前が何でも引き寄せるのが、直そうとしている失敗そのもの**

`error.rs` (200 行) と `io.rs` (56 行) の **2 本**に分けた【判断】。1 本の `common.rs` に
しなかったのは、**「共通」という名前は次に来たものを何でも受け入れる**からで、それは X6 が
直している失敗——**「そこを開く必然性が無い住所」**——の別の形。`error.rs` / `io.rs` は
名前が中身を言うので、stage を足す人がそこに着地する。その一文を `error.rs` の
モジュール doc に書いた。

移したのは **verbatim で 220 行**:

- `error.rs` ← `detect.rs:582-762` (`enum Error` / `exit_code` / `Display` / `NAMES_IN_REFUSAL` /
  `some_of` / `impl std::error::Error`)。**`Error::exit_code` の 1 つの `match` はそのまま** —
  5 stage 分の終了コードが 1 箇所に集まっている状態は動かしていない
- `io.rs` ← `detect.rs:481-502` + `:513-529` (`lines_file` / `write_text` / `write` / `write_json_line`)

`detect.rs` は **763 → 539 行**。間に挟まっていた `hashed_bytes` は `ModuleEntry` の話なので残した。

**`lib.rs` の再輸出名は変わっていない** — `Error` を `detect::{…}` の並びから
`pub use error::Error;` に移しただけで、`litedoc4_incr::Error` は同じ。消えたのは
`litedoc4_incr::detect::Error` という経路で、**crate の外から使っているものは無い**
【実測: `litedoc4_incr::detect` のヒットは `litedoc4/src/watch.rs:542` のコメント 1 件だけ、
しかも mod を指していて型ではない】。

**`pub mod error` / `pub(crate) mod io`**【判断】。`error` を pub にしたのは他の 5 stage の
mod がすべて pub だからで、X5 が方針を 1 つ選ぶときに一緒に扱われるべきものを先に例外にしない。
`io` は中身が全部 `pub(crate)` なので、`pub mod` にすると**中身の無い公開ページ**になる。

**`lines_file` は private → `pub(crate)` に広がった。** `detect.rs` は 3 つの集合を
`write_text(path, x)` ではなく `write(path, &lines_file(x))` と書いていて、**これは触っていない** —
同値だが、揃えるのは移設ではない。

**§14 の 3 箇所は触っていない** (`prune.rs:423-446` の `read_dir` 非ソート /
`impact.rs:378-386` の `write_text` 不使用 / `merge.rs:25-98` の Lean 順序)。
**§14 の領域内で変えたのは 1 行だけ**で、`impact.rs:379` のコメントが指す綴り
`crate::detect::write_text` → `crate::io::write_text`。**移設が住所を変えた以上、
この行は直さないと嘘になる** — 理由も実装も 1 文字も動いていない。同じ理由で
`litedoc4/src/pipeline.rs:1770` の doc が名指ししていた `detect::write_text` も直した。

**住所が動いたものが docs にもう 1 件ある**: 段 0 の D13 が引いている `detect.rs:656-659`
(`OutsidePageRoot` の「`«..»` は届く」論証) は **`error.rs` に移った**。D13 は決着済みで
当時の住所を書いている記録なので、**書き換えていない**。

**`Error` の doc の「The three refusals below」は今 exit 3 が 7 件あるが、そのままにした**
【判断】 — 移設で本文を書き換えると、何が動いたのかが後から読めなくなる。直すなら別の変更として。

`cargo test --workspace` は **452 passed / 0 failed / 22 ignored / バイナリ 39** で X2 の後と同じ。
出力バイトは 1 つも動いていない — `RENDERER_ID` / `EXTRACTOR_ID` は無傷で、
両項目を通して赤くしたのは**わざと壊したときだけ**。


### X7 — `search_index::encode` は panic するが、対の `decode` は `Option` を返す

- `global/search_index.rs:120-234` の `encode` は `assert!(kinds.len() <= 255)` に加えて
  **入力由来の値に対する `expect` を 13 個**持つ
  (`u16::try_from(len).expect("a declaration name under 64 KiB")` /
   `u16::try_from(entry.module).expect("fewer than 65,536 modules")` など)。**`# Panics` 節が無い**
- 一方 `decode` (`:261-333`) は
  `#[expect(clippy::missing_panics_doc, reason = "the slice lengths are checked before every conversion")]`
  を持ち、すべての読みが `bytes.get(..)?` で境界検査され、壊れたファイルには `None` を返す
- **`missing_panics_doc` は `[workspace.lints.clippy]` に無いので全体では off だが、
  `decode` の `#[expect]` はその項目に対して lint を有効化している
  = `encode` の panic 経路が clippy から見えていない**
- `encode` の限界 (65,535 モジュール / 255 kind / 64 KiB 名) は `:20-31` の**フォーマット仕様の一部**で、
  それを破る入力は「パッケージが大きい」であって「ファイルが壊れている」ではない
  (**現実的には安全** — Mathlib 全体でも 8,169 モジュール【実測、R4】)
- やること: `encode` に `/// # Panics` 節を書いて 4 つの上限を列挙する (10 行)。
  **`Result` 化は別の判断で、今は要らない**

### X8 — `Span` のデシリアライザが数の関係を検査しない

- `ir/span.rs:113-147` の `visit_seq` は要素数 3/4/6 を強制し kind の u8 収まりを見るが、
  **`start <= stop` と `front <= start` を見ていない**
- `front_range()` は `self.start - self.front` (`:89`) なので、`front > start` の span で
  **debug ビルドは "attempt to subtract with overflow" で panic、release は wrap して
  巨大な `Range` になり `Utf16Text::get` が `None` を返す**
- この 4 つの数は **plan §7 U2 そのもの**。crate の姿勢 (`deny_unknown_fields` / `Attr` の arity 拒否 /
  5 要素 span の拒否 / `Member::is_direct` の三値化) は一貫して「推測より拒否」で、**ここだけ抜けている**
- panic するとしても、メッセージが `utf16.rs:218-221` の良いメッセージ
  (「span [4,2) は 7 単位のフラグメントの有効なスライスではない」) ではなく整数演算のオーバーフローになる
- やること: `visit_seq` の末尾に 2 検査 + `back_range` を `checked_add` に。
  `:196-209` の `malformed_forms_are_rejected` に `"[5,2,0]"` と `r#"[0,1,1,"n",3,0]"#` を足す (15 行)

#### 結果【2026-08-23】— **先に書いたテストが 3 本落ちた。うち 2 本は計画に無い検査**

**テストを先に書いて落とした**。`malformed_forms_are_rejected` に 2 形を足し、
メッセージの質を見る `the_refusals_say_which_numbers` と、`stop + back` が u32 を溢れる
`a_trailing_width_that_runs_off_the_end_is_not_a_range` を書いた時点で:

```
malformed_forms_are_rejected            expected [5,2,0] to be rejected
the_refusals_say_which_numbers          an inverted span is refused:
                                        Span { start: 5, stop: 2, kind: Fn, ... }
a_trailing_width_that_runs_off_the_end  attempt to add with overflow (span.rs:94)
```

**計画が予告した `front_range` の panic も、直す前に実際に出させた**【実測】 —
`[0,1,1,"n",3,0]` を読んで `front_range()` を呼ぶ使い捨てのテストで
`attempt to subtract with overflow (span.rs:89)`。**「そうなるはず」で直していない。**

直したのは 3 箇所: `visit_seq` 末尾の 2 検査、`back_range` の `checked_add`、
そして `front_range` / `back_range` / モジュール見出しの doc。

- **メッセージは `utf16.rs:218-221` の綴りに寄せた** — 「`span [5, 2)` is not a range:
  it ends before it starts」「a span at 0 cannot carry 3 units of leading whitespace:
  there are only 0 units in front of it」。**数を本文に出す**のがあの行の要点で、
  `the_refusals_say_which_numbers` がそれを固定する (`"[5, 2)"` を含むこと)
- **`front_range` は減算のまま残した**【判断】。`checked_sub` で `None` を返すのは
  「先行空白は無い」と**推測する**ことになる。デシリアライザが `front <= start` を立てた以上、
  ここに来る壊れた `Span` は**フィールドを手で組んだもの**しかないので、
  X7 と同じ形で **`# Panics` 節を書いて panic を残した**
- **`back_range` だけ `checked_add` なのは非対称ではない**。`stop` と `back` は
  **各々は正当で和だけが不正**なので visitor が 2 数の関係として拒否できない。
  そして `u32::MAX` を超える範囲を持てるフラグメントは存在しないので、
  ここで返る `None` は「末尾空白が無い」と同じ答えでよく、推測ではない

**この 2 検査が corpus を弾かないことは、機材ではなく抽出器を読んで確かめた**
【実測: `extractor/Extract.lean:1125`】 — 抽出器は `start = off + front`,
`stop = off + total - back` を**同じアキュムレータから**書く (`wsTrim`, `:1064-1071`)。
したがって `start - front = off ≥ 0` と `stop + back = off + total ≤ 断片長` が
**構成上成り立つ**。この検査が拒否するのは**抽出器以外が書いた IR** だけ。
(corpus は当機材に無いので実走では確かめていない。確かめたのは書き手の側。)

`cargo test --workspace` は **448 → 450 passed** (足した `#[test]` は 2 本。
`malformed_forms_are_rejected` はケースが 4 → 6 に増えただけなので本数には出ない)。

## 7. 段 4 — テストの共通化 (ワークスペース横断)

**調査 3 件が独立に同じことを指摘した。** 製品コードの規律 (`unwrap()` ゼロ / `#[allow]` ゼロ /
`#[expect]` に全部理由) が、**テストのヘルパ層には届いていない**。

### U1 — `TempDir` が 15 箇所にある【実測。当初 14、段 2 の S8 で 1 増えた】

```
crates/litedoc4-global/tests/state_and_delta.rs:2081   crates/litedoc4/tests/site.rs:661
crates/litedoc4-global/tests/global.rs:1143            crates/litedoc4/tests/incremental.rs:2593
crates/litedoc4-incr/src/prune.rs:590                  crates/litedoc4/tests/extract.rs:466
crates/litedoc4-incr/tests/impact.rs:2225              crates/litedoc4/tests/build.rs:1896
crates/litedoc4-incr/tests/merge.rs:2594               crates/litedoc4-render/tests/pages.rs:1272
crates/litedoc4-incr/tests/ledger.rs:1583              crates/litedoc4-render/src/assets.rs:116
crates/litedoc4/src/packages.rs:1217                   crates/litedoc4-render/src/config.rs:168 (`Dir`)
crates/litedoc4-render/src/site.rs:323
```

`crates/litedoc4/tests/` の 4 本は**プレフィックス文字列以外は完全に同一の 29 行**。
`crates/litedoc4-render/tests/pages.rs:1272` のコメントは
「Hand-rolled rather than a dependency: … the workspace has no other use for one」と書いているが、
**同じクレートに他に 2 つある** = 事実として偽。

### U2 — 共有の置き場所【設計判断】

`tests/common/mod.rs` があるのは **`litedoc4-render` だけ**で、**8 バイナリ中 3 本しか使っていない**。

| | `tests/common/mod.rs` を各 crate に | `crates/litedoc4-testutil` を 1 本 |
|---|---|---|
| integration test から | 使える | 使える |
| **`src/` 内の `#[cfg(test)]` から** | **使えない** | **使える** |
| 該当箇所 | — | `prune.rs:590` `packages.rs:1217` `assets.rs:116` `config.rs:168` の 4 つ |
| 依存 | 増えない | ワークスペース内なので **NOTICE に影響しない** (`provenance-gate.sh` は `cargo tree -e normal`) |
| `cargo machete` | — | 使う crate だけに入れれば問題なし |

**決定: `crates/litedoc4-testutil` を作る** (依存ゼロ / `publish = false` は `workspace.package` から継承 /
`members = ["crates/*"]` なので自動で member)。**`tempfile` のような外部 crate は入れない** (§2.3)。

**対案と却下理由**: 調査担当の 1 人は「crate 境界を跨げないので各 crate に `tests/common/mod.rs` を
置いて 4 → 2 が上限。crate が違えば dev-dependency を足す価値は無い」と判断した。
これを採らないのは、**`src/` 内の `#[cfg(test)]` にある 4 つ (`prune.rs:590` / `packages.rs:1217` /
`assets.rs:116` / `config.rs:168`) に `tests/common/mod.rs` が届かない**ため。
crate ごとの `tests/common/` だと `TempDir` は 14 → 6 にしかならず、testutil なら 14 → 1 になる。
**ただし段 1 の R1 で `packages.rs` のテストは `tests/` に出す**ので、その分は差が縮む —
R1 の後に再評価してよい。

### U3 — render のテストヘルパ fork 11 種

| ヘルパ | コピー |
|---|---|
| `unescape` | `common/mod.rs:106` と `fragment.rs:726` — 完全一致 |
| `anchors_of` | `autolink.rs:583` と `fragment.rs:709` — 1 行違い |
| `show` | `autolink.rs:605` / `fragment.rs:733` / `md/docgen4.rs:98` / `md/md4lean.rs:224` — **4 版** |
| `attr_values` | `pages.rs:1073` と `page_parts.rs:1289` — 完全一致 |
| `between` | `pages.rs:1092` と `page_parts.rs:1334` — 完全一致 |
| `file_count` | `ref_pages.rs:109` と `pages.rs:1233` — 1 行違い |
| `env_path` | `ref_pages.rs:76` と `autolink.rs:577` — 完全一致 |
| `first_difference` | 3 版、**窓幅が 40/60・40/90・40/40 でバラバラ** |
| `Case::index()` | `page_parts.rs:153-173` と `autolink.rs:128-148` — **8 行のコメント含め 1 文字も違わない** |
| `DEFAULT_IR` / `DEFAULT_LINK_INDEX` | 4 箇所に同じリテラル |

**`DEFAULT_IR` の 4 重定義が最も危ない** — CLAUDE.md が名指しする凍結パス
(`/private/tmp/lean-doc-relay/…`) で、**改名時に 1 箇所だけ直る形**。
`show` の `'\t'` 分岐が片方にしか無いので、**同じ乖離が 2 つのテストで違って表示され、
失敗メッセージが比較できない**。

### U4 — `crates/litedoc4/tests/` の fake extractor が 2 本に分岐済み【U3 より重い】

- `tests/build.rs:197-263` と `tests/incremental.rs:1015-1067`。
  **前者が後者のスーパーセットで、共通部分約 40 行が二重管理**
  (`--corrupt` と deps スライス対応が build 側だけにある)
- **どちらも「fake extractor が焼いた IR を full generation と比べる」ゲートを持っている**ので、
  **片方の IR 生成規則が変わっても比較は成立してしまう**
- やること: `write_fake_extractor(path, Features { corrupt: bool, deps: bool })` の **1 本の生成器**に
- **統合しないもの**: `ModuleSpec` / `Live` (`tests/build.rs:60-300` と `tests/incremental.rs:684-1290`)。
  **フィクスチャの意味が違う 2 つを 1 つにすると、どちらの前提でテストが書かれているか読めなくなる**

### U5 — `litedoc4()` / `stderr()` / `stdout()` / `code()` / `message()`

`crates/litedoc4/tests/` の 5 ファイル (`build.rs:1698` / `site.rs:36` / `incremental.rs:2538` /
`extract.rs:428` / `resident.rs:278`) に散在。バイナリを `Command` で起こす薄いラッパ。
`testutil` に置けば 5 本が 1 本になる。


### U6 — incr / global 側のフォーク

- **`fnv1a64` ×4 は「オラクルの独立性」ではない**【調査担当の判定】。
  `incr/tests/impact.rs:976` / `incr/tests/merge.rs:1120` / `global/tests/global.rs:1094` /
  `global/tests/state_and_delta.rs:2072` の 4 つとも**同じ 6 行** (同じ定数
  `0xcbf2_9ce4_8422_2325` / `0x0000_0100_0000_01b3`、同じ `format!("{hash:016x}")`)。
  **独立なオラクルは生成器側の TypeScript** (`global.rs:1092` の
  「the same ten lines the generator has」、`global-expected.json` の `generatedBy`) であって、
  **Rust 側の 4 コピーは互いに独立ではない。1 本にまとめても TS 側からの独立性は 1 ミリも減らない**
- `copy_tree` ×2 (`impact.rs:2212-2223` / `merge.rs:2581-2592`) は **byte 同一**
- `TempDir` ×6 のうち **`incr/src/prune.rs:590-607` だけ分岐が 1 本足りない** —
  他の 5 つが持つ `slug` (英数字以外を `-` に置換、40 文字で切る) が無い
- **フォークではなかったもの (誤検知として潰す)**:
  `run_build` ×2 (`ledger.rs:575` は自由関数、`:1503` はそれを呼ぶメソッド) と
  `target_shaped` ×2 (`impact.rs:2072` は `FakeIr`、`merge.rs:2404` は merge の base/inc ペア。
  **別の型の別のフィクスチャで名前が偶然一致しているだけ**)。**どちらも触らない**
- 段 3 の X3 (`corpus_dir`) も同じ場所に入る

## 8. 段 5 — `tools/*.sh` (35 本 / 9,740 行)

**ここから安全網が薄くなる。** CI が呼ぶのは 6 本だけで、残り 29 本は手で回すしかない。
**だから「共通化して壊す」リスクが Rust より高い。1 本ずつ、回して確かめながら進める。**

### T1 — 共通化の仕組みは既にある。`tools/` だけが取り残されている

- `benchmarks/tools/env.sh` は**共通ライブラリとして機能している** — `TARGET_REPO` の既定値、
  `LITEDOC4_ROOT`、`RESULTS_DIR`、対象の存在検査を持ち、`benchmarks/tools/*.sh` 6 本と
  `extractor/build.sh` が `source` している
- **一方 `tools/*.sh` 35 本は 1 本も `source` していない**【実測: `rg '^\s*(source|\.)\s+' tools/*.sh` = 0 件】

### T2 — 計測対象の指定が 5 通り。うち 2 通りは上書きできない【優先度: 高】

| 綴り | 上書き | ファイル |
|---|---|---|
| `TARGET=/Users/haruka/dev/lean-projects` | **不可** | `watch-gate:86` `build-gate:117` `ledger-reference:29` `incremental-reference:151` `deps-docs-gate:131` `clone-gate:209` |
| `MEASUREMENT_TARGET=/Users/haruka/…` | **不可** | `target2-gate:93` |
| `TARGET="${TARGET_REPO:-…}"` | `TARGET_REPO` | `benchmarks/tools/measure-ledger:42` ほか |
| `SRC="${TARGET_SRC:-…}"` | `TARGET_SRC` | `setup-clone:45` `make-target2:75` `rebuild-own:33` |
| `target="${LITEDOC4_TARGET:-…}"` | `LITEDOC4_TARGET` | `corpus-gate:187` |

**public リポジトリで、7 ファイルが特定の機材の絶対パスを上書き不能に焼いている。**
`env.sh` の `TARGET_REPO` が唯一の正しい形で、コメントが理由も書いている
(「Override only to add a target, never to replace the baseline one」)。

**やること**: `benchmarks/tools/env.sh` から**変数定義だけ**を `tools/lib/target.sh` に抜き、
`env.sh` はそれを source して自分の副作用 (`RESULTS_DIR` / `DOCGEN_BIN` / `mkdir`) だけ持つ。
`tools/*.sh` も `tools/lib/target.sh` を source する。
**`env.sh` を移動しない** — 参照が 8 箇所あり、`extractor/build.sh` のコメントが相対パスの履歴を持っている。

### T3 — 現役でない compare / reference 6 本 (1,331 行) を棚卸しする

`{ledger,merge,impact}-{compare,reference}.sh` は **CI からも docs からも参照されず、
互いを参照し合うだけ**【実測】。6 本すべてが「`experiments/` が撤去されたので元のループは無い」と
コメントに書いている。`ledger-compare.sh:17-18` は代替も明言している:

> `cargo test -p litedoc4-incr --test ledger` makes the same comparison in process

行数: ledger-compare 139 / ledger-reference 157 / merge-compare 184 / merge-reference 299 /
impact-compare 203 / impact-reference 349。

**消す前に 1 件ずつ「`cargo test` 側が同じ検査をしている」ことを確認する。**
確認できなければ残す — **道具を消すことと、その道具が守っていた主張を消すことは別**。

### T4 — 5 種類のブロックが 4〜23 ファイルに散在【実測: 同一行の出現数】

| 種類 | 代表行 | 出現 |
|---|---|---|
| 引数パース | `while [ $# -gt 0 ]; do` / `case "$1" in` | 23 |
| 〃 | `--out) OUT="$2"; shift 2 ;;` | 15 |
| 〃 | unknown アーム (綴り 2 種) | 8 + 7 |
| パス解決 | `HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` | 12 |
| 〃 | `REPO="$(cd "$(dirname …)/.." && pwd)"` | 10 |
| バイナリ検出 | `LAKE="${LAKE:-$HOME/.elan/bin/lake}"` | 11 |
| 〃 | `RUST_BIN=…` + `[ -x ]` 検査 | 7 |
| 環境記録 | `printf 'host … sysctl … uname … date …'` | 5 |
| 木の比較 | `IDENTICAL` / `DIFFERENT` の判定と `extra=` の走査 | 5 / 4 |

**「環境記録」は CLAUDE.md「計測条件を毎回記録する」の実装** — 共通化すれば記録漏れが構造的に防げる。
これが T4 の中で最も価値が高い。

### T5 — CLAUDE.md が記録している 2 つの罠は、共通化で構造的に防げる

- 「`trap … EXIT` の最後のコマンドの終了コードがスクリプトの終了コードになる」
  — `tools/e2e-micro.sh` が「E2E MICRO: ok」と印字して **exit 1** していた【実測 2026-08-18】
- 「パイプを噛ませた瞬間、見ている終了コードは最後のコマンドのもの」【実測 2026-08-18、同日 2 回】

**どちらも「1 本の正しい cleanup / run ヘルパ」があれば各スクリプトが再実装しなくてよくなる。**
`tools/lib/common.sh` に `cleanup_trap()` (必ず `if` で書く) と `run_logged()` (パイプを使わず
ファイルにリダイレクトして終了コードを保つ) を置く。

### T6 — `set -e` の有無が割れている

`set -euo pipefail` 24 本 / `set -uo pipefail` 11 本。後者は compare 系に多く**意図的かもしれない**
(個別の失敗を集計して最後に `status` を返す形)。**どちらを選ぶかの基準が書かれていない**ので、
`tools/lib/common.sh` の冒頭コメントに 2 行で書く。

---

## 9. 段 6 — `.github/workflows/` (13 本 / 3,248 行)

**安全網は「走らせるまで分からない」。ブランチ push + `gh workflow run` で確かめる**
(CLAUDE.md「CI の実測値を main を赤くせずに取るには」)。

### C1 — elan のインストール 4 ステップが 6 ファイルで完全一致

`- name: Cache elan` / `id: elan-cache` /
`key: elan-${{ runner.os }}-${{ hashFiles('e2e/micro/lean-toolchain') }}` /
`if: steps.elan-cache.outputs.cache-hit != 'true'` / curl / `- name: Put elan on PATH` /
`run: echo "$HOME/.elan/bin" >> "$GITHUB_PATH"` が **6 ファイルで一字一句同じ**。

**やること**: `.github/actions/setup-elan/action.yml` (composite) にまとめ、
toolchain ファイルのパスを入力にする (`e2e/micro/lean-toolchain` と `target/lean-toolchain` の 2 系統がある)。

### C2 — その他の重複

- `repository: FujiHaruka/information-theory` の checkout が 6 ファイル
- `lake exe cache get` が 5 ファイル
- 環境記録 `} | tee env-before.txt` が 4 ファイル
- `actions/checkout@v5` が 35 箇所 / **`@v4` が 2 箇所** ← バージョン不統一。揃える

### C3 — `setup-node` 13 箇所は**後回し**

`node-version: "24.19.0"` が 7 ファイル 13 箇所にあるが、
**`tools/assets-gate.sh:48-56` が `mise.toml` と全箇所の一致を両方向で検査している**。
今壊れてはいない。C1 を先にやる。

---

## 10. 段 7 — `extractor/Extract.lean` (3,687 行の単一ファイル)

**最も安全網が薄い。対象リポジトリの Lean 環境が要る。最後にやる。**

### L1 — 分割にはビルド経路が 2 本ある

- `extractor/build.sh` — 単一ファイルを `lake env lean --root=$HERE` で直接コンパイル
- `lakefile.lean` の `lean_exe extract` — Lake 経由 (package symbol prefix と `-O3` が付く)
- **`tools/lake-package-gate.sh` item 4 が両者の一致 (byte-identical な IR を書くこと) を見ている**
- **どちらも直さないと割れない。** 分割するなら `Extract/` 配下に置いて `import` で繋ぐ形になり、
  `build.sh` は `.olean` と `.c` が複数になる分を扱う必要がある

### L2 — 定義長【実測】

定義 103 本、100 行超 5 本、200 行超 2 本。
最大は `def run` (`:2915`) の **659 行**、次が `probeAllTacticDocs` (`:2248`) の 224 行。
**`run` は「1 回の抽出」全体で、`run_incremental` と同じく順序が内容**の可能性が高い。
分割の前に、**まず段の見出しごとに関数を切れるかを読んで判断する** (機械的に割らない)。

### L3 — namespace `Stage4b` — **変えられる。ただしイベントキーは別物で触れない**

- **namespace `Stage4b`** は `extractor/Extract.lean` の 4 箇所のみ。出力に出ない内部名。
  `docs/plans/rename.md` の「意図的に残した 5 種」に**入っていない**
- **イベントキー `stage4b.*` は触らない** — これは**プロトコル**で、
  `crates/litedoc4/src/extract.rs:506` が prefix を剥がし、
  `crates/litedoc4/tests/extract.rs:30` のフィクスチャ、`benchmarks/results/*.jsonl` の凍結ログ、
  `benchmarks/tools/measure-link-index.sh:83` が同じ文字列に依存している
- **この 2 つを混同しない。** L3 をやるなら「namespace だけ」と明記してコミットする

---

## 11. 段 8 — docs と掃除

### E1 — `docs/plans/feature-sweep.md` (829 行) の圧縮

CLAUDE.md「計画文書は 600 行を超えたら `/compact-plan`」に該当。
8 項目すべて完了済み (束 A・B・C)。**要約であって分割ではない**
(`approach.md` を分割したのは §5・§6 が節ごと生きていたからで、こちらは違う)。

### E2 — 掃除

- `mutants.out` / `mutants.out.old` がリポジトリルートに残置 (3.9 MB × 2、gitignored)
- `target/` 12 GB / `.lake/` 178 MB
- **この機材のディスクの空きは 17 GiB しかない**【実測 2026-08-23、`df -h /`】。
  作業領域 `/private/tmp/lean-doc-relay` は今 34 MB まで掃除されているが、
  **1 回のサイトが約 60 MB、`make-target2.sh` の package は数 GB**。
  2026-08-17 に 5 世代ぶん 24 GB 溜めてディスクを満杯にし、
  **中断された `lake build` が対象の olean を 1 つ欠落させた**【実測】。
  **段の切れ目で必ず `du -sh /private/tmp/lean-doc-relay` と `df -h /` を見る。**
  段 5 と段 7 は対象リポジトリを使うので特に

### E3 — docs のパス参照

機械検査で「実在しないパス」122 件が出たが、**大半はノイズ** (対象リポジトリ内のパス /
doc-gen4 のソース / tag `experiments-frozen` 配下 / crate 相対 / web 相対)。
本物らしいのは 2 件だけ: `docs/plans/assets-typescript.md:77` の `tools/search-gate.sh` (不在)、
`docs/plans/feature-sweep.md:480` の `tools/check-site-browser.ts` (実在は `benchmarks/tools/`)。

### E4 — Cargo.toml の lint 注記

`#![allow]` (inner) と `#[allow]` (outer) で clippy の扱いが違う【実測 2026-08-23】:
- **`allow_attributes_without_reason` は inner も見る** — 理由なしの `#![allow(dead_code)]` を
  `litedoc4-ir/src/lib.rs` に足したら clippy が **exit 101** で落ちた
- **`allow_attributes` は inner を見ない** — `crates/litedoc4-render/tests/common/mod.rs:20` の
  理由付き `#![allow(dead_code, reason = …)]` は CI (`--all-targets`) で緑のまま

つまり穴は「**理由を書けば inner allow は書き放題**」の側だけ。
CLAUDE.md と Cargo.toml のコメントは「機械的に強制している」と書いているが、
**確認されたのは outer 形だけ**なので、`[workspace.lints.clippy]` の該当箇所に 2 行足す。
強制したいなら**件数を固定する** (`#![allow` の出現が 1 件であること) — 許可リストにするのは
「例外リストを持つ比較器」と同じ失敗。


## 12. 順序と完了条件

**段 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8。** 安全網が厚い順 (§2.2)。
**段の中の項目は独立なので任意順**だが、段 1 の R1 (`lib.rs` 化) だけは同じ段の他より先。

各段の完了条件は共通:

1. `cargo test --workspace --no-fail-fast` が **437 passed / 0 failed** (増える分にはよい)
2. `cargo fmt --check` / `cargo clippy --workspace --all-targets -- -D warnings` が exit 0
3. **`cargo doc` は CI と同じ形で回す** ← **push 前に。**
   2026-08-22 にこれを忘れて CI を 1 回赤くしている。**素で回すと赤くなる**
   【実測 2026-08-23、この計画の D0 で踏んだ】 — 公開項目が非公開項目を指す intra-doc link が
   5 件あり、`ci.yml:139-144` はそれを「a public item pointing at a private one is normal here」
   として許している:

   ```sh
   RUSTDOCFLAGS='-D warnings -A rustdoc::private_intra_doc_links' \
     cargo doc --workspace --no-deps --document-private-items
   ```
4. 触った層に対応するゲートが緑 (下の「検証」)
5. **その段で何が変わったかを 1 行で言える**

## 13. 検証 — どの段で何を回すか

| 段 | 回すもの | 機材 |
|---|---|---|
| 0〜4 (Rust) | `cargo test` / `clippy` / `fmt` / `doc` | 不要 |
| 0 の D4 / 段 1 の R1 | **`tools/corpus-gate.sh --verify-list`** | 不要 |
| 段 2 の S5 | `tools/assets-gate.sh` (**`mise exec --` 越しに呼ぶ**) | node |
| 段 4 (テスト共通化) | 全テストバイナリ。`--verify-list` も | 不要 |
| 段 5 (shell) | **触った 1 本ずつを実際に回す。** CI の 6 本は `ci.yml` | 対象リポジトリ |
| 段 6 (CI) | ブランチ push + `gh workflow run <name> --ref <branch>` | — |
| 段 7 (Lean) | `extractor/build.sh` + `tools/lake-package-gate.sh` (item 4 が 2 経路の一致を見る) | 対象 + toolchain |

**この機材の罠は全部そのまま効いている** (CLAUDE.md「この機材の罠」)。特にこの計画で踏みやすいもの:
- **`mise exec --` 越しに呼ぶ** — PATH 上の `node` は署名不正で **SIGKILL (exit 137)**。
  `cargo build` は build.rs で npm を呼ぶので**これに当たる**
- **終了コードを判定に使う場面でパイプを外す** — このセッションのシェルは zsh で `PIPESTATUS` を持たない
- **`pgrep -f 'litedoc4 watch'` を先に見る** — 長命プロセスが作業領域を書き続けていると
  「ゲートが壊れた」ように見える
- **`git checkout <file>` を無効化実験に使わない**
- **`rg` の `-r` を束ねない**

## 14. 触らないもの — 一覧

**調査 3 件が「意図的にそうなっている」と判定したもの。整形の対象にしない。**

### 出力バイトと互換トークン
- **`RENDERER_ID` / `EXTRACTOR_ID` を上げる変更はこの計画の範囲外**
- **凍結フィクスチャ** (`crates/*/tests/data/*-expected.json`) — 再生成手段は HEAD に無い
  (tag `experiments-frozen`)
- **`/private/tmp/lean-doc-relay/**` の旧名** — 凍結フィクスチャに生成時のパスとして焼かれている
- **イベントキー `stage4b.*`** — プロトコル (→ 段 7 の L3)

### 「順序そのものが関数の内容」であるもの
- `pipeline.rs:431` `run_incremental` — 6 つの順序制約が段の見出しに書いてある
- `site.rs:162` `render_site` の `NameIndex` 構築部 — `site.rs:8-14` が明記
- `main.rs:701-705` — **`site` は render→global、incremental は global→render の逆順**。
  「揃えるべき不整合」に見えるが、コメントが明示的に否定している (制約 2 の帰結)

### 「網羅性が関数の内容」であるもの
- `md/parse.rs:502` `leave_block` (138 行) / `md/html.rs:195` `block_into` (105 行) /
  `html.rs:328` `text_into` (78 行) — **`wrapper.c` / `DocString.lean` の転写**。
  arm を散らすと原典との 1 対 1 対応が読めなくなる

### 生成テーブル — 「巨大ファイル」ではない
- `litedoc4-md/src/gc.rs` 1,696 行のうち **1,581 行が生成テーブル (実コード 115 行)**
- `litedoc4-global/src/v8_gc.rs` 821 行のうち **737 行が生成テーブル (実コード 84 行)**
- どちらも「Generated by …; do not edit」があり `--check` で再生成の一致を検査。
  **使い分けの禁止事項まで書かれている** (「nothing that produces bytes may use it at all」)

### 意図的な二重実装 (オラクル)
- `crates/litedoc4/tests/incremental.rs:342` `revision_is_forty_hex` — 「written a second time」と明記
- `crates/litedoc4-render/tests/link_index_fixture.rs:115` `last_entry` —
  「Spot check against the file itself rather than against this reader」

### 例外リストに見えるが違うもの
- `ref_pages.rs:73` `KNOWN_SUBSET_DIVERGENCE` — `:247-251` が
  `assert_eq!(counts.known_divergences, 1)` で**ちょうど 1 件**を要求するので 2 件目は黙って飲まれない

### 「死んだ枝」に見えるが消してはいけないもの (段 3 の調査から)

- **`global/facts.rs:364-366` の `is_token_separator` の第 1 項が今は冗長であること** —
  `:352-362` が「削っても答えは変わらない【実測 2026-08-12】が、2 つの表が独立に動くので
  union のまま残す」と明記し、`:581-614` のテストがその前提 (`unicode_basic_only == 0`) を検査している
- **`global/delta.rs:119-126` のショートサーキット** — 「これは最適化にすぎない【実測】、
  消しても出力もテストも動かない」と自認したうえでプロトタイプに合わせて残してある
- **`Delta::compute` (`global/delta.rs:76-83`) が製品コードから呼ばれていないこと** —
  `site.rs:213-215` は `changed` と `scan` を別々に呼ぶ (時間を分けて測るため)。
  `compute` は `tests/state_and_delta.rs:1962` が「**2 つの綴りが同じ答えを出す**」不変量として使う。
  これは重複ではなく **CLAUDE.md が言う「別経路が同じ答えを出すか」そのもの**
- `incr/prune.rs:423-446` が `read_dir` をソートしないこと (`:418-422` に理由) /
  `incr/impact.rs:378-386` が `write_text` を使わないこと (`:379-385` に理由) /
  `incr/merge.rs:25-98` の Lean 順序 — いずれもバイト列を決める意図的な選択で doc に決着がある

### 実測記録は現状に合わせて書き換えない

- **`incr/merge.rs:46`** の「six whole-package artifacts derived: 438 of 438 files byte-identical,
  31,617,612 B」と **`global/facts.rs:348`** の「the six artifacts and the state file are byte for
  byte what they were before it」は、**どちらも【実測 2026-08-12】の記録**で当時の母数。
  今は 9 件だが、**D14 で直すのは「今この crate が何を書くか」を述べている側だけ**
- CLAUDE.md「完走しなかった計測を完走したように書かない」「倍率は分母を明示する」

### フォークに見えたが違ったもの (誤検知として潰した)

- `incr/tests/ledger.rs:575` `run_build` (自由関数) と `:1503` `run_build` (それを呼ぶメソッド)
- `incr/tests/impact.rs:2072` `target_shaped` (`FakeIr`) と `merge.rs:2404` `target_shaped`
  (merge の base/inc ペア) — **別の型の別のフィクスチャで、名前が偶然一致しているだけ**

### 設計として意図されているもの
- `decl.rs:151-164` `used_by_html` が全宣言に空ブロックを出す —
  **ページのバイトを他モジュールに依存させないため。増分ビルドの成立条件そのもの**
  (依存させると 1 モジュールの編集が中央値 2・最悪 15 ページを陳腐化させる【実測 2026-08-22】)
- `pipeline.rs:848-861` `prune_removed` が `ir` を取らない — 引数の不在自体がガード
- `Extractor` enum の 2 経路 (`pipeline.rs:214`) — Lean 無しでテストする唯一の seam
- `resident.rs:1150` `write_executable` の rename 経由 — ETXTBSY 対策。
  docstring が「a fix for a measured symptom against a reasoned cause, and the cause is not itself
  measured」と限界を正直に書いている
- `#lidx1` を使うフィクスチャ — 後方互換の検査が消える
- by-name refusal のメッセージ群 (計 200 行超) — **製品の出力そのもの**
- `crates/litedoc4-render/tests/common/mod.rs:20` の `#![allow(dead_code, reason = …)]` —
  `expect` にできない理由が書いてある
- `tools/corpus-tests.txt` の「frozen」7 件 — 入力が永久に無いが意図的に inventory に残されている
- `benchmarks/tools/` の Python / TS / shell / C の混在 — CLAUDE.md
  「オラクルを同じ言語・同じ設計で書き直さない」の帰結
- **README.md** — 2026-08-19 の決定 (利用者向けは最終状態だけ) が守られている
  【実測: 「改名 / 以前 / かつて / 旧 / やめた / 移設 / プロトタイプ」の出現ゼロ】

## 15. 撤退ライン

**この計画を途中でやめる条件。**

1. **`RENDERER_ID` を上げないと通せない変更が出たら、その項目をやめる。**
   出力バイトが動いた時点でリファクタリングではない。**「小さいから」で通さない**
2. **テストを書けない整形はやらない。** 「テストが無いから壊れても分からない」箇所を
   「読みやすく」するのは、**壊れたことに気づけないまま壊す**のと同じ
3. **段 5 (shell) で、共通化した結果 1 本でも回せなくなったら、その 1 本を元に戻して先へ進む。**
   29 本は手で回すしかないので、全部を一度に共通化しない
4. **段 7 (Lean) は「読んで判断する」で止まってよい。** 分割が `build.sh` と `lakefile.lean` の
   2 経路を壊すなら、やらないことに価値がある
5. **T3 (現役でない compare 6 本) で、代替の `cargo test` が同じ検査をしていることを
   確認できないものは残す。** 道具を消すことと、その道具が守っていた主張を消すことは別

## 16. この計画が外れるとしたら

- **「同じ判断が 2 本ある」を潰すことが、実は 2 本必要だったと分かる場合。**
  オラクルの独立性 (`revision_is_forty_hex` / `last_entry` / `fnv1a64`) がその形で、
  **潰す前に「これはオラクルか」を毎回問う**
- **`lib.rs` 化 (R1) が `tools/corpus-tests.txt` 以外にも名前で依存しているものを壊す場合。**
  テスト名を読んでいるものが他にないか、`rg 'litedoc4::'` で先に探す
- **shell の共通化が、CLAUDE.md が記録している罠を新しい形で作る場合。**
  `tools/lib/*.sh` 自身が「出力と終了コードが食い違う」形になったら、
  **全 35 本が同時に嘘をつく**。だから `tools/lib/` は**作った当日に一度落として**から通す

