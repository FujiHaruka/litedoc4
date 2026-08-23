# リファクタリング — 一度もやっていない木の棚卸し

起票 2026-08-23。**このリポジトリは検証段階 (approach.md §7) と移設 (M1〜M8) と機能スイープを
通してきたが、リファクタリングを一度もやっていない。** v0.1 を締め、残件掃きも決着した今が、
**「動いているものを動いたまま整える」**唯一の空きどころ。

**状態: 段 0〜8 の全 62 項目が決着した【2026-08-23】。**
**「決着」は「全部やった」ではない** — **やらないと決めたものが 5 件ある**
(段 2 の S2 / 段 6 の C2・C3 / 段 7 の L1・L2)。**どれも理由を測ってから決めた**ので、
再検討するときは同じ測り方をやり直すこと。

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

#### 結果【2026-08-23】— **共有モジュールは作らなかった。述語だけ直した**

**段 4 の共有テストクレート (`crates/litedoc4-testutil`) はまだ無い**ので、計画が書いた
「共有モジュールに移す」はここではできない。**述語をその場で直し、`file_count` を
テストバイナリごとに複製した**【判断】 — 段 4 の U1/U3/U6 が畳む前提で、
畳む対象の一覧は下に置く。

直したのは **`is_dir()` の 6 箇所**で、計画が名指しした 4 つより 2 つ多い。
計画は `global.rs:997/1009` / `state_and_delta.rs:2046` / `merge.rs:1180` と書いたが、
**`state_and_delta.rs` と `merge.rs` はそれぞれ同じ関数の中に 2 つ目の `is_dir()` を持っていた**
(`corpus_reference` と `fixtures`)。同じヘルパの中で片方だけ直すのは、直していないのと同じ。

| ファイル | 関数 | 直した述語 |
|---|---|---|
| `global/tests/global.rs:990` / `:1004` | `corpus_ir` / `corpus_reference` | `LITEDOC4_IR` / `LITEDOC4_REFERENCE_GLOBAL` |
| `global/tests/state_and_delta.rs:2051` / `:2065` | 同上 (**バイト同一のフォーク**) | 同上 |
| `incr/tests/merge.rs:1191` / `:1197` | `corpus` | `LITEDOC4_BASE_IR` / `LITEDOC4_MERGE_FIXTURES` |

**一度落としてから通した**【実測 2026-08-23】。存在するが空のディレクトリを
`LITEDOC4_IR` に渡して `global::corpus_facts_match_the_prototype` を回すと、
直す前後で出るものが変わる:

```
# is_dir() のとき — 環境の問題が、コードの問題の顔で出る
panicked at tests/global.rs:952 (IrTree::open の expect):
  the corpus opens: Io { path: ".../emptydir/index.json",
  source: Os { code: 2, kind: NotFound, message: "No such file or directory" } }

# file_count のとき — 何を設定すればよいかを言う
panicked at tests/global.rs:989 (corpus_ir の assert):
  no IR tree at .../emptydir (empty or missing): set LITEDOC4_IR,
  or run this test through tools/corpus-gate.sh, ...
```

`tools/corpus-tests.txt:59-63` が「`m1/ref-pages` と `w7h/base-state` は空でディレクトリだけ残っている」と
書いている状態は今も続いているので、**これは仮定ではなく現況**。

**`base_ir.rs:37` の `index.json` 検査は触っていない** — ファイル数より強い
(**木が持っていなければならないファイルを名指ししている**)。同じ理由で
`state_and_delta.rs:1136` の `fs::read(&prototype)` も触っていない (ファイル自身を読む)。

##### 段 4 が引き継ぐもの — この項目が増やした重複

**`file_count` は 3 コピー → 6 コピー**になった【実測】。U3 の表は
`ref_pages.rs` / `pages.rs` の 2 版しか挙げていないので、**表に無い次の 4 本を足して読む**
(うち 3 本はこの項目が作った):

```
crates/litedoc4-incr/tests/impact.rs:1019
crates/litedoc4-incr/tests/merge.rs:1212              ← この項目
crates/litedoc4-global/tests/global.rs:1019           ← この項目
crates/litedoc4-global/tests/state_and_delta.rs:2080  ← この項目
```

- **綴りは 2 種で、違いは意図的**。5 本は「ディレクトリでなければ 0」、
  `ref_pages.rs:109` だけ「ファイルなら 1」を返す — 入力 3 つのうち `.lidx` が**ファイル**だから。
  `pages.rs:548` は同じ事情を `file_count(..) != 0 && file_count(..) != 0 && lidx.is_file()` と
  **呼び出し側で**書いている。**畳むなら `ref_pages.rs` 版が正**で、`pages.rs` の 3 項式は消える
- **入口のヘルパ自体もフォーク**: `global/tests/global.rs:987` / `:999` と
  `state_and_delta.rs:2048` / `:2060` の `corpus_ir` + `corpus_reference` は
  **バイト同一**【実測: 2 ブロックを比較】。U6 が挙げる `fnv1a64` ×4 / `copy_tree` ×2 と同じ形で、
  **同じ 2 ファイルに載っている**
- 畳んだ先の形は計画の `corpus_dir(var, default) -> PathBuf` でよいが、
  **`file_count` と 2 つに分けない** — 「空でないディレクトリか」を答えるのが述語の全体で、
  分けると `is_dir()` に戻す余地がまた開く
- **畳んではいけないもの 2 つ**: `base_ir.rs:37` (`index.json` の名指し) と
  `state_and_delta.rs:1136` (`fs::read`)。どちらもファイル数より強い主張をしている

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

#### 結果【2026-08-23】— **採ったのは X5 の方針ではなく S7 の方針。表は S7 の前に書かれている**

**上の表は良い調査で、判定は今も大半が正しい。だが「やること」の勧め (非公開 mod +
root への re-export) は採らなかった**【決定、オーケストレータ判断】。理由は 1 つだけ:
**S7 が同じ日にその逆の形を `litedoc4-render` と `litedoc4-md` に適用済み** (`bb7e158`) で、
規則が両方の `lib.rs` に書かれている。**方針が 2 つある木は、どちらか一方の木より悪い。**
X5 の表は S7 が入る前に書かれたもので、**「両 crate が既にこうなっている」という前提が
書かれた時点では存在しなかった**。

採った方針 (3 つの `lib.rs` に同文で書いた):

> **mod は `pub` のまま。root の `pub use` に載るのは 2 種だけ** — (1) **ワークスペースの他の
> crate が import するもの**、grep ではなくコンパイラが証明したもの。(2) **他に経路が無いもの**
> — 所属 mod が非公開で、re-export を落とすと `unreachable_pub` (CI は `-D warnings`) が出るもの。
> **値の *意味* の SoT がこの crate にあるものは残してよい**、理由を 1 行書いて。

手順も S7 と同じ: 候補を落として
`cargo check --workspace --all-targets --exclude <当該 crate>` を回し、
**他 package がエラーとして名乗り出たものだけ戻す**。

##### 数 — 3 crate 合計 **115 → 75**、40 件が root から降りた

| | ir 39 | global 22 | incr 54 |
|---|---:|---:|---:|
| (1) 他 crate が実際に import している | **22** | **4** | **31** |
| (2) 私有 mod なので re-export が唯一の経路 | **11** | **3** | **0** |
| (3) 意味の SoT として残す (理由 1 行付き) | 0 | **2** | **2** |
| `pub use` から外した | **4** | **13** | **21** |
| 項目そのものを `pub(crate)` に落とした | **2** | 0 | 0 |
| **残った re-export** | **33** | **9** | **33** |

**(2) が incr でゼロなのは、X6 が `error` を `pub mod` にしたから** —
`-incr` の 9 mod のうち非公開は `io` だけで、そこは re-export を 1 つも持たない。
**つまり `-incr` には「他に経路が無い」項目が存在しない。**

##### 計画の表に、コンパイラが「違う」と言ったもの

- **`incr::DepMapRecord` / `FileEntry` / `ImpactSummary` の 3 件は「必要」ではない**。
  表は「所属 mod が非公開なので re-export が唯一の経路」と書くが、
  **`merge` / `ledger` / `impact` はすべて `pub mod`**。3 件とも他 crate は import しておらず、
  **重複経路なので外した**。これは表の 1 行目 (「必要」) と 3 行目 (「重複経路」) の
  **分類の取り違え**で、判定基準ではなく事実の側が違っていた
- **`ir::DepMapEntry` は必要。ただし表が挙げる根拠は成り立たない**【実測】。
  `Index::dependency_maps: Vec<DepMapEntry>` (`model.rs:49`) と
  `IrTree::dep_map(&self, entry: &DepMapEntry)` (`reader.rs:134`) の 2 つで、
  役割の主張は正しい。**しかし re-export を落としても `unreachable_pub` は出ない** —
  rustc の到達可能性は公開フィールドと公開シグネチャを通って伝播するので、
  **既に「到達可能」と数えられている。名前を書けないだけ**。
  **同じ形が同じ crate にあと 2 つある**: `Ref` (`Decl::refs`) と `Tactic` (`ModuleFile::tactics`)。
  表はこの 2 つを挙げていない
- **方針の機械的な検査には穴がある、という一般形**【実測】。方針は
  「落とすと `unreachable_pub` が出るもの」を (2) の判定条件として書いているが、
  **`ir` の (2) 11 件のうち `unreachable_pub` が出るのは 2 件だけ**
  (`Result` / `MIN_SCHEMA_VERSION`)。内訳:

  | 何が証明したか | 件数 | 項目 |
  |---|---:|---|
  | `unreachable_pub` | **2** | `Result` / `MIN_SCHEMA_VERSION` |
  | `litedoc4-ir` 自身の統合テスト `tests/base_ir.rs` の E0603 のみ | **6** | `DeclNaming` / `Generated` / `GeneratedFact` / `SelectionRange` / `SorryFact` / `SorryKind` |
  | **何も証明しない** | **3** | `DepMapEntry` / `Ref` / `Tactic` |

  (`unreachable_pub` は全部で 4 件出たが、残り 2 件は `pub(crate)` に降ろした schema 定数。)
  **最後の 3 件は `lib.rs` のコメントが唯一の根拠**なので、そう書いた。
  `global` の `Error` も同じ形 (`build_global` の戻り型としてのみ到達可能で、lint は黙る)
- **`ir::name` が re-export しているのは 6 名ではなく 8 名**だった —
  今日 `page_path` が入っている (`e32b1dd`)。うち他 crate が import するのは
  `escape_module` / `module_components` / `module_path` / `page_path` の **4 名**で、そこまで減った。
  `is_letter_like` / `needs_no_escape` / `is_subscript_alnum` は元から re-export されておらず、
  そのまま。**「選び方の規則が無い」という指摘は正しく、今は規則がある**
- **`incr/lib.rs` は 6 mod ではなく 9 mod** (今日 `ordered` / `error` / `io` が入った、`2083cc1`)。
  **`litedoc4_incr::merge::merge` と `litedoc4_incr::merge` が両方有効なのは変わっていない** —
  S7 の方針は mod を `pub` に保つので、この曖昧さは消えない。
  **消えたのは「どちらが正か言うものが無い」の方**: root の名前は
  **`litedoc4` (bin) が import するから在る**、mod の一覧が surface、と `lib.rs` が言う

##### 名指しされた項目、1 つずつ

| 項目 | 判定 | 根拠 |
|---|---|---|
| `ir::SELECTION_RANGE_SCHEMA_VERSION` / `SORRY_SCHEMA_VERSION` | **`pub(crate)` に降ろした** | どの package も import していない (コンパイラ)。`model.rs` の 3 箇所を `crate::reader::…` に。doc との矛盾は消えた |
| `ir::DepMapEntry` | **残す** (2) | 上記。`unreachable_pub` は出ない |
| `global::FactsRun` | **残す** (2) | `mod site` が非公開。落とすと `site.rs:134` に `unreachable_pub`【実測】 |
| `incr::DepMapRecord` / `FileEntry` / `ImpactSummary` | **外した** | 所属 mod が `pub`。誰も import しない |
| `incr::RULE_LOST_OWNER` / `RULE_MOVED_ELSEWHERE` | **外した** | 誰も import しない。**`Witness` 自身が root に無い**以上、その `rule` が取る 2 値だけ root に置くのは兄弟を割る (S7 の `used_by_html` と同じ形)。今は 3 つとも `ownership` に在る |
| `ir::escape_component` / `unescape_component` | **外した** | 表のとおり重複経路。**`is_id_first` / `is_id_rest` も同じ**で、表は挙げていない |
| `global::DeltaTimings` | **外した** | 表のとおり |
| `incr::OLEAN_SUFFIXES` / `ORPHANS_IN_SUMMARY` | **外した** | 表のとおり |

##### (3) 「意味の SoT」に残した 4 件 — 基準は「外の誰かが合わせなければならない値か」

- `incr::EXTRACTOR_ID` / `RENDERER_ID` — 台帳のキーが取られる 2 つの互換トークン。
  §2.1 がこの計画全体を吊っている値で、render の `DIGEST_MARKER` / `DOCS_DIGEST_MARKER` と同型
- `global::STATE_FILE` / `STATE_DERIVATION` — キャッシュが載るファイルの名前と、その導出トークン。
  **`STATE_FILE` は既に 2 度綴られている**【実測】: `litedoc4/src/build.rs:238` が
  `"global-state.json"` を直に書いている。**root に在っても防げていない**ので、
  この 2 件は「残したから安全」ではなく「意味の出所はここだと言い続ける」ためのもの
- **`STATE_VERSION` は残さなかった** — 状態ファイル自身の schema 番号で、外に合わせる相手がいない

##### `cargo doc` が見つけたもの、と `cargo doc` には構造的に見えないもの

**intra-doc link が 12 本壊れ、`cargo doc` が全部見つけた**。うち
**`crate::[a-z_]` の grep に映るのは 1 本だけ** (`is_token_separator`) — 残り 11 本は
`crate::Delta` / `crate::Counts::used_by_edges` のような CamelCase。**S7 が書いたとおり。**

**そのうえで、`cargo doc` が構造的に見られない綴りが 9 件あった**【実測】。
`cargo doc` は**テストターゲットを document しない**し、`#[cfg(test)]` も off:

- **リンク 4 本**: `global/tests/state_and_delta.rs:1121` / `global/tests/global.rs:32` /
  `incr/tests/merge.rs:1629` / `global/src/artifacts.rs:696` (`#[cfg(test)]` の中)
- **コードスパン 5 本** (リンクではないので元から誰も検査しない):
  `render/src/assets.rs:71`,`:74` / `ir/src/name.rs:209`,`:294` /
  `global/tests/state_and_delta.rs:352`

**5 本のコードスパンを直したのは X6 と同じ理由** — 住所を動かした以上、直さないと嘘になる。
S7 が「触らない」と判断した 3 種とは別で、あちらは**元から古かった**もの、
こちらは**この変更が古くした**もの。

##### 動かしていないもの

- **出力バイトは 1 つも動いていない。** `RENDERER_ID` は `v4` のまま、`EXTRACTOR_ID` も無傷
  (**むしろ 2 つとも root に残す側の判断をした**)。依存は増やしていない
- **`pub mod` を `mod` にした箇所はゼロ。** 方針が「mod は `pub` のまま」なので、
  X5 が勧めた「非公開 mod 化」は 1 件も入っていない
- **他 crate の呼び出し元は 1 箇所も動いていない** — 外した 40 件はどれも他 package が
  使っていないことをコンパイラが言ったものなので、`crates/litedoc4` / `-render` / `-md` の
  `use` は 1 行も変わっていない。動いたのは**当該 3 crate 自身のテスト 5 ファイルの `use`**
  (root パス → mod パス) と、上の doc 21 箇所だけ
- `cargo test --workspace --no-fail-fast` は **39 バイナリ / 452 passed / 0 failed / 22 ignored** で
  変更前と同じ。**doctest は `--all-targets` に入らない**ので最後に必ず回した (S7 の教訓) が、
  今回は doctest 側の破れはゼロだった

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

#### 結果【2026-08-23】— **上限は 3 つでも 4 つでもなく 6 つ。expect 13 個のうち 4 個は発火しない**

`encode` に `/// # Panics` 節を書いた (`search_index.rs:119-141`)。**`Result` 化はしていない**
(計画どおり、別の判断)。

**計画の数え方を 2 つ直す (結果が SoT)**:

1. **「入力由来の値に対する `expect` を 13 個」の内訳が違う**【実測】。`encode` から届く
   `expect` は `put_len` の 2 個を含めて**ちょうど 13 個**だが、**そのうち 4 個はどんな入力でも
   発火しない** — `:97` と `:175` は `"checked above"` (直前の分岐と `:121` の `assert!` が
   境界を既に立てている)、`:150` は `shared` をループが 254 で止めている、`:208` は定数
   `RESTART`。**入力で発火しうるのは 9 個**、これに `assert!` が 1 つ。
2. **上限は 4 つではなく 6 つ**【実測: `:20-31` の layout を 1 行ずつ突き合わせた】:

| 上限 | 幅を決めている場所 | 発火する行 |
|---|---|---|
| kind ラベル 255 個まで、`Entry::kind` は 256 未満 | `kind_of` は 1 宣言 1 バイト | `:121` (assert) / `:184` |
| kind ラベル 1 個が 256 バイト未満 | ラベル自身の長さバイト | `:178` |
| モジュール 65,536 個未満 | module 列は 1 宣言 1 u16 | `:190` |
| 名前と、その `to_lowercase()` が 64 KiB 未満 | long-suffix escape と fold 節の長さ (どちらも u16) | `:94` / `:166` |
| 宣言 2^32 個未満 | `count` と fold 節の添字 | `:206` / `:162` |
| ファイル全体が 4 GiB 未満 | 52 バイトヘッダの全 offset / length | `:138` / `:221` |

**一番近いのはモジュール列で、8 分の 1** — Mathlib 全体で 8,169 モジュール
【実測 → `docs/verification-log.md`】。**計画の「【実測、R4】」は誤り**で、この計画の R4 は
CLI の入口を共有する項目。出所は検証ログ側。

**`decode` の `#[expect(clippy::missing_panics_doc, …)]` は残す**【判断】。理由は 2 つ、
どちらも「今も仕事をしている」こと: (a) `#[expect]` は**発火しなくなったときに警告する**ので、
`decode` の境界検査が将来削られて panic 経路ができれば unfulfilled として出る —
コメントにはできない仕事。(b) reason 行が「なぜ `# Panics` 節が要らないか」を書いていて、
`encode` に節ができた今、**対の非対称の説明そのもの**になっている。

**ただし clippy がこの 2 つを見ているわけではない**【実測】。`missing_panics_doc` は
`[workspace.lints.clippy]` に無いので、**`decode` の `#[expect]` 1 箇所を除いて木全体で off**。
書いた節が lint を満たしていることは**節の見出しを `# Limits` に変えて測って確かめた** —
`cargo clippy -W clippy::missing_panics_doc` の件数が **12 → 13** に増え、増えた 1 件が
`search_index.rs` の `encode` だった。**節を書けば黙る**ことの確認であり、
**節を消しても誰も気づかない**ことの確認でもある。

**`[workspace.lints.clippy]` に入れることは、この項目ではやらない**【判断】 — 木全体で
**12 件**出る (incr 6 / global 3 / litedoc4 2 / render 1)。「発火したら何が壊れたか 1 行で
言えるか」には答えられる (「公開関数が panic するのに doc が黙っている」) ので候補ではあるが、
**12 件を読んで 1 件ずつ節を書くのは X7 ではない**。件数は測ってあるので、やるときに
調査からやり直さなくてよい。

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

#### 結果【2026-08-23】— **15 → 1。ただし「同じ型で 2 通りの作り方」が要った**

`crates/litedoc4-testutil` の `TempDir` に**15 箇所すべて**が寄った。手書きの残りはゼロ。
折り込めなかったものは無いが、**型を弱めずに折り込むために、作り方を 2 つ名前で分けた**:

| | 意味 | 箇所 |
|---|---|---:|
| `TEMP.make(what)` | ディレクトリを**作って**返す | 13 |
| `TEMP.reserve(what)` | **作らずに**パスだけ返す | 2 |

`reserve` が要るのは `litedoc4-render/src/assets.rs` と同 `src/site.rs` で、
**その 2 本が検査しているのは「呼ばれた側がディレクトリを作ること」そのもの**
(`write_assets(&dir)` に付いた `.expect("the first write creates the directory")` と、
`write_page` の「2 階層上がまだ無い」)。コンストラクタが先に作ってしまうと、
**その主張が黙って消える**。`make` に寄せれば 15/15 と書けるが、それは型を弱めた側。

**プレフィックス 15 通りはそのまま**。各ファイルが
`const TEMP: TempDirs = TempDirs::prefixed("litedoc4-pages");` を 1 つ持つ形にした。
`TempDir::new(prefix, what)` にしなかったのは **`&str` が 2 つ並ぶ**ため — R8 が 3 つの
シグネチャから外したのと同じ弱さで、入れ替えてもコンパイラは何も言わない。
プレフィックスをファイルに 1 回束縛すれば、呼び出しには引数が 1 つしか残らない。

**`prune.rs` に無かった分岐 (U6) は、実際には 5 ファイルに無かった** —
`incr/src/prune.rs` / `litedoc4/src/packages.rs` / `render/src/assets.rs` /
`render/src/site.rs` / `render/src/config.rs`。U6 が prune.rs だけを挙げたのは、
**U6 の視野が incr / global だった**ため。

- **代わりに入っていたのは `{what}` の生値。今日の引数では 1 バイトも違わない**【実測】 —
  この 5 ファイルの引数は**すべてリテラル**で、最長 20 文字 (`prune-assets-orphans`)、
  全部 `[a-z-]`。**`slug` は恒等写像で、生値に依存していた呼び出し口は 1 つも無い**。
  逆に、`slug` を持っていた 10 ファイルの方は**リテラルでない引数を渡す**
  (`tests/pages.rs` の `&case.what` はフィクスチャの値) — 分岐の有無は偶然ではなかった
- **分岐が買っているもの**: `/` を含む名前は、ディレクトリを **`Drop` が消すパスより
  1 階層深く**作るので、上の階層が残る。`litedoc4/tests/extract.rs` の `shell_quote` の
  docstring (「The temporary paths hold a process id and a counter, never a quote」) は
  **この分岐が根拠**で、それを持たない 5 ファイルではその文が保証されていなかった

**`incr/tests/impact.rs` には `Drop` そのものが無かった**【実測、計画に記載なし】。
`struct TempDir` と `impl TempDir` はあり、**`impl Drop` だけが無い**。症状は静かで、
テストは全部緑のまま、溜まるのは OS の一時ディレクトリの側:

```
$TMPDIR に残っていた litedoc4-impact-* : 2,276 ディレクトリ / 23 MB
残っていた他のプレフィックス           : 1 (litedoc4-deps-docs-bad-77040)
```

CLAUDE.md「誰も消さないので溜まる」の小型版。**共有の `Drop` が付いたので今後は残らない** —
これが呼び出し口の振る舞いを変える唯一の変更で、変わったのは「消す側が増えた」こと。

**`tests/pages.rs` のコメントは、移した先で真になるように書き直した。**
元は「Hand-rolled rather than a dependency: it is ten lines and **the workspace has no other use
for one**」で、**同じクレートに他に 2 つ (S8 の後は 3 つ) あったので事実として偽**。新しい文:

> Not because the workspace has no other use for one. It had fifteen, spread over four crates,
> and this is the one they folded into. It is hand-rolled because `tempfile` would be an external
> crate, and an external crate is a licence and an advisory decision here even as a
> `dev-dependency` — `deny.toml`'s `[graph]` sets no `exclude-dev`.

**理由を消さずに、理由を正した** — 依存を入れない根拠は「使い道が無い」ではなく
`deny.toml` の側にある (§2.3)。

**`Drop` を壊す実験**【実測】 — `remove_dir_all` の行を消して
`cargo test --workspace --no-fail-fast` を回した。

- **落ちたのは `litedoc4-testutil` 自身の `the_directory_is_gone_when_the_value_is` 1 本だけ。**
  452 passed / **1 failed**。**折り込んだ 15 箇所はどれも気づかない** —
  どのテストも自分の `TempDir` が落ちた後を見ないので、見る手段が無い
- **つまりこの変更の前は、workspace 全体でこれに気づくものが 1 つも無かった。**
  impact.rs の 2,276 個は「全部緑」のまま溜まっていた。だから testutil 側に 1 本置いた
- 実験の副産物としてその run 自身が **243 ディレクトリを残した**。
  **戻した後の全 run の直後は `$TMPDIR` の `litedoc4-*` が 0 件**【実測】

**この項目の外に出た発見 — `env::temp_dir()` 直呼びが「さらに 6 箇所」ある**【実測】。
`struct TempDir` ではないので、U1 の 15 件を出した grep に映っていない:

```
litedoc4-global/src/state.rs:296     litedoc4/src/httpd.rs:424
litedoc4/src/deps_docs.rs:983        litedoc4/src/httpd.rs:607
litedoc4/src/deps_docs.rs:1018       litedoc4/tests/resident.rs:218
```

どれも末尾の `let _ = remove_dir_all(&dir);` で片付けるので、**panic した回は片付かない**
(上に残っていた `litedoc4-deps-docs-bad-77040` がその 1 つ)。**この項目では触っていない** —
6 箇所それぞれが別の事情 (httpd はサーバを、resident はプロセスを起こす) を持つので、
まとめて畳む前に 1 本ずつ読む必要がある。**5 箇所が `src/` 内**なので U2 の判断をさらに支える。
`litedoc4/src/resident.rs:1156` は**製品コード** (`write_executable` の ETXTBSY 対策) で §14。

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

#### 結果【2026-08-23】— **再評価: 差は縮まなかった。4 → 5 に増えている**

**計画が保留にした再評価を先にやった。** 計画はこう書いていた —
「段 1 の R1 で `packages.rs` のテストは `tests/` に出すので、その分は差が縮む」。

**縮んでいない。R1 はそれをやっていない**【実測 2026-08-23】:

| `src/` 内の `#[cfg(test)]` にある `TempDir` | 計画時 | 今 |
|---|---|---|
| `litedoc4-incr/src/prune.rs` | ある | ある |
| `litedoc4/src/packages.rs` | R1 で消える見込み | **ある** (`:530` から末尾まで 710 行) |
| `litedoc4-render/src/assets.rs` | ある | ある |
| `litedoc4-render/src/config.rs` | ある | ある |
| `litedoc4-render/src/site.rs` | — | **ある** (段 2 の S8 が足した) |
| 計 | 4 (→ 3 の見込み) | **5** |

R1 が実際にやったのは `main.rs` 1,773 → 57 行の分割で、**`packages.rs` は範囲に入らなかった**。
`read_manifest` / `module_roots` / `unquote` が今も `pub` でないので、テストは src 内にある。

**したがって U2 の決定は変わらない。根拠は当時より強い** — `tests/common/mod.rs` が
届かない場所が 4 でも 3 でもなく **5** ある。さらに U1 が見つけた `env::temp_dir()` 直呼び
6 箇所のうち **5 箇所も `src/` 内**なので、同じ差は次の項目でも効く。

**crate の形**:

```
crates/litedoc4-testutil/
  Cargo.toml   [dependencies] は空。publish = false は workspace.package から継承
  src/lib.rs   crate doc と `pub use temp::{TempDir, TempDirs}` だけ
  src/temp.rs  TempDirs (prefixed / make / reserve)、TempDir (path / Drop)、テスト 4 本
```

- **`members = ["crates/*"]` なので登録は不要**だった (予告どおり)
- **`dev-dependencies` に入れたのは 4 crate だけ** — `litedoc4` / `litedoc4-render` /
  `litedoc4-incr` / `litedoc4-global`。`litedoc4-ir` と `litedoc4-md` は使わないので入れておらず、
  **`cargo machete` は無言**【実測: "didn't find any unused dependencies"】
- **依存ゼロ**。`tempfile` を入れない根拠は「使い道が無い」ではなく `deny.toml` の側にある
  ことを `temp.rs` の docstring に書いた (→ U1)
- **NOTICE は動かない** — `provenance-gate.sh` は `cargo tree -p litedoc4 -e normal` なので
  dev の辺を歩かない

**テストバイナリは 1 本増え、inventory は動かなかった**【実測、`--verify-list` を回して確かめた】 —
新 crate は `#[ignore]` を 1 つも持たないので `corpus-gate.sh` の `listed()` はそのバイナリから
0 件しか読まない。`tools/corpus-tests.txt` は **1 行も触っていない** (`ok (21 tests)`)。
`cargo test --workspace` は **39 → 41 バイナリ / 452 → 457 passed / 22 ignored のまま**
(足したのは testutil の単体 4 本と doctest 1 本)。

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

#### 結果【2026-08-23】— **前半 (corpus 入力) だけ。表の件数は 3 行が過少だった**

**`crates/litedoc4-testutil/src/corpus.rs` (411 行) を作り、corpus 入力の在庫を 1 ファイルに集めた。**
X3 が段 4 に引き継いだ `file_count` 6 コピーと、この表の `env_path` / `DEFAULT_IR` 行がここで閉じる。
**HTML ヘルパ (`unescape` / `anchors_of` / `show` / `attr_values` / `between` /
`first_difference` / `Case::index`) は未着手** — 置き場所が違う (下記)。

**数え直したら表が 3 行外れていた**【実測】:

| ヘルパ | 表 | 実測 |
|---|---|---|
| `DEFAULT_IR` (`…/w7h/base-ir`) | 4 箇所 | **10 箇所** (render 5 / ir 1 / global 2 / incr 2)。<br>`DEFAULT_BASE_IR` という別名の 3 本を数えていない |
| `show` | 4 版 | **5 版** (`differential.rs` が表に無い) |
| `Case::index()` | 2 (page_parts / autolink) | **4** (fragment / docgen4_linked も同名)。<br>ただし**一致するのは 2 だけ** — 残り 2 は別の世界を建てている (`build` vs `build_with_a_page_for_every_module`) |

**畳んだことで初めて見えた事実が 2 つある。どちらも「重複」ではなく仕様**:

1. **1 本の木に 3 つの変数名** — `…/m1/ref-pages` は `LITEDOC4_REF_PAGES` /
   `LITEDOC4_REFERENCE_PAGES` / `LITEDOC4_PAGES` で呼ばれる。ゲートが 1 つずつ設定するので、
   「片方の比較のためだけにページを持っている機材」が成立する。`tools/corpus-tests.txt:64-66` が列挙している
2. **1 つの変数名に 2 つの既定** — `LITEDOC4_LINK_INDEX` は render の corpus テストでは
   `…/w7c/linkindex/link-index.lidx`、`link_index_fixture.rs` と `packages.rs` では
   `/private/tmp/litedoc4-m7a/link-index.lidx`。後者は
   `benchmarks/tools/check-lidx-urls.sh` の `WORK_DIR` で、この 2 本はそちらに結合している。
   `LITEDOC4_DOCGEN4_TREE` も同じ形 (片方は `LITEDOC4_TARGET` からの導出)

**設計**: `Input { what, var, default }` の**フィールドは私有**で、`pub const` 13 本だけが構築する。
呼び出し側は変数名と既定パスを自分で綴れない — 6 コピーが生まれた経路がこれで閉じる。
`path()` (在否検査つき) / `path_built_by(how)` (作り方を 1 行足す) / `raw()` (無検査)。
**`raw()` は 2 箇所のためだけにある** — `base_ir.rs` の `index.json` 名指しと
`state_and_delta.rs` の `fs::read`。どちらも**ファイル数より強い**主張で、X3 が「畳むな」と書いたもの。
「自分で検査する」は「強い検査をする」と同じではない、と doc に書いた。

**挙動が変わった箇所** (すべて意図的、いずれも X3 の一般形):

- `autolink.rs` / `page_parts.rs` / `fragment.rs` の `LITEDOC4_IR` / `LITEDOC4_LINK_INDEX` は
  **在否検査を持っていなかった** — 空の IR を渡すと `IrTree::open` の serde エラーで落ちていた。
  今は変数名を言って落ちる
- `link_index_fixture.rs` / `packages.rs` が `is_file()` から述語 1 本に移った。
  ファイルに対しては同値。**ディレクトリを渡したときだけ弱くなる**が、X3 の
  「述語を 2 つに割らない」を優先した
- `pages.rs` の `… && lidx.is_file()` 第 3 項が消えた (X3 の指示)

**新しい検査は 9 本、すべて一度落としてから通した**【実測】。実装を 9 通りに壊して赤を確認
(`is_dir()` に戻す / `file_count` の fallback を `0` や `1` に固定 / 述語を反転 / `raw()` に検査を足す /
`path_built_by` が `how` を捨てる など)。**そのうち 1 通りが自分の欠陥を出した** — 共有した
フォーマット文字列が `None` の枝で `or ` を落としていて、`set {var}, run this test through …` と
出ていた。検査を「panic したか」から**文全体の一致**に強めて直した。

**`cargo doc` が設計を 1 つ却下した**【実測】: `lib.rs` の `pub mod corpus;` に `///` を付けると、
rustdoc は `corpus.rs` の `//!` ヘッダと連結した**全体を `lib.rs` の側で解決する**。
ヘッダの intra-doc リンク 8 本が全部壊れた。`//` の普通のコメントにして解決。

**`test`: 457 → 466 passed / 0 failed / 22 ignored** (増えた 9 本が上記)。5 種すべて緑。

#### 結果【2026-08-23】— **後半 (HTML / テキストヘルパ)。置き場所が 2 つに割れた**

**行き先は 1 つではない**【判断】。`litedoc4_render` の型か HTML を知っているものは
**`crates/litedoc4-render/tests/common/mod.rs`** (既存)、文字列処理だけで 2 crate が要るものは
**`crates/litedoc4-testutil/src/text.rs`** (新規)。**testutil に `litedoc4-render` を依存させない**ため。
`common/mod.rs` を `mod common;` する test binary は **3 → 5** に増えた。

**`show` は 5 コピーだが方針は 2 つで、片方は欠陥**:

| 版 | 場所 | 挙動 |
|---|---|---|
| A | `fragment.rs` | `\n` / `\t` を名前化、印字可能なものは非 ASCII も残す |
| B | `autolink.rs` | **A から `'\t'` の枝が落ちている** ← U3 が言う「失敗メッセージが比較できない」の実体 |
| C | `differential.rs` | ASCII graphic と空白以外は全部 `<U+XXXX>` |
| D | md の 2 本 (バイト同一) | C を 200 字で打ち切り |

**A と C は好みではなく対象の違い**なので 1 本に畳まず、`show` (=A) / `show_ascii` (=C) /
`show_ascii_head` (=D) の 3 本にして**どちらを選ぶかを doc に書いた**。根拠は数えた
【実測 2026-08-23】: render 側のフィクスチャは非 ASCII を **3,409 / 2,126 字**持つので
`<U+2082>` にすると読めなくなる。md 側は結合文字 (U+0301 等) を **12 / 28 個**持つので、
文字を出すと `expected é, got é` になる。

**`first_difference` は 3 コピーだが、同じ関数は 2 つだけ。** `page_parts.rs` (窓 40/90、
ラベル frozen/here) と `md/docgen4.rs` (窓 40/40、`show` 経由、ラベル doc-gen4/here) を
`Diff { want, want_label, got, got_label }` + `report()` / `report_escaped()` に畳んだ
(**ラベル 2 本を引数の並びで渡さない** — §4 R8 が 3 つの署名から外した弱さ)。
窓は 1 つの定数にした (40/90) — **同じ corpus の 2 つの失敗が比較できることが要求そのもの**。
**`ref_pages.rs` の同名関数は畳まない** — 片側の窓を返すだけでラベルも 2 者比較も無い。
§14 の「名前が偶然一致しているだけ」なので **`context_where_they_part` に改名**した。

**`Case::index()` は 4 コピー、一致は 2 だけ** (`page_parts` と `autolink` が 8 行のコメント込みで
バイト同一)。`common::name_index(ir_modules, known, lidx)` に畳み、**`fragment.rs` と
`docgen4_linked.rs` には「なぜ共有版ではないか」を 1 行ずつ書いた** (前者は `.lidx` を持たない、
後者は `build` であって `build_with_a_page_for_every_module` ではない)。**似ているが違う世界が
3 つあることは、1 文ずつ書く価値がある。**

**`#[expect]` が仕事をした**【実測】: `fragment.rs` と `autolink.rs` のファイル頭にあった
`#![expect(clippy::format_push_string, …)]` は **`show` のためだけ**にあり、`show` を出したら
両方 unfulfilled になって `-D warnings` で落ちた。`text.rs` 側は `write!` で書いたので抑制自体が要らない。

**畳めなかったもの・畳まなかったもの**:

- `attr_values` は**本体はバイト同一だが doc が違った** — `page_parts.rs` の方に
  「先頭の空白が `id` を `data-name` の中にマッチさせない」という 1 文が余分にある。**長い方を残した**
- `ref_pages.rs` の `wrapped(page, open, from)` は `between` と別物 (`(usize, &str)` を返し
  `</div>` を直書きしている)。**畳まない**

**挙動が変わったのは失敗メッセージだけで、アサートは 1 つも動いていない**【確認済】:
(1) `autolink.rs` が `\t` を名前化するようになった (これが直したかった欠陥)、
(2) `md/docgen4.rs` の窓が 40/40 → 40/90 (比較可能にすることが目的)、
(3) 同じく `String::from_utf8_lossy` をやめ `floor_char_boundary` に変えた
(**境界で切れると `<U+FFFD>` が出ていた**)。`differential.rs` / `md4lean.rs` / `page_parts.rs` の
メッセージはバイト同一で、`Diff` の書式は単体テストが綴りごと固定している。

**新しい検査 10 本 + doctest 1 本、すべて一度落としてから通した**【実測】。
**そのうち 1 本は最初トートロジーだった** — 窓幅の検査を `window.len() == BEFORE + AFTER` と
書いていて、`AFTER` を 40 に戻す変異が通ってしまった。定数を読まずに **130 を直に書く**形に
直したら落ちるようになった。**ゲートは自分では自分を検査しない** (CLAUDE.md) の小さな実例。

**`test`: 466 → 477 passed / 0 failed / 22 ignored**。5 種 + `cargo machete` すべて緑。

### U4 — `crates/litedoc4/tests/` の fake extractor が 2 本に分岐済み【U3 より重い】

- `tests/build.rs:197-263` と `tests/incremental.rs:1015-1067`。
  **前者が後者のスーパーセットで、共通部分約 40 行が二重管理**
  (`--corrupt` と deps スライス対応が build 側だけにある)
- **どちらも「fake extractor が焼いた IR を full generation と比べる」ゲートを持っている**ので、
  **片方の IR 生成規則が変わっても比較は成立してしまう**
- やること: `write_fake_extractor(path, Features { corrupt: bool, deps: bool })` の **1 本の生成器**に
- **統合しないもの**: `ModuleSpec` / `Live` (`tests/build.rs:60-300` と `tests/incremental.rs:684-1290`)。
  **フィクスチャの意味が違う 2 つを 1 つにすると、どちらの前提でテストが書かれているか読めなくなる**

#### 結果【2026-08-23】— **フォークが生き延びた理由は「位置で読んでいたこと」だった**

**生成器は `crates/litedoc4/tests/common/mod.rs` に置いた。`litedoc4-testutil` ではない**【判断】。
スクリプトが書くのは **extractor が所有する形式** (`schemaVersion` / `generator` /
`hashAlgorithm` / `leanVersion` / `dependencyMaps` は `extractor/Extract.lean` の綴り) で、
読み戻すのはこのディレクトリが試験している `litedoc4` バイナリだけ。呼び手は 2 つとも
`crates/litedoc4/tests/` にあり、`tests/common/mod.rs` はちょうどその 2 つに届く
(`litedoc4-render/tests/common/mod.rs` が同じ形の先例)。**`litedoc4-testutil` は
`tests/common/mod.rs` が届かないもの (= `src/` の中の `#[cfg(test)] mod tests`) のためにある**、と
その `lib.rs` 自身が書いている。ここには 1 つも無い。

**畳めなかったのは書く側ではなく、読む側だった。** `extractor-calls.txt` の読み手は 2 本で、
**読み方が食い違っていた**:

- `build.rs` の `Live::extractions` は `line.split_whitespace().nth(1)` — **位置**で読む
- `incremental.rs` の `case_extractor_contract` は `call.starts_with("--world ")` を**要求**する

**`--world` を持つ側が唯一「行の形を主張している」側**なので、1 本化するとその綴りが残る。
そのとき `build.rs` は `$WORLD` をモジュール一覧だと思って読み、ディレクトリを
`read_to_string` して落ちる。**実際に落として確かめた**【実測 2026-08-23】 — `extractions()` を
直さずに `--world` を先頭にすると `build` バイナリの **8 本**が
`the module list the extractor was handed: Os { code: 21, kind: IsADirectory }` で落ちる。
**位置で読むのをやめることがこの項目の本体**で、副作用ではない。

**`tr -d '\n' < "$MODULES" | tr ' ' '\n' > /dev/null` の 1 行は無意味だったので消した**【実測】。
`f73ded5` (M4) から在り、tag `experiments-frozen` の実物 (`stage7g/extract-once.sh`) に対応物が無い。
「モジュール一覧が読めることの確認」だとしても**その役は果たしていない** —
**パイプの終了ステータスは最後のコマンドのもの**なので、`$MODULES` が無くても
stderr に `No such file or directory` を出して **status 0 で先へ進む**。
CLAUDE.md 「パイプを噛ませた瞬間、見ている終了コードは最後のコマンドのもの」が、
**テストのフィクスチャの中に 4 か月埋まっていた**形。

**この項目が出した一番重い事実は、畳んだこと自体ではない**【実測】:
**incremental 側の `"dependencyMaps":[]` を読んでいるものが、外に 1 つも無かった。**
`litedoc4-incr::merge` は結合後のモジュールファイルから**その配列を計算し直す**
(`merge.rs:362-395`) ので、incremental 側の `index.json` に出鱈目な依存マップを差し込んでも
**`incremental.rs` の 19 本は全部緑のまま**だった。生成器に検査 4 本を足して初めて赤くなる。
**「テストが緑」は「その枝を見ている」ではない**の、この段で 5 回目。

**新規 4 テストは `build` と `incremental` の両方にコンパイルされる**ので `cargo test` は
**491 → 499**。変異 4 通り (`--corrupt` の腕を殺す / deps の複製を殺す / deps:false 側に
依存マップを漏らす / `extractions()` を位置読みに戻す) をすべて一度赤にしてから通した。

**畳まなかったもの**: `ModuleSpec` / `Live` (計画と §14)。
**incremental 側に deps 機能を「ただだから」付けることもしなかった** —
付けると 2 つの flavour が区別できなくなり、テストが今している主張が消える。

**6 種すべて緑。`$TMPDIR` に `litedoc4-*` の残骸 0 件。これで段 4 は完了。**

### U5 — `litedoc4()` / `stderr()` / `stdout()` / `code()` / `message()`

`crates/litedoc4/tests/` の 5 ファイル (`build.rs:1698` / `site.rs:36` / `incremental.rs:2538` /
`extract.rs:428` / `resident.rs:278`) に散在。バイナリを `Command` で起こす薄いラッパ。
`testutil` に置けば 5 本が 1 本になる。


#### 結果【2026-08-23】— **表の件数は合っていた。合っていないのは「数え方」の方だった**

**`crates/litedoc4-testutil/src/cli.rs` を作り、5 ファイル 44 箇所を畳んだ。**
`Cli { bin, cleared }` + `run` / `run_with_env` と、自由関数 `stderr` / `stdout` / `code` / `message`。
`S: AsRef<OsStr>` の総称で `&[&str]` と `&[String]` の 2 署名が 1 本になり、
**それだけのために存在していた `let borrowed: Vec<&str> = …` が 7 行消えた**。

**`stdout` は「フォークしていない唯一のヘルパ」に見えていたが、違った**【実測】 —
`fn` として 1 本 (`build.rs`) なだけで、**同じ式が `site.rs:253` と `incremental.rs:2466` に
直書きされていた**。**一般形: 名前を与えられなかったフォークは、名前を数えても出てこない。**
段 5〜8 の棚卸しにも同じ死角がある (計画の件数はすべて `fn`/定数の定義数)。

**`resident.rs` の `env_remove` 3 つは resident 専用のまま置いた**【判断】。
`Cli::at(BIN).clearing(&["EXTRACT_BIN", "TARGET_REPO", "LAKE"])` と書けるようにして、
**全体の既定にはしない** — ほかの 4 ファイルは環境変数を継承したままでよく、一律に消すのは
「どう走るか」ではなく「何を検査しているか」を変える。

**畳まなかったもの**: `extract.rs:174` は `Command::new(BIN)` を直に起こす
(`.current_dir(&world.root)` を渡す。**そのテストの主題が子プロセスの作業ディレクトリ**で、
共有ランナーはそれを運ばない)。`const` の doc にその理由を書いた。

`cli.rs` のテストは `#[cfg(all(test, unix))]` で `/bin/sh` を起こす。**skip ではなく
コンパイル対象からの除外**で、`cargo test --workspace` は `ubuntu-latest` でしか走らない
(`ci.yml` を確認済) ので、検査される場所では常に走る。

**環境の 2 本は構造体を覗かずに実子プロセスで検査した** — `env_remove` の枝を消す変異と
2 つのループを入れ替える変異は、**構造体を覗くテストなら両方通ってしまう**。
親側は `CARGO_PKG_NAME` (cargo が既に設定する) を使い、`std::env::set_var` を避けた。

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

#### 結果【2026-08-23】— **`fnv1a64` はオラクルではない。根拠を 3 つ取って doc に焼いた**

**`hash.rs` (`fnv1a64` ×4 → 1) と `tree.rs` (`copy_tree` ×2 → 1) を作った。**

**§16 が「潰す前にオラクルかを毎回問う」と書いているので、問うた**【実測 2026-08-23】。
答えは「オラクルではない」で、根拠は 3 つ:

1. **製品コードに FNV の実装が 1 つも無い** (`crates/*/src/` に 0 件)。この木が出荷するものの
   第 2 の綴りではない — 何とも食い違いようがない
2. **独立な実装は TypeScript で、このリポジトリに無い。** 比較相手の digest は
   `impact-expected.json` / `merge-expected.json` / `global-expected.json` のリテラルで、
   各ファイルの header が書いた者を名乗っている (`gen-impact-expected.ts` /
   `generatedBy: gen-global-expected.ts`)。生成器は `experiments/` と一緒に HEAD を離れた
3. ゆえに独立しているのは**プロトタイプのバイト列 対 この木のバイト列**であって、
   **ハッシュは比較の道具であって辺ではない**。比較が意味を持つには両辺が**同じ関数**を
   走らせる必要がある。**4 コピーは何とも独立していなかった**

**この 3 点を `hash.rs` の header に書いた** — 後の読み手が「独立性を回復する」つもりで
再びフォークしないため。

**`copy_tree` は同名が 3 本あるが、同一なのは 2 本だけ**【実測】。
`litedoc4/tests/incremental.rs:2584` は**別の関数** — 先に `remove_dir_all` し、その
ファイル自身の `tree`/`write` を通り、最後に `deps` を作る。**畳まず、定義に 1 行書いた**
(§14 の「名前が偶然一致しているだけ」の 4 例目)。

**既に閉じていたもの** (再作業せず確認だけした): `TempDir` ×6 と `prune.rs` の slug 欠落は U1、
`corpus_dir` は U3a。`litedoc4-md/tests/fuzz_corpus.rs:50` に似た形が 1 つ残るが、
`CARGO_MANIFEST_DIR` 配下のリポジトリ内フィクスチャで corpus 入力ではない。**畳まない**。

**変異 12 通りで新規 12 テスト + doctest 2 本を一度ずつ落とした**【実測】。
うち 1 通りは `copy_tree` に `remove_dir_all` を足す (= `incremental.rs` 版にする) もので、
**「畳んではいけない」ことをテストが言うようにした**。

**`test`: 477 → 491 passed / 0 failed / 22 ignored** (+12 unit + 2 doctest)。
6 種 (5 種 + `cargo machete`) すべて緑。**段 4 で残るのは U4 だけ。**

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

#### 結果【2026-08-23】— **T2 の表は二重に外れていた。7 本のうち 4 本は既に上書きでき、3 本は設定ですらない**

**`tools/lib/target.sh` を作り、`benchmarks/tools/env.sh` と `tools/*.sh` 7 本が source する。**
`tools/*.sh` が 1 本も source していない状態 (T1) はこれで終わり。

**表の「上書き不可」は 4 本について誤り**【実測 2026-08-23】。
`deps-docs-gate:131` / `watch-gate:86` / `incremental-reference:151` / `ledger-reference:29` は
**引数ループの前に置かれた既定値**で、どのループにも `--target) TARGET="$2"; shift 2 ;;` がある。
**環境変数で動かせないだけで、フラグでは動く。**

**残り 3 本は設定ではなくガードだった**【実測】。`build-gate:117` / `clone-gate:209` /
`target2-gate:93` のパスは「ここに書いてはいけない」という**拒否の主語**で、
`case "$CLONE" in "$TARGET"/*) … exit 2`、および olean の `strings` 出力にそのパスが
漏れていないかの検査に使われている。**上書き可能にしてはいけない** —
`TARGET_REPO` を無害なパスに export した瞬間、計測対象への書き込みが再び開く。
実際に測った:

```
TARGET_REPO=/tmp/harmless で $TARGET_REPO を読むガード  → ALLOWED (exit 0)
同じ arm が $TARGET_REPO_BASELINE を読む               → REFUSED (exit 2)
```

だから `target.sh` は**1 つのリテラルに 2 つの名前**を与える:
`TARGET_REPO_BASELINE` (上書き不能、ガードが読む) と
`TARGET_REPO`(上書き可、設定が読む)。**優先順位は フラグ > 環境変数 > baseline**。
`clone-gate:224` が子プロセス向けに `TARGET_REPO="$CLONE"` を export しているのも、
名前を分けるべき理由の 2 つ目だった【実測】。

#### §16 が警告した形が、実際に出た

**「`tools/lib/` は作った当日に一度落としてから通す」を実行したら、落ちなかった**【実測 2026-08-23】。
`target.sh` に構文エラーを足すと 6 本は exit 2 で止まるが、**`watch-gate.sh` は
ゲートを最後まで走らせて `WATCH GATE: ok — 12 check(s), 0 failed` と印字し exit 0 を返した**。
理由は `set -uo pipefail` (**`-e` が無い**) で、`source` の失敗は stderr に出るだけで先へ進み、
**構文エラーの手前までの代入は既に効いている**ので何も欠けて見えない。
**`tools/*.sh` 35 本のうち 11 本が `set -uo pipefail`** なので、これは 1 本の問題ではない。

**修正は一般形にした**: すべての source 行を `… || exit 1` にする。
`.` と `source` で挙動は同じで、`set -e` の側はもともと自力で止まるので損はない。
修正後は `watch-gate` も 0 → 1 になり、ゲートを走らせない。

**検証**: `bash -n` は `target.sh` + 7 本 + `env.sh` + `env.sh` の他の利用者 7 本すべて exit 0。
4 本の設定は `TARGET_REPO=/nonexistent-target-xyz` がそのパスに届き、`--target` がそれに勝つ。
3 本のガードは `TARGET_REPO` を別の値に export しても拒否する。
`apply-instrumentation.sh --check` の出力は変更前とバイト同一。
`cargo test` は 41 / 499 / 0 / 22 で不変、`--verify-list` も 21 で不変。

**完走したのは 1 本。回せなかったものを緑と書かない**: 7 本のうちこの機材で完走できるのは
`watch-gate.sh` だけで、**最終形に対して回して `WATCH GATE: ok — 12 check(s), 0 failed`**
(exit 0、`litedoc4 watch` の残骸なし、作業ディレクトリも自分で消えた)【実測 2026-08-23】。
ただし `target/release/litedoc4` は **8/22 のビルド**なので、これが検査したのは
「スクリプトが対象を解決して最後まで走るか」であって製品の今の挙動ではない。
残り 6 本は対象の `.lake` / 特定状態の release バイナリ / `/private/tmp/lean-doc-relay/**` の
フィクスチャを要するため**前置き部分 (対象の解決と拒否) までしか動かしていない** —
ただしそこが今回変えた範囲そのもの。**`shellcheck` はこの機材に無く、CI も回していない**ので、
足した `# shellcheck source=` 指示は誰も検査していない。**CI はこの 7 本を 1 本も呼ばない。**

### T3 — 現役でない compare / reference 6 本 (1,331 行) を棚卸しする

`{ledger,merge,impact}-{compare,reference}.sh` は **CI からも docs からも参照されず、
互いを参照し合うだけ**【実測】。6 本すべてが「`experiments/` が撤去されたので元のループは無い」と
コメントに書いている。`ledger-compare.sh:17-18` は代替も明言している:

> `cargo test -p litedoc4-incr --test ledger` makes the same comparison in process

行数: ledger-compare 139 / ledger-reference 157 / merge-compare 184 / merge-reference 299 /
impact-compare 203 / impact-reference 349。

**消す前に 1 件ずつ「`cargo test` 側が同じ検査をしている」ことを確認する。**
確認できなければ残す — **道具を消すことと、その道具が守っていた主張を消すことは別**。

#### 着手前の実測【2026-08-23】— **この項目の前提は成り立たない。着手する者は先にここを読む**

**「6 本が現役でない」も「CI からも docs からも参照されない」も誤り**【実測】。

**`*-reference.sh` 3 本は生きていて、消す候補にならない**:

- 3 本とも「**シナリオの唯一の定義**」で、`cargo test` 側の doc がそれを名指しして
  「in-process で再演する」と書いている — `impact.rs:204` / `:991`、`merge.rs:199`、
  `ledger.rs:158`。**道具を消すことと、その道具が守っていた主張を消すことは別**の、
  まさにその形
- **`merge-reference.sh` は corpus 入力を作る** — `$OUT/fixtures` を base IR から
  **決定的に**生成し (script header が明記)、それが `LITEDOC4_MERGE_FIXTURES` の実体
- 消す候補として残るのは `*-compare.sh` 側だけ (ループの相手だった `--impl ts` が消えたため)

**`tools/` の compare/reference は 6 本ではなく 11 本**【実測】 — 上の 6 本 +
`global-compare` / `incremental-compare` / `incremental-reference` / `render-compare` /
`site-compare`。**crate の doc から名指しされているものがある**:
`pages.rs` → `render-compare.sh`、`prune.rs:431` → `impact-compare.sh`、
`merge.rs:178` → `merge-compare.sh`、`litedoc4/src/lib.rs:8` → `ledger-compare.sh`。
**「参照されない」は `rg` の当て方が `tools/` と `.github/` に閉じていたため。**

##### この項目が拾うべき欠陥 — **実行できない指示が 1 つある**

`crates/litedoc4-incr/tests/merge.rs` の corpus テストが、入力が無いとき
`tools/merge-reference.sh --impl ts` を実行しろと言う。**`--impl` は 3 本のどれにももう無い**
— header に「2026-08-16 まで在った」と書いてあるだけ【実測】。今の正しい綴りは
`tools/merge-reference.sh --out <dir>` で、fixtures は `<dir>/fixtures`。
`--impl` は「どの実装が fixtures を**消費する**か」の選択で、**作る側は今も決定的に同じバイト列**。
直すのは `merge.rs` の `path_built_by(...)` と、その綴りを固定している
`litedoc4-testutil/src/corpus.rs` のテスト 2 箇所 (`should_panic` の expected と呼び出し)。
**U3a が逐語で運んだだけで、U3a が作った欠陥ではない。**

#### 結果【2026-08-23】— **1 本も消していない。消す項目ではなく、主張の鮮度を測る項目だった**

**11 本すべて残した**【実測】。計 2,456 行。**元の前提のうち正しかったのは 1 つだけ** —
「CI から参照されない」は **11 本とも 0 件**で正しい。「docs からも参照されない」「現役でない」は誤り
(→ 上の着手前の実測)。**7 本の compare は自分のヘッダに今走る recipe を持っている**ので、
「ループの相手が消えた」ことと「使い道が無い」ことは別だった。

**計画の行数が 1 件ずれていた**【実測】 — `ledger-reference` は 157 ではなく **159**。
6 本の合計は 1,331 ではなく **1,333**。他 5 本は一致。

**1. 実行できない指示を直した** (`96c3635`)。`merge.rs` の `path_built_by` と
`corpus.rs` の 3 箇所 (doc 1・`should_panic` の expected 1・呼び出し 1)。
**同時に、それを機械的に捕まえるテストを足した** —
`corpus::tests::every_path_built_by_instruction_names_flags_the_command_accepts`。
`path_built_by` の引数は `&str` なので**誰も見ていなかった**のが原因なので、
crates 配下の `path_built_by("…")` を全部拾い、名指しされた**フラグがコマンド側に在るか**を見る
(`tools/*.sh` は `case` アーム、`litedoc4` は `USAGE`)。**両方の枝を変異させて落ちることを確認した** —
`--impl` (shell 側) と `--outdir` (USAGE 側)。**言えることの限界も書いてある**:
シェル側はアームを**ファイル全体**から拾うので内部関数のアームも混ざる
(`merge-reference.sh` は `--inc/--removed/--exclude` を報告する)。
どの `case` が CLI かを当てるには 35 本のインデントを推測することになり、
**弱い検査より間違った検査の方が悪い**ので取らなかった。

**2. 一般形を測って、ゲートにしないことを決めた**【実測】。「スクリプトの `usage:` が自分のパーサと
一致するか」を 35 本に当てた結果:

| 向き | 該当 | 中身 |
|---|---:|---|
| usage が名指さないアームが在る | **26 本中 15 本** | 過半は `--help` (9 本)。残りも内部パーサの取り違え |
| **usage が名指すのにアームが無い** | **35 本中 0 本** | 見えた 3 本は全部こちらの probe の偽陽性 |

**前者をゲートにすると 15 件を例外リストで飲むことになる**ので足さない (§14「例外リストを持つ
比較器を作らない」)。**後者 (= `--impl` の一般形) は shell 側に 1 件も無い。**
偽陽性 3 本の中身は、`browser-gate` が `"$@"` を deno 側へ転送している / `provenance-gate` が
`case` ではなく `if` で見ている / `config-gate` の `--no-link-index` が
**`litedoc4 render` 側のフラグの説明**だった、の 3 通り。
**「フラグを綴る場所は `case` アームだけではない」が probe の側の欠陥。**

**3. 今は成り立たない主張を 2 つ直した。** どちらも「代替が in-process に在る」と書いていた:

- `ledger-compare.sh:17-18` は**両方の意味で誤り**【実測】 — 「同じ比較」でも
  「対象リポジトリが要る」でもない。prototype とのバイト比較は**再凍結せず削除された**
  (`ledger.rs:1-16`)。残っているのは `the_harness_scenarios_are_measured_on_a_synthetic_package`
  で、`FakeRepo` 上で走り `#[ignore]` を持たず **CI で走る** (`ledger.rs` に `#[ignore]` は 0 件、
  `corpus-tests.txt` にも `ledger::` の行が無い)
- `impact-compare.sh:17-18` は test 自体は実在するが、**HEAD からは到達できない** —
  `impact::the_corpus_matches_the_prototype` は `corpus-tests.txt` の **frozen** 区画
  (`LITEDOC4_PAGES = m1/ref-pages, emptied`) で、ゲートは attempt しない

**`render-compare` / `merge-compare` / `global-compare` の同じ形の主張は検査して正確だった** —
消さない。特に `render-compare` の「committed fixture に対して」は非 corpus のテスト 2 本
(`pages.rs:123`/`:143`) を指していて、`#[ignore]` の corpus テストの方ではない。
**代替を名乗る主張は 5 本中 2 本が腐っていて、3 本は生きていた。**

**4. `incremental-reference.sh` の usage に `--lib` を足した** — パーサに在り (`:183`)、
既定が `InformationTheory` で **`:389`/`:391` で実際に使う**のに usage が黙っていた。
`--target` を変える者はこれも要る。**T2 (対象パスの集約) が拾い残した 1 件**で、
上の表の「15 本」のうち、`--help` ではない側の実例。

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

#### 着手前の実測【2026-08-23】— **表は数としては当たっている。外れているのは表に無い 1 行**

**上の 9 行のうち 8 行は実測と一致した**【実測: 35 本 / 9,769 行を `/usr/bin/diff` と `md5` で照合】。
外れたのは**環境記録の 1 行だけ (5 → 7)** — `printf 'host …'` という**綴りで数えれば 5 は正しく**、
綴りがまったく違う薄い 2 本 (`ci-build:193` / `extractor-uniqueness:83`) が落ちていた。
**leg 3 の「名前を与えられなかったフォークは名前を数えても出てこない」がそのまま再現した。**

**表が落としている変種** (すべて実測): root 解決は `REPO=` 10 本の他に
**`HERE=` + `ROOT=` の 2 行綴りが 7 本**あり、実体は「root を求める 17 箇所 + `HERE` で足りる 5 箇所」/
`LAKE` は elan 絶対パス 11 本の他に **PATH 探索の `${LAKE:-lake}` が 3 本** (**畳めない** — CI と
ローカルで解決先が変わる) / 製品バイナリの検出は **6 綴り 17 箇所**で、**`release` を見る 11 本と
`debug` を見る 5 本が同居**している (**畳めない** — 名前ではなく既定値の差) /
`[ -x ]` 失敗時の終了コードが **1 が 5 本・2 が 9 本に割れている** /
`extra=` 走査は 4 本のうち**バイト同一は 3 本**で、`global-compare` は allowlist 比較、
`incremental-compare` は揮発ファイルを除外してからの比較 (**どちらも畳めない**)。

##### 表に無い欠陥 — **`-h|--help` の 9 本は「重複」ではなく既に壊れている**

`--help` を持つ **12 本のうち、腐らない綴り (マーカー方式) は 3 本だけ**【実測】。
残り **9 本は `sed -n '1,NNp' "$0"` と行番号をベタ書き**していて、**測った時点で 3 本が既に誤り**:

| 本 | 綴り | 実際のヘッダ末尾 | 症状 |
|---|---|---:|---|
| `publish-pages` | `2,25p` | 22 | **`set -euo pipefail` と `SITE=""` を usage として印字**、exit 0 |
| `config-gate` | `1,32p` | 35 | **文の途中で切れ、`--blind` を一度も出さない** |
| `pinned-dep-gate` | `1,36p` | 41 | 5 行落ちる |

**4 件目は同じセッションで作った**【実測】 — T5 が `publish-pages` に `lib/common.sh` を
source した瞬間、ヘッダが 4 行伸びて `--help` がシェルコードを 2 行**追加で**吐いた。
**「ヘッダを 1 行足すと黙って壊れる」が仮説ではないことの実演。**
どれも **CLAUDE.md「出力と終了コードが食い違う形」**で、`--help` は常に exit 0 を返す。

**直し方は行番号を数え直すことではない** — 9 本すべてを
`sed -n '1,/^set -/p' "$0" | sed '$d'` にした。**`set -` 行で止める**ので二度と腐らない。
数が合っていた 6 本では出力はバイト単位で不変、合っていなかった 3 本では正しくなる。
既にマーカー方式の 3 本は**触っていない** — あちらは `# usage:` から始める別の意図
(長い前書きを `--help` に出さない) で、変える理由が無い。

##### 畳まなかったものと、その理由

- **root 解決 17 箇所** — **sourced library には畳めない。ライブラリを見つけるのにパスが要る**。
  `tools/lib/target.sh` の `LITEDOC4_ROOT` は**呼ばれる側**のための名前で、
  `benchmarks/tools/env.sh` 経由で 4 本が使っている (**`rg` を `tools/` に閉じると「未使用」に
  見える** — T3 の前提を壊したのと同じ当て方の誤りを、同じセッションで踏んだ【実測】)
- **バイナリ検出** — `release`/`debug` と exit 1/2 の割れが**挙動の差**なので、
  綴りを 1 本にすると意味が変わる。統一は別の判断であって整形ではない
- **引数パースの骨組み** — `while`〜`done` ブロックが**バイト同一なのは 1 組だけ**
  (`render-compare` ≡ `site-compare`)。畳めるのは骨組みと共通アームだけで、ブロック全体ではない

##### 環境記録 — **7 本。畳めたのは `date` + `host` の 2 行だけで、残りは 4 つの欠陥**

**実測 7 本** (計画は 5): `build-gate:386` / `clone-gate:697` / `target2-gate:401` /
`watch-gate:447` / `incremental-reference:546` / **`ci-build:193`** / **`extractor-uniqueness:85`**。
後ろ 2 本が落ちていたのは綴りがまったく違うため (`printf` ではなく `echo` と裸の `uname -srm`)。

**畳んだのは `date` + `host` の 2 行**。5 本で **3 種に割れていた**ものを
`tools/lib/common.sh` の `record_host` にした。**macOS では出力がバイト単位で不変**【実測】。

**畳んだことで直った欠陥**: 5 本のうち **4 本は `sysctl -n hw.memsize` にフォールバックが無く**、
macOS 以外では `$(( / 1024 / 1024 / 1024 ))` が**シェルの syntax error を stderr に吐き、
RAM 欄が空のまま exit 0** になる【実測】。5 本目 (`watch-gate`) はフォールバックを持つが
**`0 GB` と書く** — これは**空欄より悪い**。空欄は欠けていると見えるが、`0` は計測値に見える
(「計測の誠実性」)。`record_host` は `/proc/meminfo` と `/proc/cpuinfo` を読み、
**どちらも答えないときは `?`** と書く。**3 経路すべて実測で確認した** (macOS / Linux 形式の
`/proc` / どちらも無い場合)。

**畳まなかった 4 つ。どれも整形ではなく判断が要る**:

1. **7 本のうち 5 本は計測の「後」に記録する**【実測: `conditions` の呼び出しは
   `build-gate:411` / `clone-gate:722` / `target2-gate:426` で、いずれも末尾 5〜7 行】。
   **どれも `set -euo pipefail` なので、フェーズが途中で落ちると conditions ファイルは
   1 バイトも残らない** — 条件が最も要るときに残らない。直すには
   「環境 (前)」と「結果 (後)」に割る必要があり、各本ごとの作業になる
2. **page cache の状態と peak RSS は 7 本すべてが落としている**【実測】。
   CLAUDE.md が「メモリ律速」「cold と warm を両方記録する」「`/usr/bin/time -l` を噛ませる」と
   名指ししている項目。`tools/*.sh` 35 本で `/usr/bin/time -l` は
   **`rebuild-own.sh:47` の 1 箇所だけ**で、しかも `| tail -25` に食われて残らない
3. **`mathlib rev` は `target2-gate` 1 本しか記録していない**【実測】。
   計測対象が Mathlib 全体に依存する以上、他の 4 本にも同じだけ要る。
   **`watch-gate` は `rustc --version` を落としている** — Rust 側の増分挙動を測るゲートなのに
4. **共有の環境記録は既に在るのに、35 本のシェルは 1 本も使っていない**【実測】 —
   `benchmarks/tools/record-runner.sh` (116 行) は nproc / pagesize / readahead /
   `/proc/meminfo` / `df` / **CPU キャリブレータ**まで残し、上の 7 本のどれより厚い。
   呼んでいるのは `.github/workflows/` の 3 箇所だけ。
   **`ci-build.sh` を呼ぶ 2 本のワークフローのうち、`record-runner` が在るのは `ci-template.yml`
   だけで `ci-action.yml` には無い**。統合するかは「CI のログ形式を変える」判断で、
   **この木には CI 出力を検査するゲートが無い**ので、走らせずには確かめられない

##### 残りの行は畳まなかった — **畳んで得があるのは「食い違っている」ものだけで、残りは食い違っていない**

表の残り 6 行 (`--out)` 15 / unknown アーム 8+7 / `LAKE=` 11 / `RUST_BIN` + `[ -x ]` 7 /
verdict 5 / `extra=` 3) は**どれもバイト同一**で、**直すべき差が無い**【実測】。
一方、同じ行の「畳めない」側 (`LAKE` の PATH 版 3 / `release` vs `debug` /
exit 1 vs 2 / `global-compare` と `incremental-compare` の `extra=`) は**食い違っているが、
畳むには挙動を決める判断が要る** — 整形ではない。**T4 の残りはこの二分にきれいに割れる。**

費用も測った: `RUST_BIN` + `[ -x ]` の 7 本は**全部 `REPO=` を持ち 4 本は既に `common.sh` を
source している**が、畳むと **3 本に `source` 行が増えて差引ほぼゼロ**。しかも
**代入 (先頭) と検査 (引数パースの後) は離れている**のが意図で、1 つの関数にすると
**バイナリが無い機械で `--help` が落ちる**。verdict と `extra=` の 5 本 / 3 本は
**compare 系にパス起点が無い**ので、畳むには T4 が重複と呼ぶブロックを 4 本に新設することになる。

**`make-target2.sh:88` の `OUT=$2` (非クォート) は欠陥ではない**【実測】 —
**代入の右辺は語分割もグロブ展開もされない**ので `OUT="$2"` と等価。
空白入りパスで確かめた。**綴りの差であって挙動の差ではない。**

### T5 — CLAUDE.md が記録している 2 つの罠は、共通化で構造的に防げる

- 「`trap … EXIT` の最後のコマンドの終了コードがスクリプトの終了コードになる」
  — `tools/e2e-micro.sh` が「E2E MICRO: ok」と印字して **exit 1** していた【実測 2026-08-18】
- 「パイプを噛ませた瞬間、見ている終了コードは最後のコマンドのもの」【実測 2026-08-18、同日 2 回】

**どちらも「1 本の正しい cleanup / run ヘルパ」があれば各スクリプトが再実装しなくてよくなる。**
`tools/lib/common.sh` に `cleanup_trap()` (必ず `if` で書く) と `run_logged()` (パイプを使わず
ファイルにリダイレクトして終了コードを保つ) を置く。

#### 着手前の実測【2026-08-23】— **2 つの罠のうち 1 つは `tools/` に存在しない。もう 1 つは条件が違う**

bash 3.2.57 (この機材) と 5.3.9 の**両方で同じ結果**【実測】。

**罠 2「パイプで終了コードを失う」は `tools/*.sh` には無い。** **35 本すべてが `pipefail` を
立てている**【実測: 24 本が `set -euo pipefail`、11 本が `set -uo pipefail`、合計 35】。
`pipefail` の下では `( exit 3 ) | tail -1` は **3** を返す (切ると 0)。
CLAUDE.md がこの罠を記録したのは**対話セッション側の話**で、そこは zsh、`pipefail` も
`PIPESTATUS` も無い。**`run_logged()` は、この木には無い欠陥に対する対策になる。**

**罠 1「trap が終了コードを上書きする」は `set -e` の下だけで起きる**【実測】:

| | 落ちて終わる | `exit 0` | `exit 7` |
|---|---|---|---|
| `set -uo pipefail` (11 本) | 0 | 0 | **7** |
| `set -euo pipefail` (24 本) | **1** | **1** | **1** |

上段では cleanup が失敗しても**スクリプトの終了コードは変わらない**。下段で 1 になるのは
「trap の中で失敗したコマンドが `set -e` を発火させ、trap を中断する」ためで、
**`exit 7` を書いていても 1 になる**。つまり **`set -uo pipefail` の 11 本はこの罠に免疫がある。**

**さらに、計画が書いた対策 (「必ず `if` で書く」) だけでは足りない**【実測】。
`cleanup() { local rc=$?; false; return "$rc"; }` は `set -e` の下で **exit 7 → 1**。
`false` で関数が中断され、**`return "$rc"` に到達しない**。正しい条件は 3 つ揃うこと:
**(1) 先頭で `$?` を捕まえる (2) 中の全コマンドが失敗しない (`|| true` か `if` ガード)
(3) 最後に `return "$rc"`**。(2) が欠けると (3) は走らない。

**EXIT trap を張っていて `set -e` の 6 本**が対象: `deps-docs-gate` / `extractor-uniqueness` /
`extractor-mismatch` / `corpus-gate` / `e2e-micro` / `publish-pages`。
`site-compare` / `render-compare` / `watch-gate` も trap を張るが `set -uo` なので免疫。
**無条件に嘘をつく本はもう無い** (e2e-micro は 2026-08-18 に直っている) **が、穴は 3 本に残る** —
`rm -rf "$WORK"` を張る `extractor-mismatch` と `publish-pages`、そして `cp` が失敗しうる
`e2e-micro` (**自分のコメントで「A failing `cp` still fails here」と認めている**)。
`rm` が失敗するのは**作業領域を長命プロセスが掴んでいるとき**で、CLAUDE.md の `litedoc4 watch`
の事例と同じ形。つまり T5 は**今出ている欠陥の修正ではなく、出方が分かっている欠陥の予防**。
なお **6 本のうち 4 本 (`corpus-gate` / `e2e-micro` / `extractor-uniqueness` /
`extractor-mismatch`) は CI が呼ぶ**ので、T5 の変更には CI の信号が付く【実測】 —
段 5 の T1+T2 が触った 7 本とは違う。

**T6 の基準も、この計測から書ける** — 「`set -uo pipefail` を選ぶ」は
**個別の失敗が集計対象 (データ) である**とき。`set -euo pipefail` の下で 1 つのコマンドの
終了コードだけが欲しいときは、`extractor-mismatch.sh:102-106` のように
`set +e` … `CODE=$?` … `set -e` で囲む (35 本で唯一の実例)。

### T6 — `set -e` の有無が割れている

`set -euo pipefail` 24 本 / `set -uo pipefail` 11 本。後者は compare 系に多く**意図的かもしれない**
(個別の失敗を集計して最後に `status` を返す形)。**どちらを選ぶかの基準が書かれていない**ので、
`tools/lib/common.sh` の冒頭コメントに 2 行で書く。

#### 結果【2026-08-23】— T5 と T6 は 1 つのファイルに落ちた

**`tools/lib/common.sh` (72 行) を作った。中身は `on_exit` 1 本だけ。**
`run_logged()` は**作らなかった** — 上の実測どおり、それが防ぐ欠陥は `tools/` に存在しない。

**`on_exit` は計画の `cleanup_trap()` より強い。** 計画は「必ず `if` で書く」= 呼び出し側の規律
だったが、実測が示したのは **`set -e` の下では規律では届かない**こと (中の 1 コマンドの失敗が
trap ごと中断させる)。だから `on_exit` は**渡された action を `set +e` の subshell で走らせ、
入ってきた `$?` をそのまま返す**。**呼び出し側は何も気をつけなくてよい。**
失敗した cleanup は**黙らない** — stderr に 1 行出る (終了コードは変えない)。
**変異で全形を確認した**【実測】: `false` / `rm -rf` の失敗 / `e2e-micro` を嘘にした
`[ -f … ] && cp …` のいずれでも `exit 7` が 7 のまま届く (素の trap では 1 になる)。

**繋いだのは `set -e` の 6 本だけ** — `corpus-gate` (2 箇所) / `deps-docs-gate` /
`extractor-uniqueness` / `extractor-mismatch` / `e2e-micro` / `publish-pages`。
`site-compare` / `render-compare` / `watch-gate` も EXIT trap を張るが `set -uo` で免疫があり、
**繋ぐにはパス起点を 2 本に新設する必要があった** (T4 が「重複」と呼ぶブロックを増やすことになる)
ので見送った。**代償は「`set` 行を変えると穴が開く」**ことで、だから T6 の基準を
`common.sh` の冒頭に書いた — **T6 は独立した項目ではなく、この代償の説明**だった。

**`extractor-mismatch` と `publish-pages` にはパス起点を新設した** (`HERE=`)。
穴 (`rm -rf "$WORK"`) が在るのがまさにこの 2 本なので、**費用は欠陥の在る場所に落ちている。**

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

### C3 — `setup-node` 13 箇所は**後回し** → **決着済 (下の「C3 の決着」)**

`node-version: "24.19.0"` が 7 ファイル 13 箇所にあるが、
**`tools/assets-gate.sh:48-56` が `mise.toml` と全箇所の一致を両方向で検査している**。
今壊れてはいない。C1 を先にやる。

---

### 結果【2026-08-23】— C1 は済んだ。**C2 の「揃える」はやってはいけない**

**C1: 12 箇所 / 6 ファイル / 192 行 → `.github/actions/setup-elan` 1 本 + 12 行**【実測】。

計画が外した点が 2 つ:

- **「toolchain のパスが 2 系統ある」は誤り**。12 箇所すべてが `e2e/micro/lean-toolchain` で、
  **綴りは 1 種、md5 まで一致**した。だから composite に**入力を持たせなかった** —
  呼び手が 1 通りしかない入力は、まだ誰も選んでいないパラメータでしかない
- **12 箇所すべて `runs-on: ubuntu-latest`**【実測】。`ci-browser-windows.yml` に在るものも
  ubuntu 側のジョブで、Windows 側は Lean を入れない。だから
  `elan-x86_64-unknown-linux-gnu` の直書きは正しく、**`runner.os` の分岐は誰も通らない枝**になる

**`ci-template.yml` と `.github/workflow-templates/litedoc4-docs.yml` は触っていない** —
この 2 本の elan は**別方式** (`elan-init.sh` を raw.githubusercontent から、キャッシュ無し)。
`elan-cache` を持たないので置換にも掛からなかった。

**C2 の `actions/checkout@v4` 2 箇所は直してはいけない**【実測、判断を覆す】。
2 箇所とも `ci-template.yml` に在り、**出荷テンプレートの逐語写し**である。
この workflow の存在理由は「テンプレートそのものの証拠であって、言い換えの証拠ではない」ことで、
ヘッダが `actions/checkout@v4` を**名指しで「テンプレートのもの、verbatim」**と書いている。
片方だけ v5 にすると、**この workflow が主張できることが消える**。両方上げるのは
**利用者向けテンプレートを変える判断**で、整形ではない。

**C2 の他の数も測り直した**: `FujiHaruka/information-theory` の checkout は **6 ファイル** (計画 6、一致) /
`lake exe cache get` は **6 ファイル 18 箇所** (計画 5、不一致) /
`env-before.txt` は **6 ファイル** (計画 4、不一致) で、**うち 2 本は `record-runner.sh` 経由、
4 本はインライン** — これは §8 T4 の「環境記録が 3 系統に分裂している」の CI 側そのもの。
**C2 を畳むなら T4 の環境記録と同じ判断になる**ので、独立した項目として扱わない。

#### C3 の決着【2026-08-23】— **畳まない。C1 が畳んだのは「検査されていない重複」だった**

**C1 と C3 は同じ「同一ブロックの反復」に見えて、種類が違う**【実測】。

| | C1 (elan) | C3 (setup-node) |
|---|---|---|
| 1 箇所の大きさ | **16 行** (cache / key / if / curl / PATH) | **3 行** (`- uses:` / `with:` / `node-version:`) |
| 箇所 | 12 (6 ファイル) | **14** (7 ファイル + `action.yml`。計画の「13 箇所」は `action.yml` を数えていない) |
| 一致を見ている者 | **居ない** | **`tools/assets-gate.sh`** が `mise.toml` の pin と**両方向**で突き合わせ、**見た本数を印字する** (`ci.yml:69` で毎 push 実走) |
| 畳んだ後の正味 | **192 行 → 12 行** | composite を足して**約 −13 行** |

**決め手は行数ではなく「検査されているか」**。C1 は誰も見ていない 12 個の写しで、
ずれても誰も言わなかった。C3 は **`mise.toml` が唯一の出所**で、14 個は**その写しであることを
毎 push 検査されている**写しである。しかも各箇所に**その旨のコメントが付いている**
(`# … the version is the one in mise.toml, and tools/assets-gate.sh checks that these two agree.`)。
畳むと、**検査されている重複が、検査されない間接参照に変わる** — ゲートが見る本数は 14 → 1 になる。

**`action.yml` の 1 箇所はどのみち畳めない**【判断】 — composite の中の `uses: ./…` は
**利用者側のワークスペース**を基準に解決されるので、出荷する action からリポジトリ内の
composite は指せない。C1 で `ci-template.yml` と出荷テンプレートを触らなかったのと同じ線。

**これで段 6 は終わり** — C1 は入れた、C2 は「やってはいけない」、C3 は「畳まない」。

#### CI に当てた結果【2026-08-23】— **5/6 緑。6 本目の赤は C1 のせいではなく、main が既に赤い**

ブランチ `elan-composite` に push して 6 本を `gh workflow run --ref` で回した (§13 の手順)。

| workflow | 結果 |
|---|---|
| CI (`ci.yml`) / lake package / browser gate on Windows / extractor portability / release (dry-run) | **success** |
| action (self-test) | **failure** — 5 ジョブ中 2 本 |

**赤は C1 と無関係**。**main の内容を別ブランチ (`elan-baseline`) に置いて同じ workflow を回したら、
まったく同じ 2 ジョブが同じように落ちた**【実測】。つまり **`ci-action.yml` は既に main で赤い**。
気づかれていなかったのは、この workflow が `action.yml` / `tools/ci-build.sh` / 自分自身への
push でしか走らず、**最後の成功が 2026-08-19、schema 5 が入ったのが 2026-08-21** (`8318e6c`)
だから。**その間に誰もそれらを触っていない。**

落ちる場所は `litedoc4 build`:

```
plan    incremental (continuing /home/runner/work/_temp/litedoc4-out)
detect  10 module(s): 10 to re-extract, 0 removed — render key moved
litedoc4: …/ir/modules/Micro.json is schema 4; this reader needs schema 5 or newer
```

**これは利用者に当たる欠陥**である — `action.yml` の増分状態キャッシュは
`key: litedoc4-state-<toolchain>-<sha>` / `restore-keys: litedoc4-state-<toolchain>-` で、
**IR schema が変わっても restore-key は当たり続ける**。**決着済 (下の「決着」) — 採ったのは (b)** —
(a) キャッシュキーに schema を入れる (b) **読めない schema の IR を「全部再抽出」として扱う**。
**(b) の方が一般形**だが製品の挙動変更になる。**「10 を再抽出」と言った後で古い IR を読んで
落ちている**ので、再抽出の結果がどこへ行ったのかを先に確かめること。

**C1 について検証できたこと / できていないこと**【実測】:
`hashFiles` は composite の中でも同じ値を出す — **キャッシュキーが変更前と 1 文字も違わず、
走った 11 箇所すべてが primary key で hit した** (12 箇所目はそのジョブが elan の段まで来ていない。
miss は 0)。逆に言うと **`curl | tar xz` + `elan-init` の
インストール枝は 1 度も走っていない**。枝の中身は逐語コピー (`shell: bash` を足しただけ) だが、
**「走らせた」と「見ている」は別**なので、**`gh cache delete` で elan のキャッシュを消してから
`ci.yml` の `e2e` ジョブだけ回し直した**【実測】 — `Cache not found` → `./elan-init -y
--default-toolchain` → `info: default toolchain set to 'leanprover/lean4:v4.31.0'` →
**同じキーで保存**、ジョブは success。**両方の枝を走らせて緑**なので main に入れた。

#### 決着【2026-08-23】— **(b) を採った。ただし「全部再抽出」ではなく「full generation に落とす」**

**計画が「先に確かめよ」と書いた点は、確かめたら前提が違った**【実測】。
「再抽出の出力先とキャッシュ復元先が食い違っている」のではない —
**再抽出は正しく `work/inc-ir-1/` に出ていて、10 モジュールすべて schema 5** だった。
落ちるのは**その後で base IR (`<out>/ir/`) を読む段**で、そこはまだ schema 4 のままである
(`ownership.rs:137` の `IrTree::open_unvalidated(base)` と `merge.rs:369` の
`read_module_file`)。**`detect` は間違っていない** — 「10 を再抽出」は正しい答えで、
**その答えを実行する経路が、置き換える前の木を読む**。

**再現は Lean 込みで取った**【実測】。`e2e/micro` を schema 5 で 1 度建て、IR の全 JSON と
ledger の `extractKey` を schema 4 相当に落として再実行すると、CI と 1 行ずつ同じになる:

```
detect  10 module(s): 10 to re-extract, 0 removed — render key moved (sourceUrl)
litedoc4: <out>/ir/modules/Micro.json is schema 4; this reader needs schema 5 or newer
```

**修正は `plan_of` に判定 1 本** (`build.rs` の `ir_is_readable`)。
`--out` の IR がこの版で読めなければ `Plan::Full("the IR under --out is not one this version reads")`。
**「読めない IR を全部再抽出として扱う」より 1 段強い** — 全部再抽出しても base IR を読む段は
残るので、**incremental の枝に入らないことが答え**になる。置き場所は
「前回の run から続けられるか」を答える他の 4 つと同じ場所で、**判断を 1 箇所に集める**形。

**index だけ読む** (1 ファイル。IR の pass ではない)。index がモジュール群を保証できる根拠は
**この関数より前に既にある 2 つの門**: 中断された merge は `complete` が false で捕まり、
schema が上がるときは extractor の identity 文字列が動くので**1 ラウンドで全モジュールが
再抽出される** (混在した木にならない)。`IrTree::module` の doc が「index はモジュールを
保証しない」と書いているのは正しく、**ここではその 2 つが埋めている**。

**(a) キャッシュキーに schema を入れる、は採らなかった**。action が schema を知るには
binary に尋ねるしかなく、**「この IR は読めるか」の判定が製品と action の 2 箇所に増える**。
製品が自力で回復するなら `restore-keys` はそのままでよい。

**一般形に引き上げたら、同じ前提が別の入力で崩れることが分かった**【実測、コードの読みと
テストで確認】。最初に書いた根拠は「index がモジュール群を保証する」だったが、**保証しない**:
`merge` は merged index の `schemaVersion` を **base のものそのまま**にする
(`merge.rs:445` の `base_index.clone()` は `moduleCount` / `declarationCount` しか
差し替えない) 一方、incremental の module ファイルは**そのまま複写**される。だから
**古い版の binary が新しい木に merge すると、index だけ新しい番号のまま、モジュールが古い木**が
できる。次に新しい binary が走ると `plan_of` の検査は通り、**同じ場所で同じように落ちる**。

そこで **`merge` が index に書く schema を「その木の下で最も弱い主張」にした**
(`weakest_schema`)。これで**この版が merge した木は過大申告できない**。
**この版より前の binary が作った木は直せない** — その木は今も最初のモジュールで落ちる。
**`plan_of` の検査が買っているのは「木ごと 1 つの古い版のもの」という、キャッシュが
実際に復元する形**であって、混在した木ではない。**コードのコメントもこの通りに直した**
(最初に書いた「index が保証する」は誤りだったので残さない)。

**テストは 2 本とも先に書いた** — `crates/litedoc4/tests/build.rs` の
`an_unreadable_ir_forces_a_full_generation` と `crates/litedoc4-incr/tests/merge.rs` の
`the_merged_index_claims_the_weakest_schema_under_the_tree`。**書いた時点で落ちることを確認**しており
(`ir/modules/Pkg.json is schema 4`, exit 1)、落ち方が CI と同じ形である。
検査するのは 3 つ: full generation を選ぶこと / IR がこの版のものに戻ること /
**次の run は incremental に戻る** (フォールバックが 1 回であって、居座る状態ではない)。

---

#### CI で決着した【実測 2026-08-23】— **`ci-action.yml` は 5/5 緑。2026-08-19 以来はじめて**

main に入れて `gh workflow run ci-action.yml --ref main`。**緑の理由が修正であることまで確かめた** —
落ちていた `standalone` ジョブのログに、**古い状態を復元した上で full generation に落ちた**ことが
そのまま出ている:

```
Cache restored from key: litedoc4-state-leanprover/lean4:v4.31.0-201df2e33fa31eae64e051a4f18fec8a87fdb229
plan    full generation (the IR under --out is not one this version reads)
detect  10 module(s) hashed
```

**キャッシュが偶然新しくなったのではない** — 復元したのは前と同じ古い状態で、
そこから経路が変わっている。**`restore-keys` は 1 文字も変えていない**。

**同じ run の `released` ジョブ (`uses: @v0.1.4`) も緑**で、これは**古い binary が
共有の状態キャッシュを読み書きしている**ことの実物である。上で書いた「古い版が新しい木に
merge すると index だけ新しい木ができる」は、**この workflow の中に経路がある**。

---

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

### 結果【2026-08-23】— **L3 だけやった。L1 と L2 は「読んで判断して止まる」(撤退ライン 4)**

**定義長は計画の数字のまま**【再測】: 103 定義 / 100 行超 5 本 / 200 行超 2 本、
最大は `run` (:2915) の 659 行、次が `probeAllTacticDocs` (:2248) の 224 行。

#### L3 — やった。namespace `Stage4b` → `Litedoc4` (4 行 / 5 箇所)

**「触ってはいけないもの」は計画が挙げた 1 種ではなく 3 種あった**【実測】:

| | 箇所 | なぜ触れないか |
|---|---|---|
| `sink.emit "stage4b.*"` | 18 | プロトコル (計画が挙げていた唯一のもの) |
| `("generator", Json.str "lean-doc/experiments/stage4b")` | :2838 | **IR のバイトに出る**。動かすと抽出キーが動く = **撤退ライン 1** |
| `fileName := "<litedoc4/stage4b>"` | 2 | Lean の `Core.Context`。失敗メッセージに出うる |

**3 種とも小文字 `stage4b` で、namespace は `Stage4b`** — だから case-sensitive な置換は
namespace 4 行にだけ当たる。**大文字小文字が安全弁になっている**のは偶然なので、
**置換する前に小文字側を数えてから当てた**。

検証は `tools/e2e-micro.sh` が **extractor を実際に建て直して 15/15 緑**
(ログに `reusing` 行が無いこと、binary の mtime がソースと同じ分であることを確認)。
**2 経路の一致 (item 4) は `ci-lake.yml`** — `extractor/**` を触ると push で走る。

#### L2 — 分割しない。**「順序が内容」より具体的な理由が出た**【実測】

`run` (659 行) は 10 個の phase の列で、各 phase は `t<X>0 → 仕事 → t<X>1 → sink.emit` の形。
**順序が内容であることに加えて、末尾 110 行 (:3430〜3541) の報告ブロックが全 phase の
局所束縛を読み直す** — `tImp1 - tImp0` / `linkIndex` / `probe` / `counters` / `irStats` /
`refUnique` / `byKind` / `missing` / `failures`。つまり **phase は順序だけでなく、
「報告」という第 2 の消費者を通じても結合している**。

だから phase を関数に出すと **25 個前後のフィールドを持つ run 状態**を作ることになり、
`let mut` の束を struct の束に置き換えるだけになる。**時間と数の報告が出力の一部**
(JSONL と標準出力) である以上、これは非本質の抽出ではない。

#### L1 — 分割しない (撤退ライン 4)

L2 で切る単位が無いと判定した以上、分割は「行数で割る」ことにしかならない。
そのうえ `extractor/build.sh` は**単一ファイル経路** (`lean -o Extract.olean -c Extract.c` を
1 本、`leanc` で 1 本) なので、分割すると `.c` が複数になり**リンク段を書き足す**必要がある。
`lakefile.lean` 側は import を辿るので自動で済み、**2 経路の非対称がここで初めて効く**。
**やらないことに価値がある**、という撤退ライン 4 の通りにした。

---

---

## 11. 段 8 — docs と掃除

### E1 — `docs/plans/feature-sweep.md` (829 行) の圧縮 — **済【2026-08-23】**

**828 → 498 行 (-40%)。** 畳んだのは**着手前の見積もり・触るファイル一覧・テスト計画**で、
8 件すべて完了済みなのでコードと git が持っている。**残したものを機械的に確かめた** —
`benchmarks/results/*.txt` **10 本**・doc-gen4 の issue 番号 **20 個**・節番号 (§1〜§9)・
項目ラベル (A-1〜C-4)・決定 1〜5 は**圧縮の前後で差分ゼロ**。これらは
`crates/litedoc4-ir/src/model.rs` / `reader.rs` / `tools/config-gate.sh` /
`e2e/README.md` / `docs/plans/b0-generated-decls.md` から参照されている。

**`tools/*.sh` は 4 本減った** — `assets-gate.sh` / `browser-gate.sh` / `corpus-gate.sh` /
`provenance-gate.sh`。うち 3 本は §5 の「CI が回すものの一覧」にしか無く、
**その一覧は文書自身が「`ci.yml` が SoT、記憶で並べない」と書いている**ので、
一覧ごと SoT への参照に畳んだ。`browser-gate.sh` は C-1 のゲート行に**戻した**
(あれは入口の実体で、一覧ではない)。

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

#### 結果【2026-08-23】— **両方消した。判断を仰ぐ必要は無かった**

`mutants.out` と `mutants.out.old` を削除した。**残すべき固有の記録は 1 つも無かった**【実測】:

- 2 つは **2026-08-16 21:01〜21:03 の 1 回の探索のビフォー/アフターの対**で、
  `.old` が 73 caught / **1 missed**、新しい方が 74 caught / 0 missed。対象は
  `decl.rs` の 74 mutant だけ (ワークスペース全体の 1,602 は未実施 → `quality-gates.md` Q10)。
- **生き残った 1 件の中身は 3 箇所に焼いてある** — `quality-gates.md` の Q10 本文、
  `crates/litedoc4-render/src/decl.rs` のコメント、そして**塞いだテスト自体が HEAD にある**。
- **結果はすでに腐っていた** — `caught.txt` のパスが `crates/lean-doc-render/…` で、
  **2026-08-18 の改名より前**の木のもの。その後の段 0〜8 で `decl.rs` は実際に動いている。
- **`.gitignore` 自身が「the run directory itself is disposable」と書いている。**

**目的はディスクではない** — 7.8 MB は空き 17 GiB に対して無意味で、目的は
「ルートに残った作業ディレクトリを片づける」ことだった。

**一般形**【ユーザー指摘】: **「ユーザー判断に寄せる」と書く前に、実物を見て
「寄せる必要があるか」を確かめる。** ここでは*何のためのもので何が失われるか*を
調べた時点で答えが決まっていて、判断は要らなかった。**目的を書かずに選択肢だけ出すと、
相手は判断できない。**

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

#### 結果【2026-08-23】— E3 / E4 は済み。**E3 の 1 件は「パス違い」ではなく「存在しない名前」だった**

**E3**: 2 件とも直した。
`docs/plans/feature-sweep.md:480` は**パス違い** (`tools/` → `benchmarks/tools/`) なので綴りを直し、
駆動する `tools/browser-gate.sh` も併記した。
**`docs/plans/assets-typescript.md:77` の `tools/search-gate.sh` は違う** —
**どのブランチのどの commit にも存在したことがない**【実測: `git log --all -- tools/search-gate.sh` が空】。
移動したのでも消したのでもなく、**doc の中で発明された名前**。検索を実際に検査しているのは
`tools/browser-gate.sh` が駆動する `benchmarks/tools/check-site-browser.ts` なので、そう書き直した。
**「実在しないパス」の 2 件が別種だったのは、機械検査が「今どこにあるか」しか見ないため。**

**E4**: `Cargo.toml` の `allow_attributes*` に、2 つの lint が**同じ属性を見ていない**ことを書いた。
加えて**件数を固定した** — `litedoc4_testutil` の
`tests::the_tree_has_one_inner_allow_and_this_is_it` が `crates/**/*.rs` を歩いて
`#![allow` が **1 件**であることを見る (実測: `litedoc4-render/tests/common/mod.rs:29` の 1 件のみ。
計画は `:20` と書いていたが移動していた)。**一度落として確認した** — `litedoc4-ir/src/lib.rs` に
理由付きの 2 件目を足すと、両方のパスを名指しして落ちる。
**歩いた本数も検査している** (20 本未満なら「ワークスペースを歩けていない」で落ちる) —
空振りで緑になるのが「skip で緑を返さない」の失敗そのものなので。

**E2 はディスクだけ見た**【実測 2026-08-23】: 空き **17 GiB** / `/private/tmp/lean-doc-relay` は
**34 MB** / `mutants.out` と `mutants.out.old` は在る (gitignored)。段 7 が対象リポジトリを使うので、
着手前にもう一度見る。


## 12. 順序と完了条件

**段 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8。** 安全網が厚い順 (§2.2)。
**段の中の項目は独立なので任意順**だが、段 1 の R1 (`lib.rs` 化) だけは同じ段の他より先。

各段の完了条件は共通:

1. `cargo test --workspace --no-fail-fast` が **499 passed / 0 failed** (増える分にはよい)。
   **これは下限で、段が進むごとに上げる** — 段 0 開始時 437、段 4 完了時 499。下限を据え置くと、
   60 本消えても緑になる
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

