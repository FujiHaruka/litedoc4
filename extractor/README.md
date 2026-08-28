# extractor — litedoc4 の抽出器 (Lean のまま)

対象パッケージの olean を `importModules` で読み、モジュール単位の IR (schema 5) を書く。
**これだけが Lean で、外側 (IR 消費・レンダリング・増分・検索索引) は Rust**。
抽出器が Lean なのは速度の話ではなく、
**対象の Lean 環境の中でしか動けない**から — delaborator も `getEqnsFor?` も
`findDocString?` も Lean のプロセスの中にしか無い。

| ファイル | 行 | |
|---|---:|---|
| `Extract.lean` | 3,174 | 抽出器本体。IR schema 5 + `--link-index` |
| `build.sh` | 46 | `lake env lean` → `lake env leanc -rdynamic` の 2 段 |
| `build/` | — | 生成物 (171 MB のバイナリ + 2.7 MB の C)。**gitignored** |

## ビルドと実行

```sh
TARGET_REPO=/path/to/lean-project extractor/build.sh   # -> extractor/build/extract
litedoc4 extract --modules <list> --ir-dir <dir> --timings <file> \
  --extractor-bin extractor/build/extract --target /path/to/lean-project --jobs 4
```

litedoc4 側に toolchain も lakefile も Mathlib も置かない (CLAUDE.md)。環境は
`lake env` で対象から借りるので、**対象が `lake build` 済みであることがビルドの前提**。
バイナリは対象の toolchain に対して作られるため、**別の対象には作り直しが要る**。

直接叩く形 (`extract <modules.txt> <events.jsonl> [options]`) は `Extract.lean` の
ヘッダにある。製品の呼び手は `litedoc4 extract` と `litedoc4 incremental --serve`。

## 表面で効いている約束

理由は `Extract.lean` と `build.sh` の側に書いてある。ここは一覧だけ。

- **`--write-ir` は `--ir-dir` を必須にする**。既定は無く、`IR_DIR` 環境変数も読まない。
  欠けていたら**引数解析の時点で** exit 1 (`parseArgs`) — 抽出の最後まで走ってからでは、
  20 秒払った後に usage エラーが届く
- **`--serve` は常駐経路**。使うのは `litedoc4 incremental --serve` で、
  `litedoc4 extract` は `--serve*` を名指しで断る (`crates/litedoc4/src/extract.rs`)
- **`leanc -rdynamic` は load-bearing**。`importModules (loadExts := true)` が
  Lean インタプリタでモジュール初期化子を走らせ、実行中の実行ファイルからシンボルを解決する
  (Lake の `supportInterpreter := true`)。外すと
  "Could not find native implementation of external declaration" で死ぬ

## `--link-index <path>` — 依存クロージャの名前 → モジュール写像

`.lidx` を、**抽出のために読んだ環境から**書き出す (`writeLinkIndex`)。レンダラが
docstring の autolink を解決する入力。

doc-gen4 のサイトの `declarations/declaration-data.bmp` から作る経路を取らないのは、
それが上流の公開サイトと**同じ Lean / Mathlib** であることを前提にしていて、
対象では成り立たないから【実測】。

抽出を伴わずに写像だけ作る / 計測するときは直に叩く:

```sh
cd /path/to/lean-project && lake env /path/to/litedoc4/extractor/build/extract \
  modules.txt events.jsonl --skip-analyze --link-index link-index.lidx
```

**IR は 1 バイトも動かない** — `--link-index` を足した状態でフラグ一式
(`--equations --refs --write-ir --tagged-code --jobs 4`) を回し、下のゲートの参照 IR と
`diff -r` して**436/436 バイト一致**【実測 2026-08-15】。

### `--link-index-omit` と `--link-index-key`

どちらも `--link-index` と組でのみ意味を持つ (単独で渡すと usage エラー)。
実測は `benchmarks/results/lidx-own-half-2026-08-17.txt` と
`benchmarks/results/g3-stage-*-2026-08-17.txt`。

| フラグ | 何をするか |
|---|---|
| `--link-index-omit <modules.txt>` | ここに名前があるモジュールの**宣言群を書かない** (`@` 節には残す)。レンダラは自パッケージの名前を IR 由来の索引で先に解決するので、この 3.6% は読まれない — **落としてもサイトは 429/429 バイト一致**。落とす理由は速度ではなく、**そこだけが 1 モジュール編集で動く**ため (動くと `renderKey` が動き全ページ再描画になる) |
| `--link-index-key <token>` | 地図の隣に `<path>.key` を置き、次回**トークン一致 + `#lidx2` マーカー一致 + `@` 節が現環境と一致**なら**走査ごと飛ばす**。トークンは呼び手が作る不透明文字列で、抽出器から見えないもの (依存 olean の同一性 = `extractKey`、omit 一覧の中身) を担う |

製品側 (`litedoc4 build` / `incremental --serve`) は**両方を自動で渡す**ので、
利用者がこのフラグを意識することはない (`crates/litedoc4/src/resident.rs`)。
手で叩くときだけ意味がある。

### `.lidx` の 1 行にはソース行範囲が乗る (`#lidx2`)

依存へのリンクを版固定の GitHub blob URL (`…/Mathlib/Order/Basic.lean#L67-L67`) にするための
入力。宣言の行は `\t<name>\t<line>\t<endLine>`。値は `findDeclarationRanges?` の
`range.pos.line` / `range.endPos.line` で、IR の `line`/`endLine` と同じ 2 フィールド。

**行範囲が取れない宣言は 1 フィールドのまま残す** — 落とすとリンクごと消えるが、
範囲が無いだけならアンカーが落ちるだけ (doc-gen4 の `gh_nav_link` と同じ形)。
読む側 (`crates/litedoc4-render/src/link_index.rs`) は旧マーカー `#lidx1` も読み続ける。

行範囲を乗せる代償【実測 2026-08-16、n=5 ずつ → `benchmarks/results/m7a-summary.txt`】:

| | 行範囲なし | 行範囲あり (現行) |
|---|---:|---:|
| `.lidx` バイト | 8,465,776 | **10,464,171** (+23.6%) |
| 宣言数 / うち行範囲あり | 255,975 / — | 255,975 / **255,975 (100%)** |
| `linkIndex` フェーズ warm 中央値 | 0.927 s | **1.203 s** (+29.8%) |
| `linkIndex` フェーズ cold 中央値 | 1.504 s | **1.770 s** (+17.7%) |

参照木由来のオラクル 241,553 件に対し、`.lidx` から組んだ URL は
**235,185 件を突き合わせて不一致 0**【実測、母数と残り 3 バケットは同ファイル】。

## ゲート — 凍結バイナリとの IR バイト一致

同じモジュール一覧 (`litedoc4 modules --root … --lib InformationTheory`、432 件、
UTF-16 code unit 順) を**両側に同じファイルで**渡し、同じフラグ
(`--equations --refs --write-ir --tagged-code --jobs 4 --ir-dir <dir>`) で走らせて、
IR 木を全ファイル `cmp` する。

一覧を共有するのは、**抽出器が渡されたリスト順をそのまま `index.json` に書く**から
(`Extract.lean` の `--modules` の扱い) — 別々に作った一覧だと中身と無関係に落ちる。

| | |
|---|---|
| 参照 | `experiments-frozen` タグ時点の `experiments/stage7d/build/extract` (凍結。**実行するだけ、再ビルドしない**) |
| 候補 | `extractor/build/extract` |
| 結果 | **436/436 バイト一致** (432 モジュール + `index.json` + `deps/*.json` 3)【実測 2026-08-15】 |

**このゲートはもう回せない。** 参照側のバイナリは `.gitignore` 対象で
tag `experiments-frozen` にも入っておらず (ソースの `Extract.lean` は入っている)、
**ローカルファイル 1 個に依存していた**。**その 171 MB は 2026-08-16 に消した。**
回すには tag から `experiments/stage7d/Extract.lean` を取り出し、当時と同じ toolchain で
ビルドし直すところから要る。**上の 436/436 は書き換えない** — 2026-08-15 に
実際に出た結果であることは変わらない。**再現手段が無い実測**として読むこと。

`diff -r` も `IDENTICAL`。差分 0 / 欠落 0 / 余分 0。
