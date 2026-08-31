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

### M4 build — `site` の周りのパイプライン 【完了 2026-08-31】

- **完了判定**: `litedoc4 build --root e2e/micro` が Rust と **23/23 バイト一致**し、
  `site-gate` / `config-gate` が Lean 実装で緑 → 達成。判定器は
  `tools/purelean-micro-gate.sh` の項目 10〜14。サイトの外も一致する
  （`ledger.json` / `link-index.lidx`(+`.key`) / `work/modules.txt` / `ir/` の木、
  そして `litedoc4-build.json` は `work.irReads` 込みで
  `{index:3, module:22, depMap:4, total:29}` — **Lean のリーダは Rust と同じ回数 IR を開く**）

M6 以降に効く残りだけ:

- **アセットの正本はリポジトリ直下の `assets/`** で、鎖は 3 リンク・各リンクを 1 か所だけが見る:
  vite → `assets/` は `assets.rs` の**テスト**（`build.rs` が既に vite を走らせているので追加費用が無く、
  **M9 で vite ごと去る**のが正しい）、`assets/` → `Assets.lean` と `assets/` → `assets.rs` は
  `tools/assets-embed-gate.sh` の項目 2 / 3。後者は**存在ではなく回数**を数える
  （2 つ目の `include_str!` は存在検査を素通りする）。
  アセットは 3 つではなく **4 つ** — `theme-boot.js` はファイルに書かれず全ページの
  `<head>` にインラインされるので、数えるときに落ちやすい
- **`build` は `--source-url .../blob/HEAD/...` を exit 2 で拒否する** — `/blob/` の後に
  **40 桁小文字 hex** を要求する（`render` と `site` は要求しない）。
  **新しいゲートは両バイナリに 40-hex の同一固定文字列を渡すこと。URL を git から導出させない**
  — 調査中に HEAD が動いて 11 ページ全部が変わった（実測）
- **`--source-url` の末尾スラッシュで 11/11 ページが乖離していた**（2026-08-31 に塞いだ）。
  一般形の `trimTrailingSlash` は既にあり、**Rust が剥がす 4 箇所のうち 3 箇所では呼ばれていて
  `renderSite` の 1 箇所だけが呼び忘れ**だった。**検査は「関数があるか」ではなく
  「呼ぶべき場所すべてで呼んでいるか」を見る**。ゲートは項目を増やさず
  **項目 3 を 2 つの綴り**（素 / 末尾スラッシュ付き）で走らせて塞いだ
- **`write_marker` は `open_extractor` の前に呼ばれる** — `--extractor-bin` が無くて失敗した
  `build` も `litedoc4-build.json` と `work/modules.txt` を残す（実測）。
  「空の `--out`」と「失敗した run が触った `--out`」は**別の状態**で、
  試行のあいだに `rm -rf` するゲートは後者を隠す
- **`build` が起こすプロセスは 6 つだけ**（`git` ×4 / `lean --githash` ×1 /
  `lake env <extractor> … --serve` ×1）。モジュール列挙で `lake` は起動されない —
  ファイルシステムの glob と手書きの `lakefile.toml` 行認識器（説明できない行はすべて exit 3）


### M5 incremental — ledger / impact / ownership / merge / mode 【完了 2026-08-31】

- **完了判定**: `incremental-compare.sh` / `impact-compare.sh` / `merge-compare.sh` /
  `ledger-compare.sh` / `onemod-gate.sh` が Lean 実装で緑
  → **5 本とも緑。U1〜U13 完了**: incremental **3,201/3,201** / impact **3,556/3,556** /
  merge **3,961/3,961** / ledger **66/66** / `onemod-gate.sh` 緑。
  **5 本とも先に落としてから通した**。micro ゲートは 14 → **16 項目**
  （12 の 2 つ目の綴り / 15 `--only-from` / 16 incremental）
- 移植したもの: ledger リーダ + `checkLedger` + `touch` / `ownership` / `merge`（`--verify` 込み）/
  `impact` / `prune` / `render --only` `--only-from` / `global` と delta /
  `extract` / `incremental` / `planOf` の全検査

#### オラクルの記録 — 再現の仕方（M8 と M9 が要る）

`*-reference.sh` は**実装の答えを記録する**スクリプトで、`*-compare.sh` が 2 つの記録を比べる。
`LITEDOC4=<バイナリ>` で相手を選ぶ（2026-08-31 に 4 本へ足した）。**対象リポジトリは読むだけ。**

| 記録 | 入力 | 規模 |
|---|---|---|
| ledger | `--ir /private/tmp/lean-doc-relay/purelean/ir` | 78 ファイル |
| merge / ownership | `--base-ir` 同上 | 3,961 ファイル |
| impact / prune | `--base-ir` 同上 / `--pages m5-impact/ref-pages` / `--site m5-impact/ref-site` | 3,585 |
| incremental | `--base-ir` 同上 / `--lidx purelean/link-index.json` / `--ref-site m5-impact/ref-site`、`--extractor product\|resident` | 3,168 |

`ref-pages` / `ref-site` は `target/release/litedoc4` の `render` / `site` を
`purelean/ir` に当てて作る。**記録の入力は記録と同じ寿命を持つ場所に置く** —
一度 `--pages` に他のゲートの残骸を渡して、掃除で消してしまった。

**この 4 本は M9 で片側が消える。** 比較器は 2 つの記録を比べる道具なので、Rust を削除すると
**問いごと無くなる**。M5 で唯一 Rust を要らない判定は **micro ゲート項目 16**（Lean 半分の
3 回の run を互いに比べる）。M9 に入る前に、比較器が持っていた問いのどれを
オラクル無しの形に移すかを決めること。

#### M5's evidence was narrower than it said (found 2026-08-31, list fixed the same day)

`tools/incremental-reference.sh` carried **a fifth copy of the doc-gen4 six-name
artefact list**, and `copy_globals` wrote an `.absent` marker for every name a run
did not produce. Five of the six are names litedoc4 never writes, so each
scenario's `<s>-global/` held **one real file and five absences that agreed with
themselves on both sides** — the shape `tools/site-artefacts.txt`'s own header
records for `clone-gate.sh` in 2026-08-29. The eight artefacts litedoc4 *does*
derive were compared by nothing.

The list now comes from `site-artefacts.txt`, and `copy_globals` writes
`<s>-global.count.txt` so the denominator is in the record: **9 compared, 3
absent** where it used to be 1 compared, 5 absent (the three are `build`'s
assets, legitimately absent from a `global` derivation).

**The 3,145/3,145 stood for what it compared**, and what it compared was smaller
than the header claimed. **Both recordings were retaken with the corrected list**
(2026-08-31 → `benchmarks/results/purelean-incremental-retake-2026-08-31.txt`):
**3,201/3,201 identical**, every record `9 compared, 3 absent`. The 56 new files
are 8 records × (6 further artefact entries + the `.count.txt`), and the eight
artefacts that had never been compared —
`404.html` / `foundational_types.html` / `index.html` / `search.html` /
`declarations/used-by.json` / `instances.json` / `modules.json` /
`search-index.bin` — agree byte for byte on both halves.

**`--ref-site` was the second half of the same defect.** `base-sitecheck.txt` is
the one oracle inside the recording that says the base site equals a site
somebody already accepted, and the guard around it was an `if` whose default path
had rotted, so it was never written and `incremental-compare.sh` skips
`*-sitecheck.txt` by design. It is a hard exit now, and all 16 within-run oracles
(8 per half) report **431 files, identical**.

**The general form nobody applied**: when the first two copies of that list were
collected into `site-artefacts.txt` on 2026-08-29, the fix was not raised to
"where else is this judgement made". Four more copies have been found since, one
per place that compares a site. CLAUDE.md's "Fixing defects" rule is the one that
would have caught them.

#### M5 が残した、次に効く事実

- **`ownership` は bimodal**。`lostOwners` と `gainedOwners` がどちらも空なら base の IR を
  **1 つも読まない**、空でなければ exclude を除く全部を読む。実測で **0 対 417〜421**。
  `watching` ガードは最適化ではなく**その 2 つを分ける唯一のもの**
- **遅延起動は計測した**（→ `benchmarks/results/purelean-lazy-serve-2026-08-31.txt`）。
  `nochange` は抽出器プロセス **0 個 / 5.7 s**、`self-one` は **1 個 / 23.4 s**。
  **両方とも timings に `"serve": true` と出る** — これは「resident の経路を選んだ」であって
  「プロセスが在る」ではない。**後者と読むと遅延起動が未検証のまま通る**
- **純粋な段を計る Lean の実装は時計の穴を持つ**。2 つの `IO.monoNanosNow` の間に純粋な
  `let` を置くと、Lean はその計算を**値が最初に見られる場所まで動かす** —
  `Global/Delta.lean` の `scanSeconds` が 212 モジュールの走査中に **84 ns** と出ていた（実測）。
  `timedPure` で塞いだ。**バイト比較には一切映らない**
- **`ExceptT ε IO α` は `IO (Except ε α)` と定義上同じ**。拒否が `UInt32 × String` の関数は
  `let x ← f …` がそのまま伝播で、`match ← f … with | .error …` はスクルティニが `α` に
  解決されて型エラーになる
- **JSON リーダは誤りの経路を持つ**（`JVal.bad` → `parseJson` だけが見る）。
  小数は `JVal.real` が**書かれたバイトのまま**持つ（Lean に最短往復の `Float` 印字が無く、
  `--timings` はこれらを素通しでコピーするだけだから）
- **`ledger check` が遅いのは移植ではなくハッシュ**（→ `purelean-ledger-check-2026-08-31.txt`）。
  `--algorithm lake` なら Rust の 1.3 倍、`sha256` で 15.7 倍。差の全部が SHA-256 で、
  **C を採らない判断は M4 で決着済**（→ `purelean-sha256-2026-08-31.txt`）
- **`it-modules.txt` は 432 で凍り、base IR は 422**。ledger のシナリオは 432 をハッシュし、
  merge / incremental は 422 の木を動かす。**同じ記録の中で母数が 2 つある**

#### 構成できていない窓（「たぶん大丈夫」と読まないこと）

- **`--max-rounds` 超過の exit 5** — 7 シナリオが 1 つも stale モジュールを出さないので届かない
- **`prune` の `allowRemoveDir` の `strictly`（ルート自身）** — 呼ぶ側が `relative` が空のときに
  止めるので、**Rust にも到達経路が無い**
- **`Generation` 照合の 3 つ目の窓（リクエスト前）** — `detect` の最中に世界が動く必要があり、
  フックが無い。他の 2 つ（spawn 時 / リクエスト後）は両バイナリがバイト同一のメッセージで exit 3
- **`Server.stop` の「signalled」枝は Lean に無い** — Rust が 10 秒ポーリングしてから signal する
  ところを `wait` で塞いでいる（意図した乖離）
- **`prune` のガード 3 つは記録が 1 つも通らない**ので、記録の外で Rust と突き合わせた
  （語彙的な脱出 `«..».Foo` / 物理的な脱出 symlink / symlink を降りない歩き方。3 つとも一致）

#### M7 へ持ち越す穴

- **`incremental --timings` のレコードで Rust と違うのは入れ子の `global` が無いことだけ**。
  Lean の `global` は `--timings` を実装していない
- **診断メッセージの文言**は一致していない（終了コードと判断は一致する）。
  Rust は serde のバイトオフセット付き、Lean は自前
- `--deps-docs-map` は `ledger` と `render` の両方で名指しで拒否している

### M6 watch と HTTP サーバ（`Std.Async.TCP`） 【完了 2026-08-31】

- **完了判定**: `watch-gate.sh` が Lean 実装で緑（`LITEDOC4=<lean>` で相手を選べる）
  → **達成。12 check / 0 failed で、Rust ベースラインと 1 行ずつ同じ**（ページの 37357 B まで）。
  **`--inject wrong-module` と `--inject no-touch` の両方で先に落とした**
  （前者は 3 つの整数が 1/1/1 のまま**名前の検査だけ**が落ちる、後者は 30 秒で time out）。
  `purelean-{gate,micro-gate,render-gate}` は 5/5・16/16・6/6 で `failed 0`、`docs-gate` も緑。
  記録は `benchmarks/results/purelean-watch-2026-08-31.txt`

**破断条件は発火しなかった**（実測 2026-08-31 →
`benchmarks/results/purelean-async-tcp-2026-08-31.txt`）。`Std.Async.TCP` は
**3 つのツールチェーン（v4.31.0 / v4.32.2 / v4.33.0）でバイト同一**にあり、名前も動いていない。
**ファイル監視は要らない** — `watch.rs` はポーリングを選んでいて、`Std` にも watcher は無い。

#### 調査が挙げた 3 つの代価は、どれが実際に噛んだか

1. **stdout の完全バッファ — 噛んだ**。塞ぎ方は「1 行ごとに flush するヘルパ」ではなく
   **stdout そのものを差し替える**（`IO.setStdout` に `write`/`putStr` が flush する
   `IO.FS.Stream` を渡す）。**待たれている行はループのではなく `runBuild` 側**で、
   ヘルパ経由の println はそこに届かない。core にバッファモード設定が入れば 1 行で済む
2. **ポーリングの代価 — 測り直した**。1 パスは **Lean 2.25 s 対 Rust 0.063 s（35.7 倍）**、
   同じ木・同じセッション・暖機、heartbeat 5 回。`--interval 1000` で 1 パス 3.2 s、
   コアは 69%（Rust は 6%）。**下限は 100 ms のまま**（`--interval` は
   `public-surface.txt` の約束名で、受け入れる値を動かすのは他人のファイルを壊す）が、
   module doc と下限の拒否文の**両方に実測値を書いた**。
   調査 §7 の 0.129/2.033 s とは**母数（432 と 422）も形（プロセス丸ごとと呼び出し）も違う** —
   4 つの数字を 1 行に並べないこと
3. **港をいつ取るか — 落ちなかった。構造で避けた**。`Httpd.bind` が
   **accept ループ自身を起こす**ので、`listen` と `accept` の間に何も印字しない。
   Rust は bind と serve を呼び手が 3 行の印字を挟んで呼ぶが、Lean でそれをやると
   「検査」と「その検査が licence する主張」の間に窓ができる

#### M6 が残した、次に効く事実

- **`Step` の 4 分岐のうちゲートが触るのは `idle` と `rebuild` だけ**。`settling` と `skip` は
  e2e/micro の複製に **olean の無い .lean を 1 つ置いて**手で駆動した（記録の §5）。
  `skip` は**毎パス何も印字しない**ので、60 秒 heartbeat の
  `watch   waiting — …, unchanged since the last pass acted on it` だけが陽の証拠になる。
  **「初回の失敗は致命・以降は待つ」もここで出る** — `skip` に到達するには
  先に 1 回 acted している必要がある
- **`BuildM α` は定義上 `IO (Except (UInt32 × String) α)`** なので、
  `match ← (runBuild r).run with | .ok …` は**中身の `BuildRan` に解決されて型エラー**になる。
  塞ぎ方は束縛に型を書くこと（M5 が記録した罠の裏返しで、**捕まえる側**で出る）
- **`Ran` という名前は既に `Incr/Pipeline.lean` が使っている**（どの抽出器が走ったか）。
  Rust では別モジュールなので衝突しない。Lean 側は `BuildRan`
- **構造体リテラルの継続行は最初のフィールドの桁以上に揃える**。
  `{ x with a := 1,` の次行を浅くインデントすると `unexpected identifier; expected '}'`
- `lean_exe litedoc4` は **5,132,640 → 5,550,096 B（+417,456 B）**。
  調査が hello-world で測った +289 KB に Watch/Httpd の 560 行が乗った値で、
  `require` だけの配布は揺るがない

#### M7 へ持ち越す穴

- **`public-surface.txt` の `[watch]` は `--extractor` / `--extractor-arg` / `--mode` /
  `--max-rounds` も約束している**。Lean 側は `buildUnimplemented` 経由で
  **名指しで「実装していない」と拒否**する（黙って無視はしない）。M7 の判定はここ
- **`--deps-docs-url` / `--deps-docs-index` の拒否文が違う**。Rust は
  「`watch` のフラグではない（ネットワーク越しに解決するから）」、Lean は
  「この build は実装していない」。終了コードは同じ 2
- **診断文言の不一致は M5 から続き**。`describe` に Rust の `Answered(code)` に当たる形が無い

**未計測**: **Linux**。上は全部 macOS/arm64 で、`ci.yml` は `watch-gate.sh` を
`ubuntu-latest` で走らせる。**libuv の遅延 bind と `SO_REUSEADDR` が一番違いそうな場所**で、
代価 2 はそこに依存している。**「たぶん大丈夫」と読まないこと** — 塞ぐのは PR 1 本
（`pull_request:` は `ci.yml` を起こす。ブランチ push は何も起こさない）

**M9 に効く**: `watch-gate.sh` は `LITEDOC4` で相手を選べるので、
**M5 の 4 本の比較器と違い Rust が消えても問いごと消えない**。

### M7 残り — CLI 全フラグ / 設定 / 診断メッセージ / deps-docs 【完了 2026-08-31】

- **完了判定**: `tools/public-surface.txt` の全名が Lean 実装に存在し、
  `public-surface-gate.sh` が Lean 側を見て緑 → **達成**。
  `public-surface-gate.sh` は **両半分を読む**（Rust の `USAGE` と Lean の `usage`、
  `config.rs` の `File` と `Config.lean` の `parseConfig`）。片方だけを読むと、
  「消費者が今どちらを使っているか」は**インストール経路で決まる**のに、検査は片方の
  半分にしか効かない。M9 で Rust が消えたら Rust 側の半分も一緒に消え、問いは残る。
  **5 通りに落としてから通した**（Lean の watch 概要から `--max-rounds` を抜く /
  `parseConfig` が `index` を名指さない / `parseConfig` の unknown key 拒否を外す /
  `def usage` のマーカーを動かす / Rust の `USAGE` から `--timings` を抜く）
- 埋めたもの: `build`/`watch` の `--extractor` `--extractor-arg` `--mode` `--max-rounds`
  `--timings` `--link-index` / `global --timings` / `site --timings` / `links` /
  `--deps-docs-url` `--deps-docs-index`（curl + 66 MB のテーブルを値に組み立てず走査する
  `src/Litedoc4/DepsDocs.lean`）/ `--deps-docs-map`（`render` `site` `incremental`
  `ledger` `links`）/ `--help` `--help-all`（`usage` と `summary` は Rust の 2 つの定数と
  **バイト同一**にした）
- **`purelean-render-gate.sh` の項目 5 は反転した**。「未実装フラグを名指しで拒否するか」
  から「**両方が同じ地図で同じバイトを書き、かつ項目 3 と違うバイトになるか**」へ。
  ヘッダが「実装したらこの項目は消えず、肯定形になる」と書いてあったとおり。
  **先に落とした** — `linkTo` の docs 分岐を殺すと 422 ページ中の 1 つ目で落ちる。
  そのとき**この項目自身の欠陥も出た**: `grep` が 0 件で終了 1 を返し `pipefail` で
  スクリプトごと死に、**報告すべき唯一の状態を報告できなかった**
- **`deps-docs-gate.sh` を Lean 実装で走らせた（実測 2026-08-31）**: Mathlib 396/396、
  Init 127/130 で Rust 側の記録と同数、mathlib4_docs から 443 ページ取得・503 アンカー照合、
  dead 0 / leaked 0、フォールバック枝も 3 件で発火

#### M5 / M6 から持ち越した穴は全部閉じた

- `incremental --timings` に入れ子の `global` が入り、**2026-08-31 のオラクルと同じ 27 キー**
- `--deps-docs-map` は `ledger` でも `render` でも実装済み
- 診断文言は **22 個の拒否のうち 21 個が stderr 丸ごとバイト一致**（`usage` 込み）。
  `wants a value` → `needs a value`、`takes a number, not \`x\`` → `wants a number, not x`、
  `linkIndexRequired` の代価文、`ledger build` の桁区切り、unknown subcommand の空行も揃えた

#### M7 が残した、次に効く事実

- **意図的に残した乖離が 2 種類ある**。(1) `build --serve` の拒否文は Rust だけが
  `(see crates/litedoc4/src/resident.rs)` を持つ — M10 で消えるファイルを Lean のバイナリが
  指すのは腐るポインタなので足さなかった。(2) **OS エラーの文言**:
  Rust は `No such file or directory (os error 2)`、Lean は
  `no such file or directory (error code: 4294967294)`。後者の数字は errno ではなく Lean の
  番兵で、Rust の文字列を書き写すのは別処理系のエラー表を捏造すること
- **`--deps-docs-url` のテーブルは Lean 側では一度メモリに載る**。Rust は curl の
  stdout をストリームで食う。66 MB ぶんピーク RSS が違う（未計測）
- **`incremental-reference.sh` は run 内オラクルを黙って飛ばしていた**（実測 2026-08-31、
  同日に塞いだ）。`--ref-site` の既定は既に存在しないパスで、`if [ -d "$REF_SITE" ]` で
  囲われていたので**ファイルが書かれないだけ**だった。`incremental-compare.sh` は
  `*-sitecheck.txt` を設計上飛ばすので、**どこも報告しない**。
  他の 3 入力と同じハード終了に寄せた。**「入力が無いと黙って項目が消える」は
  比較器が数を数えていても捕まらない** — 数えているのは書かれたファイルの側だから
- **`IO.Process.output` で curl を待つと終了コードを先に見られる** ので、Rust が
  「パーサのエラーより curl のエラーを優先する」ためにやっている順序制御は要らない
- **`skipVal` はオブジェクトと配列を同じループで飛ばせない**。キーを飛ばした直後は `:` が
  来るので、`,` か `}` を期待すると 1244 バイト目で落ちる（実測）。
  **落ちるのは静かではない**（テーブルが読めない扱いになり全部ソースへ落ちる）が、
  症状は「そのサイトのリンクが 1 つも出ない」で、出力は正しく見える
- **`git checkout` ではなくバイナリを差し替える実験にも同じ罠がある**。記録スクリプトの
  実行中に `lake build` でバイナリを置き換えたら、記録は途中で死んで
  **`conditions.txt` が無いだけの、一見それらしいディレクトリ**を残した（実測 2026-08-31）

### M8 対象リポジトリ全体で一致 【完了 2026-08-31】

The criterion below replaces the one this section carried
("432 モジュールで 422/422 バイト一致、`build-gate.sh` / `corpus-gate.sh` /
`lean-versions-gate.sh` が Lean 実装で緑"). Two of its three gate clauses were
not statements about the Lean half at all, and its denominator was the 432 that
left the sources:

- **`corpus-gate.sh` cannot be green "with the Lean implementation", and no flag
  can make it so.** Its 21 inventory entries are `#[ignore]`d **Rust tests** that
  call `litedoc4_render::…`, `litedoc4_ir::…` and friends **in process**; there
  is no `litedoc4` executable in it to select. Turning it into a claim about the
  Lean half means rewriting fourteen in-process comparisons as subprocess ones,
  i.e. writing a different gate. It stays a Rust-half gate and goes with
  `crates/` at M10. **What must not happen is ticking this clause by running the
  Rust gate** — and it also needs `cargo`, which `target/debug` no longer has.
- **`lean-versions-gate.sh` is about the extractor, which was Lean before M1.**
  It compares one IR tree per toolchain, and the IR is written by
  `extractor/Extract.lean`. Driving `tools/e2e-micro.sh` with the Lean CLI
  instead of the Rust one would re-measure the extractor's toolchain
  independence with a different (irrelevant) driver — the "gate that agrees with
  itself" shape. **The real gap it sits next to is a different one**: the Lean
  half has never been *compiled* on any toolchain but v4.31.0 (`ci-lake.yml`
  runs the `purelean-*` gates at `e2e/consumer/lean-toolchain`;
  `ci-lean-versions.yml` builds the **Rust** binary), and
  `tools/lean-toolchains.txt` promises four. That is a `ci-lean-versions.yml`
  change and belongs with M9's rewrite of it.

- **完了判定**: one `litedoc4 build` over the whole target from each half writes
  `--out` trees that are **867 of 871 files identical** (site 434/434, ir 426/426,
  `ledger.json` / `link-index.lidx`(+`.key`) / `litedoc4-build.json` / `state/` /
  `work/modules.txt` / `work/ledger-detect.json`, with `work.irReads`
  `{index:3, module:844, depMap:6, total:853}` on both), **stdout 21 of 22 lines
  byte-identical** (the 22nd is `--timings`' summary JSON, where 4 of 25 keys
  differ and all four are `*Seconds`), **stderr empty on both**, and
  `build-gate.sh` green **driving each half**.
  → **The first half is done** (2026-08-31 →
  `benchmarks/results/purelean-target-build-2026-08-31.txt`). All four files that
  differ are under `work/`: three are written by the **same extractor binary** and
  carry wall clock, the fourth is `work/ledger-timings.json`, which only Rust
  writes — its four values are durations and its fifth is `concurrency` (Rust 8,
  Lean 1 because the Lean ledger hashes sequentially), so writing it could not
  make the tree identical. M9 decides whether it is written at all.
  → **`build-gate.sh all` is green driving both halves** (2026-08-31 →
  `benchmarks/results/purelean-build-gate-2026-08-31.txt`). **M8 is complete.**

  **The "20 GiB free" rule was wrong by an order of magnitude.** The whole
  operation costs **1.92 GiB and 666 s** (421 oleans, default parallelism, 8
  concurrent `lean`), of which **1 GiB was one new swapfile** and ~0.92 GiB build
  products. The earlier 2 GiB-in-90 s reading saw a machine still growing swap
  toward its ceiling; one already at the ceiling reuses slots (that part is
  (assumed) — what is measured is the two disk curves). **Capping parallelism is
  not available**: Lake 5.0.0 has **no job-count option at all**, and a `--jobs`
  knob proven against a stub was reverted when lake rejected the flag — the stub
  proved the call site, not the contract.

  **Running it first found two things that were waiting.** (1) A clone of this
  target could **never** reach `baseline`: both gates read `git status
  --porcelain`, which counts untracked paths, and the target carries
  `docs/doc-gen-bench/`; `reset` cannot cure it because its `clean` is scoped to
  the library. Fixed where the baseline is constructed (`setup-clone.sh clone`,
  `git clean -fd` — `.lake` is ignored and stays). (2) **A real defect in the Lean
  half**: `carriesAPreviousRun` asked `Layout.linkIndex`, always the derived
  `<out>/link-index.lidx`, where Rust asks the **request's** resolved index. With
  `--link-index` no run writes that file, so every second `build` took the **full**
  path for ever. **A full generation of the same sources produces the same site**,
  so no byte comparison can see it — only gate 2's re-extraction count.
  **The same judgement had the same mistake in `Watch.lean`** (its trigger watched
  a file that does not exist); both fixed.

### M9 切替 — 配布モデルを変える（**ここから不可逆**）【リポジトリ側は完了 2026-08-31】
- ~~`action.yml` の binary 解決を廃止 / `lakefile.lean` の `resolveLitedoc4` 削除 /
  `release.yml` 削除 / `lake-download-gate.sh`・`release-notes-gate.sh` 廃止 /
  ビルド済み JS をリポジトリへ~~ 済（`08efc70` / `11735e9` / `9a47cca`）。
  実際に消えたのは 353 行（250 の見積りより多い）。JS は M2 の時点で `assets/` に
  コミット済みで `tools/gen-assets.py` が `Assets.lean` を生成しており、新たな作業は無かった
- **`public-surface.txt` の `binary-source` は残した**（判断、実物を読んで決めた）。
  1.x が約束した名前で、**GitHub Actions は消えた output を空文字で返しエラーにしない** —
  消すと利用者の `test "$SRC" = release` が黙って通る。値は定数 `lake` にし、
  `ci-action.yml` の `standalone` job が「約束した output が届く」ことだけを assert する
- **新しく増えた義務**: `src/` は `tools/lean-toolchains.txt` の全 toolchain で
  コンパイルできなければならない（消費者の Lean がコンパイルするから）。
  `ci-lean-versions.yml` に `tools/build-lean-exe.sh` を走らせる段を足した。
  **これは M9 以前には存在しなかった要求**で、U5（extractor が v4.33.0 で通らなかった）と同じ形
- **完了判定は満たした（実測）** — git require の消費者が
  `cargo`/`rustc`/`node`/`npm` の無い PATH でサイトを出す
  → `benchmarks/results/purelean-require-only-2026-08-31.txt`。
  消費者が払うのは初回の **18.1 s（litedoc4）+ 25.7 s（extractor）**、2 回目からは 0.57 s
- **残り 3 つ**:
  1. **タグ `v1.3.0` を切る** — README と `lakefile.lean` は既にこれを指している。
     切るまで README のピン例は存在しないタグを指したまま
  2. **`information-theory` のピンを上げる**（`docs.yml` の `@v1.2.0`）—
     **別リポジトリで、しかも CLAUDE.md が「計測対象にコミットするな」と言っている対象**。
     ユーザー判断
  3. **`pages.yml` はまだ Rust バイナリでサンプルを建てている**。M10 で切り替わる。
     M8 で全体一致を取っているのでバイト差は無い（実測）が、
     「配布は Lean、公開サンプルは Rust」という非対称は M10 まで残る

### M10 Rust 削除
- `crates/` を HEAD から削除、`rust-frozen` タグで凍結（`experiments-frozen` の前例）
- この計画ファイルを削除
- **完了判定**: `cargo` を名指しするワークフローが 0 本

## この計画が壊れる条件

- **M2 で e2e/micro のページが一致しない** → プロトタイプは対象リポジトリでしか
  突き合わせていない。e2e/micro は「対象が持たない宣言形状」を持つので、
  **ここで初めて出る差がある**。差が出たら M2 を分割する
- ~~**`Std.Async.TCP` が watch の要求を満たさない**（M6）~~ → **2026-08-31 に実測で否定**
  （→ `benchmarks/results/purelean-async-tcp-2026-08-31.txt`）。配布モデルの決定に戻る必要は無い。
  **ただし Linux は未計測** — そこが違えば M6 の代価 3（港をいつ取るか）が変わる
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
