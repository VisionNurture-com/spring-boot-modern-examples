# 002-startup-3ways

## 何を測るか

**Spring Boot の起動を速くする 3 手段を、同一アプリ・同一機体で比較する。**

| 手段 | 必要なもの |
|---|---|
| 素の JVM | なし（基準） |
| JVM AOT キャッシュ（JEP 483 + JEP 514） | JDK 25。**コード変更なし** |
| GraalVM Native Image | GraalVM |

## なぜ測るか

「Spring Boot の起動を速くするなら Native Image」という通説を確かめるためです。

JVM AOT キャッシュは **JDK 24 で導入され JDK 25 LTS が継承**しており、Spring は
**Java 25 and above で CDS より AOT キャッシュを推奨**しています。Native Image の制約
（Closed World / リフレクション Hints / 長いビルド）を負わずに起動を短縮できるなら、
選択肢は 1 つではありません。

## 測定設計（意図的な選択）

1. **基準（素の JVM）は本シナリオが唯一持つ。**他シナリオで基準を測り直さない。
   値が 2 つ存在すると、記事の 3 方式比較がどちらを引くかで揺れる。
2. **ブロック実行ではなくラウンドロビン。**「A を 7 回 → B を 7 回」だと機体の熱や
   背景負荷が特定の方式にだけ乗る。同じセット内で 3 方式を隣り合わせる。
3. **捨て走りを 1 セット行い記録しない。**初回のページキャッシュ効果を特定の方式へ
   乗せないため。実測では native の捨て走りが本計測の約 26 倍かかった。
4. **`clean` を必ず挟む。**前回の Native ビルドが `target/classes` へ残す Spring AOT
   生成クラスが素の jar に混ざり、実行前の状態で結果が変わる。
5. **素の jar を退避してから使う。**Native Image ビルドは `target/app.jar` を作り直す。
   退避しないと AOT キャッシュを作った jar と計測する jar が食い違い、
   **キャッシュが捨てられて、付けないときより遅くなる**（既定の出力に warning 1 行 + error 3 行が出る。
   実測は [`002-cache-pitfalls`](../002-cache-pitfalls/expected.md)）。

## 実行

```bash
bash scenarios/002-startup-3ways/run.sh                        # 既定 7 セット・3 方式
bash scenarios/002-startup-3ways/run.sh --sets 3               # セット数を変える
bash scenarios/002-startup-3ways/run.sh --methods jvm,aot \
     --out /tmp/x                                              # GraalVM なしで試す
```

> 🔴 **`--methods` で方式を減らした結果を `results/` へ書けません**（run.sh がガードします）。
> リポジトリにコミットする `summary.json` は常に 3 方式そろった全量です。

## 前提

| 項目 | 要件 |
|---|---|
| モード | **M3**（JDK + Maven + GraalVM） |
| Java | **25 以上**（`-XX:AOTCacheOutput` は JDK 25 の JEP 514） |
| GraalVM | `native-image` を含むもの。`--graalvm-home` か `GRAALVM_HOME` で指定（SDKMAN の `25.0.2-graalce` は自動検出） |
| Docker | 不要 |

## 出力

| ファイル | 内容 |
|---|---|
| `results/002-startup-3ways/run.log` | 生ログ（環境・ビルド・AOT 警告・捨て走り・各セットの値） |
| `results/002-startup-3ways/summary.json` | 実効値（機械が読む） |
| `scenarios/002-startup-3ways/expected.md` | **記事に載せる値の正本**（`summary.json` から生成し機械照合する） |

## 測っていないもの

- **定常状態**のスループット・p99 レイテンシ（`002-steady-throughput` の担当）
- **キャッシュが食い違ったときの出力と時間**（`002-cache-pitfalls` の担当）
- **`clean` を挟まなかった jar のサイズ**（`002-cache-pitfalls` の担当）
- メモリ使用量（RSS）
- 依存の多い実アプリでの短縮率
- CI 上での Native Image ビルド（005 の担当）
