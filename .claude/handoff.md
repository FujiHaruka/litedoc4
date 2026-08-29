# Handoff — 2026-08-29 (v1.1.0。aarch64 Linux と、そこで走らせて出た 3 件)

## Relay control
- Mode: DONE
- Goal: 前ハンドオフの「次に拾うならここ」の 1 番目と 2 番目。**達成**
- Leg: 1 / cap 8
- Predecessor: 2026-08-29 の v1.0.1 ハンドオフ
- Stop-on: completion

## この回でやったこと

**「機材が無い」と書いてあるコメントを 1 回走らせて確かめた**、が全部の入口。

- **`v1.1.0`** (`35425aa`、tag 済み、`latest`)。**aarch64 Linux のバイナリを出した**。
  `ubuntu-24.04-arm` は実在してすぐ起動し、**クロスは要らない**（ネイティブ musl ビルド、
  静的リンク、e2e-micro 16/16）。`release.yml` のコメントは書かれた当時は本当で、腐っていた
- **そこで初めて走らせたら 3 件出た**（→ `benchmarks/results/arm64-linux-runner-2026-08-29.txt`）:
  1. `c_char` が aarch64 Linux では unsigned。`parse.rs` の `mark as u8` が 1 行で clippy 3 件
     （`-D warnings` ならエラー）。`to_ne_bytes()[0]` に置き換えた。**`#[expect]` はどちらを書いても
     片方のアーキで不成立になる**ので使えない
  2. `packages.rs` の unit test 3 本が **PATH の `lean` を読んでいた**。
     `lean_beside("lake-that-does-not-exist")` が裸の `lean` になるため。
     **`cargo test --workspace` が緑だったのは、default toolchain を持つマシンが無かったから**。
     `queries.rs` は同じ問題を既に解いていたので、
     `litedoc4_testutil::toolchain::lake_that_is_not_there` に寄せた
  3. `clippy::from_iter_instead_of_collect` は **upstream で削除済み**で、
     **`-D warnings` はこの警告に届かない**（rustc の仕様）。CI は 1.98.0 でずっと素通ししていた。
     lint を落とし、`renamed_and_removed_lints = "deny"` を足した（ローカルで 1 回落として確認）
- **`ci.yml` に `test-arm64` ジョブ**（clippy + test のみ）。上の 1 と 2 が黙って戻らないように
- **リリースノートが tree から出るようになった**。`.github/release-notes.md` を `@VERSION@`
  置換して `--notes-file`。**`--generate-notes` を毎回手で差し替える運用は終わり**。
  `notes` は独立ジョブなので **dry run でもレンダリングを証明する**。
  番人は新設 `tools/release-notes-gate.sh`（アーカイブ名 / Lean バージョンを両方向、
  README のアーカイブ名を片方向。4 通りの落とし方を実測済み）
- **Intel macOS は対象外**【決定 2026-08-29、ユーザー判断】。`macos-15-intel` は実在して起動する
  （`macos-13` は今も起動しない）ので、**「機材が無い」という理由が嘘になった**。
  理由だけ書き換えた（→ `benchmarks/results/intel-mac-runner-2026-08-29.txt`）。
  **ビルド/テストは途中でキャンセルしたので、Intel で通るかは測っていない**
- `information-theory` の pin を `v1.1.0` に上げ、docs.yml を dispatch して再デプロイした

## 状態

- Branch **`main`** = `7e16e67`、push 済み。tag **`v1.1.0`**（assets 3 点 + checksums、`latest`）
- ローカル: `cargo test --workspace` **567 passed / 0 failed / 22 ignored**
  （**PATH に偽 `lean` を置いた状態で** — 修正前はここで 3 本落ちた）、fmt / clippy / 4 ゲート 0
- CI: `7e16e67` で CI と lake package が緑。tag では release / CI / lake / pages / action が全緑。
  `ci-action` の `uses:@v1.1.0` と `ci-lake` の「release が v1.1.0 を持つ世界」も dispatch して緑
- 実例 2 本とも公開中・v1.1.0 出力: <https://fujiharuka.github.io/information-theory/> と
  <https://fujiharuka.github.io/litedoc4/>

## まだ番人が居ないと分かっているもの

- **`clone-gate.sh` の `move` / `delete` は依然として再実走していない。** 前回から変わっていない。
  clone + 実編集 + `lake build` が 2 回要る。算術は `build-gate` の実測と一致する（422 + 12 = 434、
  移動後 435）が、通したわけではない
- **Intel macOS でビルド/テストが通るかは未測定**（上記のとおり、対象外なので測る必要も無い）

## 次に拾うならここ

- **`macos-13` を名指ししている場所が他に無いか**。今回直したのは `release.yml` と `lakefile.lean`
  の 2 箇所だけ。同じ「機材が無い」型の主張は 2026-08-18 に 2 件、今回 2 件見つかっている
- **小 RAM Linux での実走はやらない**【決定 2026-08-22】。外挿で答えが出ている

## 最初に読むファイル

1. `CLAUDE.md` の「v1.0.0 — what is promised, and what that costs to keep」（3 項目増えている）
2. `benchmarks/results/arm64-linux-runner-2026-08-29.txt` — 今回の 3 件の実測
3. `tools/release-notes-gate.sh` と `.github/release-notes.md` — ノートの新しい出どころ
4. `tools/public-surface.txt` / `tools/lean-toolchains.txt` — 約束の実体
