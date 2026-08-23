# Handoff — 2026-08-23 (リファクタリング)

## Relay control
- Mode: ON
- Goal: `docs/plans/refactoring.md` を段 0 から段 8 まで完遂する。各項目は**テストを先に書いてから直す**。
  1 commit = 1 項目。各段の終わりで下の 5 つを緑に戻す。
- Leg: 2 / cap 8
- Predecessor: none (leg 1 はユーザーの元セッション。kill しない)
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: **段 0 (15 件) 完了** / **段 1 (R1〜R9) 完了** / **段 2 は S1・S3・S4・S5 完了、S2 は退避**。
    `78db946` + S4 まで push 済み

## State

- Branch: **`main`** / clean
- `cargo test --workspace` = **38 バイナリ / 442 passed / 0 failed / 21 ignored**
- fmt / clippy / doc / corpus-gate / provenance-gate すべて緑
- **`git stash` に 1 件ある**: "S2 の RootHref (機械置換で制御を失った)"。
  **段 2 の S2 は「やらない」と決着済**なので、拾う必要は無い (捨ててよい)

### 検証コマンド (これを使う。素で回すと doc が赤くなる)

```sh
mise exec -- cargo test --workspace --no-fail-fast
mise exec -- cargo fmt --check
mise exec -- cargo clippy --workspace --all-targets -- -D warnings
RUSTDOCFLAGS='-D warnings -A rustdoc::private_intra_doc_links' \
  mise exec -- cargo doc --workspace --no-deps --document-private-items
tools/corpus-gate.sh --verify-list
```

## Next step

**段 2 の残り 4 つ: S6 → S7 → S8。** (S2 は「やらない」で決着)

- **S6** — `autolink.rs:795` `PageLinks::name_to_link` が `expect` で panic する。
  `# Panics` を書いて `debug_assert!` を `new` に置く (構築時に落とす) か、
  `NameIndex::page_links` にして `decl_names` を内部で作る
- **S7** — 公開 API 22 件の棚卸し。**3 分類する** (計画 §5 の S7)。
  `decl::used_by_html` だけ re-export から漏れているので**兄弟 3 つを揃える**
- **S8** — `render_site` から `write_page` を抜く (`assets.rs:99-105` と同型)

その後 段 3 (X1〜X8) → 段 4 (U1〜U6) → 段 5〜8。

## この計画で繰り返し起きていること (次 leg が同じ手順を踏むために)

1. **計画どおりに書くと落ちる項目がある。落ちてから範囲が決まる。**
   - S4: `member_li` にクラス名を渡したら**スタイルシートゲートが落ちた** —
     クラス名がテキストから消えると検査できない。開始タグは呼び出し元に残す形に変えた
   - S5: ゲートを一度落としたら、計画の「TS の 8 クラスが未検査」が**7 クラス**だと分かった
   - R7 / R9: 測ってから範囲を絞った
2. **機械置換で範囲を制御できないものは手でやる** — S2 で 60 箇所超のリテラルを
   正規表現で包もうとして失敗した (`lean_quote("./")` まで包んだ)
3. **`#[expect]` は発火しなくなると落ちる** — `cli.rs` で 1 度踏んだ。理由はコメントに移す
4. **`--fix` の結果は `git diff` で読む**

## Files to read first

- `docs/plans/refactoring.md` — 冒頭に読み方がある。**§14「触らないもの」は着手前に必ず読む**
- 各項目の「結果」節に、その項目で分かったことが書いてある
