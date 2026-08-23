# Handoff — 2026-08-23 (リファクタリング計画 完了)

## Relay control
- Mode: DONE
- Goal: `docs/plans/refactoring.md` を段 0 から段 8 まで完遂する。**達成**。
- Leg: 5 / cap 8
- Predecessor: none
- Stop-on: completion
- **結果**: 段 0〜8 の **全 62 項目が決着**。main の CI (`ci.yml` / `ci-action.yml` /
  `ci-lake.yml`) はすべて緑。**やらないと決めたものが 5 件ある** (段 2 の S2 /
  段 6 の C2・C3 / 段 7 の L1・L2) — **どれも理由を測ってから決めた**。
- Progress ledger:
  - r1: 段 0 (15 件) 完了 / 段 1 (R1〜R9) 完了 / 段 2 は S1・S3〜S5 完了、S2 は「やらない」で決着
  - r2: **段 2 完了** / **段 3 完了** / 段 4 は U1+U2 まで (`95c7902`)
  - r3: **段 4 完了** → **段 5 は T1+T2 完了** (`5262070`)、T3 の前提を実測で否定 (`bd8f0e6`)
  - r4: **段 5 完了** → **段 8 の E3+E4 完了** → **段 6 の C1 完了、CI 検証して main へ** (`085f50b`〜`fbd2ef4`)
  - r5: **利用者に当たる欠陥を決着** (`f762a0b`+`7c5dce1`、`ci-action` 5/5 緑) →
    **段 6 完了** (C3 は畳まないと決着、`dace0a5`) →
    **段 7 完了** (L3 の namespace 改名 `361548f`、L1/L2 は分割しないと判断、`ci-lake` 緑) →
    **段 8 完了** (E1 の圧縮 `c96bb7f`、E2 の削除)

## State

- Branch: **`main`** / clean / push 済み
- **計画は 62 項目すべて決着。この計画でやることは残っていない**
- **やらないと決めたものが 5 件ある** — 段 2 の S2 / 段 6 の C2・C3 / 段 7 の L1・L2。
  **どれも理由を測ってから決めた。** 再検討するなら同じ測り方をやり直すこと
- CI: `ci.yml` / `ci-action.yml` (5/5) / `ci-lake.yml` すべて main で緑。
  **`ci-action.yml` が緑になったのは 2026-08-19 以来はじめて**
- `cargo test --workspace --no-fail-fast` = **41 バイナリ / 503 passed / 0 failed / 22 ignored**
- fmt / clippy / doc (CI と同じ形) / machete / `corpus-gate.sh --verify-list` (21) /
  **`tools/e2e-micro.sh` を `--keep` 無しで 2 回実走** (どちらも `EXIT=0`) すべて緑
- remote ブランチを掃除した (`elan-composite` / `elan-baseline` / `extract-namespace` を削除)。
  **`bundle-c` と `ts-assets` は残っている** — こちらの作ったものではないので触っていない
- ディスク: 空き **17 GiB** / `/private/tmp/lean-doc-relay` は **40 MB** / `target/` は **14 GB**。
  **`mutants.out{,.old}` は消した** (E2)

### 検証コマンド (これを使う。素で回すと doc が赤くなる。`cargo test` は **20 分超**なので background で)

```sh
mise exec -- cargo test --workspace --no-fail-fast
mise exec -- cargo fmt --check
mise exec -- cargo clippy --workspace --all-targets -- -D warnings
RUSTDOCFLAGS='-D warnings -A rustdoc::private_intra_doc_links' \
  mise exec -- cargo doc --workspace --no-deps --document-private-items
mise exec -- cargo machete
tools/corpus-gate.sh --verify-list        # 2 分超
tools/e2e-micro.sh                        # Lean 込み。extractor を触ったら必ず
```

## この leg で直した欠陥 (利用者に当たる)

**`litedoc4 build` が、読めない IR の上で incremental を続けて死んでいた。**
CI のキャッシュが**前の版の状態**を復元するので、schema が上がると必ず踏む。

- **原因は計画の推測とは違った**【実測】 — 再抽出は正しく `work/inc-ir-1/` に出ていて
  10 モジュールすべて schema 5。落ちるのは**その後で base IR を読む段**
  (`ownership.rs:137` / `merge.rs:369`)。**`detect` は間違っていない。**
- 修正 2 本: `plan_of` に `ir_is_readable` (読めなければ full generation に落とす) と、
  `merge` が merged index に**その木で最も弱い schema** を書くこと。
- **index はモジュール群を保証しない** — `merge` は index を base のままにするので、
  **古い版が新しい木に merge すると index だけ新しい木**ができる。
  **この版より前の binary が作った木は直せない**ことは計画に明記してある。

## Next step

**この計画は終わった。次の主題はユーザーが決める段階。** 手持ちの候補:

1. `docs/plans/feature-sweep.md` §8 の未検証項目 — **IR とページの書き込みが atomic でない**
   (中断された再ビルドが半分書かれた IR を残す。単一プロセスで完走する限り露出しない) /
   公理の全列挙に価値があるか。
2. `crates/litedoc4-global/tests/state_and_delta.rs` の `the_state_file_is_the_prototypes_bytes` —
   **861,999 B が C-2 で動いたまま、432 モジュールの corpus がこの機材に無く測り直せていない**。
   **corpus を復元した者が最初に測り直す。**
3. **この版より前の binary が作った「index だけ新しい IR」は直せない** (下の 3 を見よ)。
   踏んだときの案内を README か拒否メッセージに書くかは未決。

## Files to read first

- `docs/plans/refactoring.md` — **先頭に状態を書いた**。§9 の「決着」が今回の欠陥、
  §10 の「結果」が段 7、§11 の E1 が圧縮の結果。**`/compact-plan` をかけない**
  【判断、leg 3〜5 で踏襲】
- `crates/litedoc4/src/build.rs` の `plan_of` / `ir_is_readable` — 「この run は続けられるか」の
  判断を集めてある場所
- `crates/litedoc4-incr/src/merge.rs` の `weakest_schema`

## Load-bearing context

1. **CI の緑は「緑になった理由」まで確かめる。**【実測 leg 5】 `ci-action` が緑になったとき、
   **キャッシュが偶然新しくなっただけ**という可能性があった。ログに
   `Cache restored from key: litedoc4-state-…-201df2e3` と
   `plan full generation (…)` の両方が出ていることを確認して初めて修正が理由だと言える。
2. **一般形に引き上げると、たいてい別の入力で崩れる。**【実測 leg 5】 `plan_of` の修正の
   根拠として「index がモジュール群を保証する」と書いたが、**保証しない**。
   `merge` を読んで気づき、コメントごと書き直した。**最初に書いた根拠は残さない。**
3. **`ci-action.yml` の `released` ジョブ (`uses: @v0.1.4`) は古い binary で、
   共有の状態キャッシュを読み書きする。** つまり「古い版が作った混在した木」は
   このリポジトリの CI の中に経路がある。
4. **`e2e-micro.sh` は extractor を「ソースが新しければ」建て直す。**
   Lean を触ったら、ログに `reusing` 行が無いことと binary の mtime を確認する
   (でないと**変更前の binary で緑になる**)。
5. **バックグラウンドの待ち合わせに `pgrep -f 'cargo test …'` を使わない** —
   **自分の待機シェルのコマンドラインが同じ文字列を含むので自分にマッチする**。
   実体のパス (`rustup/toolchains/.*/bin/cargo`) で見るか、`Monitor` を使う。
6. **段 6 の C2「checkout@v4 を揃える」はやってはいけない** (出荷テンプレートの逐語写し)。
   **C3「setup-node を畳む」もやらない** — C1 が畳んだのは**誰も見ていない重複**、
   C3 は `tools/assets-gate.sh` が `mise.toml` と**両方向で毎 push 検査している**重複。
7. **`extractor/Extract.lean` の `Stage4b` は `Litedoc4` に改名済み。**
   **小文字の `stage4b` は 20 箇所すべて別物** — イベントキー 18 / IR の `generator` 文字列 /
   `fileName`。**`generator` は IR のバイトに出るので触ると抽出キーが動く。**
8. **CI の実測値はブランチで取る。** `gh workflow run <name> --ref <branch>`。
   ただし `ci-action.yml` の `published` ジョブは `uses: @main` なので、
   **main に入るまでブランチでは直らない。**
9. **「ユーザー判断に寄せる」と書く前に、寄せる必要があるかを実物で確かめる。**
   【ユーザー指摘 2026-08-23】 E2 を 2 leg にわたって判断待ちにしていたが、
   *何のためのもので何が失われるか*を調べた時点で答えは決まっていた
   (腐った探索結果 / 記録は 3 箇所に焼き済み / `.gitignore` が disposable と明言)。
   **目的を書かずに選択肢だけ出すと、相手は判断できない。**
