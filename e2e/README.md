# e2e — 本物の Lean から本物のサイトまでを 1 本通す

単体テストは**抽出器を偽物に差し替えるか、手で書いた IR から始めるか**のどちらかである。
これは正しい判断で (Lean toolchain を要求したら誰も走らせない)、代償も 1 つだけ:
**抽出器とその下流の間の契約を検査するものが 1 つも無くなる**。`Extract.lean` が書く形を
変えても単体テストは全部緑のまま通る。ここはその穴を塞ぐ唯一の場所。

走らせるのは `tools/e2e-micro.sh`。**入力は 2 つあり、担当が違う**
(→ 下の「`consumer/` — なぜ micro と別なのか」)。

```
tools/build-lean-exe.sh --toolchain-from e2e/micro
tools/e2e-micro.sh          # micro/  — 宣言の形
tools/pinned-dep-gate.sh    # micro/ + micro-dep/ — 版固定できる依存 (git require に差し替える)
tools/lake-package-gate.sh  # consumer/ — Lake の配線
tools/purelean-gate.sh      # consumer/ — `lean_exe litedoc4` が消費者側でビルドできる
```

`micro/` is also **the published sample**: `.github/workflows/pages.yml` serves the
very site `tools/e2e-micro.sh` builds, at <https://fujiharuka.github.io/litedoc4/>.
So it wears two hats, and the second one decides how it is written — see
「触るときの注意」 below.

## なぜ Mathlib に依存しないのか

**計測対象は CI の判定には使えない** — import closure が数 GB あり、無料枠の外。
`micro/` が依存するのは **Lean core と、このリポジトリの中にある `micro-dep/` だけ**なので
`lake build` が約 1 秒、抽出器のビルドが約 17 秒【実測 2026-08-16、warm】で、無料のランナーで回る。
**ネットワークは要らない** — `micro-dep/` は path で require している。

抽出器が Mathlib 無しで立つのは `import Lean` しか書いていないから
(→ `extractor/Extract.lean`)。`lake env` で借りる環境は**このサンプルのもの**でよい。

## サンプルが持っているもの — 「対象が持たない形」

`git show rust-frozen:crates/litedoc4-render/tests/page_parts.rs` (tag の中にあり、HEAD には無い)
が記録している事実:

> **41 分岐のうち 9 つは、432 モジュール全部を通しても一度も発火しない** —
> `class` も `inductive` も `class_inductive` も無い、constructor が `mk` でない structure も、
> `ctor` member を持たない structure も、structure の range 内で宣言された継承 field も、
> field の implicit binder も、import の無いモジュールも無い。

curated な単体テストは**手で書いた IR** でこれらの分岐に到達している。だが
**実際のパイプライン (抽出器 → IR → ページ) を通ってこの形が描かれたことは一度も無かった。**
`micro/` はその形を**構成として**持つ:

| モジュール | 担当する形 |
|---|---|
| `Example/Basic.lean` | **import の無いモジュール**。docstring 付きの def / theorem / structure / instance / `abbrev` (L3-1 が名指しした形) / inductive |
| `Example/Notation.lean` | **`scoped notation`** — doc-gen4 が出せない唯一のもの。署名が `⟦n⟧` と印字されなくなったらここで出る |
| `Example/Unicode.lean` | **U1 / U2 の罠** — `𝒜` (U+1D49C) は BMP 外なので、UTF-16 順ソートと UTF-8 順ソートが食い違う唯一の領域。docstring 内の markdown (heading / code span / リスト) も |
| `Example/Shapes.lean` | **`class` / `class inductive` / 非 `mk` constructor / `extends` の継承 field / field の implicit binder** |
| `Example/Dep.lean` + `../micro-dep/` | **版固定できない依存** — path require なので manifest entry に `url` も `rev` も無い。モジュール名は **`«Dep-Aux»`** (ギュメが要る形)。**版固定できない依存へのリンク**と**`.lidx` の綴り差**がここを通る (下記) |
| `Example/Gen.lean` | **`@[ext]` が実現する宣言と、しない宣言** — inline の `@[ext]` / 後から来る `attribute [ext] Trip` / **1 つの位置に 2 つの親の子が 4 つ** (`attribute [ext] Quad Quint`) / `extends` の親射影 / そして**手書きの `@[ext] theorem`**。最後のものが要点で、**拡張に居ることは「生成された」を意味しない**ことをここだけが示す |
| `litedoc4.toml` + `docs/index.md` | **サイト設定** (feature-sweep C-3) — `title` と `index`。With no file at all every reader agrees trivially, so it is here for `tools/mv-s-gate.sh` (`render-front`) and `tools/mv-pages-gate.sh` (`path-titles`) to have something to compare |
| `docs/references.bib` | **The bibliography** — `references.html`, and three citations into it: `[deMoura2021]` in `Example`'s module docstring (the bare-key form, whose link text becomes the entry's tag), `[Theorem Proving in Lean 4][TPIL4]` in `Example.Basic`'s (the form that keeps its own text) and `[Graham1994]` in `Example.Math.displaySpan`'s. `tools/mv-s-gate.sh` holds the references data and the citations against each other (`render-references`, `render-citation`) |
| `Example/Math.lean` | **docstring の数式** (feature-sweep C-1) — インライン `$…$` / ブロック `$$…$$` / HTML が気にする文字を含む式 / **変換できない `\colim`**。最後のものが要点で、**失敗が `$…$` のまま残り、その件数が `work.mathFallbacks` に出る**ことをここだけが示す。対象は 5,079 docstring 中 3 span しか数式を持たないので、**対象では一度も通らない経路** |
| `Example/Sorry.lean` | **`sorry` の 3 形** (doc-gen4 #270) — 直接 `sorry` を書いた定理 / それに依存するだけの定理 / どちらでもない定理。**`sorry` は elaborate 済みの項の性質**なので、手書き IR では「抽出器が正しい値を入れたか」を検査できない。ここが唯一の経路 |

## 初回に出たもの【実測 2026-08-16】

このサンプルを最初に通した時点で、**レンダラの実欠陥が 1 件出た**。

`inductive` と `class_inductive` の **constructor がページに 1 つも描かれていなかった**
(当時のレンダラ `git show rust-frozen:crates/litedoc4-render/src/decl.rs` の分岐が
body を空のまま返していた。tag の中にあり、HEAD には無い)。search 索引には載っているので、
**検索で選ぶとページ先頭に着地する**という壊れ方をする。

**既存の 355 本のテストは 1 本も反応しなかった**し、**byte 再現ゲートでも原理的に出なかった** —
オラクル (doc-gen4 の参照木) 自体が inductive を 1 つも含まないページ群だったから。
「全件バイト一致は分岐被覆の証明ではない」の一段強い形:
**オラクルの入力に無い形は、何バイト一致しても見えない。**

回帰は `e2e/micro-expected/render/Example/Shapes.html` の `id="Example.Decision.no"` /
`id="Example.Decision.yes"` が持つ (`tools/mv-pages-gate.sh` の frozen arm reads them as ids on the drawn page)。

## path 依存を足して出たもの【実測 2026-08-17】

**2 件目も、依存を足した初回に出た。** `micro-dep/` を path で require した瞬間、
`tools/site-gate.sh` が **DEAD internal links 3 (1 distinct destination)** を出して落ちた。

**壊れていたのは相対リンクへのフォールバックそのもの。** `litedoc4` は依存のモジュールに
ページを書かず版固定 blob URL でリンクする (M7)。`ExternalLinks::href` は
「マップに root が無いモジュール」を**自パッケージのモジュール**とみなして相対ページリンクに
落としていたが、**版固定できない依存も同じ枝に落ちる** — 結果、**このサイトが決して書かない
ページへのリンク**が出る。死んだ 3 本は 3 経路とも別物だった:

| 経路 | 出ていたもの |
|---|---|
| ページ枠の import リスト | `<li><a href=".././Dep-Aux/Basic.html">«Dep-Aux».Basic</a></li>` |
| docstring 中の名前参照 | `<code><a href=".././Dep-Aux/Basic.html#DepAux.marker">DepAux.marker</a></code>` |
| 署名・equation 中の定数リンク | 同じ href |

**直した方針は「版固定できない依存にはリンクを張らない」** (名前はテキストで残す)。根拠は
このリポジトリが既に書いている原則 — `Litedoc4.Render.Autolink` の
`moduleForSourcePath`:「A link to the wrong page is worse than no link」。404 する相対リンクは、
リンクが無い状態より厳密に悪い。実装は外部リンクの root が **空 base** を持てるようにし、`href` を
省略できるようにしたもの。**自パッケージのリンクと、解決できた依存リンクはバイト不動。**

**単体テストでは出なかった。** 「40 桁 hex でない rev は落ちる」テストは以前からあり
(今は `Litedoc4Test.Packages`)、それは**通っていた** — 落ちること自体は正しく、
**落ちた後に何が描かれるか**を見るものが 1 つも無かった。ページまで作らないと出ない形だった、というのがこの段の収穫。

### ギュメ付きモジュール名 — `.lidx` の綴り差は実在した【実測 2026-08-17】

`.lidx` はモジュール名を**非エスケープ**で書く (`Dep-Aux.Basic`)。IR と import リストは
**エスケープ済み** (`«Dep-Aux».Basic`)。`Example/Dep.lean` の docstring が同じモジュールを
3 通りに綴っていて、**修正前**の解決結果は次のとおり割れた:

| docstring の綴り | 解決したか |
|---|---|
| `«Dep-Aux».Basic` (IR の綴り) | **する** |
| `Dep-Aux.Basic` (`.lidx` の綴り) | **しない** |
| `Dep-Aux/Basic.lean` (source path) | **する** — `module_for_source_path` が escape してから引くので |

**修正後は 3 綴りとも「リンクを張らない」に落ちる** (依存であって版固定できないので、それが正しい)。
つまり**この綴り差が出力に出るのは、版固定できる依存がギュメ付きモジュールを持つときだけ**。

### その実物を作った — `tools/pinned-dep-gate.sh`【実測 2026-08-22】

**使うのは同じ `micro-dep` で、変えたのは配線だけ**。path require を git require に
差し替えると manifest entry が `type: git` + 40 桁 rev になり、版固定できる側に落ちる。
**モジュールも docstring も toolchain も同一なので、動く変数は版固定可能性だけ**。

ネットワークは要らない: ゲートが `e2e/micro-dep` から git リポジトリを作り、
git の `insteadOf` で remote を書き換える。**manifest には https の URL が残る** —
`file://` を入れると `site-gate.sh` がそれを**内部リンクと判定して dead link 5 本**を出し、
**製品の失敗と見分けがつかない**【実測: 最初にこれを踏んだ】。

測った結果:

| | |
|---|---|
| blob URL | `https://…/micro-dep/blob/<rev>/Dep-Aux/Basic.lean` — **ギュメは落ちている** |
| dead internal links | **0** |
| `«Dep-Aux».Basic` (IR の綴り) | **リンクする** |
| `Dep-Aux/Basic.lean` (source path) | **リンクする。上と同じ URL** |
| `Dep-Aux.Basic` (`.lidx` の綴り) | **リンクする**【2026-08-22 以降】。同じ URL |

**恐れていた壊れ方は無かった** — 版固定できる依存でギュメ付きモジュールへの blob URL は
正しく組める。**測って初めて出たのは、3 綴りのうち 1 つだけが解決しないという非対称**。
版固定できない依存では 3 つとも「リンクしない」に落ちるので、**この差は出力に出なかった**。

**解決させることにした**【決定 2026-08-22、ユーザー判断】。`Dep-Aux.Basic` は
**そもそも Lean の名前リテラルではない** (`-` が `isIdRest` でない) ので、
`nameToLink` の 1 行目で弾かれていた — 写像に無かったのではなく、**引かれてすらいなかった**。
`is_name_lit` は doc-gen4 の転写なので緩めず、**弾かれた側に逆引きを足した**
(`NameIndex::module_for_unescaped`、曖昧なら答えない)。
ゲートは**3 綴りが同じ URL に解決すること**を主張する。

**番号ではなく名前で指すこと** — README の一覧は `e744f79` で消えており、
番号参照はそれより先に腐っていた。

## `consumer/` — なぜ micro と別なのか

**入力は 2 つある。担当が違う。**

| | 担当 | 走らせるもの |
|---|---|---|
| `micro/` (+ `micro-dep/`) | **宣言の形** — 対象が持たない 9 分岐と版固定できない依存 | `tools/e2e-micro.sh` |
| `consumer/` | **Lake の配線** — litedoc4 を `require` した利用者の経路 | `tools/lake-package-gate.sh` / `tools/purelean-gate.sh` |

`consumer/` は litedoc4 を **path で `require`** する最小パッケージで、
`lake run docs -- --out <dir>` が動くかだけを見る。
検査しているのは、利用者が手で書けない 2 つの引数を Lake から取れているか:

- **`--extractor-bin`** — 抽出器を Lake が建てる (root の toolchain に対して建つので、
  版がずれようがない)
- **`--lib`** — `src/Litedoc4/Lakefile.lean` は `lakefile.lean` を**名前で拒否する**
  (正直に読むには Lake で elaborate するしかないため)。`script docs` は
  **その elaborate の後に走る**ので Lake に聞ける

**`micro/` を流用しない**のは、あちらの母数と不変量を動かさないため。
`e2e-micro.sh` は「サイトのバイト不動」「フル生成 2 回がバイト一致」を主張していて、
そこに require を足すと**両方の主張の前提が変わる**。

### このフィクスチャが持っている形

**`lean_lib` が 2 つ、`defaultTargets` は 1 つだけ。** どちらも意図的で、
ゲートの 5 項目目 (`--lib` が Lake から来ているか) を**推測ではなく失敗**にするためにある:

- **2 つある**ので、最初の `lean_lib` だけを渡す実装・パッケージ名を渡す実装は
  **短いサイトを書いて成功を報告する** (`Lakefile.lean` が名指ししている失敗の形)
- **`ConsumerExtra` が `defaultTargets` に無い**ので、`lake build` だけに頼った実装は
  olean の無いモジュールに当たって**大きな音で落ちる**。`script docs` が
  `defaultTargets` ではなく root パッケージの `lean_lib` を全部建てるのはこのため

宣言の形は網羅していない — **それは `micro/` の担当**で、ここに増やす理由は無い。

## `micro-expected/` — what the Rust half wrote

`micro-expected/` is the frozen output of the **Rust** `litedoc4` over `micro/`,
minted while that binary existed: 51 files, 520 KB — the rendered pages, the
whole-package artifacts, the four transcripts, the ledger and the build marker.
`tools/mv-pages-gate.sh`'s frozen arm reads them: every page path of
`micro-expected/build/` has to have a page at `v1/<same path>` in the store-rendered
sample S, and every element id of a frozen page has to be on that page once it is
drawn in a browser. It reads paths and ids, never bytes: a page drawn from data
changes every byte.

**Not every byte in it is the Rust half's.** `site/references.html` and
`build/references.html` were written by the Lean half on 2026-10-04: the page did
not exist while the Rust binary did. So were the citations in
`Example.html`, `Example/Basic.html` and `Example/Math.html` under `render/`,
`nolidx/` and `build/`, which came with `micro/docs/references.bib` — links under
`build/` and the author's text under the other two — and so was the one-line `#L`
shift in the source links below them. What read those bytes independently
is BibtexQuery's own command line (`bibtex-query l`), whose tags and entry text
were compared with `references.html` before they were frozen. The back-references
were added to the same files by hand later that day, and only where they land: the
`id="_backref_0"` on each of the three citations under `build/`, the three
`<small>` lists in `build/references.html`, `renderKey.renderer` in `ledger.json`,
and the render and state byte counts in `build.out`. `render/`, `nolidx/` and
`site/` are rendered without `--root`, so no bibliography reaches them and they did
not move.

It outlived `crates/` on purpose: the Rust binary was the port's oracle, and
anything minted after it left would record what the Lean half does today rather
than what the answer is. It is
here rather than in `tools/` because what invalidates it is an edit to `micro/`
— a docstring changed there changes the frozen pages, and the expectation
belongs where whoever changes it will see it.

**Nothing re-mints it.** There is nothing left to mint from, and an answer minted
from the Lean half would record what it does today rather than what the answer is.
An edit to `micro/` that moves a page path or an id is argued against these files
by hand.

## ゲート

`tools/e2e-micro.sh` builds `micro/` with `litedoc4 build` — one version, rendered
from the store — and asks, in order:

1. **One command** — the site lists exactly one version, the first 12 hex digits of
   HEAD, with a page per module of the IR; `benchmarks/tools/check-store-render.py`
   finds it closed over itself (index subscripts, instance values, no other host),
   its Used by files equal to the IR's references both ways, and its `sorry` and
   origin pills the IR's
2. **Idempotent** — the same command again leaves the site's bytes where they were
3. **Deterministic** — a build into another directory is byte-identical, site and IR
4. **`--jobs` invariant** — the extractor's parallelism does not move the IR
5. **Work** — read from `litedoc4-build.json`'s `work` and `versionsExtracted`: the
   first build extracts every module with one Lean start; the second extracts 0,
   starts Lean 0 times and says `0 of 1` versions extracted
6. **One edited module** — `.lidx` does not move, exactly one module is extracted
   (`tools/onemod-gate.sh`), and the IR and site left behind equal a build from
   nothing over the edited sources
7. **Attributes arrive split into name and value** — over the IR, by name and by
   count per attribute
8. **Source links** — every module's `<source>/<module path>.lean` is a file in
   this checkout, the version's source carrying the path to `micro/`

What a page shows once drawn — the three `sorry` shapes, generated declarations'
origins, MathML, Used by, `litedoc4.toml`, module descriptions, search, theme,
375 px and the monospace glyphs — is asked of the store-rendered sample S, which
carries the same shapes, by `tools/mv-s-gate.sh` and `tools/mv-pages-gate.sh`;
the script's step 11 names where each went.

**3 stands in for an external oracle** — it catches hash order, timestamps and
paths leaking into the output without asking anyone what the bytes should be.
**5 stands in for the wall clock** — environment loading moves 5× with the page
cache, so seconds cannot be a threshold, but the work done is a deterministic
integer.

### ゲート自身が壊れていた話【実測 2026-08-16】

作った当日に 2 件出た。**残しておく価値があるのは、どちらも「通っているように見える」形で
壊れていた**から:

- e2e の**ゲート 2 が、2 回目のサイトを自分自身にコピーして比較していた** — 何をしても通る
- corpus ゲート (当時) のテスト一覧が **テストランナーの stdout と stderr の混ざり順に依存**
  していて、CI (非 TTY) では全部 `::name` に潰れた。**捕まえたのは CI を実際に回したこと**

**ゲートは自分では自分を検査しない。**

## 触るときの注意

- **`micro/` says everything it says to strangers.** Its module docstrings, its
  declaration docstrings, `docs/index.md` and `litedoc4.toml`'s `title` are the
  published sample's copy. Write them for a reader who has never seen this
  repository: what the declaration shows about a page, not which gate counts it.
  The reasons — which gate reads this shape, what must not be tidied away, what
  number moves — go in plain `/- … -/` comments, which Lean ignores and the site
  never renders. A `/--` doc comment is a page; a `/- -/` comment is a note.
- **`micro/` の宣言を消さない。** 1 つ 1 つが「対象が持たない形」を担当している。
  足すのは歓迎 (担当を上の表に書くこと)。ただし**属性を持つ宣言を足すとゲート 8 の
  属性名ごとの本数が動く** — ゲートが名指しするので、その数を直す
  (structure を 1 つ足すと射影のぶん `reducible` が増える)
- **`Example/Gen.lean` の `Example.Gen.Solo.ext` を `@[ext] structure Solo` に「まとめない」。**
  手書きの ext 定理は**環境拡張には入る**ので、拡張だけを見る規則を落とすのはこの 1 形だけ。
  まとめるとゲート 9 の否定側の期待が消える (Mathlib 標本ではこの形が 20 件ある【実測】)
- **`Example/Sorry.lean` の `sorry` を「直さない」。** `sorryHole` は**入力**で、
  他の 2 つはそれと違う答えでなければならない。`lake build` の
  ``declaration uses `sorry` `` 警告はこのサンプルの一部
- **`micro-dep/` を git 依存に変えない。** path であること (= manifest に `url` も `rev` も
  無いこと) がこの依存の担当。GitHub にすると**そのまま版固定リンクが組めてしまい**、
  上の 3 経路を守るものが消える
- **Mathlib を足さない。** 足した瞬間にこれは CI で回らなくなる
- `micro/.lake/` は gitignored。`lake build` で作り直せる
- **`consumer/` の `lean_lib` を 1 つに減らさない / `defaultTargets` に 2 つとも書かない。**
  どちらもゲート 5 項目目が見ている形そのもの (上の表)
- **`consumer/` に宣言の形を足さない。** 増やす先は `micro/`。ここを太らせると
  「Lake の配線を見るフィクスチャ」が 2 つ目の母数になる
