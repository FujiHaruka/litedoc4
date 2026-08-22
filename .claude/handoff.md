# Handoff — 2026-08-23 (リファクタリング)

## Relay control
- Mode: ON
- Goal: `docs/plans/refactoring.md` を段 0 から段 8 まで完遂する。段 0 (D0〜D14) が最優先で、
  D0 (merge が IR を破壊する) から。各項目は**テストを先に書いてから直す**。1 commit = 1 項目。
  各段の終わりで `cargo test --workspace` / `cargo fmt --check` /
  `cargo clippy --workspace --all-targets -- -D warnings` /
  `cargo doc` (`RUSTDOCFLAGS=-D warnings`) を緑に戻す。
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: (進行中)

## State

- Branch: **`main`** / clean / **`45b0cea`** まで push 済み
- **計画は `docs/plans/refactoring.md` (1,141 行)。起票 2026-08-23、commit `45b0cea`**
- ベースライン【実測 2026-08-23】: `cargo test --workspace --no-fail-fast` =
  **36 バイナリ / 437 passed / 0 failed / 21 ignored**、`fmt` / `clippy` / `doc` すべて緑
- 作業領域 `/private/tmp/lean-doc-relay` は 34 MB。**ディスクの空きは 17 GiB しかない**

## この計画の作り方 (次 leg が前提を疑わなくて済むように)

木の全体を 4 系統に分けて調べた。Rust は crate 別に subagent 3 体、
shell / CI / Lean / web / 横断指標は自分で。**すべての指摘に `file:line` の根拠がある。**
段 0 の 15 件は「リファクタリング」ではなく**今すでに壊れているもの**。

## Next step

**D0 から。** `crates/litedoc4-incr/src/merge.rs:348` の `options.out != options.base` が
`Path` の綴り比較なので、`--base ./ir --out ir` が「別ツリー」と判断され
`fs::copy` が**同一実体を 0 バイトに truncate する**【実測、2 回独立に再現】。
先に「`--base ./x --out x` で中身が残る」テストを書く。

## Files to read first

- `docs/plans/refactoring.md` — §1・§2・§12〜§16 と着手する段だけ読めばよい (冒頭に読み方がある)
- §14「触らないもの」は**着手前に必ず読む**
