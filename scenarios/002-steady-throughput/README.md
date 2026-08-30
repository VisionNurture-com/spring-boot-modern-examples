# 002-steady-throughput

## 何を測るか

**ウォームアップ後の定常状態**で、素の JVM / JVM AOT キャッシュ / GraalVM Native Image の
**スループットと p99 レイテンシ**がどう違うか。

## なぜ測るか

`002-startup-3ways` は**起動**を測りました。Native Image が 95% 以上速いという結果です。
しかし起動が速いことと、動き続けたときに速いことは別です。

JIT は実行時にホットパスを最適化しますが、AOT（Native Image）はビルド時に固定されます。
**定常状態では結論が逆になるのか**を確かめます。

## 測定設計（意図的な選択）

1. **負荷を 2 種類かける。**軽い負荷（HTTP の往復が支配的）と重い負荷（アプリの計算が支配的）。
   事前の感度測定で、計算量を 10 倍にしてもスループットがほぼ変わらない領域があると分かったため。
   その領域で測ると、JIT と AOT の差ではなく HTTP の往復を測ってしまう。
2. **ウォームアップ中の応答は記録しない。**JIT が最適化を終える前の値を混ぜないため。
   ウォームアップ時間の妥当性は `expected.md` に実測を載せている。
3. **ラウンドロビン。**1 ラウンド = jvm → aot → native。機体の状態を 3 方式へ均等に乗せる。
4. **負荷生成器は JDK だけで動くものをリポジトリに置く**（`tools/loadgen/LoadGen.java`）。
   読者が `wrk` や `hey` を別途インストールしなくても同じ計測を再現できる。

## 実行

```bash
bash scenarios/002-steady-throughput/run.sh
bash scenarios/002-steady-throughput/run.sh --rounds 1 --duration-sec 5 --out /tmp/x
bash scenarios/002-steady-throughput/run.sh --methods jvm,aot --out /tmp/x   # GraalVM なし
```

> 🔴 **`--methods` で方式を減らした結果を `results/` へ書けません**（run.sh がガードします）。

## 前提

| 項目 | 要件 |
|---|---|
| モード | **M3**（JDK + Maven + GraalVM） |
| Java | 25 以上 |
| GraalVM | `native-image` を含むもの（SDKMAN の `25.0.2-graalce` は自動検出） |
| ポート | 18080 を使う（`--` で変更したい場合は run.sh の `PORT` を編集） |

## 既知の限界

- **クライアントとサーバが同一機体で CPU を共有する。**絶対値はその前提で読むこと。
  方式間の比較には同じ条件が等しくかかる。
- 測っているのは**合成負荷 2 種類**であり、実アプリのワークロードではない。
- **機序は測っていない**（JIT のコンパイル状況やインライン展開の様子は見ていない）。

## 出力

| ファイル | 内容 |
|---|---|
| `results/002-steady-throughput/run.log` | 生ログ（環境・ビルド・各ラウンドの値） |
| `results/002-steady-throughput/summary.json` | 実効値（機械が読む） |
| `scenarios/002-steady-throughput/expected.md` | **記事に載せる値の正本** |

## 測っていないもの

- メモリ使用量（RSS）
- 起動時間（`002-startup-3ways` の担当）
- 依存の多い実アプリでの差
