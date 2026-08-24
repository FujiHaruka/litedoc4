# Handoff — 2026-08-24 (コメント削減)

## Relay control
- Mode: DONE
- Goal: `CLAUDE.md` の新しい `## コードのコメント` 規則 (既定はコメントしない /
  非自明な why not だけ) に合わせて、**コード表面のコメントを全面的に削減する**。**達成**。
- Leg: 1 / cap 8
- Predecessor: none
- Stop-on: completion
- **結果**: **コード表面のコメント 25,366 → 16,443 行 (−8,923 行、−35%)**【実測】。
  **挙動は動いていない** — `cargo test --workspace --no-fail-fast` は着手前と同じ
  **564 passed / 0 failed / 22 ignored** (doctest 12 本)、`tools/e2e-micro.sh` は 15/15 緑、
  CI の 8 段も緑。
- Progress ledger:
  - r1: 全範囲。commit `c57f2df`〜`108cefa` (14 本)

## State

- Branch: **`main`** / clean / push 済み
- **この計画でやることは残っていない**
- **`action.yml` は別セッションが編集中**【ユーザーから 2026-08-24】。触っていない

## 何をしたか

| 範囲 | before → after | |
|---|---|---|
| Rust 7 crate (108 ファイル) | 16,313 → 9,761 | −40% |
| `tools/*.sh` (37 本) | 3,396 → 2,066 | −39% |
| `.github/workflows/*.yml` (13 本) | 921 → 661 | −28% |
| TS + CSS (35 本) | 997 → 621 | −38% |
| `benchmarks/tools` の `*.ts` `*.sh` (30 本) | 1,316 → 1,152 | −12% |
| `extractor/Extract.lean` + `lakefile.lean` | 511 → 324 | −37% |
| `benchmarks/tools/*.py` (12 本) | 251 → 181 | −28% |

規則そのものも整備した — `## コードのコメント` を新設し、**コンフリクトする
「コード表面から docs を参照しない」規則を削除**、先頭の SoT 記述と `crates/` の表を揃えた。

## ついでに直した、腐っていたもの

コメント削減の副産物。**どれも製品の欠陥ではないが、読む人を誤らせるもの**:

- **死んだ計画への参照** — doc コメント / `litedoc4 --help` の usage / ゲートの拒否
  メッセージ / assert メッセージ。実装計画 19 本は 2026-08-24 に削除済みで、
  `plan §6` `M3-d2 の債務` `段 D` `stage 5e (e)` `決定 2` はもう解決しない
- **doc の付き先が隣の宣言にずれていた 4 件** (`page_parts.rs` / `lib.rs` / `ledger.rs` /
  `merge.rs`) — 関数が消えると doc が次の宣言へ黙って移る。`cargo doc` も clippy も見ない
- **doc の数字とアサーションの食い違い 5 件** — 「64 のうち 21」と書いてあって実体は
  `[&str; 69]` だった。数字を直すのではなく**定数名を指す**ようにした
- **`docs/provenance.md` の腐った行番号** — `style.css:320-325` は既に外れていた。
  セレクタ名 (`.fn` / `.break_within`) で指すようにし、`Extract.lean` の行数も実測に更新
- **`tools/*-reference.sh` / `*-compare.sh` の 7 本が説明していた `--impl ts`** —
  引数ループを読んで**実在しない経路**であることを確認して落とした
- **`ci.yml` の「this repository's doc comments are where the reasoning lives」** —
  新規則と食い違うので書き直した

## 見つけたが直していないもの (次に拾うならここ)

- **`tools/build-gate.sh` の `EXPECT_BASE=443` はどこからも読まれていない。**
  コメントは「ページ数の取り違えを捕まえる分母」だと言っているが、gate 1 は
  `$(files_in "$REF_IR")` を渡していて、書き下した分母が効いているのは移動後のツリーだけ
- **`tools/search-gate.sh` は存在しない**のに、`index-format.ts` と `score.ts` が
  生きているゲートとして引用していた (引用は落としたが、そのゲート自体が無い)
- **`assets.rs` の `from_scripts >= 8` は余裕が 1**。実数は 9 で、`search-empty` が
  2 ファイルで代入されている。片方を消すと 8 になり、次で落ちる。
  失敗メッセージは「走査が壊れたか」と言うが、走査は壊れていない
- **`build.rs` が node を要るという説明が 6 ワークフロー 11 箇所にコピペ**されていて、
  全コピーが編集途中で壊れた文だった。1 ファイル 1 コピーに減らしたが、
  `setup-elan` と同じ composite action にすれば重複自体が消える
- **`--jobs` の拒否メッセージが `build.rs` と `pipeline.rs` にバイト単位で重複**。
  `LINK_INDEX_COST` のように共有されていない (「判断は 1 箇所に集める」がユーザー向け
  文字列のレベルで破れている)
- **`benchmarks/tools/*.ts` は一度も単体で型検査されていない** — `deno.json` が無く、
  `check-site-browser.ts` は `deno check` で既存の `TS18046` を出す (今回の変更前から)
- **`extractor/README.md`** だけが stage4b / 7d の実験期の枠組みで書かれたまま残っている

## 意図的に残したもの (「消し忘れ」と読んで直さない)

- `tools/make-target2.sh` が生成する `.lean` の docstring 3 件 (`L3-1` `L3-2` `plan 決定 5`) —
  **target 2 の IR とページのバイトに出る**。直すなら `target2-gate.sh` を回せる状態で
- `extractor/Extract.lean` の `stage4b.*` キー 16 件 — **生きているワイヤ形式**
  (→ CLAUDE.md の保護一覧 6 種目に追加した)
- `benchmarks/tools` の計測レポート見出しにある `stage 1` / `stage 3` —
  **実測値に付いた唯一の由来標識**
- `benchmarks/results/**` / `crates/*/tests/data/**` — 凍結。触っていない

## この作業で恒久化した罠 (CLAUDE.md に入れた)

- **ゲートの部分集合を commit の判定に使わない** (`## 品質ゲート`)
- **doc の折り返しは `clippy::doc_lazy_continuation` で落ちる。`cargo check` では出ない**
  (`## Rust の lint`)
- **走っているシェルスクリプトを書き換えると実行が壊れる** (`## この機材の罠`)
- **計時 JSONL の `phase` キーは生きている識別子** (`## リポジトリの構成` の保護一覧 6 種目)
