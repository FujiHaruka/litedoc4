# Handoff — 2026-08-24 (コメント削減)

## Relay control
- Mode: ON
- Goal: `CLAUDE.md` の新しい `## コードのコメント` 規則 (既定はコメントしない /
  非自明な why not だけ) に合わせて、**コード表面のコメントを全面的に削減する**。
- Leg: 2 / cap 8
- Predecessor: none  (leg 1 はユーザーの元セッションで tmux 名を持たない。kill しない)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: `CLAUDE.md` の規則整備 + **Rust 全部** + **`tools/*.sh` の 8 本**。
    木全体 22,388 → 約 15,000 行。commit `c57f2df` `3ad2073` `03e1ded` `fcc4b6a`
    `1934448` `ee173e1` `a9a63b7` `a5be49e` `159ac85` `daa46a0` `1471b9f` `b0c40c2`。
    **`159ac85` / `daa46a0` で main を 2 回赤くし、`1471b9f` で直した** (下の罠)

## 次の一手

**`tools/` の残り 29 本のシェルを subagent が処理中** (leg 1 の最後の dispatch)。
それが戻ったら:

1. **`tools/e2e-micro.sh` をローカル実走**して緑を確認する — `verify.sh` はシェルの
   ゲートを**一切見ていない**。`tools/lib/common.sh` を触っているので、シェル 2 バッチ
   (`b0c40c2` = commit 済み・**未 push**、と 29 本ぶん) をまとめて 1 回で検査する。
   終わったら**作業ディレクトリを消す** (CLAUDE.md の 24 GB 事故)
2. 緑なら 2 バッチまとめて push
3. 続きは下の「残っている範囲」の 5〜8

## この作業の規範

- **`CLAUDE.md` の `## コードのコメント`** が規範。
- **作業手順版は `/private/tmp/lean-doc-relay/comment-diet/policy.md`**
  — 消す 8 分類 / 残す a〜e / 絶対に消さない (provenance) / 触らない /
  言語ごとの追記 / 線引きの追記 / 検証は `cargo check` では足りない。
  **subagent には必ずこれを読ませる。** 消えていたら CLAUDE.md から再生成する。
- プロンプト雛形: `/private/tmp/lean-doc-relay/comment-diet/prompt-template.md`

## 進め方 (6 範囲で確立済み。この形で回す)

1. 範囲を切って subagent に dispatch (**同時 1 体**、**commit させない**、model は Opus)
2. 戻ってきたら **コメント以外の変更**を洗い出して読む:
   ```
   git diff -U0 <範囲> | grep -E '^[-+]' | grep -vE '^[-+]{3}' \
     | grep -vE '^[-+]\s*(//|/\*|\*)' | grep -vE '^[-+]\s*$'
   ```
   毎回 0〜7 行出る (`#[expect]` の reason、assert メッセージ、区切りと一緒に消えた空行)。
   妥当なら通す
3. **`/private/tmp/lean-doc-relay/comment-diet/verify.sh --fast`**
   (fmt / clippy / doc / provenance / doctest。**パイプ無し**、ログは `logs/<段>.log`)。
   引数なしで CI の 8 段全部 (`cargo test` を含むので 15 分近くかかる)
4. 緑なら `git add <範囲> && git commit && push`
   (push は `GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=''
   GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1='!gh auth git-credential'
   git push https://github.com/FujiHaruka/litedoc4.git main:main`)

**subagent プロンプトに必ず入れる 5 点** (どれか欠けると緩くなる / 壊れる):

1. **判定基準** — 各コメントに「名前 (型名・関数名・テスト名) がすでに言っているか」
   「本体を 3 秒読めば分かるか」を問い、**どちらか yes なら消す**。
   **「あると親切」は残す理由にならない**
2. **`cargo check` では足りない。`cargo clippy --workspace --all-targets -- -D warnings` を回せ**
   (折り返した doc 行の行頭が `+` / `-` になると `clippy::doc_lazy_continuation` で落ちる【実測】)
3. **そのバッチに含まれる provenance 対象ファイルと必要文字列の表**
4. **走る doctest の本数**を明示 (```` ``` ```` 言語指定なしはテスト。```text は走らない)
5. **死んだ計画への参照は消す / 生きている docs は区別する** (下記)

**死んだ**: `plan §6` `Plan 決定 1` `実装計画 §4` `docs/plans/...` `M3-d2 の債務 1`
`段 D` `M8-d` `C-2` `search-v2 P0` — 実装計画・実装ログ・完遂した計画文書 19 本は
2026-08-24 に削除済み。**生きている**: `docs/approach.md` (§1〜4, §7〜10) /
`docs/approach-pillars.md` (§5) / `docs/approach-performance.md` (§6) /
`docs/verification-log.md` / `docs/provenance.md` — ただし**実質が同じ文にあるなら
節番号だけ落とす**。`docs/provenance.md` への参照は根拠なので消すな。

## 済んだもの

| 範囲 | before → after | | commit |
|---|---|---|---|
| `CLAUDE.md` の規則整備 | — | | `c57f2df` `3ad2073` |
| `crates/litedoc4-ir` | 1098 → 525 | −52% | `03e1ded` |
| `crates/litedoc4-md` | 1271 → 766 | −40% | `fcc4b6a` |
| `crates/litedoc4-global` | 1920 → 1154 | −40% | `1934448` |
| `crates/litedoc4-incr` | 2303 → 1421 | −38% | `ee173e1` |
| `crates/litedoc4-render/src` + `build.rs` | 2597 → 1624 | −37% | `a9a63b7` |
| `crates/litedoc4-render/tests` + `testutil` | 1923 → 1197 | −38% | `a5be49e` |
| `crates/litedoc4/src` の大 4 本 | 1992 → 1266 | −36% | `159ac85` |
| `crates/litedoc4/src` の残り 11 本 | 1527 → 891 | −42% | `daa46a0` |
| `crates/litedoc4/tests` (+ 赤の修正) | 1691 → 920 | −46% | `1471b9f` |
| `tools/*.sh` の大 8 本 | 1684 → 1013 | −40% | **`b0c40c2` (未 push)** |
| **Rust 合計** | **16,313 → 9,761** | **−40%** | |

**Rust は全部終わっている。** フル 8 段は緑で、**テスト数は着手前と同一**
(`564 passed / 0 failed / 22 ignored`、doctest 12 本)。

## 残っている範囲 (この順で)

| # | 範囲 | コメント行 | 備考 |
|---|---|---|---|
| 1 | `tools/` の残り 29 本 | ~1712 | **leg 1 で実行中**。終わったら e2e-micro 実走 → 2 バッチまとめて push |
| 2 | `extractor/Extract.lean` + `lakefile.lean` | 511 | **`Extract.lean` のヘッダは `--help` の usage を兼ねている。usage は残す。`Böving` / `Apache` は provenance ゲートが grep する。検査は `tools/e2e-micro.sh` (実 extractor を建てる)** |
| 3 | TS (`crates/litedoc4-render/web/src`, `**/tests/oracle/*.ts`, `tools/*.ts`) | 806 | 触ったら **`mise exec -- tools/assets-gate.sh`** (素で呼ぶと node が SIGKILL) |
| 4 | `benchmarks/tools/*` | 1353 | **計測条件・単位・集計方法は残す**。`benchmarks/results/**` には触るな |
| 5 | `.github/workflows/*.yml` | ? | `ci.yml` の Rustdoc links ステップが「this repository's doc comments are where the reasoning lives」と書いている — **新規則と食い違うので直す** |
| 6 | **印字文字列の死んだ参照の一括掃除** | — | 下の一覧。**最後に 1 回だけ、フル 8 段 + e2e-micro と一緒に** |

## 最後にやる: 印字文字列に埋まった死んだ参照

**subagent には触らせない** (別クレートの assert が部分文字列を見ていることがある)。
統合側が最後に一度だけ直し、**フルのテストで確かめる**。既知の一覧:

| file:line | 文言 |
|---|---|
| `tools/build-gate.sh:185` | `"tools/rebuild-own.sh first (stage 5e (e))"` |
| `tools/clone-gate.sh:304` | 同上 |
| `tools/deps-docs-gate.sh:196` | `"the build did not turn A-1 on"` |
| `tools/e2e-micro.sh:630` | `"…which B-0 §6 measured as 0 on both samples: "` |
| `crates/litedoc4/src/extract.rs` | `"…session's scratchpad path and is gone"` (経緯。ラベルは除去済み) |

**`tools/make-target2.sh` の 3 件 (`L3-2` / `L3-1` / `plan 決定 5`) は別扱い** —
生成される `.lean` の docstring で、**target 2 の IR とページのバイトに出る**。
凍結フィクスチャに影響しうるので、直すなら `target2-gate.sh` を回せる状態で。

## ベースライン (着手前、8 段すべて緑)

`fmt` / `clippy` / `doc` / `machete` / `test` (46 バイナリ・**564 passed / 0 failed /
22 ignored**、**doctest 12 本** = 11 passed + 1 ignored) / `corpus --verify-list` /
`provenance` (31 claims) / `assets` (biome 48/48、`app.js` 15370 B)。
記録は `/private/tmp/lean-doc-relay/comment-diet/baseline.txt`。
**6 範囲を終えた時点のフル 8 段は `full-r1.txt`。**

## 罠 (この作業固有。全部踏んだ or 確認済み)

- **`verify.sh` に fast モードは無い。作ってはいけない**【実測 2026-08-24、main を 2 回赤くした】。
  `cargo test` 抜きの 5 段を commit の判定に使った結果、コメント削減が**製品が印字する
  文字列リテラル**に踏み込んだのを誰も見ていなかった。`check_source_url` の拒否から
  `(coverage.ts:512)` を、`--jobs` の拒否から `(plan §6, constraint 6)` を落として、
  **別のクレートの `tests/` にある assert 2 本**が落ちた。
  **subagent への検証指示も `cargo test -p <crate>` にする** — `--lib` は `tests/` を見ない
- **`verify.sh` はシェルのゲートを一切見ていない。** `tools/*.sh` を触ったら
  **`bash -n` 全ファイル + 埋め込み python ヒアドキュメントの `compile()` +
  `--help` の実出力 + `tools/e2e-micro.sh` のローカル実走**が要る
  (`bash -n` はヒアドキュメントの中を見ない)
- **`tools/provenance-files.txt` が指す attribution を消すと `provenance-gate.sh` が落ちる。**
  残りの範囲で該当するのは **`extractor/Extract.lean` (`Böving` / `Apache`)** と
  **`crates/litedoc4-render/assets/style.css` (`Böving` / `Apache 2.0` / `math-core` /
  `Charles Edward Gagnon`)**。全一覧は policy.md
- **`cargo check` では `clippy::doc_lazy_continuation` を捕まえられない**【実測】 —
  折り返した doc 行の行頭が `+` / `-` になるとリスト項目と読まれる
- **走っているシェルスクリプトを書き換えると実行が壊れる**【実測】 — bash はバイト位置で
  読み進める。`verify.sh` を回している最中に編集して `line 24: eps: command not found` になった
- **subagent は 529 で途中終了することがある**【実測】 — 編集は残るが検証は回っていない。
  `git status` で範囲を見て、**同じ agent に SendMessage で再開させる** (context を持っている)
- **doc ブロックが隣の宣言に貼り違っていることがある**【実測、4 件】 —
  関数が消えると doc が次の宣言へ黙って移る。**`cargo doc` も clippy も検出しない**
- **doc の数字とアサーションが食い違っていることがある**【実測、5 件】 —
  「64 のうち 21」と書いてあって実体は `[&str; 69]` だった。**数字を直すのではなく
  定数名を指す**ようにする (アサーションが本当の検査)
- **subagent が同じ範囲を 2 体で触らないよう、staging はパス指定で**。
  `git add crates/litedoc4/src` は次の担当の途中結果まで巻き込む
- `crates/litedoc4-render/src/assets.rs` の `every_class_the_renderer_emits_is_styled` は
  `frame.rs` / `page.rs` / `decl.rs` / `code.rs` と `web/src/*.ts` を **`include_str!` で
  読んで** `class="` を数える。**そのファイルのコメントを触る作業はゲートの母数に触りうる**

## この leg で片付いた宿題

- `tools/*-reference.sh` / `*-compare.sh` の **`--impl ts` は実在しない経路だった**【確認済み】 —
  `incremental-reference.sh` に `--impl` フラグ自体が無く、引数ループが exit 2 で弾く。
  消えたプロトタイプ (`experiments/stage7h/incremental.sh`) を説明する散文だけが
  7 本すべてに複製されていた
