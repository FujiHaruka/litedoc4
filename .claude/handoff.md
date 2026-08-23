# Handoff — 2026-08-24 (テストの穴を埋める)

## Relay control
- Mode: ON
- Goal: `docs/plans/test-coverage.md` を全 30 項目決着まで完遂する。
  **推奨レベルまで** — 数を目標にしない、やりすぎない。過程で見つけた欠陥は直す。
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion
- Progress ledger:
  - r1: **決着 26 / 30**。段 0〜6 が全部決着し、**残るのは段 7 (F1〜F4) だけ**。
    **新しく書いたテストは 62 本** (503 → 563 passed)。**製品の欠陥を 1 件出して直した** —
    `litedoc4 ledger --help` だけが使い方を出さず exit 2 で拒否していた。
    **`ci.yml` に watch gate を載せ、ブランチで実走して 3 ジョブ緑を確認済み**
    ([run 32655090556](https://github.com/FujiHaruka/litedoc4/actions/runs/32655090556))。
    commit `c7df7a5`〜(段 6 P1)

## State

- Branch: **`main`** / clean / push 済み
- **計画の SoT は `docs/plans/test-coverage.md`** (299 行)。数字はすべてそこ
- **検証は全部緑**【実測 2026-08-24】 — `cargo test --workspace --no-fail-fast` が
  **44 バイナリ / 542 passed / 0 failed / 22 ignored**、fmt / clippy / doc / machete も 0。
  検証スクリプトは `/private/tmp/lean-doc-relay/testcov/verify.sh` (各段のログと
  終了コードを別々に残す。**パイプを使わない**)
- `#[ignore]` は増えていないので `tools/corpus-tests.txt` は触っていない

## 残り 4 項目 — 次の一手

**段 7 だけが残っている。**

| ID | 中身 |
|---|---|
| **F1** | 最終カバレッジを再計測し、前後を `benchmarks/results/coverage-2026-08-24.txt` に書く。**母数 (走ったテスト数) を必ず記録する**。**測り終えたら `cargo llvm-cov clean`** |
| **F2** | **済** — `tools/corpus-gate.sh --verify-list` は緑、`#[ignore]` は 22 のまま増やしていない |
| **F3** | **一度済** (上の run)。**段 6 P1 の commit を入れた後にもう一度 main で緑を確認する** |
| **F4** | 見つけたものを `docs/milestone-log.md` に記録する (下の「この leg で出たもの」) |

### F1 に必ず書く申し送り

**`watch.rs` の未カバー 73 行は「未検査」ではない。** `run_loop` の中で実際に走っていて
`tests/watch.rs` が log で assert しているが、テストが `Child::kill()` (SIGKILL) するので
**子プロセスの profraw が flush されない**。同じ lcov で `main.rs` が 39/39、
`queries.rs` が 333/335 なのは、そちらの子が正常終了するから。

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
