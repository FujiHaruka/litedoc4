# Handoff — 2026-08-24 (コメント削減)

## Relay control
- Mode: ON
- Goal: `CLAUDE.md` の新しい `## コードのコメント` 規則 (既定はコメントしない /
  非自明な why not だけ) に合わせて、**コード表面のコメントを全面的に削減する**。
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: (進行中)

## この作業の規範

- **`CLAUDE.md` の `## コードのコメント`** が規範。
- **作業手順版は [`/private/tmp/lean-doc-relay/comment-diet/policy.md`](/private/tmp/lean-doc-relay/comment-diet/policy.md)**
  — 「消す 8 分類 / 残す a〜e / 絶対に消さない (provenance) / 触らない」。
  **subagent には必ずこれを読ませる。** 消えていたら `git log` の
  この handoff の履歴か、CLAUDE.md から再生成する。

## 進め方 (確立済み)

1. crate / ディレクトリ単位で subagent に dispatch (**同時 1 体**、commit させない)
2. 戻ってきたら `git diff` を読んで判断を検証
3. **`/private/tmp/lean-doc-relay/comment-diet/verify.sh`** を回す
   (CI の「test (no corpus, no Lean)」ジョブと同じ 8 段。**パイプ無し**、
   各段のログは `logs/<段>.log`、終了コードは行ごとに印字)
4. 緑なら commit & push

## 残っている範囲 (コメント行数は着手前の実測)

| 範囲 | ファイル | コメント行 | 状態 |
|---|---|---|---|
| `crates/litedoc4-ir` | 10 | 1098 | **r1 で subagent 実行中** |
| `crates/litedoc4-md` | 16 | 1271 | 未 |
| `crates/litedoc4-testutil` | 7 | 689 | 未 |
| `crates/litedoc4-global` | 12 | 1920 | 未 |
| `crates/litedoc4-incr` | 13 | 2303 | 未 |
| `crates/litedoc4-render` | 24 | 3831 | 未 |
| `crates/litedoc4` | 26 | 5210 | 未 (src / tests で分ける) |
| `tools/*.sh` | ~30 | ~2500 | 未 |
| `extractor/Extract.lean` + `lakefile.lean` | 2 | 511 | 未 |
| TS (`crates/litedoc4-render/web/src`, `tests/oracle`) | ~12 | ~600 | 未 |
| `benchmarks/tools/*` | ~20 | ~700 | 未 (最後。計測条件は残す) |

合計 **約 20,500 行**が着手前のコメント行数。

## 済んだもの

- `CLAUDE.md` に `## コードのコメント` 節を追加 (`c57f2df`)
- コンフリクトする「コード表面から docs を参照しない」規則を削除し、
  先頭の SoT 記述と `crates/` の表の行を新規則に揃えた (`3ad2073`)

## 罠 (この作業固有)

- **`tools/provenance-files.txt` が指す attribution 文字列を消すと `provenance-gate.sh` が落ちる。**
  対象は `extractor/Extract.lean` / `litedoc4-md` の 6 ファイル / `litedoc4-render` の 3 ファイル /
  `litedoc4-global/src/v8_gc.rs` / `assets/style.css`。policy.md に一覧がある
- **doctest はテスト**。```` ```rust ```` フェンスを消すとテストが減る
  (```text / ```no_run / ```ignore は走らない)
- **intra-doc link** を消すと、それを指している側で `cargo doc -D warnings` が落ちる
- `Cargo.toml` の `[workspace.lints]` のコメントは **CLAUDE.md が保存を要求している** — 触らない
- `.github/workflows/ci.yml` の Rustdoc links ステップのコメントが
  「this repository's doc comments are where the reasoning lives」と書いている。
  **新規則と食い違うので最後に直す**
