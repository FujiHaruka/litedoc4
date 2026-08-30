# Handoff — 2026-08-30 (relay leg 1)

## State

**pure Lean 移植の着手。** 計画は `.claude/purelean-plan.md`（このリレーの SoT）。
計測の根拠は `benchmarks/purelean-report.md`。

- litedoc4: main `71afa49` から開始。clean
- 前提: pure-Lean study は完了済み。プロトタイプ `benchmarks/lean-prototype/` が
  render 1,866 行 + incr core 1,079 行を持ち、対象リポジトリで **422/422 バイト一致**

## 確定した判断（2026-08-30、ユーザー判断）

骨格先行 / Rust は完了時に削除して `rust-frozen` タグ / バイナリ配布を廃止して
`require` のみ / main 上で加算的に。詳細と根拠は計画ファイル。

## Files to read first

1. `.claude/purelean-plan.md` — マイルストーンと完了判定
2. `benchmarks/purelean-report.md` — 何が計測済みで何が未計測か
3. `lakefile.lean` — `package litedoc4 (srcDir := "extractor")` / `lean_exe extract` /
   `resolveLitedoc4`（M9 で消す 250 行）
4. `e2e/consumer/lakefile.toml` — path require の開発ワークスペース

## Next step

**M1 骨格**: `src/Litedoc4/` を作り、root lakefile に `lean_lib Litedoc4` +
`lean_exe litedoc4`（**`import Lean` 禁止**）を足し、vendor md4c と libc shim を
製品ツリーへ移し、`cd e2e/consumer && lake build litedoc4` を通す。
完了判定は `litedoc4 --version` が Rust 版と同じ文字列を出すことと、
`tools/purelean-gate.sh` が（先に一度落としてから）通ること。

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 1 / cap 40
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: (進行中)
