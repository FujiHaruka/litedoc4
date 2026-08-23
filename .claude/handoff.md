# Handoff — 2026-08-23 (リファクタリング)

## Relay control
- Mode: ON
- Goal: `docs/plans/refactoring.md` を段 0 から段 8 まで完遂する。各項目は**テストを先に書いてから直す**。
  1 commit = 1 項目 (絡んでいるものは `X2+X6` のように 2 項目 1 コミットにしてよい。
  **ただしビルドが通らない中間コミットを作るくらいなら束ねる**)。各段の終わりで下の 5 つを緑に戻す。
- Leg: 5 / cap 8
- Predecessor: refactor-r4   # 走り出しを確認したら `tmux kill-session -t refactor-r4`
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: 段 0 (15 件) 完了 / 段 1 (R1〜R9) 完了 / 段 2 は S1・S3〜S5 完了、S2 は「やらない」で決着
  - r2: **段 2 完了** / **段 3 完了** / 段 4 は U1+U2 まで (`95c7902`)
  - r3: **段 4 完了** → **段 5 は T1+T2 完了** (`5262070`)、T3 の前提を実測で否定 (`bd8f0e6`)
  - r4: **段 5 完了** (T3 `96c3635`+`26ad5b7` / T4+T5+T6 `8f0c042` / T4 環境記録 `6a6e526` / T4 結論 `24871d0`)
    → **段 8 の E3+E4 完了** (`9f7db10`) → **段 6 の C1 完了、CI で両枝を検証して main にマージ済み** (`085f50b`〜`fbd2ef4`)

## State

- Branch: **`main`** / clean / push 済み
- **段 6 の C1 はマージ済み。** CI で**両枝**を検証した — 初回 6 本は 11 箇所すべて cache hit、
  そのあと `gh cache delete` してから `ci.yml` の `e2e` を回し直して**インストール枝も実走**、
  どちらも緑。**ブランチ `elan-composite` / `elan-baseline` は remote に残っている**(消してよい)
- `cargo test --workspace --no-fail-fast` = **41 バイナリ / 500 passed / 0 failed / 22 ignored** (leg 4 実測)
- fmt / clippy / doc / machete / `corpus-gate.sh --verify-list` (21 tests) すべて緑
- **`tools/e2e-micro.sh` を `--keep` 無しで実走して緑** (15/15、`EXIT=0`、`cleanup failed` 無し、
  作業ツリーも clean) — 段 5 の完了条件はこれで満たした
- ディスク: 空き **17 GiB** / `/private/tmp/lean-doc-relay` は **34 MB**。`mutants.out{,.old}` は残置 (E2)

### 検証コマンド (これを使う。素で回すと doc が赤くなる。`cargo test` は **10 分超**なので background で)

```sh
mise exec -- cargo test --workspace --no-fail-fast
mise exec -- cargo fmt --check
mise exec -- cargo clippy --workspace --all-targets -- -D warnings
RUSTDOCFLAGS='-D warnings -A rustdoc::private_intra_doc_links' \
  mise exec -- cargo doc --workspace --no-deps --document-private-items
mise exec -- cargo machete
tools/corpus-gate.sh --verify-list        # 2 分超
```

## Next step

**1. 見つけた欠陥を決着させる — これが次の主題。**
**`ci-action.yml` は既に main で赤い**【実測】。`elan-baseline` ブランチ (main の内容) で
同じ 2 ジョブが同じように落ちることを確かめてあるので、**C1 のせいではない**。
落ちる場所と原因は `docs/plans/refactoring.md` §9 の「CI に当てた結果」に書いた。要点は
**`action.yml` の増分状態キャッシュの `restore-keys` が IR schema を見ていない**こと。
**まず「10 を再抽出」と言った後で古い IR を読んでいる**のがどこかを確かめること —
再抽出の出力先とキャッシュ復元先が食い違っている可能性がある。
**利用者に当たる欠陥**なので、段 7 より先。

**2. 段 7 (L1〜L3)。** 最も安全網が薄い。対象リポジトリの Lean 環境が要る。
**着手前に `df -h /` と `du -sh /private/tmp/lean-doc-relay` を見る** (段 7 は対象を使う)。

**3. 段 8 の E1 と E2。** E1 は `docs/plans/feature-sweep.md` (829 行) の `/compact-plan`
(**要約であって分割ではない**)。E2 は `mutants.out{,.old}` の始末 —
**gitignored なので消すのはユーザー判断に寄せる**。

## Files to read first

- `docs/plans/refactoring.md` — **§1 が読み方を書いている**。leg 4 が足したのは
  §8 の T3 / T4 / T5+T6 の `#### 結果`・`#### 着手前の実測` と、§9 の「結果」「CI に当てた結果」、
  §11 の E3/E4 結果。**`/compact-plan` をかけない**【判断、leg 3 で決定、leg 4 も踏襲】
- `tools/lib/common.sh` — leg 4 が作った。`on_exit` と `record_host`。**冒頭に T6 の基準がある**
- `.github/actions/setup-elan/action.yml` — C1 の成果 (ブランチ側)

## Load-bearing context

1. **計画の件数は当たる。外れるのは「表に無いもの」。**【実測 leg 4】 T4 の表は 9 行中 8 行が
   正確だった。外れたのは環境記録 (5 → 7) の 1 行だけ。**一方、表に無かった `-h|--help` は
   9 本が行番号ベタ書きで、うち 3 本が測った時点で既に壊れていた。**
   **数え直すだけでなく、「この表に無い同種のものは何か」を問う。**
2. **`rg` を `tools/` に閉じない。** leg 3 が T3 の前提を壊したのと同じ当て方の誤りを、
   leg 4 が `LITEDOC4_ROOT` で**もう一度踏んだ** (`benchmarks/tools/env.sh` 経由で 4 本が使っていた)。
   **「参照されない」と結論する前に、リポジトリ全体に当て直す。**
3. **subagent の報告は事実確認まで含めて疑う。**【実測 leg 4】 2 体とも精度は高かったが、
   `render-compare` の主張が腐っているという判定は過大 (ヘッダは実在する非 corpus テストを指していた)、
   `make-target2:88` の `OUT=$2` が「空白入りパスで壊れる」は**誤り** (代入の右辺は語分割されない)。
   **報告の判定ではなく実物を読む/走らせる。**
4. **`set -e` の下でだけ EXIT trap が終了コードを上書きする。** `set -uo pipefail` の 11 本は免疫。
   `tools/lib/common.sh` の `on_exit` が肩代わりするので、**新しい cleanup は `on_exit` で書く**。
   **`trap … EXIT` を直に書かない。**
5. **`pipefail` は 35 本すべてが立てている。** CLAUDE.md のパイプの罠は**対話セッション (zsh) の話**で、
   `tools/*.sh` には無い。`run_logged()` を作らなかったのはこのため。
6. **段 6 の C2「checkout@v4 を揃える」はやってはいけない。** 2 箇所とも `ci-template.yml` に在り、
   **出荷テンプレートの逐語写し**である。片方だけ上げるとこの workflow の存在理由が消える。
7. **CI の実測値はブランチで取る。** `gh workflow run <name> --ref <branch>`。
   **対照が要るときは main の内容を別名ブランチに置いて同じ workflow を回す** (leg 4 の `elan-baseline`)。
   `release.yml` の `workflow_dispatch` は `dry-run` 既定 true なので安全。
8. **`gh run list --json` の `databaseId` は指数表記で出ることがある** — run ID を渡すときは
   `--jq` ではなく URL か `gh run view <id>` で確かめる。
