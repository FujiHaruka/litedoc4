# Handoff — 2026-08-24 (コメント削減)

## Relay control
- Mode: ON
- Goal: `CLAUDE.md` の新しい `## コードのコメント` 規則 (既定はコメントしない /
  非自明な why not だけ) に合わせて、**コード表面のコメントを全面的に削減する**。
- Leg: 2 / cap 8
- Predecessor: none  (leg 1 はユーザーの元セッションで tmux 名を持たない。kill しない)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: `CLAUDE.md` の規則整備 + **Rust 6 範囲**。木全体 22,388 → 17,960 行 (−20%)。
    commit `c57f2df` `3ad2073` `03e1ded` `fcc4b6a` `1934448` `ee173e1` `a9a63b7` `a5be49e`

## 次の一手

**`crates/litedoc4/src` の大きい 4 ファイル (pipeline.rs 703 / build.rs 553 /
resident.rs 374 / packages.rs 362 = 1992 行) を subagent に投げる。**
下の「進め方」と「subagent プロンプトに必ず入れる 5 点」に従うこと。

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
| `crates/litedoc4-render/tests` + `litedoc4-testutil` | 1923 → 1197 | −38% | `a5be49e` |
| **計** | **11,112 → 6,687** | **−40%** | |

## 残っている範囲 (この順で)

| # | 範囲 | コメント行 | 備考 |
|---|---|---|---|
| 1 | `crates/litedoc4/src` の大 4 本 | 1992 | `pipeline.rs` 703 / `build.rs` 553 / `resident.rs` 374 / `packages.rs` 362。**`plan §6` 系の死んだ参照が集中している** |
| 2 | `crates/litedoc4/src` の残り | 1527 | `watch.rs` 289 / `deps_docs.rs` 263 / `extract.rs` 230 / `lib.rs` 214 / `httpd.rs` 135 / `queries.rs` 113 / `lakefile.rs` 87 / `stages.rs` 74 / `cli.rs` 72 / `ledger.rs` 45 / `main.rs` 5。**`lib.rs` の doctest 1 本は `ignored` だが消すな** |
| 3 | `crates/litedoc4/tests` | 1691 | `incremental.rs` 417 / `build.rs` 355 / `queries.rs` 232 / `watch.rs` 137 / `common/mod.rs` 132 / `ledger.rs` 112 / `site.rs` 94 / `extract.rs` 68 / `resident.rs` 58 / `cli_surface.rs` 50 / `page_paths.rs` 36 |
| 4 | `tools/*.sh` + `tools/lib` | 3396 | **`usage:` ブロックは残す** (インターフェース)。`trap`/パイプの罠の注意書きも残す |
| 5 | `extractor/Extract.lean` + `lakefile.lean` | 511 | **`Extract.lean` のヘッダは `--help` の usage を兼ねている。usage は残す。`Böving` / `Apache` は provenance ゲートが grep する** |
| 6 | TS (`crates/litedoc4-render/web/src`, `**/tests/oracle/*.ts`, `tools/*.ts`) | 806 | 触ったら `mise exec -- tools/assets-gate.sh` を回す |
| 7 | `benchmarks/tools/*` | 1353 | **最後。計測条件・単位・集計方法は残す** |
| 8 | `.github/workflows/*.yml` | ? | **最後。** `ci.yml` の Rustdoc links ステップが「this repository's doc comments are where the reasoning lives」と書いている — **新規則と食い違うので直す** |

着手前の合計は **22,388 行**、現在 **17,960 行**。

## ベースライン (着手前、8 段すべて緑)

`fmt` / `clippy` / `doc` / `machete` / `test` (46 バイナリ・**564 passed / 0 failed /
22 ignored**、**doctest 12 本** = 11 passed + 1 ignored) / `corpus --verify-list` /
`provenance` (31 claims) / `assets` (biome 48/48、`app.js` 15370 B)。
記録は `/private/tmp/lean-doc-relay/comment-diet/baseline.txt`。
**6 範囲を終えた時点のフル 8 段は `full-r1.txt`。**

## 罠 (この作業固有。全部踏んだ or 確認済み)

- **`tools/provenance-files.txt` が指す attribution を消すと `provenance-gate.sh` が落ちる。**
  残りの範囲で該当するのは **`extractor/Extract.lean` (`Böving` / `Apache`)** と
  **`crates/litedoc4-render/assets/style.css` (`Böving` / `Apache 2.0` / `math-core` /
  `Charles Edward Gagnon`)**。全一覧は policy.md
- **`cargo check` では `clippy::doc_lazy_continuation` を捕まえられない**【実測】
- **走っているシェルスクリプトを書き換えると実行が壊れる**【実測】 — bash はバイト位置で
  読み進める。`verify.sh` を回している最中に編集して `line 24: eps: command not found` になった
- **subagent は 529 で途中終了することがある**【実測】 — 編集は残るが検証は回っていない。
  `git status` で範囲を見て、**同じ agent に SendMessage で再開させる** (context を持っている)
- **死んだ計画参照は doc コメントだけでなく assert の文字列にもある**【実測】 —
  `fragment.rs` の `"plan §4 measured 8"`、`assets.rs` の `"決定 1 says…"` を直した。
  **`rg 'plan §|Plan 決定|実装計画' crates/` で残りを確認する**
- **doc ブロックが隣の関数に貼り違っていることがある**【実測、`page_parts.rs`】 —
  `cargo doc` も clippy も検出しない
- `crates/litedoc4-render/src/assets.rs` の `every_class_the_renderer_emits_is_styled` は
  `frame.rs` / `page.rs` / `decl.rs` / `code.rs` と `web/src/*.ts` を **`include_str!` で
  読んで** `class="` を数える。**そのファイルのコメントを触る作業はゲートの母数に触りうる**
  (今回は doc が素のクォートを使うので無害だった)

## この leg で出た宿題

- `tools/ledger-reference.sh` / `ledger-compare.sh` / `impact-reference.sh` が説明している
  **`--impl ts` の半分は `experiments/` と一緒に消えている可能性**がある。
  範囲 4 で**スクリプト自体がまだ動くか**を確かめる
