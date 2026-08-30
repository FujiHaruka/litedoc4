# Handoff — 2026-08-30 (relay leg 1 → 2)

## State

- **作業対象は別リポジトリ `../MathML4Lean`**。lean-doc/litedoc4 は消費者で、今回は触っていない。
  lean-doc の `git status` が clean なのは正常
- MathML4Lean: branch main, clean, **`a274a8d`** まで push 済み
  (https://github.com/FujiHaruka/MathML4Lean, public)
- lean-doc: branch main, clean, `ebcf07a` まで push 済み
- **Claude セッションは常に `/Users/haruka/dev/lean-doc` で作る**(ユーザー指示)。
  handoff / relay / carryon スキルがここにしか無い。作業先へは `../MathML4Lean`
- ローカル toolchain は v4.31.0 / v4.32.2 / v4.33.0 の 3 本。**v4.33.1 は未導入で CI 専用**

## Where we are

**M0〜M4 完了。** 現在のゲート:

```
corpus gate result: 2000 / 2113 match, 107 depart under a named rule, 6 refused
unit tests result: 45 / 45 pass
```

`2000 + 107 + 6 = 2113`、**未分類の乖離 0**。3 toolchain とも警告 0、ライブラリの外部 import はゼロ。

**SoT は `../MathML4Lean/docs/plan.md`。まずこれを読む** — スコープ / 判定の設計 /
M0-M6 / 完遂基準 / 反証条件。

### 途中で変わった一番大きいこと(決定)

**バイト一致は目標でない。独立したライブラリとして正しいことが目標**
(decided 2026-08-30, user's call)。plan.md §0。判定はこう:

> **仕様が語るところは仕様が決める。仕様が黙るところはオラクルが決める。**

乖離は**名前付き逸脱ルール + 仕様の引用**で覆う。これは例外リストではない —
**どのルールにも当たらない乖離はゲートが落ちる**し、**1 行も覆わないルールもゲートが落ちる**
(`#[expect]` と同じ形)。今 4 ルール、最大でも 62 行。
**新しい反証条件: ルールが 20 個超、または 1 ルールが一致行数より多くを覆ったら判断を戻す。**

### 効いている作業原理(2 度実証された)

**記憶で判断せず実物を取り寄せる。** M2 は「恣意的」8 件中 3 件、M3 は 5 件中 4 件、
M4 は合わせ込みルールが、実物(W3C operator dictionary / MathML Core / unicode-math /
`tex.web`)を読んだら消えるか逆転した。**M4 では両方の分岐が逆向きだった。**

## Next step

**M5 = 完遂基準。litedoc4 から依存ライブラリとして使えるようにする。**

1. `../lean-doc/benchmarks/lean-prototype/lakefile.lean` は既に `require MD4Lean` を
   持っている。そこに `require MathML4Lean` を足す(git 依存、rev は `main` か tag)
2. 対象 `/Users/haruka/dev/lean-projects` の docstring にある **3 つの数式 span** を変換し、
   litedoc4 の Rust 側の出力と比べる。**バイト一致は要求しない** —
   差があれば「名前付き逸脱で説明できるか」を見る。説明できない差はバグ
3. 3 span の実体は `$$|A|^{n-1} \le \prod …$$` 形が Loomis-Whitney と Brascamp-Lieb の
   2 モジュールに(litedoc4 `benchmarks/results/mathml-2026-08-22.txt` §1)。
   `../MathML4Lean/tools/corpus/` のバイナリが同じ抽出をできる
4. **注意**: lean-prototype に手を入れるのは litedoc4 リポジトリを触ること。
   `crates/` `tools/` `.github/` は触らない。`benchmarks/lean-prototype/` は計測用なので可

その後 M6(README を他人向けに、tag、Reservoir)。

## Files to read first

- `../MathML4Lean/docs/plan.md` — **最初にこれ**
- `../MathML4Lean/CLAUDE.md` — 規律。特に「dated reports は記録であって手順書でない」
- `../MathML4Lean/docs/serializer-2026-08-30.txt` — M4 の報告。`tex.web` §764/§766/§681 からの
  導出と、閉じなかった 6 件それぞれの理由
- `benchmarks/results/mathml-2026-08-22.txt` — 対象の 3 span の出所

## Load-bearing context

- **拒否は正当な答え。数字を動かすために推測しない。** 残り 6 件は
  「MathML Core にその概念の語彙が無いので符号化が選択になる」もの
  (`\mathop` / `\!` / 台のない下付き / `cases` の `\right.` / `align` は文書レベルの環境で
  docstring span には式番号カウンタが無い)
- **ライブラリは何も import しない** (`Lean` はもちろん `Std` も)。テスト側は `Lean` 可
- **`corpus/mathlib-spans.jsonl` は絶対に手で編集しない**
- **math-core のソースは読まない**
- 単体テストは 45 件、全部「一度赤くしてから」通してある。ゲートの失敗パスも同様
- push は HTTPS + gh (ssh 不通)

## Relay control
- Mode: ON
- Goal: MathML4Lean を書き上げ、litedoc4 から依存ライブラリとして使えるようにする (plan.md の M5)
- Leg: 2 / cap 12
- Predecessor: none
- Stop-on: completion | user-decision | no-progress×2 | leg-cap
- Progress ledger:
  - r1: M0 コーパス凍結 2,123 span (49f41cf) / M1 骨組み+ゲート+CI 4 toolchain (e957aca) /
    センサス 136 コマンド (5b7edd1) / M2 字句・構文・直列化 1237 (a84602a) /
    判定設計をバイト一致から仕様基準へ (304046d) / M3 記号表+逸脱ルール 2104 (ba3f839) /
    M4 tex.web から導出、2107 説明済み・単体テスト 45 (a274a8d)
