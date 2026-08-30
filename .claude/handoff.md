# Handoff — 2026-08-31 (relay leg 4 → leg 5)

## State

**M4 完了。** `litedoc4 build --root e2e/micro` が Lean で **23/23 バイト一致**し、
`site-gate` / `config-gate` が緑。**M5 も 2 項目済み**（`--state` と `Generation`）。
計画は `.claude/purelean-plan.md`（このリレーの SoT）。

- litedoc4: main `51d907e`、clean、push 済み。CI は `7b8fee5` まで緑
  （`51d907e` は docs のみで、push 時点では走行中だった。**leg 5 は最初に `gh run list` で確認すること**）
- `tools/purelean-micro-gate.sh` **14/14**、`purelean-render-gate.sh` 6/6（422 モジュール）、
  `cargo test --workspace` 582 passed
- disk **8.1 GiB**。`/private/tmp/lean-doc-relay/purelean`（398 MB）は
  `purelean-render-gate.sh` が要る — **消さないこと**。他は掃除済み

## Next step — M5 incremental

**完了判定そのものが直っていない。** 5 つの判定器のうち **4 つは比較器で、Lean を指せない**
（`*-reference.sh` が `RUST_BIN` をハードコード、実測）。→ 計画の U13。

やる順（計画の U1〜U13 表に対応。**U6 が一番安く立つ** — 対象リポジトリが要らない）:

1. **`Json.lean` を先に直す** — `JScan.digits` は整数しか読まず、`incremental --timings` が
   読み戻す `work/*-timings*.json` は `"copySeconds":0.000398834` を含む。**U11 の前に必須**
2. **U2 ledger リーダ + `checkLedger`** — M5 が読む中で**最も鋭い入口**
   （`--ledger` は任意のバージョンが書いたファイル）
3. U6 merge（`merge-reference.sh` は base IR だけで走る）→ U4 impact → U5 ownership
4. U10 Resident の遅延起動 → U11 pipeline → U12 planOf 4〜9

**`benchmarks/lean-prototype/Incr.lean`（1,079 行）が impact/ownership/merge を実装済み**で、
422 モジュールで Rust とバイト一致を確認済み。ただし**無いものがそのファイルに書いてある**
（`--census` / `--exclude` / `--removed` / `--modules` / `--timings` / `merge --verify` /
拒否のほぼ全部）。`Litedoc4.Json` / `Litedoc4.Ir` への載せ替えも要る。

## Files to read first

1. `.claude/purelean-plan.md` — M5 の節に**移植単位の表・実測値・前提を崩す発見**が全部ある。まずここ
2. `tools/purelean-micro-gate.sh` — leg 5 の採点器（14 項目）。新項目は 1 つずつ落としてから通す
3. `crates/litedoc4/src/pipeline.rs`（1,534 行）— U11 の仕様
4. `benchmarks/lean-prototype/Incr.lean` — U4〜U6 の下敷き
5. `crates/litedoc4/tests/incremental.rs` — 61 分岐の点検表

## Load-bearing context

- **`ownership` の `watching` ガードは最適化ではない。** 名前が動いていなければ base の IR を
  1 つも読まない / 動いていれば全部読む。**423 読み対 2 読み**（実測）。
  無条件にループする移植は「正しくて 200 倍遅い」
- **Rust は最初に抽出するリクエストでサーバを遅延起動する。** Lean は full path しか無いので
  常に起動している。**incremental を入れるとき遅延も一緒に運ばないと、いちばん多い答え
  （「stale なものは無い」）がいちばん高くつく**
- **項目 13 は `litedoc4-build.json` を `work.irReads` ごと比較する。** 実測値は
  full `{3,22,4,29}` / incremental 変化なし `{5,11,2,18}` / 1 モジュール編集 `{10,46,4,60}`。
  読む位置がずれるとここにだけ出る
- **対象は 432 ではなく 422 モジュール**（→ `benchmarks/results/target-drift-2026-08-31.txt`）。
  過去の 432 era の数字はそのまま正しい。**新しい数字と並べないこと**
- **壊したのにゲートが落ちないときは、まず「本当に壊れたか」を疑う。** Lean ソースの文字列は
  `\"` でエスケープされているので、素朴な置換パターンは 0 箇所しか当たらずに成功したように見える
  （leg 4 で 2 回踏んだ）
- **`say "…\`x\`…"` はコマンド置換になる。** `workflow-gate.sh` の質問 4 が機械で見るようになった

## Relay control
- Mode: ON
- Goal: litedoc4 の Rust 半分を Lean に移植し切る（計画 `.claude/purelean-plan.md` の M1〜M10）
- Leg: 5 / cap 40
- Predecessor: purelean-r4
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: 計画 + 4 判断 (1c3d7ce) / M1 骨格 (8294e56) / 帰属表示 (129ea01) /
    M2 レンダラ移設・分割 422/422 (bd505f4) / docs-gate の穴 184→199 (3ee806d) /
    MathML4Lean v0.1.1 + pin (542303e)
  - r2: **M2 完了**。IR 読み込みを index.json 起点へ (b715912) / extractor ビルドを 1 か所へ
    (d47f9c1) / 不在の名前でレンダを止める (b0e16f7) / math フォールバックを要約に
    (6a7084a) / CI ゲート purelean-micro 5 項目 + render ゲート項目 6 (91f0c11) /
    Linux CI も同バイト (b765a2c) / M3-M4 境界を実測で引き直し (5dc900c)
  - r3: **M3 完了**。境界を再確定 20 ファイル (d91c3d9) / global の JSON 4 種 + 名前分割器の
    乖離 (53d4f51) / landing page 4 枚 (8f641ce) / search-index.bin + ゲート 5→8 項目
    (ab32c35) / 消費者ビルド 6.2 s (8b038b0)
  - r4: **M4 完了 + M5 の 2 項目**。アセット 4 ファイルを `assets/` に一本化 + 新ゲート
    (c47ee15, d9f4fff) / M4 仕様と handoff の 3 誤り (a53cf57) / レンダラの `--root`
    4 通りバイト一致 (9c127c2) / resident プロトコル実証 (fc667fc) / SHA-256 + ledger
    11 通り一致 (efaa12e) / **build 23/23 + ゲート 4 項目** (1ae4c7a) / state cache +
    source-url の `//` を塞ぐ (b1141e5) / Generation digest 一致 (7b8fee5) /
    対象 422 + M5 仕様 (51d907e)。ゲートは 8 → 14 項目、増分は全部個別に落としてから通した
