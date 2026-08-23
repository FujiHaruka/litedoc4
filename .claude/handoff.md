# Handoff — 2026-08-24 (テストの穴を埋める)

## Relay control
- Mode: ON
- Goal: `docs/plans/test-coverage.md` を全 30 項目決着まで完遂する。
  **推奨レベルまで** — 数を目標にしない、やりすぎない。過程で見つけた欠陥は直す。
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion
- Progress ledger:
  - r1: **決着 16 / 30**。段 0 (既に CI で走っていた) / 段 1 (C1〜C3) / 段 2 (Q1〜Q5) /
    段 3 E1・E2 / 段 5 (M1〜M3、到達不能で決着)。**テストは 39 本増えた**
    (503 → 542 passed)。commit `c7df7a5`〜`97a3e4a`

## State

- Branch: **`main`** / clean / push 済み
- **計画の SoT は `docs/plans/test-coverage.md`** (299 行)。数字はすべてそこ
- **検証は全部緑**【実測 2026-08-24】 — `cargo test --workspace --no-fail-fast` が
  **44 バイナリ / 542 passed / 0 failed / 22 ignored**、fmt / clippy / doc / machete も 0。
  検証スクリプトは `/private/tmp/lean-doc-relay/testcov/verify.sh` (各段のログと
  終了コードを別々に残す。**パイプを使わない**)
- `#[ignore]` は増えていないので `tools/corpus-tests.txt` は触っていない

## 残り 14 項目 — 次の一手

**段 4 (watch) が最大の穴** — 本体 **23% / 未カバー 200 行**。ここから。

| 段 | ID | 中身 |
|---|---|---|
| 4 | W1 | `run_loop` / `Trigger::ask` / `announce` / `describe` / `Reading::{of,work,what}` を機材ゼロ依存で |
| 4 | W2 | `litedoc4 watch` の統合テスト。**長命プロセスなので Drop guard で必ず kill する** |
| 4 | W3 | `watch-gate.sh` が `e2e/micro` で走るか実測。**`--target`/`--lib`/`--module`/`--other`/`EXTRACT_BIN` を全部引数で受けるので見込みはある**。ゲートは対象のソースを編集するので複製が要る |
| 3 | E3 | `litedoc4-incr::Error` の未到達変種。**段 2 で大半が通った可能性がある — 先に再計測を見る** |
| 3 | E4 | `litedoc4/src/ledger.rs` — **`ledger touch` が一度も走っていない**。サブコマンド無し / 未知のサブコマンド / check の出力 3 行 |
| 6 | P1〜P5 | 中位の穴。**段 4 の後に再計測してから選ぶ。先に決め打ちしない** |
| 7 | F1〜F4 | 再計測 + `benchmarks/results/coverage-2026-08-24.txt` + CI 実走 + 欠陥の記録 |

## この leg で踏んだもの (繰り返さない)

1. **`cargo fmt --all` を回さずに commit して、HEAD の `cargo fmt --check` を赤くした**
   (`ci.yml:121`)。→ **commit の前に必ず `fmt --check` を回す**
2. **カバレッジの行の数え方を自作して間違えた。** `--json` の segments は 1 行に複数
   リージョンが乗る (`?` のエラー経路)。最小を取れば 81.6%、最大なら 87.3%、
   llvm-cov 自身の per-file 値はその間。→ **`--lcov` を使う** (1 行に 1 つの count)。
   確定値は **本体 86.9%** (`#[cfg(test)]` より手前だけ)
3. **`rg -oh` は `--help` を出す** — ripgrep の `-h` は `--no-filename` ではない (`-I` がそれ)
4. **subagent の「CI で走らないゲート」報告が誤りだった。** `e2e-micro.sh` が
   `site`/`usedby`/`config`/`onemod` の 4 本を内部で呼ぶ。**呼び出しは 2 段ある**

## 計測コマンド (再計測はこれ)

```sh
mise exec -- cargo llvm-cov --workspace --no-fail-fast --lcov --output-path cov.lcov
# 本体だけ数える: 各 src ファイルの最初の `#[cfg(test)]` より手前の DA: 行を数える
# 集計スクリプトはスクラッチにある (セッションが変わったら書き直す。20 行程度)
```

**`target/llvm-cov-target` は 880 MB、空きは 16 GiB。段 7 F1 で `cargo llvm-cov clean` する
— 掃除の主体はそこ。** このリポジトリは満杯のディスクで対象リポジトリを一度壊している。

## 作業領域

`/private/tmp/lean-doc-relay/testcov/` — e2e の出力 (6.6 MB)、検証ログ、
falsify 用のバックアップ。**段 7 が終わったら消す。**
