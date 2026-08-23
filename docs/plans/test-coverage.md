# テストの穴を埋める — カバレッジを測ってから決める

**状態**: 進行中 (2026-08-24)。全 30 項目中 **決着 6** — 段 0 (G1〜G3、**測ったら既に
CI で走っていた**) / 段 1 の C1・C2 / 段 3 の E1。

**測ってから書いた計画**である。「足りない気がする」ではなく、**本体カバレッジ 81.6%**
【実測 2026-08-24】という数字と、**どの経路を検査するものが 1 つも存在しないか**の
棚卸しの合併で穴を選んだ。**カバレッジの数値そのものは目標ではない** (→ §6 撤退ライン)。

## 1. 測ったこと

### 1.1 カバレッジ【実測 2026-08-24】

```
rustup component add llvm-tools-preview && cargo install cargo-llvm-cov --locked
mise exec -- cargo llvm-cov --workspace --no-fail-fast --json --summary-only --output-path cov.json
mise exec -- cargo llvm-cov report --json --output-path cov-full.json   # 再実行不要、profdata を使う
```

機材 Apple M1 / macOS 26.0 / Rust 1.97.1。母数は **`cargo test --workspace` が走らせる
503 テスト** (41 バイナリ、0 failed)。**`#[ignore]` の 22 本は走っていない** — 対象リポジトリと
凍結入力を要るもので、CI でも走らない。**ゲート (`tools/*.sh`) と e2e は一切入っていない。**

```
TOTAL: lines 88% (12758/14419), regions 87% (22997/26364), functions 86%
```

**数字は llvm-cov の per-file 値をそのまま使う。** 同じファイルの `#[cfg(test)]` 内の
コードも分母に入るので、**`#[ignore]` テストを多く抱えるファイルは実態より低く出る** —
下の表の `packages.rs` がそれで、**未カバーの 8 割は ignored テスト自身のコード**。
**穴の大小を見るときは、まずそれを疑う。**

**その補正を機械的にやろうとして、できなかった**【2026-08-24】。1 行に複数のリージョンが
乗る (`?` のエラー経路が同じ行の別リージョンになる) ので、`#[cfg(test)]` の手前までで
数え直しても、**行ごとに最小を取れば 81.6%、最大を取れば 87.3%** と 6 ポイント動く。
**どちらも llvm-cov の定義ではない。** 最小側を信じて書いた最初の版は
`parse.rs` を 71% と報告したが、llvm-cov 自身は 87.7% と言う。
**判断には生の per-file 値と未カバー行の絶対数を使い、自作の補正値は使わない。**

| ファイル | lines | 未カバー行 | 未カバーの中身 |
|---|---|---|---|
| `litedoc4/src/packages.rs` | 53% | 277 | **穴ではない** — 大半が `#[ignore]` テスト自身のコード |
| `litedoc4/src/queries.rs` | **35%** | 230 | `links`/`ownership`/`merge`/`impact`/`prune` の**本体が丸ごと** |
| `litedoc4/src/watch.rs` | **47%** | 211 | `watch` 本体 / `run_loop` / `Trigger::ask` / `announce` / `describe` |
| `litedoc4/src/build.rs` | 86% | 89 | |
| `litedoc4/src/deps_docs.rs` | 86% | 76 | |
| `litedoc4/src/pipeline.rs` | 90% | 74 | |
| `litedoc4/src/resident.rs` | 87% | 72 | |
| `litedoc4-incr/src/merge.rs` | 83% | 70 | |
| `litedoc4-md/src/parse.rs` | 87% | 53 | **大半は `Error::Malformed` の防御分岐** — docstring 自身が「md4c が変わったときかここのバグのときだけ」と書いている |
| `litedoc4-incr/src/prune.rs` | 82% | 50 | |
| `litedoc4-global/src/site.rs` | 75% | 43 | |
| `litedoc4/src/extract.rs` | 84% | 37 | |
| `litedoc4/src/ledger.rs` | 77% | 33 | |
| `litedoc4-ir/src/error.rs` | **16%** | 21 | `Display` / `source` — **エラーが起きる経路を通ったことがない** |
| `litedoc4-incr/src/error.rs` | 68% | 17 | 同上 |
| `litedoc4-md/src/error.rs` | **0%** | 9 | 同上 |

**関数単位のカバレッジは使わない。** `litedoc4` は lib と bin で同じ関数が 2 度
コンパイルされるので、**統合テストが子プロセスで通した関数が lib 側では count 0 に見える**
(`build::build` / `pipeline::incremental` がそう出る)。行カバレッジは union されるので正しい。

### 1.2 構造的な穴 — カバレッジが見せないもの

カバレッジは「走ったか」しか言わない。**そもそも検査するものが存在しない**経路を別途棚卸しした:

- **push で走らないゲートは 2 本だけ**【実測 2026-08-24、→ 段 0】 — `watch-gate.sh` と
  `clone-gate.sh`。後者は計測対象のクローンを要り、比較相手のゲート A が suspended なので
  設計どおり。**`watch-gate.sh` だけが「主張を疑う」対象として残る** (→ 段 4 W3)。
  ゲートは `ci.yml` から直接呼ばれるものだけではない — **`e2e-micro.sh` が 4 本
  (`site` / `usedby` / `config` / `onemod`) を内部で呼ぶ**ので、
  workflow の grep だけで数えると走っているものを走っていないと数える。
- **テストが 1 本も無いファイル**: `litedoc4/src/cli.rs` (全 13 サブコマンドが通る共通パーサ) /
  `litedoc4/src/main.rs` (dispatch) / `extractor/Extract.lean` (3,687 行) /
  両クレートの `build.rs`。
- `litedoc4-incr` の異常系は**最も厚い** (11 変種中 8 変種を `tests/` から名指し) —
  ここを手本にできる。

## 2. Approach

**方針は「カバレッジを上げる」ではなく「検査されていない利用者経路を検査下に置く」。**
数字は結果として付いてくる。順序は**コストと、壊れたときに利用者に当たるかの積**で決めた。

3 つの原則を全段に通す。どれも CLAUDE.md の既存の規律で、新しく決めることではない:

1. **足す先を「テスト」と「ゲート」で正しく分ける。** 自分の入力を持ち機材ゼロ依存なら
   `cargo test`、対象・toolchain・ネットワークを要るなら `tools/*.sh`。
   **既存のゲートを CI に載せるだけで済むものを、テストとして書き直さない。**
2. **落ちたときに何が壊れたか 1 行で言えるものだけ足す。** 件数を目標にしない。
   `Display` の文字列を突くだけの脆いテストは書かず、**エラーが起きる経路を入力から通して
   正しい variant が返るところ**を検査する。
3. **新しいゲート・新しいテストは、必ず一度落としてから通す。** 「何をしても通るゲート」を
   作った実績が 2 件ある。特に段 0 は**既存のゲートを CI に載せる**ので、
   「CI 上で本当に検査しているか」を、わざと壊して確かめる。

**e2e とインテグレーションは「導入」ではなく「拡張」。** 統合テストは
`crates/litedoc4/tests/` に 6,469 行あり (抽出器を `/bin/sh` の偽物に差し替える方式)、
e2e は `tools/e2e-micro.sh` が実 Lean で 9 ゲートを回している。**ゼロから作らない** —
既存の土台 (`tests/common/mod.rs` の偽 extractor、`e2e/micro` のフィクスチャ) に載せる。

段の順序:

```
段 0  既にある入力で走るゲートを CI に載せる     ← 最小コスト・即効
段 1  全サブコマンドが通る共通経路               ← 1 箇所壊れると全部壊れる
段 2  queries.rs の 5 サブコマンド (24%)         ← 最大の穴
段 3  壊れた入力を読む経路 (エラー型 3 つ)       ← 利用者が最初に出会う面
段 4  watch (25%)                                ← 利用者が最も長く動かすもの
段 5  md パーサの未到達分岐 (71%)
段 6  中位の穴を選択的に
段 7  仕上げ — 再計測とレポート
```

## 3. 段ごとの内訳

### 段 0 — 既にある入力で走るゲートを CI に載せる → **既に載っていた**【決着 2026-08-24】

**この段はやることが無い。** 棚卸しは「`config-gate.sh` と `usedby-gate.sh` が CI で
1 度も走らない」と報告したが、**実測したら両方とも走っていた** — `tools/e2e-micro.sh` が
823 行目と 830 行目でこの 2 本を呼んでおり、そのスクリプトは `ci.yml` の `e2e-micro`
ジョブが回す。完走ログに両ゲートの出力行がある:

```
usedby       10 module(s), 92 declaration(s); 64 target(s) / 151 edge(s) agree in both directions
config       title 'Micro Fixture' on 10 module page(s) x 3 commands; index.html identical across 3 commands
```

| ID | 結論 |
|---|---|
| **G1** | **やることなし** — `config-gate.sh` は `e2e-micro.sh` 経由で CI で走っている |
| **G2** | **やることなし** — `usedby-gate.sh` も同じ |
| **G3** | **やることなし** — 両ゲートは falsify 手段を自前で持つ (`usedby --drop` / `config --blind`)、ヘッダに落として確かめた旨が書いてある |

**教訓は 2 つあり、どちらも既存の規律の再確認である。**
(1) **項目を潰す前にまず現況を確認する** — 「未」は腐る。
(2) **ゲートが CI で走るかを workflow の grep だけで判定しない** — `e2e-micro.sh` は
4 本 (`site` / `usedby` / `config` / `onemod`) を内部で呼ぶ。**呼び出しは 2 段ある。**

### 段 1 — 全サブコマンドが通る共通経路

`litedoc4/src/cli.rs` (89 行) は**テストが 1 本も無い**が、13 サブコマンド全部がここを通る。

| ID | やること |
|---|---|
| **C1** | 共通パーサの 2 つの拒否 — `--x needs a value` (値なしで終わる) / `--x wants a number, not y` |
| **C2** | `main.rs` の dispatch 4 経路 — `--version` / 引数なし / `--help` / 未知サブコマンド。**exit code も見る** (2 と 0 の区別) |
| **C3** | `Failure` の 4 変種が `main` で正しい ExitCode になること (`Usage`=2 / `Failed`=1 / `Answered`/`Refused`= その code) |

C2/C3 は**プロセスを起こす統合テスト**にする — `ExitCode` は `main` を通らないと出ない。

### 段 2 — `queries.rs` の 5 サブコマンド (本体 24%)

**このファイルの本体 271 行のうち 207 行が、`cargo test` から一度も実行されていない。**
ライブラリ層 (`litedoc4-incr`) のテストは厚いが、**CLI としての引数解析・入出力・
exit code を通すものが無い** (対象リポジトリを要る `tools/*-compare.sh` だけ)。

| ID | サブコマンド | 検査すること |
|---|---|---|
| **Q1** | `links` | 依存マップから表を組む経路。`--link-index` の有無で深いサンプル列が出る/出ない |
| **Q2** | `ownership` | `--base` + `--inc` / `--removed`。所有者の表と、孤児の報告 |
| **Q3** | `merge` | `--base`+`--inc`+`--out` の合流と、`--verify <ir> --against <ir>` の判定 |
| **Q4** | `impact` | `--changed` / `--changed-file` から再描画集合。witness の出方 |
| **Q5** | `prune` | `--dry-run` が**消さない**こと、本番が消すこと |

**入力は偽の IR ツリー**を組む。`crates/litedoc4-incr/tests/` が既にそれをやっているので、
**同じ作り方を `litedoc4/tests/` から使えるようにするのが先** (共通化できなければ複製しない
判断もあり得る → 実装時に決める)。

### 段 3 — 壊れた入力を読む経路

エラー型 3 つが**一度も構築されていない**。利用者が最初に出会う面であり、
`litedoc4-ir::Error::Schema` に至っては**次にすべきこと (`re-extract with --tagged-code`) を
指示する文面**を持っている。

| ID | やること |
|---|---|
| **E1** | `litedoc4-ir::Error` — `Schema` (古い schema の IR) / `Ablated` / `ModuleMismatch` (index と中身の食い違い) / `Json` (途中で切れた JSON) / `Io` を、**入力から**到達させる |
| **E2** | `litedoc4-md::Error` — 到達可能な変種を入力から。`InputTooLarge` のように現実的に作れないものは**作らないと決めて理由を書く** |
| **E3** | `litedoc4-incr::Error` の未到達変種 (本体 67%) |
| **E4** | `litedoc4/src/ledger.rs` (66%) の拒否経路 — サブコマンド無し / 未知のサブコマンド / 壊れた台帳 |

**`ModuleMismatch` は docstring 自身が「増分マージが間違ったファイルをコピーするとこうなる」と
名指ししている** — 検査が無いまま放置する変種ではない。

### 段 4 — `watch` (本体 25%)

`watch-gate.sh` は「**計測対象・toolchain・171 MB の extractor を要るからゲートである**」と
書いている。**この主張をまず疑う** — 「機材が無い」と書いてあった項目が、実は
持っている機材を使っていなかっただけ、という実績が 2 件ある。

| ID | やること |
|---|---|
| **W1** | `run_loop` / `Trigger::ask` / `announce` / `describe` / `Reading::{of,work,what}` を機材ゼロ依存で回す。既存の偽 extractor を使う |
| **W2** | `litedoc4 watch` の統合テスト — 起動・1 回のリビルド・停止。**長命プロセスを確実に殺す** (セッションが落ちても生き残る実績がある。ポートは固定値を避ける) |
| **W3** | `watch-gate.sh` が `e2e/micro` で走るかを**実測**する。走るなら CI に載せる。走らないなら**何が足りないかを 1 行で書いて据え置く** |

**W2 は作業領域を共有する長命プロセスなので、失敗を作業領域のせいに見せかける。**
テストは自分専用の一時ディレクトリを持ち、終了時に必ず kill する形にする。

### 段 5 — md パーサの未到達分岐 (87%、未カバー 53 行)

**中身を読んだら、大半は「バグのときだけ通る」防御分岐だった**【実測 2026-08-24】 —
`Error::Malformed(...)` が 20 箇所以上あり、その docstring 自身が
"Every case is a bug here or a change in md4c, never bad input" と言っている。
**入力から到達させられないものにテストは書けない。**

| ID | やること |
|---|---|
| **M1** | 入力から到達する分岐だけを選んで通す。**先に `parse` / `parse_with_flags` を実際に叩いて、どれが入力で動くかを測ってから決める** — 行番号から推測しない |
| **M2** | `Error::Malformed` / `Md4c` / `NotUtf8` / `InputTooLarge` は**到達不能と書いて閉じる** (`InputTooLarge` は 4 GB の入力が要る) |
| **M3** | `Error::Unrepresentable` は**到達可能** — doc-gen4 が使わないフラグ (inline raw HTML を許す) で `parse_with_flags` を叩くと出る、と docstring が名指ししている。**その 1 本は書く** |

### 段 6 — 中位の穴を選択的に

**ここは「全部やる」段ではない。** 各ファイルの未カバー行を読んで、
**利用者に当たる経路だけ**を選ぶ。選ばなかったものは理由を書いて閉じる。

| ID | 対象 | 見るもの |
|---|---|---|
| **P1** | `litedoc4/src/build.rs` (81%) | 未カバー 100 行のうち、拒否・フォールバック経路 |
| **P2** | `litedoc4/src/pipeline.rs` (83%) | 同上 114 行 |
| **P3** | `litedoc4/src/extract.rs` (75%) / `stages.rs` (77%) | 引数の組み合わせと拒否 |
| **P4** | `litedoc4-global/src/site.rs` (70%) / `litedoc4-incr/src/prune.rs` (73%) | |
| **P5** | `litedoc4/src/deps_docs.rs` (80%) / `resident.rs` (86%) | |

### 段 7 — 仕上げ

| ID | やること |
|---|---|
| **F1** | カバレッジを**同じ手順で再計測**し、前後を `benchmarks/results/coverage-2026-08-24.txt` に書く。**cold/warm は無関係だが、母数 (走ったテスト数) は必ず記録する** |
| **F2** | `tools/corpus-gate.sh --verify-list` が緑であること (`#[ignore]` を足したなら台帳も直す) |
| **F3** | CI (`ci.yml`) を実際に走らせて緑を確認する。ブランチ push + `gh workflow run` |
| **F4** | 途中で見つけた欠陥を `docs/milestone-log.md` に記録する |

## 4. やらないと決めたもの

**すべて理由を書く。** 蒸し返すなら同じ検討をやり直すこと。

| # | やらないもの | 理由 |
|---|---|---|
| **N1** | `extractor/Extract.lean` (3,687 行) の単体テスト | Lean 側にテストフレームワークを導入するコストに対し、**`e2e-micro.sh` のゲート 7/8/9 が実 IR を名前レベルで検査している** (sorry の 3 形 / 属性の対 / `@[ext]` の由来)。抽出器の契約を守っているのはそこ。**「テストが 1 本も無い」は事実だが「検査が無い」ではない** |
| **N2** | 依存ドキュメントサイトのネットワーク経路をモックする | `deps-docs-gate.sh` (740 行) が実サーバに対して両方向を検査している。モックは**同じ前提を 2 度書く経路**を作り、404 の実挙動を再現しない |
| **N3** | `cargo-mutants` を回して mutation score を上げる | 「推奨レベル」を超える。カバレッジの穴が 1,514 行ある段階で mutant を追うのは順序が逆 |
| **N4** | カバレッジのしきい値を CI のゲートにする | **壁時計をゲートにしないのと同じ理由** — 数値が落ちたときに「何が壊れたか」を 1 行で言えない。`#[ignore]` の増減でも動く |
| **N5** | 両クレートの `build.rs` (99 + 32 行) のテスト | ビルドが通らなければ**全テストが走らない**ので、既に最強の検査下にある |

**保留 (段 6 の後に判断する)**: サイトの TypeScript 24 ファイル中テストは 5 つ。
`browser-gate.sh` と `assets-gate.sh` が別の角度から見ているが、`result-item.ts` /
`search-page.ts` は利用者が最も触る部分。**段 6 までを終えた時点のコストで決める。**

## 5. 順序と依存

段 0 と段 1 は独立。段 2 は「偽 IR ツリーをどう組むか」を決めてから (段 0/1 と並行可)。
段 3〜5 は互いに独立。段 6 は段 2〜5 で埋まった分を差し引いてから選ぶ (**先に決め打ちしない** —
段 2〜5 のテストが中位ファイルの行も通すので、**やる前に見積もると空振りする**)。
段 7 は最後。

## 6. 撤退ライン / 判断軸

- **カバレッジの数値は目標ではない。** 81.6% → 90% 前後は**結果の見込み**であって、
  達成すべき数ではない。**90% に届かなくても、利用者経路が検査下に入っていれば完了**。
  逆に**数値だけ上げるテスト (Display の文字列突き、getter の往復) は書かない**。
- **1 つの穴に 2 つ目の検査を足さない。** ゲートが見ているものをテストで書き直すのは、
  2 本目が読まれなくなるだけ。段 0 の 2 本を CI に載せるのはその逆 (**1 本目が動いていなかった**)。
- **テストを足して落ちたら、それは欠陥である。** 直す。**直したら一般形に引き上げたか問う** —
  「この判断をしている箇所は他にあるか」「同じ前提が別の入力で崩れないか」。
- **`cargo test --workspace` は 20 分超。** background で回す。パイプで `tail` に食わせない
  (終了コードが tail のものになる)。
- **`#[ignore]` を足したら `tools/corpus-tests.txt` に 1 行足す。** 両方向の差を CI が見ている。
- **足したテストが遅ければ、それは足さなかったのと同じ。** 1 本が数秒を超えるなら、
  入力を小さくするか、ゲートに移すかを決める。
